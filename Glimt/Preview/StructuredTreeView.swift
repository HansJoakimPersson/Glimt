import AppKit
import InspectorCore
import enum InspectorCore.XMLNode

/// Native, lazily materialized rows over the already inspected semantic model.
final class StructuredTreeView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private var root: StructuredOutlineItem?
    private var sortKeys = false
    private var expandDepth = 1
    private var highlightsLogLevels = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// Builds the three-column outline; rows are materialized on demand from the inspected model.
    private func configure() {
        hasVerticalScroller = true
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        autohidesScrollers = true
        for name in ["Key", "Value", "Type"] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = name
            column.width = name == "Type" ? 100 : name == "Key" ? 180 : 280
            column.minWidth = name == "Type" ? 64 : 80
            column.headerCell = StructuredTreeHeaderCell(textCell: name)
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("JSON structure")
        documentView = outline
    }

    /// Presentation preferences apply to the next display; semantic models and Raw are untouched.
    func configure(sortKeys: Bool, expandDepth: Int, highlightsLogLevels: Bool = false) {
        self.sortKeys = sortKeys
        self.expandDepth = min(max(expandDepth, 1), 3)
        self.highlightsLogLevels = highlightsLogLevels
    }

    /// Expands only the configured initial depth so large trees remain lazy and navigable.
    private func expand(_ item: StructuredOutlineItem, remainingDepth: Int) {
        guard remainingDepth > 0, item.childCount > 0 else { return }
        outline.expandItem(item)
        guard remainingDepth > 1 else { return }
        for index in 0..<item.childCount {
            expand(item.child(at: index), remainingDepth: remainingDepth - 1)
        }
    }

    /// Replaces the tree root and reloads before expanding, preventing rows from separate inspections mixing.
    func display(_ value: StructuredValue?, formatName: String = "JSON", rootKey: String = "$", preserveMultiline: Bool = false) {
        // Replace the root before reloading so the outline cannot mix rows from different inspections.
        outline.setAccessibilityLabel("\(formatName) structure")
        root = value.map { StructuredOutlineItem(key: rootKey, value: $0, preserveMultiline: preserveMultiline, sortKeys: sortKeys) }
        outline.reloadData()
        if let root { expand(root, remainingDepth: expandDepth) }
    }

    /// Adapts the XML root into an outline item while keeping the original XML model unchanged.
    func displayXML(_ node: XMLNode?) {
        outline.setAccessibilityLabel("XML structure")
        root = node.map {
            let name: String
            if case .element(let element) = $0 { name = element.name } else { name = "XML" }
            return StructuredOutlineItem(key: name, content: .xml($0), sortKeys: sortKeys)
        }
        outline.reloadData()
        if let root { expand(root, remainingDepth: expandDepth) }
    }

    /// Replaces the current root with a typed property-list view and reapplies configured expansion.
    func displayPlist(_ value: PlistValue?) {
        outline.setAccessibilityLabel("Property list structure")
        root = value.map { StructuredOutlineItem(key: "$", content: .plist($0), sortKeys: sortKeys) }
        outline.reloadData()
        if let root { expand(root, remainingDepth: expandDepth) }
    }

    /// Exposes the current root as the outline's single top-level item.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? StructuredOutlineItem)?.childCount ?? (root == nil ? 0 : 1)
    }

    /// Requests children lazily so collapsed branches do not eagerly allocate view models.
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? StructuredOutlineItem { return item.child(at: index) }
        return root ?? StructuredOutlineItem(key: "$", value: .null)
    }

    /// Reports expandability from semantic child counts without constructing child rows.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? StructuredOutlineItem)?.childCount ?? 0 > 0
    }

    /// Gives multiline scalars a bounded row height; other formats retain the native row height.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? StructuredOutlineItem, item.preserveMultiline else { return outlineView.rowHeight }
        let lines = min(8, item.text(for: "Value").split(separator: "\n", omittingEmptySubsequences: false).count)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return max(outlineView.rowHeight, CGFloat(lines) * lineHeight + outlineView.intercellSpacing.height)
    }

    /// Reuses native labels and applies only the row's already bounded text projection.
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? StructuredOutlineItem, let identifier = tableColumn?.identifier else { return nil }
        let label = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = identifier.rawValue == "Type" ? .secondaryLabelColor : .labelColor
        if highlightsLogLevels, identifier.rawValue == "Value",
           ["level", "severity", "severitytext"].contains(item.key.lowercased()),
           let levelColor = Self.logLevelColor(for: item.text(for: "Value")) {
            label.textColor = levelColor
        }
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = !item.preserveMultiline
        label.maximumNumberOfLines = item.preserveMultiline ? 8 : 1
        label.stringValue = item.text(for: identifier.rawValue)
        label.setAccessibilityLabel(label.stringValue)
        return label
    }

    static func logLevelColor(for level: String) -> NSColor? {
        switch level.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "EMERGENCY", "ALERT", "CRITICAL", "FATAL", "ERROR": .systemRed
        case "WARN", "WARNING", "HIGH": .systemOrange
        case "NOTICE", "INFO", "LOW": .controlAccentColor
        case "TRACE", "DEBUG": .secondaryLabelColor
        default: nil
        }
    }
}

