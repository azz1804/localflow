import SwiftUI

struct LocalFlowHubView: View {
    @ObservedObject var model: LocalFlowHubModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                HubSidebar(model: model)
                    .frame(width: 212)

                ZStack {
                    HubPalette.canvas
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        if model.updatePresentation != .hidden {
                            HubUpdateBanner(model: model)
                                .padding(.horizontal, 30)
                                .padding(.top, 18)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .move(edge: .top).combined(with: .opacity)
                                )
                        }

                        selectedPage
                            .id(model.selectedSection)
                            .transition(
                                reduceMotion
                                    ? .identity
                                    : .asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                                        removal: .opacity
                                    )
                            )
                    }
                }
            }

            if !model.statusMessage.isEmpty {
                HubToast(
                    message: model.statusMessage,
                    isError: model.statusIsError
                )
                .padding(24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .background(HubPalette.canvas)
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
            value: model.selectedSection
        )
        .animation(.easeOut(duration: 0.2), value: model.statusMessage)
        .animation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.88),
            value: model.updatePresentation
        )
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch model.selectedSection {
        case .home:
            LocalFlowHomeView(model: model)
        case .history:
            LocalFlowHistoryView(model: model)
        case .insights:
            LocalFlowInsightsView(model: model)
        case .dictionary:
            LocalFlowDictionaryView(model: model)
        case .settings:
            LocalFlowSettingsView(model: model)
        case .diagnostics:
            LocalFlowDiagnosticsView(model: model)
        }
    }
}

private struct HubUpdateBanner: View {
    @ObservedObject var model: LocalFlowHubModel

    private var update: LocalFlowAvailableUpdate? {
        model.updatePresentation.update
    }

    private var isInstalling: Bool {
        if case .installing = model.updatePresentation {
            return true
        }
        return false
    }

    private var failureMessage: String? {
        if case let .failed(_, message) = model.updatePresentation {
            return message
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                HubPalette.purple.opacity(0.2),
                                HubPalette.blue.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(
                    systemName: failureMessage == nil
                        ? "arrow.down.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(
                    failureMessage == nil ? HubPalette.purple : Color.orange
                )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    isInstalling
                        ? "Mise à jour en cours…"
                        : failureMessage == nil
                            ? "Une mise à jour est disponible"
                            : "La mise à jour doit être relancée"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

                Text(
                    failureMessage
                        ?? (isInstalling
                            ? "LocalFlow va se relancer automatiquement."
                            : "Appuyez sur « Mise à jour » pour appliquer les dernières améliorations.")
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 14)

            if let update {
                Text(update.shortCommit)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(HubPalette.softFill)
                    .clipShape(Capsule())
                    .accessibilityLabel("Version \(update.shortCommit)")
            }

            if isInstalling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("Mise à jour en cours")
            } else {
                Button {
                    model.installAvailableUpdate()
                } label: {
                    Label(
                        failureMessage == nil ? "Mise à jour" : "Réessayer",
                        systemImage: "arrow.down"
                    )
                }
                .buttonStyle(HubPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 66)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(HubPalette.card)
                .shadow(color: .black.opacity(0.07), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            HubPalette.purple.opacity(0.38),
                            HubPalette.blue.opacity(0.14)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct HubSidebar: View {
    @ObservedObject var model: LocalFlowHubModel

    private let primarySections: [LocalFlowHubSection] = [
        .home, .history, .insights, .dictionary
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 34)
                .padding(.horizontal, 20)

            Text("YOUR VOICE WORKSPACE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.3))
                .padding(.top, 26)
                .padding(.bottom, 10)
                .padding(.horizontal, 22)

            VStack(spacing: 5) {
                ForEach(primarySections) { section in
                    HubSidebarButton(
                        section: section,
                        isSelected: model.selectedSection == section
                    ) {
                        model.selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 24)

            shortcutCard
                .padding(.horizontal, 14)
                .padding(.bottom, 18)

            VStack(spacing: 5) {
                HubSidebarButton(
                    section: .settings,
                    isSelected: model.selectedSection == .settings
                ) {
                    model.selectedSection = .settings
                }

                HubSidebarButton(
                    section: .diagnostics,
                    isSelected: model.selectedSection == .diagnostics
                ) {
                    model.selectedSection = .diagnostics
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.075, green: 0.078, blue: 0.11),
                    Color(red: 0.045, green: 0.047, blue: 0.068)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(width: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 12) {
            LocalFlowBrandLogo(diameter: 44)
                .shadow(
                    color: HubPalette.purple.opacity(0.28),
                    radius: 10,
                    y: 4
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("LocalFlow")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Private dictation")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("LocalFlow, private dictation")
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundStyle(HubPalette.purple)
                Text("Ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: .green.opacity(0.7), radius: 5)
            }

            HStack(spacing: 6) {
                HubKeycap("fn")
                Text("hold to talk")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct HubSidebarButton: View {
    let section: LocalFlowHubSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.52))

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.62))

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.105),
                                        .white.opacity(0.075)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(isHovering ? 0.055 : 0))
                    )
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(HubPalette.purple.opacity(0.9))
                        .frame(width: 2, height: 18)
                        .offset(x: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct HubPageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                if !eyebrow.isEmpty {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.15)
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            trailing()
        }
    }
}

extension HubPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct HubCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: () -> Content
    @State private var hoverLocation: CGPoint?

    var body: some View {
        content()
            .padding(padding)
            .background {
                GeometryReader { proxy in
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: HubRadius.card,
                            style: .continuous
                        )
                        .fill(HubPalette.card)

                        if let hoverLocation {
                            RadialGradient(
                                colors: [
                                    Color.primary.opacity(0.045),
                                    Color.primary.opacity(0)
                                ],
                                center: UnitPoint(
                                    x: max(
                                        0,
                                        min(1, hoverLocation.x / proxy.size.width)
                                    ),
                                    y: max(
                                        0,
                                        min(1, hoverLocation.y / proxy.size.height)
                                    )
                                ),
                                startRadius: 0,
                                endRadius: 150
                            )
                        }
                    }
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: HubRadius.card,
                            style: .continuous
                        )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 16, y: 7)
                }
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: HubRadius.card,
                    style: .continuous
                )
                .stroke(
                    Color.primary.opacity(hoverLocation == nil ? 0.07 : 0.12),
                    lineWidth: 0.75
                )
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: HubRadius.card,
                    style: .continuous
                )
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
    }
}

struct HubKeycap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.1))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

struct HubPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                LinearGradient(
                    colors: [HubPalette.purple, HubPalette.blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(configuration.isPressed ? 0.78 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: HubPalette.purple.opacity(configuration.isPressed ? 0.12 : 0.28), radius: 10, y: 4)
    }
}

struct HubSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(HubPalette.softFill.opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(HubPalette.border, lineWidth: 1)
            }
    }
}

private struct HubToast: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 20, y: 8)
    }
}

enum HubPalette {
    static let purple = Color(red: 0.49, green: 0.39, blue: 0.98)
    static let blue = Color(red: 0.35, green: 0.48, blue: 0.96)
    static let cyan = Color(red: 0.35, green: 0.72, blue: 0.9)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let softFill = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    static let border = Color.primary.opacity(0.075)
}

enum HubRadius {
    static let card: CGFloat = 18
    static let hero: CGFloat = 22
    static let control: CGFloat = 10
    static let compact: CGFloat = 8
}
