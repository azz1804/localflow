import AVFoundation
import Foundation
import LocalFlowCore

struct DoubleClapSignalFeatures: Equatable {
    var peak: Float
    var rootMeanSquare: Float
    var crestFactor: Float
    var highFrequencyRatio: Float

    static func measure(
        samples: UnsafePointer<Float>,
        stride: Int,
        frameCount: Int
    ) -> DoubleClapSignalFeatures {
        let safeStride = max(1, stride)
        guard frameCount > 1 else {
            return DoubleClapSignalFeatures(
                peak: 0,
                rootMeanSquare: 0,
                crestFactor: 0,
                highFrequencyRatio: 0
            )
        }

        var peak: Float = 0
        var energy: Float = 0
        var differenceEnergy: Float = 0
        var previous = samples[0]

        for frame in 0..<frameCount {
            let sample = samples[frame * safeStride]
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            energy += sample * sample
            if frame > 0 {
                let difference = sample - previous
                differenceEnergy += difference * difference
            }
            previous = sample
        }

        let rootMeanSquare = sqrt(energy / Float(frameCount))
        let differenceRootMeanSquare = sqrt(
            differenceEnergy / Float(frameCount - 1)
        )
        let safeRootMeanSquare = max(rootMeanSquare, 0.000_001)

        return DoubleClapSignalFeatures(
            peak: peak,
            rootMeanSquare: rootMeanSquare,
            crestFactor: peak / safeRootMeanSquare,
            highFrequencyRatio: differenceRootMeanSquare
                / safeRootMeanSquare
        )
    }
}

struct DoubleClapDetector {
    static let minimumClapGap: TimeInterval = 0.14
    static let maximumClapGap: TimeInterval = 0.72
    static let triggerRefractoryPeriod: TimeInterval = 1.25

    private var streamTime: TimeInterval = 0
    private var noiseFloor: Float = 0.004
    private var firstClapTime: TimeInterval?
    private var lastTriggerTime = -TimeInterval.greatestFiniteMagnitude
    private var transientIsActive = false

    mutating func process(
        samples: UnsafePointer<Float>,
        stride: Int,
        frameCount: Int,
        sampleRate: Double
    ) -> Bool {
        guard frameCount > 1, sampleRate > 0 else {
            return false
        }
        let features = DoubleClapSignalFeatures.measure(
            samples: samples,
            stride: stride,
            frameCount: frameCount
        )
        return process(
            features: features,
            duration: Double(frameCount) / sampleRate
        )
    }

    mutating func process(
        features: DoubleClapSignalFeatures,
        duration: TimeInterval
    ) -> Bool {
        let timestamp = streamTime
        streamTime += max(0, duration)

        if let firstClapTime,
           timestamp - firstClapTime > Self.maximumClapGap {
            self.firstClapTime = nil
        }

        // Built-in Mac microphones apply distance-dependent gain and can
        // deliver a real hand clap far below the synthetic 0.1 peak used in
        // tests. The pair timing remains the strongest false-positive guard,
        // so keep the spectral checks while accepting quieter impacts.
        let peakThreshold = max(0.024, noiseFloor * 4.0)
        let rootMeanSquareThreshold = max(0.0025, noiseFloor * 1.3)
        let isCandidate = features.peak >= peakThreshold
            && features.rootMeanSquare >= rootMeanSquareThreshold
            && features.crestFactor >= 1.9
            && features.highFrequencyRatio >= 0.1

        // A real second clap is separated by a short valley. Requiring the
        // signal to fall almost to digital silence kept the detector latched
        // in ordinary room noise and merged both claps into one long impact.
        if features.peak < peakThreshold * 0.9 {
            transientIsActive = false
        }

        // Only quiet, non-transient buffers teach the adaptive floor. A clap
        // must not raise its own threshold and hide the second clap.
        if !isCandidate, features.peak < peakThreshold * 0.75 {
            let observedNoise = min(0.04, features.rootMeanSquare)
            noiseFloor = max(
                0.000_5,
                noiseFloor * 0.985 + observedNoise * 0.015
            )
        }

        guard isCandidate, !transientIsActive else {
            return false
        }
        transientIsActive = true

        guard timestamp - lastTriggerTime
                >= Self.triggerRefractoryPeriod else {
            return false
        }

        guard let firstClapTime else {
            self.firstClapTime = timestamp
            return false
        }

        let gap = timestamp - firstClapTime
        if gap < Self.minimumClapGap {
            return false
        }
        guard gap <= Self.maximumClapGap else {
            self.firstClapTime = timestamp
            return false
        }

        self.firstClapTime = nil
        lastTriggerTime = timestamp
        return true
    }
}

struct DoubleClapDiagnosticSnapshot: Equatable {
    var features: DoubleClapSignalFeatures
}

