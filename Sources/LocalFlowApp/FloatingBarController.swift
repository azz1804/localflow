import AppKit
import Foundation
import LocalFlowCore
import QuartzCore

/// A synchronous foreign callback can safely carry its arguments across the
/// bridge below because the value never escapes the callback's main-thread
/// stack frame. This wrapper makes that lifetime guarantee explicit to Swift's
/// strict concurrency checker for Objective-C reference types such as
/// `Notification`, `NSApplication`, and `Timer`.
struct AppKitCallbackValue<Value>: @unchecked Sendable {
    let value: Value
}

/// Bridges synchronous AppKit callbacks into the view's main-actor state.
///
/// AppKit invokes these callbacks from its Objective-C main-thread run loop,
/// which is not always registered as the Swift main-actor executor. Letting
/// Swift synthesize an actor-checked Objective-C thunk can therefore crash
/// before the callback body runs. AppKit guarantees these `NSView` callbacks
/// are delivered on the main thread, so verify that invariant and then erase
/// only the redundant executor check while keeping the implementation
/// statically main-actor isolated.
enum AppKitMainThreadBridge {
    @available(*, noasync)
    nonisolated static func run<Result>(
        _ operation: @MainActor () -> Result
    ) -> Result {
        precondition(
            Thread.isMainThread,
            "AppKit view callback was delivered off the main thread"
        )

        return withoutActuallyEscaping(operation) { isolatedOperation in
            let mainThreadOperation = unsafeBitCast(
                isolatedOperation,
                to: (() -> Result).self
            )
            return mainThreadOperation()
        }
    }
}

struct FloatingBarPalette: Equatable {
    var backgroundTop: OrbRGBA
    var backgroundBottom: OrbRGBA
    var ambientPrimary: OrbRGBA
    var ambientSecondary: OrbRGBA
    var spectrumEdge: OrbRGBA
    var spectrumCenter: OrbRGBA
    var border: OrbRGBA

    init(theme: OrbTheme) {
        backgroundTop = Self.mix(
            OrbRGBA(red: 0.064, green: 0.065, blue: 0.082),
            theme.primary,
            amount: 0.22
        )
        backgroundBottom = Self.mix(
            OrbRGBA(red: 0.025, green: 0.027, blue: 0.036),
            theme.baseDark,
            amount: 0.64
        )
        ambientPrimary = theme.primary
        ambientSecondary = theme.accent
        spectrumEdge = theme.secondary
        spectrumCenter = theme.highlight
        border = theme.rim
    }

    func spectrumColor(at normalizedDistance: CGFloat) -> OrbRGBA {
        Self.mix(
            spectrumCenter,
            spectrumEdge,
            amount: max(0, min(1, normalizedDistance))
        )
    }

    private static func mix(
        _ first: OrbRGBA,
        _ second: OrbRGBA,
        amount: CGFloat
    ) -> OrbRGBA {
        let fraction = max(0, min(1, amount))
        return OrbRGBA(
            red: first.red + (second.red - first.red) * fraction,
            green: first.green + (second.green - first.green) * fraction,
            blue: first.blue + (second.blue - first.blue) * fraction
        )
    }
}

enum FloatingBarSpectrumTransitionCurve: Equatable {
    case easeOut
    case easeIn
}

struct FloatingBarSpectrumTransition: Equatable {
    var targetOpacity: Float
    var duration: CFTimeInterval
    var curve: FloatingBarSpectrumTransitionCurve

    static func make(
        presented: Bool,
        reduceMotion: Bool
    ) -> FloatingBarSpectrumTransition {
        FloatingBarSpectrumTransition(
            targetOpacity: presented ? 1 : 0,
            duration: reduceMotion ? 0 : (presented ? 0.19 : 0.25),
            curve: presented ? .easeOut : .easeIn
        )
    }
}

struct FloatingBarSpectrumBarPresentation: Equatable {
    var amplitude: CGFloat
    var alpha: CGFloat

    static func make(value rawValue: CGFloat) -> Self {
        let value = max(0, min(1, rawValue))
        let gateStart: CGFloat = 0.004
        let gateEnd: CGFloat = 0.035
        let linearGate = max(
            0,
            min(1, (value - gateStart) / (gateEnd - gateStart))
        )
        let softGate = linearGate * linearGate * (3 - 2 * linearGate)

        return FloatingBarSpectrumBarPresentation(
            amplitude: (0.45 + pow(value, 0.82) * 12) * softGate,
            alpha: (0.1 + value * 0.72) * softGate
        )
    }
}

enum FloatingBarEnvelopeMotion {
    static func advanceEnvelope(current: Float, target: Float) -> Float {
        advance(
            current: current,
            target: target,
            attack: 0.68,
            release: 0.18
        )
    }

    static func advanceVoiceLevel(current: Float, target: Float) -> Float {
        advance(
            current: current,
            target: target,
            attack: 0.72,
            release: 0.22
        )
    }

    private static func advance(
        current: Float,
        target: Float,
        attack: Float,
        release: Float
    ) -> Float {
        let response = target >= current ? attack : release
        let updated = current + (target - current) * response
        return updated < 0.003 ? 0 : updated
    }
}

enum FloatingBarPresentationMode: Equatable {
    case horizontal
    case vertical
    case compact

    var panelSize: NSSize {
        switch self {
        case .horizontal:
            return NSSize(width: 390, height: 64)
        case .vertical:
            return NSSize(width: 72, height: 316)
        case .compact:
            return NSSize(width: 58, height: 58)
        }
    }
}

enum FloatingBarPlacement {
    static let edgeActivationDistance: CGFloat = 104
    static let edgeMargin: CGFloat = 12

    static func expandedMode(
        forCenter center: NSPoint,
        in visibleFrame: NSRect
    ) -> FloatingBarPresentationMode {
        let isNearLeft = center.x
            <= visibleFrame.minX + edgeActivationDistance
        let isNearRight = center.x
            >= visibleFrame.maxX - edgeActivationDistance
        return isNearLeft || isNearRight ? .vertical : .horizontal
    }

    static func clampedCenter(
        _ center: NSPoint,
        panelSize: NSSize,
        in visibleFrame: NSRect
    ) -> NSPoint {
        NSPoint(
            x: min(
                visibleFrame.maxX - panelSize.width / 2 - edgeMargin,
                max(
                    visibleFrame.minX + panelSize.width / 2 + edgeMargin,
                    center.x
                )
            ),
            y: min(
                visibleFrame.maxY - panelSize.height / 2 - edgeMargin,
                max(
                    visibleFrame.minY + panelSize.height / 2 + edgeMargin,
                    center.y
                )
            )
        )
    }
}

enum FloatingBarModeControlLayout {
    static let modes: [DictationOutputMode] = [
        .transcript,
        .polish,
        .prompt
    ]

    static func timerRect(
        in cardRect: NSRect,
        presentation: FloatingBarPresentationMode = .horizontal
    ) -> NSRect {
        if presentation == .vertical {
            return NSRect(
                x: cardRect.midX - 24.5,
                y: cardRect.maxY - 29,
                width: 49,
                height: 21
            )
        }
        return NSRect(
            x: cardRect.maxX - 49 - 9,
            y: cardRect.midY - 10.5,
            width: 49,
            height: 21
        )
    }

    static func modeGroupRect(
        in cardRect: NSRect,
        presentation: FloatingBarPresentationMode = .horizontal
    ) -> NSRect {
        let timerRect = timerRect(
            in: cardRect,
            presentation: presentation
        )
        if presentation == .vertical {
            return NSRect(
                x: cardRect.midX - 25,
                y: timerRect.minY - 76,
                width: 50,
                height: 69
            )
        }
        return NSRect(
            x: timerRect.minX - 123,
            y: timerRect.minY,
            width: 115,
            height: timerRect.height
        )
    }

