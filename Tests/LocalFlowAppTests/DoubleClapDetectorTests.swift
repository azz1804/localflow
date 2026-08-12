import Foundation
import XCTest
@testable import LocalFlowApp

final class DoubleClapDetectorTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameCount = 512

    func testTwoSeparatedClapsTriggerOnce() {
        var detector = DoubleClapDetector()

        XCTAssertFalse(process(clap(), with: &detector))
        feedSilence(seconds: 0.3, into: &detector)
        XCTAssertTrue(process(clap(), with: &detector))
        XCTAssertFalse(process(silence(), with: &detector))
    }

    func testQuietRealWorldClapsStillTrigger() {
        var detector = DoubleClapDetector()
        let quietClap = clap().map { $0 * 0.62 }

        XCTAssertFalse(process(quietClap, with: &detector))
        feedSilence(seconds: 0.28, into: &detector)
        XCTAssertTrue(process(quietClap, with: &detector))
    }

    func testMeasuredBuiltInMicrophoneClapsTrigger() {
        var detector = DoubleClapDetector()
        let firstClap = DoubleClapSignalFeatures(
            peak: 0.033,
            rootMeanSquare: 0.006,
            crestFactor: 5.16,
            highFrequencyRatio: 0.18
        )
        let secondClap = DoubleClapSignalFeatures(
            peak: 0.036,
            rootMeanSquare: 0.011,
            crestFactor: 3.26,
            highFrequencyRatio: 0.17
        )

        XCTAssertFalse(
            detector.process(features: firstClap, duration: 0.012)
        )
        feedSilence(seconds: 0.3, into: &detector)
        XCTAssertTrue(
            detector.process(features: secondClap, duration: 0.012)
        )
    }

    func testRoomNoiseValleyReleasesDetectorBetweenClaps() {
        var detector = DoubleClapDetector()
        let clap = DoubleClapSignalFeatures(
            peak: 0.09,
            rootMeanSquare: 0.024,
            crestFactor: 3.75,
            highFrequencyRatio: 0.22
        )
        let roomNoise = DoubleClapSignalFeatures(
            peak: 0.02,
            rootMeanSquare: 0.008,
            crestFactor: 2.5,
            highFrequencyRatio: 0.12
        )

        XCTAssertFalse(detector.process(features: clap, duration: 0.012))
        for _ in 0..<20 {
            XCTAssertFalse(
                detector.process(features: roomNoise, duration: 0.012)
            )
        }
        XCTAssertTrue(detector.process(features: clap, duration: 0.012))
    }

    func testSingleClapAndSpeechDoNotTrigger() {
        var detector = DoubleClapDetector()

        XCTAssertFalse(process(clap(), with: &detector))
        feedSilence(seconds: 0.25, into: &detector)
        for _ in 0..<12 {
            XCTAssertFalse(process(voice(), with: &detector))
        }
        feedSilence(seconds: 0.8, into: &detector)
        XCTAssertFalse(process(clap(), with: &detector))
    }

    func testClapsThatAreTooCloseAreTreatedAsOneTransient() {
        var detector = DoubleClapDetector()

        XCTAssertFalse(process(clap(), with: &detector))
        feedSilence(seconds: 0.06, into: &detector)
        XCTAssertFalse(process(clap(), with: &detector))
    }

    func testRefractoryPeriodPreventsImmediateRetrigger() {
        var detector = DoubleClapDetector()

        XCTAssertFalse(process(clap(), with: &detector))
        feedSilence(seconds: 0.25, into: &detector)
        XCTAssertTrue(process(clap(), with: &detector))
        feedSilence(seconds: 0.25, into: &detector)
        XCTAssertFalse(process(clap(), with: &detector))
        feedSilence(seconds: 0.25, into: &detector)
        XCTAssertFalse(process(clap(), with: &detector))
    }

    func testClapFeaturesRejectTonalVoice() {
        let clapFeatures = features(for: clap())
        let voiceFeatures = features(for: voice())

        XCTAssertGreaterThan(clapFeatures.crestFactor, 3.2)
        XCTAssertGreaterThan(clapFeatures.highFrequencyRatio, 0.5)
        XCTAssertLessThan(voiceFeatures.crestFactor, 2)
        XCTAssertLessThan(voiceFeatures.highFrequencyRatio, 0.1)
    }

    func testIdleMonitorPausesDuringRecordingAndProcessing() {
        XCTAssertTrue(
            DoubleClapMonitoringPolicy.shouldListenWhileIdle(for: .idle)
        )
        XCTAssertTrue(
            DoubleClapMonitoringPolicy.shouldListenWhileIdle(
                for: .done("ok", .pasted)
            )
        )
        XCTAssertFalse(
            DoubleClapMonitoringPolicy.shouldListenWhileIdle(
                for: .recording(1, .toggle)
            )
        )
        XCTAssertFalse(
            DoubleClapMonitoringPolicy.shouldListenWhileIdle(for: .processing)
        )
    }

    func testRecordingIgnoresTheStartingClapsEcho() {
        XCTAssertFalse(
            DoubleClapRecordingStopPolicy.shouldStop(
                detectionReceived: true,
                recordingDuration: 0.3
            )
        )
        XCTAssertTrue(
            DoubleClapRecordingStopPolicy.shouldStop(
                detectionReceived: true,
                recordingDuration: 1.2
            )
        )
        XCTAssertFalse(
            DoubleClapRecordingStopPolicy.shouldStop(
                detectionReceived: false,
                recordingDuration: 1.2
            )
        )
    }

    private func process(
        _ samples: [Float],
        with detector: inout DoubleClapDetector
    ) -> Bool {
        samples.withUnsafeBufferPointer { buffer in
            detector.process(
                samples: buffer.baseAddress!,
                stride: 1,
                frameCount: buffer.count,
                sampleRate: sampleRate
            )
        }
    }

    private func feedSilence(
        seconds: TimeInterval,
        into detector: inout DoubleClapDetector
    ) {
        let bufferDuration = Double(frameCount) / sampleRate
        let count = Int(ceil(seconds / bufferDuration))
        for _ in 0..<count {
            _ = process(silence(), with: &detector)
        }
    }

    private func features(for samples: [Float]) -> DoubleClapSignalFeatures {
        samples.withUnsafeBufferPointer { buffer in
            DoubleClapSignalFeatures.measure(
                samples: buffer.baseAddress!,
                stride: 1,
                frameCount: buffer.count
            )
        }
    }

    private func silence() -> [Float] {
        Array(repeating: 0, count: frameCount)
    }

    private func clap() -> [Float] {
        var samples = silence()
        let pattern: [Float] = [1, -0.72, 0.46, -0.91, 0.63, -0.38]
        for index in 0..<64 {
            let decay = exp(-Float(index) / 16)
            samples[index] = 0.92 * decay * pattern[index % pattern.count]
        }
        return samples
    }

    private func voice() -> [Float] {
        (0..<frameCount).map { index in
            0.35 * sin(
                2 * Float.pi * 220 * Float(index) / Float(sampleRate)
            )
        }
    }
}
