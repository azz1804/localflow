import AppKit
import Foundation
import QuartzCore

@MainActor
final class RecordingFrameDriver: NSObject {
    private let callback: () -> Void
    private var displayLinkDriver: AnyObject?
    private var fallbackTimer: Timer?

    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }

    func start() {
        stop()

        if #available(macOS 14.0, *) {
            let driver = ScreenDisplayLinkDriver(callback: callback)
            if driver.start() {
                displayLinkDriver = driver
                return
            }
        }

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(fallbackTimerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        LocalFlowLogger.log("Recording frame driver using 60 Hz timer fallback")
    }

    @objc nonisolated
    private func fallbackTimerDidFire(_ timer: Timer) {
        AppKitMainThreadBridge.run {
            callback()
        }
    }

    func stop() {
        if #available(macOS 14.0, *),
           let driver = displayLinkDriver as? ScreenDisplayLinkDriver {
            driver.stop()
        }
        displayLinkDriver = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }
}

@available(macOS 14.0, *)
@MainActor
private final class ScreenDisplayLinkDriver: NSObject {
    private let callback: () -> Void
    private var displayLink: CADisplayLink?
    private var measurementStartedAt: CFTimeInterval?
    private var measuredFrameCount = 0
    private var didLogMeasuredRate = false

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func start() -> Bool {
        guard let displayLink = NSScreen.main?.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        ) else {
            return false
        }

        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 60,
            preferred: 60
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        return true
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc nonisolated
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        let callbackValue = AppKitCallbackValue(value: displayLink)
        AppKitMainThreadBridge.run {
            measureCadence(timestamp: callbackValue.value.timestamp)
            callback()
        }
    }

    private func measureCadence(timestamp: CFTimeInterval) {
        guard !didLogMeasuredRate else {
            return
        }

        if measurementStartedAt == nil {
            measurementStartedAt = timestamp
        }
        measuredFrameCount += 1

        guard let measurementStartedAt else {
            return
        }
        let elapsed = timestamp - measurementStartedAt
        guard elapsed >= 1 else {
            return
        }

        let framesPerSecond = Double(measuredFrameCount - 1) / elapsed
        LocalFlowLogger.log(
            "Recording display link measuredFPS=\(String(format: "%.1f", framesPerSecond))"
        )
        didLogMeasuredRate = true
    }
}
