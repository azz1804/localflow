import CoreGraphics
import Foundation

struct LiquidOrbSparkleSample {
    var position: CGPoint
    var opacity: CGFloat
    var scale: CGFloat
    var warmth: CGFloat
}

struct LiquidOrbMotionSample {
    var cyan: CGPoint
    var violet: CGPoint
    var magenta: CGPoint
    var gold: CGPoint
    var oil: CGPoint
    var pearl: CGPoint
    var highlight: CGPoint
    var tilt: CGSize
    var cursor: CGPoint
    var cursorVelocity: CGSize
    var cursorPressure: CGFloat
    var interactionStrength: CGFloat
    var energy: CGFloat
    var turbulence: CGFloat
    var flowAngle: CGFloat
    var phase: CGFloat
    var sparkles: [LiquidOrbSparkleSample]
}

enum LiquidOrbMotion {
    static func sample(
        time: TimeInterval,
        pointer: CGPoint?,
        energy: CGFloat = 0,
        interactionStrength explicitInteractionStrength: CGFloat? = nil,
        pointerVelocity: CGSize = .zero
    ) -> LiquidOrbMotionSample {
        let clampedEnergy = max(0, min(1, energy))
        let pointer = pointer.map {
            CGPoint(
                x: max(0, min(1, $0.x)),
                y: max(0, min(1, $0.y))
            )
        }
        let interactionStrength = max(
            0,
            min(
                1,
                explicitInteractionStrength ?? (pointer == nil ? 0 : 1)
            )
        )
        let attraction = CGPoint(
            x: ((pointer?.x ?? 0.5) - 0.5) * interactionStrength,
            y: ((pointer?.y ?? 0.5) - 0.5) * interactionStrength
        )
        let cursor = pointer ?? CGPoint(x: 0.5, y: 0.5)
        let clampedVelocity = CGSize(
            width: max(-4, min(4, pointerVelocity.width))
                * interactionStrength,
            height: max(-4, min(4, pointerVelocity.height))
                * interactionStrength
        )
        let cursorPressure = min(
            1,
            hypot((cursor.x - 0.5) * 2, (cursor.y - 0.5) * 2)
        ) * interactionStrength
        let turbulence = min(
            1,
            0.12 + interactionStrength * 0.52 + clampedEnergy * 0.58
        )
        let activeAmplitude = 1 + interactionStrength * 0.42
            + clampedEnergy * 0.18
        // Keep phase continuous when hover or audio energy changes. Scaling an
        // absolute clock by live input makes the phase jump to a new point.
        let fluidTime = time

        func point(
            centerX: CGFloat,
            centerY: CGFloat,
            xFrequency: Double,
            yFrequency: Double,
            xPhase: Double,
            yPhase: Double,
            xAmplitude: CGFloat,
            yAmplitude: CGFloat,
            attractionX: CGFloat,
            attractionY: CGFloat
        ) -> CGPoint {
            CGPoint(
                x: clamp(
                    centerX
                        + CGFloat(sin(fluidTime * xFrequency + xPhase))
                            * xAmplitude * activeAmplitude
                        + attraction.x * attractionX
                ),
                y: clamp(
                    centerY
                        + CGFloat(cos(fluidTime * yFrequency + yPhase))
                            * yAmplitude * activeAmplitude
                        + attraction.y * attractionY
                )
            )
        }

        let sparkles = (0..<12).map { index in
            let value = Double(index)
            let baseX = fractionalPart(0.17 + value * 0.618_033_988_75)
            let baseY = fractionalPart(0.31 + value * 0.414_213_562_37)
            let orbit = 0.018 + turbulence * 0.025
            let phase = value * 1.73
            let x = clamp(
                CGFloat(baseX)
                    + CGFloat(
                        sin(
                            fluidTime * (0.62 + value.truncatingRemainder(
                                dividingBy: 3
                            ) * 0.075) + phase
                        )
                    ) * orbit
                    + attraction.x * (0.035 + CGFloat(index % 3) * 0.018)
            )
            let y = clamp(
                CGFloat(baseY)
                    + CGFloat(
                        cos(
                            fluidTime * (0.55 + value.truncatingRemainder(
                                dividingBy: 4
                            ) * 0.06) + phase * 0.83
                        )
                    ) * orbit
                    + attraction.y * (0.04 + CGFloat(index % 2) * 0.025)
            )
            let shimmer = 0.5 + 0.5 * CGFloat(
                sin(fluidTime * (1.55 + value * 0.04) + phase * 2.2)
            )

            return LiquidOrbSparkleSample(
                position: CGPoint(x: x, y: y),
                opacity: 0.16 + shimmer * (0.5 + turbulence * 0.18),
                scale: 0.52 + CGFloat(index % 4) * 0.12
                    + shimmer * 0.28,
                warmth: CGFloat(index % 5) / 4
            )
        }

        return LiquidOrbMotionSample(
            cyan: point(
                centerX: 0.7,
                centerY: 0.3,
                xFrequency: 1.18,
                yFrequency: 0.98,
                xPhase: 0.2,
                yPhase: 0.8,
                xAmplitude: 0.16,
                yAmplitude: 0.17,
                attractionX: 0.28,
                attractionY: 0.24
            ),
            violet: point(
                centerX: 0.34,
                centerY: 0.66,
                xFrequency: 0.92,
                yFrequency: 1.12,
                xPhase: 2.1,
                yPhase: 1.3,
                xAmplitude: 0.18,
                yAmplitude: 0.15,
                attractionX: 0.2,
                attractionY: 0.27
            ),
            magenta: point(
                centerX: 0.28,
                centerY: 0.3,
                xFrequency: 1.06,
                yFrequency: 0.9,
                xPhase: 4.2,
                yPhase: 2.8,
                xAmplitude: 0.15,
                yAmplitude: 0.18,
                attractionX: 0.34,
                attractionY: 0.2
            ),
            gold: point(
                centerX: 0.7,
                centerY: 0.73,
                xFrequency: 0.88,
                yFrequency: 1,
                xPhase: 1.7,
                yPhase: 4.1,
                xAmplitude: 0.13,
                yAmplitude: 0.12,
                attractionX: 0.22,
                attractionY: 0.3
            ),
            oil: point(
                centerX: 0.45,
                centerY: 0.52,
                xFrequency: 0.66,
                yFrequency: 0.72,
                xPhase: 3.3,
                yPhase: 1.5,
                xAmplitude: 0.2,
                yAmplitude: 0.16,
                attractionX: 0.42,
                attractionY: 0.38
            ),
            pearl: point(
                centerX: 0.58,
                centerY: 0.43,
                xFrequency: 0.84,
                yFrequency: 0.7,
                xPhase: 5.1,
                yPhase: 4.6,
                xAmplitude: 0.12,
                yAmplitude: 0.13,
                attractionX: 0.16,
                attractionY: 0.2
            ),
            highlight: point(
                centerX: 0.32,
                centerY: 0.23,
                xFrequency: 0.76,
                yFrequency: 0.82,
                xPhase: 0.4,
                yPhase: 0.2,
                xAmplitude: 0.07,
                yAmplitude: 0.06,
                attractionX: 0.12,
                attractionY: 0.1
            ),
            tilt: CGSize(
                width: attraction.x * 2,
                height: attraction.y * 2
            ),
            cursor: cursor,
            cursorVelocity: clampedVelocity,
            cursorPressure: cursorPressure,
            interactionStrength: interactionStrength,
            energy: clampedEnergy,
            turbulence: turbulence,
            flowAngle: CGFloat(sin(fluidTime * 0.54)) * 16
                + attraction.x * 24
                - attraction.y * 14,
            phase: CGFloat(fluidTime),
            sparkles: sparkles
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        max(0.05, min(0.95, value))
    }

    private static func fractionalPart(_ value: Double) -> Double {
        value - floor(value)
    }
}

enum LiquidOrbGeometry {
    static func blobPath(
        in rect: CGRect,
        motion: LiquidOrbMotionSample,
        detail: Int = 64
    ) -> CGPath {
        let pointCount = max(24, detail)
        let center = CGPoint(
            x: rect.midX + motion.tilt.width * rect.width * 0.018,
            y: rect.midY + motion.tilt.height * rect.height * 0.018
        )
        let supportsFineDeformation = rect.width >= 64
        let baseRadius = min(rect.width, rect.height) * (
            supportsFineDeformation ? 0.425 : 0.455
        )
        let phase = motion.phase
        let widthScale = 1
            + sin(phase * 0.9) * 0.018
            + motion.tilt.width * 0.014
        let heightScale = 1
            + cos(phase * 0.78) * 0.02
            - motion.tilt.height * 0.014
        let cursorVector = CGPoint(
            x: (motion.cursor.x - 0.5) * 2,
            y: (motion.cursor.y - 0.5) * 2
        )
        let cursorAngle = atan2(cursorVector.y, cursorVector.x)
        let velocityMagnitude = min(
            1,
            hypot(
                motion.cursorVelocity.width,
                motion.cursorVelocity.height
            ) / 2.5
        )
        let malleability: CGFloat = supportsFineDeformation ? 0.075 : 0.025
        let deformation = motion.interactionStrength * malleability * (
            motion.cursorPressure * 0.88 + velocityMagnitude * 0.12
        )
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)

