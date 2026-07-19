import AppKit
import Foundation

@MainActor
final class FloatingBarController {
    private let panel: NSPanel
    private let contentView: FloatingBarView
    private var hideTask: Task<Void, Never>?
    private var wasRecording = false

    init() {
        contentView = FloatingBarView(frame: NSRect(x: 0, y: 0, width: 420, height: 86))
        panel = NSPanel(
            contentRect: contentView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
    }

    func update(status: AppStatus, level: Float = 0) {
        hideTask?.cancel()
        contentView.status = status

        if case .recording = status {
            if !wasRecording {
                contentView.resetWaveform()
            }
            contentView.pushWaveformSample(
                level,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            wasRecording = true
        } else {
            wasRecording = false
        }

        guard status.shouldShowFloatingBar else {
            hidePanel(animated: true)
            return
        }

        positionPanel()
        showPanel()

        switch status {
        case .done, .error:
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self?.hidePanel(animated: true)
                }
            }
        default:
            break
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else {
            return
        }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 54
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func showPanel() {
        guard !panel.isVisible else {
            panel.orderFrontRegardless()
            return
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel(animated: Bool) {
        guard panel.isVisible else {
            return
        }

        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                panel?.alphaValue = 1
            }
        }
    }
}

final class FloatingBarView: NSView {
    private static let waveformSampleCount = 30

    var status: AppStatus = .idle {
        didSet { needsDisplay = true }
    }

    private var waveformSamples = Array(repeating: Float(0), count: waveformSampleCount)
    private var smoothedLevel: Float = 0

    override var isFlipped: Bool {
        true
    }

    func resetWaveform() {
        waveformSamples = Array(repeating: 0, count: Self.waveformSampleCount)
        smoothedLevel = 0
        needsDisplay = true
    }

    func pushWaveformSample(_ level: Float, reduceMotion: Bool) {
        let clampedLevel = max(0, min(1, level))
        smoothedLevel = smoothedLevel * 0.38 + clampedLevel * 0.62

        if reduceMotion {
            waveformSamples = Array(repeating: smoothedLevel, count: Self.waveformSampleCount)
        } else {
            waveformSamples.removeFirst()
            waveformSamples.append(smoothedLevel)
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        drawCard(in: bounds)

        drawStatusIcon(in: bounds)
        drawText(in: bounds)
        drawWaveform(in: bounds)
    }

    private func drawCard(in bounds: NSRect) {
        let cardRect = bounds.insetBy(dx: 3, dy: 3)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 21, yRadius: 21)
        let accent = statusColor

        NSGraphicsContext.saveGraphicsState()
        card.addClip()

        NSGradient(
            colors: [
                NSColor(calibratedRed: 0.095, green: 0.09, blue: 0.135, alpha: 0.98),
                NSColor(calibratedRed: 0.04, green: 0.052, blue: 0.09, alpha: 0.98)
            ]
        )?.draw(in: cardRect, angle: -12)

        NSGradient(
            starting: accent.withAlphaComponent(0.24),
            ending: accent.withAlphaComponent(0)
        )?.draw(
            in: NSRect(x: cardRect.maxX - 190, y: cardRect.minY - 60, width: 240, height: 210),
            relativeCenterPosition: NSPoint(x: 0.2, y: 0)
        )

        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        card.lineWidth = 1
        card.stroke()

        let inner = NSBezierPath(
            roundedRect: cardRect.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 19.5,
            yRadius: 19.5
        )
        NSColor.white.withAlphaComponent(0.035).setStroke()
        inner.lineWidth = 1
        inner.stroke()
    }

    private var statusColor: NSColor {
        let color: NSColor
        switch status {
        case .idle:
            color = .systemGray
        case .recording(_, .hold):
            color = .systemBlue
        case .recording(_, .toggle):
            color = .systemPurple
        case .processing:
            color = .systemBlue
        case .done:
            color = .systemGreen
        case .error:
            color = .systemOrange
        }
        return color
    }

    private func drawStatusIcon(in bounds: NSRect) {
        let color = statusColor
        let iconRect = NSRect(x: 20, y: 20, width: 46, height: 46)

        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 14, yRadius: 14).fill()

        color.withAlphaComponent(0.34).setStroke()
        let outline = NSBezierPath(roundedRect: iconRect, xRadius: 14, yRadius: 14)
        outline.lineWidth = 1
        outline.stroke()

        color.setFill()
        let heights: [CGFloat] = [10, 20, 14, 24, 12]
        for (index, height) in heights.enumerated() {
            let rect = NSRect(
                x: iconRect.midX - 13 + CGFloat(index) * 6,
                y: iconRect.midY - height / 2,
                width: 3,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawText(in bounds: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white
        ]

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.57)
        ]

        status.title.draw(
            in: NSRect(x: 80, y: 19, width: 172, height: 20),
            withAttributes: titleAttributes
        )

        if let detail = status.detail {
            let clipped = detail.count > 54 ? String(detail.prefix(54)) + "…" : detail
            clipped.draw(
                in: NSRect(x: 80, y: 44, width: 302, height: 17),
                withAttributes: detailAttributes
            )
        } else {
            let subtitle: String
            switch status {
            case .recording(_, .hold):
                subtitle = "Release to transcribe · Space locks"
            case .recording(_, .toggle):
                subtitle = "Escape to finish"
            case .processing:
                subtitle = "Transcribing securely with OpenAI"
            default:
                subtitle = ""
            }

            subtitle.draw(
                in: NSRect(x: 80, y: 44, width: 172, height: 17),
                withAttributes: detailAttributes
            )
        }

        if case let .recording(duration, _) = status {
            let timer = String(format: "%.1fs", duration)
            let timerAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.64)
            ]
            let timerRect = NSRect(x: 198, y: 17, width: 48, height: 22)
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: timerRect, xRadius: 8, yRadius: 8).fill()
            timer.draw(
                in: NSRect(x: timerRect.minX + 8, y: timerRect.minY + 4, width: 34, height: 14),
                withAttributes: timerAttributes
            )
        }
    }

    private func drawWaveform(in bounds: NSRect) {
        guard case let .recording(_, mode) = status else {
            return
        }

        let waveformRect = NSRect(x: 270, y: 17, width: 126, height: 50)
        let centerY = waveformRect.midY
        let color: NSColor = mode == .toggle ? .systemPurple : .systemBlue

        let centerLine = NSBezierPath()
        centerLine.move(to: NSPoint(x: waveformRect.minX, y: centerY))
        centerLine.line(to: NSPoint(x: waveformRect.maxX, y: centerY))
        color.withAlphaComponent(0.18).setStroke()
        centerLine.lineWidth = 1
        centerLine.stroke()

        let pointSpacing = waveformRect.width / CGFloat(max(1, waveformSamples.count - 1))
        let amplitudes = waveformSamples.enumerated().map { index, sample in
            let edgeDistance = min(index, waveformSamples.count - 1 - index)
            let edgeFade = min(1, CGFloat(edgeDistance) / 4)
            return (2 + CGFloat(sample) * 20) * edgeFade
        }

        let path = NSBezierPath()
        let firstUpperPoint = NSPoint(x: waveformRect.minX, y: centerY - amplitudes[0])
        path.move(to: firstUpperPoint)

        for index in 1..<amplitudes.count {
            let previousX = waveformRect.minX + CGFloat(index - 1) * pointSpacing
            let currentX = waveformRect.minX + CGFloat(index) * pointSpacing
            let midpointX = (previousX + currentX) / 2
            let previousY = centerY - amplitudes[index - 1]
            let currentY = centerY - amplitudes[index]
            path.curve(
                to: NSPoint(x: currentX, y: currentY),
                controlPoint1: NSPoint(x: midpointX, y: previousY),
                controlPoint2: NSPoint(x: midpointX, y: currentY)
            )
        }

        for index in amplitudes.indices.reversed() {
            let currentX = waveformRect.minX + CGFloat(index) * pointSpacing
            let currentY = centerY + amplitudes[index]

            if index == amplitudes.count - 1 {
                path.line(to: NSPoint(x: currentX, y: currentY))
                continue
            }

            let previousX = waveformRect.minX + CGFloat(index + 1) * pointSpacing
            let midpointX = (previousX + currentX) / 2
            let previousY = centerY + amplitudes[index + 1]
            path.curve(
                to: NSPoint(x: currentX, y: currentY),
                controlPoint1: NSPoint(x: midpointX, y: previousY),
                controlPoint2: NSPoint(x: midpointX, y: currentY)
            )
        }

        path.close()
        let gradient = NSGradient(
            starting: color.withAlphaComponent(0.95),
            ending: color.withAlphaComponent(0.22)
        )
        gradient?.draw(in: path, angle: 0)

        color.withAlphaComponent(0.86).setStroke()
        path.lineWidth = 1.2
        path.stroke()
    }
}
