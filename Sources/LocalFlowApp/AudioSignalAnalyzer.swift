import Accelerate
import AVFoundation
import Foundation

struct AudioWaveformSample: Equatable, Sendable {
    static let zero = AudioWaveformSample(
        rootMeanSquare: 0,
        positivePeak: 0,
        negativePeak: 0,
        linearRootMeanSquare: 0
    )

    var rootMeanSquare: Float
    var positivePeak: Float
    var negativePeak: Float
    var linearRootMeanSquare: Float = 0
}

struct AudioVisualizationFrame: Equatable, Sendable {
    static let envelopeSegmentCount = 14
    static let silent = AudioVisualizationFrame(
        sequence: 0,
        sample: .zero,
        liveEnvelope: Array(repeating: 0, count: envelopeSegmentCount),
        voiceLevel: 0
    )

    var sequence: UInt64
    var sample: AudioWaveformSample
    var liveEnvelope: [Float]
    var voiceLevel: Float

    init(
        sequence: UInt64,
        sample: AudioWaveformSample,
        liveEnvelope: [Float] = Array(
            repeating: 0,
            count: envelopeSegmentCount
        ),
        voiceLevel: Float = 0
    ) {
        self.sequence = sequence
        self.sample = sample
        self.liveEnvelope = liveEnvelope
        self.voiceLevel = voiceLevel
    }
}

enum AudioSignalMeter {
    static func measure(
        samples: UnsafeBufferPointer<Float>,
        stride: Int = 1,
        frameCount: Int? = nil
    ) -> AudioWaveformSample {
        let safeStride = max(1, stride)
        let measuredFrameCount = min(
            frameCount ?? samples.count / safeStride,
            samples.count / safeStride
        )
        guard let baseAddress = samples.baseAddress,
              measuredFrameCount > 0 else {
            return .zero
        }

        var rootMeanSquare: Float = 0
        var positivePeak: Float = 0
        var negativePeak: Float = 0

        vDSP_rmsqv(
            baseAddress,
            vDSP_Stride(safeStride),
            &rootMeanSquare,
            vDSP_Length(measuredFrameCount)
        )
        vDSP_maxv(
            baseAddress,
            vDSP_Stride(safeStride),
            &positivePeak,
            vDSP_Length(measuredFrameCount)
        )
        vDSP_minv(
            baseAddress,
            vDSP_Stride(safeStride),
            &negativePeak,
            vDSP_Length(measuredFrameCount)
        )

        return AudioWaveformSample(
            rootMeanSquare: normalizedGain(rootMeanSquare),
            positivePeak: normalizedGain(max(0, positivePeak)),
            negativePeak: normalizedGain(abs(min(0, negativePeak))),
            linearRootMeanSquare: rootMeanSquare
        )
    }

    static func normalizedGain(_ linearAmplitude: Float) -> Float {
        let noiseFloor: Float = -60
        let decibels = 20 * log10(max(linearAmplitude, 0.000_001))
        let normalized = max(0, min(1, (decibels - noiseFloor) / -noiseFloor))
        return pow(normalized, 0.68)
    }

    static func liveEnvelope(
        samples: UnsafeBufferPointer<Float>,
        stride: Int = 1,
        frameCount: Int? = nil,
        segmentCount: Int = AudioVisualizationFrame.envelopeSegmentCount
    ) -> [Float] {
        let safeStride = max(1, stride)
        let measuredFrameCount = min(
            frameCount ?? samples.count / safeStride,
            samples.count / safeStride
        )
        guard measuredFrameCount > 0, segmentCount > 0 else {
            return Array(repeating: 0, count: max(0, segmentCount))
        }

        var envelope = Array(repeating: Float(0), count: segmentCount)
        for segment in 0..<segmentCount {
            let start = segment * measuredFrameCount / segmentCount
            let end = max(
                start + 1,
                (segment + 1) * measuredFrameCount / segmentCount
            )
            var sumOfSquares: Float = 0
            var peak: Float = 0

            for frameIndex in start..<min(end, measuredFrameCount) {
                let magnitude = abs(samples[frameIndex * safeStride])
                sumOfSquares += magnitude * magnitude
                peak = max(peak, magnitude)
            }

            let count = Float(
                max(1, min(end, measuredFrameCount) - start)
            )
            let rootMeanSquare = sqrt(sumOfSquares / count)
            envelope[segment] = rootMeanSquare * 0.62 + peak * 0.38
        }

        guard let maximum = envelope.max(), maximum > 0.000_001 else {
            return Array(repeating: 0, count: segmentCount)
        }
        return envelope.map {
            pow(max(0, min(1, $0 / maximum)), 0.72)
        }
    }

