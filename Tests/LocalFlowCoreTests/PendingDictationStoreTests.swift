import Foundation
import XCTest
@testable import LocalFlowCore

final class PendingDictationStoreTests: XCTestCase {
    func testPromptModeMetadataSurvivesPendingAndHistoryRoundTrip() throws {
        let job = PendingDictationJob(
            durationSeconds: 2.5,
            targetApplication: nil,
            parameters: PendingDictationParameters(
                transcriptionModel: "transcribe",
                transcriptionLanguage: "fr",
                enablePolish: false,
                polishModel: "polish",
                outputMode: .prompt,
                promptModel: "gpt-5.6-luna",
                dictionary: .empty
            ),
            stage: .ready,
            transcribedText: "texte parlé",
            finalText: "Objectif : créer la feature.",
            polished: true,
            outputMode: .prompt
        )

        let data = try JSONEncoder().encode(job)
        let restored = try JSONDecoder().decode(
            PendingDictationJob.self,
            from: data
        )

        XCTAssertEqual(restored.parameters.resolvedOutputMode, .prompt)
        XCTAssertEqual(restored.parameters.promptModel, "gpt-5.6-luna")
        XCTAssertEqual(restored.makeHistoryRecord()?.resolvedOutputMode, .prompt)
    }

    func testMailModeMetadataSurvivesPendingAndHistoryRoundTrip() throws {
        let job = PendingDictationJob(
            durationSeconds: 1.5,
            targetApplication: nil,
            parameters: PendingDictationParameters(
                transcriptionModel: "transcribe",
                transcriptionLanguage: "fr",
                enablePolish: false,
                polishModel: "polish",
                outputMode: .email,
                promptModel: "gpt-5.6-luna",
                dictionary: .empty
            ),
            stage: .ready,
            transcribedText: "salut le backend plante",
            finalText: "Objet : Incident backend\n\nBonjour,\n\nLe backend plante.",
            polished: true,
            outputMode: .email
        )

        let restored = try JSONDecoder().decode(
            PendingDictationJob.self,
            from: JSONEncoder().encode(job)
        )

        XCTAssertEqual(restored.parameters.resolvedOutputMode, .email)
        XCTAssertEqual(restored.makeHistoryRecord()?.resolvedOutputMode, .email)
    }

    func testLegacyPendingParametersResolveToPolishWithoutNewFields() throws {
        let legacyJSON = #"{"transcriptionModel":"transcribe","transcriptionLanguage":"fr","enablePolish":true,"polishModel":"polish","dictionary":{"terms":[],"replacements":{}}}"#

        let parameters = try JSONDecoder().decode(
            PendingDictationParameters.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(parameters.resolvedOutputMode, .polish)
        XCTAssertNil(parameters.promptModel)
    }

    func testRecordingSurvivesCheckpointsAndCreatesStableHistoryRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: source)

        let store = PendingDictationStore(rootURL: root)
        var job = try await store.persistRecording(
            from: source,
            durationSeconds: 1.25,
            targetApplication: TargetApplicationInfo(
                localizedName: "Editor",
                bundleIdentifier: "com.example.editor"
            ),
            parameters: PendingDictationParameters(
                transcriptionModel: "transcribe",
                transcriptionLanguage: "fr",
                enablePolish: true,
                polishModel: "polish",
                dictionary: .empty
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let persistedAudioURL = await store.audioURL(for: job)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: persistedAudioURL.path)
        )
        XCTAssertNil(job.emptyTranscriptionResponseCount)

        job.transcribedText = "texte brut"
        job.finalText = "Texte final."
        job.polished = true
        job.emptyTranscriptionResponseCount = 2
        job.stage = .ready
        try await store.save(job)

        let restoredJobs = try await store.loadAll()
        let restored = try XCTUnwrap(restoredJobs.first)
        XCTAssertEqual(restored, job)
        XCTAssertEqual(restored.makeHistoryRecord()?.id, job.recordID)
        XCTAssertEqual(restored.makeHistoryRecord()?.finalText, "Texte final.")
    }

    func testMalformedManifestIsQuarantinedInsteadOfDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: jobDirectory.appendingPathComponent("job.json")
        )
        try Data([1]).write(
            to: jobDirectory.appendingPathComponent("recording.wav")
        )

        let store = PendingDictationStore(rootURL: root)
        let jobs = try await store.loadAll()

        XCTAssertTrue(jobs.isEmpty)
        let quarantine = root.appendingPathComponent("quarantine", isDirectory: true)
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: quarantine.path)).isEmpty
        )
    }

    func testPermanentFailureQuarantinePreservesJobOutsideRetryQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: source)

        let store = PendingDictationStore(rootURL: root)
        let job = try await store.persistRecording(
            from: source,
            durationSeconds: 2,
            targetApplication: nil,
            parameters: PendingDictationParameters(
                transcriptionModel: "transcribe",
                transcriptionLanguage: "fr",
                enablePolish: false,
                polishModel: "polish",
                dictionary: .empty
            )
        )

        try await store.quarantine(job, reason: "invalid audio")

        let remainingJobs = try await store.loadAll()
        XCTAssertTrue(remainingJobs.isEmpty)
        let quarantine = root.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        let quarantinedJobs = try FileManager.default.contentsOfDirectory(
            atPath: quarantine.path
        )
        XCTAssertEqual(quarantinedJobs.count, 1)
        XCTAssertTrue(quarantinedJobs[0].contains("invalid-audio"))
        let preservedDirectory = quarantine.appendingPathComponent(
            quarantinedJobs[0],
            isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preservedDirectory
                    .appendingPathComponent("job.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preservedDirectory
                    .appendingPathComponent("recording.wav").path
            )
        )
    }
}
