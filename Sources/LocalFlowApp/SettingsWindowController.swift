import AppKit
import LocalFlowCore
import SwiftUI

struct LocalFlowDiagnosticInfo: Equatable {
    var hotkeyStatus: String
    var lastHotkey: String
    var accessibilityStatus: String
    var inputMonitoringStatus: String
    var fnGlobeAction: String
    var envPath: String
    var dictionaryPath: String
    var historyPath: String
    var localDataPath: String
    var logPath: String
    var appPath: String
}

enum LocalFlowHubSection: String, CaseIterable, Identifiable {
    case home
    case history
    case insights
    case dictionary
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .history:
            return "History"
        case .insights:
            return "Words & Stats"
        case .dictionary:
            return "Dictionary"
        case .settings:
            return "Settings"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .home:
            return "house.fill"
        case .history:
            return "clock.arrow.circlepath"
        case .insights:
            return "chart.xyaxis.line"
        case .dictionary:
            return "character.book.closed.fill"
        case .settings:
            return "slider.horizontal.3"
        case .diagnostics:
            return "waveform.path.ecg"
        }
    }
}

struct LocalFlowHistoryGroup: Identifiable {
    var date: Date
    var records: [DictationRecord]

    var id: Date { date }
}

@MainActor
final class LocalFlowHubModel: ObservableObject {
    @Published var selectedSection: LocalFlowHubSection = .home
    @Published var configuration = AppConfiguration()
    @Published var apiKey = ""
    @Published var historyRecords: [DictationRecord] = []
    @Published var insights = DictationInsights.empty
    @Published var historySearch = ""
    @Published var selectedHistoryID: UUID?
    @Published var termsText = ""
    @Published var replacementsText = ""
    @Published var diagnosticInfo: LocalFlowDiagnosticInfo?
    @Published var statusMessage = ""
    @Published var statusIsError = false

    var saveSettingsHandler: ((AppConfiguration) -> Result<Void, Error>)?
    var saveDictionaryHandler: ((PersonalDictionary) -> Result<Void, Error>)?
    var clearHistoryHandler: (() -> Result<Void, Error>)?
    var refreshHandler: (() -> Void)?
    var requestAccessibilityHandler: (() -> Void)?
    var requestInputMonitoringHandler: (() -> Void)?
    var openSupportFolderHandler: (() -> Void)?
    var openDiagnosticLogHandler: (() -> Void)?
    var retryHotkeysHandler: (() -> Void)?

    private var statusTask: Task<Void, Never>?

    var filteredHistoryRecords: [DictationRecord] {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return historyRecords
        }