    static func modeRects(
        in cardRect: NSRect,
        presentation: FloatingBarPresentationMode = .horizontal
    ) -> [(DictationOutputMode, NSRect)] {
        let group = modeGroupRect(
            in: cardRect,
            presentation: presentation
        )
        if presentation == .vertical {
            let height: CGFloat = 21
            return modes.enumerated().map { index, mode in
                (
                    mode,
                    NSRect(
                        x: group.minX,
                        y: group.minY + CGFloat(index) * 24,
                        width: group.width,
                        height: height
                    )
                )
            }
        }

        let width = group.width / CGFloat(modes.count)
        return modes.enumerated().map { index, mode in
            (
                mode,
                NSRect(
                    x: group.minX + CGFloat(index) * width,
                    y: group.minY,
                    width: width,
                    height: group.height
                )
            )
        }
    }

    static func spectrumRect(
        in cardRect: NSRect,
        presentation: FloatingBarPresentationMode
    ) -> NSRect {
        switch presentation {
        case .horizontal:
            let group = modeGroupRect(
                in: cardRect,
                presentation: presentation
            )
            return NSRect(
                x: cardRect.minX + 53,
                y: cardRect.midY - 13,
                width: max(80, group.minX - cardRect.minX - 61),
                height: 26
            )
        case .vertical:
            let group = modeGroupRect(
                in: cardRect,
                presentation: presentation
            )
            return NSRect(
                x: cardRect.midX - 13,
                y: cardRect.minY + 48,
                width: 26,
                height: max(80, group.minY - cardRect.minY - 58)
            )
        case .compact:
            return .zero
        }
    }

    static func orbCenter(
        in cardRect: NSRect,
        presentation: FloatingBarPresentationMode
    ) -> NSPoint {
        switch presentation {
        case .horizontal:
            return NSPoint(x: cardRect.minX + 22, y: cardRect.midY)
        case .vertical:
            return NSPoint(x: cardRect.midX, y: cardRect.minY + 23)
        case .compact:
            return NSPoint(x: cardRect.midX, y: cardRect.midY)
        }
    }
}

@MainActor
final class FloatingBarController {
    static let panelSize = FloatingBarPresentationMode.horizontal.panelSize

    var onOutputModeChange: ((DictationOutputMode) -> Void)?

    private let panel: NSPanel
    private let contentView: FloatingBarView
    private var hideTask: Task<Void, Never>?
    private var presentationMode: FloatingBarPresentationMode = .horizontal
    private var hasPositionedPanel = false
    private let defaults = UserDefaults.standard

    private enum DefaultsKey {
        static let centerX = "floatingBarCenterX"
        static let centerY = "floatingBarCenterY"
        static let isCompact = "floatingBarIsCompact"
    }

    init() {
        contentView = FloatingBarView(
            frame: NSRect(origin: .zero, size: Self.panelSize)
        )
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
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .utilityWindow
        contentView.onOutputModeChange = { [weak self] mode in
            self?.onOutputModeChange?(mode)
        }
        contentView.onBackgroundClick = { [weak self] in
            self?.toggleCompactPresentation()
        }
        contentView.onDragEnded = { [weak self] in
            self?.finishPanelDrag()
        }
    }

    func update(
        status: AppStatus,
        visualization: AudioVisualizationFrame = .silent
    ) {
        hideTask?.cancel()
        contentView.update(
            status: status,
            visualization: visualization,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        guard status.shouldShowFloatingBar else {
            hidePanel(animated: true)
            return
        }

        positionPanelIfNeeded()
        showPanel()

        switch status {
        case .done, .error:
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else {
                    return
                }
                self?.hidePanel(animated: true)
            }
        default:
            break
        }
    }

    func updateTotalWords(
        _ totalWords: Int,
        overrideID: String = "automatic"
    ) {
        contentView.updateOrbProgression(
            totalWords: totalWords,
            overrideID: overrideID
        )
    }

    func updateOutputMode(_ mode: DictationOutputMode) {
        contentView.updateOutputMode(mode)
    }

    private func positionPanelIfNeeded() {
        guard !hasPositionedPanel else {
            return
        }
        guard let screen = NSScreen.main else {
            return
        }

        let visible = screen.visibleFrame
        let storedCenter = storedPanelCenter()
        let center = storedCenter ?? NSPoint(
            x: visible.midX,
            y: visible.minY + 50 + Self.panelSize.height / 2
        )
        let expandedMode = FloatingBarPlacement.expandedMode(
            forCenter: center,
            in: visible
        )
        presentationMode = defaults.bool(
            forKey: DefaultsKey.isCompact
        ) ? .compact : expandedMode
        setPresentationMode(
            presentationMode,
            centeredAt: center,
            in: visible,
            animated: false
        )
        hasPositionedPanel = true
    }

    private func toggleCompactPresentation() {
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let nextMode: FloatingBarPresentationMode
        if presentationMode == .compact {
            nextMode = FloatingBarPlacement.expandedMode(
                forCenter: center,
                in: visible
            )
        } else {
            nextMode = .compact
        }
        setPresentationMode(
            nextMode,
            centeredAt: center,
            in: visible,
            animated: true
        )
        defaults.set(nextMode == .compact, forKey: DefaultsKey.isCompact)
        persistPanelCenter()
    }