        for index in 0..<pointCount {
            let progress = CGFloat(index) / CGFloat(pointCount)
            let angle = progress * .pi * 2
            let broadLobes = sin(angle * 3 + phase * 0.96) * (
                (supportsFineDeformation ? 0.012 : 0.019)
                    + motion.energy * 0.012
            )
            let mediumLobes = cos(angle * 5 - phase * 0.72) * (
                (supportsFineDeformation ? 0.006 : 0.011)
                    + motion.energy * 0.005
            )
            let membraneRipple = sin(angle * 11 + phase * 1.22)
                * (
                    supportsFineDeformation
                        ? 0.0015 + motion.turbulence * 0.0015
                        : 0.006 + motion.turbulence * 0.004
                )
            let pulse = sin(phase * 1.18 + angle * 2) * (
                supportsFineDeformation ? 0.004 : 0.006
            )
            let cursorDelta = atan2(
                sin(angle - cursorAngle),
                cos(angle - cursorAngle)
            )
            let cursorInfluence = exp(
                -(cursorDelta * cursorDelta) / (2 * 0.62 * 0.62)
            )
            let oppositeDelta = atan2(
                sin(angle - cursorAngle - .pi),
                cos(angle - cursorAngle - .pi)
            )
            let oppositeInfluence = exp(
                -(oppositeDelta * oppositeDelta) / (2 * 0.85 * 0.85)
            )
            let radialDeformation = cursorInfluence * deformation
                - oppositeInfluence * deformation * 0.28
            let radius = baseRadius * (
                1 + broadLobes + mediumLobes + membraneRipple + pulse
                    + radialDeformation
            )
            let tangent = CGPoint(x: -sin(angle), y: cos(angle))
            let tangentialVelocity = motion.cursorVelocity.width * tangent.x
                + motion.cursorVelocity.height * tangent.y
            let drag = supportsFineDeformation
                ? max(-1, min(1, tangentialVelocity / 2.5))
                    * cursorInfluence * baseRadius * 0.025
                : 0
            points.append(
                CGPoint(
                    x: center.x + cos(angle) * radius * widthScale
                        + tangent.x * drag,
                    y: center.y + sin(angle) * radius * heightScale
                        + tangent.y * drag
                )
            )
        }

