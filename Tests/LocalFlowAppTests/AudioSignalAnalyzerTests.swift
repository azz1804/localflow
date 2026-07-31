import AVFoundation
import Foundation
import XCTest
@testable import LocalFlowApp

final class AudioSignalAnalyzerTests: XCTestCase {
    func testCaptureSinkWritesHardwareSizedBuffersWithoutTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-capture-sink-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let frameCount: AVAudioFrameCount = 8_192
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!
        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            buffer.floatChannelData![0][index] = Float(
                sin(Double(index) * 0.04) * 0.2
            )
        }

        do {
            let sink = AudioCaptureSink(recordingURL: url)
            sink.consume(buffer)
            try sink.finish()
        }

        let recording = try AVAudioFile(forReading: url)
        XCTAssertEqual(recording.length, AVAudioFramePosition(frameCount))
        XCTAssertTrue(AudioRecordingValidator.hasReadableFrames(at: url))
        XCTAssertTrue(AudioRecordingValidator.hasUsableSignal(at: url))
    }

    func testCaptureSinkAndValidatorRejectHeaderOnlyWAV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-empty-capture-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let sink = AudioCaptureSink(recordingURL: url)
            XCTAssertThrowsError(try sink.finish())
        }

        XCTAssertFalse(AudioRecordingValidator.hasReadableFrames(at: url))
    }

    func testValidatorRejectsDigitalSilenceWithReadableFrames() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-silent-capture-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_096
        )!
        buffer.frameLength = buffer.frameCapacity

        do {
            let sink = AudioCaptureSink(recordingURL: url)
            sink.consume(buffer)
            try sink.finish()
        }

        XCTAssertTrue(AudioRecordingValidator.hasReadableFrames(at: url))
        XCTAssertEqual(
            AudioRecordingValidator.validate(at: url),
            .digitalSilence
        )
        XCTAssertFalse(AudioRecordingValidator.hasUsableSignal(at: url))
    }

    func testCaptureSinkAdoptsFirstRealBufferFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-lazy-format-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 512
        )!
        buffer.frameLength = 512
        for index in 0..<512 {
            buffer.floatChannelData![0][index] = Float(
                sin(Double(index) * 0.08) * 0.15
            )
        }

        do {
            let sink = AudioCaptureSink(recordingURL: url)
            sink.consume(buffer)
            try sink.finish()
        }

        let recording = try AVAudioFile(forReading: url)
        XCTAssertEqual(recording.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(recording.fileFormat.channelCount, 1)
        XCTAssertTrue(AudioRecordingValidator.hasUsableSignal(at: url))
    }

    func testRealtimeBufferCopiesLatestPCMWithoutRetainingSourceBuffer() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 8
        )!
        buffer.frameLength = 8
        for index in 0..<8 {
            buffer.floatChannelData![0][index] = Float(index) / 8
        }
        let realtimeBuffer = RealtimeAnalysisBuffer(
            slotCount: 3,
            frameCapacity: 8
        )

        realtimeBuffer.enqueue(buffer)
        for index in 0..<8 {
            buffer.floatChannelData![0][index] = -1
        }

        var captured: [Float] = []
        realtimeBuffer.consumeLatest { samples, frameCount, sampleRate in
            captured = Array(samples)
            XCTAssertEqual(frameCount, 8)
            XCTAssertEqual(sampleRate, 48_000)
        }

        XCTAssertEqual(captured, (0..<8).map { Float($0) / 8 })
    }

    func testRealtimeBufferCopiesFirstChannelFromInterleavedRenderQuantum() {
        var interleaved: [Float] = [
            0.1, -0.9,
            0.2, -0.8,
            0.3, -0.7,
            0.4, -0.6
        ]
        let realtimeBuffer = RealtimeAnalysisBuffer(
            slotCount: 3,
            frameCapacity: 8
        )

        interleaved.withUnsafeBufferPointer { samples in
            realtimeBuffer.enqueue(
                samples: samples.baseAddress!,
                stride: 2,
                frameCount: 4,
                sampleRate: 48_000
            )
        }
        interleaved = Array(repeating: -1, count: interleaved.count)

        var captured: [Float] = []
        realtimeBuffer.consumeLatest { samples, frameCount, sampleRate in
            captured = Array(samples)
            XCTAssertEqual(frameCount, 4)
            XCTAssertEqual(sampleRate, 48_000)
        }

        XCTAssertEqual(captured, [0.1, 0.2, 0.3, 0.4])
    }

    func testRealtimeBufferDropsOlderRenderQuantaWithoutBacklog() {
        let realtimeBuffer = RealtimeAnalysisBuffer(
            slotCount: 4,
            frameCapacity: 8
        )

        for value in [Float(0.1), 0.2, 0.3] {
            let samples = Array(repeating: value, count: 4)
            samples.withUnsafeBufferPointer { buffer in
                realtimeBuffer.enqueue(
                    samples: buffer.baseAddress!,
                    stride: 1,
                    frameCount: buffer.count,
                    sampleRate: 44_100
                )
            }
        }

        var captured: [Float] = []
        realtimeBuffer.consumeLatest { samples, _, _ in
            captured = Array(samples)
        }

        XCTAssertEqual(captured, Array(repeating: 0.3, count: 4))
    }

    func testSilenceProducesZeroGain() {
        let samples = Array(repeating: Float(0), count: 512)

        let measurement = samples.withUnsafeBufferPointer {
            AudioSignalMeter.measure(samples: $0)
        }

        XCTAssertEqual(measurement, .zero)
    }

    func testMeterTracksLoudnessAndIndependentPositiveNegativePeaks() {
        let quietTone = makeTone(amplitude: 0.05)
        let loudTone = makeTone(amplitude: 0.8)
        let asymmetric: [Float] = [0.75, 0.2, 0, -0.1, -0.28]

        let quiet = quietTone.withUnsafeBufferPointer {
            AudioSignalMeter.measure(samples: $0)
        }
        let loud = loudTone.withUnsafeBufferPointer {
            AudioSignalMeter.measure(samples: $0)
        }
        let asymmetricMeasurement = asymmetric.withUnsafeBufferPointer {
            AudioSignalMeter.measure(samples: $0)
        }

        XCTAssertGreaterThan(loud.rootMeanSquare, quiet.rootMeanSquare)
        XCTAssertGreaterThan(loud.positivePeak, quiet.positivePeak)
        XCTAssertGreaterThan(
            asymmetricMeasurement.positivePeak,
            asymmetricMeasurement.negativePeak
        )
    }

    func testMeterReadsOneChannelFromInterleavedRealtimeAudio() {
        let loudFirstChannel: [Float] = [
            0.8, 0.01,
            -0.8, 0.01,
            0.8, 0.01,
            -0.8, 0.01
        ]
        let quietFirstChannel: [Float] = [
            0.01, 0.8,
            -0.01, -0.8,
            0.01, 0.8,
            -0.01, -0.8
        ]

        let loud = loudFirstChannel.withUnsafeBufferPointer {
            AudioSignalMeter.measure(
                samples: $0,
                stride: 2,
                frameCount: 4
            )
        }
        let quiet = quietFirstChannel.withUnsafeBufferPointer {
            AudioSignalMeter.measure(
                samples: $0,
                stride: 2,
                frameCount: 4
            )
        }

        XCTAssertGreaterThan(loud.rootMeanSquare, quiet.rootMeanSquare)
        XCTAssertGreaterThan(loud.positivePeak, quiet.positivePeak)
    }

    func testLiveEnvelopeUsesOnlyTheCurrentPCMBuffer() {
        let quiet = Array(repeating: Float(0.01), count: 256)
        let transient = Array(repeating: Float(0.8), count: 256)
        let samples = quiet + transient

        let envelope = samples.withUnsafeBufferPointer {
            AudioSignalMeter.liveEnvelope(samples: $0)
        }

        XCTAssertEqual(
            envelope.count,
            AudioVisualizationFrame.envelopeSegmentCount
        )
        XCTAssertLessThan(envelope[1], 0.1)
        XCTAssertGreaterThan(envelope[12], 0.9)
    }

    func testInstantVoiceLevelRejectsLearnedNoiseAndAttacksImmediately() {
        var tracker = AdaptiveVoiceLevelTracker()

        for _ in 0..<30 {
            _ = tracker.process(linearRootMeanSquare: 0.012)
        }
        let background = tracker.process(linearRootMeanSquare: 0.012)
        let normalVoice = tracker.process(linearRootMeanSquare: 0.04)
        let voice = tracker.process(linearRootMeanSquare: 0.24)
        let silence = tracker.process(linearRootMeanSquare: 0)

        XCTAssertLessThan(background, 0.03)
        XCTAssertGreaterThan(normalVoice, 0.4)
        XCTAssertGreaterThan(voice, 0.8)
        XCTAssertEqual(silence, 0)
    }

    func testVoiceFocusedEnvelopeRemovesNarrowCrackleWithoutFlatteningVoice() {
        let raw: [Float] = [
            0.02, 0.04, 0.08, 0.95, 0.1, 0.07, 0.05,
            0.04, 0.03, 0.02, 0.01, 0.01, 0, 0
        ]

        let focused = AudioSignalMeter.voiceFocusedEnvelope(raw)

        XCTAssertEqual(focused.count, raw.count)
        XCTAssertEqual(focused.max(), 1)
        XCTAssertGreaterThan(focused[2], raw[2])
        XCTAssertGreaterThan(focused[4], raw[4])
        XCTAssertLessThan(focused[3] - focused[2], raw[3] - raw[2])
    }

    func testAccumulatorKeepsEnvelopePairedWithStrongestVoiceBuffer() {
        let quiet = Array(repeating: Float(0.01), count: 512)
        let voiced = Array(repeating: Float(0), count: 256)
            + makeTone(
                amplitude: 0.55,
                frequency: 280,
                sampleCount: 256
            )
        let accumulator = SignalAccumulator()

        for _ in 0..<5 {
            voiced.withUnsafeBufferPointer {
                accumulator.consume(
                    samples: $0,
                    stride: 1,
                    frameCount: $0.count,
                    sampleRate: 44_100
                )
            }
        }
        quiet.withUnsafeBufferPointer {
            accumulator.consume(
                samples: $0,
                stride: 1,
                frameCount: $0.count,
                sampleRate: 44_100
            )
        }

        let frame = accumulator.snapshot()

        XCTAssertGreaterThan(frame.voiceLevel, 0.7)
        let maximum = frame.liveEnvelope.max() ?? 0
        let minimum = frame.liveEnvelope.min() ?? 0
        XCTAssertGreaterThan(maximum, 0.55)
        XCTAssertGreaterThan(
            maximum,
            minimum * 2.5
        )
    }

    func testVoiceSpectrumMovesPeakAcrossFrequencyBands() {
        var analyzer = VoiceSpectrumAnalyzer()
        let lowVoice = makeTone(
            amplitude: 0.7,
            frequency: 280,
            sampleCount: 512
        )
        let highVoice = makeTone(
            amplitude: 0.7,
            frequency: 2_500,
            sampleCount: 512
        )

        let lowSpectrum = lowVoice.withUnsafeBufferPointer {
            analyzer.analyze(samples: $0, sampleRate: 44_100)
        }
        analyzer.reset()
        let highSpectrum = highVoice.withUnsafeBufferPointer {
            analyzer.analyze(samples: $0, sampleRate: 44_100)
        }

        let lowPeak = lowSpectrum.indices.max {
            lowSpectrum[$0] < lowSpectrum[$1]
        }
        let highPeak = highSpectrum.indices.max {
            highSpectrum[$0] < highSpectrum[$1]
        }

        XCTAssertNotNil(lowPeak)
        XCTAssertNotNil(highPeak)
        XCTAssertLessThan(lowPeak ?? .max, 3)
        XCTAssertGreaterThan(highPeak ?? 0, 7)
        XCTAssertGreaterThan((highPeak ?? 0) - (lowPeak ?? 0), 6)
    }

    func testVoiceSpectrumProducesDistinctBandHeights() {
        var analyzer = VoiceSpectrumAnalyzer()
        let composite = zip(
            makeTone(
                amplitude: 0.7,
                frequency: 320,
                sampleCount: 512
            ),
            makeTone(
                amplitude: 0.35,
                frequency: 1_480,
                sampleCount: 512
            )
        ).map(+)

        let spectrum = composite.withUnsafeBufferPointer {
            analyzer.analyze(samples: $0, sampleRate: 44_100)
        }
        let sorted = spectrum.sorted(by: >)

        XCTAssertEqual(
            spectrum.count,
            AudioVisualizationFrame.envelopeSegmentCount
        )
        XCTAssertGreaterThan(sorted[0], sorted[5] * 1.7)
        XCTAssertGreaterThan(sorted[1], sorted[10] * 2)
    }

    func testVisualizationStabilizerKeepsContourContinuousAcrossBuffers() {
        var stabilizer = VoiceVisualizationStabilizer()
        let leftPeak: [Float] = [
            1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1,
            0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1
        ]
        let rightPeak = Array(leftPeak.reversed())

        let first = stabilizer.process(
            envelope: leftPeak,
            voiceLevel: 0.8
        )
        let second = stabilizer.process(
            envelope: rightPeak,
            voiceLevel: 0.8
        )

        let rawJump = abs(leftPeak[0] - rightPeak[0])
        let stabilizedJump = abs(
            first.envelope[0] - second.envelope[0]
        )
        XCTAssertLessThan(stabilizedJump, rawJump * 0.25)
        XCTAssertGreaterThan(second.voiceLevel, first.voiceLevel)
    }

    func testVisualizationStabilizerPreservesClearHeightVariation() {
        var stabilizer = VoiceVisualizationStabilizer()
        let contour: [Float] = [
            1, 0.12, 0.8, 0.16, 0.7, 0.14, 0.6,
            0.13, 0.5, 0.12, 0.4, 0.1, 0.3, 0.08
        ]
        var result = stabilizer.process(
            envelope: contour,
            voiceLevel: 0.8
        )
        for _ in 0..<5 {
            result = stabilizer.process(
                envelope: contour,
                voiceLevel: 0.8
            )
        }

        XCTAssertGreaterThan(
            result.envelope[0],
            result.envelope[1] * 3
        )
        XCTAssertGreaterThan(
            result.envelope[2],
            result.envelope[3] * 2.5
        )
    }

    func testVisualizationStabilizerRejectsSingleQuietTransient() {
        var stabilizer = VoiceVisualizationStabilizer()
        let transient = Array(
            repeating: Float(0.7),
            count: AudioVisualizationFrame.envelopeSegmentCount
        )

        let first = stabilizer.process(
            envelope: transient,
            voiceLevel: 0.18
        )
        let second = stabilizer.process(
            envelope: Array(repeating: 0, count: transient.count),
            voiceLevel: 0
        )

        XCTAssertEqual(first.voiceLevel, 0)
        XCTAssertEqual(second.voiceLevel, 0)
        XCTAssertEqual(first.envelope, Array(repeating: 0, count: 14))
    }

    func testVisualizationStabilizerOpensForSustainedVoice() {
        var stabilizer = VoiceVisualizationStabilizer()
        let voice = Array(
            repeating: Float(0.7),
            count: AudioVisualizationFrame.envelopeSegmentCount
        )

        _ = stabilizer.process(envelope: voice, voiceLevel: 0.4)
        let active = stabilizer.process(envelope: voice, voiceLevel: 0.4)

        XCTAssertGreaterThan(active.voiceLevel, 0.2)
        XCTAssertGreaterThan(active.envelope.max() ?? 0, 0.2)
    }

    func testVoiceBandFilterPrefersSpeechOverRumbleAndHiss() {
        let rumble = makeTone(
            amplitude: 0.5,
            frequency: 35,
            sampleCount: 4_096
        )
        let voice = makeTone(
            amplitude: 0.5,
            frequency: 280,
            sampleCount: 4_096
        )
        let hiss = makeTone(
            amplitude: 0.5,
            frequency: 10_000,
            sampleCount: 4_096
        )

        let rumbleLevel = filteredRMS(rumble)
        let voiceLevel = filteredRMS(voice)
        let hissLevel = filteredRMS(hiss)

        XCTAssertGreaterThan(voiceLevel, rumbleLevel * 2)
        XCTAssertGreaterThan(voiceLevel, hissLevel * 2)
    }

    private func makeTone(
        amplitude: Double,
        frequency: Double = 440,
        sampleCount: Int = 512
    ) -> [Float] {
        let sampleRate = 44_100.0
        return (0..<sampleCount).map { index in
            Float(
                sin(
                    2 * .pi * frequency * Double(index) / sampleRate
                ) * amplitude
            )
        }
    }

    private func filteredRMS(_ samples: [Float]) -> Float {
        var filter = VoiceBandFilter()
        let filtered = samples.withUnsafeBufferPointer {
            filter.process(samples: $0, sampleRate: 44_100)
        }
        let stableTail = Array(filtered.suffix(filtered.count / 2))
        return stableTail.withUnsafeBufferPointer {
            AudioSignalMeter.measure(samples: $0).linearRootMeanSquare
        }
    }
}
