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

    private let startStopMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleManualRecording), keyEquivalent: "")
    private let polishMenuItem = NSMenuItem(title: "Polish Dictation", action: #selector(togglePolish), keyEquivalent: "")
    private let accessibilityMenuItem = NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try loadRuntimeConfiguration()
            setupControllers()
            setupMenuBar()
            requestAccessibilityPermissionIfNeeded()
        } catch {
            setupMenuBar()
            showFatalError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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

        if dictionarySourceURL == nil {
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
            self?.dictationController?.beginHoldRecording()
        }
        hotkeyController.onHoldEnd = { [weak self] in
            self?.dictationController?.endHoldRecording()
        }
        hotkeyController.onToggle = { [weak self] in
            self?.dictationController?.toggleRecording()
        }
        hotkeyController.start()

        self.dictationController = dictationController
        self.floatingBarController = floatingBarController
        self.hotkeyController = hotkeyController
    }

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LF"
        statusItem.button?.toolTip = "LocalFlow"

        let menu = NSMenu()
        startStopMenuItem.target = self
        menu.addItem(startStopMenuItem)

        polishMenuItem.target = self
        polishMenuItem.state = configuration.enablePolish ? .on : .off
        menu.addItem(polishMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reloadItem = NSMenuItem(title: "Reload .env and Dictionary", action: #selector(reloadConfiguration), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let openSupportItem = NSMenuItem(title: "Open Support Folder", action: #selector(openSupportFolder), keyEquivalent: "")
        openSupportItem.target = self
        menu.addItem(openSupportItem)

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

    private func requestAccessibilityPermissionIfNeeded() {
        _ = PermissionManager.isAccessibilityTrusted(prompt: true)
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
        settingsWindowController.update(
            configuration: configuration,
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
        _ = PermissionManager.isAccessibilityTrusted(prompt: true)
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
        hotkeyController.start()
        self.hotkeyController = hotkeyController
    }
}
