import Charts
import LocalFlowCore
import SwiftUI

struct LocalFlowHomeView: View {
    @ObservedObject var model: LocalFlowHubModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HubPageHeader(
                    eyebrow: "",
                    title: greeting,
                    subtitle: homeSubtitle
                ) {
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(HubSecondaryButtonStyle())
                    .help("Refresh")
                }

                HubRecordingHero(
                    totalWords: model.insights.totalWords,
                    orbThemeOverride: model.configuration.orbThemeOverride,
                    isAnimationActive: model.isHubAnimationActive,
                    outputMode: model.configuration.outputMode,
                    onSelectOutputMode: model.selectOutputMode
                )

                LazyVGrid(columns: columns, spacing: 12) {
                    HubMetricCard(
                        title: "Words dictated",
                        value: HubFormat.compact(model.insights.totalWords),
                        caption: "All time",
                        symbol: "textformat.abc",
                        tint: .primary.opacity(0.68)
                    )
                    HubMetricCard(
                        title: "Dictation speed",
                        value: "\(Int(model.insights.averageWordsPerMinute.rounded()))",
                        caption: "words per minute",
                        symbol: "speedometer",
                        tint: .primary.opacity(0.68)
                    )
                    HubMetricCard(
                        title: "Time saved",
                        value: HubFormat.duration(model.insights.estimatedTimeSavedSeconds),
                        caption: "vs. typing at 40 WPM",
                        symbol: "hourglass.bottomhalf.filled",
                        tint: .primary.opacity(0.68)
                    )
                    HubMetricCard(
                        title: "Current streak",
                        value: "\(model.insights.currentStreakDays)",
                        caption: model.insights.currentStreakDays == 1 ? "active day" : "active days",
                        symbol: "flame.fill",
                        tint: .primary.opacity(0.68)
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    weeklyActivity
                        .frame(maxWidth: .infinity)

                    recentActivity
                        .frame(width: 330)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 36)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:
            return "Good morning"
        case 12..<18:
            return "Good afternoon"
        default:
            return "Good evening"
        }
    }

    private var homeSubtitle: String {
        guard let last = model.historyRecords.first else {
            return "Your private voice workspace is ready."
        }
        return "\(last.targetApplication?.displayName ?? "Last dictation") · \(HubFormat.relative(last.createdAt))"
    }

    private var weeklyActivity: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice activity")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Words dictated over the last 7 days")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("View stats") {
                        model.selectedSection = .insights
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                }

                Chart(Array(model.insights.dailyStats.suffix(7))) { stat in
                    BarMark(
                        x: .value("Day", stat.date, unit: .day),
                        y: .value("Words", stat.words)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.38),
                                Color.primary.opacity(0.72)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .cornerRadius(5)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(Color.primary.opacity(0.42))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(HubPalette.border)
                        AxisValueLabel()
                            .foregroundStyle(Color.primary.opacity(0.42))
                    }
                }
                .frame(height: 180)
            }
        }
    }

    private var recentActivity: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recent activity")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button {
                        model.selectedSection = .history
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if model.historyRecords.isEmpty {
                    HubEmptyState(
                        symbol: "waveform",
                        title: "No dictations yet",
                        message: "Hold Fn and start speaking. Your recent transcripts will appear here."
                    )
                    .frame(height: 174)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.historyRecords.prefix(4)).indices, id: \.self) { index in
                            let record = model.historyRecords[index]
                            Button {
                                model.selectedHistoryID = record.id
                                model.selectedSection = .history
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.primary.opacity(0.055))
                                        Image(systemName: "waveform")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 30, height: 30)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.finalText)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(record.targetApplication?.displayName ?? "Unknown app") · \(HubFormat.relative(record.createdAt))")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)

                            if index < min(3, model.historyRecords.count - 1) {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HubRecordingHero: View {
    var totalWords: Int
    var orbThemeOverride: String
    var isAnimationActive: Bool
    var outputMode: DictationOutputMode
    var onSelectOutputMode: (DictationOutputMode) -> Void

    var body: some View {
        HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.24, green: 0.82, blue: 0.47))
                        .frame(width: 7, height: 7)
                    Text("LocalFlow is ready")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Text("Speak naturally.\nWrite beautifully.")
                    .font(.system(size: 29, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Hold Fn to talk. Release to write.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: 470, alignment: .leading)

                HubOutputModeSwitcher(
                    selection: outputMode,
                    onSelect: onSelectOutputMode
                )

                HStack(spacing: 9) {
                    HubKeycap("fn")
                    Text("talk")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))

                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 3, height: 3)

                    HubKeycap("space")
                    Text("hands-free")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))

                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 3, height: 3)

                    HubKeycap("esc")
                    Text("cancel")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }

            Spacer()

            HubOrbProgress(
                totalWords: totalWords,
                orbThemeOverride: orbThemeOverride,
                isAnimationActive: isAnimationActive
            )
                .frame(width: 174, height: 170)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(
                cornerRadius: HubRadius.hero,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(white: 0.105),
                        Color(white: 0.065)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: HubRadius.hero,
                style: .continuous
            )
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.16),
                            .white.opacity(0.055),
                            .white.opacity(0.095)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
    }
}

private struct HubOutputModeSwitcher: View {
    let selection: DictationOutputMode
    let onSelect: (DictationOutputMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredMode: DictationOutputMode?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(DictationOutputMode.allCases, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.systemSymbolName)
                            .font(.system(size: 9, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(
                        selection == mode
                            ? .white
                            : .white.opacity(0.48)
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(buttonBackground(for: mode))
                    }
                    .contentShape(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredMode = hovering ? mode : nil
                }
                .help("Use \(mode.displayName) for the next dictation")
                .accessibilityLabel("\(mode.displayName) writing mode")
                .accessibilityAddTraits(
                    selection == mode ? .isSelected : []
                )
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.22))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.085), lineWidth: 0.75)
        }
        .fixedSize()
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: selection
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: hoveredMode
        )
    }

    private func buttonBackground(
        for mode: DictationOutputMode
    ) -> AnyShapeStyle {
        if selection == mode {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        HubPalette.purple.opacity(0.72),
                        HubPalette.purple.opacity(0.38)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(
            Color.white.opacity(hoveredMode == mode ? 0.075 : 0)
        )
    }
}

private struct HubOrbProgress: View {
    var totalWords: Int
    var orbThemeOverride: String
    var isAnimationActive: Bool

    private var progression: OrbProgression {
        OrbEvolution.progression(
            forWords: totalWords,
            overrideID: orbThemeOverride
        )
    }

