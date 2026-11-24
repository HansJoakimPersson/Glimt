import AppKit
import InspectorCore

// MARK: - Formats & Views (spec §5–§9, ADR-022)

/// The view matrix over view categories and formats beside the selected row's detail: its View
/// Order and, for a format, the File Mappings that preview as it (D68). Every edit goes through
/// the session and `ViewResolver`'s edit operations, so the Live Preview, the app and Quick Look
/// see the same result.
@MainActor
final class FormatsAndViewsSheet: NSViewController {
    typealias View = FormatDefinition.RepresentationID

    /// One outline row. A class, because NSOutlineView identifies items by object.
    final class Item: NSObject {
        let scope: ViewScope
        let children: [Item]
    /// Creates a matrix row for a category or format, with optional child format rows.
    init(scope: ViewScope, children: [Item] = []) {
            self.scope = scope
            self.children = children
        }
    }

    static let preferredSize = NSSize(width: 1060, height: 720)
    static let minimumSize = NSSize(width: 880, height: 600)
    static let noSelectionMessage = "Select a format to configure its views and file mappings."
    static let hiddenBySearchMessage = "Hidden by the current search"
    static let detailWidth: CGFloat = 280
    static let binaryMessage = "Binary and unknown files always open in Hex. This keeps every file inspectable."

    private let session: SettingsSession
    private let initialScope: ViewScope?
    private(set) var roots: [Item] = []
    /// Lets the owning window controller release its single-sheet state when this sheet closes.
    var onDismiss: (() -> Void)?

    let searchField = NSSearchField()
    let customizedOnly = NSButton(checkboxWithTitle: "Show Customized Only", target: nil, action: nil)
    let outline = NSOutlineView()
    let detailTitle = NSTextField(labelWithString: "")
    let detailOrigin = SettingsForm.secondary("")
    let orderTable = NSTableView()
    let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset to Category", target: nil, action: nil)
    let optionsButton = NSButton(title: "Format Options…", target: nil, action: nil)
    let emptyResults = SettingsForm.listEmptyState("No matching formats", identifier: "FormatsEmptyResults")
    private let orderHelp = NSTextField(wrappingLabelWithString: "")
    private var orderControls: [NSView] = []
    let mappings: FileMappingsSection
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    /// The format kept in the detail column while the search hides its row.
    private(set) var hiddenScope: ViewScope?
    private var rebuilding = false
    /// A selection made before the matrix has a size; scrolling then would use a zero-height clip.
    private var scrollsSelectionAfterLayout = false
    /// Replaced in tests so the options sheet can be inspected without a window.
    var presentOptions: (NSViewController) -> Void = { _ in }