    static func voiceFocusedEnvelope(_ envelope: [Float]) -> [Float] {
        guard envelope.count > 1 else {
            return envelope.map { max(0, min(1, $0)) }
        }

        var focused = envelope.map { max(0, min(1, $0)) }
        for _ in 0..<2 {
            let source = focused
            for index in focused.indices {
                let previous = source[max(source.startIndex, index - 1)]
                let current = source[index]
                let next = source[min(source.index(before: source.endIndex), index + 1)]
                focused[index] = previous * 0.2
                    + current * 0.6
                    + next * 0.2
            }
        }

        guard let maximum = focused.max(), maximum > 0.000_001 else {
            return Array(repeating: 0, count: envelope.count)
        }
        return focused.map {
            let normalized = max(0, min(1, $0 / maximum))
            return normalized < 0.035 ? 0 : normalized
        }
    }
}

struct AdaptiveVoiceLevelTracker {
    private static let calibrationFrameCount = 24

    private var calibrationMeasurements: [Float] = []
    private var calibrationFrames = 0
    private var noiseFloorDecibels: Float = -55

    mutating func process(linearRootMeanSquare: Float) -> Float {
        let decibels = max(
            -75,
            20 * log10(max(linearRootMeanSquare, 0.000_001))
        )
        updateNoiseFloor(with: decibels)

        let visualFloor = calibrationFrames < Self.calibrationFrameCount
            ? -42
            : noiseFloorDecibels
        let gate = max(-50, visualFloor + 6)
        let normalized = max(0, min(1, (decibels - gate) / 20))
        return pow(normalized, 0.55)
    }

    mutating func reset() {
        calibrationMeasurements.removeAll(keepingCapacity: true)
        calibrationFrames = 0
        noiseFloorDecibels = -55
    }

    private mutating func updateNoiseFloor(with decibels: Float) {
        if calibrationFrames < Self.calibrationFrameCount {
            calibrationMeasurements.append(decibels)
            calibrationFrames += 1

            if calibrationFrames == Self.calibrationFrameCount {
                let sorted = calibrationMeasurements.sorted()
                let percentileIndex = min(
                    sorted.count - 1,
                    sorted.count / 5
                )
                noiseFloorDecibels = min(-26, sorted[percentileIndex])
                calibrationMeasurements.removeAll(keepingCapacity: false)
            }
            return
        }

        let rate: Float
        if decibels < noiseFloorDecibels {
            rate = 0.18
        } else if decibels <= noiseFloorDecibels + 5 {
            rate = 0.025
        } else {
            rate = 0.0005
        }
        noiseFloorDecibels += (decibels - noiseFloorDecibels) * rate
    }
}

struct VoiceBandFilter {
    private var previousInput1: Float = 0
    private var previousHighPass1: Float = 0
    private var previousInput2: Float = 0
    private var previousHighPass2: Float = 0
    private var previousLowPass1: Float = 0
    private var previousLowPass2: Float = 0

    mutating func process(
        samples: UnsafeBufferPointer<Float>,
        stride: Int = 1,
        frameCount: Int? = nil,
        sampleRate: Double,
        lowCutoff: Double = 100,
        highCutoff: Double = 3_800
    ) -> [Float] {
        let safeStride = max(1, stride)
        let measuredFrameCount = min(
            frameCount ?? samples.count / safeStride,
            samples.count / safeStride
        )
        guard measuredFrameCount > 0, sampleRate > 0 else {
            return []
        }

        let sampleDuration = 1 / sampleRate
        let highPassRC = 1 / (2 * Double.pi * lowCutoff)
        let highPassAlpha = Float(
            highPassRC / (highPassRC + sampleDuration)
        )
        let lowPassRC = 1 / (2 * Double.pi * highCutoff)
        let lowPassAlpha = Float(
            sampleDuration / (lowPassRC + sampleDuration)
        )

        var output = Array(repeating: Float(0), count: measuredFrameCount)
        for frameIndex in 0..<measuredFrameCount {
            let input = samples[frameIndex * safeStride]
            let highPass1 = highPassAlpha
                * (previousHighPass1 + input - previousInput1)
            previousInput1 = input
            previousHighPass1 = highPass1

            let highPass2 = highPassAlpha
                * (previousHighPass2 + highPass1 - previousInput2)
            previousInput2 = highPass1
            previousHighPass2 = highPass2

            previousLowPass1 += lowPassAlpha
                * (highPass2 - previousLowPass1)
            previousLowPass2 += lowPassAlpha
                * (previousLowPass1 - previousLowPass2)
            output[frameIndex] = previousLowPass2
        }
        return output
    }

