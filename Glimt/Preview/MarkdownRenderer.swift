import AppKit
import InspectorCore
import SwiftMath

/// Only known native visuals are emitted; math uses a bounded local typesetter and active content stays inert.
@MainActor
enum MarkdownRenderer {
    static let headingIndexAttribute = NSAttributedString.Key("GlimtMarkdownHeadingIndex")

    /// Resolves a Text font family; "System" and unavailable families use the system font.
    static func textFont(_ family: String, size: CGFloat, bold: Bool = false) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        switch family {
        case "System":
            return system
        case "New York":
            guard let serif = system.fontDescriptor.withDesign(.serif) else { return system }
            return NSFont(descriptor: serif, size: size) ?? system
        default:
            return NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                             weight: bold ? 9 : 5, size: size) ?? system
        }
    }

    /// Styles the semantic Markdown model and adds only bounded local attachments; links remain inert.
    static func render(_ document: MarkdownDocument, configuration: MarkdownRenderConfiguration = .init(),
                       source: SourceRenderConfiguration = .init(), appearance: NSAppearance = .currentDrawing(),
                       maximumDiagramWidth: CGFloat = 560,
                       mermaidImages: [String: NSImage] = [:],
                       makeMermaidAttachment: MermaidAttachmentFactory = { block, appearance, width, image in
                           MermaidDiagramRenderer.attachment(for: block, appearance: appearance,
                                                             maximumWidth: width, renderedImage: image)
                       }) -> NSAttributedString {
        let sourcePreset = source.activeTheme(for: appearance)
        let sourcePalette = source.activePalette(for: appearance)
        let bodySize = CGFloat(configuration.fontSize)
        let paragraph = NSMutableParagraphStyle()
        let headingMultiplier: CGFloat
        switch configuration.profile {
        case .default:
            paragraph.paragraphSpacing = 4
            headingMultiplier = 1
        case .compact:
            paragraph.paragraphSpacing = 0
            headingMultiplier = 0.9
        case .reading:
            paragraph.paragraphSpacing = 8
            paragraph.lineSpacing = 2
            headingMultiplier = 1.1
        }
        // Prose uses the configured Text font; code keeps the monospace source font.
    /// Selects the configured prose font at the requested size and weight.
    func prose(_ size: CGFloat, bold: Bool = false) -> NSFont {
            textFont(configuration.textFont, size: size, bold: bold)
        }
        let result = NSMutableAttributedString(string: document.renderedText ?? document.raw, attributes: [
            .font: prose(bodySize), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph
        ])
        let mono = source.resolvedFont()
        let boldMono = source.resolvedFont(weight: .bold)
        for run in document.runs {
            let font: NSFont
            if run.code { font = run.bold ? boldMono : mono }
            else if let heading = run.headingLevel {
                let style: NSFont.TextStyle = heading == 1 ? .title1 : heading == 2 ? .title2 : .headline
                let preferred = NSFont.preferredFont(forTextStyle: style)
                font = prose(preferred.pointSize * bodySize / 13 * headingMultiplier, bold: true)
            } else { font = prose(bodySize, bold: run.bold) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font,
                .foregroundColor: run.quote ? SourceSyntaxColors.color(for: .comment) : NSColor.textColor
            ]
            if run.code {
                attributes[.foregroundColor] = SourceSyntaxColors.foreground(for: sourcePreset, palette: sourcePalette)
                attributes[.backgroundColor] = SourceSyntaxColors.background(for: sourcePreset, palette: sourcePalette)
            }
            if let syntax = run.syntax { attributes[.foregroundColor] = SourceSyntaxColors.color(for: syntax, preset: sourcePreset, palette: sourcePalette) }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            switch run.footnote {
            case .reference:
                attributes[.font] = prose(bodySize * 0.75)
                attributes[.baselineOffset] = bodySize * 0.35
            case .definition:
                let base = run.code ? mono : prose(bodySize, bold: run.bold)
                let small = base.withSize(bodySize * 0.85)
                attributes[.font] = run.italic ? NSFontManager.shared.convert(small, toHaveTrait: .italicFontMask) : small
                if !run.code { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            case nil: break
            }
            if let alert = run.alert { attributes[.foregroundColor] = alertTitleColor(alert) }
            if run.hashtag { attributes[.foregroundColor] = run.highlight ? highlightedHashtagColor : hashtagColor }
            if run.highlight { attributes[.backgroundColor] = highlightBackground }
            if run.isSuperscript || run.isSubscript, let base = attributes[.font] as? NSFont {
                attributes[.font] = base.withSize(base.pointSize * 0.75)
                attributes[.baselineOffset] = base.pointSize * (run.isSuperscript ? 0.35 : -0.15)
            }
            result.addAttributes(attributes, range: run.range)
        }
        renderNavigationLinks(document.navigationLinks, in: result)
        for (index, heading) in document.headings.enumerated()
        where heading.range.location >= 0 && heading.range.length > 0 && NSMaxRange(heading.range) <= result.length {
            result.addAttribute(headingIndexAttribute, value: index, range: heading.range)
        }
        renderListIndents(document.listParagraphs, in: result, paragraph: paragraph, bodySize: bodySize)
        renderDefinitionIndents(document.definitionLists, in: result, paragraph: paragraph)
        renderAlerts(document.alerts, in: result, paragraph: paragraph)
        var images = document.images
        var tables = document.tables
        var mermaidBlocks = document.mermaidBlocks
        renderMath(document.mathExpressions, in: result, paragraph: paragraph, bodySize: bodySize, appearance: appearance,
                   tables: &tables, images: &images, mermaidBlocks: &mermaidBlocks)
        renderMermaid(mermaidBlocks, in: result, appearance: appearance, maximumWidth: maximumDiagramWidth,
                      renderedImages: mermaidImages, makeAttachment: makeMermaidAttachment,
                      tables: &tables, images: &images)
        renderTables(tables, in: result, paragraph: paragraph, bodySize: bodySize, images: &images)
        renderImages(images, in: result)
        return result
    }

    /// Replaces only successfully parsed, reasonably sized formulas. Everything else stays exact source text.
    private static func renderMath(_ expressions: [MarkdownMathExpression], in result: NSMutableAttributedString,
                                   paragraph: NSParagraphStyle, bodySize: CGFloat, appearance: NSAppearance,
                                   tables: inout [MarkdownTable], images: inout [MarkdownImageReference],
                                   mermaidBlocks: inout [MarkdownMermaidBlock]) {
        // Enforce aggregate area and estimated bitmap budgets across all rendered formulas.
        var renderedArea: CGFloat = 0
        var estimatedImageBytes = 0
        for expression in expressions.prefix(64).reversed() where expression.range.location >= 0
            && expression.range.length > 0 && NSMaxRange(expression.range) <= result.length {
            guard !containsDisallowedCommand(expression.latex) else { continue }
            let size = expression.mode == .display ? bodySize * 1.2 : bodySize
            var math = MathImage(latex: expression.latex, fontSize: size,
                                 textColor: NSColor.textColor,
                                 labelMode: expression.mode == .display ? .display : .text,
                                 textAlignment: expression.mode == .display ? .center : .left)
            var renderResult: (NSError?, NSImage?, MathImage.LayoutInfo?)?
            appearance.performAsCurrentDrawingAppearance { renderResult = math.asImage() }
            guard let renderResult else { continue }
            let (error, image, layout) = renderResult
            guard error == nil, let image, let layout else { continue }
            let fittedSize = image.size
            guard fittedSize.width.isFinite, fittedSize.height.isFinite,
                  fittedSize.width > 0, fittedSize.height > 0,
                  fittedSize.width <= 640, fittedSize.height <= 320,
                  fittedSize.width <= CGFloat(Int.max / 4),
                  fittedSize.height <= CGFloat(Int.max / 4),
                  renderedArea <= 2_000_000 - fittedSize.width * fittedSize.height else { continue }
            let rasterBytes = Int(fittedSize.width.rounded(.up) * 4 * fittedSize.height.rounded(.up))
            guard rasterBytes <= 512 * 1_024,
                  estimatedImageBytes <= 4 * 1_024 * 1_024 - rasterBytes else { continue }
            estimatedImageBytes += rasterBytes
            renderedArea += fittedSize.width * fittedSize.height
            image.accessibilityDescription = expression.latex
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: expression.mode == .inline ? -layout.descent : 0,
                                       width: fittedSize.width, height: fittedSize.height)
            result.replaceCharacters(in: expression.range, with: NSAttributedString(attachment: attachment))
            if expression.mode == .display {
                let text = result.string as NSString
                let paragraphRange = text.paragraphRange(for: NSRange(location: expression.range.location, length: 1))
                let current = result.attribute(.paragraphStyle, at: expression.range.location,
                                               effectiveRange: nil) as? NSParagraphStyle ?? .default
                let centered = current.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                centered.alignment = .center
                centered.paragraphSpacingBefore = max(centered.paragraphSpacingBefore, paragraph.paragraphSpacing)
                centered.paragraphSpacing = max(centered.paragraphSpacing, paragraph.paragraphSpacing)
                result.addAttribute(.paragraphStyle, value: centered, range: paragraphRange)
            }

            let delta = expression.range.length - 1
            guard delta != 0 else { continue }
            let end = NSMaxRange(expression.range)
            for blockIndex in mermaidBlocks.indices where mermaidBlocks[blockIndex].range.location >= end {
                let block = mermaidBlocks[blockIndex]
                mermaidBlocks[blockIndex] = .init(
                    range: NSRange(location: block.range.location - delta, length: block.range.length),
                    source: block.source, flowchart: block.flowchart, layout: block.layout, diagnostic: block.diagnostic,
                    sequenceDiagram: block.sequenceDiagram, sequenceLayout: block.sequenceLayout,
                    classDiagram: block.classDiagram, classLayout: block.classLayout, stateDiagram: block.stateDiagram,
                    mermaidKitDiagram: block.mermaidKitDiagram)
            }
            for tableIndex in tables.indices {
                let cells = tables[tableIndex].cells.map { cell -> MarkdownTableCell in
                    var range = cell.range
                    if NSIntersectionRange(range, expression.range).length > 0 {
                        range.length -= delta
                    } else if range.location >= end {
                        range.location -= delta
                    }
                    return MarkdownTableCell(range: range, row: cell.row, column: cell.column)
                }
                tables[tableIndex] = MarkdownTable(columnCount: tables[tableIndex].columnCount, cells: cells)
            }
            for imageIndex in images.indices {
                if NSIntersectionRange(images[imageIndex].range, expression.range).length > 0 {
                    images[imageIndex].data = nil
                } else if images[imageIndex].range.location >= end {
                    images[imageIndex].range.location -= delta
                }
            }
        }
    }

    /// Replaces only successfully rendered bounded Mermaid blocks; failures leave their source visible.
    private static func renderMermaid(_ blocks: [MarkdownMermaidBlock], in result: NSMutableAttributedString,
                                      appearance: NSAppearance, maximumWidth: CGFloat,
                                      renderedImages: [String: NSImage],
                                      makeAttachment: MermaidAttachmentFactory,
                                      tables: inout [MarkdownTable], images: inout [MarkdownImageReference]) {
        // Diagrams share the document attachment budget and replace source only after safe layout succeeds.
        var renderedArea = 0.0
        var estimatedImageBytes = 0
        for block in blocks.prefix(MermaidDiagramRenderer.maximumDiagrams).reversed()
        where block.range.location >= 0 && block.range.length > 0 && NSMaxRange(block.range) <= result.length {
            guard let attachment = makeAttachment(block, appearance, maximumWidth, renderedImages[block.source]),
                  let image = attachment.image else { continue }
            let area = Double(image.size.width * image.size.height)
            let imageBytes = Int((image.size.width * image.size.height * 4).rounded(.up))
            guard area.isFinite, imageBytes > 0,
                  renderedArea <= MermaidDiagramRenderer.maximumAggregateArea - area,
                  estimatedImageBytes <= MermaidDiagramRenderer.maximumEstimatedImageBytes - imageBytes else { continue }
            renderedArea += area
            estimatedImageBytes += imageBytes
            result.replaceCharacters(in: block.range, with: NSAttributedString(attachment: attachment))
            let delta = block.range.length - 1
            guard delta != 0 else { continue }
            let end = NSMaxRange(block.range)
            for tableIndex in tables.indices {
                let cells = tables[tableIndex].cells.map { cell -> MarkdownTableCell in
                    var range = cell.range
                    if NSIntersectionRange(range, block.range).length > 0 {
                        range.length = max(0, range.length - delta)
                    } else if range.location >= end {
                        range.location -= delta
                    }
                    return MarkdownTableCell(range: range, row: cell.row, column: cell.column)
                }
                tables[tableIndex] = MarkdownTable(columnCount: tables[tableIndex].columnCount, cells: cells)
            }
            for imageIndex in images.indices {
                if NSIntersectionRange(images[imageIndex].range, block.range).length > 0 {
                    images[imageIndex].data = nil
                } else if images[imageIndex].range.location >= end {
                    images[imageIndex].range.location -= delta
                }
            }
        }
    }

    /// Keep commands that alter document state, styling or macro definitions as readable source.
    private static func containsDisallowedCommand(_ latex: String) -> Bool {
        let pattern = #"\\(?:input|include|write|openout|read|def|gdef|edef|xdef|newcommand|renewcommand|providecommand|catcode|csname|color|textcolor|pagecolor|colorbox|definecolor)\b"#
        return (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: latex, range: NSRange(location: 0, length: (latex as NSString).length)) != nil
    }

    /// Replaces only references backed by validated local bitmap data; unresolved references remain text.
    private static func renderImages(_ images: [MarkdownImageReference], in result: NSMutableAttributedString) {
        // Only resolved local image bytes are rendered; unresolved and remote references remain readable source.
        for image in images.reversed() where image.range.location >= 0 && image.range.length > 0
            && NSMaxRange(image.range) <= result.length {
            guard let data = image.data, let bitmap = NSImage(data: data),
                  image.pixelWidth != nil, image.pixelHeight != nil else { continue }
            let attachment = NSTextAttachment()
            attachment.image = bitmap
            let replacement = NSAttributedString(attachment: attachment)
            result.replaceCharacters(in: image.range, with: replacement)
        }
    }

    /// Emits only Glimt-internal destinations; the preview controller consumes this scheme locally.
    private static func renderNavigationLinks(_ links: [MarkdownNavigationLink], in result: NSMutableAttributedString) {
        for link in links where link.range.location >= 0 && link.range.length > 0 && NSMaxRange(link.range) <= result.length {
            var components = URLComponents()
            components.scheme = "glimt-anchor"
            components.host = "heading"
            components.path = "/\(link.headingIndex)"
            guard let destination = components.url else { continue }
            result.addAttributes([
                .link: destination,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: link.range)
        }
    }

    /// Text background blended 35% toward system yellow; opaque so contrast is measurable.
    static let highlightBackground = NSColor(name: nil) { appearance in
        var result = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor.textBackgroundColor.usingColorSpace(.sRGB)?.blended(withFraction: 0.35, of: .systemYellow) ?? .textBackgroundColor
        }
        return result
    }

    /// `color.accent`, readable on the text background (or on the highlight); tags stay inert.
    static let hashtagColor = readable(.controlAccentColor)
    static let highlightedHashtagColor = readable(.controlAccentColor, on: highlightBackground)

    /// Maps each parsed alert kind to its semantic system accent.
    private static func alertAccent(_ kind: MarkdownAlertKind) -> NSColor {
        switch kind {
        case .note: .systemBlue
        case .tip: .systemGreen
        case .important: .systemPurple
        case .warning: .systemOrange
        case .caution: .systemRed
        }
    }

    /// Resolves the alert accent to a readable title color on the text background.
    private static func alertTitleColor(_ kind: MarkdownAlertKind) -> NSColor { readable(alertAccent(kind)) }

    /// The accent, blended toward text until it reaches 4.5:1 against the background.
    private static func readable(_ accent: NSColor, on background: NSColor = .textBackgroundColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.textColor
            appearance.performAsCurrentDrawingAppearance {
                var candidate = accent
                for _ in 0..<20 where SourceSyntaxColors.contrast(candidate, background) < 4.5 {
                    candidate = candidate.blended(withFraction: 0.25, of: .textColor) ?? .textColor
                }
                result = SourceSyntaxColors.contrast(candidate, background) >= 4.5 ? candidate : .textColor
            }
            return result
        }
    }

    /// One text block per alert: a 3 pt leading accent border with `spacing.2` padding before the text.
    private static func renderAlerts(_ alerts: [MarkdownAlert], in result: NSMutableAttributedString, paragraph: NSParagraphStyle) {
        let text = result.string as NSString
        for alert in alerts where NSMaxRange(alert.range) <= result.length {
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(alertAccent(alert.kind), for: .minX)
            block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            let range = text.paragraphRange(for: alert.range)
            result.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                let base = (value as? NSParagraphStyle) ?? paragraph
                let style = base.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.textBlocks = [block]
                result.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }
    }

    /// Wrapped lines hang after the marker; nested items start at their parent's text edge.
    /// Markers use monospaced digits so sibling items numbered 1–9 share one text edge.
    private static func renderListIndents(_ paragraphs: [MarkdownListParagraph], in result: NSMutableAttributedString,
                                          paragraph: NSParagraphStyle, bodySize: CGFloat) {
        let text = result.string as NSString
        var textEdges: [Int: CGFloat] = [:]
        for item in paragraphs where item.depth > 0 && NSMaxRange(item.range) <= result.length {
            let lineStart = text.paragraphRange(for: NSRange(location: item.range.location, length: 0))
            let start = item.depth == 1 ? 0 : textEdges[item.depth - 1] ?? 0
            let textEdge: CGFloat
            if item.markerLength > 0 {
                result.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular),
                                    range: NSRange(location: item.range.location, length: item.markerLength))
                let marker = NSRange(location: lineStart.location, length: item.range.location + item.markerLength - lineStart.location)
                textEdge = start + result.attributedSubstring(from: marker).size().width
                textEdges[item.depth] = textEdge
                textEdges = textEdges.filter { $0.key <= item.depth }
            } else { textEdge = textEdges[item.depth] ?? start }
            let style = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent = item.markerLength > 0 ? start : textEdge
            style.headIndent = textEdge
            result.addAttribute(.paragraphStyle, value: style, range: text.paragraphRange(for: item.range))
        }
    }

    /// Definition terms stay at the paragraph edge; every definition line hangs 16 pt inward.
    private static func renderDefinitionIndents(_ groups: [MarkdownDefinitionList], in result: NSMutableAttributedString,
                                                paragraph: NSParagraphStyle) {
        let text = result.string as NSString
        /// Applies a list indentation only to a paragraph range that still fits the rendered document.
        func apply(_ range: NSRange, indent: CGFloat) {
            guard range.length > 0, NSMaxRange(range) <= result.length else { return }
            let paragraphRange = text.paragraphRange(for: range)
            let base = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? paragraph
            let style = base.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            result.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
        }
        for group in groups {
            apply(group.termRange, indent: 0)
            for definition in group.definitionRanges { apply(definition, indent: 16) }
        }
    }

    /// Builds native text tables and replaces source ranges in reverse order to keep offsets stable.
    private static func renderTables(_ tables: [MarkdownTable], in result: NSMutableAttributedString,
                                     paragraph: NSParagraphStyle, bodySize: CGFloat,
                                     images: inout [MarkdownImageReference]) {
        // Style first, then replace from the end so all original model ranges remain valid.
        for model in tables.reversed() {
            guard let first = model.cells.first, let last = model.cells.last else { continue }
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            guard NSMaxRange(range) <= result.length, model.columnCount > 0 else { continue }
            let table = NSTextTable()
            table.numberOfColumns = model.columnCount; table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.collapsesBorders = true; table.hidesEmptyCells = false
            table.setContentWidth(100, type: .percentageValueType)
            let byPosition = Dictionary(uniqueKeysWithValues: model.cells.map { ($0.row * model.columnCount + $0.column, $0) })
            let rows = (model.cells.map(\.row).max() ?? 0) + 1
            let replacement = NSMutableAttributedString()
            for row in 0..<rows {
                for column in 0..<model.columnCount {
                    let piece = NSMutableAttributedString()
                    if let cell = byPosition[row * model.columnCount + column] {
                        piece.append(result.attributedSubstring(from: cell.range))
                    }
                    piece.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.textColor]))
                    let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    block.setContentWidth(100 / CGFloat(model.columnCount), type: .percentageValueType)
                    block.setWidth(8, type: .absoluteValueType, for: .padding)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(.separatorColor)
                    block.backgroundColor = row == 0 ? .windowBackgroundColor : .textBackgroundColor
                    let style = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    style.paragraphSpacing = 0; style.textBlocks = [block]
                    piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
                    replacement.append(piece)
                }
            }
            result.replaceCharacters(in: range, with: replacement)
            let delta = replacement.length - range.length
            for index in images.indices {
                if NSIntersectionRange(images[index].range, range).length > 0 {
                    images[index].data = nil
                    continue
                }
                if images[index].range.location >= NSMaxRange(range) {
                    images[index].range.location += delta
                }
            }
        }
    }
}
