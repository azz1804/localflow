import AppKit
import Foundation

@MainActor
final class FloatingBarController {
    private let panel: NSPanel
    private let contentView: FloatingBarView
    private var hideTask: Task<Void, Never>?

    init() {
        contentView = FloatingBarView(frame: NSRect(x: 0, y: 0, width: 360, height: 74))
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
    }

    func update(status: AppStatus, level: Float = 0) {
        hideTask?.cancel()
        contentView.status = status
        contentView.level = level

        guard status.shouldShowFloatingBar else {
            panel.orderOut(nil)
            return
        }

        positionPanel()
        panel.orderFrontRegardless()

        switch status {
        case .done, .error:
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self?.panel.orderOut(nil)
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
        let y = visible.minY + 70
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

final class FloatingBarView: NSView {
    var status: AppStatus = .idle {
        didSet { needsDisplay = true }
    }

    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        background.fill()

        drawStatusDot(in: bounds)
        drawText(in: bounds)
        drawWaveform(in: bounds)
    }

    private func drawStatusDot(in bounds: NSRect) {
        let color: NSColor
        switch status {
        case .idle:
            color = .systemGray
        case .recording:
            color = .systemRed
        case .processing:
            color = .systemBlue
        case .done:
            color = .systemGreen
        case .error:
            color = .systemOrange
        }

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 21, width: 16, height: 16)).fill()
    }

    private func drawText(in bounds: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.8, alpha: 1)
        ]

        status.title.draw(
            in: NSRect(x: 44, y: 14, width: bounds.width - 70, height: 20),
            withAttributes: titleAttributes
        )

        if let detail = status.detail {
            let clipped = detail.count > 70 ? String(detail.prefix(70)) + "..." : detail
            clipped.draw(
                in: NSRect(x: 44, y: 37, width: bounds.width - 70, height: 18),
                withAttributes: detailAttributes
            )
        } else {
            let subtitle: String
            switch status {
            case .recording:
                subtitle = "Release the hotkey to paste"
            case .processing:
                subtitle = "Transcribing with OpenAI"
            default:
                subtitle = ""
            }

            subtitle.draw(
                in: NSRect(x: 44, y: 37, width: bounds.width - 70, height: 18),
                withAttributes: detailAttributes
            )
        }
    }

    private func drawWaveform(in bounds: NSRect) {
        guard case .recording = status else {
            return
        }

        let barCount = 12
        let startX = bounds.width - 114
        let centerY: CGFloat = 32
        let normalized = CGFloat(max(0.08, min(1, level)))

        NSColor.systemRed.withAlphaComponent(0.85).setFill()

        for index in 0..<barCount {
            let phase = CGFloat(index % 4) / 4
            let height = 6 + 28 * normalized * (0.35 + phase)
            let rect = NSRect(
                x: startX + CGFloat(index) * 7,
                y: centerY - height / 2,
                width: 4,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