    mutating func reset() {
        self = VoiceBandFilter()
    }
}

struct VoiceSpectrumAnalyzer {
    private struct BinKernel {
        var bandIndex: Int
        var cosine: [Float]
        var sine: [Float]
    }

    private var cachedFrameCount = 0
    private var cachedSampleRate: Double = 0
    private var cachedSegmentCount = 0
    private var window: [Float] = []
    private var windowedSamples: [Float] = []
    private var kernels: [BinKernel] = []
    private var binCounts: [Int] = []

    mutating func analyze(
        samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        segmentCount: Int = AudioVisualizationFrame.envelopeSegmentCount,
        lowFrequency: Double = 100,
        highFrequency: Double = 3_800
    ) -> [Float] {
        guard !samples.isEmpty,
              sampleRate > 0,
              segmentCount > 0,
              highFrequency > lowFrequency else {
            return Array(repeating: 0, count: max(0, segmentCount))
        }

        rebuildCacheIfNeeded(
            frameCount: samples.count,
            sampleRate: sampleRate,
            segmentCount: segmentCount,
            lowFrequency: lowFrequency,
            highFrequency: highFrequency
        )
        guard !kernels.isEmpty else {
            return Array(repeating: 0, count: segmentCount)
        }

        for index in samples.indices {
            windowedSamples[index] = samples[index] * window[index]
        }

        var bandPower = Array(repeating: Float(0), count: segmentCount)
        windowedSamples.withUnsafeBufferPointer { sampleBuffer in
            guard let sampleBaseAddress = sampleBuffer.baseAddress else {
                return
            }
            let vectorLength = vDSP_Length(sampleBuffer.count)

            for kernel in kernels {
                var real: Float = 0
                var imaginary: Float = 0
                kernel.cosine.withUnsafeBufferPointer { cosineBuffer in
                    guard let cosineBaseAddress = cosineBuffer.baseAddress else {
                        return
                    }
                    vDSP_dotpr(
                        sampleBaseAddress,
                        1,
                        cosineBaseAddress,
                        1,
                        &real,
                        vectorLength
                    )
                }
                kernel.sine.withUnsafeBufferPointer { sineBuffer in
                    guard let sineBaseAddress = sineBuffer.baseAddress else {
                        return
                    }
                    vDSP_dotpr(
                        sampleBaseAddress,
                        1,
                        sineBaseAddress,
                        1,
                        &imaginary,
                        vectorLength
                    )
                }
                bandPower[kernel.bandIndex] += real * real
                    + imaginary * imaginary
            }
        }

        var amplitudes = bandPower.indices.map { index -> Float in
            let count = Float(max(1, binCounts[index]))
            return sqrt(bandPower[index] / count)
        }
        guard let maximum = amplitudes.max(), maximum > 0.000_001 else {
            return Array(repeating: 0, count: segmentCount)
        }

        for index in amplitudes.indices {
            let ratio = max(0.000_001, amplitudes[index] / maximum)
            let decibels = 20 * log10(ratio)
            let normalized = max(0, min(1, (decibels + 42) / 42))
            let compressed = pow(normalized, 0.72)
            amplitudes[index] = compressed < 0.1 ? 0 : compressed
        }
        return amplitudes
    }

    mutating func reset() {
        self = VoiceSpectrumAnalyzer()
    }