final class RealtimeDoubleClapAnalyzer: @unchecked Sendable {
    private let detected = LockFreeAtomicInt32(0)
    private let diagnosticReady = LockFreeAtomicInt32(0)
    private let peakBits = LockFreeAtomicInt32(0)
    private let rootMeanSquareBits = LockFreeAtomicInt32(0)
    private let crestFactorBits = LockFreeAtomicInt32(0)
    private let highFrequencyRatioBits = LockFreeAtomicInt32(0)
    private var detector = DoubleClapDetector()

    func consume(
        samples: UnsafePointer<Float>,
        stride: Int,
        frameCount: Int,
        sampleRate: Double
    ) {
        let features = DoubleClapSignalFeatures.measure(
            samples: samples,
            stride: stride,
            frameCount: frameCount
        )
        if features.peak >= 0.025,
           features.crestFactor >= 1.6,
           features.highFrequencyRatio >= 0.12 {
            peakBits.store(Self.atomicBits(for: features.peak))
            rootMeanSquareBits.store(
                Self.atomicBits(for: features.rootMeanSquare)
            )
            crestFactorBits.store(
                Self.atomicBits(for: features.crestFactor)
            )
            highFrequencyRatioBits.store(
                Self.atomicBits(for: features.highFrequencyRatio)
            )
            diagnosticReady.store(1)
        }

        if detector.process(
            features: features,
            duration: Double(frameCount) / sampleRate
        ) {
            detected.store(1)
        }
    }

    func consumeDetection() -> Bool {
        detected.exchange(0) == 1
    }

    func consumeDiagnosticSnapshot() -> DoubleClapDiagnosticSnapshot? {
        guard diagnosticReady.exchange(0) == 1 else {
            return nil
        }
        return DoubleClapDiagnosticSnapshot(
            features: DoubleClapSignalFeatures(
                peak: Self.float(fromAtomicBits: peakBits.load()),
                rootMeanSquare: Self.float(
                    fromAtomicBits: rootMeanSquareBits.load()
                ),
                crestFactor: Self.float(
                    fromAtomicBits: crestFactorBits.load()
                ),
                highFrequencyRatio: Self.float(
                    fromAtomicBits: highFrequencyRatioBits.load()
                )
            )
        )
    }

    private static func atomicBits(for value: Float) -> Int32 {
        Int32(bitPattern: value.bitPattern)
    }

    private static func float(fromAtomicBits value: Int32) -> Float {
        Float(bitPattern: UInt32(bitPattern: value))
    }
}

enum DoubleClapMonitoringPolicy {
    static func shouldListenWhileIdle(for status: AppStatus) -> Bool {
        switch status {
        case .idle, .done, .error:
            return true
        case .recording, .processing:
            return false
        }
    }
}

enum DoubleClapRecordingStopPolicy {
    static let startupProtectionDuration: TimeInterval = 0.85

    static func shouldStop(
        detectionReceived: Bool,
        recordingDuration: TimeInterval
    ) -> Bool {
        detectionReceived
            && recordingDuration >= startupProtectionDuration
    }
}

@MainActor
final class MicrophoneClapMonitor {
    var onDoubleClap: (() -> Void)?

    private var engine: AVAudioEngine?
    private var drainNode: AVAudioSinkNode?
    private var analyzer: RealtimeDoubleClapAnalyzer?
    private var pollTimer: Timer?
    private var lastDiagnosticLogTime: TimeInterval = 0

    var isRunning: Bool {
        engine?.isRunning == true
    }

    func start() throws {
        stop()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.couldNotStart
        }