    var body: some View {
        VStack(spacing: 3) {
            ReferenceHubVoiceOrb(
                theme: progression.theme,
                isAnimationActive: isAnimationActive
            )

            Text(progression.theme.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))

            Text(progression.progressLabel)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.08))
                    Capsule()
                        .fill(
                            progression.theme.rim.color.opacity(0.72)
                        )
                        .frame(
                            width: proxy.size.width
                                * progression.progressToNext
                        )
                }
            }
            .frame(width: 92, height: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(progression.theme.name), \(progression.progressLabel)"
        )
    }
}

struct OrbHoverInteraction {
    var pointer = CGPoint(x: 0.5, y: 0.5)
    var targetStrength: CGFloat = 0
    private var transitionStart: TimeInterval = 0
    private var transitionFrom: CGFloat = 0
    private var storedVelocity = CGSize.zero
    private var lastPointerUpdate: TimeInterval?

    func strength(at time: TimeInterval) -> CGFloat {
        guard transitionStart > 0 else {
            return targetStrength
        }
        let duration = targetStrength > transitionFrom ? 0.18 : 0.3
        let progress = max(
            0,
            min(1, CGFloat((time - transitionStart) / duration))
        )
        let easedProgress = progress * progress * (3 - 2 * progress)
        return transitionFrom
            + (targetStrength - transitionFrom) * easedProgress
    }

    func velocity(at time: TimeInterval) -> CGSize {
        guard let lastPointerUpdate else {
            return .zero
        }
        let elapsed = max(0, time - lastPointerUpdate)
        let decay = CGFloat(exp(-elapsed * 7))
        return CGSize(
            width: storedVelocity.width * decay,
            height: storedVelocity.height * decay
        )
    }

    mutating func setActive(
        _ active: Bool,
        pointer newPointer: CGPoint? = nil,
        at time: TimeInterval
    ) {
        if let newPointer {
            if let lastPointerUpdate {
                let elapsed = time - lastPointerUpdate
                let decay = CGFloat(exp(-max(0, elapsed) * 7))
                storedVelocity = CGSize(
                    width: storedVelocity.width * decay,
                    height: storedVelocity.height * decay
                )
                if elapsed >= 0.004, elapsed <= 0.1 {
                    let rawVelocity = CGSize(
                        width: (newPointer.x - pointer.x) / elapsed,
                        height: (newPointer.y - pointer.y) / elapsed
                    )
                    storedVelocity = CGSize(
                        width: storedVelocity.width * 0.65
                            + max(-4, min(4, rawVelocity.width)) * 0.35,
                        height: storedVelocity.height * 0.65
                            + max(-4, min(4, rawVelocity.height)) * 0.35
                    )
                }
            }
            pointer = newPointer
            lastPointerUpdate = time
        }
        let newTarget: CGFloat = active ? 1 : 0
        guard newTarget != targetStrength else {
            return
        }
        transitionFrom = strength(at: time)
        transitionStart = time
        targetStrength = newTarget
    }
}

struct HubOrbAnimationCadence: Equatable {
    var minimumInterval: TimeInterval
    var isPaused: Bool
    var contourDetail: Int

    static func make(
        isAnimationActive: Bool,
        isHovering: Bool,
        reduceMotion: Bool
    ) -> HubOrbAnimationCadence {
        let isPaused = reduceMotion || !isAnimationActive
        return HubOrbAnimationCadence(
            minimumInterval: isHovering ? 1 / 60 : 1 / 15,
            isPaused: isPaused,
            contourDetail: isHovering ? 96 : 56
        )
    }
}

private struct ReferenceHubVoiceOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverInteraction = OrbHoverInteraction()
    @State private var isHovering = false
    @State private var hoverSettleTask: Task<Void, Never>?

    var theme: OrbTheme
    var isAnimationActive: Bool

    private let diameter: CGFloat = 136

    @ViewBuilder
    var body: some View {
        let cadence = HubOrbAnimationCadence.make(
            isAnimationActive: isAnimationActive,
            isHovering: isHovering,
            reduceMotion: reduceMotion
        )

        Group {
            if cadence.isPaused {
                orb(at: Date(), contourDetail: cadence.contourDetail)
            } else if isHovering {
                TimelineView(
                    .animation(minimumInterval: cadence.minimumInterval)
                ) { timeline in
                    orb(
                        at: timeline.date,
                        contourDetail: cadence.contourDetail
                    )
                }
            } else {
                TimelineView(
                    .periodic(
                        from: .now,
                        by: cadence.minimumInterval
                    )
                ) { timeline in
                    orb(
                        at: timeline.date,
                        contourDetail: cadence.contourDetail
                    )
                }
            }
        }
        .onDisappear {
            hoverSettleTask?.cancel()
        }
    }

    private func orb(
        at date: Date,
        contourDetail: Int
    ) -> some View {
        let time = date.timeIntervalSinceReferenceDate
        let motionTime = time * theme.motionSpeed
        let interactionStrength = reduceMotion
            ? hoverInteraction.targetStrength
            : hoverInteraction.strength(at: time)
        let pointerVelocity = reduceMotion
            ? CGSize.zero
            : hoverInteraction.velocity(at: time)
        let motion = LiquidOrbMotion.sample(
            time: reduceMotion ? 0 : motionTime,
            pointer: hoverInteraction.pointer,
            interactionStrength: interactionStrength,
            pointerVelocity: pointerVelocity,
            sparkleCount: theme.material == .galaxy ? 12 : 0
        )
        let breathing = reduceMotion
            ? 1
            : 1
                + sin(motionTime * 1.18)
                    * theme.breathingAmplitude * 0.7
                + sin(motionTime * 0.47 + 1.3)
                    * theme.breathingAmplitude * 0.3
                + interactionStrength * 0.012
        let drift = reduceMotion
            ? CGSize.zero
            : CGSize(
                width: sin(time * 0.42) * 0.9,
                height: cos(time * 0.36 + 0.8) * 0.75
            )

        return ReferenceLiquidOrbSurface(
            motion: motion,
            theme: theme,
            contourDetail: contourDetail
        )
        .frame(width: diameter, height: diameter)
        .scaleEffect(breathing)
        .offset(x: drift.width, y: drift.height)
        .rotation3DEffect(
            .degrees(Double(-motion.tilt.height * 3.2)),
            axis: (x: 1, y: 0, z: 0)
        )
        .rotation3DEffect(
            .degrees(Double(motion.tilt.width * 3.2)),
            axis: (x: 0, y: 1, z: 0)
        )
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                hoverSettleTask?.cancel()
                isHovering = true
                let pointer = CGPoint(
                    x: max(0, min(1, location.x / diameter)),
                    y: max(0, min(1, location.y / diameter))
                )
                hoverInteraction.setActive(
                    true,
                    pointer: pointer,
                    at: Date.timeIntervalSinceReferenceDate
                )
            case .ended:
                hoverInteraction.setActive(
                    false,
                    at: Date.timeIntervalSinceReferenceDate
                )
                hoverSettleTask?.cancel()
                hoverSettleTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else {
                        return
                    }
                    isHovering = false
                }
            }
        }
    }
}

