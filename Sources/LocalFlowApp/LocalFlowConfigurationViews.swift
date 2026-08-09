import LocalFlowCore
import SwiftUI

struct LocalFlowDictionaryView: View {
    @ObservedObject var model: LocalFlowHubModel

    private var termCount: Int {
        model.termsText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    private var replacementCount: Int {
        model.replacementsText
            .components(separatedBy: .newlines)
            .filter { $0.contains("=") }
            .count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HubPageHeader(
                eyebrow: "Teach LocalFlow your language",
                title: "Dictionary",
                subtitle: "Names, products, acronyms, and automatic phrase replacements"
            ) {
                HStack(spacing: 10) {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(HubSecondaryButtonStyle())

                    Button {
                        model.saveDictionary()
                    } label: {
                        Label("Save dictionary", systemImage: "checkmark")
                    }
                    .buttonStyle(HubPrimaryButtonStyle())
                }
            }

            HStack(spacing: 14) {
                HubDictionaryEditor(
                    title: "Vocabulary",
                    subtitle: "One important word per line",
                    count: termCount,
                    placeholder: "LocalFlow\nCodex\nSupabase",
                    text: $model.termsText
                )

                HubDictionaryEditor(
                    title: "Replacements",
                    subtitle: "spoken phrase = final text",
                    count: replacementCount,
                    placeholder: "code ex = Codex\nlocal flow = LocalFlow",
                    text: $model.replacementsText
                )
            }

            HubCard(padding: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(HubPalette.purple.opacity(0.1))
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(HubPalette.purple)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep it focused")
                            .font(.system(size: 12, weight: .semibold))
                        Text("A concise dictionary of uncommon words improves recognition more reliably than a very large list.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 30)
    }
}

private struct HubDictionaryEditor: View {
    let title: String
    let subtitle: String
    let count: Int
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HubCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(HubPalette.purple)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(HubPalette.purple.opacity(0.1), in: Capsule())
                }
                .padding(18)

                Divider()

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                }
                .background(HubPalette.softFill.opacity(0.25))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LocalFlowSettingsView: View {
    @ObservedObject var model: LocalFlowHubModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HubPageHeader(
                    eyebrow: "Make it yours",
                    title: "Settings",
                    subtitle: "Models, shortcuts, language, and local behavior"
                ) {
                    Button {
                        model.saveSettings()
                    } label: {
                        Label("Save settings", systemImage: "checkmark")
                    }
                    .buttonStyle(HubPrimaryButtonStyle())
                }

                HubSettingsSection(
                    symbol: "circle.hexagongrid.fill",
                    title: "Orb Lab",
                    subtitle: "Administrator override for color, matter, and motion."
                ) {
                    HubOrbThemePicker(
                        selection: $model.configuration.orbThemeOverride
                    )
                }

                HubSettingsSection(
                    symbol: "sparkles",
                    title: "OpenAI & transcription",
                    subtitle: "Your API key remains in LocalFlow's local application data."
                ) {
                    HubSettingRow(
                        label: "API key",
                        help: "Used directly for transcription, Lissé, and Prompt Mode."
                    ) {
                        SecureField("sk-…", text: $model.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }

                    HubSettingRow(
                        label: "Transcription model",
                        help: "OpenAI audio transcription model."
                    ) {
                        TextField("gpt-4o-mini-transcribe", text: $model.configuration.transcriptionModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }

                    HubSettingRow(
                        label: "Language",
                        help: "ISO language hint sent with each recording."
                    ) {
                        TextField("fr", text: $model.configuration.transcriptionLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    HubSettingRow(
                        label: "Writing mode",
                        help: "Raw mode keeps your exact transcript, Lissé cleans it lightly, and Prompt turns it into a clear instruction while preserving your voice."
                    ) {
                        Picker(
                            "Writing mode",
                            selection: $model.configuration.outputMode
                        ) {
                            Text("Raw mode").tag(
                                DictationOutputMode.transcript
                            )
                            Text("Lissé").tag(
                                DictationOutputMode.polish
                            )
                            Text("Prompt").tag(
                                DictationOutputMode.prompt
                            )
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                    }

                    if model.configuration.outputMode == .polish {
                        HubSettingRow(
                            label: "Lissé model",
                            help: "Text model used for the optional cleanup pass."
                        ) {
                            TextField("gpt-4o-mini", text: $model.configuration.polishModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                        }
                    }

                    if model.configuration.outputMode == .prompt {
                        HubSettingRow(
                            label: "Prompt model",
                            help: "Fast text model used to clarify the transcript. GPT-5.6 Luna runs with reasoning disabled for low latency and stronger prompt quality."
                        ) {
                            TextField(
                                "gpt-5.6-luna",
                                text: $model.configuration.promptModel
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        }
                    }
                }

                HubSettingsSection(
                    symbol: "airpodspro",
                    title: "Audio input",
                    subtitle: "Keep Bluetooth playback clear while LocalFlow listens."
                ) {
                    HubSettingRow(
                        label: "Protect AirPods audio",
                        help: "When a Bluetooth headset is the active microphone, LocalFlow automatically uses the Mac microphone instead. This prevents macOS from switching the headset into low-quality call mode."
                    ) {
                        Toggle(
                            "",
                            isOn: $model.configuration
                                .preferBuiltInMicrophoneForBluetooth
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                HubSettingsSection(
                    symbol: "keyboard",
                    title: "Shortcuts",
                    subtitle: "Global shortcuts work while LocalFlow runs in the background."
                ) {
                    HubSettingRow(
                        label: "Hold to talk",
                        help: "Hold this key while speaking, then release."
                    ) {
                        TextField("fn", text: $model.configuration.holdHotkey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    HubSettingRow(
                        label: "Fallback hold",
                        help: "Reliable alternative when Fn is unavailable."
                    ) {
                        TextField("option+space", text: $model.configuration.fallbackHoldHotkey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    HubSettingRow(
                        label: "Hands-free toggle",
                        help: "Start or stop a locked recording."
                    ) {
                        TextField("fn+space", text: $model.configuration.toggleHotkey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    HubSettingRow(
                        label: "Cancel recording",
                        help: "Discards the current recording without transcribing or pasting."
                    ) {
                        Text("Escape")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(HubPalette.softFill, in: RoundedRectangle(cornerRadius: 7))
                    }
                }

                HubSettingsSection(
                    symbol: "lock.shield.fill",
                    title: "Local data & clipboard",
                    subtitle: "Control what LocalFlow keeps and how it restores your clipboard."
                ) {
                    HubSettingRow(
                        label: "History retention",
                        help: "Number of days transcripts remain in local history. Use 0 to keep them forever."
                    ) {
                        HStack(spacing: 7) {
                            TextField(
                                "0",
                                value: $model.configuration.historyRetentionDays,
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 82)
                            Text(model.configuration.historyRetentionDays == 0 ? "forever" : "days")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HubSettingRow(
                        label: "Restore clipboard",
                        help: "Return your previous clipboard content after text is pasted."
                    ) {
                        Toggle("", isOn: $model.configuration.restoreClipboardAfterPaste)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if model.configuration.restoreClipboardAfterPaste {
                        HubSettingRow(
                            label: "Restore delay",
                            help: "Wait before restoring the previous clipboard."
                        ) {
                            HStack(spacing: 7) {
                                TextField(
                                    "900",
                                    value: $model.configuration.pasteRestoreDelayMilliseconds,
                                    format: .number
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 82)
                                Text("ms")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 36)
        }
    }
}

private struct HubOrbThemePicker: View {
    @Binding var selection: String

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    selection = "automatic"
                }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(HubPalette.softFill)
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HubPalette.purple)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatic progression")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Unlock materials naturally as your word count grows.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    selectionMark(isSelected: selection == "automatic")
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(HubPalette.softFill.opacity(0.5))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            selection == "automatic"
                                ? HubPalette.purple.opacity(0.7)
                                : Color.primary.opacity(0.08),
                            lineWidth: selection == "automatic" ? 1.2 : 0.7
                        )
                }
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(OrbEvolution.themes) { theme in
                    orbButton(theme)
                }
            }

            Label(
                "Administrator mode unlocks every material immediately. Save settings to apply it to the floating bar.",
                systemImage: "lock.open.fill"
            )
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func orbButton(_ theme: OrbTheme) -> some View {
        let isSelected = selection == theme.id

        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                selection = theme.id
            }
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.highlight.color,
                                theme.secondary.color,
                                theme.primary.color,
                                theme.baseDark.color
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 25
                        )
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                theme.rim.color.opacity(0.58),
                                lineWidth: 0.7
                            )
                    }
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Label(theme.material.name, systemImage: theme.material.symbol)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)
                selectionMark(isSelected: isSelected)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? theme.primary.color.opacity(0.1)
                            : HubPalette.softFill.opacity(0.28)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected
                            ? theme.rim.color.opacity(0.76)
                            : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.2 : 0.7
                    )
            }
        }
        .buttonStyle(.plain)
        .help(theme.material.tagline)
        .accessibilityLabel(
            "\(theme.name), \(theme.material.name). \(theme.material.tagline)"
        )
        .accessibilityAddTraits(
            isSelected ? [.isSelected] : []
        )
    }

    private func selectionMark(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                isSelected ? HubPalette.purple : .secondary.opacity(0.45)
            )
    }
}

private struct HubSettingsSection<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HubCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(HubPalette.purple.opacity(0.1))
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HubPalette.purple)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)

                Divider()

                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }
}

private struct HubSettingRow<Control: View>: View {
    let label: String
    let help: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Text(help)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: 390, alignment: .leading)

            Spacer()
            control()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 18)
        }
    }
}