        return smoothClosedPath(points)
    }

    static func strandPath(
        in rect: CGRect,
        index: Int,
        motion: LiquidOrbMotionSample
    ) -> CGPath {
        let strandCount = 6
        let boundedIndex = max(0, min(strandCount - 1, index))
        let normalized = CGFloat(boundedIndex) / CGFloat(strandCount - 1)
            * 2 - 1
        let phase = motion.phase
        let sway = sin(
            phase * (0.62 + CGFloat(boundedIndex) * 0.035)
                + CGFloat(boundedIndex) * 1.27
        )
        let counterSway = cos(
            phase * 0.48 + CGFloat(boundedIndex) * 0.91
        )
        let topY = rect.minY + rect.height * (0.07 + abs(normalized) * 0.025)
        let bottomY = rect.maxY
            - rect.height * (0.06 + abs(normalized) * 0.035)
        let fieldShift = sin(phase * 0.34) * rect.width * 0.18
            * (1 - abs(normalized) * 0.24)
            + motion.tilt.width * rect.width * 0.1
            + max(-1, min(1, motion.cursorVelocity.width / 3))
                * rect.width * 0.025
        let verticalDrag = motion.tilt.height * rect.height * 0.035
            + max(-1, min(1, motion.cursorVelocity.height / 3))
                * rect.height * 0.018
        let startX = rect.midX
            + normalized * rect.width * 0.3
            + sway * rect.width * 0.055
            + fieldShift
        let endX = rect.midX
            + normalized * rect.width * 0.33
            + counterSway * rect.width * 0.05
            + fieldShift * 0.82
        let side: CGFloat = normalized >= 0 ? 1 : -1
        let alternating: CGFloat = boundedIndex.isMultiple(of: 2) ? 1 : -1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: topY))
        path.addCurve(
            to: CGPoint(x: endX, y: bottomY),
            control1: CGPoint(
                x: startX
                    + side * rect.width * (
                        0.12 + abs(normalized) * 0.07
                    ),
                y: rect.minY + rect.height * 0.34 + verticalDrag
            ),
            control2: CGPoint(
                x: endX
                    - side * rect.width * 0.1
                    + alternating * rect.width * 0.035,
                y: rect.minY + rect.height * 0.72 + verticalDrag * 0.72
            )
        )
        return path
    }

    private static func smoothClosedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first,
              let last = points.last else {
            return path
        }

        path.move(to: midpoint(last, first))
        for index in points.indices {
            let point = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(
                to: midpoint(point, next),
                control: point
            )
        }
        path.closeSubpath()
        return path
    }

    private static func midpoint(
        _ first: CGPoint,
        _ second: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2
        )
    }
}
