import Accelerate
import AudioToolbox
import AVFoundation
import Darwin
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
        var output: [Float] = []
        process(
            samples: samples,
            stride: stride,
            frameCount: frameCount,
            sampleRate: sampleRate,
            lowCutoff: lowCutoff,
            highCutoff: highCutoff,
            output: &output
        )
        return output
    }

    mutating func process(
        samples: UnsafeBufferPointer<Float>,
        stride: Int = 1,
        frameCount: Int? = nil,
        sampleRate: Double,
        lowCutoff: Double = 100,
        highCutoff: Double = 3_800,
        output: inout [Float]
    ) {
        let safeStride = max(1, stride)
        let measuredFrameCount = min(
            frameCount ?? samples.count / safeStride,
            samples.count / safeStride
        )
        guard measuredFrameCount > 0, sampleRate > 0 else {
            output.removeAll(keepingCapacity: true)
            return
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

        if output.count != measuredFrameCount {
            output = Array(repeating: 0, count: measuredFrameCount)
        }
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
    private var bandPower: [Float] = []
    private var amplitudes: [Float] = []

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

        for index in bandPower.indices {
            bandPower[index] = 0
        }
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

        for index in bandPower.indices {
            let count = Float(max(1, binCounts[index]))
            amplitudes[index] = sqrt(bandPower[index] / count)
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
        bandPower = Array(repeating: 0, count: segmentCount)
        amplitudes = Array(repeating: 0, count: segmentCount)

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
    private let processingLock = NSLock()
    private let outputLock = NSLock()
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
    private var filteredSamples: [Float] = []
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

        processingLock.lock()
        defer { processingLock.unlock() }

        voiceBandFilter.process(
            samples: samples,
            stride: stride,
            frameCount: frameCount,
            sampleRate: sampleRate,
            output: &filteredSamples
        )
        let (sample, liveEnvelope) = filteredSamples
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

        outputLock.lock()
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
        let measuredSequence = sequence
        outputLock.unlock()

        measureCaptureCadence(
            sequence: measuredSequence,
            frameLength: AVAudioFrameCount(frameCount),
            sampleRate: sampleRate
        )
    }

    func snapshot() -> AudioVisualizationFrame {
        outputLock.lock()
        let frame = AudioVisualizationFrame(
            sequence: sequence,
            sample: pendingSample,
            liveEnvelope: pendingLiveEnvelope,
            voiceLevel: pendingVoiceLevel
        )
        pendingSample = .zero
        for index in pendingLiveEnvelope.indices {
            pendingLiveEnvelope[index] = 0
        }
        pendingVoiceLevel = 0
        outputLock.unlock()
        return frame
    }

    func reset() {
        processingLock.lock()
        voiceLevelTracker.reset()
        voiceBandFilter.reset()
        voiceSpectrumAnalyzer.reset()
        visualizationStabilizer.reset()
        filteredSamples.removeAll(keepingCapacity: true)

        outputLock.lock()
        sequence = 0
        pendingSample = .zero
        for index in pendingLiveEnvelope.indices {
            pendingLiveEnvelope[index] = 0
        }
        pendingVoiceLevel = 0
        measurementStartedAt = nil
        measurementStartedSequence = 0
        didLogCaptureCadence = false
        outputLock.unlock()
        processingLock.unlock()
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

private final class LockFreeAtomicInt32: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int32>

    init(_ value: Int32) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: value)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func load() -> Int32 {
        OSAtomicAdd32Barrier(0, storage)
    }

    func store(_ value: Int32) {
        _ = exchange(value)
    }

    func exchange(_ value: Int32) -> Int32 {
        while true {
            let oldValue = load()
            if OSAtomicCompareAndSwap32Barrier(oldValue, value, storage) {
                return oldValue
            }
        }
    }

    func compareExchange(expected: Int32, desired: Int32) -> Bool {
        OSAtomicCompareAndSwap32Barrier(expected, desired, storage)
    }
}

private enum RealtimeSlotState {
    static let free: Int32 = 0
    static let writing: Int32 = 1
    static let ready: Int32 = 2
    static let reading: Int32 = 3
}

private final class AnalysisSampleSlot: @unchecked Sendable {
    let state = LockFreeAtomicInt32(RealtimeSlotState.free)
    let samples: UnsafeMutableBufferPointer<Float>
    var frameCount = 0
    var sampleRate: Double = 0
    var sequence: UInt64 = 0

    init(capacity: Int) {
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0)
    }

    deinit {
        samples.deinitialize()
        samples.deallocate()
    }
}

