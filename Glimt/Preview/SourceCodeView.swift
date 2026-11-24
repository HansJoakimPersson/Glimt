import AppKit
import InspectorCore

/// A native selectable text view with one gutter number per logical source line.
final class SourceCodeView: NSView {
    let textView = SourceCodeTextView()
    let scrollView = NSScrollView()
    private(set) var options: SourceRenderConfiguration
    private var document: SourceDocument?
    private var lineRuler: SourceLineNumberRuler?
    private var vcsLineDiff: VCSLineDiff?

    /// Creates a source view configured with validated rendering options.
    init(options: SourceRenderConfiguration = .init()) {
        self.options = options
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    /// Sets up native text/ruler views once; source parsing and VCS lookup remain outside this renderer.
    private func configure() {
        identifier = .init("SourceCodePreview")
        scrollView.identifier = .init("SourceCodeScrollView")
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        textView.identifier = .init("SourceCodeText")
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = options.resolvedFont()
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        let ruler = SourceLineNumberRuler(scrollView: scrollView, orientation: .verticalRuler)
        ruler.clientView = textView
        ruler.setAccessibilityLabel("Line numbers")
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        lineRuler = ruler

        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyOptions()
    }

    /// Installs a parsed document and clears stale line-diff state when the underlying source changes.
    func display(_ document: SourceDocument) {
        let sameSource = self.document?.source == document.source
        if !sameSource {
            vcsLineDiff = nil
            lineRuler?.lineDiff = nil
        }
        self.document = document
        textView.setAccessibilityLabel("\(document.language.displayName) source code")
        applyHighlighting(preservingSelection: sameSource)
        applyOptions()
        if !sameSource { textView.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    }

    /// Reapplies colors and text geometry only when presentation settings actually changed.
    func updateOptions(_ value: SourceRenderConfiguration) {
        guard value != options else { return }
        options = value
        applyHighlighting()
        applyOptions()
    }

    /// Removes source, wrapping and ruler state so no prior document is visible in an empty preview.
    func clear() {
        document = nil
        vcsLineDiff = nil
        textView.hardWrap = nil
        textView.string = ""
        lineRuler?.lineStarts = []
        lineRuler?.lineDiff = nil
        textView.logicalLineStarts = []
    }

    /// Applies a precomputed VCS diff to the existing logical-line ruler. Repository lookup stays
    /// outside the renderer; nil removes the overlay without changing the inspected source.
    func displayVCSLineDiff(_ diff: VCSLineDiff?) {
        guard vcsLineDiff != diff else { return }
        vcsLineDiff = diff
        lineRuler?.lineDiff = diff
    }

    /// Re-resolves syntax colors and ruler drawing when the window appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHighlighting()
    }

    /// Rebuilds attributed display text from original UTF-16 runs and maps presentation wraps back to source.
    private func applyHighlighting(preservingSelection: Bool = true) {
        let preset = options.activeTheme(for: effectiveAppearance)
        let palette = options.activePalette(for: effectiveAppearance)
        let background = SourceSyntaxColors.background(for: preset, palette: palette)
        let foreground = SourceSyntaxColors.foreground(for: preset, palette: palette)
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        textView.textColor = foreground
        textView.indentationColor = foreground.blended(withFraction: 0.75, of: background) ?? .separatorColor
        lineRuler?.preset = preset
        lineRuler?.palette = palette
        guard let document else { return }
        let paragraph = NSMutableParagraphStyle()
        let font = options.resolvedFont()
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(options.tabWidth)
        paragraph.tabStops = []
        // Hard wrap changes only the displayed string; the document and its runs stay original (ADR-016).
        let layout = options.wrapMode == .hard
            ? (try? HardWrapLayout.wrap(document.source, lineLength: options.lineLength, tabStop: options.tabWidth)) ?? .identity(document.source)
            : .identity(document.source)
        textView.hardWrap = layout
        let lineStarts = document.lineStarts.map(layout.displayedLocation(forOriginal:))
        lineRuler?.lineStarts = lineStarts
        lineRuler?.lineDiff = vcsLineDiff
        textView.logicalLineStarts = Set(lineStarts)
        let attributed = NSMutableAttributedString(string: layout.displayed, attributes: [
            .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph
        ])
        // InspectorCore has already checked ranges, ordering and UTF-16 boundaries.
        let colors = Dictionary(uniqueKeysWithValues: SyntaxTokenKind.allCases.map { ($0, SourceSyntaxColors.color(for: $0, preset: preset, palette: palette)) })
        for run in document.highlighting.runs {
            if let color = colors[run.kind] { attributed.addAttribute(.foregroundColor, value: color, range: layout.displayedRange(forOriginal: run.range)) }
        }
        // Replacing native attributed storage can move selection even when only colors change.
        let selections = preservingSelection ? textView.selectedRanges.filter { value in
            let range = value.rangeValue
            return range.location <= attributed.length && range.length <= attributed.length - range.location
        } : []
        textView.textStorage?.setAttributedString(attributed)
        if !selections.isEmpty { textView.selectedRanges = selections }
        else if !preservingSelection { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        lineRuler?.needsDisplay = true
    }

    /// Configures native wrapping, ruler visibility and text container geometry for the active mode.
    private func applyOptions() {
        let font = options.resolvedFont()
        textView.font = font
        lineRuler?.font = font
        textView.indentationGuidesEnabled = options.indentationGuides
        textView.indentationTabWidth = options.tabWidth
        textView.indentationSpaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        textView.needsDisplay = true
        scrollView.rulersVisible = options.showLineNumbers
        // Hard wrap breaks lines itself, so only Soft wrap follows the window width.
        let soft = options.wrapMode == .soft
        scrollView.hasHorizontalScroller = !soft
        textView.isHorizontallyResizable = !soft
        textView.autoresizingMask = soft ? [.width] : []
        textView.textContainer?.widthTracksTextView = soft
        scrollView.tile()
        textView.textContainer?.containerSize = NSSize(width: soft ? max(1, softWrapWidth) : CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        if soft { textView.setFrameSize(NSSize(width: softWrapWidth, height: max(textView.frame.height, scrollView.contentSize.height))) }
        textView.sizeToFit()
        lineRuler?.needsDisplay = true
    }

    /// The width text can use beside the line-number ruler. The ruler takes its room as a clip-view
    /// inset, which `contentSize` does not subtract (E5-01).
    private var softWrapWidth: CGFloat {
        let insets = scrollView.contentView.contentInsets
        return max(1, scrollView.contentView.bounds.width - insets.left - insets.right)
    }

    /// Keeps the text container matched to the viewport for wrapping and line-number layout.
    override func layout() {
        super.layout()
        // Autoresizing keeps any earlier width error, so soft wrap re-derives the width on every pass.
        guard options.wrapMode == .soft, abs(textView.frame.width - softWrapWidth) > 0.5 else { return }
        textView.setFrameSize(NSSize(width: softWrapWidth, height: textView.frame.height))
    }
}

/// Read-only preview text. With Hard wrap the displayed string contains presentation-only breaks;
/// copying writes the original text the selection covers (ADR-016).
class PreviewTextView: NSTextView {
    var hardWrap: HardWrapLayout?

    /// Copies selected source characters, removing hard-wrap breaks inserted only for display.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let hardWrap, !hardWrap.insertions.isEmpty else { return super.writeSelection(to: pboard, types: types) }
        let text = selectedRanges.map { hardWrap.originalText(forDisplayed: $0.rangeValue) }.joined(separator: "\n")
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }
}

/// Decorative guides are painted behind text; the source, glyphs and selection stay untouched.
/// Only leading whitespace on logical first fragments receives guides, never soft-wrap text.
final class SourceCodeTextView: PreviewTextView {
    var logicalLineStarts: Set<Int> = []
    var indentationGuidesEnabled = false
    var indentationTabWidth = 4
    var indentationSpaceWidth: CGFloat = 1
    var indentationColor = NSColor.separatorColor

    /// Paints the active source palette behind text and any reserved guide columns.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        indentationColor.setFill()
        for guide in indentationGuideRects(in: rect) { guide.fill() }
    }

    /// Bounded visible geometry, also used by native layout regression tests.
    /// Computes guides only for visible logical lines and caps both scanned indentation and emitted marks.
    func indentationGuideRects(in rect: NSRect) -> [NSRect] {
        guard indentationGuidesEnabled, indentationSpaceWidth > 0, let layout = layoutManager,
              let container = textContainer, !logicalLineStarts.isEmpty else { return [] }
        let origin = textContainerOrigin
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return [] }
        let text = string as NSString
        let tabWidth = min(max(indentationTabWidth, 1), 8)
        var guides: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, stop in
            let start = layout.characterIndexForGlyph(at: range.location)
            guard self.logicalLineStarts.contains(start) else { return }
            var index = start
            var columns = 0
            while index < text.length, index - start < 4_096 {
                let unit = text.character(at: index)
                if unit == 32 { columns += 1 }
                else if unit == 9 { columns += tabWidth - columns % tabWidth }
                else { break }
                index += 1
            }
            let leadingX = origin.x + fragment.minX + container.lineFragmentPadding
            let first = max(0, Int(ceil((rect.minX - leadingX) / self.indentationSpaceWidth / CGFloat(tabWidth)))) * tabWidth
            var column = first
            var lineGuideCount = 0
            while column < columns, lineGuideCount < 128 {
                let x = leadingX + CGFloat(column) * self.indentationSpaceWidth
                if x > rect.maxX { break }
                let guide = NSRect(x: x, y: fragment.minY + origin.y, width: 1, height: fragment.height).intersection(rect)
                if !guide.isEmpty { guides.append(guide) }
                if guides.count >= 4_096 { stop.pointee = true; return }
                lineGuideCount += 1
                column += tabWidth
            }
        }
        return guides
    }
}

