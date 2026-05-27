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

    private let startStopMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleManualRecording), keyEquivalent: "")
    private let polishMenuItem = NSMenuItem(title: "Polish Dictation", action: #selector(togglePolish), keyEquivalent: "")
    private let hotkeyStatusMenuItem = NSMenuItem(title: "Hotkeys: Starting", action: #selector(retryHotkeys), keyEquivalent: "")
    private let accessibilityMenuItem = NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try loadRuntimeConfiguration()
            LocalFlowLogger.log("Launch appPath=\(Bundle.main.bundlePath) bundleID=\(Bundle.main.bundleIdentifier ?? "-") hold=\(configuration.holdHotkey) fallback=\(configuration.fallbackHoldHotkey) toggle=\(configuration.toggleHotkey)")
            setupMenuBar()
            setupControllers()
            refreshAccessibilityMenuState()
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
        }

        let hotkeyController = HotkeyController(
            holdHotkey: configuration.holdHotkey,
            fallbackHoldHotkey: configuration.fallbackHoldHotkey,
            toggleHotkey: configuration.toggleHotkey
        )

        hotkeyController.onHoldStart = { [weak self] in
            LocalFlowLogger.log("Hotkey hold start")
            self?.dictationController?.beginHoldRecording()
        }
        hotkeyController.onHoldEnd = { [weak self] in
            LocalFlowLogger.log("Hotkey hold end")
            self?.dictationController?.endHoldRecording()
        }
        hotkeyController.onToggle = { [weak self] in
            LocalFlowLogger.log("Hotkey toggle")
            self?.dictationController?.toggleRecording()
        }
        let started = hotkeyController.start()
        LocalFlowLogger.log("Initial hotkey start started=\(started) tap=\(hotkeyController.activeTapDescription) monitors=\(hotkeyController.monitorsAreInstalled) carbon=\(hotkeyController.carbonHotkeysAreRegistered) accessibilityTrusted=\(PermissionManager.isAccessibilityTrusted(prompt: false))")

        self.dictationController = dictationController
        self.floatingBarController = floatingBarController
        self.hotkeyController = hotkeyController
        refreshAccessibilityMenuState()

        if !started {
            scheduleHotkeyRetryAfterAccessibilityPrompt()
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

        let settingsItem = NSMenuItem(title: "Open LocalFlow", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reloadItem = NSMenuItem(title: "Reload .env and Dictionary", action: #selector(reloadConfiguration), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let openSupportItem = NSMenuItem(title: "Open Support Folder", action: #selector(openSupportFolder), keyEquivalent: "")
        openSupportItem.target = self
        menu.addItem(openSupportItem)

        hotkeyStatusMenuItem.target = self
        menu.addItem(hotkeyStatusMenuItem)

        accessibilityMenuItem.target = self
        menu.addItem(accessibilityMenuItem)

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

    private func refreshAccessibilityMenuState() {
        let trusted = PermissionManager.isAccessibilityTrusted(prompt: false)
        accessibilityMenuItem.title = trusted ? "Accessibility Permission Granted" : "Enable Accessibility Permission"
        accessibilityMenuItem.isEnabled = !trusted
        updateHotkeyStatusMenu()
    }

    private func updateHotkeyStatusMenu() {
        if hotkeyController?.isRunning == true {
            let tap = hotkeyController?.activeTapDescription ?? "none"
            let monitors = hotkeyController?.monitorsAreInstalled == true ? "+monitor" : ""
            let carbon = hotkeyController?.carbonHotkeysAreRegistered == true ? "+carbon" : ""
            hotkeyStatusMenuItem.title = "Hotkeys: Active (\(tap)\(monitors)\(carbon))"
            hotkeyStatusMenuItem.isEnabled = false
        } else {
            hotkeyStatusMenuItem.title = "Hotkeys: Inactive - Retry"
            hotkeyStatusMenuItem.isEnabled = true
        }
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

    @objc private func showSettings() {
        let settingsWindowController = self.settingsWindowController ?? SettingsWindowController()
        configureSettingsWindowCallbacks(settingsWindowController)
        settingsWindowController.update(
            configuration: configuration,
            dictionary: dictionary,
            historyRecords: loadHistoryRecords(),
            envSource: envSourceURL,
            dictionarySource: dictionarySourceURL,
            historyURL: historyURL,
            appSupportURL: appSupportURL
        )
        settingsWindowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindowController = settingsWindowController
    }

    @objc private func reloadConfiguration() {
        do {
            try loadRuntimeConfiguration()
            dictationController?.updateConfiguration(configuration, dictionary: dictionary)
            restartHotkeys()
            polishMenuItem.state = configuration.enablePolish ? .on : .off
            showSettings()
        } catch {
            floatingBarController?.update(status: .error(error.localizedDescription), level: 0)
        }
    }

    @objc private func openSupportFolder() {
        NSWorkspace.shared.open(appSupportURL)
    }

    @objc private func requestAccessibilityPermission() {
        if PermissionManager.isAccessibilityTrusted(prompt: false) {
            refreshAccessibilityMenuState()
            if hotkeyController?.isRunning != true {
                restartHotkeys()
            }
            return
        }

        _ = PermissionManager.isAccessibilityTrusted(prompt: true)
        scheduleHotkeyRetryAfterAccessibilityPrompt()
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
            LocalFlowLogger.log("Hotkey hold start")
            dictationController?.beginHoldRecording()
        }
        hotkeyController.onHoldEnd = { [weak dictationController] in
            LocalFlowLogger.log("Hotkey hold end")
            dictationController?.endHoldRecording()
        }
        hotkeyController.onToggle = { [weak dictationController] in
            LocalFlowLogger.log("Hotkey toggle")
            dictationController?.toggleRecording()
        }
        let started = hotkeyController.start()
        self.hotkeyController = hotkeyController
        LocalFlowLogger.log("Hotkey start started=\(started) tap=\(hotkeyController.activeTapDescription) monitors=\(hotkeyController.monitorsAreInstalled) carbon=\(hotkeyController.carbonHotkeysAreRegistered) accessibilityTrusted=\(PermissionManager.isAccessibilityTrusted(prompt: false))")
        refreshAccessibilityMenuState()

        if !started {
            scheduleHotkeyRetryAfterAccessibilityPrompt()
        }
    }

    private func scheduleHotkeyRetryAfterAccessibilityPrompt() {
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = Timer.scheduledTimer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(accessibilityRetryTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func accessibilityRetryTimerFired(_ timer: Timer) {
        refreshAccessibilityMenuState()
        guard PermissionManager.isAccessibilityTrusted(prompt: false) else {
            return
        }

        timer.invalidate()
        accessibilityRetryTimer = nil
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
            self?.reloadConfiguration()
        }

        controller.onRequestAccessibility = { [weak self] in
            self?.requestAccessibilityPermission()
        }

        controller.onOpenSupportFolder = { [weak self] in
            self?.openSupportFolder()
        }
    }

    private func loadHistoryRecords() -> [DictationRecord] {
        (try? HistoryStore(url: historyURL).load(limit: 500)) ?? []
    }
}