/// Single-producer/single-consumer storage between CoreAudio and the DSP
/// queue. The callback only copies into preallocated memory and performs atomic
/// state transitions: no locks, allocation, DFT, disk I/O, or UI work.
final class RealtimeAnalysisBuffer: @unchecked Sendable {
    private let slots: [AnalysisSampleSlot]
    private var writeCursor = 0
    private var nextSequence: UInt64 = 0

    init(slotCount: Int = 6, frameCapacity: Int = 4_096) {
        slots = (0..<slotCount).map { _ in
            AnalysisSampleSlot(capacity: frameCapacity)
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let source = buffer.floatChannelData?[0] else {
            return
        }

        let frameCount = min(Int(buffer.frameLength), slots[0].samples.count)
        guard frameCount > 0 else {
            return
        }
        let stride = buffer.format.isInterleaved
            ? max(1, Int(buffer.format.channelCount))
            : 1

        for offset in slots.indices {
            let index = (writeCursor + offset) % slots.count
            let slot = slots[index]
            let claimed = slot.state.compareExchange(
                expected: RealtimeSlotState.free,
                desired: RealtimeSlotState.writing
            )
            guard claimed else {
                continue
            }

            for frame in 0..<frameCount {
                slot.samples[frame] = source[frame * stride]
            }
            nextSequence &+= 1
            slot.frameCount = frameCount
            slot.sampleRate = buffer.format.sampleRate
            slot.sequence = nextSequence
            slot.state.store(RealtimeSlotState.ready)
            writeCursor = (index + 1) % slots.count
            return
        }
        // Dropping a visualization buffer is preferable to blocking audio.
    }

    func consumeLatest(
        _ body: (UnsafeBufferPointer<Float>, Int, Double) -> Void
    ) {
        var newestIndex: Int?
        var newestSequence: UInt64 = 0

        for index in slots.indices {
            let slot = slots[index]
            guard slot.state.load()
                    == RealtimeSlotState.ready else {
                continue
            }
            if newestIndex == nil || slot.sequence > newestSequence {
                newestIndex = index
                newestSequence = slot.sequence
            }
        }

        for index in slots.indices where index != newestIndex {
            releaseReadySlot(at: index)
        }

        guard let newestIndex else {
            return
        }
        let slot = slots[newestIndex]
        let claimed = slot.state.compareExchange(
            expected: RealtimeSlotState.ready,
            desired: RealtimeSlotState.reading
        )
        guard claimed else {
            return
        }

        body(
            UnsafeBufferPointer(
                start: slot.samples.baseAddress,
                count: slot.frameCount
            ),
            slot.frameCount,
            slot.sampleRate
        )
        slot.state.store(RealtimeSlotState.free)
    }

    func discardPending() {
        for index in slots.indices {
            releaseReadySlot(at: index)
        }
    }

    private func releaseReadySlot(at index: Int) {
        let slot = slots[index]
        let claimed = slot.state.compareExchange(
            expected: RealtimeSlotState.ready,
            desired: RealtimeSlotState.reading
        )
        if claimed {
            slot.state.store(RealtimeSlotState.free)
        }
    }
}

private final class AudioAnalysisWorker: @unchecked Sendable {
    private let accumulator: SignalAccumulator
    private let realtimeBuffer = RealtimeAnalysisBuffer()
    private let queue = DispatchQueue(
        label: "com.localflow.audio-analysis",
        qos: .userInteractive
    )
    private let timer: DispatchSourceTimer
    private let running = LockFreeAtomicInt32(0)

