import AppKit
import Foundation
import LocalFlowCore
import ServiceManagement

@MainActor
enum AppLaunchPresentationPolicy {
    static func shouldOpenMainWindow(
        userInfo: [AnyHashable: Any]?,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        if arguments.contains("--show-dashboard") {
            return true
        }

        guard let value = userInfo?[NSApplication.launchIsDefaultUserInfoKey]
            as? NSNumber else {
            // Preserve the historical behavior on launchers that omit AppKit's
            // hint, while allowing login/restoration launches to stay quiet.
            return true
        }
        return value.boolValue
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configuration = AppConfiguration()
    private var dictionary = PersonalDictionary.empty
    private var envSourceURL: URL?
    private var dictionarySourceURL: URL?
    private var appSupportURL = LocalFlowPaths.appSupportDirectory
    private var historyURL = LocalFlowPaths.appSupportDirectory.appendingPathComponent("history.jsonl")
    private var historyRecordsCache: [DictationRecord] = []

    private var statusItem: NSStatusItem?
    private var dictationController: DictationController?
    private var hotkeyController: HotkeyController?
    private var floatingBarController: FloatingBarController?
    private var settingsWindowController: SettingsWindowController?
    private var accessibilityRetryTimer: Timer?
    private var permissionRetryBaseline: (accessibility: Bool, inputMonitoring: Bool)?
    private var hotkeyRestartCoordinator = HotkeyRestartCoordinator()
    private var terminationPreparationIsInFlight = false

    private let startStopMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleManualRecording), keyEquivalent: "")
    private let polishMenuItem = NSMenuItem(title: "Polish Dictation", action: #selector(togglePolish), keyEquivalent: "")
    private let hotkeyStatusMenuItem = NSMenuItem(title: "Hotkeys: Starting", action: #selector(retryHotkeys), keyEquivalent: "")
    private let lastHotkeyMenuItem = NSMenuItem(title: "Last hotkey: none", action: nil, keyEquivalent: "")
    private let accessibilityMenuItem = NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: "")
    private let inputMonitoringMenuItem = NSMenuItem(title: "Request Input Monitoring Permission", action: #selector(requestInputMonitoringPermission), keyEquivalent: "")

    nonisolated func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        let callbackValue = AppKitCallbackValue(value: notification)
        AppKitMainThreadBridge.run {
            applicationDidFinishLaunchingOnMainActor(callbackValue.value)
        }
    }

    private func applicationDidFinishLaunchingOnMainActor(
        _ notification: Notification
    ) {
        do {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(showDashboardFromActivationSignal(_:)),
                name: LocalFlowActivationSignal.showDashboard,
                object: nil
            )
            try loadRuntimeConfiguration()
            recoverOrphanedTemporaryAudio()
            LocalFlowLogger.log("Launch appPath=\(Bundle.main.bundlePath) bundleID=\(Bundle.main.bundleIdentifier ?? "-") commit=\(Bundle.main.object(forInfoDictionaryKey: "LocalFlowGitCommit") as? String ?? "unknown") hold=\(configuration.holdHotkey) fallback=\(configuration.fallbackHoldHotkey) toggle=\(configuration.toggleHotkey)")
            setupMenuBar()
            configureLaunchAtLogin()
            setupControllers()
            refreshPermissionMenuState()
            let activationRequested = LocalFlowActivationSignal
                .consumeDashboardRequest()
            if activationRequested || AppLaunchPresentationPolicy
                .shouldOpenMainWindow(userInfo: notification.userInfo) {
                showMainWindow()
            } else {
                LocalFlowLogger.log(
                    "Background launch; dashboard remains closed"
                )
            }
        } catch {
            setupMenuBar()
            configureLaunchAtLogin()
            showFatalError(error)
        }
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        AppKitMainThreadBridge.run {
            applicationWillTerminateOnMainActor()
        }
    }

    private func applicationWillTerminateOnMainActor() {
        LocalFlowLogger.log("Application will terminate")
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: LocalFlowActivationSignal.showDashboard,
            object: nil
        )
        accessibilityRetryTimer?.invalidate()
        hotkeyController?.stop()
        LocalFlowLogger.flush()
    }

    nonisolated func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let callbackValue = AppKitCallbackValue(value: sender)
        return AppKitMainThreadBridge.run {
            applicationShouldTerminateOnMainActor(callbackValue.value)
        }
    }

    private func applicationShouldTerminateOnMainActor(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !terminationPreparationIsInFlight else {
            return .terminateLater
        }
        guard let dictationController,
              dictationController.canCancelRecording else {
            LocalFlowLogger.flush()
            return .terminateNow
        }

        terminationPreparationIsInFlight = true
        Task { @MainActor [weak self, weak sender] in
            await dictationController.prepareForTermination()
            LocalFlowLogger.flush()
            self?.terminationPreparationIsInFlight = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        AppKitMainThreadBridge.run {
            applicationShouldHandleReopenOnMainActor()
        }
    }

    private func applicationShouldHandleReopenOnMainActor() -> Bool {
        showMainWindow()
        return true
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        AppKitMainThreadBridge.run {
            applicationShouldTerminateAfterLastWindowClosedOnMainActor()
        }
    }

    private func applicationShouldTerminateAfterLastWindowClosedOnMainActor() -> Bool {
        return false
    }

    private func loadRuntimeConfiguration() throws {
        appSupportURL = try LocalFlowPaths.ensureAppSupportDirectory()
        historyURL = try LocalFlowPaths.historyURL()

        let bundleResources = Bundle.main.resourceURL
        let envCandidates = LocalFlowPaths.envCandidates(bundleResourceURL: bundleResources)
        var loadedEnv = ProcessInfo.processInfo.environment

        for candidate in envCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            do {
                loadedEnv.merge(try EnvLoader.load(from: candidate)) {
                    _, fileValue in fileValue
                }
                envSourceURL = candidate
                break
            } catch {
                LocalFlowLogger.log(
                    "Configuration candidate skipped file=\(candidate.lastPathComponent) error=\(error.localizedDescription)"
                )
            }
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
        do {
            try historyStore.prune(
                retentionDays: configuration.historyRetentionDays
            )
            historyRecordsCache = try historyStore.load()
        } catch {
            // History is valuable but must not prevent recording/hotkeys from
            // starting. Durable jobs will retry their append when storage heals.
            historyRecordsCache = []
            LocalFlowLogger.log(
                "History startup degraded error=\(error.localizedDescription)"
            )
        }
    }

    private func setupControllers() {
        let historyStore = HistoryStore(url: historyURL)
        let dictationController = DictationController(
            configuration: configuration,
            dictionary: dictionary,
            historyStore: historyStore
        )

        let floatingBarController = FloatingBarController()
        dictationController.onStatusChanged = { [weak self] status, visualization in
            self?.floatingBarController?.update(
                status: status,
                visualization: visualization
            )
            self?.updateMenu(for: status)
            if case .recording = status {
                self?.hotkeyController?.setApplicationRecordingActive(true)
                return
            }
            self?.hotkeyController?.clearToggleRecordingState()
            self?.performDeferredHotkeyRestartIfNeeded()
        }
        dictationController.onRecordingFrame = { [weak self] status, visualization in
            self?.floatingBarController?.update(
                status: status,
                visualization: visualization
            )
        }
        dictationController.onHistoryRecordCreated = { [weak self] record in
            self?.cacheHistoryRecord(record)
            self?.settingsWindowController?.insertHistoryRecord(record)
            self?.refreshOrbProgression()
        }
        dictationController.onInsertionCompleted = { [weak self] outcome in
            self?.settingsWindowController?.showInsertionOutcome(outcome)
        }

        let hotkeyController = HotkeyController(
            holdHotkey: configuration.holdHotkey,
            fallbackHoldHotkey: configuration.fallbackHoldHotkey,
            toggleHotkey: configuration.toggleHotkey
        )

        configureHotkeyCallbacks(
            hotkeyController,
            dictationController: dictationController
        )
        let started = hotkeyController.start()
        LocalFlowLogger.log("Initial hotkey start started=\(started) tap=\(hotkeyController.activeTapDescription) monitors=\(hotkeyController.monitorsAreInstalled) carbon=\(hotkeyController.carbonHotkeysAreRegistered) hid=\(hotkeyController.hidListenerIsRunning) accessibilityTrusted=\(PermissionManager.isAccessibilityTrusted(prompt: false)) inputMonitoringTrusted=\(PermissionManager.isInputMonitoringTrusted())")

        self.dictationController = dictationController
        self.floatingBarController = floatingBarController
        self.hotkeyController = hotkeyController
        refreshOrbProgression()
        refreshPermissionMenuState()

        if !PermissionManager.isAccessibilityTrusted(prompt: false) {
            floatingBarController.update(
                status: .error("Enable Accessibility so LocalFlow can paste into the active app.")
            )
            requestAccessibilityPermission()
        }

        if !started {
            scheduleHotkeyRetryAfterPermissionPrompt()
        } else if fnListenerNeedsInputMonitoring {
            floatingBarController.update(
                status: .error("Enable Input Monitoring for Fn. Option+Space can be used meanwhile.")
            )
            requestInputMonitoringPermission()
        }

        dictationController.resumePendingDictations()
    }

    private func recoverOrphanedTemporaryAudio() {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let orphanedFiles = files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("LocalFlow-") && url.pathExtension == "wav"
                || name.hasPrefix("LocalFlow-upload-") && url.pathExtension == "m4a"
        }
        guard !orphanedFiles.isEmpty else {
            return
        }

        let recoveryDirectory = appSupportURL.appendingPathComponent(
            "recovered-audio",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for sourceURL in orphanedFiles {
            let modificationDate = try? sourceURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard modificationDate?.timeIntervalSinceNow ?? -1 < -30 else {
                continue
            }
            let destinationURL = recoveryDirectory
                .appendingPathComponent("orphan-\(UUID().uuidString)")
                .appendingPathExtension(sourceURL.pathExtension)
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationURL.path
                )
                LocalFlowLogger.log(
                    "Recovered orphan audio path=\(destinationURL.lastPathComponent)"
                )
            } catch {
                LocalFlowLogger.log(
                    "Orphan audio recovery failed file=\(sourceURL.lastPathComponent) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        statusItem.autosaveName = "LocalFlow.StatusItem"
        statusItem.behavior = []
        statusItem.isVisible = true

        if let icon = makeStatusItemIcon() {
            icon.isTemplate = false
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.imageScaling = .scaleProportionallyDown
        } else {
            statusItem.button?.title = "LF"
        }
        statusItem.button?.toolTip = "LocalFlow"
        statusItem.button?.setAccessibilityLabel("LocalFlow menu")

        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Open LocalFlow",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(
            title: "Open History",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        historyItem.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "Open History"
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        startStopMenuItem.target = self
        menu.addItem(startStopMenuItem)

        polishMenuItem.target = self
        polishMenuItem.state = configuration.enablePolish ? .on : .off
        menu.addItem(polishMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit LocalFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func makeStatusItemIcon() -> NSImage? {
        if let url = Bundle.main.url(
            forResource: "MenuBarOrb",
            withExtension: "png"
        ),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "LocalFlow"
            return image
        }

        return NSImage(
            systemSymbolName: "circle.hexagongrid.fill",
            accessibilityDescription: "LocalFlow"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: 16,
                weight: .semibold
            )
        )
    }

    private func configureLaunchAtLogin() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            return
        }

        let service = SMAppService.mainApp
        LocalFlowLogger.log(
            "Launch at login status=\(String(describing: service.status))"
        )
        guard service.status != .enabled,
              service.status != .requiresApproval else {
            return
        }

        do {
            try service.register()
            LocalFlowLogger.log("Launch at login registered")
        } catch {
            LocalFlowLogger.log(
                "Launch at login registration failed: \(error.localizedDescription)"
            )
        }
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
        LocalFlowLogger.log("Fatal startup error=\(error.localizedDescription)")

        if let floatingBarController {
            floatingBarController.update(status: .error(error.localizedDescription))
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "LocalFlow could not start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc nonisolated private func toggleManualRecording() {
        AppKitMainThreadBridge.run {
            toggleManualRecordingOnMainActor()
        }
    }

    private func toggleManualRecordingOnMainActor() {
        guard let dictationController else {
            return
        }

        if startStopMenuItem.title == "Stop Recording" {
            dictationController.stopManualRecording()
        } else {
            dictationController.startManualRecording()
        }
    }

    @objc nonisolated private func togglePolish() {
        AppKitMainThreadBridge.run {
            togglePolishOnMainActor()
        }
    }

    private func togglePolishOnMainActor() {
        guard let dictationController else {
            return
        }

        dictationController.isPolishEnabled.toggle()
        configuration.enablePolish = dictationController.isPolishEnabled
        polishMenuItem.state = configuration.enablePolish ? .on : .off
    }

    @objc nonisolated private func showMainWindow() {
        AppKitMainThreadBridge.run {
            showMainWindowOnMainActor()
        }
    }

    private func showMainWindowOnMainActor() {
        presentMainWindow(selectHistory: false, selectHome: true)
    }

    @objc nonisolated private func showDashboardFromActivationSignal(
        _ notification: Notification
    ) {
        AppKitMainThreadBridge.run {
            LocalFlowActivationSignal.consumeDashboardRequest()
            showMainWindowOnMainActor()
        }
    }

    @objc nonisolated private func showHistory() {
        AppKitMainThreadBridge.run {
            showHistoryOnMainActor()
        }
    }

    private func showHistoryOnMainActor() {
        presentMainWindow(selectHistory: true)
    }

    private func presentMainWindow(selectHistory: Bool, selectHome: Bool = false) {
        refreshOrbProgression()
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
        if selectHome {
            settingsWindowController.selectHomeTab()
        } else if selectHistory {
            settingsWindowController.selectHistoryTab()
        }
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindowController = settingsWindowController
    }

    @objc nonisolated private func reloadConfiguration() {
        AppKitMainThreadBridge.run {
            reloadConfigurationOnMainActor()
        }
    }

    private func reloadConfigurationOnMainActor() {
        do {
            try loadRuntimeConfiguration()
            dictationController?.updateConfiguration(configuration, dictionary: dictionary)
            restartHotkeys()
            polishMenuItem.state = configuration.enablePolish ? .on : .off
            showMainWindow()
        } catch {
            floatingBarController?.update(status: .error(error.localizedDescription))
        }
    }

    @objc nonisolated private func openSupportFolder() {
        AppKitMainThreadBridge.run {
            openSupportFolderOnMainActor()
        }
    }

    private func openSupportFolderOnMainActor() {
        NSWorkspace.shared.open(appSupportURL)
    }

    @objc nonisolated private func openDiagnosticLog() {
        AppKitMainThreadBridge.run {
            openDiagnosticLogOnMainActor()
        }
    }

    private func openDiagnosticLogOnMainActor() {
        let logURL = appSupportURL.appendingPathComponent("localflow.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            NSWorkspace.shared.open(appSupportURL)
        }
    }

    @objc nonisolated private func requestAccessibilityPermission() {
        AppKitMainThreadBridge.run {
            requestAccessibilityPermissionOnMainActor()
        }
    }

    private func requestAccessibilityPermissionOnMainActor() {
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

    @objc nonisolated private func requestInputMonitoringPermission() {
        AppKitMainThreadBridge.run {
            requestInputMonitoringPermissionOnMainActor()
        }
    }

    private func requestInputMonitoringPermissionOnMainActor() {
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

    @objc nonisolated private func retryHotkeys() {
        AppKitMainThreadBridge.run {
            retryHotkeysOnMainActor()
        }
    }

    private func retryHotkeysOnMainActor() {
        restartHotkeys()
    }

    @objc nonisolated private func quit() {
        AppKitMainThreadBridge.run {
            quitOnMainActor()
        }
    }

    private func quitOnMainActor() {
        NSApplication.shared.terminate(nil)
    }

    private func restartHotkeys(reason: String = "requested") {
        let recordingIsActive = dictationController?.canCancelRecording == true
        guard hotkeyRestartCoordinator.requestRestart(
            recordingIsActive: recordingIsActive
        ) else {
            LocalFlowLogger.log(
                "Hotkey restart deferred reason=\(reason) recording=true"
            )
            return
        }

        performHotkeyRestart(reason: reason)
    }

    private func performHotkeyRestart(reason: String) {
        hotkeyController?.stop()

        let hotkeyController = HotkeyController(
            holdHotkey: configuration.holdHotkey,
            fallbackHoldHotkey: configuration.fallbackHoldHotkey,
            toggleHotkey: configuration.toggleHotkey
        )
        configureHotkeyCallbacks(
            hotkeyController,
            dictationController: dictationController
        )
        let started = hotkeyController.start()
        hotkeyController.setApplicationRecordingActive(
            dictationController?.canCancelRecording == true
        )
        self.hotkeyController = hotkeyController
        LocalFlowLogger.log("Hotkey start reason=\(reason) started=\(started) tap=\(hotkeyController.activeTapDescription) monitors=\(hotkeyController.monitorsAreInstalled) carbon=\(hotkeyController.carbonHotkeysAreRegistered) hid=\(hotkeyController.hidListenerIsRunning) accessibilityTrusted=\(PermissionManager.isAccessibilityTrusted(prompt: false)) inputMonitoringTrusted=\(PermissionManager.isInputMonitoringTrusted())")
        refreshPermissionMenuState()

        if !started {
            scheduleHotkeyRetryAfterPermissionPrompt()
        }
    }

    private func configureHotkeyCallbacks(
        _ hotkeyController: HotkeyController,
        dictationController: DictationController?
    ) {
        hotkeyController.onHoldStart = { [weak dictationController] in
            dictationController?.beginHoldRecording()
        }
        hotkeyController.onHoldEnd = { [weak dictationController] in
            dictationController?.endHoldRecording()
        }
        hotkeyController.onHoldLocked = { [weak dictationController] in
            dictationController?.lockCurrentHoldRecording()
        }
        hotkeyController.onToggle = { [weak dictationController] in
            dictationController?.toggleRecording()
        }
        hotkeyController.onCancel = { [weak dictationController] in
            dictationController?.cancelRecording()
        }
        hotkeyController.recordingCancellationIsAvailable = {
            [weak dictationController] in
            dictationController?.canCancelRecording == true
        }
        hotkeyController.onDiagnosticEvent = { [weak self] event in
            self?.updateLastHotkey(event)
        }
    }

    private func performDeferredHotkeyRestartIfNeeded() {
        guard hotkeyRestartCoordinator.consumeDeferredRestart(
            recordingIsActive: dictationController?.canCancelRecording == true
        ) else {
            return
        }

        // Let the current key event finish before replacing its event tap.
        Task { @MainActor [weak self] in
            self?.restartHotkeys(reason: "deferred-after-recording")
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

    @objc nonisolated private func accessibilityRetryTimerFired(
        _ timer: Timer
    ) {
        let callbackValue = AppKitCallbackValue(value: timer)
        AppKitMainThreadBridge.run {
            accessibilityRetryTimerFiredOnMainActor(callbackValue.value)
        }
    }

    private func accessibilityRetryTimerFiredOnMainActor(_ timer: Timer) {
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
        controller.onWindowClosed = { [weak self, weak controller] in
            guard let self,
                  self.settingsWindowController === controller else {
                return
            }
            self.settingsWindowController = nil
        }
        controller.onSaveSettings = { [weak self] updatedConfiguration in
            guard let self else {
                return .success(())
            }

            do {
                let url = self.appSupportURL.appendingPathComponent(".env")
                try ConfigurationStore.save(updatedConfiguration, to: url)
                self.envSourceURL = url
                self.configuration = updatedConfiguration
                let historyStore = HistoryStore(url: self.historyURL)
                try historyStore.prune(retentionDays: updatedConfiguration.historyRetentionDays)
                self.historyRecordsCache = try historyStore.load()
                self.refreshOrbProgression()
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
                self.historyRecordsCache = []
                self.floatingBarController?.updateTotalWords(
                    0,
                    overrideID: self.configuration.orbThemeOverride
                )
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
                self.floatingBarController?.update(status: .error(error.localizedDescription))
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
        historyRecordsCache
    }

    private func cacheHistoryRecord(_ record: DictationRecord) {
        historyRecordsCache.removeAll { $0.id == record.id }
        historyRecordsCache.insert(record, at: 0)
    }

    private func refreshOrbProgression() {
        let totalWords = DictationInsightsCalculator.make(
            records: loadHistoryRecords()
        ).totalWords
        floatingBarController?.updateTotalWords(
            totalWords,
            overrideID: configuration.orbThemeOverride
        )
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
