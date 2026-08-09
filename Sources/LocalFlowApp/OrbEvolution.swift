import AppKit
import SwiftUI

struct OrbRGBA: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    func nsColor(alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

enum OrbMaterial: String, CaseIterable, Equatable, Hashable, Sendable {
    case water
    case wind
    case earth
    case aurora
    case lava
    case galaxy
    case ice
    case plasma
    case prism
    case eclipse

    var name: String {
        rawValue.capitalized
    }

    var symbol: String {
        switch self {
        case .water:
            return "drop.fill"
        case .wind:
            return "wind"
        case .earth:
            return "mountain.2.fill"
        case .aurora:
            return "wave.3.right"
        case .lava:
            return "flame.fill"
        case .galaxy:
            return "sparkles"
        case .ice:
            return "snowflake"
        case .plasma:
            return "bolt.fill"
        case .prism:
            return "triangle.fill"
        case .eclipse:
            return "circle.lefthalf.filled"
        }
    }

    var tagline: String {
        switch self {
        case .water:
            return "Caustics, bubbles, and liquid refraction"
        case .wind:
            return "Fast ribbons and suspended particles"
        case .earth:
            return "Mineral strata and drifting sediment"
        case .aurora:
            return "Luminous veils and magnetic currents"
        case .lava:
            return "Dark crust and incandescent veins"
        case .galaxy:
            return "Spiral matter and stellar dust"
        case .ice:
            return "Frozen light and slow crystalline currents"
        case .plasma:
            return "Electric filaments and charged color"
        case .prism:
            return "Refracted light and spectral ribbons"
        case .eclipse:
            return "Dark gravity and a molten solar rim"
        }
    }
}

struct OrbTheme: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var unlockWords: Int
    var material: OrbMaterial
    var baseDark: OrbRGBA
    var primary: OrbRGBA
    var secondary: OrbRGBA
    var accent: OrbRGBA
    var highlight: OrbRGBA
    var rim: OrbRGBA
    var motionSpeed: Double
    var breathingAmplitude: CGFloat
    var fieldScale: CGFloat
    var sparkleCount: Int
}

struct OrbProgression: Equatable, Sendable {
    var theme: OrbTheme
    var nextTheme: OrbTheme?
    var totalWords: Int
    var progressToNext: CGFloat
    var isAdministratorOverride: Bool

    var remainingWords: Int {
        max(0, (nextTheme?.unlockWords ?? totalWords) - totalWords)
    }

    var progressLabel: String {
        if isAdministratorOverride {
            return "Administrator override · \(theme.material.name)"
        }
        guard let nextTheme else {
            return "Master orb unlocked"
        }
        return "\(OrbEvolution.compact(remainingWords)) words to \(nextTheme.name)"
    }
}

enum OrbEvolution {
    static let brandTheme = OrbTheme(
        id: "violet-tide",
        name: "Violet Tide",
        unlockWords: 0,
        material: .water,
        baseDark: OrbRGBA(red: 0.025, green: 0.008, blue: 0.13),
        primary: OrbRGBA(red: 0.34, green: 0.1, blue: 0.9),
        secondary: OrbRGBA(red: 0.66, green: 0.24, blue: 1),
        accent: OrbRGBA(red: 0.96, green: 0.22, blue: 0.74),
        highlight: OrbRGBA(red: 0.78, green: 0.68, blue: 1),
        rim: OrbRGBA(red: 0.5, green: 0.28, blue: 0.96),
        motionSpeed: 1,
        breathingAmplitude: 0.013,
        fieldScale: 1,
        sparkleCount: 4
    )

