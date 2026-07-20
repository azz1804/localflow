import CoreGraphics
import XCTest
@testable import LocalFlowApp

final class LiquidOrbMotionTests: XCTestCase {
    func testPointerPullsLiquidFieldTowardInteraction() {
        let passive = LiquidOrbMotion.sample(
            time: 1.2,
            pointer: nil
        )
        let interactive = LiquidOrbMotion.sample(
            time: 1.2,
            pointer: CGPoint(x: 1, y: 1)
        )

        XCTAssertEqual(passive.interactionStrength, 0)
        XCTAssertEqual(interactive.interactionStrength, 1)
        XCTAssertGreaterThan(interactive.cyan.x, passive.cyan.x)
        XCTAssertGreaterThan(interactive.cyan.y, passive.cyan.y)
        XCTAssertGreaterThan(interactive.tilt.width, 0)
        XCTAssertGreaterThan(interactive.tilt.height, 0)
    }

    func testLiquidFieldAlwaysStaysInsideOrb() {
        let sample = LiquidOrbMotion.sample(
            time: 10_000,
            pointer: CGPoint(x: 0, y: 1),
            energy: 1
        )
        let points = [
            sample.cyan,
            sample.violet,
            sample.magenta,
            sample.gold,
            sample.oil,
            sample.pearl,
            sample.highlight
        ] + sample.sparkles.map(\.position)

        for point in points {
            XCTAssertTrue((0.05...0.95).contains(point.x))
            XCTAssertTrue((0.05...0.95).contains(point.y))
        }
    }

    func testLiquidMaterialAddsBoundedGlitterAndEnergy() {
        let passive = LiquidOrbMotion.sample(
            time: 3.4,
            pointer: nil,
            energy: 0
        )
        let energized = LiquidOrbMotion.sample(
            time: 3.4,
            pointer: CGPoint(x: 0.2, y: 0.8),
            energy: 1
        )

        XCTAssertEqual(passive.sparkles.count, 12)
        XCTAssertEqual(energized.sparkles.count, 12)
        XCTAssertEqual(passive.energy, 0)
        XCTAssertEqual(energized.energy, 1)
        XCTAssertGreaterThan(energized.turbulence, passive.turbulence)

        for sparkle in energized.sparkles {
            XCTAssertTrue((0...1).contains(sparkle.opacity))
            XCTAssertGreaterThan(sparkle.scale, 0)
            XCTAssertTrue((0...1).contains(sparkle.warmth))
        }
    }

    func testLivingLiquidFieldsTravelContinuouslyOverTime() {
        let first = LiquidOrbMotion.sample(
            time: 10,
            pointer: nil
        )
        let next = LiquidOrbMotion.sample(
            time: 10.5,
            pointer: nil
        )
        let travel = hypot(
            next.violet.x - first.violet.x,
            next.violet.y - first.violet.y
        ) + hypot(
            next.magenta.x - first.magenta.x,
            next.magenta.y - first.magenta.y
        )

        XCTAssertGreaterThan(travel, 0.05)
        XCTAssertEqual(next.phase - first.phase, 0.5, accuracy: 0.000_1)
    }

    func testReferenceOrbGeometryStaysInsideItsCanvas() {
        let motion = LiquidOrbMotion.sample(
            time: 42,
            pointer: CGPoint(x: 1, y: 0),
            energy: 1
        )
        let canvas = CGRect(x: 5, y: 5, width: 102, height: 102)
        let blob = LiquidOrbGeometry.blobPath(
            in: canvas,
            motion: motion
        )
        let bounds = blob.boundingBoxOfPath

        XCTAssertGreaterThanOrEqual(bounds.minX, canvas.minX)
        XCTAssertGreaterThanOrEqual(bounds.minY, canvas.minY)
        XCTAssertLessThanOrEqual(bounds.maxX, canvas.maxX)
        XCTAssertLessThanOrEqual(bounds.maxY, canvas.maxY)

        for index in 0..<6 {
            let strand = LiquidOrbGeometry.strandPath(
                in: canvas,
                index: index,
                motion: motion
            )
            XCTAssertFalse(strand.isEmpty)
        }
    }

    func testHoverAndEnergyNeverResetTheAnimationPhase() {
        let time: TimeInterval = 752_431_908.25
        let passive = LiquidOrbMotion.sample(
            time: time,
            pointer: CGPoint(x: 0.5, y: 0.5),
            interactionStrength: 0
        )
        let hovered = LiquidOrbMotion.sample(
            time: time,
            pointer: CGPoint(x: 0.9, y: 0.2),
            energy: 1,
            interactionStrength: 1
        )

        XCTAssertEqual(passive.phase, hovered.phase, accuracy: 0.000_1)
    }