    /// Creates the Formats and Views sheet and optionally selects a specific row.
    init(session: SettingsSession, selecting scope: ViewScope? = nil) {
        self.session = session
        initialScope = scope
        mappings = FileMappingsSection(session: session)
        super.init(nibName: nil, bundle: nil)
        presentOptions = { [weak self] sheet in self?.presentAsSheet(sheet) }
        session.observe { [weak self] _ in self?.reload() }
    }
    /// Rejects storyboard construction because the sheet is assembled from catalog and session data.
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    /// Builds the catalog, detail panes, and controls from the settings session.
    override func loadView() {
        let title = SettingsForm.heading("Formats & Views",
                                         subtitle: "Choose the views each format offers and their order. The first active view is the Default View.")
        let content = makeContent()

        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.keyEquivalent = "\r"
        doneButton.identifier = .init("FormatsAndViewsDone")
        // While a mapping is being added, Return adds it instead of closing the sheet.
        mappings.onEditingChanged = { [weak self] editing in self?.doneButton.keyEquivalent = editing ? "" : "\r" }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = SettingsForm.horizontal([spacer, doneButton], spacing: 8)

        let root = NSView(frame: .init(origin: .zero, size: Self.preferredSize))
        for child in [title, content, buttons] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSize.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumSize.height)
        ])
        root.identifier = .init("FormatsAndViews")
        view = root
        preferredContentSize = Self.preferredSize
        rebuild()
        if let initialScope { select(initialScope) } else if !roots.isEmpty { outline.selectRowIndexes([0], byExtendingSelection: false) }
        updateDetail()
    }

    /// The sheet is resizable (spec §5); AppKit sheets are not by default.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }
        window.styleMask.insert(.resizable)
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.preferredSize)
    }

    /// Two permanent columns: the matrix and the selected row's detail.
    private func makeContent() -> NSView {
        searchField.placeholderString = "Search formats or extensions"
        searchField.setAccessibilityLabel("Search formats")
        searchField.identifier = .init("FormatsSearch")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        customizedOnly.target = self
        customizedOnly.action = #selector(filterChanged(_:))
        customizedOnly.identifier = .init("CustomizedOnly")
        let filters = SettingsForm.horizontal([searchField, customizedOnly], spacing: 12)
        filters.alignment = .centerY

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Format"
        name.width = 190
        name.minWidth = 140
        outline.addTableColumn(name)
        outline.outlineTableColumn = name
        let origin = NSTableColumn(identifier: .init("origin"))
        origin.title = "Origin"
        origin.width = 84
        origin.minWidth = 70
        outline.addTableColumn(origin)
        for view in ViewResolver.matrixColumns {
            let column = NSTableColumn(identifier: .init(view.rawValue))
            column.title = Self.title(of: view)
            column.headerCell.alignment = .center
            column.width = 56
            column.minWidth = 50
            column.resizingMask = []
            outline.addTableColumn(column)
        }
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        outline.style = .fullWidth
        outline.rowHeight = 22
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Formats and views")
        outline.identifier = .init("FormatsMatrix")
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder
        let matrix = SettingsForm.overlay(emptyResults, on: outlineScroll, width: 400)

        let detail = makeDetail()
        let content = NSView()
        for child in [filters, matrix, detail] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            filters.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            matrix.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10),
            matrix.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            matrix.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: matrix.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: matrix.topAnchor),
            detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            detail.widthAnchor.constraint(equalToConstant: Self.detailWidth)
        ])
        return content
    }

    /// The selected row's detail: View Order, then File Mappings. It scrolls when the sheet is
    /// short or the mapping editor is open.
    private func makeDetail() -> NSView {
        detailTitle.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        detailTitle.identifier = .init("DetailTitle")
        detailTitle.lineBreakMode = .byTruncatingTail
        detailOrigin.identifier = .init("DetailOrigin")
        let orderLabel = NSTextField(labelWithString: "View Order")
        orderLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        let column = NSTableColumn(identifier: .init("view"))
        column.title = "View Order"
        orderTable.addTableColumn(column)
        orderTable.headerView = nil
        orderTable.rowHeight = 22
        orderTable.dataSource = self
        orderTable.delegate = self
        orderTable.registerForDraggedTypes([.string])
        orderTable.setDraggingSourceOperationMask(.move, forLocal: true)
        orderTable.setAccessibilityLabel("View Order")
        orderTable.identifier = .init("ViewOrder")
        let orderScroll = NSScrollView()
        orderScroll.documentView = orderTable
        orderScroll.hasVerticalScroller = true
        orderScroll.autohidesScrollers = true
        orderScroll.borderType = .bezelBorder
        orderScroll.heightAnchor.constraint(equalToConstant: 5 * 22 + 4).isActive = true

        moveUpButton.target = self
        moveUpButton.action = #selector(moveViewUp(_:))
        moveUpButton.identifier = .init("MoveViewUp")
        moveUpButton.keyEquivalent = String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1)
        moveUpButton.keyEquivalentModifierMask = [.command, .option]
        moveUpButton.toolTip = "Move the selected view up (⌥⌘↑)"
        moveDownButton.target = self
        moveDownButton.action = #selector(moveViewDown(_:))
        moveDownButton.identifier = .init("MoveViewDown")
        moveDownButton.keyEquivalent = String(utf16CodeUnits: [unichar(NSDownArrowFunctionKey)], count: 1)
        moveDownButton.keyEquivalentModifierMask = [.command, .option]
        moveDownButton.toolTip = "Move the selected view down (⌥⌘↓)"
        let moves = SettingsForm.horizontal([moveUpButton, moveDownButton], spacing: 8)

        orderHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        orderHelp.textColor = .secondaryLabelColor
        orderHelp.isSelectable = false
        orderHelp.preferredMaxLayoutWidth = Self.detailWidth
        orderHelp.identifier = .init("ViewOrderHelp")

        resetButton.target = self
        resetButton.action = #selector(reset(_:))
        resetButton.identifier = .init("ResetViews")
        optionsButton.target = self
        optionsButton.action = #selector(showOptions(_:))
        optionsButton.identifier = .init("FormatOptionsButton")

        orderControls = [orderLabel, orderScroll, moves]
        addChild(mappings)
        // Reset and Format Options share a row so File Mappings fit at the opening size.
        let actions = SettingsForm.horizontal([resetButton, optionsButton], spacing: 8)
        let stack = NSStackView(views: [detailTitle, detailOrigin, orderLabel, orderScroll, moves, orderHelp, actions, mappings.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: detailOrigin)
        stack.setCustomSpacing(16, after: orderHelp)
        stack.setCustomSpacing(16, after: actions)
        for child in [detailTitle, orderScroll, orderHelp, mappings.view] as [NSView] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.identifier = .init("ViewOrderEditor")

        let document = FlippedView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.identifier = .init("FormatDetail")
        for child in [document, stack] as [NSView] { child.translatesAutoresizingMaskIntoConstraints = false }
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return scroll
    }

    /// Produces the user-facing title for a representation choice.
    static func title(of view: View) -> String { view.rawValue.capitalized }

    /// Names the category or format represented by one settings scope.
    static func name(of scope: ViewScope) -> String {
        switch scope {
        case .category(let category): category.displayName
        case .format(let format): FormatCatalog.definition(for: format)?.displayName ?? format.rawValue
        }
    }

    /// Row origin as shown in the matrix and the editor.
    func originLabel(of scope: ViewScope) -> String {
        guard ViewResolver.isEditable(scope) else { return "Fixed" }
        let customized = ViewResolver.isCustomized(scope, in: session.settings)
        switch scope {
        case .category: return customized ? "Customized" : "Default"
        case .format: return customized ? "Customized" : "Inherited"
        }
    }

    // MARK: Filtering

    /// Applies the current search text and reloads visible matrix rows.
    @objc func filterChanged(_ sender: Any?) {
        refilter()
        updateDetail()
    }

    /// Rebuilds the tree and restores the selection; a format the search hides stays in the
    /// detail column, marked as hidden, until the user selects another row.
    private func refilter() {
        let selected = selectedScope ?? hiddenScope
        // The selection passes through empty while the tree reloads; that is not a user change.
        rebuilding = true
        rebuild()
        if let selected { select(selected) }
        rebuilding = false
        if case .format = selected, selectedScope == nil { hiddenScope = selected } else { hiddenScope = nil }
    }

    /// Builds the visible tree from the catalog; planned formats never appear (spec §6).
    private func rebuild() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let customized = customizedOnly.state == .on
        let settings = session.settings
        roots = ViewCategoryID.allCases.compactMap { category in
            let categoryMatches = query.isEmpty || category.displayName.lowercased().contains(query)
            let children = category.formats.filter { definition in
                if customized, settings.formatOverrides[definition.id.rawValue] == nil { return false }
                return categoryMatches || Self.matches(definition, query)
            }.map { Item(scope: .format($0.id)) }
            let categoryCustomized = settings.categoryProfiles[category.rawValue] != nil
            let keep = customized ? (categoryCustomized && categoryMatches) || !children.isEmpty
                : categoryMatches || !children.isEmpty
            return keep ? Item(scope: .category(category), children: children) : nil
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        emptyResults.isHidden = !roots.isEmpty
    }

    /// Name, identifier, extension or exact filename.
    private static func matches(_ definition: FormatDefinition, _ query: String) -> Bool {
        definition.displayName.lowercased().contains(query) || definition.id.rawValue.contains(query)
            || definition.extensions.contains { $0.lowercased().contains(query.trimmingCharacters(in: ["*", "."])) }
            || definition.exactFilenames.contains { $0.lowercased().contains(query) }
    }

    /// Settings changed: refresh cells and the editor without losing selection or scroll position.
    func reload() {
        guard isViewLoaded else { return }
        let orderRow = orderTable.selectedRow
        refilter()
        updateDetail()
        if orderRow >= 0, orderRow < orderTable.numberOfRows {
            orderTable.selectRowIndexes([orderRow], byExtendingSelection: false)
        }
        updateMoveButtons()
    }

    // MARK: Selection

    var selectedScope: ViewScope? {
        (outline.item(atRow: outline.selectedRow) as? Item)?.scope
    }

    /// Finds the outline row that represents a category or format scope.
    func item(for scope: ViewScope) -> Item? {
        roots.lazy.compactMap { root in root.scope == scope ? root : root.children.first { $0.scope == scope } }.first
    }

    /// Selects a scope and scrolls it into view when the outline has completed layout.
    func select(_ scope: ViewScope) {
        guard let item = item(for: scope) else { return }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        guard (outline.enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else {
            scrollsSelectionAfterLayout = true
            return
        }
        outline.scrollRowToVisible(row)
    }

    /// Completes deferred scrolling after the outline's scroll viewport receives its size.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard scrollsSelectionAfterLayout, (outline.enclosingScrollView?.contentView.bounds.height ?? 0) > 0 else { return }
        scrollsSelectionAfterLayout = false
        if outline.selectedRow >= 0 { outline.scrollRowToVisible(outline.selectedRow) }
    }

    /// The configured views of the selected row; the first is the Default View.
    var orderedViews: [View] {
        guard let scope = selectedScope else { return [] }
        return ViewResolver.configured(in: scope, settings: session.settings)
    }

    /// Rebuilds selected-format details and synchronizes matrix and view-order controls.
    private func updateDetail() {
        if case .format(let format) = hiddenScope {
            detailTitle.stringValue = Self.name(of: .format(format))
            detailOrigin.stringValue = Self.hiddenBySearchMessage
            orderControls.forEach { $0.isHidden = true }
            orderHelp.isHidden = true
            resetButton.isHidden = true
            optionsButton.isHidden = true
            mappings.show(.format(format, hiddenBySearch: true))
            return
        }
        guard let scope = selectedScope else {
            detailTitle.stringValue = ""
            detailOrigin.stringValue = Self.noSelectionMessage
            orderControls.forEach { $0.isHidden = true }
            orderHelp.isHidden = true
            resetButton.isHidden = true
            optionsButton.isHidden = true
            mappings.show(.none)
            return
        }
        let editable = ViewResolver.isEditable(scope)
        let customized = ViewResolver.isCustomized(scope, in: session.settings)
        detailTitle.stringValue = Self.name(of: scope)
        switch scope {
        case .category(let category):
            detailOrigin.stringValue = !editable ? "Fixed" : customized ? "Customized category profile"
                : "Default profile for \(category.formats.count) formats"
            resetButton.title = "Restore Category Defaults"
            optionsButton.isHidden = true
            mappings.show(.category)
        case .format(let format):
            let category = ViewCategoryID.category(for: format)
            detailOrigin.stringValue = customized ? "Customized" : "Inherited from \(category.displayName)"
            resetButton.title = "Reset to Category"
            optionsButton.isHidden = !FormatOptionsSheet.isAvailable(for: format)
            optionsButton.isEnabled = true
            mappings.show(.format(format, hiddenBySearch: false))
        }
        orderControls.forEach { $0.isHidden = !editable }
        orderHelp.isHidden = false
        orderHelp.stringValue = editable
            ? "Tabs follow this order. The first view is the Default View. Drag or use Move Up and Move Down; turn views on or off in the matrix."
            : Self.binaryMessage
        resetButton.isHidden = !editable
        resetButton.isEnabled = customized && session.canEdit
        orderTable.reloadData()
        if orderTable.selectedRow < 0, orderTable.numberOfRows > 0 {
            orderTable.selectRowIndexes([0], byExtendingSelection: false)
        }
        updateMoveButtons()
    }

    /// Enables move controls only when a selected row can move within the current order.
    private func updateMoveButtons() {
        let row = orderTable.selectedRow
        let count = orderedViews.count
        let editable = session.canEdit && selectedScope.map(ViewResolver.isEditable) == true
        moveUpButton.isEnabled = editable && row > 0
        moveDownButton.isEnabled = editable && row >= 0 && row < count - 1
    }

    // MARK: Edits

    /// Checkbox: activation only (spec §8). Disabling the last active view is refused by the model.
    func setView(_ view: View, enabled: Bool, for scope: ViewScope) {
        session.update { $0.setView(view, enabled: enabled, for: scope) }
        // A refused edit sends no change notification; resync the checkbox with the model.
        reload()
    }

    /// Moves a view in the selected row's order and keeps it selected.
    func moveView(from source: Int, to destination: Int) {
        guard let scope = selectedScope, source != destination else { return }
        session.update { $0.moveView(from: source, to: destination, for: scope) }
        let count = orderedViews.count
        guard count > 0 else { return }
        orderTable.selectRowIndexes([min(max(destination, 0), count - 1)], byExtendingSelection: false)
        updateMoveButtons()
    }

    /// Moves the selected active view earlier in its configured display order.
    @objc func moveViewUp(_ sender: Any?) {
        let row = orderTable.selectedRow
        guard row > 0 else { return }
        moveView(from: row, to: row - 1)
    }

    /// Moves the selected active view later in its configured display order.
    @objc func moveViewDown(_ sender: Any?) {
        let row = orderTable.selectedRow
        guard row >= 0, row < orderedViews.count - 1 else { return }
        moveView(from: row, to: row + 1)
    }

    /// Reset to Category (format) or Restore Category Defaults (category).
    @objc func reset(_ sender: Any?) {
        guard let scope = selectedScope else { return }
        session.update { $0.resetViews(for: scope) }
    }

    /// Opens the format-specific options sheet for the selected format row.
    @objc func showOptions(_ sender: Any?) {
        guard case .format(let format) = selectedScope, FormatOptionsSheet.isAvailable(for: format) else { return }
        presentOptions(FormatOptionsSheet(session: session, format: format))
    }

    /// Escape cancels a mapping draft first, then closes the sheet.
    override func cancelOperation(_ sender: Any?) {
        if mappings.isEditing { mappings.cancelDraft(sender) } else { dismissSheet() }
    }
    /// Dismisses the sheet without changing settings beyond edits already saved by the session.
    @objc private func done(_ sender: Any?) { dismissSheet() }

    /// Clears the owner's active-sheet state before asking AppKit to dismiss this controller.
    private func dismissSheet() {
        let notifyOwner = onDismiss
        onDismiss = nil
        notifyOwner?()
        dismiss(self)
    }
}