    private mutating func rebuildCacheIfNeeded(
        frameCount: Int,
        sampleRate: Double,
        segmentCount: Int,
        lowFrequency: Double,
        highFrequency: Double
    ) {
        guard frameCount != cachedFrameCount
                || sampleRate != cachedSampleRate
                || segmentCount != cachedSegmentCount else {
            return
        }

        cachedFrameCount = frameCount
        cachedSampleRate = sampleRate
        cachedSegmentCount = segmentCount
        let denominator = Double(max(1, frameCount - 1))
        window = (0..<frameCount).map { index in
            Float(
                0.5
                    - 0.5
                    * cos(2 * Double.pi * Double(index) / denominator)
            )
        }
        windowedSamples = Array(repeating: 0, count: frameCount)
        kernels = []
        binCounts = Array(repeating: 0, count: segmentCount)

        let minimumBin = max(
            1,
            Int(ceil(lowFrequency * Double(frameCount) / sampleRate))
        )
        let nyquistBin = max(1, frameCount / 2 - 1)
        let maximumBin = min(
            nyquistBin,
            Int(floor(highFrequency * Double(frameCount) / sampleRate))
        )
        guard minimumBin <= maximumBin else {
            return
        }

        for bin in minimumBin...maximumBin {
            let frequency = Double(bin) * sampleRate / Double(frameCount)
            let position = (frequency - lowFrequency)
                / (highFrequency - lowFrequency)
            let bandIndex = min(
                segmentCount - 1,
                max(0, Int(position * Double(segmentCount)))
            )
            let phaseStep = 2 * Double.pi * Double(bin)
                / Double(frameCount)
            let cosine = (0..<frameCount).map { index in
                Float(cos(phaseStep * Double(index)))
            }
            let sine = (0..<frameCount).map { index in
                Float(sin(phaseStep * Double(index)))
            }
            kernels.append(
                BinKernel(
                    bandIndex: bandIndex,
                    cosine: cosine,
                    sine: sine
                )
            )
            binCounts[bandIndex] += 1
        }
    }
}

struct VoiceVisualizationStabilizer {
    private var envelope = Array(
        repeating: Float(0),
        count: AudioVisualizationFrame.envelopeSegmentCount
    )
    private var voiceLevel: Float = 0
    private var consecutiveVoiceFrames = 0
    private var consecutiveQuietFrames = 0
    private var voiceIsActive = false

    mutating func process(
        envelope rawEnvelope: [Float],
        voiceLevel rawVoiceLevel: Float
    ) -> (envelope: [Float], voiceLevel: Float) {
        let measuredLevel = max(0, min(1, rawVoiceLevel))
        updateActivityGate(with: measuredLevel)
        let levelTarget = voiceIsActive ? measuredLevel : 0
        let levelResponse: Float = levelTarget >= voiceLevel ? 0.55 : 0.34
        voiceLevel += (levelTarget - voiceLevel) * levelResponse
        if voiceLevel < 0.012 {
            voiceLevel = 0
        }

        let validEnvelope = envelope.indices.map { index in
            index < rawEnvelope.count
                ? max(0, min(1, rawEnvelope[index]))
                : 0
        }
        let mean = validEnvelope.reduce(0, +)
            / Float(max(1, validEnvelope.count))

        for index in envelope.indices {
            let coherentContour = validEnvelope[index] * 0.82
                + mean * 0.18
            let target = levelTarget > 0.025 ? coherentContour : 0
            let response: Float = target >= envelope[index] ? 0.38 : 0.26
            envelope[index] += (target - envelope[index]) * response
            if envelope[index] < 0.012 {
                envelope[index] = 0
            }
        }

        return (envelope, voiceLevel)
    }

    private mutating func updateActivityGate(with level: Float) {
        if voiceIsActive {
            if level < 0.055 {
                consecutiveQuietFrames += 1
                if consecutiveQuietFrames >= 3 {
                    voiceIsActive = false
                    consecutiveVoiceFrames = 0
                }
            } else {
                consecutiveQuietFrames = 0
            }
            return
        }

        guard level >= 0.11 else {
            consecutiveVoiceFrames = 0
            return
        }
        consecutiveVoiceFrames += 1
        if consecutiveVoiceFrames >= 2 {
            voiceIsActive = true
            consecutiveQuietFrames = 0
        }
    }

    mutating func reset() {
        self = VoiceVisualizationStabilizer()
    }
}

