import Charts
import LocalFlowCore
import SwiftUI

struct LocalFlowHomeView: View {
    @ObservedObject var model: LocalFlowHubModel

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HubPageHeader(
                    eyebrow: "Local voice, serious speed",
                    title: greeting,
                    subtitle: homeSubtitle
                ) {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(HubSecondaryButtonStyle())
                }

                HubRecordingHero(model: model)

                LazyVGrid(columns: columns, spacing: 14) {
                    HubMetricCard(
                        title: "Words dictated",
                        value: HubFormat.compact(model.insights.totalWords),
                        caption: "All time",
                        symbol: "textformat.abc",
                        tint: HubPalette.purple
                    )
                    HubMetricCard(
                        title: "Dictation speed",
                        value: "\(Int(model.insights.averageWordsPerMinute.rounded()))",
                        caption: "words per minute",
                        symbol: "speedometer",
                        tint: HubPalette.blue
                    )
                    HubMetricCard(
                        title: "Time saved",
                        value: HubFormat.duration(model.insights.estimatedTimeSavedSeconds),
                        caption: "vs. typing at 40 WPM",
                        symbol: "hourglass.bottomhalf.filled",
                        tint: HubPalette.cyan
                    )
                    HubMetricCard(
                        title: "Current streak",
                        value: "\(model.insights.currentStreakDays)",
                        caption: model.insights.currentStreakDays == 1 ? "active day" : "active days",
                        symbol: "flame.fill",
                        tint: .orange
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
            .padding(.top, 34)
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
        return "Last dictation \(last.createdAt.formatted(.relative(presentation: .named)))."
    }

    private var weeklyActivity: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Voice activity")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
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
                    .foregroundStyle(HubPalette.purple)
                }

                Chart(Array(model.insights.dailyStats.suffix(7))) { stat in
                    BarMark(
                        x: .value("Day", stat.date, unit: .day),
                        y: .value("Words", stat.words)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [HubPalette.purple, HubPalette.blue],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .cornerRadius(5)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                            .foregroundStyle(HubPalette.border)
                        AxisValueLabel()
                            .foregroundStyle(.secondary)
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
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer()
                    Button {
                        model.selectedSection = .history
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HubPalette.purple)
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
                                            .fill(HubPalette.purple.opacity(0.1))
                                        Image(systemName: "waveform")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(HubPalette.purple)
                                    }
                                    .frame(width: 30, height: 30)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.finalText)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(record.targetApplication?.displayName ?? "Unknown app") · \(record.createdAt.formatted(date: .omitted, time: .shortened))")
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
    @ObservedObject var model: LocalFlowHubModel
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: .green.opacity(0.7), radius: pulse ? 9 : 3)
                    Text("LOCALFLOW IS READY")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text("Speak naturally.\nWrite beautifully.")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Hold Fn in any app, then release to transcribe. Lock hands-free mode with Space and finish with Escape.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(3)
                    .frame(maxWidth: 470, alignment: .leading)

                HStack(spacing: 8) {
                    HubKeycap("fn")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                    HubKeycap("space")
                    Text("lock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                    HubKeycap("esc")
                    Text("finish")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(HubPalette.purple.opacity(0.2))
                    .frame(width: pulse ? 148 : 124, height: pulse ? 148 : 124)
                    .blur(radius: 18)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [HubPalette.purple, HubPalette.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 92, height: 92)
                    .shadow(color: HubPalette.purple.opacity(0.5), radius: 26, y: 10)

                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 160, height: 150)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.11, green: 0.095, blue: 0.18),
                        Color(red: 0.065, green: 0.075, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(HubPalette.blue.opacity(0.2))
                    .frame(width: 260, height: 260)
                    .blur(radius: 70)
                    .offset(x: 330, y: -80)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.2), HubPalette.purple.opacity(0.3), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: HubPalette.purple.opacity(0.12), radius: 26, y: 12)
        .onAppear {
            guard !reduceMotion else {
                return
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
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
                            if record.polished {
                                HubInfoPill(symbol: "sparkles", text: "Polished")
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
        HubCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint.opacity(0.11))
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 34, height: 34)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
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
}