        let analyzer = RealtimeDoubleClapAnalyzer()
        let drainNode = Self.makeDrainNode(
            analyzer: analyzer,
            sampleRate: format.sampleRate,
            isInterleaved: format.isInterleaved
        )
        engine.attach(drainNode)
        engine.connect(input, to: drainNode, format: nil)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            engine.disconnectNodeInput(drainNode)
            engine.detach(drainNode)
            engine.reset()
            throw error
        }

        self.engine = engine
        self.drainNode = drainNode
        self.analyzer = analyzer
        pollTimer = Timer.scheduledTimer(
            timeInterval: 0.04,
            target: self,
            selector: #selector(pollForDetection(_:)),
            userInfo: nil,
            repeats: true
        )
        LocalFlowLogger.log("Double-clap idle monitor started")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        guard let engine else {
            analyzer = nil
            drainNode = nil
            return
        }
        if engine.isRunning {
            engine.stop()
        }
        if let drainNode {
            engine.disconnectNodeInput(drainNode)
            engine.detach(drainNode)
        }
        engine.reset()
        self.engine = nil
        analyzer = nil
        drainNode = nil
        LocalFlowLogger.log("Double-clap idle monitor stopped")
    }

    @objc nonisolated private func pollForDetection(_ timer: Timer) {
        let callbackTimer = AppKitCallbackValue(value: timer)
        AppKitMainThreadBridge.run {
            guard pollTimer === callbackTimer.value else {
                return
            }
            if let diagnostic = analyzer?.consumeDiagnosticSnapshot() {
                logDiagnosticIfNeeded(diagnostic)
            }
            guard analyzer?.consumeDetection() == true else {
                return
            }
            onDoubleClap?()
        }
    }

    private func logDiagnosticIfNeeded(
        _ snapshot: DoubleClapDiagnosticSnapshot
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnosticLogTime >= 0.2 else {
            return
        }
        lastDiagnosticLogTime = now
        let features = snapshot.features
        let peak = String(format: "%.3f", features.peak)
        let rootMeanSquare = String(
            format: "%.3f",
            features.rootMeanSquare
        )
        let crestFactor = String(format: "%.2f", features.crestFactor)
        let broadband = String(
            format: "%.2f",
            features.highFrequencyRatio
        )
        LocalFlowLogger.log(
            "Double-clap impact peak=\(peak) rms=\(rootMeanSquare) crest=\(crestFactor) broadband=\(broadband)"
        )
    }

    private nonisolated static func makeDrainNode(
        analyzer: RealtimeDoubleClapAnalyzer,
        sampleRate: Double,
        isInterleaved: Bool
    ) -> AVAudioSinkNode {
        AVAudioSinkNode { _, frameCount, inputData in
            let audioBuffer = inputData.pointee.mBuffers
            guard let rawData = audioBuffer.mData else {
                return noErr
            }

            let stride = isInterleaved
                ? max(1, Int(audioBuffer.mNumberChannels))
                : 1
            let availableSampleCount = Int(audioBuffer.mDataByteSize)
                / MemoryLayout<Float>.size
            let safeFrameCount = min(
                Int(frameCount),
                availableSampleCount / stride
            )
            guard safeFrameCount > 0 else {
                return noErr
            }

            analyzer.consume(
                samples: rawData.assumingMemoryBound(to: Float.self),
                stride: stride,
                frameCount: safeFrameCount,
                sampleRate: sampleRate
            )
            return noErr
        }
    }
}

@MainActor
final class DoubleClapController {
    var onDoubleClap: (() -> Void)?

    private let monitor = MicrophoneClapMonitor()
    private var enabled = false
    private var shouldListenWhileIdle = true
    private var startupTask: Task<Void, Never>?
    private var startupGeneration: UInt64 = 0

    init() {
        monitor.onDoubleClap = { [weak self] in
            self?.handleDoubleClap()
        }
    }

    func update(configuration: AppConfiguration) {
        enabled = configuration.enableDoubleClapControl
        reconcileMonitoring()
    }

    func update(status: AppStatus) {
        shouldListenWhileIdle = DoubleClapMonitoringPolicy
            .shouldListenWhileIdle(for: status)
        reconcileMonitoring()
    }

    func stop() {
        startupGeneration &+= 1
        startupTask?.cancel()
        startupTask = nil
        monitor.stop()
    }

    private func reconcileMonitoring() {
        guard enabled, shouldListenWhileIdle else {
            stop()
            return
        }
        guard !monitor.isRunning, startupTask == nil else {
            return
        }

        startupGeneration &+= 1
        let generation = startupGeneration
        startupTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let granted = await PermissionManager.requestMicrophoneAccess()
            guard granted, !Task.isCancelled else {
                self.finishStartup(generation: generation)
                return
            }

            do {
                _ = try await AudioInputRouteManager.preparePreferredInput(
                    preferBuiltInForBluetooth: true
                )
                try Task.checkCancellation()
                guard self.enabled,
                      self.shouldListenWhileIdle,
                      self.startupGeneration == generation else {
                    self.finishStartup(generation: generation)
                    return
                }
                try self.monitor.start()
            } catch is CancellationError {
                // A recording or settings change intentionally cancels startup.
            } catch {
                LocalFlowLogger.log(
                    "Double-clap monitor start failed error=\(error.localizedDescription)"
                )
            }
            self.finishStartup(generation: generation)
        }
    }

    private func finishStartup(generation: UInt64) {
        guard startupGeneration == generation else {
            return
        }
        startupTask = nil
    }

    private func handleDoubleClap() {
        guard enabled, shouldListenWhileIdle else {
            return
        }
        // Release CoreAudio before the normal recorder creates its graph.
        monitor.stop()
        LocalFlowLogger.log("Double-clap control requested recording start")
        onDoubleClap?()
    }
}
