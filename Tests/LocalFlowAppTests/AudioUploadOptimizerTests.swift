import AVFoundation
import Foundation
import XCTest
@testable import LocalFlowApp

final class AudioUploadOptimizerTests: XCTestCase {
    @MainActor
    func testPrepareKeepsSmallRecordingsUncompressed() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-small-upload-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try makeTone(at: sourceURL, duration: 0.5)
        let optimized = await AudioUploadOptimizer.prepare(sourceURL)

        XCTAssertEqual(optimized.fileURL, sourceURL)
        XCTAssertEqual(
            optimized.uploadByteCount,
            optimized.originalByteCount
        )
    }

    @MainActor
    func testPrepareCreatesASmallerM4AUpload() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-optimizer-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        try makeTone(at: sourceURL, duration: 6)
        let optimized = await AudioUploadOptimizer.prepare(sourceURL)

        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            if optimized.fileURL != sourceURL {
                try? FileManager.default.removeItem(at: optimized.fileURL)
            }
        }

        XCTAssertEqual(optimized.fileURL.pathExtension, "m4a")
        XCTAssertGreaterThan(optimized.originalByteCount, 0)
        XCTAssertGreaterThan(optimized.uploadByteCount, 0)
        XCTAssertLessThan(
            optimized.uploadByteCount,
            optimized.originalByteCount / 4
        )
    }

    private func makeTone(at url: URL, duration: TimeInterval) throws {
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        let angularStep = 2.0 * Double.pi * 440.0 / sampleRate
        for index in 0..<Int(frameCount) {
            samples[index] = Float(0.25 * sin(angularStep * Double(index)))
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
    }
}