    private func finishPanelDrag() {
        guard let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }
        var center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        if presentationMode != .compact {
            let nextMode = FloatingBarPlacement.expandedMode(
                forCenter: center,
                in: visible
            )
            if nextMode == .vertical {
                let isLeft = center.x < visible.midX
                center.x = isLeft
                    ? visible.minX
                        + nextMode.panelSize.width / 2
                        + FloatingBarPlacement.edgeMargin
                    : visible.maxX
                        - nextMode.panelSize.width / 2
                        - FloatingBarPlacement.edgeMargin
            }
            setPresentationMode(
                nextMode,
                centeredAt: center,
                in: visible,
                animated: true
            )
        } else {
            let clamped = FloatingBarPlacement.clampedCenter(
                center,
                panelSize: presentationMode.panelSize,
                in: visible
            )
            panel.setFrameOrigin(
                NSPoint(
                    x: clamped.x - panel.frame.width / 2,
                    y: clamped.y - panel.frame.height / 2
                )
            )
        }
        persistPanelCenter()
    }

    private func setPresentationMode(
        _ mode: FloatingBarPresentationMode,
        centeredAt requestedCenter: NSPoint,
        in visible: NSRect,
        animated: Bool
    ) {
        presentationMode = mode
        let size = mode.panelSize
        let center = FloatingBarPlacement.clampedCenter(
            requestedCenter,
            panelSize: size,
            in: visible
        )
        let frame = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        contentView.updatePresentationMode(mode)
        panel.setFrame(
            frame,
            display: true,
            animate: animated
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func storedPanelCenter() -> NSPoint? {
        guard defaults.object(forKey: DefaultsKey.centerX) != nil,
              defaults.object(forKey: DefaultsKey.centerY) != nil else {
            return nil
        }
        return NSPoint(
            x: defaults.double(forKey: DefaultsKey.centerX),
            y: defaults.double(forKey: DefaultsKey.centerY)
        )
    }

    private func persistPanelCenter() {
        defaults.set(panel.frame.midX, forKey: DefaultsKey.centerX)
        defaults.set(panel.frame.midY, forKey: DefaultsKey.centerY)
    }

    private func showPanel() {
        guard !panel.isVisible else {
            panel.orderFrontRegardless()
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel(animated: Bool) {
        guard panel.isVisible else {
            return
        }

        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
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
    private static let envelopeSegmentCount =
        AudioVisualizationFrame.envelopeSegmentCount
    private static let displayedSegmentCount = 11
    private static let spectrumBarCount = displayedSegmentCount * 2 - 1

    private var status: AppStatus = .idle
    private var outputMode = DictationOutputMode.transcript
    private var presentationMode = FloatingBarPresentationMode.horizontal
    var onOutputModeChange: ((DictationOutputMode) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var displayedEnvelope = Array(
        repeating: Float(0),
        count: envelopeSegmentCount
    )
    private var targetEnvelope = Array(
        repeating: Float(0),
        count: envelopeSegmentCount
    )
    private var displayedVoiceLevel: Float = 0
    private var targetVoiceLevel: Float = 0
    private var lastSequence: UInt64 = 0
    private var lastTimerSecond: Int?
    private var wasRecording = false
    private var reduceMotion = false
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var hoverLocation = NSPoint.zero
    private let spectrumContainerLayer = CALayer()
    private var spectrumBarLayers: [CALayer] = []
    private var spectrumHideWorkItem: DispatchWorkItem?
    private var spectrumTransitionGeneration: UInt64 = 0
    private var isSpectrumDismissing = false
    private let processingContainerLayer = CALayer()
    private var processingDotLayers: [CALayer] = []
    private let orbContainerLayer = CALayer()
    private let orbClipLayer = CALayer()
    private let orbMaskLayer = CAShapeLayer()
    private let orbGradientLayer = CAGradientLayer()
    private let orbBloomLayer = CAGradientLayer()
    private let orbMagentaLayer = CAGradientLayer()
    private let orbGoldLayer = CAGradientLayer()
    private let orbOilLayer = CAGradientLayer()
    private let orbPearlLayer = CAGradientLayer()
    private let orbCausticLayer = CAShapeLayer()
    private var orbMaterialLayers: [CAShapeLayer] = []
    private var orbGlitterLayers: [CALayer] = []
    private var orbStrandLayers: [CAShapeLayer] = []
    private let orbHighlightLayer = CAGradientLayer()
    private let orbRimLayer = CAShapeLayer()
    private var orbTheme = OrbEvolution.progression(forWords: 0).theme
    private var barPalette: FloatingBarPalette {
        FloatingBarPalette(theme: orbTheme)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    nonisolated override var isFlipped: Bool {
        true
    }

    private var cardRect: NSRect {
        presentationMode == .compact
            ? bounds.insetBy(dx: 5, dy: 5)
            : bounds.insetBy(dx: 6, dy: 5)
    }

    private var modeControlRects: [(DictationOutputMode, NSRect)] {
        FloatingBarModeControlLayout.modeRects(
            in: cardRect,
            presentation: presentationMode
        )
    }

    private var hoveredOutputMode: DictationOutputMode? {
        guard case .recording = status else {
            return nil
        }
        return modeControlRects.first {
            $0.1.contains(hoverLocation)
        }?.0
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.allowsEdgeAntialiasing = true
        configureSpectrumLayers()
        configureOrbLayers()
        configureProcessingLayers()
        updateAudioLayerGeometry()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("LocalFlow voice bar")
        updateOutputModeAccessibility()
    }

    private func configureSpectrumLayers() {
        spectrumContainerLayer.actions = [
            "hidden": NSNull(),
            "opacity": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        spectrumContainerLayer.opacity = 0
        spectrumContainerLayer.isHidden = true
        layer?.addSublayer(spectrumContainerLayer)

        spectrumBarLayers = (0..<Self.spectrumBarCount).map { _ in
            let barLayer = CALayer()
            barLayer.cornerRadius = 1.3
            barLayer.actions = [
                "backgroundColor": NSNull(),
                "bounds": NSNull(),
                "cornerRadius": NSNull(),
                "opacity": NSNull(),
                "position": NSNull(),
                "transform": NSNull()
            ]
            spectrumContainerLayer.addSublayer(barLayer)
            return barLayer
        }
        applySpectrumTheme()
    }

    private func configureProcessingLayers() {
        processingContainerLayer.actions = [
            "bounds": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
            "position": NSNull()
        ]
        processingContainerLayer.isHidden = true
        layer?.addSublayer(processingContainerLayer)

        processingDotLayers = (0..<3).map { _ in
            let dotLayer = CALayer()
            dotLayer.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            dotLayer.cornerRadius = 2
            dotLayer.actions = [
                "backgroundColor": NSNull(),
                "bounds": NSNull(),
                "cornerRadius": NSNull(),
                "opacity": NSNull(),
                "position": NSNull(),
                "transform": NSNull()
            ]
            processingContainerLayer.addSublayer(dotLayer)
            return dotLayer
        }
        applyProcessingTheme()
    }

    private func configureOrbLayers() {
        orbContainerLayer.actions = [
            "hidden": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "transform": NSNull()
        ]
        orbContainerLayer.isHidden = true
        layer?.addSublayer(orbContainerLayer)

        orbClipLayer.masksToBounds = true
        orbClipLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "cornerRadius": NSNull()
        ]
        orbMaskLayer.fillColor = NSColor.white.cgColor
        orbMaskLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "path": NSNull()
        ]
        orbClipLayer.mask = orbMaskLayer
        orbContainerLayer.addSublayer(orbClipLayer)

        orbGradientLayer.type = .axial
        orbGradientLayer.startPoint = CGPoint(x: 0.12, y: 0.86)
        orbGradientLayer.endPoint = CGPoint(x: 0.9, y: 0.12)
        orbGradientLayer.colors = [
            NSColor(
                calibratedRed: 0.055,
                green: 0.02,
                blue: 0.19,
                alpha: 1
            ).cgColor,
            NSColor(
                calibratedRed: 0.32,
                green: 0.13,
                blue: 0.92,
                alpha: 1
            ).cgColor,
            NSColor(
                calibratedRed: 0.9,
                green: 0.25,
                blue: 0.83,
                alpha: 1
            ).cgColor
        ]
        orbGradientLayer.locations = [0, 0.54, 1]
        orbGradientLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "transform": NSNull()
        ]
        orbClipLayer.addSublayer(orbGradientLayer)

        orbBloomLayer.type = .radial
        orbBloomLayer.startPoint = CGPoint(x: 0.7, y: 0.3)
        orbBloomLayer.endPoint = CGPoint(x: 1, y: 0)
        orbBloomLayer.colors = [
            NSColor(
                calibratedRed: 0.52,
                green: 0.42,
                blue: 1,
                alpha: 0.9
            ).cgColor,
            NSColor(
                calibratedRed: 0.34,
                green: 0.12,
                blue: 1,
                alpha: 0.16
            ).cgColor,
            NSColor.clear.cgColor
        ]
        orbBloomLayer.locations = [0, 0.5, 1]
        orbBloomLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull()
        ]
        orbClipLayer.addSublayer(orbBloomLayer)

        orbMagentaLayer.type = .radial
        orbMagentaLayer.startPoint = CGPoint(x: 0.28, y: 0.3)
        orbMagentaLayer.endPoint = CGPoint(x: 0.88, y: 0.88)
        orbMagentaLayer.colors = [
            NSColor(
                calibratedRed: 1,
                green: 0.22,
                blue: 0.76,
                alpha: 0.68
            ).cgColor,
            NSColor(
                calibratedRed: 0.55,
                green: 0.08,
                blue: 0.92,
                alpha: 0.14
            ).cgColor,
            NSColor.clear.cgColor
        ]
        orbMagentaLayer.locations = [0, 0.5, 1]
        orbMagentaLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull()
        ]
        orbClipLayer.addSublayer(orbMagentaLayer)

        orbGoldLayer.type = .radial
        orbGoldLayer.startPoint = CGPoint(x: 0.7, y: 0.73)
        orbGoldLayer.endPoint = CGPoint(x: 0.98, y: 0.3)
        orbGoldLayer.colors = [
            NSColor(
                calibratedRed: 0.74,
                green: 0.58,
                blue: 1,
                alpha: 0.46
            ).cgColor,
            NSColor(
                calibratedRed: 0.42,
                green: 0.18,
                blue: 0.96,
                alpha: 0.1
            ).cgColor,
            NSColor.clear.cgColor
        ]
        orbGoldLayer.locations = [0, 0.42, 1]
        orbGoldLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull()
        ]
        orbClipLayer.addSublayer(orbGoldLayer)

        orbOilLayer.type = .radial
        orbOilLayer.startPoint = CGPoint(x: 0.45, y: 0.52)
        orbOilLayer.endPoint = CGPoint(x: 0.9, y: 0.94)
        orbOilLayer.colors = [
            NSColor(
                calibratedRed: 0.035,
                green: 0.008,
                blue: 0.14,
                alpha: 0.8
            ).cgColor,
            NSColor(
                calibratedRed: 0.17,
                green: 0.05,
                blue: 0.45,
                alpha: 0.44
            ).cgColor,
            NSColor(
                calibratedRed: 0.5,
                green: 0.1,
                blue: 0.8,
                alpha: 0.05
            ).cgColor,
            NSColor.clear.cgColor
        ]
        orbOilLayer.locations = [0, 0.38, 0.7, 1]
        orbOilLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull()
        ]
        orbClipLayer.addSublayer(orbOilLayer)

        orbPearlLayer.type = .radial
        orbPearlLayer.startPoint = CGPoint(x: 0.58, y: 0.43)
        orbPearlLayer.endPoint = CGPoint(x: 0.88, y: 0.72)
        orbPearlLayer.colors = [
            NSColor(
                calibratedRed: 1,
                green: 0.84,
                blue: 1,
                alpha: 0.5
            ).cgColor,
            NSColor(
                calibratedRed: 0.72,
                green: 0.48,
                blue: 1,
                alpha: 0.1
            ).cgColor,
            NSColor.clear.cgColor
        ]
        orbPearlLayer.locations = [0, 0.5, 1]
        orbPearlLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull()
        ]
        orbClipLayer.addSublayer(orbPearlLayer)

        orbCausticLayer.fillColor = nil
        orbCausticLayer.strokeColor = NSColor(
            calibratedRed: 0.82,
            green: 0.68,
            blue: 1,
            alpha: 0
        )
            .cgColor
        orbCausticLayer.lineWidth = 0.9
        orbCausticLayer.lineCap = .round
        orbCausticLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "path": NSNull(),
            "opacity": NSNull()
        ]
        orbClipLayer.addSublayer(orbCausticLayer)
        orbCausticLayer.isHidden = true

        orbMaterialLayers = (0..<6).map { _ in
            let materialLayer = CAShapeLayer()
            materialLayer.fillColor = nil
            materialLayer.lineCap = .round
            materialLayer.lineJoin = .round
            materialLayer.actions = [
                "backgroundColor": NSNull(),
                "bounds": NSNull(),
                "fillColor": NSNull(),
                "hidden": NSNull(),
                "lineWidth": NSNull(),
                "opacity": NSNull(),
                "path": NSNull(),
                "position": NSNull(),
                "shadowColor": NSNull(),
                "shadowOpacity": NSNull(),
                "shadowRadius": NSNull(),
                "strokeColor": NSNull(),
                "transform": NSNull()
            ]
            orbClipLayer.addSublayer(materialLayer)
            return materialLayer
        }

        orbGlitterLayers = (0..<6).map { _ in
            let glitterLayer = CALayer()
            glitterLayer.cornerRadius = 1
            glitterLayer.actions = [
                "backgroundColor": NSNull(),
                "bounds": NSNull(),
                "cornerRadius": NSNull(),
                "opacity": NSNull(),
                "position": NSNull(),
                "transform": NSNull()
            ]
            orbClipLayer.addSublayer(glitterLayer)
            return glitterLayer
        }
        orbStrandLayers = []

        orbHighlightLayer.type = .radial
        orbHighlightLayer.startPoint = CGPoint(x: 0.3, y: 0.24)
        orbHighlightLayer.endPoint = CGPoint(x: 0.84, y: 0.82)
        orbHighlightLayer.colors = [
            NSColor(
                calibratedRed: 1,
                green: 0.9,
                blue: 1,
                alpha: 0.62
            ).cgColor,
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.clear.cgColor
        ]
        orbHighlightLayer.locations = [0, 0.36, 1]
        orbHighlightLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull()
        ]
        orbClipLayer.addSublayer(orbHighlightLayer)

        orbRimLayer.fillColor = nil
        orbRimLayer.strokeColor = NSColor(
            calibratedRed: 0.9,
            green: 0.86,
            blue: 1,
            alpha: 0.72
        ).cgColor
        orbRimLayer.lineWidth = 0.4
        orbRimLayer.lineJoin = .round
        orbRimLayer.shadowColor = NSColor(
            calibratedRed: 0.58,
            green: 0.22,
            blue: 1,
            alpha: 1
        ).cgColor
        orbRimLayer.shadowOpacity = 0.26
        orbRimLayer.shadowRadius = 0.8
        orbRimLayer.shadowOffset = .zero
        orbRimLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "path": NSNull(),
            "opacity": NSNull()
        ]
        orbContainerLayer.addSublayer(orbRimLayer)
        applyOrbTheme()
    }

    private func applyOrbTheme() {
        orbGradientLayer.colors = [
            orbTheme.baseDark.nsColor().cgColor,
            orbTheme.primary.nsColor().cgColor,
            orbTheme.accent.nsColor().cgColor
        ]
        orbBloomLayer.colors = [
            orbTheme.highlight.nsColor(alpha: 0.82).cgColor,
            orbTheme.secondary.nsColor(alpha: 0.16).cgColor,
            NSColor.clear.cgColor
        ]
        orbMagentaLayer.colors = [
            orbTheme.accent.nsColor(alpha: 0.66).cgColor,
            orbTheme.primary.nsColor(alpha: 0.12).cgColor,
            NSColor.clear.cgColor
        ]
        orbGoldLayer.colors = [
            orbTheme.highlight.nsColor(alpha: 0.42).cgColor,
            orbTheme.secondary.nsColor(alpha: 0.09).cgColor,
            NSColor.clear.cgColor
        ]
        orbOilLayer.colors = [
            orbTheme.baseDark.nsColor(alpha: 0.84).cgColor,
            orbTheme.primary.nsColor(alpha: 0.34).cgColor,
            orbTheme.secondary.nsColor(alpha: 0.04).cgColor,
            NSColor.clear.cgColor
        ]
        orbPearlLayer.colors = [
            orbTheme.highlight.nsColor(alpha: 0.46).cgColor,
            orbTheme.rim.nsColor(alpha: 0.08).cgColor,
            NSColor.clear.cgColor
        ]
        orbHighlightLayer.colors = [
            orbTheme.highlight.nsColor(alpha: 0.5).cgColor,
            orbTheme.rim.nsColor(alpha: 0.05).cgColor,
            NSColor.clear.cgColor
        ]
        orbCausticLayer.strokeColor = orbTheme.highlight
            .nsColor(alpha: 0.42)
            .cgColor
        orbRimLayer.strokeColor = orbTheme.rim
            .nsColor(alpha: 0.52)
            .cgColor
        orbRimLayer.shadowColor = orbTheme.primary
            .nsColor(alpha: 0.72)
            .cgColor

        for (index, glitterLayer) in orbGlitterLayers.enumerated() {
            let color = index.isMultiple(of: 2)
                ? orbTheme.highlight
                : orbTheme.accent
            glitterLayer.backgroundColor = color
                .nsColor()
                .cgColor
            glitterLayer.opacity = 0
        }
        resetOrbMaterialLayers()
    }

    private func applySpectrumTheme() {
        for (layerIndex, barLayer) in spectrumBarLayers.enumerated() {
            let offsetIndex = layerIndex - (Self.displayedSegmentCount - 1)
            let normalizedDistance = CGFloat(abs(offsetIndex))
                / CGFloat(max(1, Self.displayedSegmentCount - 1))
            barLayer.backgroundColor = barPalette
                .spectrumColor(at: normalizedDistance)
                .nsColor()
                .cgColor
        }
    }

    nonisolated override func layout() {
        AppKitMainThreadBridge.run {
            super.layout()
            updateAudioLayerGeometry()
        }
    }

    nonisolated override func updateTrackingAreas() {
        AppKitMainThreadBridge.run {
            super.updateTrackingAreas()

            if let trackingAreaReference {
                removeTrackingArea(trackingAreaReference)
            }
            let trackingArea = NSTrackingArea(
                rect: cardRect,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeAlways
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            trackingAreaReference = trackingArea
        }
    }

    nonisolated override func resetCursorRects() {
        AppKitMainThreadBridge.run {
            super.resetCursorRects()
            addCursorRect(cardRect, cursor: .openHand)
            guard presentationMode != .compact else {
                return
            }
            for (_, rect) in modeControlRects {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    nonisolated override func mouseEntered(with event: NSEvent) {
        let locationInWindow = event.locationInWindow
        AppKitMainThreadBridge.run {
            updateHoverLocation(locationInWindow: locationInWindow)
            setHovered(true)
        }
    }

    nonisolated override func mouseMoved(with event: NSEvent) {
        let locationInWindow = event.locationInWindow
        AppKitMainThreadBridge.run {
            updateHoverLocation(locationInWindow: locationInWindow)
        }
    }

    nonisolated override func mouseExited(with event: NSEvent) {
        AppKitMainThreadBridge.run {
            toolTip = nil
            setHovered(false)
        }
    }

    nonisolated override func acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool {
        true
    }

    nonisolated override func mouseDown(with event: NSEvent) {
        let locationInWindow = event.locationInWindow
        let callbackEvent = AppKitCallbackValue(value: event)
        AppKitMainThreadBridge.run {
            let location = convert(locationInWindow, from: nil)
            if case .recording = status,
               presentationMode != .compact,
               let selectedMode = modeControlRects.first(where: {
                   $0.1.contains(location)
               })?.0 {
                updateOutputMode(selectedMode)
                onOutputModeChange?(selectedMode)
                return
            }

            guard let window else {
                onBackgroundClick?()
                return
            }
            let initialOrigin = window.frame.origin
            window.performDrag(with: callbackEvent.value)
            let distance = hypot(
                window.frame.origin.x - initialOrigin.x,
                window.frame.origin.y - initialOrigin.y
            )
            if distance >= 3 {
                onDragEnded?()
            } else {
                onBackgroundClick?()
            }
        }
    }

    private func updateHoverLocation(locationInWindow: NSPoint) {
        hoverLocation = convert(locationInWindow, from: nil)
        if let hoveredOutputMode {
            toolTip = "Activer \(hoveredOutputMode.displayName)"
        } else if presentationMode == .compact {
            toolTip = "Cliquer pour déployer · Glisser pour déplacer"
        } else {
            toolTip = "Cliquer pour réduire · Glisser pour déplacer"
        }
        needsDisplay = true
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else {
            return
        }
        isHovered = hovered
        needsDisplay = true
    }

    func update(
        status: AppStatus,
        visualization: AudioVisualizationFrame,
        reduceMotion: Bool
    ) {
        let previousStatus = self.status
        self.status = status
        self.reduceMotion = reduceMotion
        var shouldRedrawCard = Self.visualState(
            for: previousStatus
        ) != Self.visualState(for: status)

        if case .recording = status {
            if !wasRecording {
                resetEnvelope()
                setSpectrumPresented(true)
                shouldRedrawCard = true
            }

            if visualization.sequence > 0,
               visualization.sequence != lastSequence {
                updateTargetEnvelope(
                    visualization.liveEnvelope,
                    voiceLevel: visualization.voiceLevel
                )
                lastSequence = visualization.sequence
            }

            advanceDisplayedEnvelope()
            updateSpectrumLayers()
            updateOrbActivity()

            if case let .recording(duration, _) = status {
                let timerSecond = max(0, Int(duration))
                if timerSecond != lastTimerSecond {
                    lastTimerSecond = timerSecond
                    shouldRedrawCard = true
                }
            }
            wasRecording = true
        } else {
            if wasRecording {
                setSpectrumPresented(false)
            }
            wasRecording = false
            lastSequence = 0
            lastTimerSecond = nil
            orbContainerLayer.isHidden = presentationMode != .compact
            stopOrbAnimation()
        }

        updateProcessingIndicatorForCurrentStatus()

        if shouldRedrawCard {
            needsDisplay = true
        }
    }

    func updateOrbProgression(
        totalWords: Int,
        overrideID: String
    ) {
        let nextTheme = OrbEvolution.progression(
            forWords: totalWords,
            overrideID: overrideID
        ).theme
        guard nextTheme != orbTheme else {
            return
        }

        orbTheme = nextTheme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyOrbTheme()
        applySpectrumTheme()
        applyProcessingTheme()
        CATransaction.commit()
        needsDisplay = true
    }

    func updateOutputMode(_ mode: DictationOutputMode) {
        guard outputMode != mode else {
            return
        }
        outputMode = mode
        updateOutputModeAccessibility()
        if hoveredOutputMode != nil {
            toolTip = "Activer \(mode.displayName)"
        }
        needsDisplay = true
    }

    func updatePresentationMode(_ mode: FloatingBarPresentationMode) {
        guard presentationMode != mode else {
            return
        }
        presentationMode = mode
        frame.size = mode.panelSize
        updateTrackingAreas()
        discardCursorRects()
        updateAudioLayerGeometry()
        updateProcessingIndicatorForCurrentStatus()
        if case .recording = status {
            spectrumContainerLayer.isHidden = mode == .compact
            orbContainerLayer.isHidden = false
        } else if mode == .compact {
            orbContainerLayer.isHidden = false
            updateOrbActivity()
        }
        updateOutputModeAccessibility()
        needsDisplay = true
    }

    private func updateOutputModeAccessibility() {
        setAccessibilityHelp(
            "Mode: \(outputMode.displayName). Choose a named mode, click the bar to resize it, or drag it to move it."
        )
    }

    func setHoveredForPreview(_ hovered: Bool, location: NSPoint) {
        hoverLocation = location
        isHovered = hovered
        needsDisplay = true
    }

    private func resetEnvelope() {
        displayedEnvelope = Array(
            repeating: 0,
            count: Self.envelopeSegmentCount
        )
        targetEnvelope = displayedEnvelope
        displayedVoiceLevel = 0
        targetVoiceLevel = 0
        lastSequence = 0
        lastTimerSecond = nil
    }

    private func setSpectrumPresented(_ presented: Bool) {
        spectrumTransitionGeneration &+= 1
        let generation = spectrumTransitionGeneration
        spectrumHideWorkItem?.cancel()
        spectrumHideWorkItem = nil

        let transition = FloatingBarSpectrumTransition.make(
            presented: presented,
            reduceMotion: reduceMotion
        )
        let currentOpacity = spectrumContainerLayer
            .presentation()?
            .opacity ?? spectrumContainerLayer.opacity

        spectrumContainerLayer.removeAnimation(forKey: "presence")
        if presented {
            spectrumContainerLayer.isHidden = false
            isSpectrumDismissing = false
        } else {
            isSpectrumDismissing = true
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spectrumContainerLayer.opacity = transition.targetOpacity
        CATransaction.commit()

        guard transition.duration > 0 else {
            if !presented {
                spectrumContainerLayer.isHidden = true
                isSpectrumDismissing = false
            }
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = transition.targetOpacity
        animation.duration = transition.duration
        animation.timingFunction = CAMediaTimingFunction(
            name: transition.curve == .easeOut ? .easeOut : .easeIn
        )
        spectrumContainerLayer.add(animation, forKey: "presence")

        guard !presented else {
            return
        }

        let hideWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.spectrumTransitionGeneration == generation,
                  !self.wasRecording else {
                return
            }
            self.spectrumContainerLayer.isHidden = true
            self.isSpectrumDismissing = false
            self.updateProcessingIndicatorForCurrentStatus()
            self.needsDisplay = true
        }
        spectrumHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + transition.duration + 0.01,
            execute: hideWorkItem
        )
    }

    private func updateProcessingIndicatorForCurrentStatus() {
        let shouldShow: Bool
        if case .processing = status {
            shouldShow = !isSpectrumDismissing
                && presentationMode != .compact
        } else {
            shouldShow = false
        }
        setProcessingIndicatorVisible(shouldShow)
    }

    private func setProcessingIndicatorVisible(_ visible: Bool) {
        guard visible else {
            guard !processingContainerLayer.isHidden else {
                return
            }
            processingContainerLayer.isHidden = true
            for dotLayer in processingDotLayers {
                dotLayer.removeAnimation(forKey: "processingPulse")
            }
            return
        }

        guard processingContainerLayer.isHidden else {
            return
        }
        processingContainerLayer.isHidden = false
        startProcessingAnimation()
    }

    private func startProcessingAnimation() {
        let baseTime = processingContainerLayer.convertTime(
            CACurrentMediaTime(),
            from: nil
        )

        for (index, dotLayer) in processingDotLayers.enumerated() {
            dotLayer.removeAnimation(forKey: "processingPulse")
            dotLayer.opacity = reduceMotion ? 0.72 : 0.2
            dotLayer.transform = CATransform3DIdentity

            guard !reduceMotion else {
                continue
            }

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.2, 1, 0.34, 0.2]
            opacity.keyTimes = [0, 0.2, 0.52, 1]
            opacity.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeIn)
            ]

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.78, 1.12, 0.88, 0.78]
            scale.keyTimes = opacity.keyTimes
            scale.timingFunctions = opacity.timingFunctions

            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.beginTime = baseTime + Double(index) * 0.16
            group.duration = 0.72
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            group.fillMode = .backwards
            dotLayer.add(group, forKey: "processingPulse")
        }
    }

    private func applyProcessingTheme() {
        for (index, dotLayer) in processingDotLayers.enumerated() {
            let normalizedDistance = CGFloat(abs(index - 1))
            dotLayer.backgroundColor = barPalette
                .spectrumColor(at: normalizedDistance)
                .nsColor()
                .cgColor
        }
    }

    private func updateTargetEnvelope(
        _ envelope: [Float],
        voiceLevel: Float
    ) {
        let clampedVoiceLevel = max(0, min(1, voiceLevel))
        let liftedVoiceLevel = max(
            0,
            min(1, (clampedVoiceLevel - 0.025) / 0.78)
        )
        targetVoiceLevel = min(1, pow(liftedVoiceLevel, 0.78) * 1.06)

        for index in targetEnvelope.indices {
            let segment = index < envelope.count
                ? max(0, min(1, envelope[index]))
                : 0
            let pulseShape = 0.12 + 0.88 * segment
            targetEnvelope[index] = targetVoiceLevel * pulseShape
        }
    }

    private func advanceDisplayedEnvelope() {
        if reduceMotion {
            displayedEnvelope = targetEnvelope
            displayedVoiceLevel = targetVoiceLevel
            return
        }

        for index in displayedEnvelope.indices {
            let current = displayedEnvelope[index]
            let target = targetEnvelope[index]
            displayedEnvelope[index] = FloatingBarEnvelopeMotion
                .advanceEnvelope(
                    current: current,
                    target: target
                )
        }

        displayedVoiceLevel = FloatingBarEnvelopeMotion
            .advanceVoiceLevel(
                current: displayedVoiceLevel,
                target: targetVoiceLevel
            )
    }

    nonisolated override func draw(_ dirtyRect: NSRect) {
        AppKitMainThreadBridge.run {
            super.draw(dirtyRect)
            drawCard()

            switch status {
            case .recording:
                drawRecordingState()
            case .processing:
                break
            case .done:
                drawSymbolState(name: "checkmark", color: .systemGreen)
            case .error:
                drawSymbolState(
                    name: "exclamationmark",
                    color: .systemOrange
                )
            case .idle:
                break
            }
        }
    }

    private func drawCard() {
        let radius = presentationMode == .horizontal
            ? min(27, cardRect.height / 2)
            : min(cardRect.width, cardRect.height) / 2
        let path = NSBezierPath(
            roundedRect: cardRect,
            xRadius: radius,
            yRadius: radius
        )

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let palette = barPalette
        if presentationMode == .compact {
            palette.backgroundBottom.nsColor(alpha: 0.86).setFill()
            path.fill()
        } else {
            NSGradient(
                colors: [
                    palette.backgroundTop.nsColor(alpha: 0.985),
                    palette.backgroundBottom.nsColor(alpha: 0.99)
                ]
            )?.draw(in: cardRect, angle: -8)
        }

        drawOrbAmbientLight()

        if isHovered {
            drawHoverSpotlight()
        }

        NSGraphicsContext.restoreGraphicsState()

        let borderColor: NSColor
        if presentationMode == .compact {
            borderColor = palette.border.nsColor(alpha: 0.12)
        } else {
            borderColor = isHovered
                ? palette.spectrumCenter.nsColor(alpha: 0.34)
                : palette.border.nsColor(alpha: 0.18)
        }
        borderColor.setStroke()
        path.lineWidth = presentationMode == .compact
            ? 0.4
            : (isHovered ? 0.9 : 0.7)
        path.stroke()
    }

    private func drawOrbAmbientLight() {
        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(
                  colorsSpace: CGColorSpaceCreateDeviceRGB(),
                  colors: [
                      barPalette.ambientPrimary
                          .nsColor(alpha: 0.24)
                          .cgColor,
                      barPalette.ambientSecondary
                          .nsColor(alpha: 0.075)
                          .cgColor,
                      barPalette.ambientPrimary
                          .nsColor(alpha: 0)
                          .cgColor
                  ] as CFArray,
                  locations: [0, 0.42, 1]
              ) else {
            return
        }

        let center = CGPoint(
            x: FloatingBarModeControlLayout.orbCenter(
                in: cardRect,
                presentation: presentationMode
            ).x,
            y: FloatingBarModeControlLayout.orbCenter(
                in: cardRect,
                presentation: presentationMode
            ).y
        )
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: 84,
            options: []
        )
    }

    private func drawHoverSpotlight() {
        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(
                  colorsSpace: CGColorSpaceCreateDeviceRGB(),
                  colors: [
                      barPalette.ambientSecondary
                          .nsColor(alpha: 0.22)
                          .cgColor,
                      barPalette.ambientPrimary
                          .nsColor(alpha: 0)
                          .cgColor
                  ] as CFArray,
                  locations: [0, 1]
              ) else {
            return
        }

        context.drawRadialGradient(
            gradient,
            startCenter: hoverLocation,
            startRadius: 0,
            endCenter: hoverLocation,
            endRadius: 88,
            options: []
        )
    }

    private func drawRecordingState() {
        guard presentationMode != .compact else {
            return
        }
        drawOutputModeControl()
        drawTimer()
    }

    private func drawOutputModeControl() {
        let groupRect = FloatingBarModeControlLayout.modeGroupRect(
            in: cardRect,
            presentation: presentationMode
        )
        let groupPath = NSBezierPath(
            roundedRect: groupRect,
            xRadius: 11,
            yRadius: 11
        )
        barPalette.backgroundBottom.nsColor(alpha: 0.72).setFill()
        groupPath.fill()
        NSColor.white.withAlphaComponent(0.09).setStroke()
        groupPath.lineWidth = 0.65
        groupPath.stroke()

        for (mode, rect) in modeControlRects {
            let selected = mode == outputMode
            let hovered = mode == hoveredOutputMode
            if selected || hovered {
                let segmentPath = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 1.2, dy: 1.2),
                    xRadius: 9.5,
                    yRadius: 9.5
                )
                NSGradient(
                    colors: [
                        barPalette.spectrumCenter.nsColor(
                            alpha: selected ? 0.32 : 0.18
                        ),
                        barPalette.ambientPrimary.nsColor(
                            alpha: selected ? 0.2 : 0.1
                        )
                    ]
                )?.draw(in: segmentPath, angle: -62)
                (selected
                    ? barPalette.spectrumCenter.nsColor(alpha: 0.54)
                    : NSColor.white.withAlphaComponent(0.14)
                ).setStroke()
                segmentPath.lineWidth = 0.7
                segmentPath.stroke()
            }

            let label = mode.compactDisplayName
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: presentationMode == .vertical ? 8.2 : 8.5,
                    weight: selected ? .semibold : .medium
                ),
                .foregroundColor: selected
                    ? NSColor.white.withAlphaComponent(0.94)
                    : NSColor.white.withAlphaComponent(
                        hovered ? 0.78 : 0.48
                    )
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: ceil(size.width),
                    height: ceil(size.height)
                ),
                withAttributes: attributes
            )
        }
    }

    private func drawTimer() {
        guard case let .recording(duration, mode) = status else {
            return
        }

        let totalSeconds = max(0, Int(duration))
        let value = String(
            format: "%02d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
        let capsuleRect = FloatingBarModeControlLayout.timerRect(
            in: cardRect,
            presentation: presentationMode
        )
        drawTimerCapsule(in: capsuleRect, mode: mode)

        let timerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: 10,
                weight: .medium
            ),
            .foregroundColor: NSColor.white.withAlphaComponent(
                isHovered ? 0.86 : 0.72
            )
        ]
        let timerSize = value.size(withAttributes: timerAttributes)
        value.draw(
            in: NSRect(
                x: capsuleRect.midX - timerSize.width / 2,
                y: capsuleRect.midY - timerSize.height / 2,
                width: ceil(timerSize.width),
                height: ceil(timerSize.height)
            ),
            withAttributes: timerAttributes
        )

    }

    private func drawTimerCapsule(
        in rect: NSRect,
        mode: RecordingMode
    ) {
        let outerPath = NSBezierPath(
            roundedRect: rect,
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        )
        let borderColors: [NSColor] = mode == .toggle
            ? [
                barPalette.spectrumCenter.nsColor(
                    alpha: isHovered ? 0.52 : 0.36
                ),
                NSColor.white.withAlphaComponent(0.11),
                barPalette.border.nsColor(
                    alpha: isHovered ? 0.46 : 0.3
                )
            ]
            : [
                barPalette.border.nsColor(
                    alpha: isHovered ? 0.3 : 0.2
                ),
                NSColor.white.withAlphaComponent(0.07)
            ]
        NSGradient(colors: borderColors)?.draw(
            in: outerPath,
            angle: 8
        )

        let innerRect = rect.insetBy(dx: 0.7, dy: 0.7)
        let innerPath = NSBezierPath(
            roundedRect: innerRect,
            xRadius: innerRect.height / 2,
            yRadius: innerRect.height / 2
        )
        NSGradient(
            colors: [
                barPalette.backgroundTop.nsColor(alpha: 0.97),
                barPalette.backgroundBottom.nsColor(alpha: 0.985)
            ]
        )?.draw(in: innerPath, angle: -90)

        let topHighlightRect = NSRect(
            x: innerRect.minX + 6,
            y: innerRect.minY + 1,
            width: max(0, innerRect.width - 12),
            height: 0.5
        )
        barPalette.spectrumCenter.nsColor(
            alpha: isHovered ? 0.14 : 0.085
        ).setFill()
        NSBezierPath(
            roundedRect: topHighlightRect,
            xRadius: 0.25,
            yRadius: 0.25
        ).fill()

    }

    private func updateAudioLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        spectrumContainerLayer.frame = bounds
        processingContainerLayer.frame = bounds
        for (index, dotLayer) in processingDotLayers.enumerated() {
            if presentationMode == .vertical {
                dotLayer.position = CGPoint(
                    x: cardRect.midX,
                    y: cardRect.midY + (CGFloat(index) - 1) * 10
                )
            } else {
                dotLayer.position = CGPoint(
                    x: cardRect.midX + (CGFloat(index) - 1) * 10,
                    y: cardRect.midY
                )
            }
        }

        let orbSize: CGFloat
        switch presentationMode {
        case .horizontal:
            orbSize = 20
        case .vertical:
            orbSize = 25
        case .compact:
            orbSize = 46
        }
        orbContainerLayer.bounds = NSRect(
            x: 0,
            y: 0,
            width: orbSize,
            height: orbSize
        )
        orbContainerLayer.position = FloatingBarModeControlLayout.orbCenter(
            in: cardRect,
            presentation: presentationMode
        )
        orbClipLayer.frame = orbContainerLayer.bounds
        orbClipLayer.cornerRadius = 0
        orbMaskLayer.frame = orbClipLayer.bounds

        orbGradientLayer.frame = orbClipLayer.bounds
        orbBloomLayer.frame = orbClipLayer.bounds
        orbMagentaLayer.frame = orbClipLayer.bounds
        orbGoldLayer.frame = orbClipLayer.bounds
        orbOilLayer.frame = orbClipLayer.bounds
        orbPearlLayer.frame = orbClipLayer.bounds
        orbCausticLayer.frame = orbClipLayer.bounds
        for materialLayer in orbMaterialLayers {
            materialLayer.frame = orbClipLayer.bounds
        }
        for strandLayer in orbStrandLayers {
            strandLayer.frame = orbClipLayer.bounds
        }
        orbHighlightLayer.frame = orbClipLayer.bounds
        orbRimLayer.frame = orbContainerLayer.bounds

        if case .recording = status {
            updateSpectrumLayers()
        }
        CATransaction.commit()
    }

    private func updateSpectrumLayers() {
        guard presentationMode != .compact else {
            spectrumContainerLayer.isHidden = true
            return
        }
        let rect = FloatingBarModeControlLayout.spectrumRect(
            in: cardRect,
            presentation: presentationMode
        )
        guard !displayedEnvelope.isEmpty,
              spectrumBarLayers.count == Self.spectrumBarCount else {
            return
        }

        let availableLength = presentationMode == .vertical
            ? rect.height
            : rect.width
        let spacing = availableLength
            / CGFloat((Self.displayedSegmentCount - 1) * 2 + 2)
        let barWidth: CGFloat = 2.2
        let centerY = rect.midY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spectrumContainerLayer.isHidden = false

        for (layerIndex, offsetIndex) in (
            -(Self.displayedSegmentCount - 1)...(
                Self.displayedSegmentCount - 1
            )
        ).enumerated() {
            let normalizedIndex = CGFloat(abs(offsetIndex))
                / CGFloat(max(1, Self.displayedSegmentCount - 1))
            let index = min(
                displayedEnvelope.count - 1,
                Int(
                    (
                        normalizedIndex
                        * CGFloat(displayedEnvelope.count - 1)
                    ).rounded()
                )
            )
            let rawValue = displayedEnvelope[index]
            let value = CGFloat(max(0, min(1, rawValue)))
            let presentation = FloatingBarSpectrumBarPresentation.make(
                value: value
            )
            let barLayer = spectrumBarLayers[layerIndex]
            if presentationMode == .vertical {
                barLayer.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: presentation.amplitude * 2,
                    height: barWidth
                )
                barLayer.position = CGPoint(
                    x: rect.midX,
                    y: rect.midY + CGFloat(offsetIndex) * spacing
                )
            } else {
                barLayer.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: barWidth,
                    height: presentation.amplitude * 2
                )
                barLayer.position = CGPoint(
                    x: rect.midX + CGFloat(offsetIndex) * spacing,
                    y: centerY
                )
            }
            barLayer.opacity = Float(presentation.alpha)
            barLayer.cornerRadius = min(
                barWidth / 2,
                presentation.amplitude
            )
        }

        CATransaction.commit()
    }

    private func updateOrbActivity() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbContainerLayer.isHidden = false

        let center = CGPoint(
            x: FloatingBarModeControlLayout.orbCenter(
                in: cardRect,
                presentation: presentationMode
            ).x,
            y: FloatingBarModeControlLayout.orbCenter(
                in: cardRect,
                presentation: presentationMode
            ).y
        )
        let hoverDelta = CGPoint(
            x: hoverLocation.x - center.x,
            y: hoverLocation.y - center.y
        )
        let orbIsHovered = isHovered
            && hypot(hoverDelta.x, hoverDelta.y) <= 24
        let pointer = orbIsHovered
            ? CGPoint(
                x: max(0, min(1, 0.5 + hoverDelta.x / 32)),
                y: max(0, min(1, 0.5 + hoverDelta.y / 32))
            )
            : nil
        let phase = reduceMotion
            ? 0
            : CACurrentMediaTime() * orbTheme.motionSpeed
        let motion = LiquidOrbMotion.sample(
            time: phase,
            pointer: pointer,
            energy: CGFloat(displayedVoiceLevel),
            sparkleCount: orbTheme.material == .galaxy ? 12 : 0
        )

        let voiceEnergy = CGFloat(displayedVoiceLevel)
        let voicePulse = reduceMotion
            ? 0
            : sin(phase * 8.2) * voiceEnergy * 0.026
        let scale = 1
            + voiceEnergy * 0.17
            + motion.interactionStrength * 0.08
            + voicePulse
        orbContainerLayer.transform = CATransform3DMakeScale(
            scale,
            scale,
            1
        )
        orbGradientLayer.startPoint = CGPoint(
            x: 0.12 + motion.tilt.width * 0.05,
            y: 0.86 + motion.tilt.height * 0.05
        )
        orbGradientLayer.endPoint = CGPoint(
            x: 0.9 + motion.tilt.width * 0.04,
            y: 0.12 + motion.tilt.height * 0.04
        )
        applyOrbLiquidMotion(motion)
        CATransaction.commit()
    }

    private func applyOrbLiquidMotion(_ motion: LiquidOrbMotionSample) {
        orbBloomLayer.opacity = Float(0.68 + motion.energy * 0.32)
        orbMagentaLayer.opacity = Float(0.72 + motion.energy * 0.28)
        orbGoldLayer.opacity = Float(0.58 + motion.energy * 0.42)
        orbOilLayer.opacity = Float(0.92 - motion.energy * 0.18)
        orbPearlLayer.opacity = Float(0.62 + motion.energy * 0.38)
        orbHighlightLayer.opacity = Float(0.7 + motion.energy * 0.3)

        let core = motion.oil
        orbBloomLayer.startPoint = motion.cyan
        orbMagentaLayer.startPoint = motion.magenta
        orbGoldLayer.startPoint = motion.gold
        orbOilLayer.startPoint = core
        orbOilLayer.endPoint = CGPoint(
            x: max(0.05, min(0.95, core.x + 0.42)),
            y: max(0.05, min(0.95, core.y + 0.38))
        )
        orbPearlLayer.startPoint = motion.pearl
        orbPearlLayer.endPoint = CGPoint(
            x: 0.72,
            y: 0.62
        )
        orbHighlightLayer.startPoint = motion.highlight

        let visibleSparkleCount = [.galaxy, .eclipse].contains(
            orbTheme.material
        )
            ? min(
                orbTheme.sparkleCount,
                orbGlitterLayers.count
            )
            : 0
        if visibleSparkleCount > 0, !motion.sparkles.isEmpty {
            for index in 0..<visibleSparkleCount {
                let glitterLayer = orbGlitterLayers[index]
                let sampleIndex = min(
                    motion.sparkles.count - 1,
                    index * 2
                )
                let sparkle = motion.sparkles[sampleIndex]
                let diameter = 0.5 + sparkle.scale * 0.72
                glitterLayer.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: diameter,
                    height: diameter
                )
                glitterLayer.cornerRadius = diameter / 2
                glitterLayer.position = CGPoint(
                    x: sparkle.position.x * orbClipLayer.bounds.width,
                    y: sparkle.position.y * orbClipLayer.bounds.height
                )
                glitterLayer.opacity = Float(sparkle.opacity * 0.48)
            }
        }

        let size = orbClipLayer.bounds.size
        let orbRect = CGRect(origin: .zero, size: size)
            .insetBy(dx: 0.7, dy: 0.7)
        let blobPath = LiquidOrbGeometry.blobPath(
            in: orbRect,
            motion: motion,
            detail: 36
        )
        orbMaskLayer.path = blobPath
        orbRimLayer.path = blobPath
        if presentationMode == .compact {
            orbRimLayer.opacity = 0.24
            orbRimLayer.lineWidth = 0.22
            orbRimLayer.shadowOpacity = 0.06
            orbRimLayer.shadowRadius = 0.25
        } else {
            orbRimLayer.opacity = Float(
                0.58 + motion.turbulence * 0.12
            )
            orbRimLayer.lineWidth = 0.38 + motion.energy * 0.08
            orbRimLayer.shadowOpacity = 0.26
            orbRimLayer.shadowRadius = 0.7 + motion.energy * 0.5
        }

        orbCausticLayer.path = LiquidOrbGeometry.strandPath(
            in: orbRect,
            index: 0,
            motion: motion
        )
        orbCausticLayer.lineWidth = 0.72 + motion.energy * 0.62
        orbCausticLayer.opacity = Float(
            0.16 + motion.turbulence * 0.18 + motion.energy * 0.18
        )
        applyOrbMaterialMotion(motion, in: orbRect)

        for (index, strandLayer) in orbStrandLayers.enumerated() {
            strandLayer.path = LiquidOrbGeometry.strandPath(
                in: orbRect,
                index: index + 1,
                motion: motion
            )
            let shimmer = 0.55 + 0.45 * sin(
                motion.phase * 0.7 + CGFloat(index + 1) * 1.18
            )
            strandLayer.lineWidth = (
                index.isMultiple(of: 2) ? 0.34 : 0.24
            ) * (1 + motion.energy * 0.78)
            strandLayer.opacity = Float(
                0.18 + shimmer * 0.48 + motion.energy * 0.26
            )
        }
    }

    private func applyOrbMaterialMotion(
        _ motion: LiquidOrbMotionSample,
        in rect: CGRect
    ) {
        orbCausticLayer.isHidden = true

        switch orbTheme.material {
        case .water, .wind, .earth, .aurora, .lava, .ice, .plasma, .prism:
            // At 20 pt, explicit geometry reads as a decal on the glass.
            // The animated radial fields already carry the material behind
            // the clean front lens, so keep the shell visually untouched.
            break
        case .galaxy, .eclipse:
            applyGalaxyMaterial(motion, in: rect)
        }
    }

    private func resetOrbMaterialLayers() {
        for layer in orbMaterialLayers {
            layer.isHidden = true
            layer.path = nil
            layer.fillColor = nil
            layer.strokeColor = nil
            layer.opacity = 0
            layer.lineWidth = 0
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
            layer.shadowOffset = .zero
        }
    }

    private func applyGalaxyMaterial(
        _ motion: LiquidOrbMotionSample,
        in rect: CGRect
    ) {
        for index in 0..<3 {
            let layer = orbMaterialLayers[index]
            layer.isHidden = false
            layer.path = galaxyMaterialPath(
                in: rect,
                phase: motion.phase,
                arm: index
            )
            layer.fillColor = nil
            layer.strokeColor = (
                index.isMultiple(of: 2)
                    ? orbTheme.highlight
                    : orbTheme.accent
            ).nsColor(alpha: 0.72).cgColor
            layer.lineWidth = 0.48 + motion.energy * 0.28
            layer.opacity = Float(0.52 + motion.energy * 0.25)
            layer.shadowColor = orbTheme.accent.nsColor().cgColor
            layer.shadowOpacity = 0.44
            layer.shadowRadius = 1.2
        }

    }
    private func galaxyMaterialPath(
        in rect: CGRect,
        phase: CGFloat,
        arm: Int
    ) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let armOffset = CGFloat(arm) * .pi
        let rotation = phase * 0.46 + armOffset
        let steps = 28

        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let radius = 0.6 + progress * rect.width * 0.46
            let angle = rotation + progress * .pi * 2.25
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius * 0.48
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func stopOrbAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let motion = LiquidOrbMotion.sample(
            time: 0,
            pointer: nil,
            sparkleCount: [.galaxy, .eclipse].contains(orbTheme.material)
                ? 12
                : 0
        )
        applyOrbLiquidMotion(motion)
        CATransaction.commit()
    }

    private static func visualState(for status: AppStatus) -> Int {
        switch status {
        case .idle:
            return 0
        case .recording(_, .hold):
            return 1
        case .recording(_, .toggle):
            return 2
        case .processing:
            return 3
        case .done:
            return 4
        case .error:
            return 5
        }
    }

    private func drawSymbolState(name: String, color: NSColor) {
        guard !isSpectrumDismissing,
              presentationMode != .compact else {
            return
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .semibold
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: status.title
        )?.withSymbolConfiguration(configuration) else {
            return
        }

        image.draw(
            in: NSRect(
                x: cardRect.midX - image.size.width / 2,
                y: cardRect.midY - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
        )
    }
}
