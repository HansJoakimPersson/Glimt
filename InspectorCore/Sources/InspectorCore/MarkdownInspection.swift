import Foundation

/// Interpretation controls are applied by Core; changing them requires fresh inspection.
public enum MarkdownBreakBehavior: String, Codable, CaseIterable, Sendable { case standard, preserveSoftLines }
/// Controls whether leading YAML front matter is shown, hidden, or summarized as metadata.
public enum MarkdownFrontMatterMode: String, Codable, CaseIterable, Sendable { case show, hide, metadata }

/// Parser options that change Markdown interpretation and therefore require reinspection.
public struct MarkdownOptions: Equatable, Sendable {
    public let taskLists: Bool
    public let strikethrough: Bool
    public let breakBehavior: MarkdownBreakBehavior
    public let frontMatter: MarkdownFrontMatterMode
    public let tableOfContents: Bool

    /// Creates options for supported task, strikethrough, line-break, front-matter, and TOC behavior.
    public init(taskLists: Bool = true, strikethrough: Bool = true,
                breakBehavior: MarkdownBreakBehavior = .standard,
                frontMatter: MarkdownFrontMatterMode = .show, tableOfContents: Bool = false) {
        self.taskLists = taskLists; self.strikethrough = strikethrough
        self.breakBehavior = breakBehavior; self.frontMatter = frontMatter
        self.tableOfContents = tableOfContents
    }
}

/// Parsed heading metadata, including its resolved local anchor and rendered UTF-16 range.
public struct MarkdownHeading: Equatable, Sendable {
    public let level: Int
    public let title: String
    /// A trailing `{#id}` on the heading line, otherwise a GitHub-style slug unique within the document.
    public var anchor: String = ""
    /// UTF-16 range of the visible heading title in `MarkdownDocument.renderedText`.
    public var range: NSRange = .init(location: 0, length: 0)
}

/// A local-only link from TOC or a fragment reference to one heading in `renderedText`.
public struct MarkdownNavigationLink: Equatable, Sendable {
    public let range: NSRange
    public let targetRange: NSRange
    public let headingIndex: Int
    public let anchor: String
}

/// Bounded inline image content; unresolved or disallowed resources retain their alt text.
public struct MarkdownImageReference: Equatable, Sendable {
    public var range: NSRange
    public let destination: String
    public var data: Data? = nil
    public var pixelWidth: Int? = nil
    public var pixelHeight: Int? = nil
}

/// A bounded delimited math expression in `MarkdownDocument.renderedText`.
public struct MarkdownMathExpression: Equatable, Sendable {
    /// Whether the expression uses inline or display-style layout.
    public enum Mode: Equatable, Sendable { case inline, display }
    public let range: NSRange
    public let latex: String
    public let mode: Mode
    /// Exact visible source used when the renderer cannot typeset this expression.
    public let fallbackText: String
}

/// Collects one fenced Mermaid source block and its range before parsing and layout.
private struct MarkdownMermaidAccumulator {
    let identity: Int
    let start: Int
    var end: Int
    var source: String
    var isOversized = false
    var range: NSRange { NSRange(location: start, length: end - start) }
}

/// GFM footnotes: an inline numbered reference, or text in the trailing footnote list.
public enum MarkdownFootnoteRole: Equatable, Sendable { case reference, definition }

/// Inert styling over Glimt-owned UTF-16 text. URLs, attachments and HTML are never activated.
public struct MarkdownStyleRun: Equatable, Sendable {
    public let range: NSRange
    public let headingLevel: Int?
    public let bold: Bool
    public let italic: Bool
    public let strikethrough: Bool
    public let code: Bool
    public let quote: Bool
    public let syntax: SyntaxTokenKind?
    public let tableCell: Bool
    public var footnote: MarkdownFootnoteRole? = nil
    /// Set on the title run of a GitHub alert.
    public var alert: MarkdownAlertKind? = nil
    /// `==text==` outside code.
    public var highlight: Bool = false
    /// `^text^` or `<sup>text</sup>` outside code.
    public var isSuperscript: Bool = false
    /// `<sub>text</sub>` outside code; `~text~` stays GFM strikethrough.
    public var isSubscript: Bool = false
    /// `#tag` after whitespace or at a line start, outside code, links and headings.
    public var hashtag: Bool = false
}

/// UTF-16 cell ranges into renderedText, preserving native row/column positions and inline styles.
public struct MarkdownTableCell: Equatable, Sendable {
    public let range: NSRange
    public let row: Int
    public let column: Int

    public init(range: NSRange, row: Int, column: Int) {
        self.range = range; self.row = row; self.column = column
    }
}

/// Table geometry and cell ranges in the rendered Markdown string.
public struct MarkdownTable: Equatable, Sendable {
    public let columnCount: Int
    public let cells: [MarkdownTableCell]

    /// Creates a table model from the expanded column count and rendered cell ranges.
    public init(columnCount: Int, cells: [MarkdownTableCell]) {
        self.columnCount = columnCount; self.cells = cells
    }
}

/// GFM task state of a list item; the checkbox is inert text and never toggles the file.
public enum MarkdownTaskState: Equatable, Sendable { case open, done }

/// One list paragraph in renderedText. `depth` starts at 1; `markerLength` covers the bullet,
/// number and/or checkbox before the item text and is 0 for an item's continuation paragraphs.
public struct MarkdownListParagraph: Equatable, Sendable {
    public let range: NSRange
    public let depth: Int
    public let markerLength: Int
    public let task: MarkdownTaskState?
}

/// GitHub alert types, written `> [!NOTE]` alone on the first line of a top-level quote.
public enum MarkdownAlertKind: String, CaseIterable, Equatable, Sendable {
    case note, tip, important, warning, caution

    public var title: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }
}

/// A GitHub alert in renderedText: the title line plus the quote's content.
public struct MarkdownAlert: Equatable, Sendable {
    public let range: NSRange
    public let kind: MarkdownAlertKind
    public let title: String?

    /// Creates an alert record covering its rendered title and quoted content.
    public init(range: NSRange, kind: MarkdownAlertKind, title: String? = nil) {
        self.range = range
        self.kind = kind
        self.title = title
    }
}

/// One top-level definition list group in renderedText.
public struct MarkdownDefinitionList: Equatable, Sendable {
    public let termRange: NSRange
    public let definitionRanges: [NSRange]
}

/// Semantic Markdown output shared by the host and Quick Look renderers.
public struct MarkdownDocument: Equatable, Sendable {
    public let raw: String
    public let renderedText: String?
    public let runs: [MarkdownStyleRun]
    public let diagnostics: [InspectionDiagnostic]
    public let headings: [MarkdownHeading]
    public let frontMatter: StructuredValue?
    public let tables: [MarkdownTable]
    public let listParagraphs: [MarkdownListParagraph]
    public let alerts: [MarkdownAlert]
    public var definitionLists: [MarkdownDefinitionList] = []
    public var navigationLinks: [MarkdownNavigationLink] = []
    public var images: [MarkdownImageReference] = []
    public var mathExpressions: [MarkdownMathExpression] = []
    public var mermaidBlocks: [MarkdownMermaidBlock] = []
}