        return historyRecords.filter { record in
            record.finalText.localizedCaseInsensitiveContains(query)
                || record.transcribedText.localizedCaseInsensitiveContains(query)
                || (record.targetApplication?.displayName.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var historyGroups: [LocalFlowHistoryGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredHistoryRecords) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            LocalFlowHistoryGroup(
                date: date,
                records: grouped[date, default: []].sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    var selectedHistoryRecord: DictationRecord? {
        guard let selectedHistoryID else {
            return filteredHistoryRecords.first
        }
        return historyRecords.first { $0.id == selectedHistoryID }
    }

    func update(
        configuration: AppConfiguration,
        dictionary: PersonalDictionary,
        historyRecords: [DictationRecord],
        diagnosticInfo: LocalFlowDiagnosticInfo
    ) {
        self.configuration = configuration
        apiKey = configuration.openAIAPIKey ?? ""
        self.historyRecords = historyRecords
        insights = DictationInsightsCalculator.make(records: historyRecords)
        self.diagnosticInfo = diagnosticInfo
        termsText = dictionary.terms.joined(separator: "\n")
        replacementsText = dictionary.replacements
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")

        if selectedHistoryID == nil || !historyRecords.contains(where: { $0.id == selectedHistoryID }) {
            selectedHistoryID = historyRecords.first?.id
        }
    }

    func saveSettings() {
        var updated = configuration
        updated.openAIAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.historyRetentionDays = max(1, updated.historyRetentionDays)
        updated.pasteRestoreDelayMilliseconds = max(0, updated.pasteRestoreDelayMilliseconds)

        switch saveSettingsHandler?(updated) ?? .success(()) {
        case .success:
            configuration = updated
            showStatus("Settings saved")
        case let .failure(error):
            showStatus(error.localizedDescription, isError: true)
        }
    }

    func saveDictionary() {
        do {
            let dictionary = try parsedDictionary()
            switch saveDictionaryHandler?(dictionary) ?? .success(()) {
            case .success:
                showStatus("Dictionary saved")
            case let .failure(error):
                showStatus(error.localizedDescription, isError: true)
            }
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    func clearHistory() {
        switch clearHistoryHandler?() ?? .success(()) {
        case .success:
            historyRecords = []
            selectedHistoryID = nil
            insights = .empty
            showStatus("History cleared")
        case let .failure(error):
            showStatus(error.localizedDescription, isError: true)
        }
    }

    func copy(_ record: DictationRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.finalText, forType: .string)
        showStatus("Copied to clipboard")
    }

    func refresh() {
        refreshHandler?()
        showStatus("Data refreshed")
    }

    func retryHotkeys() {
        retryHotkeysHandler?()
        showStatus("Hotkeys restarted")
    }

    func requestAccessibility() {
        requestAccessibilityHandler?()
        showStatus("Accessibility request opened")
    }

    func requestInputMonitoring() {
        requestInputMonitoringHandler?()
        showStatus("Input Monitoring request opened")
    }

    func showStatus(_ message: String, isError: Bool = false) {
        statusTask?.cancel()
        statusMessage = message
        statusIsError = isError

        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            self?.statusMessage = ""
        }
    }

    private func parsedDictionary() throws -> PersonalDictionary {
        let terms = termsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var replacements: [String: String] = [:]
        for rawLine in replacementsText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }
            guard let separator = line.range(of: "=") else {
                throw DictionaryEditorError.invalidReplacement(line)
            }

            let source = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let target = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !target.isEmpty else {
                throw DictionaryEditorError.invalidReplacement(line)
            }
            replacements[source] = target
        }

        return PersonalDictionary(terms: terms, replacements: replacements)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    var onSaveSettings: ((AppConfiguration) -> Result<Void, Error>)?
    var onSaveDictionary: ((PersonalDictionary) -> Result<Void, Error>)?
    var onClearHistory: (() -> Result<Void, Error>)?
    var onRefresh: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestInputMonitoring: (() -> Void)?
    var onOpenSupportFolder: (() -> Void)?
    var onOpenDiagnosticLog: (() -> Void)?
    var onRetryHotkeys: (() -> Void)?

    private let model: LocalFlowHubModel

    init() {
        let model = LocalFlowHubModel()
        self.model = model

        let hostingController = NSHostingController(rootView: LocalFlowHubView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "LocalFlow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 940, height: 640)
        window.animationBehavior = .documentWindow
        window.setFrameAutosaveName("LocalFlowHubWindow")
        window.center()

        super.init(window: window)
        configureModelActions()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(
        configuration: AppConfiguration,
        dictionary: PersonalDictionary,
        historyRecords: [DictationRecord],
        envSource: URL?,
        dictionarySource: URL?,
        historyURL: URL,
        appSupportURL: URL,
        diagnosticInfo: LocalFlowDiagnosticInfo
    ) {
        model.update(
            configuration: configuration,
            dictionary: dictionary,
            historyRecords: historyRecords,
            diagnosticInfo: diagnosticInfo
        )
    }

    func selectHistoryTab() {
        model.selectedSection = .history
    }

    func selectHomeTab() {
        model.selectedSection = .home
    }

    private func configureModelActions() {
        model.saveSettingsHandler = { [weak self] configuration in
            self?.onSaveSettings?(configuration) ?? .success(())
        }
        model.saveDictionaryHandler = { [weak self] dictionary in
            self?.onSaveDictionary?(dictionary) ?? .success(())
        }
        model.clearHistoryHandler = { [weak self] in
            self?.onClearHistory?() ?? .success(())
        }
        model.refreshHandler = { [weak self] in
            self?.onRefresh?()
        }
        model.requestAccessibilityHandler = { [weak self] in
            self?.onRequestAccessibility?()
        }
        model.requestInputMonitoringHandler = { [weak self] in
            self?.onRequestInputMonitoring?()
        }
        model.openSupportFolderHandler = { [weak self] in
            self?.onOpenSupportFolder?()
        }
        model.openDiagnosticLogHandler = { [weak self] in
            self?.onOpenDiagnosticLog?()
        }
        model.retryHotkeysHandler = { [weak self] in
            self?.onRetryHotkeys?()
        }
    }
}

private enum DictionaryEditorError: LocalizedError {
    case invalidReplacement(String)

    var errorDescription: String? {
        switch self {
        case let .invalidReplacement(line):
            return "Invalid replacement: \(line)"
        }
    }
}