    func testHoverInteractionEasesInAndOutWithoutJumping() {
        var hover = OrbHoverInteraction()
        hover.setActive(
            true,
            pointer: CGPoint(x: 0.8, y: 0.2),
            at: 100
        )

        XCTAssertEqual(hover.strength(at: 100), 0, accuracy: 0.000_1)
        XCTAssertTrue((0..<1).contains(hover.strength(at: 100.09)))
        XCTAssertEqual(hover.strength(at: 100.18), 1, accuracy: 0.000_1)

        hover.setActive(false, at: 100.18)

        XCTAssertEqual(hover.strength(at: 100.18), 1, accuracy: 0.000_1)
        XCTAssertTrue((0..<1).contains(hover.strength(at: 100.33)))
        XCTAssertEqual(hover.strength(at: 100.48), 0, accuracy: 0.000_1)
    }

    func testHoverInteractionCarriesAndDampsPointerMomentum() {
        var hover = OrbHoverInteraction()
        hover.setActive(
            true,
            pointer: CGPoint(x: 0.2, y: 0.5),
            at: 100
        )
        hover.setActive(
            true,
            pointer: CGPoint(x: 0.8, y: 0.5),
            at: 100.02
        )

        let immediate = hover.velocity(at: 100.02)
        let settled = hover.velocity(at: 100.7)

        XCTAssertGreaterThan(immediate.width, 0)
        XCTAssertEqual(immediate.height, 0, accuracy: 0.000_1)
        XCTAssertLessThan(abs(settled.width), abs(immediate.width))
    }

    func testHoverInteractionDoesNotReuseStaleMomentumOnReentry() {
        var hover = OrbHoverInteraction()
        hover.setActive(
            true,
            pointer: CGPoint(x: 0.2, y: 0.5),
            at: 100
        )
        hover.setActive(
            true,
            pointer: CGPoint(x: 0.8, y: 0.5),
            at: 100.02
        )
        hover.setActive(false, at: 100.03)
        hover.setActive(
            true,
            pointer: CGPoint(x: 0.5, y: 0.5),
            at: 101.5
        )

        XCTAssertEqual(
            hover.velocity(at: 101.5).width,
            0,
            accuracy: 0.001
        )
    }

    func testCursorLocallyDeformsTheOrbContour() {
        let rect = CGRect(x: 5, y: 5, width: 102, height: 102)
        let passive = LiquidOrbMotion.sample(
            time: 2.4,
            pointer: CGPoint(x: 1, y: 0.5),
            interactionStrength: 0
        )
        let interactive = LiquidOrbMotion.sample(
            time: 2.4,
            pointer: CGPoint(x: 1, y: 0.5),
            interactionStrength: 1,
            pointerVelocity: CGSize(width: 1.5, height: 0)
        )

        let passiveBounds = LiquidOrbGeometry.blobPath(
            in: rect,
            motion: passive,
            detail: 96
        ).boundingBoxOfPath
        let interactiveBounds = LiquidOrbGeometry.blobPath(
            in: rect,
            motion: interactive,
            detail: 96
        ).boundingBoxOfPath

        XCTAssertGreaterThan(interactiveBounds.maxX, passiveBounds.maxX)
        XCTAssertGreaterThan(interactiveBounds.minX, rect.minX)
        XCTAssertLessThan(interactiveBounds.maxX, rect.maxX)
    }

    func testSparkleGenerationCanBeSkippedForNonGalaxyThemes() {
        let sample = LiquidOrbMotion.sample(
            time: 2.4,
            pointer: nil,
            sparkleCount: 0
        )

        XCTAssertTrue(sample.sparkles.isEmpty)
    }

    func testDashboardOrbPausesInBackgroundAndBoostsOnHover() {
        let background = HubOrbAnimationCadence.make(
            isAnimationActive: false,
            isHovering: false,
            reduceMotion: false
        )
        let ambient = HubOrbAnimationCadence.make(
            isAnimationActive: true,
            isHovering: false,
            reduceMotion: false
        )
        let interactive = HubOrbAnimationCadence.make(
            isAnimationActive: true,
            isHovering: true,
            reduceMotion: false
        )

        XCTAssertTrue(background.isPaused)
        XCTAssertFalse(ambient.isPaused)
        XCTAssertEqual(ambient.minimumInterval, 1 / 15)
        XCTAssertEqual(interactive.minimumInterval, 1 / 60)
        XCTAssertLessThan(ambient.contourDetail, interactive.contourDetail)
    }
}