/// Native CommonMark/GFM presentation, bounded before entering Foundation's synchronous parser.
/// Cancellation is cooperative: an individual Foundation call cannot be preempted.
/// Foundation has no footnote syntax and would read `[^x]: text` as a link reference definition,
/// so footnote definitions are removed before parsing and rendered as a trailing numbered list.
/// Foundation also unescapes `\\[ ]` and has no alert syntax, so unescaped task markers at list-item
/// starts and alert markers on quote lines are replaced by private-use placeholders before parsing;
/// any placeholder that does not become a checkbox or alert title is restored to its exact source text.
/// A trailing `{#id}` on an ATX heading line is marked the same way and becomes the heading anchor,
/// and tight `==text==`, `^text^` and lowercase `<sup>`/`<sub>` pairs on one line outside code
/// spans become inline markers. `[[Page]]` and `[[Page|Label]]` wikilinks keep only their label.
/// `#tag` gets zero-width markers around it, so its text is kept.
public enum MarkdownInspector {
    /// Converts a bounded text analysis to semantic Markdown metadata and a native-renderable string.
    /// Each preprocessing pass is checkpointed because Foundation's parser itself is synchronous.
    public static func inspect(analysis: TextAnalysis, options: MarkdownOptions = .init()) throws -> MarkdownDocument {
        try Task.checkCancellation()
        /// Keeps original text available when Markdown interpretation is unsupported or exceeds a hard limit.
        func fallback(_ code: InspectionDiagnostic.Code, _ message: String) -> MarkdownDocument {
            .init(raw: analysis.text, renderedText: nil, runs: [], diagnostics: [.init(code: code, message: message)], headings: [], frontMatter: nil, tables: [], listParagraphs: [], alerts: [])
        }
        guard !analysis.truncated else { return fallback(.truncated, "Markdown input is incomplete. Raw remains available.") }
        guard !analysis.isBinary, analysis.text.utf8.count <= 1_048_576 else {
            return fallback(.limitExceeded, "Markdown rendering limit reached. Raw remains available.")
        }
        let checkpoint = { try Task.checkCancellation() }
        do {
            try checkpoint()
            let frontMatter = try leadingFrontMatter(analysis.text, checkpoint: checkpoint)
            let footnotes = try extractFootnotes(frontMatter?.body ?? analysis.text, checkpoint: checkpoint)
            let admonitionInput = try markAdmonitions(footnotes.body,
                                                       sourceHasPlaceholderCollision: analysis.text.unicodeScalars.contains {
                                                           placeholderScalars.contains($0.value)
                                                       }, checkpoint: checkpoint)
            let definitionPass = try markDefinitionLists(admonitionInput, checkpoint: checkpoint)
            let mathPass = try MarkdownMathExpressions.mark(in: definitionPass.text, checkpoint: checkpoint)
            let prePlaceholderInput = mathPass.text
            let body = try markPlaceholders(mathPass.text, tasks: options.taskLists,
                                            allowingDefinitionMarkers: !definitionPass.occurrences.isEmpty,
                                            allowingAdmonitionTitleMarker: !analysis.text.unicodeScalars.contains(admonitionTitleMarker))
            let placeholdersMarked = body != prePlaceholderInput || !definitionPass.occurrences.isEmpty
            let parsed = try AttributedString(markdown: body, options: .init(interpretedSyntax: .full))
            var occurrenceGroups = Array(repeating: -1, count: definitionPass.occurrences.count)
            for (groupIndex, group) in definitionPass.groups.enumerated() {
                occurrenceGroups[group.termOccurrence] = groupIndex
                for occurrence in group.definitionOccurrences { occurrenceGroups[occurrence] = groupIndex }
            }
            var validDefinitionOccurrences = Array(repeating: false, count: definitionPass.occurrences.count)
            var seenDefinitionOccurrences: Set<Int> = []
            var parsedDefinitionCursor = 0
            for run in parsed.runs {
                try checkpoint()
                let text = String(parsed[run.range].characters)
                guard let first = text.unicodeScalars.first,
                      first == definitionTermMarker || first == definitionBodyMarker,
                      parsedDefinitionCursor < definitionPass.occurrences.count else { continue }
                let metadata = definitionPass.occurrences[parsedDefinitionCursor]
                let matches = metadata.term == (first == definitionTermMarker)
                let components = run.presentationIntent?.components ?? []
                let ordinary = !components.contains { component in
                    switch component.kind {
                    case .header, .orderedList, .unorderedList, .listItem, .blockQuote, .codeBlock,
                         .tableHeaderRow, .tableRow, .tableCell, .table: true
                    default: false
                    }
                }
                if matches {
                    validDefinitionOccurrences[parsedDefinitionCursor] = ordinary
                    seenDefinitionOccurrences.insert(parsedDefinitionCursor)
                }
                parsedDefinitionCursor += 1
            }
            for occurrence in definitionPass.occurrences.indices where !seenDefinitionOccurrences.contains(occurrence) {
                validDefinitionOccurrences[occurrence] = false
            }
            var invalidDefinitionGroups: Set<Int> = []
            for occurrence in definitionPass.occurrences.indices where !validDefinitionOccurrences[occurrence] {
                if occurrenceGroups[occurrence] >= 0 { invalidDefinitionGroups.insert(occurrenceGroups[occurrence]) }
            }
            var footnoteNumbers: [String: Int] = [:]
            var footnoteOrder: [String] = []
            try checkpoint()
            var output = ""
            var length = 0
            var styles: [MarkdownStyleRun] = []
            var previousBlock: Int?
            var previousOuterList: Int?
            var markedItems: Set<Int> = []
            var listParagraphs: [MarkdownListParagraph] = []
            var openListParagraph: Int?
            var alerts: [MarkdownAlert] = []
            var definitionRanges: [Int: NSRange] = [:]
            var definitionCursor = 0
            var activeDefinition: (occurrence: Int, term: Bool, block: Int?)?
            var alertQuotes: [Int: Int] = [:]
            var seenQuotes: Set<Int> = []
            var alertTitleBlock: Int?
            var alertBreakPending = false
            var previousRow: Int?
            var inlineMarks = InlineMarks()
            var tableBuilders: [MarkdownTableBuilder] = []
            var tableIndices: [Int: Int] = [:]
            var mermaidAccumulators: [Int: MarkdownMermaidAccumulator] = [:]
            var mermaidOrder: [Int] = []
            /// Appends only while the rendered UTF-8 output remains within the global output cap.
            func append(_ text: String) throws {
                guard text.utf8.count <= 262_144 - output.utf8.count else { throw MarkdownLimit.exceeded }
                output += text
                length += text.utf16.count
            }
            var headings: [MarkdownHeading] = []
            var headingIndices: [Int: Int] = [:]
            var previousHeadingID: Int?
            var currentHeadingIndex: Int?
            for run in parsed.runs {
                try checkpoint()
                if let header = run.presentationIntent?.components.first(where: { if case .header = $0.kind { true } else { false } }),
                   case .header(let level) = header.kind {
                    let (stripped, anchor) = headingAnchor(String(parsed[run.range].characters), marked: placeholdersMarked)
                    let text = mathPass.restore(restorePlaceholders(removingInlineMarkers(stripped), marked: placeholdersMarked)).text
                    if previousHeadingID == header.identity {
                        if let index = currentHeadingIndex {
                            headings[index] = .init(level: level, title: String((headings[index].title + text).unicodeScalars.prefix(256)),
                                                    anchor: anchor ?? headings[index].anchor)
                        }
                    } else if headings.count < 128 {
                        currentHeadingIndex = headings.count
                        headings.append(.init(level: level, title: String(text.unicodeScalars.prefix(256)), anchor: anchor ?? ""))
                    } else {
                        if options.tableOfContents { throw MarkdownLimit.exceeded }
                        currentHeadingIndex = nil
                    }
                    if let currentHeadingIndex { headingIndices[header.identity] = currentHeadingIndex }
                    previousHeadingID = header.identity
                }
            }
            assignAnchors(&headings)
            var headingRanges: [Int: NSRange] = [:]
            var pendingNavigationLinks: [(range: NSRange, headingIndex: Int)] = []
            var mathExpressions: [MarkdownMathExpression] = []
            /// Adds a styled prefix span and advances the shared UTF-16 output offset.
            func prefix(_ text: String, code: Bool = false, secondary: Bool = false) throws {
                guard !text.isEmpty else { return }
                let location = length
                try append(text)
                styles.append(.init(range: NSRange(location: location, length: text.utf16.count), headingLevel: nil,
                                    bold: false, italic: false, strikethrough: false, code: code, quote: secondary, syntax: nil, tableCell: false))
            }
            if let frontMatter {
                switch options.frontMatter {
                case .hide: break
                case .show, .metadata:
                    /// Summarizes nested front matter with independent depth, member, and string bounds.
                    func summary(_ value: StructuredValue, depth: Int = 0) -> String {
                        guard depth < 3 else { return "…" }
                        switch value {
                        case .string(let text), .number(let text): return String(text.prefix(256))
                        case .boolean(let value): return value ? "true" : "false"
                        case .null: return "null"
                        case .array(let values): return values.prefix(12).map { summary($0, depth: depth + 1) }.joined(separator: ", ")
                        case .object(let members): return members.prefix(12).map { $0.key + ": " + summary($0.value, depth: depth + 1) }.joined(separator: ", ")
                        }
                    }
                    let metadata: String
                    if case .object(let members) = frontMatter.value {
                        metadata = members.prefix(16).map { String($0.key.prefix(80)) + "    " + summary($0.value) }.joined(separator: "\n")
                    } else { metadata = summary(frontMatter.value) }
                    try prefix(metadata, secondary: true)

                }
            }
            if options.tableOfContents, !headings.isEmpty {
                var contents = "Contents\n"
                let base = headings.map(\.level).min() ?? 1
                var tocLinks: [(range: NSRange, headingIndex: Int)] = []
                for (headingIndex, heading) in headings.enumerated() {
                    try checkpoint()
                    contents += String(repeating: "  ", count: max(0, heading.level - base)) + "• "
                    let titleStart = contents.utf16.count
                    contents += heading.title
                    tocLinks.append((.init(location: titleStart, length: heading.title.utf16.count), headingIndex))
                    contents += "\n"
                }
                if !output.isEmpty { try append("\n\n") }
                let tocStart = length
                try prefix(contents.trimmingCharacters(in: .newlines))
                pendingNavigationLinks.append(contentsOf: tocLinks.map {
                    (.init(location: tocStart + $0.range.location, length: $0.range.length), $0.headingIndex)
                })
            }
            let bodyStart = length
            for run in parsed.runs {
                try checkpoint()
                guard styles.count < 8_192 else { throw MarkdownLimit.exceeded }
                let components = run.presentationIntent?.components ?? []
                // Only a sole thematic-break component is top-level. Quote/list container intents
                // include blockQuote, listItem, orderedList, or unorderedList and keep their path.
                if components.count == 1, case .thematicBreak = components[0].kind { continue }
                let block = components.first?.identity
                var heading: Int?
                var headingIdentity: Int?
                var innerList: Int?
                var outerList: Int?
                var listDepth = 0
                var item: Int?
                var ordinal: Int?
                var ordered = false
                var row: Int?
                var cell = false
                var tableHeader = false
                var tableID: Int?
                var columnCount = 0
                var column = 0
                var rowNumber = 0
                var quote = false
                var quoteDepth = 0
                var quoteInsideItem = false
                var code = false
                var language: SourceLanguage?
                var mermaidIdentity: Int?
                for component in components {
                    switch component.kind {
                    case .header(let level): heading = level; headingIdentity = component.identity
                    // Components run innermost first: the first list and item found own the marker.
                    case .orderedList, .unorderedList:
                        if innerList == nil {
                            innerList = component.identity
                            if case .orderedList = component.kind { ordered = true }
                        }
                        outerList = component.identity; listDepth += 1
                    case .listItem(let number):
                        if item == nil { item = component.identity; ordinal = number }
                    case .blockQuote:
                        if !quote { quoteInsideItem = item == nil && components.contains { if case .listItem = $0.kind { true } else { false } } }
                        quote = true; quoteDepth += 1
                    case .codeBlock(let hint):
                        code = true
                        language = sourceLanguage(hint)
                        if components.count == 1, hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" {
                            mermaidIdentity = component.identity
                        }
                    case .tableHeaderRow: row = component.identity; tableHeader = true
                    case .tableRow(let number): row = component.identity; rowNumber = number
                    case .tableCell(let number): cell = true; column = number
                    case .table(let columns): tableID = component.identity; columnCount = columns.count
                    default: break
                    }
                }
                var text = String(parsed[run.range].characters)
                if heading != nil { text = headingAnchor(text, marked: placeholdersMarked).text }
                let topQuote: Int? = components.last.flatMap { if case .blockQuote = $0.kind { $0.identity } else { nil } }
                var alertIndex = topQuote.flatMap { alertQuotes[$0] }
                var alertTitle: MarkdownAlertKind?
                var customAlertTitle: String?
                if block != previousBlock, let topQuote, seenQuotes.insert(topQuote).inserted, placeholdersMarked,
                   components.count == 2, let first = text.unicodeScalars.first, case .alert(let kind)? = placeholder(first) {
                    alertTitle = kind
                    text = String(text.unicodeScalars.dropFirst())
                    if text.unicodeScalars.first == admonitionTitleMarker {
                        customAlertTitle = String(text.unicodeScalars.dropFirst())
                        text = ""
                    }
                }
                // Alert content is body text: only quotes nested inside the alert keep quote styling.
                if alertIndex != nil || alertTitle != nil { quote = quoteDepth > 1 }
                if block != previousBlock {
                    activeDefinition = nil
                    if !output.isEmpty {
                        if cell && row == previousRow { try append("\t") }
                        else if cell || (outerList != nil && outerList == previousOuterList) { try append("\n") }
                        else if alertIndex != nil && previousBlock == alertTitleBlock { try append("\n") }
                        else { try append("\n\n") }
                    }
                    if let alertTitle {
                        guard alerts.count < 256 else { throw MarkdownLimit.exceeded }
                        let location = length
                        try append(customAlertTitle ?? alertTitle.title)
                        styles.append(.init(range: .init(location: location, length: length - location), headingLevel: nil,
                                            bold: true, italic: false, strikethrough: false, code: false, quote: false,
                                            syntax: nil, tableCell: false, alert: alertTitle))
                        alertIndex = alerts.count
                        alertQuotes[topQuote ?? 0] = alerts.count
                        alerts.append(.init(range: .init(location: location, length: 0), kind: alertTitle,
                                            title: customAlertTitle))
                        alertTitleBlock = block
                        alertBreakPending = true
                    }
                    if quote && !quoteInsideItem { try append("> ") }
                    openListParagraph = nil
                    if let item, let ordinal {
                        guard listParagraphs.count < 8_192 else { throw MarkdownLimit.exceeded }
                        let markerStart = length
                        var task: MarkdownTaskState?
                        var markerLength = 0
                        if markedItems.insert(item).inserted {
                            if placeholdersMarked, let first = text.unicodeScalars.first, case .task(let state)? = placeholder(first) {
                                task = state
                                text = (state == .done ? "☑" : "☐") + String(text.unicodeScalars.dropFirst())
                                if ordered { try append("\(ordinal). ") }
                                markerLength = 2
                            } else { try append(ordered ? "\(ordinal). " : "• ") }
                            if quote && quoteInsideItem { try append("> ") }
                            markerLength += length - markerStart
                        } else if quote && quoteInsideItem { try append("> ") }
                        openListParagraph = listParagraphs.count
                        listParagraphs.append(.init(range: .init(location: markerStart, length: 0), depth: listDepth,
                                                    markerLength: markerLength, task: task))
                    }
                }
                let inline = run.inlinePresentationIntent ?? []
                let isCode = code || inline.contains(.code)
                if block != previousBlock { inlineMarks = InlineMarks() }
                var startsDefinition: (occurrence: Int, term: Bool)?
                if let first = text.unicodeScalars.first,
                   first == definitionTermMarker || first == definitionBodyMarker {
                    let isTerm = first == definitionTermMarker
                    if definitionCursor < definitionPass.occurrences.count {
                        let occurrence = definitionCursor
                        let metadata = definitionPass.occurrences[occurrence]
                        if metadata.term == isTerm {
                            definitionCursor += 1
                            let groupIndex = occurrenceGroups[occurrence]
                            if groupIndex >= 0 && !invalidDefinitionGroups.contains(groupIndex) && validDefinitionOccurrences[occurrence] {
                                startsDefinition = (occurrence, isTerm)
                                text = String(text.unicodeScalars.dropFirst())
                            } else {
                                text = metadata.restore + String(text.unicodeScalars.dropFirst())
                            }
                        } else {
                            text = metadata.restore + String(text.unicodeScalars.dropFirst())
                            definitionCursor += 1
                        }
                    }
                }
                // Parser-only end markers are structural and never reach Rendered text. A source
                // collision disables the pre-pass, so preserve any matching user scalar then.
                if !definitionPass.occurrences.isEmpty {
                    text = text.replacingOccurrences(of: String(Character(definitionParagraphEndMarker)), with: "")
                }
                text = restorePlaceholders(text, marked: placeholdersMarked, keepingInlineMarkers: !isCode)
                let restoredMath = mathPass.restore(text)
                text = restoredMath.text
                if alertBreakPending && block == alertTitleBlock && alertTitle == nil {
                    alertBreakPending = false
                    if inline.contains(.softBreak) { text = "\n" }
                }
                if options.breakBehavior == .preserveSoftLines, inline.contains(.softBreak) { text = "\n" }
                var references: [NSRange] = []
                if !footnotes.definitions.isEmpty, !code, !inline.contains(.code) {
                    (text, references) = numberFootnoteReferences(in: text, definitions: footnotes.definitions,
                                                                  numbers: &footnoteNumbers, order: &footnoteOrder)
                }
                var segments: [(range: NSRange, marks: InlineMarks)] = []
                if placeholdersMarked, !isCode {
                    (text, segments) = splitInlineMarks(text, marks: &inlineMarks, references: &references)
                } else { segments = [(NSRange(location: 0, length: text.utf16.count), InlineMarks())] }
                let location = length
                try append(text)
                if let mermaidIdentity, !text.isEmpty {
                    if var accumulator = mermaidAccumulators[mermaidIdentity] {
                        accumulator.end = length
                        if !accumulator.isOversized {
                            if accumulator.source.utf8.count <= MermaidFlowchartParser.maximumSourceBytes - text.utf8.count {
                                accumulator.source += text
                            } else {
                                accumulator.source = ""
                                accumulator.isOversized = true
                            }
                        }
                        mermaidAccumulators[mermaidIdentity] = accumulator
                    } else if mermaidOrder.count < 16 {
                        mermaidOrder.append(mermaidIdentity)
                        mermaidAccumulators[mermaidIdentity] = .init(identity: mermaidIdentity, start: location,
                                                                      end: length,
                                                                      source: text.utf8.count <= MermaidFlowchartParser.maximumSourceBytes ? text : "",
                                                                      isOversized: text.utf8.count > MermaidFlowchartParser.maximumSourceBytes)
                    }
                }
                if !isCode {
                    for item in restoredMath.expressions {
                        mathExpressions.append(.init(
                            range: NSRange(location: location + item.range.location, length: item.range.length),
                            latex: item.entry.latex, mode: item.entry.mode, fallbackText: item.entry.fallbackText
                        ))
                    }
                }
                if let headingIdentity, let headingIndex = headingIndices[headingIdentity] {
                    var range = headingRanges[headingIndex] ?? .init(location: location, length: 0)
                    range.length = length - range.location
                    headingRanges[headingIndex] = range
                }
                if let anchor = localFragmentAnchor(run.link), !code, !text.isEmpty,
                   let headingIndex = headings.firstIndex(where: { $0.anchor == anchor }) {
                    pendingNavigationLinks.append((.init(location: location, length: text.utf16.count), headingIndex))
                }
                if let startsDefinition {
                    activeDefinition = (startsDefinition.occurrence, startsDefinition.term, block)
                    definitionRanges[startsDefinition.occurrence] = NSRange(location: location, length: text.utf16.count)
                } else if let activeDefinition, activeDefinition.block == block,
                          var range = definitionRanges[activeDefinition.occurrence] {
                    range.length = length - range.location
                    definitionRanges[activeDefinition.occurrence] = range
                }
                if let index = openListParagraph {
                    let paragraph = listParagraphs[index]
                    listParagraphs[index] = .init(range: .init(location: paragraph.range.location, length: length - paragraph.range.location),
                                                  depth: paragraph.depth, markerLength: paragraph.markerLength, task: paragraph.task)
                }
                if let alertIndex {
                    let alert = alerts[alertIndex]
                        alerts[alertIndex] = .init(range: .init(location: alert.range.location, length: length - alert.range.location),
                                                   kind: alert.kind, title: alert.title)
                }
                if cell, let tableID {
                    guard columnCount > 0, columnCount <= 64, column < columnCount, rowNumber < 1_024 else { throw MarkdownLimit.exceeded }
                    let index: Int
                    if let existing = tableIndices[tableID] { index = existing }
                    else {
                        guard tableBuilders.count < 64 else { throw MarkdownLimit.exceeded }
                        index = tableBuilders.count; tableIndices[tableID] = index
                        tableBuilders.append(.init(columnCount: columnCount))
                    }
                    tableBuilders[index].append(range: NSRange(location: location, length: text.utf16.count), row: rowNumber, column: column)
                }
                for segment in segments where segment.range.length > 0 {
                    styles.append(.init(range: .init(location: location + segment.range.location, length: segment.range.length),
                                        headingLevel: heading, bold: inline.contains(.stronglyEmphasized) || tableHeader || (activeDefinition?.term == true),
                                        italic: inline.contains(.emphasized), strikethrough: options.strikethrough && inline.contains(.strikethrough),
                                        code: isCode, quote: quote, syntax: nil, tableCell: cell, highlight: segment.marks.highlight,
                                        isSuperscript: segment.marks.superscript, isSubscript: segment.marks.lowered,
                                        hashtag: segment.marks.hashtag && heading == nil && run.link == nil))
                }
                for reference in references {
                    styles.append(.init(range: .init(location: location + reference.location, length: reference.length),
                                        headingLevel: nil, bold: false, italic: false, strikethrough: false, code: false,
                                        quote: false, syntax: nil, tableCell: cell, footnote: .reference))
                }
                if code, let language {
                    // Unsupported contextual syntax stays readable monospace; no commands are run.
                    do {
                        let highlighted = try InternalSyntaxHighlighter().highlight(text, language: language)
                        guard highlighted.runs.count <= 8_192 - styles.count else { throw MarkdownLimit.exceeded }
                        for token in highlighted.runs {
                            styles.append(.init(range: .init(location: location + token.range.location, length: token.range.length),
                                                headingLevel: nil, bold: false, italic: false, strikethrough: false,
                                                code: true, quote: false, syntax: token.kind, tableCell: false))
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch is MarkdownLimit { throw MarkdownLimit.exceeded }
                    catch { /* Keep the already rendered code block plain when tokenization fails. */ }
                }
                previousBlock = block
                previousOuterList = outerList
                previousRow = row
            }
            let expandedCells = tableBuilders.reduce(0) { total, table in
                total + ((table.cells.map(\.row).max() ?? 0) + 1) * table.columnCount
            }
            guard expandedCells <= 8_192 else { throw MarkdownLimit.exceeded }
            if !footnoteOrder.isEmpty {
                /// Emits a footnote span while retaining its inline emphasis and code styling.
                func definitionText(_ text: String, bold: Bool = false, italic: Bool = false,
                                    strikethrough: Bool = false, code: Bool = false) throws {
                    guard !text.isEmpty else { return }
                    let location = length
                    try append(text)
                    styles.append(.init(range: .init(location: location, length: text.utf16.count), headingLevel: nil,
                                        bold: bold, italic: italic, strikethrough: strikethrough, code: code, quote: false,
                                        syntax: nil, tableCell: false, footnote: .definition))
                }
                if !output.isEmpty { try append("\n\n") }
                try definitionText("Footnotes", bold: true)
                for (index, label) in footnoteOrder.enumerated() {
                    try checkpoint()
                    guard styles.count < 8_192, let definition = footnotes.definitions[label] else { throw MarkdownLimit.exceeded }
                    try append("\n")
                    try definitionText("[\(index + 1)] ")
                    let inline = try AttributedString(markdown: definition, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                    for run in inline.runs {
                        let intent = run.inlinePresentationIntent ?? []
                        try definitionText(String(inline[run.range].characters), bold: intent.contains(.stronglyEmphasized),
                                           italic: intent.contains(.emphasized),
                                           strikethrough: options.strikethrough && intent.contains(.strikethrough),
                                           code: intent.contains(.code))
                    }
                }
            }
            try checkpoint()
            for (index, range) in headingRanges { headings[index].range = range }
            var definitionLists: [MarkdownDefinitionList] = []
            for (groupIndex, group) in definitionPass.groups.enumerated() {
                try checkpoint()
                guard !invalidDefinitionGroups.contains(groupIndex) else { continue }
                guard let term = definitionRanges[group.termOccurrence], term.length > 0 else { continue }
                let definitions = group.definitionOccurrences.compactMap { definitionRanges[$0] }.filter { $0.length > 0 }
                guard definitions.count == group.definitionOccurrences.count else { continue }
                definitionLists.append(.init(termRange: term, definitionRanges: definitions))
            }
            let navigationLinks = pendingNavigationLinks.compactMap { item -> MarkdownNavigationLink? in
                guard headings.indices.contains(item.headingIndex) else { return nil }
                let heading = headings[item.headingIndex]
                guard heading.range.length > 0 else { return nil }
                return .init(range: item.range, targetRange: heading.range, headingIndex: item.headingIndex, anchor: heading.anchor)
            }
            var mermaidBlocks: [MarkdownMermaidBlock] = []
            for identity in mermaidOrder {
                try checkpoint()
                guard let accumulator = mermaidAccumulators[identity] else { continue }
                if accumulator.isOversized {
                    mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: .resourceLimit))
                    continue
                }
                let firstStatement = accumulator.source.split(whereSeparator: \.isNewline)
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                    .trimmingCharacters(in: .whitespaces)
                if firstStatement == "sequenceDiagram" {
                    let parsedSequence = try MermaidSequenceParser.parse(accumulator.source, checkpoint: checkpoint)
                    switch parsedSequence {
                    case .failure(let diagnostic):
                        mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                    case .success(let sequenceDiagram):
                        let sequenceLayout = try MermaidSequenceLayoutEngine.layout(sequenceDiagram, checkpoint: checkpoint)
                        switch sequenceLayout {
                        case .success(let layout):
                            mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil,
                                                       diagnostic: nil, sequenceDiagram: sequenceDiagram, sequenceLayout: layout))
                        case .failure(let diagnostic):
                            mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                        }
                    }
                    continue
                }
                if firstStatement == "classDiagram" {
                    let parsed = try MermaidClassParser.parse(accumulator.source, checkpoint: checkpoint)
                    switch parsed {
                    case .failure(let diagnostic):
                        mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                    case .success(let diagram):
                        let laidOut = try MermaidClassLayoutEngine.layout(diagram, checkpoint: checkpoint)
                        switch laidOut {
                        case .success(let layout): mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: nil, classDiagram: diagram, classLayout: layout))
                        case .failure(let diagnostic): mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                        }
                    }
                    continue
                }
                if firstStatement == "stateDiagram" || firstStatement == "stateDiagram-v2" {
                    let parsed = try MermaidStateParser.parse(accumulator.source, checkpoint: checkpoint)
                    switch parsed {
                    case .failure(let diagnostic): mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                    case .success(let diagram):
                        let laidOut = try MermaidFlowchartLayoutEngine.layout(diagram, checkpoint: checkpoint)
                        switch laidOut {
                        case .success(let layout): mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: layout, diagnostic: nil, stateDiagram: diagram))
                        case .failure(let diagnostic): mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                        }
                    }
                    continue
                }
                let parsedDiagram = try MermaidFlowchartParser.parse(accumulator.source, checkpoint: checkpoint)
                switch parsedDiagram {
                case .failure(let diagnostic):
                    mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                case .success(let flowchart):
                    let diagramLayout = try MermaidFlowchartLayoutEngine.layout(flowchart, checkpoint: checkpoint)
                    switch diagramLayout {
                    case .success(let layout):
                        mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: flowchart, layout: layout, diagnostic: nil))
                    case .failure(let diagnostic):
                        mermaidBlocks.append(.init(range: accumulator.range, source: accumulator.source, flowchart: nil, layout: nil, diagnostic: diagnostic))
                    }
                }
            }
            let images = MarkdownLocalImages.references(in: analysis.text, renderedText: output, bodyStart: bodyStart,
                                                        checkpoint: checkpoint)
            return .init(raw: analysis.text, renderedText: output, runs: styles, diagnostics: [], headings: headings, frontMatter: frontMatter?.value, tables: tableBuilders.map { .init(columnCount: $0.columnCount, cells: $0.cells) },
                         listParagraphs: listParagraphs, alerts: alerts, definitionLists: definitionLists,
                         navigationLinks: navigationLinks, images: images, mathExpressions: mathExpressions,
                         mermaidBlocks: mermaidBlocks)
        } catch is CancellationError { throw CancellationError() }
        catch MarkdownFrontMatterError.invalid { return fallback(.parseError, "YAML front matter is invalid. Raw remains available.") }
        catch is MarkdownLimit { return fallback(.limitExceeded, "Markdown rendering limit reached. Raw remains available.") }
        catch { return fallback(.parseError, "Markdown rendering unavailable. Raw remains available.") }
    }

    // MARK: Task and alert placeholders

    private static let definitionTermMarker: Unicode.Scalar = "\u{E018}"
    private static let definitionBodyMarker: Unicode.Scalar = "\u{E019}"
    private static let definitionParagraphEndMarker: Unicode.Scalar = "\u{E01A}"

    /// Maps one protected definition-list marker back to its original source text.
    private struct DefinitionOccurrence {
        let term: Bool
        let restore: String
    }

    /// Associates a term marker with the definition markers belonging to it.
    private struct DefinitionGroup {
        let termOccurrence: Int
        let definitionOccurrences: [Int]
    }

    /// Carries marked Markdown plus the occurrence and grouping maps for restoration.
    private struct DefinitionPass {
        let text: String
        let occurrences: [DefinitionOccurrence]
        let groups: [DefinitionGroup]
    }

    /// Shared conservative block-context scan for the line-based Markdown extensions.
    /// Marks fenced and indented code so later extension passes cannot reinterpret code as Markdown syntax.
    private static func protectedMarkdownLines(_ clean: [String], checkpoint: () throws -> Void) throws -> [Bool] {
        var protected = Array(repeating: false, count: clean.count)
        var fence: (Character, Int)?
        var htmlBlock = false
        for index in clean.indices {
            try checkpoint()
            let line = clean[index]
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if let open = fence {
                protected[index] = true
                if indent <= 3, trimmed.first == open.0,
                   trimmed.prefix(while: { $0 == open.0 }).count >= open.1,
                   trimmed.drop(while: { $0 == open.0 }).allSatisfy(\.isWhitespace) { fence = nil }
                continue
            }
            if htmlBlock {
                protected[index] = true
                if line.trimmingCharacters(in: .whitespaces).isEmpty { htmlBlock = false }
                continue
            }
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix(while: { $0 == marker }).count
                if count >= 3 { fence = (marker, count); protected[index] = true; continue }
            }
            if indent == 0, line.hasPrefix("<") { htmlBlock = true; protected[index] = true; continue }
            if indent > 0 || line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("*") ||
                line.range(of: #"^[0-9]{1,9}[.)][ \t]+"#, options: .regularExpression) != nil ||
                line.range(of: #"^ {0,3}#{1,6}(?:[ \t]|$)"#, options: .regularExpression) != nil ||
                line.range(of: #"^ {0,3}(?:[-*_][ \t]*){3,}$"#, options: .regularExpression) != nil ||
                line.range(of: #"^\[[^]]+\]:"#, options: .regularExpression) != nil || footnoteLabel(line[...]) != nil {
                protected[index] = true
            }
            // A table header and its separator are both protected even when a cell has no leading pipe.
            if index + 1 < clean.count, clean[index + 1].range(of: #"^\s*\|?\s*:?-{3,}"#, options: .regularExpression) != nil {
                protected[index] = true; protected[index + 1] = true
            }
        }
        return protected
    }

    /// Translates only complete, unambiguous top-level admonitions into existing GitHub alerts.
    /// Temporarily marks supported quote alerts while preserving exact source when markers collide.
    private static func markAdmonitions(_ text: String, sourceHasPlaceholderCollision: Bool,
                                        checkpoint: () throws -> Void) throws -> String {
        guard !sourceHasPlaceholderCollision, text.contains("!!!") else { return text }
        let lines = text.components(separatedBy: "\n")
        let clean = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var protected = try protectedMarkdownLines(clean, checkpoint: checkpoint)
        var lazyContainer = false
        for index in clean.indices {
            try checkpoint()
            let line = clean[index]
            if line.allSatisfy(\.isWhitespace) {
                lazyContainer = false
                continue
            }
            if lazyContainer { protected[index] = true }
            if line.range(of: #"^ {0,3}>"#, options: .regularExpression) != nil ||
                line.range(of: #"^(?: {0,3}(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)"#, options: .regularExpression) != nil {
                protected[index] = true
                lazyContainer = true
            }
        }

        /// Treats indentation-only lines as blank during block-boundary analysis.
        func blank(_ index: Int) -> Bool { clean[index].allSatisfy(\.isWhitespace) }
        let openerPattern = try NSRegularExpression(pattern: #"^!!![ \t]+(note|tip|important|warning|caution)(?:[ \t]+"([^"\n]{1,256})")?[ \t]*$"#)
        /// Parses only supported alert kinds and rejects unsafe or overlong custom titles.
        func admonition(_ line: String) -> (kind: MarkdownAlertKind, title: String?)? {
            guard let match = openerPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let kindRange = Range(match.range(at: 1), in: line),
                  let kind = MarkdownAlertKind(rawValue: String(line[kindRange])) else { return nil }
            if match.range(at: 2).location == NSNotFound { return (kind, nil) }
            guard let titleRange = Range(match.range(at: 2), in: line) else { return nil }
            let title = String(line[titleRange])
            guard !title.isEmpty, title.unicodeScalars.count <= 80,
                  !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return (kind, title)
        }
        /// Counts leading spaces used by indentation-sensitive block rules.
        func indentation(_ line: String) -> Int {
            line.prefix(while: { $0 == " " }).count
        }
        /// Recognizes table delimiter rows before rewriting adjacent pipe-separated content.
        func tableSeparator(_ line: String) -> Bool {
            line.range(of: #"^\s*\|?\s*:?-{3,}(?:\s*\|\s*:?-{3,})*\s*\|?\s*$"#, options: .regularExpression) != nil
        }
        /// Identifies Setext heading underlines so extension markers do not cross the block boundary.
        func setextUnderline(_ line: String) -> Bool {
            line.range(of: #"^ {0,3}(?:=+|-+)[ \t]*$"#, options: .regularExpression) != nil
        }
        /// Detects block starts that make an admonition's lazy continuation unsafe to absorb.
        func unsafeBoundary(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            return indent <= 3 && (trimmed.hasPrefix("!!!") || trimmed.hasPrefix(":") ||
                startsBlock(line, admonition: true) || tableSeparator(line) || setextUnderline(line))
        }
        /// Detects constructs that can follow a blank line and must remain outside an alert body.
        func unsafeAfterBlank(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            return indent <= 3 && (trimmed.hasPrefix("!!!") || trimmed.hasPrefix(":") ||
                line.range(of: #"^ {0,3}\\?\[[^]]+\]:"#, options: .regularExpression) != nil ||
                tableSeparator(line) || setextUnderline(line))
        }

        var replacements: [Int: String] = [:]
        var consumed: Set<Int> = []
        var generatedCount = 0
        var index = 0
        while index < clean.count {
            try checkpoint()
            guard !protected[index], (index == 0 || blank(index - 1)),
                  let parsedOpener = admonition(clean[index]) else { index += 1; continue }
            var cursor = index + 1
            var body: [String] = []
            var internalBlanks: [Int] = []
            var bodyLineIndices: [Int] = []
            var rejected = false
            var needsQuoteBoundary = false
            while cursor < clean.count {
                try checkpoint()
                let line = clean[cursor]
                if line.allSatisfy(\.isWhitespace) {
                    // The grammar requires a body line immediately after the opener. Blank
                    // lines are permitted only between two otherwise valid body lines.
                    if body.isEmpty { rejected = true; break }
                    internalBlanks.append(cursor)
                    cursor += 1
                    continue
                }
                let spaces = indentation(line)
                let isTabIndented = line.first == "\t"
                if spaces == 4, line.count > 4, let fifth = line.dropFirst(4).first, !fifth.isWhitespace {
                    let content = String(line.dropFirst(4))
                    if startsBlock(content, admonition: true) || content.hasPrefix(":") || tableSeparator(content) {
                        rejected = true
                    }
                    if !internalBlanks.isEmpty {
                        body.append(contentsOf: internalBlanks.map { _ in "" })
                        bodyLineIndices.append(contentsOf: internalBlanks)
                        internalBlanks.removeAll(keepingCapacity: true)
                    }
                    body.append(content)
                    bodyLineIndices.append(cursor)
                    cursor += 1
                    if rejected { break }
                    continue
                }
                if spaces > 0 || isTabIndented {
                    // Indentation inside the candidate is all-or-nothing; it cannot form a nested block.
                    rejected = true
                    break
                }
                let isFollowingAdmonition = !internalBlanks.isEmpty && admonition(line) != nil
                if !internalBlanks.isEmpty {
                    if unsafeAfterBlank(line) && !isFollowingAdmonition { rejected = true }
                } else if unsafeBoundary(line) { rejected = true }
                else if internalBlanks.isEmpty { needsQuoteBoundary = true }
                break
            }
            if body.isEmpty { rejected = true }
            if !rejected {
                for bodyIndex in body.indices where !body[bodyIndex].isEmpty {
                    if bodyIndex + 1 < body.count, tableSeparator(body[bodyIndex + 1]) { rejected = true; break }
                    if bodyIndex > 0, tableSeparator(body[bodyIndex]) { rejected = true; break }
                }
            }
            if !rejected {
                generatedCount += 1
                guard generatedCount <= 256 else { throw MarkdownLimit.exceeded }
                let titleSuffix = parsedOpener.title.map { String(Character(admonitionTitleMarker)) + $0 } ?? ""
                var translated = ["> [!\(parsedOpener.kind.rawValue.uppercased())]\(titleSuffix)"]
                var hasBlank = false
                for line in body {
                    if line.isEmpty {
                        translated.append(hasBlank ? "> " : ">")
                        hasBlank = true
                    } else {
                        translated.append("> " + line)
                        hasBlank = false
                    }
                }
                replacements[index] = translated.joined(separator: "\n") + (needsQuoteBoundary ? "\n" : "")
                consumed.insert(index)
                consumed.formUnion(bodyLineIndices)
                index = max(index + 1, (bodyLineIndices.max() ?? index) + 1)
            } else { index += 1 }
        }
        guard !replacements.isEmpty else { return text }
        var translated: [String] = []
        translated.reserveCapacity(lines.count)
        for lineIndex in lines.indices {
            try checkpoint()
            if let replacement = replacements[lineIndex] { translated.append(replacement) }
            else if !consumed.contains(lineIndex) { translated.append(lines[lineIndex]) }
        }
        return translated.joined(separator: "\n")
    }

    /// Recognizes only bounded, top-level term/definition paragraphs from the original body.
    /// Protects candidate definition-list markers, then validates them against Foundation's parsed structure.
    private static func markDefinitionLists(_ text: String, checkpoint: () throws -> Void) throws -> DefinitionPass {
        if text.unicodeScalars.contains(where: { placeholderScalars.contains($0.value) }) {
            return .init(text: text, occurrences: [], groups: [])
        }
        let lines = text.components(separatedBy: "\n")
        let clean = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let protected = try protectedMarkdownLines(clean, checkpoint: checkpoint)
        var fenced = Array(repeating: false, count: clean.count)
        var fence: (marker: Character, count: Int)?
        for lineIndex in clean.indices {
            try checkpoint()
            let line = clean[lineIndex]
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            if let open = fence {
                fenced[lineIndex] = true
                if indent <= 3, trimmed.prefix(while: { $0 == open.marker }).count >= open.count,
                   trimmed.drop(while: { $0 == open.marker }).allSatisfy(\.isWhitespace) { fence = nil }
            } else if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~",
                      trimmed.prefix(while: { $0 == marker }).count >= 3 {
                fence = (marker, trimmed.prefix(while: { $0 == marker }).count)
                fenced[lineIndex] = true
            }
        }
        /// Treats whitespace-only lines as separators between definition-list items.
        func blank(_ index: Int) -> Bool { clean[index].allSatisfy(\.isWhitespace) }
        /// Parses one indented definition body while rejecting content that starts another block.
        func definitionContent(_ line: String) -> (String, String)? {
            guard line.first == ":" else { return nil }
            let separator = line.dropFirst().prefix(while: { $0 == " " || $0 == "\t" })
            guard !separator.isEmpty else { return nil }
            let content = String(line.dropFirst(1 + separator.count))
            guard content.first.map({ !$0.isWhitespace }) == true,
                  !startsBlock(content) else { return nil }
            return (String(separator), content)
        }
        var replacements: [Int: String] = [:]
        var consumedContinuationLines: Set<Int> = []
        var occurrences: [DefinitionOccurrence] = []
        var groups: [DefinitionGroup] = []
        var definitionsCount = 0
        var stopped = false
        var index = 0
        while index < clean.count {
            try checkpoint()
            guard !stopped, !protected[index], !clean[index].isEmpty,
                  clean[index].first.map({ !$0.isWhitespace }) == true,
                  (index == 0 || blank(index - 1)), index + 1 < clean.count,
                  let first = definitionContent(clean[index + 1]), !protected[index + 1] else { index += 1; continue }
            var definitions: [(line: Int, separator: String, content: String)] = [(index + 1, first.0, first.1)]
            var groupContinuationLines: Set<Int> = []
            var cursor = index + 2
            while cursor < clean.count {
                try checkpoint()
                if !protected[cursor], let parsed = definitionContent(clean[cursor]) {
                    definitions.append((cursor, parsed.0, parsed.1))
                    cursor += 1
                    continue
                }
                let line = clean[cursor]
                let indent = line.prefix(while: { $0 == " " }).count
                guard !blank(cursor), !fenced[cursor], (2...3).contains(indent),
                      line.dropFirst(indent).first.map({ !$0.isWhitespace }) == true else { break }
                let continuation = String(line.dropFirst(indent))
                guard !startsBlock(continuation) else { break }
                definitions[definitions.count - 1].content += "\n" + continuation
                groupContinuationLines.insert(cursor)
                cursor += 1
            }
            guard !definitions.isEmpty else { index += 1; continue }
            if groups.count >= 256 || definitionsCount + definitions.count > 1_024 {
                stopped = true; index = cursor; continue
            }
            consumedContinuationLines.formUnion(groupContinuationLines)
            let termOccurrence = occurrences.count
            occurrences.append(.init(term: true, restore: ""))
            replacements[index] = String(Character(definitionTermMarker)) + clean[index]
            var definitionOccurrences: [Int] = []
            for definition in definitions {
                let occurrence = occurrences.count
                occurrences.append(.init(term: false, restore: ":" + definition.separator))
                replacements[definition.line] = String(Character(definitionBodyMarker)) + definition.content + String(Character(definitionParagraphEndMarker))
                definitionOccurrences.append(occurrence)
            }
            groups.append(.init(termOccurrence: termOccurrence, definitionOccurrences: definitionOccurrences))
            definitionsCount += definitions.count
            index = cursor
        }
        guard !replacements.isEmpty else { return .init(text: text, occurrences: [], groups: []) }
        var markedLines: [String] = []
        for lineIndex in lines.indices {
            try checkpoint()
            if let replacement = replacements[lineIndex] {
                markedLines.append(replacement)
                markedLines.append("")
            } else if !consumedContinuationLines.contains(lineIndex) { markedLines.append(lines[lineIndex]) }
        }
        return .init(text: markedLines.joined(separator: "\n"), occurrences: occurrences, groups: groups)
    }

    /// Identifies block-level boundaries that prevent a definition term from absorbing following content.
    private static func startsBlock(_ text: String, admonition: Bool = false) -> Bool {
        let patterns = [#"^ {0,3}#{1,6}(?:[ \t]|$)"#, #"^(?:[-+*]|[0-9]{1,9}[.)])[ \t]+"#,
                       #"^ {0,3}>"#, #"^ {0,3}(?:`{3,}|~{3,})"#, #"^\s*\|"#,
                       #"^ {0,3}<"#, #"^ {0,3}(?:[-*_][ \t]*){3,}$"#, #"^\[[^]]+\]:"#]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }
        guard admonition else { return false }
        return text.hasPrefix(":") || text.hasPrefix("!!!") ||
            text.range(of: #"^ {0,3}=+[ \t]*$"#, options: .regularExpression) != nil ||
            text.range(of: #"^\s*\|?\s*:?-{3,}(?:\s*\|\s*:?-{3,})*\s*\|?\s*$"#, options: .regularExpression) != nil
    }

    /// Meaning associated with each private-use marker during Foundation Markdown parsing.
    private enum Placeholder { case task(MarkdownTaskState), alert(MarkdownAlertKind), emoji(String) }

    private static let placeholders: [(scalar: Unicode.Scalar, marker: String, meaning: Placeholder)] = [
        ("\u{E000}", "[ ]", .task(.open)), ("\u{E001}", "[x]", .task(.done)), ("\u{E002}", "[X]", .task(.done)),
        ("\u{E003}", "[!NOTE]", .alert(.note)), ("\u{E004}", "[!TIP]", .alert(.tip)),
        ("\u{E005}", "[!IMPORTANT]", .alert(.important)), ("\u{E006}", "[!WARNING]", .alert(.warning)),
        ("\u{E007}", "[!CAUTION]", .alert(.caution)),
        ("\u{E01B}", ":smile:", .emoji("😄")), ("\u{E01C}", ":heart:", .emoji("❤️")),
        ("\u{E01D}", ":rocket:", .emoji("🚀")), ("\u{E01E}", ":tada:", .emoji("🎉")),
        ("\u{E01F}", ":warning:", .emoji("⚠️")), ("\u{E020}", ":thumbsup:", .emoji("👍"))
    ]
    private static let anchorOpen: Unicode.Scalar = "\u{E008}"
    private static let anchorClose: Unicode.Scalar = "\u{E009}"
    /// Paired inline markers: open scalar, close scalar, their exact source text and the mark they set.
    private static let inlineMarkers: [(open: Unicode.Scalar, close: Unicode.Scalar, source: (String, String), mark: InlineMarks.Kind)] = [
        ("\u{E00A}", "\u{E00B}", ("==", "=="), .highlight),
        ("\u{E00C}", "\u{E00D}", ("^", "^"), .superscript),
        ("\u{E00E}", "\u{E00F}", ("<sup>", "</sup>"), .superscript),
        ("\u{E010}", "\u{E011}", ("<sub>", "</sub>"), .lowered),
        ("\u{E016}", "\u{E017}", ("", ""), .hashtag)
    ]
    /// Wikilink markers: `[[` (plain), `[[` (labelled: target hidden until the separator), `|`, `]]`.
    private static let wikilinkOpen: Unicode.Scalar = "\u{E012}"
    private static let wikilinkLabelledOpen: Unicode.Scalar = "\u{E013}"
    private static let wikilinkSeparator: Unicode.Scalar = "\u{E014}"
    private static let wikilinkClose: Unicode.Scalar = "\u{E015}"
    private static let wikilinkSources: [Unicode.Scalar: String] = [
        wikilinkOpen: "[[", wikilinkLabelledOpen: "[[", wikilinkSeparator: "|", wikilinkClose: "]]"
    ]
    private static let admonitionTitleMarker: Unicode.Scalar = "\u{E021}"
    private static let placeholderScalars: ClosedRange<UInt32> = 0xE000...0xE021

    /// Marks `[ ]`, `[x]` and `[X]` directly after a list marker (optionally inside quotes) and
    /// before item text, and uppercase alert markers alone on a quote line indented at most three
    /// spaces. A trailing `{#id}` on an ATX heading line becomes `anchorOpen id anchorClose`.
    /// Bundled emoji shortcodes are mapped locally; unknown names stay literal. Sources that already
    /// contain a placeholder scalar are left unmarked.
    /// Replaces supported extension syntax with private-use markers before Foundation normalizes escapes.
    private static func markPlaceholders(_ text: String, tasks: Bool, allowingDefinitionMarkers: Bool = false,
                                         allowingAdmonitionTitleMarker: Bool = false) throws -> String {
        guard !text.unicodeScalars.contains(where: {
            let isDefinitionMarker = (definitionTermMarker.value...definitionParagraphEndMarker.value).contains($0.value)
            let isAdmonitionTitleMarker = $0 == admonitionTitleMarker
            return placeholderScalars.contains($0.value) && !(allowingDefinitionMarkers && isDefinitionMarker)
                && !(allowingAdmonitionTitleMarker && isAdmonitionTitleMarker)
        }) else { return text }
        let titleMarker = NSRegularExpression.escapedPattern(for: String(admonitionTitleMarker))
        var patterns = ["^ {0,3}>[ \\t]?(\\[!(?:NOTE|TIP|IMPORTANT|WARNING|CAUTION)\\])(?:" + titleMarker + "[^\\n]{1,80})?[ \\t]*$"]
        if tasks { patterns.append(#"^(?:[ \t]{0,3}>[ \t]?)*[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(\[[ xX]\])(?=[ \t]+\S)"#) }
        let result = NSMutableString(string: text)
        let whole = NSRange(location: 0, length: result.length)
        let codeSpans = try NSRegularExpression(pattern: #"(`+)[^`\n]*?(?:`(?!\1)[^`\n]*?)*\1(?!`)"#)
            .matches(in: text, range: whole).map(\.range)
        let ranges = try patterns.flatMap { pattern in
            try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines).matches(in: text, range: whole).map { $0.range(at: 1) }
        }
        var replacements: [(NSRange, String)] = ranges.compactMap { range in
            placeholders.first { $0.marker == result.substring(with: range) }.map { (range, String(Character($0.scalar))) }
        }
        let emojiShortcode = #"(?<![\\\w]):(?:smile|heart|rocket|tada|warning|thumbsup):"#
        for match in try NSRegularExpression(pattern: emojiShortcode).matches(in: text, range: whole)
        where !codeSpans.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            && !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
            let shortcode = result.substring(with: match.range)
            if let placeholder = placeholders.first(where: { $0.marker == shortcode }),
               case .emoji = placeholder.meaning {
                replacements.append((match.range, String(Character(placeholder.scalar))))
            }
        }
        let anchor = #"^ {0,3}#{1,6}[ \t]+[^\n]*?[ \t](\{#[A-Za-z][A-Za-z0-9_:.-]{0,63}\})[ \t]*$"#
        for match in try NSRegularExpression(pattern: anchor, options: .anchorsMatchLines).matches(in: text, range: whole) {
            let range = match.range(at: 1)
            let id = result.substring(with: NSRange(location: range.location + 2, length: range.length - 3))
            replacements.append((range, String(Character(anchorOpen)) + id + String(Character(anchorClose))))
        }
        // Inline pairs stay on one line, never contain a backtick or `|`, and are skipped when they touch
        // a code span. Highlight is tight (no whitespace just inside, no longer `=` run, no `==` inside);
        // carets enclose no whitespace, brackets or backslash; tags are lowercase and non-empty.
        // Paired in order with `inlineMarkers`; the trailing hashtag markers are placed separately below.
        let inlinePatterns = [
            #"(?<![=\\])==(?![\s=])(?:(?!==)[^|`\n])*?[^\s=\\|`]==(?!=)"#,
            #"(?<![\\\[^])\^[^\s^\[\]`|\\]+\^"#,
            #"<sup>(?:(?!</?su[pb]>)[^`|\n])+</sup>"#,
            #"<sub>(?:(?!</?su[pb]>)[^`|\n])+</sub>"#
        ]
        for (marker, pattern) in zip(inlineMarkers, inlinePatterns) {
            let (openText, closeText) = marker.source
            for match in try NSRegularExpression(pattern: pattern).matches(in: text, range: whole)
            where !codeSpans.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                && !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
                let open = NSRange(location: match.range.location, length: openText.utf16.count)
                let close = NSRange(location: NSMaxRange(match.range) - closeText.utf16.count, length: closeText.utf16.count)
                replacements.append((open, String(Character(marker.open))))
                replacements.append((close, String(Character(marker.close))))
            }
        }
        // Wikilinks: not escaped or embedded (`![[`), one line, a non-blank target and at most one label.
        var wikilinks: [NSRange] = []
        let wikilink = #"(?<![\\!])\[\[([^\[\]|`\n]*[^\s\[\]|`][^\[\]|`\n]*)(?:(\|)[^\[\]|`\n]*[^\s\[\]|`][^\[\]|`\n]*)?\]\]"#
        for match in try NSRegularExpression(pattern: wikilink).matches(in: text, range: whole)
        where !codeSpans.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            && !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
            wikilinks.append(match.range)
            let labelled = match.range(at: 2).location != NSNotFound
            replacements.append((NSRange(location: match.range.location, length: 2),
                                 String(Character(labelled ? wikilinkLabelledOpen : wikilinkOpen))))
            if labelled { replacements.append((match.range(at: 2), String(Character(wikilinkSeparator)))) }
            replacements.append((NSRange(location: NSMaxRange(match.range) - 2, length: 2), String(Character(wikilinkClose))))
        }
        // Hashtags: a letter after `#`, then letters, digits, `_`, `-` or `/`, ending on a letter, digit or `_`.
        let hashtag = #"(?<!\S)#\p{L}(?:[\p{L}\p{N}_/-]*[\p{L}\p{N}_])?"#
        let (tagOpen, tagClose) = (inlineMarkers[4].open, inlineMarkers[4].close)
        for match in try NSRegularExpression(pattern: hashtag).matches(in: text, range: whole)
        where !(codeSpans + wikilinks).contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            && !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
            replacements.append((NSRange(location: match.range.location, length: 0), String(Character(tagOpen))))
            replacements.append((NSRange(location: NSMaxRange(match.range), length: 0), String(Character(tagClose))))
        }
        // From the end; at one location a replacement goes before an insertion so neither splits the other.
        for (range, replacement) in replacements.sorted(by: { ($0.0.location, $0.0.length) > ($1.0.location, $1.0.length) }) {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }

    /// Maps only the reserved marker range; ordinary user text remains untouched.
    private static func placeholder(_ scalar: Unicode.Scalar) -> Placeholder? {
        placeholders.first { $0.scalar == scalar }?.meaning
    }

    /// Restores markers that did not become recognized constructs so the reader can still see the literal source.
    private static func restorePlaceholders(_ text: String, marked: Bool, keepingInlineMarkers: Bool = false) -> String {
        guard marked, text.unicodeScalars.contains(where: { placeholderScalars.contains($0.value) }) else { return text }
        var restored = ""
        for scalar in text.unicodeScalars {
            if let source = wikilinkSources[scalar] {
                if keepingInlineMarkers { restored.unicodeScalars.append(scalar) } else { restored += source }
                continue
            }
            if let marker = inlineMarkers.first(where: { $0.open == scalar || $0.close == scalar }) {
                if keepingInlineMarkers { restored.unicodeScalars.append(scalar) }
                else { restored += marker.open == scalar ? marker.source.0 : marker.source.1 }
                continue
            }
            if let entry = placeholders.first(where: { $0.scalar == scalar }) {
                if case .emoji(let value) = entry.meaning, keepingInlineMarkers { restored += value }
                else { restored += entry.marker }
            }
            else if scalar == anchorOpen { restored += "{#" }
            else if scalar == anchorClose { restored += "}" }
            else { restored.unicodeScalars.append(scalar) }
        }
        return restored
    }

    /// Identifies invisible control markers used to recover inline extension styling.
    private static func isInlineMarker(_ scalar: Unicode.Scalar) -> Bool {
        wikilinkSources[scalar] != nil || inlineMarkers.contains { $0.open == scalar || $0.close == scalar }
    }

    /// The visible text of a heading run: markers removed and labelled wikilink targets hidden.
    /// Removes only the invisible boundaries inserted around inline extensions, retaining their visible text.
    private static func removingInlineMarkers(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInlineMarker) else { return text }
        var marks = InlineMarks()
        var references: [NSRange] = []
        return splitInlineMarks(text, marks: &marks, references: &references).0
    }

    /// Removes inline markers and hidden wikilink targets, returning UTF-16 segments with the marks in
    /// effect. `marks` carries the state across runs of one block; footnote reference ranges are shifted to match.
    /// Splits rendered text into native styling ranges without changing its visible characters.
    private static func splitInlineMarks(_ text: String, marks: inout InlineMarks,
                                         references: inout [NSRange]) -> (String, [(range: NSRange, marks: InlineMarks)]) {
        var result = ""
        var segments: [(range: NSRange, marks: InlineMarks)] = []
        var segmentStart = 0
        var removed: [Int] = []
        var position = 0
        for scalar in text.unicodeScalars {
            if wikilinkSources[scalar] != nil {
                marks.hidingWikilinkTarget = scalar == wikilinkLabelledOpen
                removed.append(position)
            } else if marks.hidingWikilinkTarget {
                removed.append(contentsOf: (0..<scalar.utf16.count).map { position + $0 })
            } else if let marker = inlineMarkers.first(where: { $0.open == scalar || $0.close == scalar }) {
                let length = result.utf16.count
                segments.append((NSRange(location: segmentStart, length: length - segmentStart), marks))
                segmentStart = length
                marks.set(marker.mark, marker.open == scalar)
                removed.append(position)
            } else { result.unicodeScalars.append(scalar) }
            position += scalar.utf16.count
        }
        segments.append((NSRange(location: segmentStart, length: result.utf16.count - segmentStart), marks))
        references = references.map { reference in
            NSRange(location: reference.location - removed.filter { $0 < reference.location }.count, length: reference.length)
        }
        return (result, segments)
    }

    /// Splits a marked trailing anchor off heading text; the whitespace before it is dropped.
    /// Extracts an explicitly marked heading ID while leaving unmarked heading text unchanged.
    private static func headingAnchor(_ text: String, marked: Bool) -> (text: String, anchor: String?) {
        guard marked, text.unicodeScalars.last == anchorClose,
              let open = text.unicodeScalars.lastIndex(of: anchorOpen) else { return (text, nil) }
        let scalars = text.unicodeScalars
        let id = String(scalars[scalars.index(after: open)..<scalars.index(before: scalars.endIndex)])
        var head = String(scalars[..<open])
        while head.last == " " || head.last == "\t" { head.removeLast() }
        return (head, id)
    }

    /// Keeps explicit anchors, then gives every other heading a GitHub-style slug: lowercased, with
    /// characters other than letters, digits, spaces, `-` and `_` removed and spaces turned into `-`.
    /// Repeats get `-1`, `-2`, … so every anchor is unique.
    /// Generates stable slug anchors and disambiguates repeated headings in document order.
    private static func assignAnchors(_ headings: inout [MarkdownHeading]) {
        var used = Set<String>()
        for index in headings.indices where !headings[index].anchor.isEmpty {
            let base = headings[index].anchor
            var anchor = base
            var suffix = 0
            while used.contains(anchor) { suffix += 1; anchor = base + "-\(suffix)" }
            headings[index].anchor = anchor
            used.insert(anchor)
        }
        for index in headings.indices where headings[index].anchor.isEmpty {
            let base = String(headings[index].title.lowercased().unicodeScalars.compactMap { scalar -> Character? in
                if scalar == " " { return "-" }
                let keep = scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
                return keep ? Character(scalar) : nil
            })
            var anchor = base
            var suffix = 0
            while used.contains(anchor) { suffix += 1; anchor = base + "-\(suffix)" }
            used.insert(anchor)
            headings[index].anchor = anchor
        }
    }

    /// Accepts only in-document fragments; external destinations are not converted to preview navigation.
    private static func localFragmentAnchor(_ link: URL?) -> String? {
        guard let link, let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.scheme == nil, components.host == nil, components.user == nil,
              components.password == nil, components.path.isEmpty, components.query == nil,
              let encoded = components.percentEncodedFragment,
              let fragment = encoded.removingPercentEncoding, !fragment.isEmpty else { return nil }
        return fragment
    }

    /// Preserves front-matter source, parsed value, pretty form, and remaining Markdown body.
    private struct FrontMatter {
        let body: String
        let literal: String
        let value: StructuredValue
        let pretty: String
    }

    /// Reads front matter only at the first line and preserves its original range/body for configured display modes.
    private static func leadingFrontMatter(_ text: String, checkpoint: @escaping () throws -> Void) throws -> FrontMatter? {
        let bytes = Array(text.utf8)
        /// Finds the physical line end and advances over CR, LF, or CRLF as one terminator.
        func lineEnd(_ start: Int) -> (end: Int, next: Int) {
            var end = start
            while end < bytes.count, bytes[end] != 10, bytes[end] != 13 { end += 1 }
            var next = end
            if next < bytes.count {
                if bytes[next] == 13, next + 1 < bytes.count, bytes[next + 1] == 10 { next += 2 }
                else { next += 1 }
            }
            return (end, next)
        }
        let first = lineEnd(0)
        guard bytes[0..<first.end].elementsEqual([45, 45, 45]), first.next > first.end else { return nil }
        var position = first.next
        while position < bytes.count {
            try checkpoint()
            guard position <= 16_384 else { throw MarkdownLimit.exceeded }
            let line = lineEnd(position)
            let marker = bytes[position..<line.end]
            if marker.elementsEqual([45, 45, 45]) || marker.elementsEqual([46, 46, 46]) {
                let payload = Data(bytes[first.next..<position])
                let yaml = try YAMLInspector.inspect(bytes: payload, limits: .init(maximumBytes: 16_384, maximumDepth: 16,
                    maximumValues: 512, maximumOutputBytes: 32_768), maximumDocuments: 1)
                guard yaml.diagnostics.isEmpty, let documents = yaml.documents, documents.count <= 1,
                      let pretty = yaml.prettyText else {
                    if yaml.diagnostics.contains(where: { $0.code == .limitExceeded }) { throw MarkdownLimit.exceeded }
                    throw MarkdownFrontMatterError.invalid
                }
                try checkpoint()
                return .init(body: String(decoding: bytes[line.next...], as: UTF8.self),
                    literal: String(decoding: bytes[..<line.end], as: UTF8.self), value: documents.first ?? .null,
                    pretty: documents.isEmpty ? "null" : pretty)
            }
            position = line.next
        }
        return nil
    }

    /// Markdown body with definitions separated for numbered trailing-list rendering.
    private struct Footnotes {
        let body: String
        /// Lowercased label → single-line definition Markdown.
        let definitions: [String: String]
    }

    /// Removes `[^label]: text` definitions (with indented or lazy continuation lines) outside fenced code.
    /// Multi-paragraph definitions are joined into one paragraph.
    /// Removes bounded footnote definitions before Foundation parses link references, retaining first definitions.
    private static func extractFootnotes(_ text: String, checkpoint: () throws -> Void) throws -> Footnotes {
        guard text.contains("[^") else { return .init(body: text, definitions: [:]) }
        var kept: [Substring] = []
        var definitions: [String: String] = [:]
        var fence: (marker: Character, count: Int)?
        var current: (label: String, lines: [String])?
        var pendingBlank = false
        /// Commits one bounded footnote definition, preserving the first occurrence of duplicate labels.
        func finish() throws {
            guard let definition = current else { return }
            current = nil
            guard definitions.count < 256 else { throw MarkdownLimit.exceeded }
            let joined = definition.lines.joined(separator: " ")
            guard joined.utf8.count <= 4_096 else { throw MarkdownLimit.exceeded }
            if definitions[definition.label] == nil { definitions[definition.label] = joined }
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try checkpoint()
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if indent <= 3, trimmed.prefix(while: { $0 == open.marker }).count >= open.count,
                   trimmed.drop(while: { $0 == open.marker }).allSatisfy(\.isWhitespace) { fence = nil }
                kept.append(rawLine)
                continue
            }
            if current != nil {
                let blank = line.allSatisfy(\.isWhitespace)
                if blank { pendingBlank = true; continue }
                let indented = indent >= 4 || line.hasPrefix("\t")
                if indented || (!pendingBlank && footnoteLabel(line) == nil) {
                    current?.lines.append(line.trimmingCharacters(in: .whitespaces))
                    pendingBlank = false
                    continue
                }
                try finish()
                if pendingBlank { kept.append("") }
                pendingBlank = false
            }
            if indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 { fence = (marker, count); kept.append(rawLine); continue }
            }
            if let (label, rest) = footnoteLabel(line) {
                current = (label, rest.isEmpty ? [] : [rest])
                continue
            }
            kept.append(rawLine)
        }
        try finish()
        return .init(body: kept.joined(separator: "\n"), definitions: definitions)
    }

    /// `[^label]: rest` with at most three leading spaces; labels are matched case-insensitively.
    /// Parses the supported single-line `[^label]: body` definition form without accepting nested syntax.
    private static func footnoteLabel(_ line: Substring) -> (String, String)? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, trimmed.hasPrefix("[^"),
              let close = trimmed.firstIndex(of: "]") else { return nil }
        let label = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close]
        let afterClose = trimmed.index(after: close)
        guard !label.isEmpty, label.count <= 64, !label.contains(where: \.isWhitespace),
              afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
        let rest = trimmed[trimmed.index(after: afterClose)...].trimmingCharacters(in: .whitespaces)
        return (label.lowercased(), rest)
    }

    /// Replaces defined `[^label]` references with `[n]`, numbered by first reference.
    /// Returns UTF-16 ranges of the replacements within the returned text.
    /// Assigns numbers by first reference so output order follows the rendered document rather than source definitions.
    private static func numberFootnoteReferences(in text: String, definitions: [String: String],
                                                 numbers: inout [String: Int], order: inout [String]) -> (String, [NSRange]) {
        guard text.contains("[^") else { return (text, []) }
        var result = ""
        var ranges: [NSRange] = []
        var remainder = Substring(text)
        while let start = remainder.range(of: "[^") {
            guard let close = remainder[start.upperBound...].firstIndex(of: "]") else { break }
            let label = remainder[start.upperBound..<close].lowercased()
            result += remainder[..<start.lowerBound]
            if definitions[label] != nil {
                let number: Int
                if let existing = numbers[label] { number = existing }
                else { order.append(label); number = order.count; numbers[label] = number }
                let marker = "[\(number)]"
                ranges.append(NSRange(location: result.utf16.count, length: marker.utf16.count))
                result += marker
            } else {
                result += remainder[start.lowerBound...close]
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return (result + remainder, ranges)
    }

    /// Resolves only languages represented by the source inspector; unknown code-fence hints stay unhighlighted.
    private static func sourceLanguage(_ hint: String?) -> SourceLanguage? {
        switch hint?.lowercased().split(whereSeparator: \.isWhitespace).first {
        case "swift": .swift
        case "java": .java
        case "c": .c
        case "cpp", "c++": .cpp
        case "objective-c", "objectivec", "objc": .objectiveC
        case "python", "py": .python
        case "javascript", "js": .javascript
        case "jsx", "astro": .jsx
        case "typescript", "ts", "tsx": .typescript
        case "sh", "bash", "zsh", "shell": .shell
        case "clojure", "clj", "cljs", "cljc", "edn", "bb": .clojure
        case "csh": .csh
        case "csharp", "cs": .csharp
        case "cmake": .cmake
        case "ruby": .ruby
        case "perl", "pl": .perl
        case "r": .r
        case "scala": .scala
        case "julia", "jl": .julia
        case "coffeescript", "coffee": .coffeescript
        case "coldfusion", "cfml": .coldfusion
        case "crystal", "cr": .crystal
        case "cson": .cson
        case "css": .css
        case "bibtex", "bib": .bibtex
        default: nil
        }
    }
}

/// Signals that a bounded Markdown parsing or transformation budget was exceeded.
private enum MarkdownLimit: Error { case exceeded }

/// Tracks the inline extension styles active while placeholder markers are restored.
private struct InlineMarks {
    /// Inline marker kinds supported by the Markdown renderer.
    enum Kind: Sendable { case highlight, superscript, lowered, hashtag }
    var highlight = false
    var superscript = false
    var lowered = false
    var hashtag = false
    var hidingWikilinkTarget = false

    /// Updates one active inline-style flag as its marker is entered or exited.
    mutating func set(_ kind: Kind, _ value: Bool) {
        switch kind {
        case .highlight: highlight = value
        case .superscript: superscript = value
        case .lowered: lowered = value
        case .hashtag: hashtag = value
        }
    }
}

/// Indicates that leading YAML front matter could not be parsed as the supported value.
private enum MarkdownFrontMatterError: Error { case invalid }

/// Builds the expanded table-cell map while merging cells that occupy the same grid position.
private struct MarkdownTableBuilder {
    let columnCount: Int
    var cells: [MarkdownTableCell] = []
    private var cellIndices: [Int: Int] = [:]

    /// Starts an empty table builder for a known expanded column count.
    init(columnCount: Int) { self.columnCount = columnCount }
    /// Adds or merges a cell span keyed by its row and column in the expanded table grid.
    mutating func append(range: NSRange, row: Int, column: Int) {
        let key = row * columnCount + column
        if let index = cellIndices[key] {
            let original = cells[index]
            cells[index] = .init(range: NSUnionRange(original.range, range), row: row, column: column)
        } else {
            cellIndices[key] = cells.count
            cells.append(.init(range: range, row: row, column: column))
        }
    }
}
