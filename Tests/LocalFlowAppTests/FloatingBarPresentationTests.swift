import AppKit
import LocalFlowCore
import XCTest
@testable import LocalFlowApp

final class FloatingBarPresentationTests: XCTestCase {
    func testWritingModesCycleWithoutDeadEnd() {
        XCTAssertEqual(DictationOutputMode.transcript.next, .polish)
        XCTAssertEqual(DictationOutputMode.polish.next, .prompt)
        XCTAssertEqual(DictationOutputMode.prompt.next, .transcript)
    }

    func testModeControlStaysBetweenSpectrumAndTimer() {
        let cardRect = NSRect(x: 6, y: 5, width: 292, height: 54)
        let modeRect = FloatingBarModeControlLayout.modeRect(in: cardRect)
        let timerRect = FloatingBarModeControlLayout.timerRect(in: cardRect)

        XCTAssertGreaterThanOrEqual(modeRect.minX, cardRect.minX)
        XCTAssertLessThan(modeRect.maxX, timerRect.minX)
        XCTAssertLessThanOrEqual(timerRect.maxX, cardRect.maxX)
        XCTAssertEqual(modeRect.height, timerRect.height)
    }

    func testModeControlClickChangesTheActiveMode() {
        XCTAssertTrue(Thread.isMainThread)
        AppKitMainThreadBridge.run {
            let view = FloatingBarView(
                frame: NSRect(
                    origin: .zero,
                    size: FloatingBarController.panelSize
                )
            )
            view.update(
                status: .recording(2, .toggle),
                visualization: .silent,
                reduceMotion: true
            )
            var selectedMode: DictationOutputMode?
            view.onOutputModeChange = { selectedMode = $0 }

            let cardRect = view.bounds.insetBy(dx: 6, dy: 5)
            let modeRect = FloatingBarModeControlLayout.modeRect(
                in: cardRect
            )
            let clickPoint = NSPoint(
                x: modeRect.midX,
                y: modeRect.midY
            )
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: clickPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )

            if let event {
                view.mouseDown(with: event)
            }

            XCTAssertEqual(selectedMode, .polish)
        }
    }

    func testEveryOrbProducesADistinctBarAtmosphere() {
        let palettes = OrbEvolution.themes.map(FloatingBarPalette.init)
        let signatures = Set(
            palettes.map {
                [
                    $0.backgroundTop.red,
                    $0.backgroundTop.green,
                    $0.backgroundTop.blue,
                    $0.backgroundBottom.red,
                    $0.backgroundBottom.green,
                    $0.backgroundBottom.blue
                ]
                .map(String.init)
                .joined(separator: "-")
            }
        )

        XCTAssertEqual(signatures.count, OrbEvolution.themes.count)
    }

    func testSpectrumGradientUsesTheCurrentOrbPalette() {
        for theme in OrbEvolution.themes {
            let palette = FloatingBarPalette(theme: theme)
            let center = palette.spectrumColor(at: 0)
            let edge = palette.spectrumColor(at: 1)

            XCTAssertEqual(center.red, theme.highlight.red, accuracy: 0.000_1)
            XCTAssertEqual(center.green, theme.highlight.green, accuracy: 0.000_1)
            XCTAssertEqual(center.blue, theme.highlight.blue, accuracy: 0.000_1)
            XCTAssertEqual(edge.red, theme.secondary.red, accuracy: 0.000_1)
            XCTAssertEqual(edge.green, theme.secondary.green, accuracy: 0.000_1)
            XCTAssertEqual(edge.blue, theme.secondary.blue, accuracy: 0.000_1)
        }
    }

    func testSpectrumPresenceUsesResponsiveButStableTiming() {
        let reveal = FloatingBarSpectrumTransition.make(
            presented: true,
            reduceMotion: false
        )
        let dismiss = FloatingBarSpectrumTransition.make(
            presented: false,
            reduceMotion: false
        )

        XCTAssertEqual(reveal.targetOpacity, 1)
        XCTAssertEqual(reveal.curve, .easeOut)
        XCTAssertGreaterThanOrEqual(reveal.duration, 0.15)
        XCTAssertLessThanOrEqual(reveal.duration, 0.3)

        XCTAssertEqual(dismiss.targetOpacity, 0)
        XCTAssertEqual(dismiss.curve, .easeIn)
        XCTAssertGreaterThan(dismiss.duration, reveal.duration)
        XCTAssertLessThanOrEqual(dismiss.duration, 0.3)
    }

    func testReducedMotionMakesSpectrumPresenceImmediate() {
        XCTAssertEqual(
            FloatingBarSpectrumTransition.make(
                presented: true,
                reduceMotion: true
            ).duration,
            0
        )
        XCTAssertEqual(
            FloatingBarSpectrumTransition.make(
                presented: false,
                reduceMotion: true
            ).duration,
            0
        )
    }

    func testSpectrumSoftGateDoesNotFlashAroundTheOldCutoff() {
        let below = FloatingBarSpectrumBarPresentation.make(value: 0.017)
        let above = FloatingBarSpectrumBarPresentation.make(value: 0.019)

        XCTAssertGreaterThan(below.amplitude, 0)
        XCTAssertGreaterThan(below.alpha, 0)
        XCTAssertGreaterThan(above.amplitude, below.amplitude)
        XCTAssertGreaterThan(above.alpha, below.alpha)
        XCTAssertLessThan(above.alpha - below.alpha, 0.12)
    }

    func testBriefSilenceKeepsEnoughVisualEnergyToAvoidAFlash() {
        var value: Float = 0.6
        for _ in 0..<5 {
            value = FloatingBarEnvelopeMotion.advanceEnvelope(
                current: value,
                target: 0
            )
        }

        XCTAssertGreaterThan(value, 0.2)
    }

    func testSpectrumSoftGateIsMonotonic() {
        let samples = stride(
            from: CGFloat(0),
            through: CGFloat(0.08),
            by: CGFloat(0.002)
        ).map {
            FloatingBarSpectrumBarPresentation.make(value: $0)
        }

        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.1.amplitude,
                pair.0.amplitude
            )
            XCTAssertGreaterThanOrEqual(pair.1.alpha, pair.0.alpha)
        }
    }

    func testAppKitCallbacksEnterWithoutActorExecutorThunk() {
        XCTAssertTrue(Thread.isMainThread)
        AppKitMainThreadBridge.run {
            let view = FloatingBarView(
                frame: NSRect(
                    origin: .zero,
                    size: FloatingBarController.panelSize
                )
            )
            let mouseEvent = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: 24, y: 28),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 0,
                pressure: 0
            )

            XCTAssertNotNil(mouseEvent)

            _ = view.perform(#selector(NSView.layout))
            _ = view.perform(#selector(NSView.updateTrackingAreas))
            XCTAssertEqual(view.trackingAreas.count, 1)

            if let mouseEvent {
                _ = view.perform(
                    #selector(NSResponder.mouseEntered(with:)),
                    with: mouseEvent
                )
                _ = view.perform(
                    #selector(NSResponder.mouseMoved(with:)),
                    with: mouseEvent
                )
                _ = view.perform(
                    #selector(NSResponder.mouseExited(with:)),
                    with: mouseEvent
                )
            }

            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width),
                pixelsHigh: Int(view.bounds.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            XCTAssertNotNil(bitmap)

            if let bitmap,
               let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphicsContext
                let selector = #selector(NSView.draw(_:))
                typealias ObjectiveCDraw = @convention(c) (
                    AnyObject,
                    Selector,
                    NSRect
                ) -> Void
                let objectiveCDraw = unsafeBitCast(
                    view.method(for: selector),
                    to: ObjectiveCDraw.self
                )
                objectiveCDraw(view, selector, view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
