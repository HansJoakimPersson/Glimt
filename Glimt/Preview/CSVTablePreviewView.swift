import AppKit
import InspectorCore

@MainActor
final class CSVTablePreviewView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private var model: TableRows?
    private var visibleRows: [Int] = []
    private var filters: [Int: String] = [:]
    private var sortColumn: Int?
    private var sortAscending = true
    private var interactiveHeaders = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// Connects the table as the scroll view document and exposes a concise accessibility name.
    private func configure() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.setAccessibilityLabel("Tabular preview")
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        documentView = tableView
    }

    /// Rebuilds columns for the bounded parsed table and reloads its visible rows.
    func display(_ model: CSVTable?) {
        interactiveHeaders = false
        filters.removeAll()
        sortColumn = nil
        display(headers: model?.headers, rows: model?.rows)
    }

    /// Displays a semantic table projection from any inspector without parsing source text here.
    func display(headers: [String]?, rows: [[String]]?, minimumWidths: [CGFloat]? = nil,
                 interactiveHeaders: Bool = false, resetControls: Bool = false) {
        self.interactiveHeaders = interactiveHeaders
        if resetControls {
            filters.removeAll()
            sortColumn = nil
            sortAscending = true
        }
        model = headers.flatMap { headers in rows.map { TableRows(headers: headers, rows: $0) } }
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        filters = filters.filter { $0.key < (model?.headers.count ?? 0) }
        if let sortColumn, sortColumn >= (model?.headers.count ?? 0) { self.sortColumn = nil }
        guard let model, !model.headers.isEmpty else {
            visibleRows = []
            tableView.reloadData()
            return
        }

        for index in model.headers.indices {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column-\(index)"))
            column.title = model.headers[index]
            if interactiveHeaders {
                column.headerCell = FilterableHeaderCell(textCell: model.headers[index])
                column.headerCell.menu = headerMenu(for: index)
            }
            let equalWidth = max(1, bounds.width / CGFloat(model.columnCount))
            let minimumWidth = minimumWidths.flatMap { widths in
                widths.indices.contains(index) ? widths[index] : nil
            } ?? 0
            column.width = max(equalWidth, minimumWidth)
            tableView.addTableColumn(column)
        }
        updateVisibleRows()
        tableView.reloadData()
    }

    /// Exposes parsed data rows; the column heading is rendered separately by the table.
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    /// Supplies a cell only for indices present in the model; stale table callbacks receive empty text.
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let model, visibleRows.indices.contains(row), let tableColumn,
              let index = tableView.tableColumns.firstIndex(of: tableColumn),
              model.rows[visibleRows[row]].indices.contains(index) else { return "" }
        return model.rows[visibleRows[row]][index]
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard interactiveHeaders, let index = tableView.tableColumns.firstIndex(of: tableColumn) else { return }
        if sortColumn == index { sortAscending.toggle() }
        else { sortColumn = index; sortAscending = true }
        updateVisibleRows()
        for (columnIndex, column) in tableView.tableColumns.enumerated() {
            guard let model, model.headers.indices.contains(columnIndex) else { continue }
            let marker = columnIndex == sortColumn ? (sortAscending ? " ↑" : " ↓") : ""
            column.headerCell.title = model.headers[columnIndex] + marker
        }
        tableView.reloadData()
    }

    private func headerMenu(for column: Int) -> NSMenu {
        let menu = NSMenu()
        let filter = NSMenuItem(title: "Filter…", action: #selector(setColumnFilter(_:)), keyEquivalent: "")
        filter.target = self
        filter.representedObject = column
        menu.addItem(filter)
        let clear = NSMenuItem(title: "Clear Filter", action: #selector(clearColumnFilter(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = column
        clear.isEnabled = filters[column] != nil
        menu.addItem(clear)
        return menu
    }

    @objc private func setColumnFilter(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int, let model,
              model.headers.indices.contains(column) else { return }
        let alert = NSAlert()
        alert.messageText = "Filter \(model.headers[column])"
        alert.informativeText = "Show rows where this column contains:"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: filters[column] ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        applyFilter(value.isEmpty ? nil : value, to: column)
    }

    func applyFilter(_ query: String?, to column: Int) {
        guard interactiveHeaders, model?.headers.indices.contains(column) == true else { return }
        if let query, !query.isEmpty { filters[column] = query }
        else { filters.removeValue(forKey: column) }
        updateVisibleRows()
        tableView.reloadData()
        if tableView.tableColumns.indices.contains(column) {
            tableView.tableColumns[column].headerCell.menu = headerMenu(for: column)
        }
    }

    @objc private func clearColumnFilter(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? Int else { return }
        filters.removeValue(forKey: column)
        updateVisibleRows()
        tableView.reloadData()
        if tableView.tableColumns.indices.contains(column) {
            tableView.tableColumns[column].headerCell.menu = headerMenu(for: column)
        }
    }

    private func updateVisibleRows() {
        guard let model else { visibleRows = []; return }
        visibleRows = model.rows.indices.filter { row in
            filters.allSatisfy { column, query in
                model.rows[row].indices.contains(column)
                    && model.rows[row][column].localizedCaseInsensitiveContains(query)
            }
        }
        guard let sortColumn, model.headers.indices.contains(sortColumn) else { return }
        visibleRows.sort { left, right in
            let lhs = model.rows[left].indices.contains(sortColumn) ? model.rows[left][sortColumn] : ""
            let rhs = model.rows[right].indices.contains(sortColumn) ? model.rows[right][sortColumn] : ""
            let result = lhs.localizedStandardCompare(rhs)
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private struct TableRows {
        let headers: [String]
        let rows: [[String]]
        var columnCount: Int { headers.count }
    }

    private final class FilterableHeaderCell: NSTableHeaderCell {
        override func draw(withFrame frame: NSRect, in controlView: NSView) {
            super.draw(withFrame: frame, in: controlView)
            let mark = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "Column filter")
            mark?.isTemplate = true
            if let mark {
                let rect = NSRect(x: frame.maxX - 17, y: frame.midY - 5, width: 10, height: 10)
                mark.draw(in: rect)
            }
        }
    }
}
