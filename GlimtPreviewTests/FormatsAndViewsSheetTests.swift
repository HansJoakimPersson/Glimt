import AppKit
import XCTest
import InspectorCore

/// FV-M3: the Formats & Views sheet — matrix, View Order editor, inheritance actions, filters,
/// File Mappings, Format Options and the single-instance rule (spec §5–§9, §13).
@MainActor
final class FormatsAndViewsSheetTests: XCTestCase {
    private typealias View = FormatDefinition.RepresentationID

    private func makeSheet(_ session: SettingsSession = SettingsSession(store: nil, snapshot: nil),
                           selecting scope: ViewScope? = nil,
                           size: NSSize = FormatsAndViewsSheet.preferredSize) -> FormatsAndViewsSheet {
        let sheet = FormatsAndViewsSheet(session: session, selecting: scope)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sheet
        window.setContentSize(size)
        sheet.view.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in window.contentViewController = nil; window.close() }
        return sheet
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func row(of scope: ViewScope, in sheet: FormatsAndViewsSheet) throws -> Int {
        let item = try XCTUnwrap(sheet.item(for: scope), "\(scope) is listed")
        let row = sheet.outline.row(forItem: item)
        XCTAssertGreaterThanOrEqual(row, 0)
        return row
    }

    private func cell(_ view: View, _ scope: ViewScope, in sheet: FormatsAndViewsSheet) throws -> NSView {
        let column = sheet.outline.column(withIdentifier: .init(view.rawValue))
        return try XCTUnwrap(sheet.outline.view(atColumn: column, row: row(of: scope, in: sheet), makeIfNecessary: true))
    }

    private func checkbox(_ view: View, _ scope: ViewScope, in sheet: FormatsAndViewsSheet) throws -> NSButton? {
        try descendants(cell(view, scope, in: sheet)).compactMap { $0 as? NSButton }.first
    }

    private func text(_ column: String, _ scope: ViewScope, in sheet: FormatsAndViewsSheet) throws -> String {
        let index = sheet.outline.column(withIdentifier: .init(column))
        let view = try XCTUnwrap(sheet.outline.view(atColumn: index, row: row(of: scope, in: sheet), makeIfNecessary: true) as? NSTableCellView)
        return view.textField?.stringValue ?? ""
    }

    private var orderTitles: (FormatsAndViewsSheet) -> [String] {
        { sheet in sheet.orderedViews.map(FormatsAndViewsSheet.title(of:)) }
    }

    // MARK: Matrix

    func testInitialSelectionKeepsTheMatrixAtItsTopWhenTheRowFits() throws {
        // Scrolling before layout used the zero-size clip and pushed earlier rows under the header.
        let sheet = makeSheet(selecting: .format(.json))
        let outline = sheet.outline
        let header = try XCTUnwrap(outline.headerView)
        let headerBottom = header.convert(header.bounds, to: nil).minY
        let firstRow = outline.convert(outline.rect(ofRow: 0), to: nil)
        XCTAssertLessThanOrEqual(firstRow.maxY, headerBottom + 0.5, "the first category row is not hidden under the header")
        let json = outline.convert(outline.rect(ofRow: try row(of: .format(.json), in: sheet)), to: nil)
        let clip = try XCTUnwrap(outline.enclosingScrollView?.contentView)
        let visible = clip.convert(clip.bounds, to: nil)
        XCTAssertTrue(json.minY >= visible.minY && json.maxY <= headerBottom, "the selected row stays visible below the header")
    }

    func testMatrixListsCategoriesSupportedFormatsAndViewColumns() throws {
        let sheet = makeSheet()
        XCTAssertEqual(sheet.outline.tableColumns.map(\.identifier.rawValue),
                       ["name", "origin", "tree", "pretty", "table", "rendered", "source", "diff", "raw", "hex"])
        XCTAssertEqual(sheet.roots.map(\.scope), ViewCategoryID.allCases.map { .category($0) })
        let listed = Set(sheet.roots.flatMap(\.children).map(\.scope))
        XCTAssertEqual(listed, Set(FormatCatalog.supported.map { ViewScope.format($0.id) }))
        let planned = FormatCatalog.all.filter { $0.status != .supported }
        XCTAssertFalse(planned.isEmpty, "The catalog has planned formats to hide")
        for definition in planned { XCTAssertNil(sheet.item(for: .format(definition.id)), "\(definition.id) is planned") }
        for column in sheet.outline.tableColumns.dropFirst(2) {
            XCTAssertEqual(column.title, FormatsAndViewsSheet.title(of: try XCTUnwrap(View(rawValue: column.identifier.rawValue))))
        }
        XCTAssertFalse(descendants(sheet.view).contains { ($0 as? NSTextField)?.stringValue.contains("Parser") == true })
    }