// MARK: - Matrix

extension FormatsAndViewsSheet: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Reports the visible child count for a category or format outline item.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    /// Returns the indexed child used to populate the category and format outline.
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? roots[index]
    }

    /// Allows expansion only for catalog categories that contain formats.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    /// Creates the outline cell and its status text for a catalog item.
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item, let column = tableColumn?.identifier.rawValue else { return nil }
        let scope = item.scope
        switch column {
        case "name":
            let label = NSTextField(labelWithString: Self.name(of: scope))
            if case .category = scope { label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
            return Self.cell(label, centered: false)
        case "origin":
            let label = SettingsForm.secondary(originLabel(of: scope))
            return Self.cell(label, centered: false)
        default:
            guard let view = View(rawValue: column) else { return nil }
            return matrixCell(view, scope: scope)
        }
    }

    /// One matrix cell: a checkbox for a supported view, a dash for an unsupported one.
    private func matrixCell(_ view: View, scope: ViewScope) -> NSView {
        let settings = session.settings
        let name = Self.name(of: scope)
        let title = Self.title(of: view)
        let state = ViewResolver.state(of: view, in: settings, for: scope)
        guard state != .unsupported else {
            let dash = SettingsForm.secondary("–")
            dash.setAccessibilityLabel("\(title) not supported for \(name)")
            dash.toolTip = "\(name) has no \(title) view"
            return Self.cell(dash, centered: true)
        }
        let box = ClosureCheckbox(title: "")
        box.state = state == .enabled ? .on : .off
        let isDefault = ViewResolver.configured(in: scope, settings: settings).first == view
        box.setAccessibilityLabel("\(title) for \(name)" + (isDefault ? ", Default View" : ""))
        box.toolTip = isDefault ? "\(title) is the Default View" : nil
        box.identifier = .init("ViewCell-\(view.rawValue)")
        let canToggle = state == .disabled || ViewResolver.canDisable(view, in: settings, for: scope)
        box.isEnabled = session.canEdit && ViewResolver.isEditable(scope) && canToggle
        box.onChange = { [weak self] on in self?.setView(view, enabled: on, for: scope) }
        return Self.cell(box, centered: true)
    }

    /// Wraps matrix content in a table cell with centered or leading alignment.
    private static func cell(_ content: NSView, centered: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        if let field = content as? NSTextField {
            cell.textField = field
            field.lineBreakMode = .byTruncatingTail
        }
        var constraints = [content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if centered {
            constraints.append(content.centerXAnchor.constraint(equalTo: cell.centerXAnchor))
        } else {
            constraints += [content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2)]
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// Refreshes the selected category or format detail after outline selection changes.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding else { return }
        // A rebuild clears the selection; only a real selection replaces a format hidden by search.
        if selectedScope != nil { hiddenScope = nil }
        orderTable.deselectAll(nil)
        updateDetail()
    }
}