struct LocalFlowDiagnosticsView: View {
    @ObservedObject var model: LocalFlowHubModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HubPageHeader(
                    eyebrow: "Health & permissions",
                    title: "Diagnostics",
                    subtitle: "Everything LocalFlow needs to record, transcribe, and paste reliably"
                ) {
                    Button {
                        model.refresh()
                    } label: {
                        Label("Refresh status", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(HubSecondaryButtonStyle())
                }

                if let info = model.diagnosticInfo {
                    HStack(spacing: 14) {
                        HubDiagnosticStatusCard(
                            title: "Accessibility",
                            value: info.accessibilityStatus,
                            symbol: "cursorarrow.click.2",
                            isHealthy: info.accessibilityStatus == "Granted"
                        ) {
                            model.requestAccessibility()
                        }
                        HubDiagnosticStatusCard(
                            title: "Input Monitoring",
                            value: info.inputMonitoringStatus,
                            symbol: "keyboard.badge.ellipsis",
                            isHealthy: info.inputMonitoringStatus == "Granted"
                        ) {
                            model.requestInputMonitoring()
                        }
                        HubDiagnosticStatusCard(
                            title: "Hotkeys",
                            value: info.hotkeyStatus.contains("Active") ? "Active" : "Needs attention",
                            symbol: "command",
                            isHealthy: info.hotkeyStatus.contains("Active")
                        ) {
                            model.retryHotkeys()
                        }
                    }

                    HubCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Runtime status")
                                .font(.system(size: 15, weight: .bold, design: .rounded))

                            HubDiagnosticLine(label: "Hotkey engine", value: info.hotkeyStatus)
                            HubDiagnosticLine(label: "Last hotkey", value: info.lastHotkey)
                            HubDiagnosticLine(label: "Fn / Globe action", value: info.fnGlobeAction)

                            HStack(spacing: 10) {
                                Button("Restart hotkeys") {
                                    model.retryHotkeys()
                                }
                                .buttonStyle(HubSecondaryButtonStyle())

                                Button("Reload configuration") {
                                    model.refresh()
                                }
                                .buttonStyle(HubSecondaryButtonStyle())
                            }
                            .padding(.top, 4)
                        }
                    }

                    HubCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Local files")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                Spacer()
                                HStack(spacing: 10) {
                                    Button("Open folder") {
                                        model.openSupportFolderHandler?()
                                    }
                                    .buttonStyle(HubSecondaryButtonStyle())
                                    Button("Open log") {
                                        model.openDiagnosticLogHandler?()
                                    }
                                    .buttonStyle(HubSecondaryButtonStyle())
                                }
                            }

                            HubPathLine(label: "Configuration", value: info.envPath)
                            HubPathLine(label: "Dictionary", value: info.dictionaryPath)
                            HubPathLine(label: "History", value: info.historyPath)
                            HubPathLine(label: "Local data", value: info.localDataPath)
                            HubPathLine(label: "Diagnostic log", value: info.logPath)
                            HubPathLine(label: "Application", value: info.appPath)
                        }
                    }
                } else {
                    HubEmptyState(
                        symbol: "waveform.path.ecg",
                        title: "Loading diagnostics",
                        message: "LocalFlow is collecting runtime information."
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 36)
        }
    }
}

private struct HubDiagnosticStatusCard: View {
    let title: String
    let value: String
    let symbol: String
    let isHealthy: Bool
    let action: () -> Void

    var body: some View {
        HubCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill((isHealthy ? Color.green : Color.orange).opacity(0.11))
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isHealthy ? .green : .orange)
                    }
                    .frame(width: 34, height: 34)
                    Spacer()
                    Circle()
                        .fill(isHealthy ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(value)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !isHealthy {
                    Button("Fix") {
                        action()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HubPalette.purple)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HubDiagnosticLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }
}

private struct HubPathLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 18) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