/// Keeps native table-header drawing while using the preview's effective appearance for its title color.
final class StructuredTreeHeaderCell: NSTableHeaderCell {
    /// Draws the semantic value using its resolved type color and tree-row geometry.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let color = Self.resolvedLabelColor(for: controlView.effectiveAppearance)
        let title = NSMutableAttributedString(attributedString: attributedStringValue)
        if title.length > 0 {
            title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
            attributedStringValue = title
        }
        textColor = color
        super.draw(withFrame: cellFrame, in: controlView)
    }

    /// Resolves header label color in the preview's effective light/dark appearance.
    static func resolvedLabelColor(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? NSColor.labelColor
        }
        return color
    }
}

// Concrete UI adapters over the three existing semantic models; parsers retain their own types.
private enum OutlineContent {
    case structured(StructuredValue)
    case xml(XMLNode)
    case attribute(XMLAttribute)
    case plist(PlistValue)
}

@MainActor
private final class StructuredOutlineItem {
    let key: String
    private let content: OutlineContent
    private var children: [Int: StructuredOutlineItem] = [:]
    let preserveMultiline: Bool

    private let sortKeys: Bool
    private let childOrder: [Int]?

    convenience init(key: String, value: StructuredValue, preserveMultiline: Bool = false, sortKeys: Bool = false) {
        self.init(key: key, content: .structured(value), preserveMultiline: preserveMultiline, sortKeys: sortKeys)
    }

    /// Captures one semantic node and precomputes stable source indices only when sorting is requested.
    init(key: String, content: OutlineContent, preserveMultiline: Bool = false, sortKeys: Bool = false) {
        self.key = key
        self.content = content
        self.preserveMultiline = preserveMultiline
        self.sortKeys = sortKeys
        if sortKeys {
            let keys: [String]?
            switch content {
            case .structured(.object(let members)): keys = members.map(\.key)
            case .plist(.dictionary(let members)): keys = members.map(\.key)
            default: keys = nil
            }
            // Explicit original indices preserve duplicate-key order, independent of sort stability.
            childOrder = keys.map { keys in
                keys.indices.sorted { left, right in
                    keys[left] == keys[right] ? left < right : keys[left] < keys[right]
                }
            }
        } else {
            childOrder = nil
        }
    }

    var childCount: Int {
        switch content {
        case .structured(.object(let members)): members.count
        case .structured(.array(let values)): values.count
        case .xml(.element(let element)): element.attributes.count + element.children.count
        case .plist(.dictionary(let members)): members.count
        case .plist(.array(let values)): values.count
        default: 0
        }
    }

