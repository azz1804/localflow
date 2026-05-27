import AppKit
import Foundation
import LocalFlowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configuration = AppConfiguration()
    private var dictionary = PersonalDictionary.empty
    private var envSourceURL: URL?
    private var dictionarySourceURL: URL?
    private var appSupportURL = LocalFlowPaths.appSupportDirectory
    private var historyURL = LocalFlowPaths.appSupportDirectory.appendingPathComponent("history.jsonl")

    private var statusItem: NSStatusItem?
    private var dictationController: DictationController?
    private var hotkeyController: HotkeyController?
    private var floatingBarController: FloatingBarController?
    private var settingsWindowController: SettingsWindowController?
    private var accessibilityRetryTimer: Timer?
    private var permissionRetryBaseline: (accessibility: Bool, inputMonitoring: Bool)?

    private let startStopMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleManualRecording), keyEquivalent: "")
    private let polishMenuItem = NSMenuItem(title: "Polish Dictation", action: #selector(togglePolish), keyEquivalent: "")
    private let hotkeyStatusMenuItem = NSMenuItem(title: "Hotkeys: Starting", action: #selector(retryHotkeys), keyEquivalent: "")
    private let lastHotkeyMenuItem = NSMenuItem(title: "Last hotkey: none", action: nil, keyEquivalent: "")
    private let accessibilityMenuItem = NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
    private let inputMonitoringMenuItem = NSMenuItem(title: "Request Input Monitoring Permission", action: #selector(requestInputMonitoringPermission), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try loadRuntimeConfiguration()
            LocalFlowLogger.log("Launch appPath=\(Bundle.main.bundlePath) bundleID=\(Bundle.main.bundleIdentifier ?? "-") hold=\(configuration.holdHotkey) fallback=\(configuration.fallbackHoldHotkey) toggle=\(configuration.toggleHotkey)")
            setupMenuBar()
            setupControllers()
            refreshPermissionMenuState()
            showMainWindow()
        } catch {
            setupMenuBar()
            showFatalError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityRetryTimer?.invalidate()
        hotkeyController?.stop()
    }

    private func loadRuntimeConfiguration() throws {
        appSupportURL = try LocalFlowPaths.ensureAppSupportDirectory()
        historyURL = try LocalFlowPaths.historyURL()

        let bundleResources = Bundle.main.resourceURL
        let envCandidates = LocalFlowPaths.envCandidates(bundleResourceURL: bundleResources)
        var loadedEnv = ProcessInfo.processInfo.environment

        for candidate in envCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            loadedEnv.merge(try EnvLoader.load(from: candidate)) { _, fileValue in fileValue }
            envSourceURL = candidate
            break
        }

        configuration = AppConfiguration(env: loadedEnv)

        let loadedDictionary = try DictionaryStore.load(
            candidates: LocalFlowPaths.dictionaryCandidates(bundleResourceURL: bundleResources)
        )
        dictionary = loadedDictionary.dictionary
        dictionarySourceURL = loadedDictionary.sourceURL

        let editableDictionaryURL = try DictionaryStore.ensureEditableDictionaryExists(
            appSupportDirectory: appSupportURL,
            fallback: dictionary
        )

        if dictionarySourceURL == nil || dictionarySourceURL?.standardizedFileURL != editableDictionaryURL.standardizedFileURL {
            dictionarySourceURL = editableDictionaryURL
        }

        let historyStore = HistoryStore(url: historyURL)
        try historyStore.prune(retentionDays: configuration.historyRetentionDays)
    }

    private func setupControllers() {
        let historyStore = HistoryStore(url: historyURL)
        let dictationController = DictationController(
            configuration: configuration,
            dictionary: dictionary,
            historyStore: historyStore
        )

        let floatingBarController = FloatingBarController()
        dictationController.onStatusChanged = { [weak self] status, level in
            self?.floatingBarController?.update(status: status, level: level)
            self?.updateMenu(for: status)
            if case .recording = status {
                return
            }
            self?.hotkeyController?.clearToggleRecordingState()
        }

        let hotkeyController = HotkeyController(
            holdHotkey: configuration.holdHotkey,
            fallbackHoldHotkey: configuration.fallbackHoldHotkey,
            toggleHotkey: configuration.toggleHotkey
        )

        hotkeyController.onHoldStart = { [weak self] in
            self?.dictationController?.beginHoldRecording()
        }
        hotkeyController.onHoldEnd = { [weak self] in
            self?.dictationController?.endHoldRecording()
        }
        hotkeyController.onToggle = { [weak self] in
            self?.dictationController?.toggleRecording()
        }
        hotkeyController.onDiagnosticEvent = { [weak self] event in
            self?.updateLastHotkey(event)
        }
        let started = hotkeyController.start()
        LocalFlowLogger.log("Initial hotkey start started=\(started) tap=\(hotkeyController.activeTapDescription) monitors=\(hotkeyController.monitorsAreInstalled) carbon=\(hotkeyController.carbonHotkeysAreRegistered) hid=\(hotkeyController.hidListenerIsRunning) accessibilityTrusted=\(PermissionManager.isAccessibilityTrusted(prompt: false)) inputMonitoringTrusted=\(PermissionManager.isInputMonitoringTrusted())")

        self.dictationController = dictationController
        self.floatingBarController = floatingBarController
        self.hotkeyController = hotkeyController
        refreshPermissionMenuState()

        if !PermissionManager.isAccessibilityTrusted(prompt: false) {
            floatingBarController.update(status: .error("Enable Accessibility so LocalFlow can paste into the active app."), level: 0)
            requestAccessibilityPermission()
        }

        if !started {
            scheduleHotkeyRetryAfterPermissionPrompt()
        } else if fnListenerNeedsInputMonitoring {
            floatingBarController.update(status: .error("Enable Input Monitoring for Fn. Option+Space can be used meanwhile."), level: 0)
            requestInputMonitoringPermission()
        }
    }

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "LF"
        }
        statusItem.button?.toolTip = "LocalFlow"

        let menu = NSMenu()
        startStopMenuItem.target = self
        menu.addItem(startStopMenuItem)

        polishMenuItem.target = self
        polishMenuItem.state = configuration.enablePolish ? .on : .off
        menu.addItem(polishMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Open LocalFlow", action: #selector(showMainWindow), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LocalFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func updateMenu(for status: AppStatus) {
        switch status {
        case .recording:
            startStopMenuItem.title = "Stop Recording"
        default:
            startStopMenuItem.title = "Start Recording"
        }
    }

    private func refreshPermissionMenuState() {
        let accessibilityTrusted = PermissionManager.isAccessibilityTrusted(prompt: false)
        accessibilityMenuItem.title = accessibilityTrusted ? "Accessibility Permission Granted" : "Enable Accessibility Permission"
        accessibilityMenuItem.isEnabled = !accessibilityTrusted

        let inputMonitoringTrusted = PermissionManager.isInputMonitoringTrusted()
        inputMonitoringMenuItem.title = inputMonitoringTrusted ? "Input Monitoring Permission Granted" : "Enable Input Monitoring Permission"
        inputMonitoringMenuItem.isEnabled = !inputMonitoringTrusted

        refreshFnSystemActionMenuState()
        updateHotkeyStatusMenu()
    }

    private func updateHotkeyStatusMenu() {
        if fnListenerNeedsInputMonitoring {
            hotkeyStatusMenuItem.title = "Fn blocked - Enable Input Monitoring"
            hotkeyStatusMenuItem.action = #selector(requestInputMonitoringPermission)
            hotkeyStatusMenuItem.isEnabled = true
            return
        }

        if hotkeyController?.isRunning == true {
            let tap = hotkeyController?.activeTapDescription ?? "none"
            let monitors = hotkeyController?.monitorsAreInstalled == true ? "+monitor" : ""
            let carbon = hotkeyController?.carbonHotkeysAreRegistered == true ? "+carbon" : ""
            let hid = hotkeyController?.hidListenerIsRunning == true ? "+hid" : ""
            hotkeyStatusMenuItem.title = "Hotkeys: Active (\(tap)\(monitors)\(carbon)\(hid))"
            hotkeyStatusMenuItem.action = #selector(retryHotkeys)
            hotkeyStatusMenuItem.isEnabled = false
        } else {
            hotkeyStatusMenuItem.title = "Hotkeys: Inactive - Retry"
            hotkeyStatusMenuItem.action = #selector(retryHotkeys)
            hotkeyStatusMenuItem.isEnabled = true
        }
    }

    private var fnListenerNeedsInputMonitoring: Bool {
        let holdHotkey = configuration.holdHotkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return holdHotkey == "fn"
            && hotkeyController?.activeTapDescription == "none"
            && !PermissionManager.isInputMonitoringTrusted()
    }

    private func updateLastHotkey(_ event: String) {
        let time = Self.timeFormatter.string(from: Date())
        lastHotkeyMenuItem.title = "Last hotkey: \(event) @ \(time)"
    }

    private func refreshFnSystemActionMenuState() {
    }

    private func showFatalError(_ error: Error) {
        floatingBarController?.update(status: .error(error.localizedDescription), level: 0)
    }

    @objc private func toggleManualRecording() {
        guard let dictationController else {
            return
        }

        if startStopMenuItem.title == "Stop Recording" {
            dictationController.stopManualRecording()
        } else {
            dictationController.startManualRecording()
        }
    }

    @objc private func togglePolish() {
        guard let dictationController else {
            return
        }

        dictationController.isPolishEnabled.toggle()
        configuration.enablePolish = dictationController.isPolishEnabled
        polishMenuItem.state = configuration.enablePolish ? .on : .off
    }

    @objc private func showMainWindow() {
        presentMainWindow(selectHistory: true)
    }

    private func presentMainWindow(selectHistory: Bool) {
        let settingsWindowController = self.settingsWindowController ?? SettingsWindowController()
        configureSettingsWindowCallbacks(settingsWindowController)
        settingsWindowController.update(
            configuration: configuration,
            dictionary: dictionary,
            historyRecords: loadHistoryRecords(),
            envSource: envSourceURL,
            dictionarySource: dictionarySourceURL,
            historyURL: historyURL,
            appSupportURL: appSupportURL,
            diagnosticInfo: makeDiagnosticInfo()
        )
        if selectHistory {
            settingsWindowController.selectHistoryTab()
        }
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindowController = settingsWindowController
    }

    @objc private func reloadConfiguration() {
        do {
            try loadRuntimeConfiguration()
            dictationController?.updateConfiguration(configuration, dictionary: dictionary)
            restartHotkeys()
            polishMenuItem.state = configuration.enablePolish ? .on : .off
            showMainWindow()
        } catch {
            floatingBarController?.update(status: .error(error.localizedDescription), level: 0)
        }
    }

    @objc private func openSupportFolder() {
        NSWorkspace.shared.open(appSupportURL)
    }

    @objc private func openDiagnosticLog() {
        let logURL = appSupportURL.appendingPathComponent("localflow.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            NSWorkspace.shared.open(appSupportURL)
        }
    }

    @objc private func requestAccessibilityPermission() {
        if PermissionManager.isAccessibilityTrusted(prompt: false) {
            refreshPermissionMenuState()
            if hotkeyController?.isRunning != true {
                restartHotkeys()
            }
            return
        }

        _ = PermissionManager.isAccessibilityTrusted(prompt: true)
        scheduleHotkeyRetryAfterPermissionPrompt()
    }

    @objc private func requestInputMonitoringPermission() {
        if PermissionManager.isInputMonitoringTrusted() {
            refreshPermissionMenuState()
            if hotkeyController?.activeTapDescription == "none" {
                restartHotkeys()
            }
            return
        }

        LocalFlowLogger.log("Request input monitoring permission")
        _ = PermissionManager.requestInputMonitoringAccess()
        scheduleHotkeyRetryAfterPermissionPrompt()
    }

    @objc private func retryHotkeys() {
        restartHotkeys()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func restartHotkeys() {
        hotkeyController?.stop()

        let hotkeyController = HotkeyController(
            holdHotkey: configuration.holdHotkey,
            fallbackHoldHotkey: configuration.fallbackHoldHotkey,
            toggleHotkey: configuration.toggleHotkey
        )
        hotkeyController.onHoldStart = { [weak dictationController] in
            dictationController?.beginHoldRecording()
        }
        hotkeyController.onHoldEnd = { [weak dictationController] in
            dictationController?.endHoldRecording()
        }
        hotkeyController.onToggle = { [weak dictationController] in
            dictationController?.toggleRecording()
        }
        hotkeyController.onDiagnosticEvent = { [weak self] event in
            self?.updateLastHotkey(event)
        }
        let started = hotkeyController.start()
        self.hotkeyController = hotkeyController
        LocalFlowLogger.log("Hotkey start started=\(started) tap=\(hotkeyController.activeTapDescription) monitors=\(hotkeyController.monitorsAreInstalled) carbon=\(hotkeyController.carbonHotkeysAreRegistered) hid=\(hotkeyController.hidListenerIsRunning) accessibilityTrusted=\(PermissionManager.isAccessibilityTrusted(prompt: false)) inputMonitoringTrusted=\(PermissionManager.isInputMonitoringTrusted())")
        refreshPermissionMenuState()

        if !started {
            scheduleHotkeyRetryAfterPermissionPrompt()
        }
    }

    private func scheduleHotkeyRetryAfterPermissionPrompt() {
        accessibilityRetryTimer?.invalidate()
        permissionRetryBaseline = (
            accessibility: PermissionManager.isAccessibilityTrusted(prompt: false),
            inputMonitoring: PermissionManager.isInputMonitoringTrusted()
        )
        accessibilityRetryTimer = Timer.scheduledTimer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(accessibilityRetryTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func accessibilityRetryTimerFired(_ timer: Timer) {
        let accessibilityTrusted = PermissionManager.isAccessibilityTrusted(prompt: false)
        let inputMonitoringTrusted = PermissionManager.isInputMonitoringTrusted()
        refreshPermissionMenuState()
        guard accessibilityTrusted != permissionRetryBaseline?.accessibility
                || inputMonitoringTrusted != permissionRetryBaseline?.inputMonitoring else {
            return
        }

        timer.invalidate()
        accessibilityRetryTimer = nil
        permissionRetryBaseline = nil
        restartHotkeys()
    }

    private func configureSettingsWindowCallbacks(_ controller: SettingsWindowController) {
        controller.onSaveSettings = { [weak self] updatedConfiguration in
            guard let self else {
                return .success(())
            }

            do {
                let url = self.appSupportURL.appendingPathComponent(".env")
                try ConfigurationStore.save(updatedConfiguration, to: url)
                self.envSourceURL = url
                self.configuration = updatedConfiguration
                try HistoryStore(url: self.historyURL).prune(retentionDays: updatedConfiguration.historyRetentionDays)
                self.dictationController?.updateConfiguration(updatedConfiguration, dictionary: self.dictionary)
                self.restartHotkeys()
                self.polishMenuItem.state = updatedConfiguration.enablePolish ? .on : .off
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        controller.onSaveDictionary = { [weak self] updatedDictionary in
            guard let self else {
                return .success(())
            }

            do {
                let url = self.appSupportURL.appendingPathComponent("dictionary.json")
                try DictionaryStore.save(updatedDictionary, to: url)
                self.dictionary = updatedDictionary
                self.dictionarySourceURL = url
                self.dictationController?.updateConfiguration(self.configuration, dictionary: updatedDictionary)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        controller.onClearHistory = { [weak self] in
            guard let self else {
                return .success(())
            }

            do {
                try HistoryStore(url: self.historyURL).clear()
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        controller.onRefresh = { [weak self] in
            guard let self else {
                return
            }

            do {
                try self.loadRuntimeConfiguration()
                self.dictationController?.updateConfiguration(self.configuration, dictionary: self.dictionary)
                self.restartHotkeys()
                self.polishMenuItem.state = self.configuration.enablePolish ? .on : .off
                self.presentMainWindow(selectHistory: false)
            } catch {
                self.floatingBarController?.update(status: .error(error.localizedDescription), level: 0)
            }
        }

        controller.onRequestAccessibility = { [weak self] in
            self?.requestAccessibilityPermission()
        }

        controller.onRequestInputMonitoring = { [weak self] in
            self?.requestInputMonitoringPermission()
        }

        controller.onOpenSupportFolder = { [weak self] in
            self?.openSupportFolder()
        }

        controller.onOpenDiagnosticLog = { [weak self] in
            self?.openDiagnosticLog()
        }

        controller.onRetryHotkeys = { [weak self] in
            self?.retryHotkeys()
            self?.presentMainWindow(selectHistory: false)
        }
    }

    private func makeDiagnosticInfo() -> LocalFlowDiagnosticInfo {
        refreshPermissionMenuState()

        let logURL = appSupportURL.appendingPathComponent("localflow.log")
        let envURL = envSourceURL ?? appSupportURL.appendingPathComponent(".env")
        let dictionaryURL = dictionarySourceURL ?? appSupportURL.appendingPathComponent("dictionary.json")

        return LocalFlowDiagnosticInfo(
            hotkeyStatus: hotkeyStatusMenuItem.title,
            lastHotkey: lastHotkeyMenuItem.title.replacingOccurrences(of: "Last hotkey: ", with: ""),
            accessibilityStatus: PermissionManager.isAccessibilityTrusted(prompt: false) ? "Granted" : "Missing",
            inputMonitoringStatus: PermissionManager.isInputMonitoringTrusted() ? "Granted" : "Missing",
            fnGlobeAction: Self.description(forFnUsageType: Self.fnUsageType),
            envPath: envURL.path,
            dictionaryPath: dictionaryURL.path,
            historyPath: historyURL.path,
            localDataPath: appSupportURL.path,
            logPath: logURL.path,
            appPath: Bundle.main.bundlePath
        )
    }

    private func loadHistoryRecords() -> [DictationRecord] {
        (try? HistoryStore(url: historyURL).load(limit: 500)) ?? []
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static var fnUsageType: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    private static func description(forFnUsageType usage: Int?) -> String {
        switch usage {
        case 0:
            return "Do Nothing"
        case 1:
            return "Change Input Source"
        case 2:
            return "Show Emoji & Symbols"
        case 3:
            return "Start Dictation"
        case let .some(value):
            return "Unknown (\(value))"
        case .none:
            return "Default"
        }
    }
}
