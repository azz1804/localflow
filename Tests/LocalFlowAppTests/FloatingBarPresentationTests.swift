import XCTest
@testable import LocalFlowApp

final class FloatingBarPresentationTests: XCTestCase {
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
}