    func testCellsShowEnabledDisabledAndUnsupportedStates() throws {
        let sheet = makeSheet()
        XCTAssertEqual(try checkbox(.tree, .format(.json), in: sheet)?.state, .on)
        XCTAssertEqual(try checkbox(.hex, .format(.json), in: sheet)?.state, .off)
        XCTAssertNil(try checkbox(.table, .format(.json), in: sheet), "Unsupported cells have no checkbox")
        let dash = try XCTUnwrap(descendants(cell(.table, .format(.json), in: sheet)).compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(dash.accessibilityLabel(), "Table not supported for JSON")
        XCTAssertEqual(try checkbox(.tree, .format(.json), in: sheet)?.accessibilityLabel(), "Tree for JSON, Default View")
        XCTAssertEqual(try text("origin", .format(.json), in: sheet), "Inherited")
        XCTAssertEqual(try text("origin", .category(.structuredData), in: sheet), "Default")
        XCTAssertEqual(try text("origin", .category(.binaryAndUnknown), in: sheet), "Fixed")
        XCTAssertEqual(try checkbox(.hex, .category(.binaryAndUnknown), in: sheet)?.isEnabled, false)
    }

    func testMermaidUsesRenderedDocumentsRawColumnAndFilteredFactoryOrder() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.mermaid))
        XCTAssertEqual(try checkbox(.rendered, .format(.mermaid), in: sheet)?.state, .on)
        XCTAssertEqual(try checkbox(.raw, .format(.mermaid), in: sheet)?.state, .on)
        XCTAssertNil(try checkbox(.source, .format(.mermaid), in: sheet), "Mermaid does not claim Markdown Source")
        XCTAssertNil(try checkbox(.raw, .format(.markdown), in: sheet), "Markdown Raw remains outside its capability matrix")
        XCTAssertEqual(try checkbox(.raw, .category(.renderedDocuments), in: sheet)?.state, .on,
                       "Rendered Documents exposes Raw because Mermaid supports it")
        XCTAssertEqual(orderTitles(sheet), ["Rendered", "Raw"])

        sheet.moveViewDown(nil)
        XCTAssertEqual(orderTitles(sheet), ["Raw", "Rendered"])
        XCTAssertEqual(session.settings.formatOverrides[FormatID.mermaid.rawValue], ["raw", "rendered"])
    }

    func testMermaidAndRenderedDocumentsKeepTheLastInheritingViewActive() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session)
        sheet.setView(.rendered, enabled: false, for: .format(.mermaid))
        XCTAssertEqual(session.settings.formatOverrides[FormatID.mermaid.rawValue], ["raw"])
        sheet.setView(.raw, enabled: false, for: .format(.mermaid))
        XCTAssertEqual(session.settings.formatOverrides[FormatID.mermaid.rawValue], ["raw"],
                       "A format override cannot remove its last active view")
        session.update { $0.resetViews(for: .format(.mermaid)) }

        sheet.setView(.rendered, enabled: false, for: .category(.renderedDocuments))
        XCTAssertEqual(session.settings.categoryProfiles[ViewCategoryID.renderedDocuments.rawValue], ["source", "raw"])
        sheet.setView(.raw, enabled: false, for: .category(.renderedDocuments))
        XCTAssertEqual(session.settings.categoryProfiles[ViewCategoryID.renderedDocuments.rawValue], ["source", "raw"],
                       "A category edit cannot leave inheriting Mermaid without a view")
    }

    func testCheckboxMaterializesAnOverrideAndAppendsTheView() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session)
        try XCTUnwrap(checkbox(.hex, .format(.json), in: sheet)).performClick(nil)
        XCTAssertEqual(session.settings.formatOverrides["json"], ["tree", "pretty", "raw", "hex"])
        XCTAssertEqual(try text("origin", .format(.json), in: sheet), "Customized")
        XCTAssertEqual(try checkbox(.hex, .format(.json), in: sheet)?.state, .on)
        XCTAssertEqual(ViewResolver.resolve(session.settings, for: .yaml).origin, .inherited, "Siblings keep inheriting")
        try XCTUnwrap(checkbox(.tree, .format(.json), in: sheet)).performClick(nil)
        XCTAssertEqual(session.settings.formatOverrides["json"], ["pretty", "raw", "hex"], "Disabling removes from the order")
    }

    func testTheLastActiveViewCannotBeTurnedOff() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session)
        let raw = try XCTUnwrap(checkbox(.raw, .format(.text), in: sheet))
        XCTAssertEqual(raw.state, .on)
        XCTAssertFalse(raw.isEnabled, "Plain Text keeps Raw, its only view")
        sheet.setView(.raw, enabled: false, for: .format(.text))
        XCTAssertNil(session.settings.formatOverrides["text"])
        XCTAssertEqual(try checkbox(.raw, .format(.text), in: sheet)?.state, .on)
    }

    func testCategoryEditFlowsToInheritingFormatsOnly() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        session.update { $0.moveView(from: 2, to: 0, for: .format(.yaml)) }
        let sheet = makeSheet(session)
        try XCTUnwrap(checkbox(.pretty, .category(.structuredData), in: sheet)).performClick(nil)
        XCTAssertEqual(session.settings.categoryProfiles["structuredData"], ["table", "tree", "raw"])
        XCTAssertEqual(try checkbox(.pretty, .format(.json), in: sheet)?.state, .off, "JSON inherits the edit")
        XCTAssertEqual(try checkbox(.pretty, .format(.yaml), in: sheet)?.state, .on, "Customized YAML keeps its list")
        XCTAssertEqual(try text("origin", .category(.structuredData), in: sheet), "Customized")
    }

    // MARK: View Order

    func testOrderEditorMarksTheDefaultAndMovesViews() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        XCTAssertEqual(sheet.selectedScope, .format(.json))
        XCTAssertEqual(orderTitles(sheet), ["Tree", "Pretty", "Raw"])
        let first = try XCTUnwrap(sheet.orderTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertTrue(descendants(first).contains { $0.identifier?.rawValue == "DefaultViewMarker" })
        XCTAssertEqual(first.accessibilityLabel(), "Tree, position 1 of 3, Default View")
        let second = try XCTUnwrap(sheet.orderTable.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertFalse(descendants(second).contains { $0.identifier?.rawValue == "DefaultViewMarker" })

        XCTAssertEqual(sheet.orderTable.selectedRow, 0)
        XCTAssertFalse(sheet.moveUpButton.isEnabled)
        XCTAssertTrue(sheet.moveDownButton.isEnabled)
        sheet.moveViewDown(nil)
        XCTAssertEqual(orderTitles(sheet), ["Pretty", "Tree", "Raw"])
        XCTAssertEqual(session.settings.formatOverrides["json"], ["pretty", "tree", "raw"])
        XCTAssertEqual(sheet.orderTable.selectedRow, 1, "The moved view stays selected")
        XCTAssertEqual(ViewResolver.resolve(session.settings, for: .json).defaultView, .pretty)
        sheet.moveViewUp(nil)
        XCTAssertEqual(orderTitles(sheet), ["Tree", "Pretty", "Raw"])
        XCTAssertEqual(sheet.moveUpButton.keyEquivalentModifierMask, [.command, .option])
    }

    func testOrderRowsOfferVoiceOverMoveActions() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        let middle = try XCTUnwrap(sheet.orderTable.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let actions = middle.accessibilityCustomActions() ?? []
        XCTAssertEqual(actions.map(\.name), ["Move Up", "Move Down"])
        _ = actions.first?.handler?()
        XCTAssertEqual(orderTitles(sheet), ["Pretty", "Tree", "Raw"])
        let last = try XCTUnwrap(sheet.orderTable.view(atColumn: 0, row: 2, makeIfNecessary: true))
        XCTAssertEqual((last.accessibilityCustomActions() ?? []).map(\.name), ["Move Up"])
    }

    func testDropRowsTranslateToMoveDestinations() {
        XCTAssertEqual(FormatsAndViewsSheet.destination(dropRow: 3, source: 0), 2, "Below its own row")
        XCTAssertEqual(FormatsAndViewsSheet.destination(dropRow: 0, source: 2), 0, "To the top")
        XCTAssertEqual(FormatsAndViewsSheet.destination(dropRow: 1, source: 1), 1)
    }

    func testBinaryRowExplainsItsFixedView() throws {
        let sheet = makeSheet(selecting: .category(.binaryAndUnknown))
        let visible = descendants(sheet.view).filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertTrue(visible.contains { ($0 as? NSTextField)?.stringValue == FormatsAndViewsSheet.binaryMessage })
        XCTAssertTrue(sheet.orderTable.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(sheet.resetButton.isHidden)
    }

    // MARK: Reset

    func testResetToCategoryAndRestoreCategoryDefaults() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        XCTAssertEqual(sheet.resetButton.title, "Reset to Category")
        XCTAssertFalse(sheet.resetButton.isEnabled, "Nothing to reset while inherited")
        sheet.moveViewDown(nil)
        XCTAssertTrue(sheet.resetButton.isEnabled)
        sheet.reset(nil)
        XCTAssertNil(session.settings.formatOverrides["json"])
        XCTAssertEqual(try text("origin", .format(.json), in: sheet), "Inherited")

        sheet.select(.category(.sourceCode))
        XCTAssertEqual(sheet.resetButton.title, "Restore Category Defaults")
        sheet.setView(.hex, enabled: true, for: .category(.sourceCode))
        XCTAssertEqual(session.settings.categoryProfiles["sourceCode"], ["source", "raw", "hex"])
        XCTAssertTrue(sheet.resetButton.isEnabled)
        sheet.reset(nil)
        XCTAssertNil(session.settings.categoryProfiles["sourceCode"])
    }

    // MARK: Filters

    func testSearchMatchesNamesAndExtensionsAndExplainsNoResults() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        sheet.searchField.stringValue = "yml"
        sheet.filterChanged(nil)
        XCTAssertEqual(sheet.roots.map(\.scope), [.category(.structuredData)])
        XCTAssertEqual(sheet.roots.first?.children.map(\.scope), [.format(.spdxYAML), .format(.yaml)])
        sheet.searchField.stringValue = "Source Code"
        sheet.filterChanged(nil)
        XCTAssertEqual(sheet.roots.first?.children.count, ViewCategoryID.sourceCode.formats.count, "A category match lists its formats")
        XCTAssertTrue(sheet.emptyResults.isHidden)
        sheet.searchField.stringValue = "no-such-format"
        sheet.filterChanged(nil)
        XCTAssertTrue(sheet.roots.isEmpty)
        XCTAssertFalse(sheet.emptyResults.isHidden)
        XCTAssertNil(sheet.selectedScope)
        XCTAssertEqual(sheet.detailOrigin.stringValue, FormatsAndViewsSheet.hiddenBySearchMessage, "The hidden format stays in the detail column")
        sheet.searchField.stringValue = ""
        sheet.filterChanged(nil)
        XCTAssertEqual(sheet.roots.count, ViewCategoryID.allCases.count)
        XCTAssertEqual(sheet.selectedScope, .format(.json))
        XCTAssertNil(session.settings.formatOverrides["json"], "Filtering never edits settings")
    }

    func testCustomizedFilterShowsOnlyCustomizedRows() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        session.update { $0.setView(.hex, enabled: true, for: .format(.csv)) }
        session.update { $0.setView(.hex, enabled: true, for: .category(.sourceCode)) }
        let sheet = makeSheet(session)
        sheet.customizedOnly.state = .on
        sheet.filterChanged(nil)
        XCTAssertEqual(sheet.roots.map(\.scope), [.category(.tabularData), .category(.sourceCode)])
        XCTAssertEqual(sheet.roots.flatMap(\.children).map(\.scope), [.format(.csv)])
        sheet.select(.format(.csv))
        sheet.reset(nil)
        XCTAssertEqual(sheet.roots.map(\.scope), [.category(.sourceCode)], "A reset row leaves the Customized list")
    }

    // MARK: Options, mappings, read-only

    func testFormatOptionsAreContextual() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.csv))
        XCTAssertTrue(sheet.optionsButton.isHidden, "CSV has no format options")
        var presented: NSViewController?
        sheet.presentOptions = { presented = $0 }
        sheet.select(.format(.markdown))
        XCTAssertFalse(sheet.optionsButton.isHidden)
        sheet.showOptions(nil)
        let options = try XCTUnwrap(presented as? FormatOptionsSheet)
        XCTAssertEqual(options.format, .markdown)
        options.loadViewIfNeeded()
        let tasks = try XCTUnwrap(descendants(options.view).compactMap { $0 as? NSButton }.first { $0.title == "Task lists" })
        let before = EffectiveSettingsResolver.resolve(session.settings, for: .markdown).markdown.taskLists
        tasks.performClick(nil)
        XCTAssertEqual(EffectiveSettingsResolver.resolve(session.settings, for: .markdown).markdown.taskLists, !before)
        sheet.select(.format(.json))
        XCTAssertFalse(sheet.optionsButton.isHidden, "Structured formats have options")
        sheet.select(.category(.structuredData))
        XCTAssertTrue(sheet.optionsButton.isHidden, "Options are per format")
    }

    // MARK: File Mappings (D68)

    private func frame(_ view: NSView, in sheet: FormatsAndViewsSheet) -> NSRect { view.convert(view.alignmentRect(forFrame: view.bounds), to: sheet.view) }

    func testOneDetailColumnHoldsViewOrderThenFileMappings() throws {
        let sheet = makeSheet(selecting: .format(.json))
        XCTAssertFalse(descendants(sheet.view).contains { $0 is NSSegmentedControl || $0 is NSTabView }, "No Views | File Mappings picker")
        let matrix = frame(try XCTUnwrap(sheet.outline.enclosingScrollView), in: sheet)
        let order = frame(try XCTUnwrap(sheet.orderTable.enclosingScrollView), in: sheet)
        let list = frame(try XCTUnwrap(sheet.mappings.table.enclosingScrollView), in: sheet)
        XCTAssertGreaterThan(order.minX, matrix.maxX, "Detail sits right of the matrix")
        XCTAssertEqual(order.width, FormatsAndViewsSheet.detailWidth, accuracy: 1)
        XCTAssertTrue((260...300).contains(FormatsAndViewsSheet.detailWidth))
        XCTAssertEqual(list.minX, order.minX, accuracy: 1)
        // AppKit's view coordinates grow upward: later rows have smaller minY.
        let stackOrder = [sheet.detailTitle, sheet.orderTable.enclosingScrollView!, sheet.moveUpButton, sheet.resetButton,
                          sheet.mappings.heading, sheet.mappings.table.enclosingScrollView!, sheet.mappings.addButton]
        XCTAssertLessThan(frame(sheet.resetButton, in: sheet).maxX, frame(sheet.optionsButton, in: sheet).minX, "Reset, then Format Options")
        // At the opening size the whole column, +/– included, is visible without scrolling.
        let detail = try XCTUnwrap(descendants(sheet.view).first { $0.identifier?.rawValue == "FormatDetail" } as? NSScrollView)
        XCTAssertTrue(frame(detail.contentView, in: sheet).contains(frame(sheet.mappings.removeButton, in: sheet)), "+/– visible at the opening size")
        for (upper, lower) in zip(stackOrder, stackOrder.dropFirst()) {
            XCTAssertGreaterThan(frame(upper, in: sheet).minY, frame(lower, in: sheet).maxY - 1, "\(upper) above \(lower)")
        }
        XCTAssertEqual(sheet.mappings.table.tableColumns.map(\.title), ["Type", "Name or Extension"])
        XCTAssertLessThanOrEqual(list.height, 24 + 6 * 22, "A bounded list of about four to six rows")
        XCTAssertEqual(sheet.preferredContentSize, FormatsAndViewsSheet.preferredSize, "The sheet does not grow")
    }

    func testOpenEditorScrollsIntoViewAtTheOpeningSize() throws {
        let sheet = makeSheet(selecting: .format(.json))
        let detail = try XCTUnwrap(descendants(sheet.view).first { $0.identifier?.rawValue == "FormatDetail" } as? NSScrollView)
        sheet.mappings.beginAdd(nil)
        sheet.mappings.valueField.stringValue = "a/b"
        sheet.mappings.add(nil)
        let clip = frame(detail.contentView, in: sheet)
        for view in [sheet.mappings.valueField, sheet.mappings.feedback, sheet.mappings.confirmButton] as [NSView] {
            XCTAssertTrue(clip.contains(frame(view, in: sheet)), "\(view) \(frame(view, in: sheet)) visible in \(clip); doc \(detail.documentView!.frame) clipBounds \(detail.contentView.bounds)")
        }
    }

    func testMappingTableShowsOnlyTheSelectedFormatsMappings() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "conf", target: .yaml))
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "customjson", target: .json))
        XCTAssertNil(session.addMapping(kind: .filename, value: "Brewfile", target: .yaml))
        let sheet = makeSheet(session, selecting: .format(.xml))
        let mappings = sheet.mappings
        let empty = try XCTUnwrap(descendants(mappings.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "MappingListEmpty" })
        XCTAssertEqual(mappings.table.numberOfRows, 0)
        XCTAssertFalse(empty.isHiddenOrHasHiddenAncestor, "No custom file mappings")
        XCTAssertEqual(empty.stringValue, "No custom file mappings")
        sheet.select(.format(.json))
        XCTAssertEqual(mappings.table.numberOfRows, 1, "Catalog extensions such as .json are never listed")
        XCTAssertEqual(mappings.rows, [.init(kind: .fileExtension, value: "customjson", target: .json)])
        XCTAssertTrue(empty.isHidden)
        sheet.select(.format(.yaml))
        XCTAssertEqual(mappings.table.numberOfRows, 2)
        let kind = try XCTUnwrap(mappings.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        let value = try XCTUnwrap(mappings.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(kind.textField?.stringValue, "Exact Filename")
        XCTAssertEqual(value.textField?.stringValue, ".conf")
        XCTAssertEqual(session.settings.fileAssociations.count, 3, "Storage stays one global list")
    }

    func testCategoryAndNoSelectionExplainTheirContext() throws {
        let sheet = makeSheet(selecting: .category(.structuredData))
        let mappings = sheet.mappings
        XCTAssertEqual(mappings.context, .category)
        XCTAssertFalse(mappings.contextMessage.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(mappings.contextMessage.stringValue, "File mappings are configured for individual formats.")
        XCTAssertTrue(try XCTUnwrap(mappings.table.enclosingScrollView).isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(mappings.addButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(sheet.orderTable.isHiddenOrHasHiddenAncestor, "The category View Order stays")
        sheet.outline.deselectAll(nil)
        XCTAssertEqual(mappings.context, .none)
        XCTAssertEqual(sheet.detailOrigin.stringValue, "Select a format to configure its views and file mappings.")
        XCTAssertTrue(mappings.view.isHidden)
        XCTAssertFalse(mappings.canAdd)
    }

    func testAddTargetsTheSelectedFormatAndSelectsTheNewRow() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        let mappings = sheet.mappings
        XCTAssertTrue(mappings.editor.isHidden)
        XCTAssertEqual(sheet.doneButton.keyEquivalent, "\r")
        mappings.beginAdd(nil)
        XCTAssertTrue(mappings.isEditing)
        XCTAssertFalse(mappings.addButton.isEnabled)
        XCTAssertEqual(sheet.doneButton.keyEquivalent, "", "Return adds while the editor is open")
        XCTAssertEqual(mappings.confirmButton.keyEquivalent, "\r")
        XCTAssertEqual(mappings.kindPopup.itemTitles, ["Extension", "Exact Filename"])
        XCTAssertEqual(descendants(mappings.view).filter { $0 is NSPopUpButton }.count, 1, "No Preview As target popup")
        XCTAssertEqual(mappings.hint.stringValue, "Add a name or extension recognized as JSON.")
        mappings.valueField.stringValue = ".CustomJSON"
        mappings.add(nil)
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "customjson", target: .json)])
        XCTAssertFalse(mappings.isEditing)
        XCTAssertEqual(sheet.doneButton.keyEquivalent, "\r")
        XCTAssertEqual(mappings.selectedMapping, .init(kind: .fileExtension, value: "customjson", target: .json))
        mappings.beginAdd(nil)
        mappings.kindPopup.selectItem(at: 1)
        mappings.valueField.stringValue = "Pipfile.lock"
        mappings.add(nil)
        XCTAssertEqual(mappings.selectedMapping, .init(kind: .filename, value: "Pipfile.lock", target: .json))
        XCTAssertEqual(mappings.table.numberOfRows, 2)
    }

    func testAddShowsConflictsAndDuplicatesAndKeepsTheDraft() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "conf", target: .yaml))
        let sheet = makeSheet(session, selecting: .format(.json))
        let mappings = sheet.mappings
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "conf"
        mappings.add(nil)
        XCTAssertEqual(mappings.feedback.stringValue, "This extension is already mapped to YAML.")
        XCTAssertFalse(mappings.feedback.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(mappings.isEditing)
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "conf", target: .yaml)], "Never replaced")
        mappings.valueField.stringValue = "customjson"
        mappings.add(nil)
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "*.customjson"
        mappings.add(nil)
        XCTAssertEqual(mappings.feedback.stringValue, "This extension is already in the list.")
        XCTAssertEqual(mappings.table.numberOfRows, 1)
    }

    func testCancelEscapeAndFormatChangeDiscardTheDraft() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        let mappings = sheet.mappings
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "draft"
        mappings.cancelDraft(nil)
        XCTAssertFalse(mappings.isEditing)
        XCTAssertEqual(mappings.cancelButton.keyEquivalent, "\u{1b}")
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "draft"
        sheet.cancelOperation(nil)
        XCTAssertFalse(mappings.isEditing, "Escape closes the editor before the sheet")
        mappings.beginAdd(nil)
        mappings.valueField.stringValue = "draft"
        sheet.select(.format(.yaml))
        XCTAssertFalse(mappings.isEditing, "Another format cancels the draft")
        XCTAssertEqual(mappings.valueField.stringValue, "")
        XCTAssertTrue(session.settings.fileAssociations.isEmpty, "Nothing was written")
        XCTAssertEqual(sheet.doneButton.keyEquivalent, "\r")
    }

    func testRemoveDeletesTheSelectedKeyAndSelectsTheNextRow() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "conf", target: .yaml))
        for value in ["a1", "b2", "c3"] { XCTAssertNil(session.addMapping(kind: .fileExtension, value: value, target: .json)) }
        let sheet = makeSheet(session, selecting: .format(.json))
        let mappings = sheet.mappings
        XCTAssertFalse(mappings.removeButton.isEnabled, "Remove needs a selected mapping")
        mappings.table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertTrue(mappings.removeButton.isEnabled)
        mappings.remove(nil)
        XCTAssertEqual(session.settings.fileAssociations.map(\.value), ["conf", "a1", "c3"], "Removed by key, not by global index")
        XCTAssertEqual(mappings.selectedMapping?.value, "c3", "The next row takes the selection")
        mappings.remove(nil)
        XCTAssertEqual(mappings.selectedMapping?.value, "a1", "After the last row, the previous one")
        mappings.remove(nil)
        XCTAssertNil(mappings.selectedMapping)
        XCTAssertFalse(mappings.removeButton.isEnabled)
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "conf", target: .yaml)])
    }

    func testMappingsNeverChangeViewOrderOrInheritance() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let sheet = makeSheet(session, selecting: .format(.json))
        let views = sheet.orderedViews
        XCTAssertEqual(sheet.originLabel(of: .format(.json)), "Inherited")
        sheet.mappings.beginAdd(nil)
        sheet.mappings.valueField.stringValue = "customjson"
        sheet.mappings.add(nil)
        XCTAssertEqual(sheet.orderedViews, views)
        XCTAssertTrue(session.settings.formatOverrides.isEmpty, "A mapping creates no override")
        XCTAssertEqual(sheet.originLabel(of: .format(.json)), "Inherited")
        sheet.moveView(from: 0, to: 1)
        XCTAssertEqual(sheet.originLabel(of: .format(.json)), "Customized")
        sheet.reset(nil)
        XCTAssertEqual(sheet.originLabel(of: .format(.json)), "Inherited")
        XCTAssertEqual(session.settings.fileAssociations, [.init(kind: .fileExtension, value: "customjson", target: .json)],
                       "Reset to Category keeps mappings")
        sheet.mappings.remove(nil)
        XCTAssertEqual(sheet.orderedViews, views)
        XCTAssertTrue(session.settings.formatOverrides.isEmpty)
    }

    func testAFormatHiddenBySearchStaysButBlocksAdd() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "customjson", target: .json))
        let sheet = makeSheet(session, selecting: .format(.json))
        let mappings = sheet.mappings
        mappings.beginAdd(nil)
        sheet.searchField.stringValue = "yaml"
        sheet.filterChanged(nil)
        XCTAssertNil(sheet.selectedScope)
        XCTAssertEqual(mappings.context, .format(.json, hiddenBySearch: true))
        XCTAssertEqual(sheet.detailTitle.stringValue, "JSON")
        XCTAssertEqual(sheet.detailOrigin.stringValue, FormatsAndViewsSheet.hiddenBySearchMessage)
        XCTAssertFalse(mappings.contextMessage.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(mappings.isEditing, "The draft closes")
        XCTAssertFalse(mappings.addButton.isEnabled)
        mappings.beginAdd(nil)
        XCTAssertFalse(mappings.isEditing, "Add is blocked")
        XCTAssertEqual(mappings.table.numberOfRows, 1)
        sheet.searchField.stringValue = ""
        sheet.filterChanged(nil)
        XCTAssertEqual(sheet.selectedScope, .format(.json), "Clearing the search selects it again")
        XCTAssertTrue(mappings.addButton.isEnabled)
        sheet.select(.format(.yaml))
        sheet.searchField.stringValue = "json"
        sheet.filterChanged(nil)
        sheet.select(.format(.json))
        XCTAssertNil(sheet.hiddenScope, "Selecting a row replaces a hidden format")
    }

    func testMappingControlsAndRowsAreNamedForVoiceOver() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        XCTAssertNil(session.addMapping(kind: .fileExtension, value: "customjson", target: .json))
        let sheet = makeSheet(session, selecting: .format(.json))
        let mappings = sheet.mappings
        XCTAssertEqual(mappings.table.accessibilityLabel(), "File mappings for JSON")
        XCTAssertEqual(mappings.addButton.accessibilityLabel(), "Add file mapping")
        XCTAssertEqual(mappings.removeButton.accessibilityLabel(), "Remove file mapping")
        XCTAssertEqual(mappings.kindPopup.accessibilityLabel(), "Mapping type")
        XCTAssertEqual(mappings.valueField.accessibilityLabel(), "Name or extension")
        XCTAssertEqual(mappings.confirmButton.accessibilityLabel(), "Add file mapping")
        XCTAssertEqual(mappings.cancelButton.accessibilityLabel(), "Cancel new file mapping")
        let row = try XCTUnwrap(mappings.table.rowView(atRow: 0, makeIfNecessary: true))
        XCTAssertEqual(row.accessibilityLabel(), "Extension, .customjson, mapped to JSON.")
    }

    func testReadOnlySessionDisablesEveryEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtFormatsAndViews-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"schemaVersion":5}"#.utf8).write(to: directory.appendingPathComponent(SettingsStore.v3Filename))
        let session = await SettingsSession.load(store: SettingsStore(directory: directory))
        XCTAssertFalse(session.canEdit)
        let sheet = makeSheet(session, selecting: .format(.json))
        XCTAssertEqual(try checkbox(.hex, .format(.json), in: sheet)?.isEnabled, false)
        XCTAssertFalse(sheet.moveDownButton.isEnabled)
        XCTAssertFalse(sheet.resetButton.isEnabled)
        XCTAssertNil(sheet.tableView(sheet.orderTable, pasteboardWriterForRow: 0), "No drag in a read-only session")
        XCTAssertFalse(sheet.mappings.addButton.isEnabled)
        sheet.mappings.beginAdd(nil)
        XCTAssertFalse(sheet.mappings.isEditing, "No mapping editor in a read-only session")
    }

    // MARK: Window behaviour

    func testSheetIsLargeResizableAndKeepsTheEditorInsideAtMinimumSize() throws {
        let sheet = makeSheet(size: FormatsAndViewsSheet.minimumSize)
        XCTAssertEqual(sheet.preferredContentSize, NSSize(width: 1060, height: 720))
        XCTAssertEqual(FormatsAndViewsSheet.minimumSize, NSSize(width: 880, height: 600))
        let bounds = sheet.view.bounds
        for view in [sheet.orderTable.enclosingScrollView, sheet.resetButton, sheet.outline.enclosingScrollView] {
            let frame = try XCTUnwrap(view).convert(try XCTUnwrap(view).bounds, to: sheet.view)
            XCTAssertTrue(bounds.insetBy(dx: 19, dy: 19).contains(frame), "\(String(describing: view)) \(frame) fits \(bounds)")
        }
        let done = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "FormatsAndViewsDone" })
        XCTAssertEqual(done.keyEquivalent, "\r")
    }

    func testSettingsWindowOpensASingleSheet() throws {
        let session = SettingsSession(store: nil, snapshot: nil)
        let root = SettingsRootViewController(session: session)
        var presentations = 0
        var presented: NSViewController?
        root.presentSheet = { presentations += 1; presented = $0 }
        let first = root.showFormatsAndViews()
        let second = root.showFormatsAndViews(selecting: .format(.csv))
        XCTAssertTrue(first === second)
        XCTAssertTrue(presented === first)
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(second.selectedScope, .format(.csv))
    }
}