    static let themes: [OrbTheme] = [
        brandTheme,
        OrbTheme(
            id: "cobalt-current",
            name: "Cobalt Current",
            unlockWords: 1_000,
            material: .wind,
            baseDark: OrbRGBA(red: 0.005, green: 0.025, blue: 0.14),
            primary: OrbRGBA(red: 0.04, green: 0.24, blue: 0.88),
            secondary: OrbRGBA(red: 0.12, green: 0.58, blue: 1),
            accent: OrbRGBA(red: 0.24, green: 0.86, blue: 1),
            highlight: OrbRGBA(red: 0.58, green: 0.84, blue: 1),
            rim: OrbRGBA(red: 0.14, green: 0.48, blue: 0.96),
            motionSpeed: 1.14,
            breathingAmplitude: 0.01,
            fieldScale: 0.92,
            sparkleCount: 3
        ),
        OrbTheme(
            id: "rose-bloom",
            name: "Rose Bloom",
            unlockWords: 5_000,
            material: .earth,
            baseDark: OrbRGBA(red: 0.09, green: 0.035, blue: 0.012),
            primary: OrbRGBA(red: 0.42, green: 0.18, blue: 0.045),
            secondary: OrbRGBA(red: 0.72, green: 0.4, blue: 0.1),
            accent: OrbRGBA(red: 0.32, green: 0.58, blue: 0.2),
            highlight: OrbRGBA(red: 0.9, green: 0.7, blue: 0.34),
            rim: OrbRGBA(red: 0.58, green: 0.36, blue: 0.12),
            motionSpeed: 0.88,
            breathingAmplitude: 0.018,
            fieldScale: 1.14,
            sparkleCount: 6
        ),
        OrbTheme(
            id: "aurora-veil",
            name: "Aurora Veil",
            unlockWords: 20_000,
            material: .aurora,
            baseDark: OrbRGBA(red: 0.005, green: 0.08, blue: 0.1),
            primary: OrbRGBA(red: 0.02, green: 0.48, blue: 0.48),
            secondary: OrbRGBA(red: 0.1, green: 0.86, blue: 0.66),
            accent: OrbRGBA(red: 0.44, green: 0.3, blue: 1),
            highlight: OrbRGBA(red: 0.52, green: 1, blue: 0.82),
            rim: OrbRGBA(red: 0.08, green: 0.7, blue: 0.6),
            motionSpeed: 1.06,
            breathingAmplitude: 0.014,
            fieldScale: 1.08,
            sparkleCount: 8
        ),
        OrbTheme(
            id: "solar-nova",
            name: "Solar Nova",
            unlockWords: 50_000,
            material: .lava,
            baseDark: OrbRGBA(red: 0.12, green: 0.025, blue: 0.015),
            primary: OrbRGBA(red: 0.82, green: 0.18, blue: 0.04),
            secondary: OrbRGBA(red: 1, green: 0.48, blue: 0.06),
            accent: OrbRGBA(red: 1, green: 0.78, blue: 0.2),
            highlight: OrbRGBA(red: 1, green: 0.9, blue: 0.52),
            rim: OrbRGBA(red: 0.96, green: 0.42, blue: 0.08),
            motionSpeed: 1.18,
            breathingAmplitude: 0.011,
            fieldScale: 0.86,
            sparkleCount: 10
        ),
        OrbTheme(
            id: "cosmic-ink",
            name: "Cosmic Ink",
            unlockWords: 100_000,
            material: .galaxy,
            baseDark: OrbRGBA(red: 0.004, green: 0.006, blue: 0.025),
            primary: OrbRGBA(red: 0.08, green: 0.1, blue: 0.28),
            secondary: OrbRGBA(red: 0.28, green: 0.3, blue: 0.68),
            accent: OrbRGBA(red: 0.64, green: 0.4, blue: 0.96),
            highlight: OrbRGBA(red: 0.7, green: 0.78, blue: 1),
            rim: OrbRGBA(red: 0.26, green: 0.3, blue: 0.68),
            motionSpeed: 0.82,
            breathingAmplitude: 0.008,
            fieldScale: 1.2,
            sparkleCount: 12
        ),
        OrbTheme(
            id: "glacier-heart",
            name: "Glacier Heart",
            unlockWords: 180_000,
            material: .ice,
            baseDark: OrbRGBA(red: 0.008, green: 0.04, blue: 0.09),
            primary: OrbRGBA(red: 0.08, green: 0.46, blue: 0.72),
            secondary: OrbRGBA(red: 0.32, green: 0.84, blue: 0.96),
            accent: OrbRGBA(red: 0.54, green: 0.62, blue: 1),
            highlight: OrbRGBA(red: 0.86, green: 0.98, blue: 1),
            rim: OrbRGBA(red: 0.42, green: 0.78, blue: 0.96),
            motionSpeed: 0.76,
            breathingAmplitude: 0.007,
            fieldScale: 1.26,
            sparkleCount: 5
        ),
        OrbTheme(
            id: "plasma-orchid",
            name: "Plasma Orchid",
            unlockWords: 300_000,
            material: .plasma,
            baseDark: OrbRGBA(red: 0.065, green: 0.004, blue: 0.11),
            primary: OrbRGBA(red: 0.5, green: 0.05, blue: 0.92),
            secondary: OrbRGBA(red: 0.12, green: 0.66, blue: 1),
            accent: OrbRGBA(red: 1, green: 0.12, blue: 0.62),
            highlight: OrbRGBA(red: 0.96, green: 0.66, blue: 1),
            rim: OrbRGBA(red: 0.74, green: 0.24, blue: 1),
            motionSpeed: 1.31,
            breathingAmplitude: 0.016,
            fieldScale: 0.88,
            sparkleCount: 7
        ),
        OrbTheme(
            id: "prismatic-dream",
            name: "Prismatic Dream",
            unlockWords: 500_000,
            material: .prism,
            baseDark: OrbRGBA(red: 0.025, green: 0.025, blue: 0.08),
            primary: OrbRGBA(red: 0.24, green: 0.72, blue: 0.9),
            secondary: OrbRGBA(red: 0.88, green: 0.38, blue: 0.94),
            accent: OrbRGBA(red: 1, green: 0.7, blue: 0.26),
            highlight: OrbRGBA(red: 0.94, green: 0.98, blue: 1),
            rim: OrbRGBA(red: 0.7, green: 0.5, blue: 1),
            motionSpeed: 0.97,
            breathingAmplitude: 0.012,
            fieldScale: 1.04,
            sparkleCount: 9
        ),
        OrbTheme(
            id: "event-horizon",
            name: "Event Horizon",
            unlockWords: 1_000_000,
            material: .eclipse,
            baseDark: OrbRGBA(red: 0.002, green: 0.002, blue: 0.008),
            primary: OrbRGBA(red: 0.08, green: 0.035, blue: 0.18),
            secondary: OrbRGBA(red: 0.62, green: 0.2, blue: 0.9),
            accent: OrbRGBA(red: 1, green: 0.38, blue: 0.08),
            highlight: OrbRGBA(red: 1, green: 0.82, blue: 0.36),
            rim: OrbRGBA(red: 0.96, green: 0.46, blue: 0.12),
            motionSpeed: 0.69,
            breathingAmplitude: 0.006,
            fieldScale: 1.34,
            sparkleCount: 14
        )
    ]