    /// Creates and caches one child adapter, preserving duplicate mapping keys and source order.
    func child(at index: Int) -> StructuredOutlineItem {
        if let cached = children[index] { return cached }
        let child: StructuredOutlineItem
        let sourceIndex = childOrder?[index] ?? index
        switch content {
        case .structured(.object(let members)):
            child = .init(key: members[sourceIndex].key, value: members[sourceIndex].value, preserveMultiline: preserveMultiline, sortKeys: sortKeys)
        case .structured(.array(let values)):
            child = .init(key: "[\(index)]", value: values[index], preserveMultiline: preserveMultiline, sortKeys: sortKeys)
        case .xml(.element(let element)):
            if index < element.attributes.count {
                let attribute = element.attributes[index]
                child = .init(key: "@" + attribute.name, content: .attribute(attribute), sortKeys: sortKeys)
            } else {
                let node = element.children[index - element.attributes.count]
                let name: String
                switch node {
                case .element(let element): name = element.name
                case .text: name = "#text"
                case .comment: name = "#comment"
                }
                child = .init(key: name, content: .xml(node), sortKeys: sortKeys)
            }
        case .plist(.dictionary(let members)):
            child = .init(key: members[sourceIndex].key, content: .plist(members[sourceIndex].value), sortKeys: sortKeys)
        case .plist(.array(let values)):
            child = .init(key: "[\(index)]", content: .plist(values[index]), sortKeys: sortKeys)
        default: return self
        }
        children[index] = child
        return child
    }

    /// Produces bounded Key/Value/Type display strings without changing semantic values.
    func text(for column: String) -> String {
        if column == "Key" { return Self.summary(key) }
        switch content {
        case .structured(let value): return structuredText(value, column: column)
        case .attribute(let attribute): return scalar(attribute.value, type: "Attribute", column: column)
        case .xml(let node):
            switch node {
            case .element(let element):
                if column == "Type" { return "Element" }
                if element.children.count == 1, case .text(let value) = element.children[0] { return Self.summary(value) }
                return "\(element.attributes.count) attributes · \(element.children.count) children"
            case .text(let text): return scalar(text, type: "Text", column: column)
            case .comment(let text): return scalar(text, type: "Comment", column: column)
            }
        case .plist(let value):
            switch value {
            case .dictionary(let members): return column == "Type" ? "Dictionary" : "\(members.count) keys"
            case .array(let values): return column == "Type" ? "Array" : "\(values.count) items"
            case .string(let text): return scalar(text, type: "String", column: column)
            case .integer(let value): return column == "Type" ? "Integer" : Self.summary(value)
            case .real(let value): return column == "Type" ? "Real" : String(value)
            case .boolean(let value): return column == "Type" ? "Boolean" : (value ? "true" : "false")
            case .date(let date): return column == "Type" ? "Date" : Self.dateFormatter.string(from: date)
            case .data(let data): return column == "Type" ? "Data" : ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            }
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formats a scalar for the tree while retaining type and source-column context.
    private func scalar(_ string: String, type: String, column: String) -> String {
        column == "Type" ? type : "\"" + Self.summary(string, preserveMultiline: preserveMultiline) + "\""
    }

    /// Maps JSON/YAML scalar and container cases into concise table text for the requested column.
    private func structuredText(_ value: StructuredValue, column: String) -> String {
        switch value {
        case .object(let members): return column == "Type" ? "Object" : "\(members.count) keys"
        case .array(let elements): return column == "Type" ? "Array" : "\(elements.count) items"
        case .string(let string):
            if column == "Type" { return "String" }
            let value = Self.summary(string, preserveMultiline: preserveMultiline)
            return preserveMultiline && string.contains("\n") ? value : "\"\(value)\""
        case .number(let number): return column == "Type" ? "Number" : Self.summary(number)
        case .boolean(let boolean): return column == "Type" ? "Boolean" : (boolean ? "true" : "false")
        case .null: return column == "Type" ? "Null" : "null"
        }
    }

    /// Creates a compact one-line tree value unless the structured view should preserve line breaks.
    private static func summary(_ string: String, preserveMultiline: Bool = false) -> String {
        // Bound cell work even for one enormous key or value; complete content remains in Raw.
        let scalars = string.unicodeScalars.prefix(256)
        var result = String(String.UnicodeScalarView(scalars))
        if scalars.endIndex != string.unicodeScalars.endIndex { result += "…" }
        if preserveMultiline { return result }
        return result.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