// MARK: - View Order

extension FormatsAndViewsSheet: NSTableViewDataSource, NSTableViewDelegate {
    /// Reports the number of configured representations shown in View Order.
    func numberOfRows(in tableView: NSTableView) -> Int { orderedViews.count }

    /// "1  Tree   Default"; VoiceOver reads position and default, and can move the row with
    /// custom actions (spec §8).
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let views = orderedViews
        guard views.indices.contains(row) else { return nil }
        let view = views[row]
        let title = Self.title(of: view)
        let number = SettingsForm.secondary("\(row + 1)")
        let label = NSTextField(labelWithString: title)
        var parts: [NSView] = [number, label]
        if row == 0 {
            let marker = SettingsForm.secondary("Default")
            marker.identifier = .init("DefaultViewMarker")
            parts.append(marker)
        }
        let stack = SettingsForm.horizontal(parts, spacing: 8)
        let cell = NSTableCellView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = label
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.cell)
        cell.setAccessibilityLabel("\(title), position \(row + 1) of \(views.count)" + (row == 0 ? ", Default View" : ""))
        var actions: [NSAccessibilityCustomAction] = []
        if session.canEdit {
            if row > 0 {
                actions.append(.init(name: "Move Up") { [weak self] in self?.moveView(from: row, to: row - 1); return true })
            }
            if row < views.count - 1 {
                actions.append(.init(name: "Move Down") { [weak self] in self?.moveView(from: row, to: row + 1); return true })
            }
        }
        cell.setAccessibilityCustomActions(actions)
        return cell
    }

    /// Recomputes move availability when View Order selection changes.
    func tableViewSelectionDidChange(_ notification: Notification) { updateMoveButtons() }

    /// Exports a selected representation index for an internal reorder drag.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard session.canEdit, selectedScope.map(ViewResolver.isEditable) == true else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    /// Accepts drops only from this table and normalizes drops onto rows to insert-above operations.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === orderTable else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    /// Moves the dragged row to its validated destination and persists the configured order.
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === orderTable,
              let source = info.draggingPasteboard.string(forType: .string).flatMap(Int.init) else { return false }
        moveView(from: source, to: Self.destination(dropRow: row, source: source))
        return true
    }

    /// A drop "above row n" lands at n, or n-1 when the dragged row was above it.
    static func destination(dropRow: Int, source: Int) -> Int { dropRow > source ? dropRow - 1 : dropRow }
}