final class SignalAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var pendingSample = AudioWaveformSample.zero
    private var pendingLiveEnvelope = Array(
        repeating: Float(0),
        count: AudioVisualizationFrame.envelopeSegmentCount
    )
    private var pendingVoiceLevel: Float = 0
    private var voiceLevelTracker = AdaptiveVoiceLevelTracker()
    private var voiceBandFilter = VoiceBandFilter()
    private var voiceSpectrumAnalyzer = VoiceSpectrumAnalyzer()
    private var visualizationStabilizer = VoiceVisualizationStabilizer()
    private var lastFrameLength: AVAudioFrameCount = 0
    private var sampleRate: Double = 0
    private var measurementStartedAt: TimeInterval?
    private var measurementStartedSequence: UInt64 = 0
    private var didLogCaptureCadence = false

    func consume(
        samples: UnsafeBufferPointer<Float>,
        stride: Int,
        frameCount: Int,
        sampleRate: Double
    ) {
        guard frameCount > 0, sampleRate > 0 else {
            return
        }

        let voiceBandSamples = voiceBandFilter.process(
            samples: samples,
            stride: stride,
            frameCount: frameCount,
            sampleRate: sampleRate
        )
        let (sample, liveEnvelope) = voiceBandSamples
            .withUnsafeBufferPointer { voiceSamples in
                let sample = AudioSignalMeter.measure(samples: voiceSamples)
                let liveEnvelope = voiceSpectrumAnalyzer.analyze(
                    samples: voiceSamples,
                    sampleRate: sampleRate
                )
                return (sample, liveEnvelope)
            }
        let rawVoiceLevel = voiceLevelTracker.process(
            linearRootMeanSquare: sample.linearRootMeanSquare
        )
        let stabilized = visualizationStabilizer.process(
            envelope: liveEnvelope,
            voiceLevel: rawVoiceLevel
        )

        lock.lock()
        sequence &+= 1
        pendingSample = AudioWaveformSample(
            rootMeanSquare: max(
                pendingSample.rootMeanSquare,
                sample.rootMeanSquare
            ),
            positivePeak: max(
                pendingSample.positivePeak,
                sample.positivePeak
            ),
            negativePeak: max(
                pendingSample.negativePeak,
                sample.negativePeak
            )
        )
        // Keep the contour and gain from the same hardware buffer. Pairing a
        // previous peak with the latest (often quiet/noisy) contour makes the
        // visualizer look like it crackles even when the voice is steady.
        if stabilized.voiceLevel >= pendingVoiceLevel {
            pendingLiveEnvelope = stabilized.envelope
            pendingVoiceLevel = stabilized.voiceLevel
        }
        lastFrameLength = AVAudioFrameCount(frameCount)
        self.sampleRate = sampleRate
        lock.unlock()
    }

    func snapshot() -> AudioVisualizationFrame {
        lock.lock()
        let frame = AudioVisualizationFrame(
            sequence: sequence,
            sample: pendingSample,
            liveEnvelope: pendingLiveEnvelope,
            voiceLevel: pendingVoiceLevel
        )
        let measuredSequence = sequence
        let measuredFrameLength = lastFrameLength
        let measuredSampleRate = sampleRate
        pendingSample = .zero
        pendingLiveEnvelope = Array(
            repeating: 0,
            count: AudioVisualizationFrame.envelopeSegmentCount
        )
        pendingVoiceLevel = 0
        lock.unlock()

        measureCaptureCadence(
            sequence: measuredSequence,
            frameLength: measuredFrameLength,
            sampleRate: measuredSampleRate
        )
        return frame
    }

    func reset() {
        lock.lock()
        sequence = 0
        pendingSample = .zero
        pendingLiveEnvelope = Array(
            repeating: 0,
            count: AudioVisualizationFrame.envelopeSegmentCount
        )
        pendingVoiceLevel = 0
        voiceLevelTracker.reset()
        voiceBandFilter.reset()
        voiceSpectrumAnalyzer.reset()
        visualizationStabilizer.reset()
        lastFrameLength = 0
        sampleRate = 0
        measurementStartedAt = nil
        measurementStartedSequence = 0
        didLogCaptureCadence = false
        lock.unlock()
    }

    private func measureCaptureCadence(
        sequence: UInt64,
        frameLength: AVAudioFrameCount,
        sampleRate: Double
    ) {
        guard !didLogCaptureCadence else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if measurementStartedAt == nil {
            measurementStartedAt = now
            measurementStartedSequence = sequence
            return
        }

        guard let measurementStartedAt else {
            return
        }
        let elapsed = now - measurementStartedAt
        guard elapsed >= 1, sampleRate > 0 else {
            return
        }

        let callbackCount = sequence &- measurementStartedSequence
        let callbacksPerSecond = Double(callbackCount) / elapsed
        let bufferMilliseconds = Double(frameLength) / sampleRate * 1_000
        LocalFlowLogger.log(
            "Audio capture measuredCallbacksPerSecond=\(String(format: "%.1f", callbacksPerSecond)) frameLength=\(frameLength) sampleRate=\(String(format: "%.0f", sampleRate)) bufferDurationMs=\(String(format: "%.1f", bufferMilliseconds))"
        )
        didLogCaptureCadence = true
    }
}

