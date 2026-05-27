import AppKit
import LocalFlowCore

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    var onSaveSettings: ((AppConfiguration) -> Result<Void, Error>)?
    var onSaveDictionary: ((PersonalDictionary) -> Result<Void, Error>)?
    var onClearHistory: (() -> Result<Void, Error>)?
    var onRefresh: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestInputMonitoring: (() -> Void)?
    var onOpenSupportFolder: (() -> Void)?

    private var configuration = AppConfiguration()
    private var dictionary = PersonalDictionary.empty
    private var historyRecords: [DictationRecord] = []

    private let tabView = NSTabView()
    private let statusLabel = NSTextField(labelWithString: "")

    private let apiKeyField = NSSecureTextField()
    private let transcriptionModelField = NSTextField()
    private let languageField = NSTextField()
    private let polishCheckbox = NSButton(checkboxWithTitle: "Enable polish", target: nil, action: nil)
    private let polishModelField = NSTextField()
    private let holdHotkeyField = NSTextField()
    private let fallbackHoldHotkeyField = NSTextField()
    private let toggleHotkeyField = NSTextField()
    private let historyRetentionField = NSTextField()
    private let restoreClipboardCheckbox = NSButton(checkboxWithTitle: "Restore clipboard after paste", target: nil, action: nil)
    private let pasteDelayField = NSTextField()
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let envPathLabel = NSTextField(labelWithString: "")
    private let dictionaryPathLabel = NSTextField(labelWithString: "")

    private let historyTableView = NSTableView()
    private let historyDetailView = NSTextView()
    private let historyCountLabel = NSTextField(labelWithString: "")
    private weak var historySplitView: NSSplitView?

    private let termsTextView = NSTextView()
    private let replacementsTextView = NSTextView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalFlow"
        window.minSize = NSSize(width: 760, height: 540)
        window.center()

        super.init(window: window)

        buildInterface()
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
        appSupportURL: URL
    ) {
        self.configuration = configuration
        self.dictionary = dictionary
        self.historyRecords = historyRecords

        apiKeyField.stringValue = configuration.openAIAPIKey ?? ""
        transcriptionModelField.stringValue = configuration.transcriptionModel
        languageField.stringValue = configuration.transcriptionLanguage
        polishCheckbox.state = configuration.enablePolish ? .on : .off
        polishModelField.stringValue = configuration.polishModel
        holdHotkeyField.stringValue = configuration.holdHotkey
        fallbackHoldHotkeyField.stringValue = configuration.fallbackHoldHotkey
        toggleHotkeyField.stringValue = configuration.toggleHotkey
        historyRetentionField.stringValue = String(configuration.historyRetentionDays)
        restoreClipboardCheckbox.state = configuration.restoreClipboardAfterPaste ? .on : .off
        pasteDelayField.stringValue = String(configuration.pasteRestoreDelayMilliseconds)

        accessibilityStatusLabel.stringValue = PermissionManager.isAccessibilityTrusted(prompt: false) ? "Granted" : "Missing"
        inputMonitoringStatusLabel.stringValue = PermissionManager.isInputMonitoringTrusted() ? "Granted" : "Missing"
        envPathLabel.stringValue = envSource?.path ?? appSupportURL.appendingPathComponent(".env").path
        dictionaryPathLabel.stringValue = dictionarySource?.path ?? appSupportURL.appendingPathComponent("dictionary.json").path

        termsTextView.string = dictionary.terms.joined(separator: "\n")
        replacementsTextView.string = dictionary.replacements
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key) = \($0.value)" }
            .joined(separator: "\n")

        refreshHistoryDisplay()
        setStatus("")
    }

    func selectHistoryTab() {
        tabView.selectTabViewItem(withIdentifier: Self.historyTabIdentifier)
        refreshHistoryDisplay()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        historyRecords.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < historyRecords.count else {
            return nil
        }

        let record = historyRecords[row]
        let identifier = tableColumn?.identifier.rawValue ?? "cell"
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(identifier), owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)

        if tableColumn?.identifier.rawValue == "copy" {
            cell.subviews.forEach { $0.removeFromSuperview() }
            cell.textField = nil

            let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyHistoryRow(_:)))
            copyButton.bezelStyle = .rounded
            copyButton.controlSize = .small
            copyButton.font = .systemFont(ofSize: 11)
            copyButton.tag = row
            copyButton.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(copyButton)
            NSLayoutConstraint.activate([
                copyButton.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                copyButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                copyButton.widthAnchor.constraint(equalToConstant: 54),
                copyButton.heightAnchor.constraint(equalToConstant: 22)
            ])
            return cell
        }

        let textField: NSTextField
        if let existingTextField = cell.textField {
            textField = existingTextField
        } else {
            cell.subviews.forEach { $0.removeFromSuperview() }
            textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1

        switch tableColumn?.identifier.rawValue {
        case "date":
            textField.stringValue = Self.dateFormatter.string(from: record.createdAt)
        case "app":
            textField.stringValue = record.targetApplication?.displayName ?? "-"
        default:
            textField.stringValue = record.finalText
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateHistoryDetail()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard tabViewItem?.identifier as? String == Self.historyTabIdentifier else {
            return
        }

        refreshHistoryTableAfterLayout()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else {
            return
        }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 10
        rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        tabView.addTabViewItem(tab(identifier: Self.settingsTabIdentifier, label: "Settings", view: buildSettingsTab()))
        tabView.addTabViewItem(tab(identifier: Self.historyTabIdentifier, label: "History", view: buildHistoryTab()))
        tabView.addTabViewItem(tab(identifier: Self.dictionaryTabIdentifier, label: "Dictionary", view: buildDictionaryTab()))
        tabView.selectTabViewItem(withIdentifier: Self.historyTabIdentifier)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        rootStack.addArrangedSubview(tabView)
        rootStack.addArrangedSubview(statusLabel)
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    private func buildSettingsTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 700))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionTitle("API"))
        stack.addArrangedSubview(row("OpenAI key", apiKeyField))
        stack.addArrangedSubview(row("Transcription model", transcriptionModelField))
        stack.addArrangedSubview(row("Language", languageField))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("Dictation"))
        stack.addArrangedSubview(row("Hold hotkey", holdHotkeyField))
        stack.addArrangedSubview(row("Fallback hold hotkey", fallbackHoldHotkeyField))
        stack.addArrangedSubview(row("Toggle hotkey", toggleHotkeyField))
        stack.addArrangedSubview(restoreClipboardCheckbox)
        stack.addArrangedSubview(row("Paste restore delay", pasteDelayField, suffix: "ms"))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("Polish and history"))
        stack.addArrangedSubview(polishCheckbox)
        stack.addArrangedSubview(row("Polish model", polishModelField))
        stack.addArrangedSubview(row("History retention", historyRetentionField, suffix: "days"))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("Permissions and files"))
        stack.addArrangedSubview(row("Accessibility", accessibilityStatusLabel))
        stack.addArrangedSubview(row("Input Monitoring", inputMonitoringStatusLabel))
        stack.addArrangedSubview(pathRow("Config", envPathLabel))
        stack.addArrangedSubview(pathRow("Dictionary", dictionaryPathLabel))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        buttons.addArrangedSubview(button("Save Settings", action: #selector(saveSettings)))
        buttons.addArrangedSubview(button("Request Accessibility", action: #selector(requestAccessibility)))
        buttons.addArrangedSubview(button("Request Input Monitoring", action: #selector(requestInputMonitoring)))
        buttons.addArrangedSubview(button("Open Local Data Folder", action: #selector(openSupportFolder)))
        buttons.addArrangedSubview(NSView())
        stack.addArrangedSubview(buttons)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])

        return wrapInScrollView(view)
    }

    private func buildHistoryTab() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(historyCountLabel)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(button("Refresh", action: #selector(refreshWindowData)))
        toolbar.addArrangedSubview(button("Copy Text", action: #selector(copySelectedHistoryText)))
        toolbar.addArrangedSubview(button("Clear History", action: #selector(clearHistory)))

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        historySplitView = splitView

        configureHistoryTable()
        let tableScrollView = NSScrollView()
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = false
        tableScrollView.documentView = historyTableView

        historyDetailView.isEditable = false
        historyDetailView.isSelectable = true
        historyDetailView.font = .systemFont(ofSize: 14)
        historyDetailView.textContainerInset = NSSize(width: 12, height: 12)
        let detailScrollView = NSScrollView()
        detailScrollView.hasVerticalScroller = true
        detailScrollView.documentView = historyDetailView

        splitView.addArrangedSubview(tableScrollView)
        splitView.addArrangedSubview(detailScrollView)

        container.addSubview(toolbar)
        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            toolbar.heightAnchor.constraint(equalToConstant: 32),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            tableScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            detailScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])

        return container
    }

    private func buildDictionaryTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let editors = NSSplitView()
        editors.isVertical = true
        editors.dividerStyle = .thin
        editors.translatesAutoresizingMaskIntoConstraints = false

        editors.addArrangedSubview(editorPanel(title: "Terms", textView: termsTextView))
        editors.addArrangedSubview(editorPanel(title: "Replacements", textView: replacementsTextView))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(button("Save Dictionary", action: #selector(saveDictionary)))
        buttons.addArrangedSubview(button("Reload", action: #selector(refreshWindowData)))
        buttons.addArrangedSubview(NSView())

        stack.addArrangedSubview(editors)
        stack.addArrangedSubview(buttons)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            editors.heightAnchor.constraint(greaterThanOrEqualToConstant: 410)
        ])

        return container
    }

    private func configureHistoryTable() {
        historyTableView.headerView = nil
        historyTableView.usesAlternatingRowBackgroundColors = true
        historyTableView.rowHeight = 32
        historyTableView.dataSource = self
        historyTableView.delegate = self
        historyTableView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        historyTableView.autoresizingMask = [.width]

        if historyTableView.tableColumns.isEmpty {
            let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
            dateColumn.title = "Date"
            dateColumn.width = 132
            historyTableView.addTableColumn(dateColumn)

            let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
            appColumn.title = "App"
            appColumn.width = 120
            historyTableView.addTableColumn(appColumn)

            let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
            textColumn.title = "Text"
            textColumn.width = 300
            historyTableView.addTableColumn(textColumn)

            let copyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("copy"))
            copyColumn.title = ""
            copyColumn.width = 70
            historyTableView.addTableColumn(copyColumn)
        }
    }

    @objc private func saveSettings() {
        guard let retentionDays = Int(historyRetentionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pasteDelay = Int(pasteDelayField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            setStatus("History retention and paste delay must be numbers.")
            return
        }

        let updated = AppConfiguration(
            openAIAPIKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            transcriptionModel: transcriptionModelField.stringValue.nonEmptyOr("gpt-4o-transcribe"),
            transcriptionLanguage: languageField.stringValue.nonEmptyOr("fr"),
            enablePolish: polishCheckbox.state == .on,
            polishModel: polishModelField.stringValue.nonEmptyOr("gpt-4o-mini"),
            holdHotkey: holdHotkeyField.stringValue.nonEmptyOr("fn"),
            fallbackHoldHotkey: fallbackHoldHotkeyField.stringValue.nonEmptyOr("option+space"),
            toggleHotkey: toggleHotkeyField.stringValue.nonEmptyOr("fn+space"),
            historyRetentionDays: max(1, retentionDays),
            restoreClipboardAfterPaste: restoreClipboardCheckbox.state == .on,
            pasteRestoreDelayMilliseconds: max(0, pasteDelay)
        )

        switch onSaveSettings?(updated) ?? .success(()) {
        case .success:
            configuration = updated
            setStatus("Settings saved.")
        case let .failure(error):
            setStatus(error.localizedDescription)
        }
    }

    @objc private func saveDictionary() {
        do {
            let parsedDictionary = try parsedDictionaryFromEditors()
            switch onSaveDictionary?(parsedDictionary) ?? .success(()) {
            case .success:
                dictionary = parsedDictionary
                setStatus("Dictionary saved.")
            case let .failure(error):
                setStatus(error.localizedDescription)
            }
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    @objc private func refreshWindowData() {
        onRefresh?()
        setStatus("Refreshed.")
    }

    @objc private func copySelectedHistoryText() {
        let row = historyTableView.selectedRow
        guard row >= 0, row < historyRecords.count else {
            setStatus("Select a history item first.")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyRecords[row].finalText, forType: .string)
        setStatus("Copied.")
    }

    @objc private func copyHistoryRow(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < historyRecords.count else {
            setStatus("History item not found.")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyRecords[row].finalText, forType: .string)
        historyTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        setStatus("Copied history item.")
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear history?"
        alert.informativeText = "This removes all locally stored text records."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        switch onClearHistory?() ?? .success(()) {
        case .success:
            historyRecords = []
            historyTableView.reloadData()
            historyDetailView.string = ""
            historyCountLabel.stringValue = "0 records"
            setStatus("History cleared.")
        case let .failure(error):
            setStatus(error.localizedDescription)
        }
    }

    @objc private func requestAccessibility() {
        onRequestAccessibility?()
        accessibilityStatusLabel.stringValue = PermissionManager.isAccessibilityTrusted(prompt: false) ? "Granted" : "Missing"
    }

    @objc private func requestInputMonitoring() {
        onRequestInputMonitoring?()
        inputMonitoringStatusLabel.stringValue = PermissionManager.isInputMonitoringTrusted() ? "Granted" : "Missing"
    }

    @objc private func openSupportFolder() {
        onOpenSupportFolder?()
    }

    private func parsedDictionaryFromEditors() throws -> PersonalDictionary {
        let terms = termsTextView.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var replacements: [String: String] = [:]
        for rawLine in replacementsTextView.string.components(separatedBy: .newlines) {
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

    private func refreshHistoryDisplay() {
        historyCountLabel.stringValue = "\(historyRecords.count) records"
        historyTableView.reloadData()

        if historyRecords.isEmpty {
            historyTableView.deselectAll(nil)
            historyDetailView.string = ""
        } else {
            let selectedRow = historyTableView.selectedRow
            let rowToSelect = (0..<historyRecords.count).contains(selectedRow) ? selectedRow : 0
            historyTableView.selectRowIndexes(IndexSet(integer: rowToSelect), byExtendingSelection: false)
            updateHistoryDetail()
        }

        refreshHistoryTableAfterLayout()
    }

    private func refreshHistoryTableAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.window?.contentView?.layoutSubtreeIfNeeded()
            self.restoreHistorySplitPositionIfNeeded()
            self.historyTableView.noteNumberOfRowsChanged()
            self.historyTableView.reloadData()
            self.historyTableView.needsDisplay = true
            self.historyTableView.enclosingScrollView?.contentView.needsDisplay = true
        }
    }

    private func restoreHistorySplitPositionIfNeeded() {
        guard let splitView = historySplitView, splitView.arrangedSubviews.count == 2 else {
            return
        }

        let width = splitView.bounds.width
        guard width > 700 else {
            return
        }

        let currentTableWidth = splitView.arrangedSubviews[0].frame.width
        guard currentTableWidth < 160 else {
            return
        }

        let targetTableWidth = min(max(width * 0.48, 360), width - 300)
        splitView.setPosition(targetTableWidth, ofDividerAt: 0)
    }

    private func updateHistoryDetail() {
        let row = historyTableView.selectedRow
        guard row >= 0, row < historyRecords.count else {
            historyDetailView.string = ""
            return
        }

        let record = historyRecords[row]
        let appName = record.targetApplication?.displayName ?? "-"
        let duration = record.durationSeconds.map { String(format: "%.1fs", $0) } ?? "-"
        historyDetailView.string = """
        Date: \(Self.fullDateFormatter.string(from: record.createdAt))
        App: \(appName)
        Duration: \(duration)
        Polished: \(record.polished ? "yes" : "no")

        Final text:
        \(record.finalText)

        Raw transcription:
        \(record.transcribedText)
        """
    }

    private func setStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    private func tab(identifier: String, label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: identifier)
        item.label = label
        item.view = view
        return item
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func row(_ labelText: String, _ control: NSView, suffix: String? = nil) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let label = NSTextField(labelWithString: labelText)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true

        if let textField = control as? NSTextField {
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        if let suffix {
            let suffixLabel = NSTextField(labelWithString: suffix)
            suffixLabel.textColor = .secondaryLabelColor
            row.addArrangedSubview(suffixLabel)
        }

        row.addArrangedSubview(NSView())
        return row
    }

    private func pathRow(_ labelText: String, _ label: NSTextField) -> NSStackView {
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        return row(labelText, label)
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func editorPanel(title: String, textView: NSTextView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)

        let label = sectionTitle(title)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        return stack
    }

    private func wrapInScrollView(_ view: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = view
        return scrollView
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let settingsTabIdentifier = "settings"
    private static let historyTabIdentifier = "history"
    private static let dictionaryTabIdentifier = "dictionary"

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
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

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