    init(accumulator: SignalAccumulator) {
        self.accumulator = accumulator
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(16),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.analyzeLatestBuffer()
        }
    }

    func start() {
        guard running.compareExchange(expected: 0, desired: 1) else {
            return
        }
        timer.resume()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard running.load() == 1 else {
            return
        }
        realtimeBuffer.enqueue(buffer)
    }

    func stop() {
        guard running.exchange(0) == 1 else {
            return
        }
        timer.cancel()
        queue.sync {
            realtimeBuffer.discardPending()
            accumulator.reset()
        }
    }

    private func analyzeLatestBuffer() {
        realtimeBuffer.consumeLatest { [accumulator] samples, count, sampleRate in
            accumulator.consume(
                samples: samples,
                stride: 1,
                frameCount: count,
                sampleRate: sampleRate
            )
        }
    }
}

/// The proven capture path: AVAudioFile accepts the exact buffer delivered by
/// the input tap, including hardware-sized slices larger than the requested tap
/// size. DSP remains off the realtime callback in AudioAnalysisWorker.
final class AudioCaptureSink: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let lock = NSLock()
    private var storedWriteError: Error?
    private var writtenFrameCount: AVAudioFramePosition = 0

    init(recordingURL: URL, format: AVAudioFormat) throws {
        audioFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else {
            return
        }

        do {
            try audioFile.write(from: buffer)
            lock.lock()
            writtenFrameCount += AVAudioFramePosition(buffer.frameLength)
            lock.unlock()
        } catch {
            lock.lock()
            if storedWriteError == nil {
                storedWriteError = error
            }
            lock.unlock()
        }
    }

    func finish() throws {
        lock.lock()
        let error = storedWriteError
        let frames = writtenFrameCount
        lock.unlock()

        if let error {
            throw error
        }
        guard frames > 0 else {
            throw AudioRecorderError.recordingUnavailable
        }
    }
}

@MainActor
final class MicrophoneAudioCapture {
    private let engine = AVAudioEngine()
    private let accumulator = SignalAccumulator()
    private var captureSink: AudioCaptureSink?
    private var analysisWorker: AudioAnalysisWorker?
    private var tapIsInstalled = false
    private var isRunning = false

    func start(recordingURL: URL) throws {
        try? stop()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0,
              format.sampleRate > 0,
              format.commonFormat == .pcmFormatFloat32 else {
            throw AudioRecorderError.couldNotStart
        }

        let captureSink = try AudioCaptureSink(
            recordingURL: recordingURL,
            format: format
        )
        let analysisWorker = AudioAnalysisWorker(accumulator: accumulator)
        analysisWorker.start()
        self.captureSink = captureSink
        self.analysisWorker = analysisWorker

        input.installTap(
            onBus: 0,
            bufferSize: 512,
            format: format,
            block: Self.makeTapBlock(
                captureSink: captureSink,
                analysisWorker: analysisWorker
            )
        )
        tapIsInstalled = true

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            tapIsInstalled = false
            analysisWorker.stop()
            try? captureSink.finish()
            self.analysisWorker = nil
            self.captureSink = nil
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
        analysisWorker?.stop()
        analysisWorker = nil

        let captureSink = captureSink
        self.captureSink = nil
        try captureSink?.finish()
    }

    func currentFrame() -> AudioVisualizationFrame {
        accumulator.snapshot()
    }

    private nonisolated static func makeTapBlock(
        captureSink: AudioCaptureSink,
        analysisWorker: AudioAnalysisWorker
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            captureSink.consume(buffer)
            analysisWorker.enqueue(buffer)
        }
    }
}