final class SourceLineNumberRuler: NSRulerView {
    var palette: SourceThemePalette? { didSet { needsDisplay = true } }
    var preset = SourceThemePreset.glimtDefault {
        didSet { needsDisplay = true }
    }
    var lineStarts: [Int] = [] {
        didSet { updateThickness() }
    }
    var lineDiff: VCSLineDiff? {
        didSet { updateThickness() }
    }
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet { updateThickness() }
    }

    /// Bounds the vertical gutter divider to the visible content viewport, excluding scroll insets.
    var dividerFrame: NSRect {
        guard let scrollView else { return .zero }
        let viewport = scrollView.contentView.convert(scrollView.contentView.bounds, to: self)
        let top = max(bounds.minY, viewport.minY)
        let bottom = min(bounds.maxY, viewport.maxY)
        guard bottom > top else { return .zero }
        return NSRect(x: bounds.maxX - 1, y: top, width: 1, height: bottom - top)
    }

    /// Reserves enough gutter for the largest line number and optional VCS markers.
    private func updateThickness() {
        let markerSpace: CGFloat = lineDiff == nil ? 0 : 12
        ruleThickness = max(32, (String(lineStarts.count) as NSString).size(withAttributes: [.font: font]).width + 16 + markerSpace)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    /// Draws visible logical line numbers and delegates change markers using the same text layout.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        SourceSyntaxColors.background(for: preset, palette: palette).setFill()
        rect.intersection(bounds).fill()
        guard let text = clientView as? NSTextView, let layout = text.layoutManager,
              let container = text.textContainer else { return }
        let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
        if !lineStarts.isEmpty, layout.numberOfGlyphs > 0 {
            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
            if glyphs.length > 0 {
                let firstCharacter = layout.characterIndexForGlyph(at: glyphs.location)
                var lower = 0, upper = lineStarts.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if lineStarts[middle] <= firstCharacter { lower = middle + 1 } else { upper = middle }
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: SourceSyntaxColors.color(for: .comment, preset: preset, palette: palette)
                ]
                for index in max(0, lower - 1)..<lineStarts.count {
                    let glyph = layout.glyphIndexForCharacter(at: lineStarts[index])
                    guard glyph < layout.numberOfGlyphs else { break }
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let origin = convert(NSPoint(x: 0, y: line.minY + text.textContainerOrigin.y), from: text)
                    if origin.y > bounds.maxY { break }
                    let number = String(index + 1) as NSString
                    let width = number.size(withAttributes: attributes).width
                    number.draw(at: NSPoint(x: bounds.maxX - width - 8, y: origin.y), withAttributes: attributes)
                }
            }
        }
        drawVCSMarkers(in: rect, text: text, layout: layout, container: container)
        NSColor.separatorColor.setFill()
        dividerFrame.intersection(rect).fill()
    }

    /// Paints only changed lines intersecting the visible range; deletions anchor at their nearest boundary.
    private func drawVCSMarkers(in rect: NSRect, text: NSTextView, layout: NSLayoutManager,
                                container: NSTextContainer) {
        guard let lineDiff else { return }
        let markerX = bounds.minX + 3
        let width: CGFloat = 3
        let visibleGlyphs = layout.glyphRange(forBoundingRect: text.visibleRect.offsetBy(
            dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y
        ), in: container)
        let visibleFirstCharacter = visibleGlyphs.length > 0
            ? layout.characterIndexForGlyph(at: visibleGlyphs.location) : 0
        let visibleLastCharacter = visibleGlyphs.length > 0
            ? layout.characterIndexForGlyph(at: min(NSMaxRange(visibleGlyphs) - 1, max(0, layout.numberOfGlyphs - 1)))
            : visibleFirstCharacter
        let visibleFirstLine = lineIndex(atOrBefore: visibleFirstCharacter)
        let visibleLastLine = min(lineStarts.count, lineIndex(atOrBefore: visibleLastCharacter) + 2)
        let changes = lineDiff.changes
        var firstChange = 0
        var upperChange = changes.count
        while firstChange < upperChange {
            let middle = (firstChange + upperChange) / 2
            if changes[middle].workingLines.upperBound < visibleFirstLine { firstChange = middle + 1 }
            else { upperChange = middle }
        }
        for change in changes.dropFirst(firstChange) {
            if change.workingLines.lowerBound > visibleLastLine { break }
            let color: NSColor = switch change.kind {
            case .added: .systemGreen
            case .modified: .systemOrange
            case .deleted: .systemRed
            }
            color.setFill()
            if !change.workingLines.isEmpty {
                let visibleRange = max(change.workingLines.lowerBound, visibleFirstLine)..<min(change.workingLines.upperBound, visibleLastLine)
                for logicalLine in visibleRange where lineStarts.indices.contains(logicalLine) {
                    let glyph = layout.glyphIndexForCharacter(at: lineStarts[logicalLine])
                    guard glyph < layout.numberOfGlyphs else { continue }
                    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let origin = convert(NSPoint(x: 0, y: fragment.minY + text.textContainerOrigin.y), from: text)
                    let marker = NSRect(x: markerX, y: origin.y, width: width,
                                        height: max(2, fragment.height)).intersection(rect)
                    if !marker.isEmpty { marker.fill() }
                }
            } else if change.kind == .deleted {
                // A deletion has no working line. Pin a short bar to the next logical line, or
                // to the end of the final line when the removed block was at EOF.
                let boundary = min(max(change.workingLines.lowerBound, 0), lineStarts.count)
                let y: CGFloat
                if boundary < lineStarts.count {
                    let glyph = layout.glyphIndexForCharacter(at: lineStarts[boundary])
                    guard glyph < layout.numberOfGlyphs else { continue }
                    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    y = convert(NSPoint(x: 0, y: fragment.minY + text.textContainerOrigin.y), from: text).y
                } else if layout.numberOfGlyphs > 0 {
                    let fragment = layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil)
                    y = convert(NSPoint(x: 0, y: fragment.maxY + text.textContainerOrigin.y), from: text).y - 2
                } else {
                    y = text.textContainerOrigin.y
                }
                let marker = NSRect(x: markerX, y: y, width: width, height: 4).intersection(rect)
                if !marker.isEmpty { marker.fill() }
            }
        }
    }

    /// Binary-searches logical line starts for the line containing a character offset.
    private func lineIndex(atOrBefore character: Int) -> Int {
        var lower = 0, upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= character { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}

/// Shared read-only text surface for textual structured Raw and Pretty representations.
/// TextKit 1 is required: TextKit 2 does not draw the NSTextTable/NSTextBlock layout that
/// Markdown tables and alerts use.
final class StructuredTextPreview: NSScrollView {
    let textView = PreviewTextView(usingTextLayoutManager: false)
    private let lineRuler: SourceLineNumberRuler
    override init(frame: NSRect) {
        lineRuler = SourceLineNumberRuler(scrollView: nil, orientation: .verticalRuler)
        super.init(frame: frame)
        documentView = textView
        lineRuler.scrollView = self
        lineRuler.clientView = textView
        verticalRulerView = lineRuler
        hasVerticalRuler = true
        textView.isEditable = false
        textView.isSelectable = true
    }
    required init?(coder: NSCoder) { nil }
    /// Shows a ruler and bounded syntax colors only for structured plain-text representations.
    func decorate(format: StructuredTextFormat?) {
        rulersVisible = format != nil
        guard let format else { return }
        let source = textView.string as NSString
        var starts: [Int] = []
        var position = 0
        while position < source.length {
            starts.append(position)
            let next = NSMaxRange(source.lineRange(for: .init(location: position, length: 0)))
            guard next > position else { break }
            position = next
        }
        lineRuler.lineStarts = starts
        lineRuler.font = textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        guard let storage = textView.textStorage else { return }
        StructuredTextHighlighting.apply(to: storage, format: format)
    }
}

/// Structured text format labels used by the tree view's accessibility and status text.
enum StructuredTextFormat { case yaml, json, xml }

/// Bounded lexical presentation only. Inspected content and original UTF-16 remain unchanged.
enum StructuredTextHighlighting {
    @MainActor
    /// Applies capped regex-based coloring without changing the inspected text or its ranges.
    static func apply(to storage: NSTextStorage, format: StructuredTextFormat) {
        guard storage.length <= 2_097_152 else { return }
        let pattern: String
        let kinds: [SyntaxTokenKind]
        switch format {
        case .json:
            pattern = #"("(?:\\.|[^"\\])*"\s*(?=:))|("(?:\\.|[^"\\])*")|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|(\b(?:true|false|null)\b)|([{}\[\],:])"#
            kinds = [.type, .string, .number, .keyword, .comment]
        case .yaml:
            pattern = #"(?m)(#[^\r\n]*)|("(?:\\.|[^"\\])*"|'(?:''|[^'])*')|([\w.-]+\s*(?=:\s|:$))|(\b(?:true|false|null|yes|no|~)\b)|(-?\b\d+(?:\.\d+)?\b)|([&*!][\w:.-]+)|([\w./-]+)"#
            kinds = [.comment, .string, .type, .keyword, .number, .directive, .string]
        case .xml:
            pattern = #"(<!--[\s\S]*?-->)|("[^"]*"|'[^']*')|(?<=<)(/?[\w:.-]+)|([\w:.-]+\s*(?==))|(<\?|\?>|</?|/?>)"#
            kinds = [.comment, .string, .type, .directive, .keyword]
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        var count = 0
        regex.enumerateMatches(in: storage.string, range: .init(location: 0, length: storage.length)) { match, _, stop in
            guard let match else { return }
            count += 1
            if count > 100_000 { stop.pointee = true; return }
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: SourceSyntaxColors.color(for: kinds[index - 1]), range: match.range(at: index))
                break
            }
        }
    }
}

/// Offset/hex/ASCII presentation of an explicitly bounded retained byte prefix.
enum HexPreview {
    static let maximumBytes = 65_536
    /// Formats only the retained prefix into offset, hexadecimal and printable-ASCII columns.
    static func format(_ data: Data) -> String {
        let bytes = Array(data.prefix(maximumBytes))
        let digits = Array("0123456789abcdef".utf8)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var hex = ""
            for index in 0..<16 {
                if index == 8 { hex += " " }
                if index < row.count {
                    let value = row[row.startIndex + index]
                    hex += String(decoding: [digits[Int(value >> 4)], digits[Int(value & 15)]], as: UTF8.self) + " "
                } else { hex += "   " }
            }
            let ascii = String(row.map { $0 >= 32 && $0 <= 126 ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x  ", offset) + hex + " |" + ascii + "|"
        }.joined(separator: "\n")
    }
}