private final class AudioCaptureSink: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let lock = NSLock()
    private var storedWriteError: Error?

    init(audioFile: AVAudioFile) {
        self.audioFile = audioFile
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        do {
            try audioFile.write(from: buffer)
        } catch {
            lock.lock()
            if storedWriteError == nil {
                storedWriteError = error
            }
            lock.unlock()
        }

    }

    func writeError() -> Error? {
        lock.lock()
        let error = storedWriteError
        lock.unlock()
        return error
    }
}

@MainActor
final class MicrophoneAudioCapture {
    private let engine = AVAudioEngine()
    private let accumulator = SignalAccumulator()
    private var sink: AudioCaptureSink?
    private var monitoringSinkNode: AVAudioSinkNode?
    private var tapIsInstalled = false
    private var isRunning = false

    func start(recordingURL: URL) throws {
        try? stop()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.couldNotStart
        }

        let audioFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sink = AudioCaptureSink(audioFile: audioFile)
        self.sink = sink

        let monitoringSinkNode = makeMonitoringSinkNode(format: format)
        engine.attach(monitoringSinkNode)
        engine.connect(input, to: monitoringSinkNode, format: format)
        self.monitoringSinkNode = monitoringSinkNode

        input.installTap(
            onBus: 0,
            bufferSize: 512,
            format: format,
            block: Self.makeTapBlock(for: sink)
        )
        tapIsInstalled = true

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            tapIsInstalled = false
            engine.detach(monitoringSinkNode)
            self.monitoringSinkNode = nil
            self.sink = nil
            throw error
        }
    }

    func stop() throws {
        if isRunning {
            engine.stop()
            isRunning = false
        }
        if tapIsInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
        if let monitoringSinkNode {
            engine.detach(monitoringSinkNode)
            self.monitoringSinkNode = nil
        }

        let writeError = sink?.writeError()
        sink = nil
        accumulator.reset()
        if let writeError {
            throw writeError
        }
    }

    func currentFrame() -> AudioVisualizationFrame {
        accumulator.snapshot()
    }

    private nonisolated static func makeTapBlock(
        for sink: AudioCaptureSink
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            sink.consume(buffer)
        }
    }

    private nonisolated func makeMonitoringSinkNode(
        format: AVAudioFormat
    ) -> AVAudioSinkNode {
        let accumulator = accumulator
        let sampleRate = format.sampleRate
        let isInterleaved = format.isInterleaved

        return AVAudioSinkNode {
            _, frameCount, inputData -> OSStatus in
            let audioBuffer = inputData.pointee.mBuffers
            guard let rawData = audioBuffer.mData else {
                return noErr
            }

            let channelStride = isInterleaved
                ? max(1, Int(audioBuffer.mNumberChannels))
                : 1
            let availableSampleCount = Int(audioBuffer.mDataByteSize)
                / MemoryLayout<Float>.size
            let requestedSampleCount = Int(frameCount) * channelStride
            let sampleCount = min(
                availableSampleCount,
                requestedSampleCount
            )
            let availableFrameCount = sampleCount / channelStride
            guard availableFrameCount > 0 else {
                return noErr
            }

            let samples = UnsafeBufferPointer(
                start: rawData.assumingMemoryBound(to: Float.self),
                count: sampleCount
            )
            accumulator.consume(
                samples: samples,
                stride: channelStride,
                frameCount: availableFrameCount,
                sampleRate: sampleRate
            )
            return noErr
        }
    }
}