    static func progression(
        forWords words: Int,
        overrideID: String = "automatic"
    ) -> OrbProgression {
        let safeWords = max(0, words)
        if overrideID != "automatic",
           let overrideTheme = themes.first(where: { $0.id == overrideID }) {
            return OrbProgression(
                theme: overrideTheme,
                nextTheme: nil,
                totalWords: safeWords,
                progressToNext: 1,
                isAdministratorOverride: true
            )
        }
        let currentIndex = themes.lastIndex {
            safeWords >= $0.unlockWords
        } ?? 0
        let theme = themes[currentIndex]
        let nextTheme = themes.indices.contains(currentIndex + 1)
            ? themes[currentIndex + 1]
            : nil
        let progress: CGFloat

        if let nextTheme {
            let span = max(1, nextTheme.unlockWords - theme.unlockWords)
            progress = min(
                1,
                max(
                    0,
                    CGFloat(safeWords - theme.unlockWords) / CGFloat(span)
                )
            )
        } else {
            progress = 1
        }

        return OrbProgression(
            theme: theme,
            nextTheme: nextTheme,
            totalWords: safeWords,
            progressToNext: progress,
            isAdministratorOverride: false
        )
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            let formatted = Double(value) / 1_000
            return formatted.rounded() == formatted
                ? "\(Int(formatted))K"
                : String(format: "%.1fK", formatted)
        default:
            return "\(value)"
        }
    }
}