struct ReferenceLiquidOrbSurface: View {
    var motion: LiquidOrbMotionSample
    var theme: OrbTheme
    var contourDetail: Int

    var body: some View {
        Canvas(
            opaque: false,
            colorMode: .extendedLinear,
            rendersAsynchronously: true
        ) { context, size in
            renderOrb(context: &context, size: size)
        }
    }

    private func renderOrb(
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let orbRect = CGRect(origin: .zero, size: size)
            .insetBy(dx: 4.5, dy: 4.5)
        let blob = Path(
            LiquidOrbGeometry.blobPath(
                in: orbRect,
                motion: motion,
                detail: contourDetail
            )
        )
        let cursorOffset = CGPoint(
            x: (motion.cursor.x - 0.5) * motion.interactionStrength,
            y: (motion.cursor.y - 0.5) * motion.interactionStrength
        )
        let velocityOffset = CGSize(
            width: max(-1, min(1, motion.cursorVelocity.width / 3)),
            height: max(-1, min(1, motion.cursorVelocity.height / 3))
        )
        let coreCenter = CGPoint(
            x: orbRect.midX
                + sin(motion.phase * 0.41) * orbRect.width * 0.075
                + motion.tilt.width * orbRect.width * 0.025
                + cursorOffset.x * orbRect.width * 0.1
                + velocityOffset.width * orbRect.width * 0.008,
            y: orbRect.midY
                + cos(motion.phase * 0.37) * orbRect.height * 0.055
                + motion.tilt.height * orbRect.height * 0.025
                + cursorOffset.y * orbRect.height * 0.1
                + velocityOffset.height * orbRect.height * 0.008
        )

        context.drawLayer { glow in
                glow.addFilter(.blur(radius: 8))
                glow.fill(
                    blob,
                    with: .color(
                        theme.primary.color
                            .opacity(0.13)
                    )
                )
            }

        context.fill(
                blob,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(
                            color: theme.baseDark.color,
                            location: 0
                        ),
                        .init(
                            color: theme.primary.color,
                            location: 0.34
                        ),
                        .init(
                            color: theme.secondary.color,
                            location: 0.72
                        ),
                        .init(
                            color: theme.accent.color,
                            location: 1
                        )
                    ]),
                    center: coreCenter,
                    startRadius: 0,
                    endRadius: orbRect.width * 0.58
                )
            )

        context.drawLayer { colorant in
                colorant.clip(to: blob)
                colorant.blendMode = .screen
                colorant.fill(
                    blob,
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.highlight.color.opacity(0.5),
                            theme.primary.color
                                .opacity(0.12),
                            theme.accent.color
                                .opacity(0.32)
                        ]),
                        startPoint: CGPoint(
                            x: orbRect.minX,
                            y: orbRect.minY
                        ),
                        endPoint: CGPoint(
                            x: orbRect.maxX,
                            y: orbRect.maxY
                        )
                    )
                )
            }

        drawLivingFields(
            context: &context,
            blob: blob,
            orbRect: orbRect
        )
        drawMaterialSignature(
            context: &context,
            blob: blob,
            orbRect: orbRect
        )
        drawFrontLiquidLens(
            context: &context,
            blob: blob,
            orbRect: orbRect
        )

        context.drawLayer { depth in
                depth.clip(to: blob)
                depth.blendMode = .multiply
                depth.addFilter(.blur(radius: 9))
                let coreRect = CGRect(
                    x: coreCenter.x - orbRect.width * 0.27,
                    y: coreCenter.y - orbRect.height * 0.3,
                    width: orbRect.width * 0.54,
                    height: orbRect.height * 0.6
                )
                depth.fill(
                    Path(ellipseIn: coreRect),
                    with: .color(
                        theme.baseDark.color
                            .opacity(0.5)
                    )
                )

                let leftDepth = CGRect(
                    x: orbRect.minX - orbRect.width * 0.08,
                    y: orbRect.minY + orbRect.height * 0.16,
                    width: orbRect.width * 0.4,
                    height: orbRect.height * 0.7
                )
                depth.fill(
                    Path(ellipseIn: leftDepth),
                    with: .color(
                        theme.baseDark.color
                            .opacity(0.3)
                    )
                )
            }

        context.drawLayer { sheen in
                sheen.clip(to: blob)
                sheen.blendMode = .screen
                sheen.addFilter(.blur(radius: 5.5))
                let sheenRect = CGRect(
                    x: orbRect.minX + orbRect.width * 0.06
                        + cursorOffset.x * orbRect.width * 0.16,
                    y: orbRect.minY + orbRect.height * 0.02
                        + cursorOffset.y * orbRect.height * 0.12,
                    width: orbRect.width * 0.58,
                    height: orbRect.height * 0.34
                )
                sheen.fill(
                    Path(ellipseIn: sheenRect),
                    with: .color(
                        theme.highlight.color
                            .opacity(0.34)
                    )
                )
            }

        drawLivingGlitter(
            context: &context,
            blob: blob,
            orbRect: orbRect
        )

        if motion.interactionStrength > 0.001 {
                let contactPoint = CGPoint(
                    x: orbRect.minX + motion.cursor.x * orbRect.width,
                    y: orbRect.minY + motion.cursor.y * orbRect.height
                )
                context.drawLayer { contactGlow in
                    contactGlow.clip(to: blob)
                    contactGlow.blendMode = .screen
                    contactGlow.addFilter(.blur(radius: 6))
                    let diameter = orbRect.width * (
                        0.3 + motion.cursorPressure * 0.12
                    )
                    let contactRect = CGRect(
                        x: contactPoint.x - diameter / 2,
                        y: contactPoint.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    contactGlow.fill(
                        Path(ellipseIn: contactRect),
                        with: .color(
                            theme.highlight.color
                                .opacity(
                                    Double(
                                        0.1
                                            + motion.interactionStrength
                                                * 0.2
                                    )
                                )
                        )
                    )
                }

                context.drawLayer { contactSpecular in
                    contactSpecular.clip(to: blob)
                    contactSpecular.blendMode = .screen
                    contactSpecular.addFilter(.blur(radius: 1.4))
                    let diameter = orbRect.width * 0.075
                    contactSpecular.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: contactPoint.x - diameter / 2,
                                y: contactPoint.y - diameter / 2,
                                width: diameter,
                                height: diameter
                            )
                        ),
                        with: .color(
                            theme.highlight.color.opacity(
                                Double(
                                    0.16
                                        + motion.interactionStrength * 0.26
                                )
                            )
                        )
                    )
            }
    }

        context.drawLayer { strandGlow in
                strandGlow.clip(to: blob)
                strandGlow.addFilter(.blur(radius: 4.4))

                for index in [0, 2, 5] {
                    let strand = Path(
                        LiquidOrbGeometry.strandPath(
                            in: orbRect,
                            index: index,
                            motion: motion
                        )
                    )
                    let shimmer = 0.55 + 0.45 * sin(
                        motion.phase * 0.7 + CGFloat(index) * 1.18
                    )
                    strandGlow.stroke(
                        strand,
                        with: .color(
                            theme.accent.color
                                .opacity(Double(0.05 + shimmer * 0.12))
                        ),
                        lineWidth: index.isMultiple(of: 2) ? 10.5 : 7.2
                    )
                }
            }

        context.drawLayer { ambientEdge in
            ambientEdge.addFilter(.blur(radius: 4.6))
            ambientEdge.stroke(
                blob,
                with: .linearGradient(
                    Gradient(colors: [
                        theme.highlight.color
                            .opacity(0.18),
                        theme.rim.color
                            .opacity(0.1),
                        theme.accent.color
                            .opacity(0.14)
                    ]),
                    startPoint: CGPoint(
                        x: orbRect.minX,
                        y: orbRect.minY
                    ),
                    endPoint: CGPoint(
                        x: orbRect.maxX,
                        y: orbRect.maxY
                    )
                ),
                lineWidth: 2.2
            )
        }

        context.drawLayer { innerDepth in
            innerDepth.clip(to: blob)
            innerDepth.blendMode = .multiply
            innerDepth.stroke(
                blob,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(
                            color: Color(
                                red: 0.035,
                                green: 0.008,
                                blue: 0.12
                            ).opacity(0.18),
                            location: 0.5
                        ),
                        .init(
                            color: Color(
                                red: 0.015,
                                green: 0.004,
                                blue: 0.07
                            ).opacity(0.54),
                            location: 1
                        )
                    ]),
                    startPoint: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.minY
                    ),
                    endPoint: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.maxY
                    )
                ),
                lineWidth: 3.2
            )
        }

        context.stroke(
            blob,
            with: .linearGradient(
                Gradient(colors: [
                    theme.highlight.color.opacity(0.56),
                    theme.rim.color
                        .opacity(0.3),
                    theme.accent.color
                        .opacity(0.2),
                    theme.primary.color
                        .opacity(0.18)
                ]),
                startPoint: CGPoint(
                    x: orbRect.minX,
                    y: orbRect.minY
                ),
                endPoint: CGPoint(
                    x: orbRect.maxX,
                    y: orbRect.maxY
                )
            ),
            lineWidth: 0.58
        )

        context.drawLayer { glassEdge in
            glassEdge.clip(to: blob)
            glassEdge.blendMode = .screen
            glassEdge.stroke(
                blob,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(
                            color: theme.highlight.color.opacity(0.6),
                            location: 0
                        ),
                        .init(
                            color: theme.rim.color.opacity(0.26),
                            location: 0.38
                        ),
                        .init(color: .clear, location: 0.72)
                    ]),
                    startPoint: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.minY
                    ),
                    endPoint: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.maxY
                    )
                ),
                lineWidth: 1.35
            )
        }
    }

    private func drawFrontLiquidLens(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        context.drawLayer { lens in
            lens.clip(to: blob)
            lens.fill(
                blob,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(
                            color: theme.highlight.color.opacity(0.08),
                            location: 0
                        ),
                        .init(
                            color: theme.primary.color.opacity(0.03),
                            location: 0.34
                        ),
                        .init(
                            color: theme.baseDark.color.opacity(0.12),
                            location: 0.62
                        ),
                        .init(
                            color: theme.baseDark.color.opacity(0.2),
                            location: 1
                        )
                    ]),
                    startPoint: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.minY
                    ),
                    endPoint: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.maxY
                    )
                )
            )
        }

        context.drawLayer { lensBloom in
            lensBloom.clip(to: blob)
            lensBloom.blendMode = .screen
            lensBloom.addFilter(.blur(radius: 7))
            let lensRect = CGRect(
                x: orbRect.minX + orbRect.width * 0.08,
                y: orbRect.minY + orbRect.height * 0.03,
                width: orbRect.width * 0.72,
                height: orbRect.height * 0.28
            )
            lensBloom.fill(
                Path(ellipseIn: lensRect),
                with: .color(
                    theme.highlight.color.opacity(0.13)
                )
            )
        }
    }

    private func drawLivingFields(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        let oilOpacity: Double
        let oilRadius: CGFloat
        switch theme.material {
        case .water:
            oilOpacity = 0.2
            oilRadius = 0.5
        case .wind:
            oilOpacity = 0.16
            oilRadius = 0.54
        case .earth:
            oilOpacity = 0.3
            oilRadius = 0.46
        case .aurora:
            oilOpacity = 0.18
            oilRadius = 0.52
        case .lava:
            // Keep lava as a continuous cooling skin. A concentrated dark
            // radial pocket reads as a black disc moving under the surface.
            oilOpacity = 0.09
            oilRadius = 0.68
        case .galaxy:
            oilOpacity = 0.4
            oilRadius = 0.42
        case .ice:
            oilOpacity = 0.14
            oilRadius = 0.62
        case .plasma:
            oilOpacity = 0.12
            oilRadius = 0.5
        case .prism:
            oilOpacity = 0.11
            oilRadius = 0.58
        case .eclipse:
            oilOpacity = 0.54
            oilRadius = 0.38
        }

        let fields: [(CGPoint, Color, CGFloat)] = [
            (
                motion.violet,
                theme.secondary.color.opacity(0.34),
                0.43 * theme.fieldScale
            ),
            (
                motion.magenta,
                theme.accent.color.opacity(0.26),
                0.36 * theme.fieldScale
            ),
            (
                motion.cyan,
                theme.primary.color.opacity(0.2),
                0.32 * theme.fieldScale
            ),
            (
                motion.pearl,
                theme.highlight.color.opacity(0.16),
                0.24 * theme.fieldScale
            )
        ]

        context.drawLayer { liquidFields in
            liquidFields.clip(to: blob)
            liquidFields.blendMode = .screen

            for (normalizedPoint, color, radius) in fields {
                liquidFields.fill(
                    blob,
                    with: .radialGradient(
                        Gradient(colors: [color, .clear]),
                        center: canvasPoint(
                            normalizedPoint,
                            in: orbRect
                        ),
                        startRadius: 0,
                        endRadius: orbRect.width * radius
                    )
                )
            }
        }

        context.drawLayer { oilDepth in
            oilDepth.clip(to: blob)
            oilDepth.blendMode = .multiply
            oilDepth.fill(
                blob,
                with: .radialGradient(
                    Gradient(colors: [
                        theme.baseDark.color.opacity(oilOpacity),
                        .clear
                    ]),
                    center: canvasPoint(motion.oil, in: orbRect),
                    startRadius: 0,
                    endRadius: orbRect.width * oilRadius
                )
            )
        }
    }

    private func drawMaterialSignature(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        switch theme.material {
        case .water:
            drawWaterMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .wind:
            drawWindMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .earth:
            drawEarthMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .aurora:
            drawAuroraMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .lava:
            drawLavaMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .galaxy:
            drawGalaxyMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .ice:
            drawWaterMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
            drawAuroraMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .plasma:
            drawLavaMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
            drawAuroraMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .prism:
            drawWindMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
            drawAuroraMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        case .eclipse:
            drawGalaxyMaterial(
                context: &context,
                blob: blob,
                orbRect: orbRect
            )
        }
    }

    private func drawWaterMaterial(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        context.drawLayer { submergedCurrents in
            submergedCurrents.clip(to: blob)
            submergedCurrents.blendMode = .screen
            submergedCurrents.addFilter(.blur(radius: 5.8))

            for index in 0..<5 {
                submergedCurrents.stroke(
                    horizontalFlowPath(
                        in: orbRect,
                        level: 0.18 + CGFloat(index) * 0.16,
                        phase: motion.phase * 0.72
                            + CGFloat(index) * 1.43,
                        amplitude: orbRect.height * (
                            0.08 + CGFloat(index % 2) * 0.025
                        )
                    ),
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.secondary.color.opacity(0.02),
                            theme.highlight.color.opacity(
                                Double(0.1 + motion.energy * 0.06)
                            ),
                            theme.primary.color.opacity(0.03)
                        ]),
                        startPoint: CGPoint(
                            x: orbRect.minX,
                            y: orbRect.midY
                        ),
                        endPoint: CGPoint(
                            x: orbRect.maxX,
                            y: orbRect.midY
                        )
                    ),
                    lineWidth: 4.5 + CGFloat(index % 3) * 2.2
                )
            }
        }
    }

    private func drawWindMaterial(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        context.drawLayer { wind in
            wind.clip(to: blob)
            wind.blendMode = .screen
            wind.addFilter(.blur(radius: 3.4))

            for index in 0..<6 {
                let path = windRibbonPath(
                    in: orbRect,
                    index: index,
                    phase: motion.phase
                )
                let color = index.isMultiple(of: 2)
                    ? theme.highlight.color
                    : theme.accent.color
                wind.stroke(
                    path,
                    with: .color(
                        color.opacity(
                            Double(0.045 + CGFloat(index % 3) * 0.025)
                        )
                    ),
                    lineWidth: 2.8 + CGFloat(index % 3) * 1.4
                )
            }
        }
    }

    private func drawEarthMaterial(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        context.drawLayer { strata in
            strata.clip(to: blob)
            strata.blendMode = .multiply
            strata.addFilter(.blur(radius: 3.6))

            for index in 0..<5 {
                let path = horizontalFlowPath(
                    in: orbRect,
                    level: 0.3 + CGFloat(index) * 0.12,
                    phase: motion.phase * 0.28 + CGFloat(index) * 0.72,
                    amplitude: orbRect.height * 0.027
                )
                strata.stroke(
                    path,
                    with: .color(
                        theme.baseDark.color.opacity(
                            Double(0.16 + CGFloat(index % 2) * 0.08)
                        )
                    ),
                    lineWidth: 5.2 + CGFloat(index % 3) * 2
                )
            }
        }
    }

    private func drawAuroraMaterial(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        context.drawLayer { veil in
            veil.clip(to: blob)
            veil.blendMode = .screen
            veil.addFilter(.blur(radius: 3.2))

            for index in 0..<6 {
                let strand = Path(
                    LiquidOrbGeometry.strandPath(
                        in: orbRect,
                        index: index,
                        motion: motion
                    )
                )
                veil.stroke(
                    strand,
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.secondary.color.opacity(0.03),
                            theme.highlight.color.opacity(0.22),
                            theme.accent.color.opacity(0.08)
                        ]),
                        startPoint: CGPoint(
                            x: orbRect.minX,
                            y: orbRect.minY
                        ),
                        endPoint: CGPoint(
                            x: orbRect.maxX,
                            y: orbRect.maxY
                        )
                    ),
                    lineWidth: 4.5 + CGFloat(index % 3) * 2.2
                )
            }
        }
    }

    private func drawLavaMaterial(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        let crustPlates = (0..<8).map {
            lavaCrustPlatePath(
                in: orbRect,
                index: $0,
                phase: motion.phase
            )
        }
        var crustNetwork = Path()
        for plate in crustPlates {
            crustNetwork.addPath(plate)
        }

        context.drawLayer { coolingSkin in
            coolingSkin.clip(to: blob)
            coolingSkin.blendMode = .multiply
            coolingSkin.addFilter(.blur(radius: 4.8))
            coolingSkin.fill(
                blob,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(
                            color: theme.baseDark.color.opacity(0.34),
                            location: 0
                        ),
                        .init(
                            color: theme.primary.color.opacity(0.1),
                            location: 0.44
                        ),
                        .init(
                            color: theme.baseDark.color.opacity(0.3),
                            location: 1
                        )
                    ]),
                    startPoint: CGPoint(
                        x: orbRect.minX,
                        y: orbRect.minY
                    ),
                    endPoint: CGPoint(
                        x: orbRect.maxX,
                        y: orbRect.maxY
                    )
                )
            )

            for (index, plate) in crustPlates.enumerated() {
                coolingSkin.fill(
                    plate,
                    with: .color(
                        theme.baseDark.color.opacity(
                            Double(0.22 + CGFloat(index % 3) * 0.035)
                        )
                    )
                )
            }
        }

        context.drawLayer { heatBloom in
            heatBloom.clip(to: blob)
            heatBloom.blendMode = .screen
            heatBloom.addFilter(.blur(radius: 6.4))

            heatBloom.stroke(
                crustNetwork,
                with: .color(
                    theme.secondary.color.opacity(
                        Double(0.28 + motion.energy * 0.2)
                    )
                ),
                lineWidth: 6.2 + motion.energy * 2.6
            )
        }

        context.drawLayer { moltenFissures in
            moltenFissures.clip(to: blob)
            moltenFissures.blendMode = .screen
            moltenFissures.addFilter(.blur(radius: 2.7))

            moltenFissures.stroke(
                crustNetwork,
                with: .linearGradient(
                    Gradient(colors: [
                        theme.secondary.color.opacity(0.38),
                        theme.accent.color.opacity(
                            Double(0.46 + motion.energy * 0.14)
                        ),
                        theme.secondary.color.opacity(0.34)
                    ]),
                    startPoint: CGPoint(
                        x: orbRect.minX,
                        y: orbRect.minY
                    ),
                    endPoint: CGPoint(
                        x: orbRect.maxX,
                        y: orbRect.maxY
                    )
                ),
                lineWidth: 1.8 + motion.energy * 0.7
            )
        }

        context.drawLayer { convection in
            convection.clip(to: blob)
            convection.blendMode = .screen
            convection.addFilter(.blur(radius: 8))

            for index in 0..<3 {
                convection.stroke(
                    lavaConvectionPath(
                        in: orbRect,
                        index: index,
                        phase: motion.phase
                    ),
                    with: .color(
                        theme.primary.color.opacity(
                            Double(0.1 + motion.energy * 0.08)
                        )
                    ),
                    lineWidth: orbRect.width * 0.11
                )
            }
        }
    }

    private func drawGalaxyMaterial(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        context.drawLayer { galaxy in
            galaxy.clip(to: blob)
            galaxy.blendMode = .screen
            galaxy.addFilter(.blur(radius: 2.8))

            for arm in 0..<2 {
                galaxy.stroke(
                    galaxySpiralPath(
                        in: orbRect,
                        phase: motion.phase * 0.24
                            + CGFloat(arm) * .pi
                    ),
                    with: .linearGradient(
                        Gradient(colors: [
                            theme.highlight.color.opacity(0.32),
                            theme.accent.color.opacity(0.14),
                            .clear
                        ]),
                        startPoint: CGPoint(
                            x: orbRect.midX,
                            y: orbRect.midY
                        ),
                        endPoint: CGPoint(
                            x: orbRect.maxX,
                            y: orbRect.minY
                        )
                    ),
                    lineWidth: arm == 0 ? 1.6 : 0.9
                )
            }

            galaxy.fill(
                blob,
                with: .radialGradient(
                    Gradient(colors: [
                        theme.highlight.color.opacity(0.2),
                        theme.accent.color.opacity(0.05),
                        .clear
                    ]),
                    center: CGPoint(
                        x: orbRect.midX,
                        y: orbRect.midY
                    ),
                    startRadius: 0,
                    endRadius: orbRect.width * 0.2
                )
            )
        }
    }

    private func lavaCrustPlatePath(
        in rect: CGRect,
        index: Int,
        phase: CGFloat
    ) -> Path {
        let centers = [
            CGPoint(x: 0.18, y: 0.2),
            CGPoint(x: 0.48, y: 0.16),
            CGPoint(x: 0.78, y: 0.26),
            CGPoint(x: 0.24, y: 0.5),
            CGPoint(x: 0.58, y: 0.46),
            CGPoint(x: 0.84, y: 0.58),
            CGPoint(x: 0.38, y: 0.78),
            CGPoint(x: 0.7, y: 0.82)
        ]
        let baseCenter = centers[index % centers.count]
        let center = canvasPoint(
            CGPoint(
                x: baseCenter.x + sin(
                    phase * 0.045 + CGFloat(index) * 1.7
                ) * 0.012,
                y: baseCenter.y + cos(
                    phase * 0.04 + CGFloat(index) * 1.3
                ) * 0.01
            ),
            in: rect
        )
        let radiusX = rect.width * (
            0.19 + CGFloat(index % 3) * 0.018
        )
        let radiusY = rect.height * (
            0.15 + CGFloat(index % 2) * 0.025
        )
        let vertexCount = 8
        let path = CGMutablePath()

        for vertex in 0..<vertexCount {
            let angle = CGFloat(vertex) / CGFloat(vertexCount) * .pi * 2
                + CGFloat(index) * 0.37
            let roughness = 0.82 + 0.18 * sin(
                CGFloat(vertex) * 2.31
                    + CGFloat(index) * 1.43
                    + phase * 0.025
            )
            let point = CGPoint(
                x: center.x + cos(angle) * radiusX * roughness,
                y: center.y + sin(angle) * radiusY * roughness
            )
            if vertex == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return Path(path)
    }

    private func lavaConvectionPath(
        in rect: CGRect,
        index: Int,
        phase: CGFloat
    ) -> Path {
        let path = CGMutablePath()
        let level = 0.24 + CGFloat(index) * 0.27
        let sway = sin(phase * 0.32 + CGFloat(index) * 2.1)
        path.move(to: CGPoint(
            x: rect.minX - rect.width * 0.12,
            y: rect.minY + rect.height * level
        ))
        path.addCurve(
            to: CGPoint(
                x: rect.maxX + rect.width * 0.12,
                y: rect.minY + rect.height * (level + sway * 0.06)
            ),
            control1: CGPoint(
                x: rect.minX + rect.width * 0.28,
                y: rect.minY + rect.height * (level + 0.15 * sway)
            ),
            control2: CGPoint(
                x: rect.minX + rect.width * 0.72,
                y: rect.minY + rect.height * (level - 0.13 * sway)
            )
        )
        return Path(path)
    }

    private func horizontalFlowPath(
        in rect: CGRect,
        level: CGFloat,
        phase: CGFloat,
        amplitude: CGFloat
    ) -> Path {
        let path = CGMutablePath()
        let start = CGPoint(
            x: rect.minX - rect.width * 0.08,
            y: rect.minY + rect.height * level
        )
        let end = CGPoint(
            x: rect.maxX + rect.width * 0.08,
            y: start.y + sin(phase * 0.7) * amplitude * 0.42
        )
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(
                x: rect.minX + rect.width * 0.27,
                y: start.y + sin(phase) * amplitude
            ),
            control2: CGPoint(
                x: rect.minX + rect.width * 0.72,
                y: start.y - cos(phase * 0.82) * amplitude
            )
        )
        return Path(path)
    }

    private func windRibbonPath(
        in rect: CGRect,
        index: Int,
        phase: CGFloat
    ) -> Path {
        let path = CGMutablePath()
        let level = 0.2 + CGFloat(index) * 0.12
        let sway = sin(phase * 1.36 + CGFloat(index) * 0.82)
        let start = CGPoint(
            x: rect.minX - rect.width * 0.1,
            y: rect.minY + rect.height * level
                + sway * rect.height * 0.04
        )
        let end = CGPoint(
            x: rect.maxX + rect.width * 0.1,
            y: rect.minY + rect.height * (
                level + 0.06 * cos(phase + CGFloat(index))
            )
        )
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(
                x: rect.minX + rect.width * 0.34,
                y: start.y - rect.height * 0.11 * sway
            ),
            control2: CGPoint(
                x: rect.minX + rect.width * 0.68,
                y: end.y + rect.height * 0.1 * sway
            )
        )
        return Path(path)
    }

    private func galaxySpiralPath(
        in rect: CGRect,
        phase: CGFloat
    ) -> Path {
        let path = CGMutablePath()
        let points = 72

        for index in 0..<points {
            let progress = CGFloat(index) / CGFloat(points - 1)
            let angle = progress * .pi * 3.8 + phase
            let radius = rect.width * (0.035 + progress * 0.38)
            let point = CGPoint(
                x: rect.midX + cos(angle) * radius,
                y: rect.midY + sin(angle) * radius * 0.62
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return Path(path)
    }

    private func drawLivingGlitter(
        context: inout GraphicsContext,
        blob: Path,
        orbRect: CGRect
    ) {
        guard theme.material == .galaxy else {
            return
        }

        let visibleIndices = Array(
            motion.sparkles.indices.prefix(
                min(motion.sparkles.count, theme.sparkleCount)
            )
        )

        context.drawLayer { glitter in
            glitter.clip(to: blob)
            glitter.blendMode = .screen

            for index in visibleIndices {
                let sparkle = motion.sparkles[index]
                let center = canvasPoint(sparkle.position, in: orbRect)
                let diameter = orbRect.width * 0.009 * sparkle.scale
                let tint = sparkle.warmth > 0.55
                    ? theme.accent.color
                    : theme.highlight.color
                glitter.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: center.x - diameter / 2,
                            y: center.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                    ),
                    with: .color(
                        tint.opacity(
                            Double(sparkle.opacity * 0.42)
                        )
                    )
                )
            }
        }
    }

    private func canvasPoint(
        _ normalizedPoint: CGPoint,
        in rect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: rect.minX + normalizedPoint.x * rect.width,
            y: rect.minY + normalizedPoint.y * rect.height
        )
    }
}

