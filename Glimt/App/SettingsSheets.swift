import AppKit
import InspectorCore

// MARK: - File mappings (D16, D68)

/// The File Mappings part of the Formats & Views detail column: the custom names and extensions
/// that preview as the selected format. Storage stays the single global `fileAssociations` list;
/// this view filters it by target and never touches View Order or format overrides. Mappings are
/// literal filenames or single extensions read by Glimt only; they never register a macOS file
/// association.
@MainActor
final class FileMappingsSection: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// What the detail column shows; the section follows it.
    enum Context: Equatable {
        case none
        case category
        case format(FormatID, hiddenBySearch: Bool)
    }

    static let emptyMessage = "No custom file mappings"
    static let categoryMessage = "File mappings are configured for individual formats."
    static let hiddenMessage = "This format is hidden by the search. Clear the search to add mappings."
    static let kindTitles = ["Extension", "Exact Filename"]
    private static let kinds: [FileAssociation.Kind] = [.fileExtension, .filename]
    static let visibleRows: CGFloat = 4

    private let session: SettingsSession
    private(set) var context: Context = .none
    /// Called when the inline editor opens or closes, so the sheet can hand Return to Add.
    var onEditingChanged: (Bool) -> Void = { _ in }

    let heading = NSTextField(labelWithString: "File Mappings")
    let contextMessage = NSTextField(wrappingLabelWithString: "")
    let table = NSTableView()
    let addButton = NSButton()
    let removeButton = NSButton()
    let editor = NSStackView()
    let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let valueField = NSTextField()
    let hint = SettingsForm.secondary("")
    let feedback = NSTextField(wrappingLabelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let confirmButton = NSButton(title: "Add", target: nil, action: nil)
    private let emptyLabel = SettingsForm.listEmptyState(emptyMessage, identifier: "MappingListEmpty")
    private var list = NSView()
    private var listButtons = NSView()

    /// Creates the file mapping sheet and observes changes from the shared settings session.
    init(session: SettingsSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        session.observe { [weak self] change in if change == .settings { self?.reload() } }
    }
    /// Rejects storyboard creation because the section is assembled from session-owned controls.
    required init?(coder: NSCoder) { nil }

    /// The mappings shown: only those whose target is the selected format.
    var rows: [FileAssociation] {
        guard case .format(let format, _) = context else { return [] }
        return session.mappings(for: format)
    }

    var isEditing: Bool { !editor.isHidden }

    // MARK: Layout

    /// Builds the mapping table and editor programmatically, then loads the current session rows.
    override func loadView() {
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        heading.identifier = .init("FileMappingsHeading")
        heading.setAccessibilityRole(.staticText)
        contextMessage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contextMessage.textColor = .secondaryLabelColor
        contextMessage.isSelectable = false
        contextMessage.identifier = .init("MappingContextMessage")

        for (identifier, title, width) in [("kind", "Type", 108.0), ("value", "Name or Extension", 150.0)] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        table.identifier = .init("MappingList")
        table.setAccessibilityLabel("File mappings")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        // Header plus about four rows; more rows scroll inside the list.
        let headerHeight = table.headerView?.frame.height ?? 23
        scroll.heightAnchor.constraint(equalToConstant: headerHeight + Self.visibleRows * (table.rowHeight + table.intercellSpacing.height) + 3).isActive = true
        list = SettingsForm.overlay(emptyLabel, on: scroll, width: 260)

        Self.configure(addButton, image: NSImage.addTemplateName, label: "Add file mapping", identifier: "AddMapping", action: #selector(beginAdd(_:)), target: self)
        Self.configure(removeButton, image: NSImage.removeTemplateName, label: "Remove file mapping", identifier: "RemoveMapping", action: #selector(remove(_:)), target: self)
        listButtons = SettingsForm.horizontal([addButton, removeButton], spacing: 0)

        kindPopup.addItems(withTitles: Self.kindTitles)
        kindPopup.setAccessibilityLabel("Mapping type")
        kindPopup.identifier = .init("MappingKind")
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        valueField.placeholderString = "customjson"
        valueField.setAccessibilityLabel("Name or extension")
        valueField.identifier = .init("MappingValue")
        valueField.lineBreakMode = .byTruncatingTail
        hint.identifier = .init("MappingHint")
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        feedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        feedback.textColor = .systemRed
        feedback.isSelectable = false
        feedback.identifier = .init("MappingFeedback")
        cancelButton.target = self
        cancelButton.action = #selector(cancelDraft(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.identifier = .init("CancelMapping")
        cancelButton.setAccessibilityLabel("Cancel new file mapping")
        confirmButton.target = self
        confirmButton.action = #selector(add(_:))
        confirmButton.keyEquivalent = "\r"
        confirmButton.identifier = .init("ConfirmMapping")
        confirmButton.setAccessibilityLabel("Add file mapping")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let editorButtons = SettingsForm.horizontal([spacer, cancelButton, confirmButton], spacing: 8)
        let entry = SettingsForm.horizontal([kindPopup, valueField], spacing: 6)
        entry.alignment = .centerY
        for view in [entry, hint, feedback, editorButtons] as [NSView] { editor.addArrangedSubview(view) }
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 6
        editor.identifier = .init("MappingEditor")
        editor.isHidden = true
        feedback.isHidden = true
        for view in [entry, hint, feedback, editorButtons] as [NSView] {
            view.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        }

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [separator, heading, contextMessage, list, listButtons, editor])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: separator)
        stack.setCustomSpacing(0, after: list)
        stack.identifier = .init("FileMappingsSection")
        for view in [separator, contextMessage, list, editor] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = stack
        reload()
    }

    /// Applies consistent native sizing, accessibility, identity, and action wiring to a control.
    private static func configure(_ button: NSButton, image: NSImage.Name, label: String, identifier: String, action: Selector, target: AnyObject) {
        button.bezelStyle = .smallSquare
        button.image = NSImage(named: image)
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.identifier = .init(identifier)
        button.target = target
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    // MARK: Context

    /// Follows the detail column. A different format cancels an open draft without writing.
    func show(_ context: Context) {
        loadViewIfNeeded()
        let previous = self.context
        self.context = context
        if Self.format(of: previous) != Self.format(of: context) {
            closeEditor()
            table.deselectAll(nil)
        }
        reload()
    }

    /// Extracts the selected format from a visible format context.
    private static func format(of context: Context) -> FormatID? {
        if case .format(let format, _) = context { return format }
        return nil
    }

    /// Reloads the filtered rows and gates every control on context and the session's read-only state.
    func reload() {
        guard isViewLoaded else { return }
        let selected = selectedMapping
        table.reloadData()
        if let selected, let row = rows.firstIndex(of: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let format = Self.format(of: context)
        view.isHidden = context == .none
        list.isHidden = format == nil
        listButtons.isHidden = format == nil
        emptyLabel.isHidden = !rows.isEmpty
        switch context {
        case .none, .format(_, hiddenBySearch: false):
            contextMessage.isHidden = true
        case .category:
            contextMessage.stringValue = Self.categoryMessage
            contextMessage.isHidden = false
        case .format(_, hiddenBySearch: true):
            contextMessage.stringValue = Self.hiddenMessage
            contextMessage.isHidden = false
        }
        if let format {
            let name = format.displayName
            table.setAccessibilityLabel("File mappings for \(name)")
            hint.stringValue = "Add a name or extension recognized as \(name)."
        }
        if case .format(_, hiddenBySearch: true) = context { closeEditor() }
        addButton.isEnabled = canAdd && !isEditing
        [kindPopup, valueField, confirmButton].forEach { $0.isEnabled = canAdd }
        updateRemoveButton()
    }

    /// Adding needs a visible format and a writable session.
    var canAdd: Bool {
        guard session.canEdit, case .format(_, hiddenBySearch: false) = context else { return false }
        return true
    }

    var selectedMapping: FileAssociation? {
        let rows = rows
        return rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    /// Enables removal only when the section is editable and a mapping row is selected.
    private func updateRemoveButton() {
        removeButton.isEnabled = session.canEdit && selectedMapping != nil
    }

    // MARK: Table

    /// Reports the mappings currently filtered to the selected format.
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// Returns the user-facing kind label for a filename or extension mapping.
    static func kindTitle(_ kind: FileAssociation.Kind) -> String { kind == .filename ? "Exact Filename" : "Extension" }

    /// Extensions read ".customjson"; exact filenames read as typed.
    static func displayValue(_ mapping: FileAssociation) -> String {
        mapping.kind == .filename ? mapping.value : "." + mapping.value
    }

    /// "Extension, .customjson, mapped to JSON."
    static func accessibilityDescription(_ mapping: FileAssociation) -> String {
        "\(kindTitle(mapping.kind)), \(displayValue(mapping)), mapped to \(mapping.target.displayName)."
    }

    /// Builds a text-only cell for one mapping row, returning nil for stale row indices.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = rows
        guard rows.indices.contains(row) else { return nil }
        let mapping = rows[row]
        let text = tableColumn?.identifier.rawValue == "kind" ? Self.kindTitle(mapping.kind) : Self.displayValue(mapping)
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// Adds an accessible row label describing the mapping's kind, pattern, and target.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        let rows = rows
        if rows.indices.contains(row) { rowView.setAccessibilityLabel(Self.accessibilityDescription(rows[row])) }
        return rowView
    }

    /// Refreshes the remove action whenever the selection changes.
    func tableViewSelectionDidChange(_ notification: Notification) { updateRemoveButton() }

    // MARK: Editing

    /// Opens the inline editor; the target is the selected format.
    @objc func beginAdd(_ sender: Any?) {
        guard canAdd else { return }
        valueField.stringValue = ""
        kindPopup.selectItem(at: 0)
        showFeedback(nil)
        editor.isHidden = false
        addButton.isEnabled = false
        onEditingChanged(true)
        view.window?.makeFirstResponder(valueField)
        revealEditor()
    }

    /// The detail column scrolls when the sheet is short; keep the editor and its feedback in view.
    private func revealEditor() {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        editor.scrollToVisible(editor.bounds)
    }

    /// Updates the value hint when the user switches between filename and extension mapping.
    @objc private func kindChanged(_ sender: Any?) {
        valueField.placeholderString = Self.kinds[max(0, kindPopup.indexOfSelectedItem)] == .filename ? "Brewfile" : "customjson"
        showFeedback(nil)
    }

    /// Validates, checks conflicts and saves through the session; on success selects the new row.
    @objc func add(_ sender: Any?) {
        guard canAdd, case .format(let format, _) = context else { return }
        let kind = Self.kinds[max(0, kindPopup.indexOfSelectedItem)]
        if let message = session.addMapping(kind: kind, value: valueField.stringValue, target: format) {
            showFeedback(message)
            return
        }
        guard let added = FileAssociation(kind: kind, value: valueField.stringValue, target: format).validated() else { return }
        closeEditor()
        reload()
        if let row = rows.firstIndex(of: added) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateRemoveButton()
        view.window?.makeFirstResponder(table)
    }

    /// Closes the editor without writing.
    @objc func cancelDraft(_ sender: Any?) {
        closeEditor()
        reload()
    }

    /// Clears and hides the draft editor without persisting its contents.
    private func closeEditor() {
        guard isViewLoaded, isEditing else { return }
        editor.isHidden = true
        valueField.stringValue = ""
        showFeedback(nil)
        onEditingChanged(false)
    }

    /// Displays validation feedback, keeps it visible, and announces it to assistive technology.
    private func showFeedback(_ message: String?) {
        feedback.stringValue = message ?? ""
        feedback.isHidden = message == nil
        if message != nil { revealEditor() }
        if let message { NSAccessibility.post(element: feedback, notification: .announcementRequested, userInfo: [.announcement: message]) }
    }

    /// Removes the selected mapping by its full key and selects the row that took its place.
    @objc func remove(_ sender: Any?) {
        guard let mapping = selectedMapping else { return }
        let row = table.selectedRow
        session.removeMapping(mapping)
        table.reloadData()
        let count = rows.count
        if count > 0 {
            table.selectRowIndexes([min(row, count - 1)], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        reload()
    }
}
