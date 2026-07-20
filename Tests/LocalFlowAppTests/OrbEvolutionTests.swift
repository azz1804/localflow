import XCTest
@testable import LocalFlowApp

final class OrbEvolutionTests: XCTestCase {
    func testOrbThemesUnlockAtWordMilestones() {
        XCTAssertEqual(
            OrbEvolution.progression(forWords: 999).theme.id,
            "violet-tide"
        )
        XCTAssertEqual(
            OrbEvolution.progression(forWords: 1_000).theme.id,
            "cobalt-current"
        )
        XCTAssertEqual(
            OrbEvolution.progression(forWords: 50_000).theme.id,
            "solar-nova"
        )
        XCTAssertEqual(
            OrbEvolution.progression(forWords: 100_000).theme.id,
            "cosmic-ink"
        )
    }

    func testOrbProgressTracksCurrentMilestoneRange() {
        let progression = OrbEvolution.progression(forWords: 3_000)

        XCTAssertEqual(progression.theme.id, "cobalt-current")
        XCTAssertEqual(progression.nextTheme?.id, "rose-bloom")
        XCTAssertEqual(progression.remainingWords, 2_000)
        XCTAssertEqual(progression.progressToNext, 0.5, accuracy: 0.000_1)
    }

    func testOrbProgressClampsNegativeWordsAndCompletesMasterTier() {
        let empty = OrbEvolution.progression(forWords: -20)
        let master = OrbEvolution.progression(forWords: 250_000)

        XCTAssertEqual(empty.totalWords, 0)
        XCTAssertEqual(empty.progressToNext, 0)
        XCTAssertNil(master.nextTheme)
        XCTAssertEqual(master.progressToNext, 1)
        XCTAssertEqual(master.progressLabel, "Master orb unlocked")
    }

    func testEveryOrbTierHasItsOwnPaletteAndMotionSignature() {
        let paletteSignatures = Set(
            OrbEvolution.themes.map {
                "\($0.primary.red)-\($0.primary.green)-\($0.primary.blue)"
            }
        )
        let motionSpeeds = Set(
            OrbEvolution.themes.map(\.motionSpeed)
        )
        let materials = Set(
            OrbEvolution.themes.map(\.material)
        )

        XCTAssertEqual(
            paletteSignatures.count,
            OrbEvolution.themes.count
        )
        XCTAssertEqual(
            motionSpeeds.count,
            OrbEvolution.themes.count
        )
        XCTAssertEqual(
            materials.count,
            OrbEvolution.themes.count
        )
    }

    func testAdministratorOverrideCanSelectAnyOrb() {
        let progression = OrbEvolution.progression(
            forWords: 12,
            overrideID: "solar-nova"
        )

        XCTAssertEqual(progression.theme.id, "solar-nova")
        XCTAssertEqual(progression.theme.material, .lava)
        XCTAssertTrue(progression.isAdministratorOverride)
        XCTAssertEqual(
            progression.progressLabel,
            "Administrator override · Lava"
        )
    }
}
