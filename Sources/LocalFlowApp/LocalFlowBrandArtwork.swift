import AppKit
import SwiftUI

struct LocalFlowBrandOrb: View {
    var diameter: CGFloat
    var phase: TimeInterval = 8.4

    private var theme: OrbTheme {
        OrbEvolution.brandTheme
    }

    var body: some View {
        ReferenceLiquidOrbSurface(
            motion: LiquidOrbMotion.sample(
                time: phase * theme.motionSpeed,
                pointer: CGPoint(x: 0.64, y: 0.36),
                interactionStrength: 0.12,
                pointerVelocity: CGSize(width: 0.14, height: -0.08),
                sparkleCount: 0
            ),
            theme: theme,
            contourDetail: diameter >= 160 ? 128 : 64
        )
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

struct LocalFlowBrandLogo: View {
    var diameter: CGFloat

    private static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "BrandOrb",
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    @ViewBuilder
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: diameter, height: diameter)
                .accessibilityHidden(true)
        } else {
            LocalFlowBrandOrb(diameter: diameter)
        }
    }
}

struct LocalFlowCompactBrandOrb: View {
    var diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.84, green: 0.72, blue: 1),
                            Color(red: 0.55, green: 0.22, blue: 0.98),
                            Color(red: 0.32, green: 0.08, blue: 0.78)
                        ],
                        center: UnitPoint(x: 0.34, y: 0.26),
                        startRadius: 0,
                        endRadius: diameter * 0.68
                    )
                )

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.24, blue: 0.78)
                                .opacity(0.72),
                            .clear
                        ],
                        startPoint: .bottomTrailing,
                        endPoint: .center
                    )
                )
                .scaleEffect(0.86)

            Ellipse()
                .fill(.white.opacity(0.52))
                .frame(
                    width: diameter * 0.24,
                    height: diameter * 0.13
                )
                .blur(radius: max(0.5, diameter * 0.018))
                .offset(
                    x: -diameter * 0.19,
                    y: -diameter * 0.2
                )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.72),
                            Color(red: 0.72, green: 0.42, blue: 1)
                                .opacity(0.5),
                            Color(red: 0.22, green: 0.04, blue: 0.5)
                                .opacity(0.8)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(1, diameter * 0.025)
                )
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

struct LocalFlowAppIconArtwork: View {
    private let canvasSize: CGFloat = 1_024

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: canvasSize * 0.225,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.048, blue: 0.085),
                        Color(red: 0.018, green: 0.016, blue: 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            RadialGradient(
                colors: [
                    Color(red: 0.42, green: 0.16, blue: 0.98)
                        .opacity(0.24),
                    .clear
                ],
                center: UnitPoint(x: 0.52, y: 0.48),
                startRadius: 0,
                endRadius: canvasSize * 0.42
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: canvasSize * 0.225,
                    style: .continuous
                )
            )

            LocalFlowBrandOrb(
                diameter: canvasSize * 0.68,
                phase: 8.4
            )
            .shadow(
                color: Color(red: 0.45, green: 0.16, blue: 1)
                    .opacity(0.38),
                radius: 58
            )

            RoundedRectangle(
                cornerRadius: canvasSize * 0.225,
                style: .continuous
            )
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(0.19),
                        Color(red: 0.55, green: 0.28, blue: 1)
                            .opacity(0.14),
                        .white.opacity(0.045)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 5
            )
        }
        .padding(42)
        .frame(width: canvasSize, height: canvasSize)
        .background(.clear)
    }
}

struct LocalFlowCompactAppIconArtwork: View {
    private let canvasSize: CGFloat = 256

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: canvasSize * 0.225,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.055, blue: 0.105),
                        Color(red: 0.018, green: 0.016, blue: 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            LocalFlowCompactBrandOrb(diameter: canvasSize * 0.72)
                .shadow(
                    color: Color(red: 0.52, green: 0.2, blue: 1)
                        .opacity(0.48),
                    radius: canvasSize * 0.055
                )

            RoundedRectangle(
                cornerRadius: canvasSize * 0.225,
                style: .continuous
            )
            .stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(0.24),
                        Color(red: 0.58, green: 0.3, blue: 1)
                            .opacity(0.16),
                        .white.opacity(0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 2
            )
        }
        .padding(10)
        .frame(width: canvasSize, height: canvasSize)
        .background(.clear)
    }
}