struct LocalFlowHistoryView: View {
    @ObservedObject var model: LocalFlowHubModel
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HubPageHeader(
                eyebrow: "Your private archive",
                title: "History",
                subtitle: "\(model.filteredHistoryRecords.count) transcripts stored locally"
            ) {
                HStack(spacing: 10) {
                    HubSearchField(text: $model.historySearch, placeholder: "Search transcripts")
                        .frame(width: 250)

                    Button {
                        showingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(HubSecondaryButtonStyle())
                    .disabled(model.historyRecords.isEmpty)
                }
            }

            HubCard(padding: 0) {
                HSplitView {
                    historyList
                        .frame(minWidth: 360, idealWidth: 430)

                    historyDetail
                        .frame(minWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 30)
        .confirmationDialog(
            "Clear your history?",
            isPresented: $showingClearConfirmation
        ) {
            Button("Clear all transcripts", role: .destructive) {
                model.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all locally stored text transcripts.")
        }
    }

    private var historyList: some View {
        Group {
            if model.filteredHistoryRecords.isEmpty {
                HubEmptyState(
                    symbol: model.historySearch.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
                    title: model.historySearch.isEmpty ? "No history yet" : "No matching transcripts",
                    message: model.historySearch.isEmpty
                        ? "Your dictations will be saved here automatically."
                        : "Try another word, application name, or phrase."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9, pinnedViews: .sectionHeaders) {
                        ForEach(model.historyGroups) { group in
                            Section {
                                ForEach(group.records) { record in
                                    HubTranscriptRow(
                                        record: record,
                                        isSelected: model.selectedHistoryID == record.id
                                    ) {
                                        model.selectedHistoryID = record.id
                                    } copy: {
                                        model.copy(record)
                                    }
                                }
                            } header: {
                                Text(HubFormat.groupDate(group.date))
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 18)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(HubPalette.card)
                            }
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .background(HubPalette.card)
    }

    private var historyDetail: some View {
        Group {
            if let record = model.selectedHistoryRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.targetApplication?.displayName ?? "Unknown app")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(HubPalette.purple)
                                Text(record.createdAt.formatted(date: .long, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.copy(record)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(HubSecondaryButtonStyle())
                        }

                        HStack(spacing: 9) {
                            HubInfoPill(
                                symbol: "textformat.abc",
                                text: "\(DictationInsightsCalculator.wordCount(in: record.finalText)) words"
                            )
                            if let duration = record.durationSeconds {
                                HubInfoPill(
                                    symbol: "timer",
                                    text: HubFormat.preciseDuration(duration)
                                )
                            }
                            if record.resolvedOutputMode == .prompt {
                                HubInfoPill(
                                    symbol: "text.badge.sparkles",
                                    text: "Prompt Mode"
                                )
                            } else if record.resolvedOutputMode == .polish {
                                HubInfoPill(symbol: "sparkles", text: "Lissé")
                            }
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("FINAL TRANSCRIPT")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                            Text(record.finalText)
                                .font(.system(size: 16, weight: .regular))
                                .textSelection(.enabled)
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if record.transcribedText != record.finalText {
                            Divider()
                            VStack(alignment: .leading, spacing: 9) {
                                Text("RAW TRANSCRIPTION")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(1)
                                    .foregroundStyle(.secondary)
                                Text(record.transcribedText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                HubEmptyState(
                    symbol: "text.alignleft",
                    title: "Select a transcript",
                    message: "Choose an item to inspect the full text and metadata."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(HubPalette.softFill.opacity(0.32))
    }
}

private struct HubTranscriptRow: View {
    let record: DictationRecord
    let isSelected: Bool
    let select: () -> Void
    let copy: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            isSelected
                                ? HubPalette.purple.opacity(0.16)
                                : HubPalette.softFill
                        )
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? HubPalette.purple : .secondary)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 5) {
                    Text(record.finalText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 5) {
                        Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                        Text("·")
                        Text(record.targetApplication?.displayName ?? "Unknown app")
                            .lineLimit(1)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if isHovering || isSelected {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(HubPalette.softFill, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        isSelected
                            ? HubPalette.purple.opacity(0.075)
                            : Color.primary.opacity(isHovering ? 0.025 : 0)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        isSelected ? HubPalette.purple.opacity(0.3) : .clear,
                        lineWidth: 1
                    )
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct LocalFlowInsightsView: View {
    @ObservedObject var model: LocalFlowHubModel

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HubPageHeader(
                    eyebrow: "Your voice in numbers",
                    title: "Words & Stats",
                    subtitle: "A private overview calculated from your local transcript history"
                )

                LazyVGrid(columns: columns, spacing: 14) {
                    HubMetricCard(
                        title: "Total words",
                        value: HubFormat.number(model.insights.totalWords),
                        caption: "\(model.insights.totalDictations) dictations",
                        symbol: "text.word.spacing",
                        tint: HubPalette.purple
                    )
                    HubMetricCard(
                        title: "Average speed",
                        value: "\(Int(model.insights.averageWordsPerMinute.rounded())) WPM",
                        caption: "across recorded sessions",
                        symbol: "gauge.with.dots.needle.67percent",
                        tint: HubPalette.blue
                    )
                    HubMetricCard(
                        title: "Voice time",
                        value: HubFormat.duration(model.insights.totalDurationSeconds),
                        caption: "captured locally",
                        symbol: "mic.fill",
                        tint: HubPalette.cyan
                    )
                    HubMetricCard(
                        title: "Time saved",
                        value: HubFormat.duration(model.insights.estimatedTimeSavedSeconds),
                        caption: "estimated typing time",
                        symbol: "bolt.fill",
                        tint: .orange
                    )
                    HubMetricCard(
                        title: "Active days",
                        value: "\(model.insights.activeDays)",
                        caption: "\(model.insights.currentStreakDays)-day current streak",
                        symbol: "calendar",
                        tint: .green
                    )
                    HubMetricCard(
                        title: "Longest thought",
                        value: "\(model.insights.longestDictationWords)",
                        caption: "words in one dictation",
                        symbol: "quote.bubble.fill",
                        tint: .pink
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    activityTrend
                        .frame(maxWidth: .infinity)
                    voiceEquivalent
                        .frame(width: 280)
                }

                topApplications
            }
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 36)
        }
    }

    private var activityTrend: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("14-day activity")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Your daily dictated word count")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Chart(model.insights.dailyStats) { stat in
                    AreaMark(
                        x: .value("Date", stat.date, unit: .day),
                        y: .value("Words", stat.words)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                HubPalette.purple.opacity(0.34),
                                HubPalette.purple.opacity(0.01)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Date", stat.date, unit: .day),
                        y: .value("Words", stat.words)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(HubPalette.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) {
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                            .foregroundStyle(.secondary)
                        AxisGridLine()
                            .foregroundStyle(.clear)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisValueLabel()
                            .foregroundStyle(.secondary)
                        AxisGridLine()
                            .foregroundStyle(HubPalette.border)
                    }
                }
                .frame(height: 220)
            }
        }
    }

    private var voiceEquivalent: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [HubPalette.purple.opacity(0.18), HubPalette.blue.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(HubPalette.purple)
                }
                .frame(width: 58, height: 58)

                Text("You have spoken the equivalent of")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(equivalentText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Every word stays in your private, local history.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }

    private var equivalentText: String {
        let words = model.insights.totalWords
        if words >= 50_000 {
            return "\(max(1, words / 50_000)) short books"
        }
        if words >= 500 {
            return "\(max(1, words / 500)) pages"
        }
        if words >= 40 {
            return "\(max(1, words / 40)) messages"
        }
        return "your first page"
    }

    private var topApplications: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where your voice works")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Top applications by dictated words")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if model.insights.topApplications.isEmpty {
                    HubEmptyState(
                        symbol: "square.grid.2x2",
                        title: "No app data yet",
                        message: "Application usage appears after your first dictations."
                    )
                    .frame(height: 120)
                } else {
                    let maximum = Double(max(1, model.insights.topApplications.first?.words ?? 1))
                    VStack(spacing: 13) {
                        ForEach(Array(model.insights.topApplications.prefix(6)).indices, id: \.self) { index in
                            let app = model.insights.topApplications[index]
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(HubPalette.purple.opacity(0.1))
                                    Text(String(app.name.prefix(1)).uppercased())
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(HubPalette.purple)
                                }
                                .frame(width: 32, height: 32)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(app.name)
                                            .font(.system(size: 11, weight: .semibold))
                                        Spacer()
                                        Text("\(HubFormat.number(app.words)) words")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: Double(app.words), total: maximum)
                                        .tint(
                                            LinearGradient(
                                                colors: [HubPalette.purple, HubPalette.blue],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct HubMetricCard: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color

    var body: some View {
        HubCard(padding: 15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: HubRadius.control,
                            style: .continuous
                        )
                        .fill(tint.opacity(0.085))
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint.opacity(0.9))
                    }
                    .frame(width: 33, height: 33)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(value)
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(caption)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct HubSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(HubPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HubPalette.border, lineWidth: 1)
        }
    }
}

struct HubEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(HubPalette.purple.opacity(0.7))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .padding(20)
    }
}

private struct HubInfoPill: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(HubPalette.softFill, in: Capsule())
    }
}

enum HubFormat {
    static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        if seconds < 3_600 {
            return "\(Int((seconds / 60).rounded()))m"
        }
        let hours = Int(seconds / 3_600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3_600)) / 60)
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }

    static func preciseDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        return duration(seconds)
    }

    static func groupDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "TODAY"
        }
        if calendar.isDateInYesterday(date) {
            return "YESTERDAY"
        }
        return date.formatted(date: .abbreviated, time: .omitted).uppercased()
    }

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 5 {
            return "just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
