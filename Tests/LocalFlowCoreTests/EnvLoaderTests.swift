import XCTest
@testable import LocalFlowCore

final class EnvLoaderTests: XCTestCase {
    func testParseEnvFile() {
        let env = EnvLoader.parse(
            """
            # ignored
            OPENAI_API_KEY=sk-test
            TRANSCRIPTION_LANGUAGE="fr"
            ENABLE_POLISH=true
            export POLISH_MODEL='gpt-4o-mini'
            EMPTY=
            """
        )

        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-test")
        XCTAssertEqual(env["TRANSCRIPTION_LANGUAGE"], "fr")
        XCTAssertEqual(env["ENABLE_POLISH"], "true")
        XCTAssertEqual(env["POLISH_MODEL"], "gpt-4o-mini")
        XCTAssertEqual(env["EMPTY"], "")
    }

    func testConfigurationDefaultsAndOverrides() {
        let configuration = AppConfiguration(env: [
            "OPENAI_API_KEY": "sk-test",
            "ENABLE_POLISH": "yes",
            "HISTORY_RETENTION_DAYS": "14",
            "PASTE_RESTORE_DELAY_MS": "1200",
            "ORB_THEME": "solar-nova",
            "ENABLE_PROMPT_MODE": "true",
            "ENABLE_MAIL_MODE": "false",
            "PROMPT_MODEL": "gpt-prompt-test",
            "PREFER_BUILT_IN_MIC_FOR_BLUETOOTH": "false"
        ])

        XCTAssertTrue(configuration.isOpenAIConfigured)
        XCTAssertEqual(configuration.transcriptionModel, "gpt-4o-mini-transcribe")
        XCTAssertEqual(configuration.transcriptionLanguage, "fr")
        XCTAssertFalse(configuration.enablePolish)
        XCTAssertTrue(configuration.enablePromptMode)
        XCTAssertEqual(configuration.outputMode, .prompt)
        XCTAssertEqual(configuration.promptModel, "gpt-prompt-test")
        XCTAssertEqual(configuration.historyRetentionDays, 14)
        XCTAssertEqual(configuration.pasteRestoreDelayMilliseconds, 1200)
        XCTAssertEqual(configuration.orbThemeOverride, "solar-nova")
        XCTAssertFalse(configuration.preferBuiltInMicrophoneForBluetooth)
    }

    func testNonPositiveHistoryRetentionUsesForeverWithoutAllowingNegatives() {
        XCTAssertEqual(
            AppConfiguration(env: ["HISTORY_RETENTION_DAYS": "0"]).historyRetentionDays,
            0
        )
        XCTAssertEqual(
            AppConfiguration(env: ["HISTORY_RETENTION_DAYS": "-30"]).historyRetentionDays,
            0
        )
        XCTAssertEqual(AppConfiguration(historyRetentionDays: 0).historyRetentionDays, 0)
    }

    func testConfigurationCanRoundTripThroughEnvFile() {
        let configuration = AppConfiguration(
            openAIAPIKey: "sk-test",
            transcriptionModel: "gpt-4o-transcribe",
            transcriptionLanguage: "fr",
            enablePolish: false,
            polishModel: "gpt-4o-mini",
            enablePromptMode: false,
            enableMailMode: true,
            promptModel: "gpt-5.6-luna",
            holdHotkey: "fn",
            fallbackHoldHotkey: "option+space",
            toggleHotkey: "fn+space",
            historyRetentionDays: 45,
            restoreClipboardAfterPaste: false,
            pasteRestoreDelayMilliseconds: 500,
            orbThemeOverride: "cosmic-ink",
            preferBuiltInMicrophoneForBluetooth: false
        )

        let parsed = EnvLoader.parse(configuration.envFileContents())
        let roundTripped = AppConfiguration(env: parsed)

        XCTAssertEqual(roundTripped, configuration)
    }

    func testBluetoothInputProtectionDefaultsToEnabled() {
        XCTAssertTrue(
            AppConfiguration().preferBuiltInMicrophoneForBluetooth
        )
        XCTAssertTrue(
            AppConfiguration(env: [:])
                .preferBuiltInMicrophoneForBluetooth
        )
    }

    func testPromptAndMailModesAreExclusiveAndLegacyPolishStaysOff() {
        XCTAssertFalse(AppConfiguration().enablePromptMode)
        XCTAssertFalse(AppConfiguration().enableMailMode)
        XCTAssertEqual(AppConfiguration().promptModel, "gpt-5.6-luna")

        var configuration = AppConfiguration(enablePolish: true)
        XCTAssertEqual(configuration.outputMode, .transcript)
        XCTAssertFalse(configuration.enablePolish)
        configuration.outputMode = .email
        XCTAssertTrue(configuration.enableMailMode)
        XCTAssertFalse(configuration.enablePromptMode)
        configuration.outputMode = .prompt
        XCTAssertTrue(configuration.enablePromptMode)
        XCTAssertFalse(configuration.enableMailMode)
        configuration.outputMode = .transcript
        XCTAssertFalse(configuration.enablePolish)
        XCTAssertFalse(configuration.enablePromptMode)
        XCTAssertFalse(configuration.enableMailMode)

        configuration.outputMode = .polish
        XCTAssertEqual(configuration.outputMode, .transcript)
    }

    func testConfigurationStoreRestrictsAPIKeyFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LocalFlowConfigurationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".env")

        try ConfigurationStore.save(
            AppConfiguration(openAIAPIKey: "sk-private"),
            to: url
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
}
