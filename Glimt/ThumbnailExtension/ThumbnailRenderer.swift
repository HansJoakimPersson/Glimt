import AppKit
import CoreGraphics
import CoreText
import InspectorCore

/// Fixed render values for `GlimtThumbnail.appex` (D62). Thumbnails read no user settings: Quick Look
/// font, wrap, line numbers, indentation guides, per-format overrides and the chosen representation
/// never reach them. Only the request size, the screen scale and the system appearance vary the output.
enum ThumbnailRenderDefaults {
    /// Rows drawn at most; the canvas height can limit them further.
    static let maximumLines = 18
    /// Glimt default theme, system monospaced font, soft wrap, 4-column tabs, no gutter, no guides.
    /// Text size follows the request size (`ThumbnailRenderer.basePointSize`), not `fontSize`.
    static let source = SourceRenderConfiguration(showLineNumbers: false, wrapLines: true, tabWidth: 4,
                                                  fontFamily: "System Monospaced", fontSize: 12,
                                                  indentationGuides: false)
    /// Light or dark follows the system; the Glimt Color scheme setting is a Quick Look preference.
    static let appearance: PreviewAppearance = .system
}

/// Renders bounded semantic inspection results into Quick Look thumbnail graphics.
enum ThumbnailRenderer {
    private static let maximumPixelDimension = 4_096
    private static let maximumPixelCount = 4_194_304
    private static let maximumLogicalDimension: CGFloat = 4_096

    /// Selects the format's preferred thumbnail representation: the catalog's `thumbnailStrategy`,
    /// falling back to source code for source formats and text lines otherwise
    /// (`FileTypeDefinition.effectiveThumbnailStrategy`). User representation choices are not consulted.
    static func semanticText(for inspection: PreviewInspectionResult) -> String? {
        switch inspection.formatDefinition?.effectiveThumbnailStrategy {
        case .table:
            if let csv = inspection.csvInspection?.table { return csv.thumbnailText() }
            if let listing = inspection.additionalInspection?.archiveListing {
                let names = listing.entries.prefix(8).map(\.displayName)
                let count = listing.entries.count
                let label = count == 1 ? "entry" : "entries"
                return (["ZIP · \(count) \(label)"] + names).joined(separator: "\n")
            }
            if let listing = inspection.additionalInspection?.tarArchiveListing {
                let count = listing.entries.count
                let label = count == 1 ? "entry" : "entries"
                return "TAR · \(count) \(label)"
            }
            return nil
        case .textLines:
            if inspection.formatDefinition?.id == .privacyManifest {
                guard let content = inspection.plistInspection?.content else { return "Privacy manifest · preview unavailable" }
                return ApplePrivacyManifestSummary.make(from: content) ?? "Privacy manifest · preview unavailable"
            }
            if inspection.formatDefinition?.id == .xcodeTestPlan {
                guard let content = inspection.jsonInspection?.content else { return "Xcode test plan · preview unavailable" }
                return XcodeTestPlanSummary.make(from: content) ?? "Xcode test plan · preview unavailable"
            }
            if inspection.formatDefinition?.id == .codeResources {
                guard let content = inspection.plistInspection?.content else { return "CodeResources · preview unavailable" }
                return AppleCodeResourcesSummary.make(from: content) ?? "CodeResources · preview unavailable"
            }
            if let security = inspection.additionalInspection?.securityInspection {
                if security.formatID == .spdxYAML, security.content == nil {
                    return "SPDX YAML · preview unavailable"
                }
                return security.content == nil ? nil : security.summary
            }
            if inspection.formatDefinition?.id == .xcstrings,
               let content = inspection.jsonInspection?.content {
                return AppleStringCatalogSummary.make(from: content)
            }
            if let certificates = inspection.additionalInspection?.certificateInspection?.certificates {
                return certificates.prefix(4).map { facts in
                    [facts.subjectSummary, facts.issuerSummary, facts.serialNumberHex]
                        .compactMap { $0 }.joined(separator: "\n")
                }.joined(separator: "\n\n")
            }
            return inspection.jsonInspection?.prettyText ?? inspection.yamlInspection?.prettyText
                ?? inspection.plistInspection?.prettyText ?? inspection.xmlInspection?.prettyText
                ?? inspection.markdownDocument?.renderedText
                ?? inspection.diffInspection?.rawText
        case .sourceCode, .none:
            return nil
        }
    }

    /// Converts the host's point dimensions to a finite pixel canvas within renderer limits.
    static func pixelSize(maximumSize: CGSize, scale: CGFloat) -> CGSize? {
        // Validate floats and hard pixel ceilings before integer conversion or bitmap allocation.
        guard maximumSize.width.isFinite, maximumSize.height.isFinite,
              scale.isFinite, scale > 0, scale <= 4,
              maximumSize.width > 0, maximumSize.height > 0 else { return nil }
        let width = ceil(maximumSize.width * scale)
        let height = ceil(maximumSize.height * scale)
        guard width.isFinite, height.isFinite,
              width <= CGFloat(maximumPixelDimension), height <= CGFloat(maximumPixelDimension),
              width * height <= CGFloat(maximumPixelCount) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Quick Look expects logical points here; its drawing context applies request.scale.
    /// Chooses a reply canvas that respects both requested bounds and the same pixel safety cap.
    static func replyContextSize(maximumSize: CGSize, minimumSize: CGSize, scale: CGFloat) -> CGSize? {
        guard let _ = pixelSize(maximumSize: maximumSize, scale: scale),
              maximumSize.width <= maximumLogicalDimension,
              maximumSize.height <= maximumLogicalDimension,
              minimumSize.width.isFinite, minimumSize.height.isFinite,
              minimumSize.width >= 0, minimumSize.height >= 0,
              minimumSize.width <= maximumSize.width,
              minimumSize.height <= maximumSize.height else { return nil }
        return maximumSize
    }

#if DEBUG
    /// Draws an unobtrusive build label for Debug Quick Look requests only.
    @discardableResult
    static func drawDebugBuildMarker(_ label: String, in context: CGContext, size: CGSize) -> Bool {
        guard size.width >= 44, size.height >= 22, label.utf8.count <= 80 else { return false }
        let font = CTFontCreateWithName("Menlo" as CFString, 7, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]))
        let textWidth = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
        let horizontalPadding: CGFloat = 3
        let verticalPadding: CGFloat = 2
        let markerWidth = textWidth + horizontalPadding * 2
        let markerHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + verticalPadding * 2
        guard markerWidth <= size.width - 8, markerHeight <= size.height - 8 else { return false }

        let origin = CGPoint(x: size.width - markerWidth - 4, y: 4)
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.68))
        context.fill(CGRect(origin: origin, size: CGSize(width: markerWidth, height: markerHeight)))
        context.textPosition = CGPoint(
            x: origin.x + horizontalPadding,
            y: origin.y + verticalPadding + CTFontGetDescent(font)
        )
        CTLineDraw(line, context)
        context.restoreGState()
        return true
    }
#endif

    /// Draws the prepared representation into the bounded bitmap context without opening the source again.
    static func render(
        analysis: TextAnalysis,
        sourceDocument: SourceDocument? = nil,
        semanticText: String? = nil,
        sourceConfiguration: SourceRenderConfiguration = ThumbnailRenderDefaults.source,
        appearance: PreviewAppearance = ThumbnailRenderDefaults.appearance,
        maximumSize: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        // Do not allocate a CoreGraphics surface until request geometry fits the pixel budget.
        guard let size = pixelSize(maximumSize: maximumSize, scale: scale) else { return nil }
        let pixelsWide = Int(size.width)
        let pixelsHigh = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let canvas = CGRect(origin: .zero, size: size)
        let drawingAppearance: NSAppearance
        switch appearance {
        case .system:
            drawingAppearance = NSAppearance.currentDrawing()
        case .light:
            drawingAppearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        case .dark:
            drawingAppearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        }
        let isDarkAppearance = drawingAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let preset = isDarkAppearance ? sourceConfiguration.darkTheme : sourceConfiguration.lightTheme
        let palette = isDarkAppearance ? sourceConfiguration.darkPalette : sourceConfiguration.lightPalette
        var backgroundColor: CGColor?
        var foregroundColor: CGColor?
        var tokenColors: [SyntaxTokenKind: CGColor] = [:]
        drawingAppearance.performAsCurrentDrawingAppearance {
            let background = SourceSyntaxColors.background(for: preset, palette: palette)
            let foreground = SourceSyntaxColors.foreground(for: preset, palette: palette)
            backgroundColor = background.cgColor
            foregroundColor = foreground.cgColor
            for kind in SyntaxTokenKind.allCases {
                tokenColors[kind] = SourceSyntaxColors.color(for: kind, preset: preset, palette: palette).cgColor
            }
        }
        guard let backgroundColor, let foregroundColor else { return nil }
        context.setFillColor(backgroundColor)
        context.fill(canvas)

        let resolvedScale = scale
        let pointSize = basePointSize(for: maximumSize)
        let pointInset: CGFloat = maximumSize.width > 384 && maximumSize.height > 384 ? 18 :
            (maximumSize.width <= 96 || maximumSize.height <= 96 ? 6 :
                (maximumSize.width <= 160 || maximumSize.height <= 160 ? 9 : 13))
        let pointSpacing: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 2 : 3
        let inset = pointInset * resolvedScale
        let contentRect = canvas.insetBy(dx: inset, dy: inset)
        guard !contentRect.isEmpty else {
            return context.makeImage()
        }
        guard !analysis.isBinary || semanticText != nil else { return nil }

        let fontSize = pointSize * resolvedScale
        let systemFont: NSFont
        switch sourceConfiguration.fontFamily {
        case "Menlo", "Monaco":
            systemFont = NSFont(name: sourceConfiguration.fontFamily, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        default:
            systemFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        let font = CTFontCreateWithName(systemFont.fontName as CFString, fontSize, nil)
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let fontLeading = CTFontGetLeading(font)
        let lineHeight = fontAscent + fontDescent + fontLeading
        let sourceText = semanticText ?? sourceDocument?.source ?? analysis.text
        let lines = Self.visibleSourceLines(
            in: sourceText,
            contentRect: contentRect,
            fontAscent: fontAscent,
            lineHeight: lineHeight,
            lineSpacing: pointSpacing * resolvedScale,
            maximumLines: ThumbnailRenderDefaults.maximumLines
        )
        guard !lines.lines.isEmpty else { return context.makeImage() }

        context.saveGState()
        context.clip(to: contentRect)
        let textX = contentRect.minX
        let textWidth = max(1, contentRect.width)
        let rowLimit = Self.lineCapacity(contentRect: contentRect, fontAscent: fontAscent, lineHeight: lineHeight,
                                         lineSpacing: pointSpacing * resolvedScale,
                                         maximumLines: ThumbnailRenderDefaults.maximumLines)
        // Same tab interval as Quick Look: space advance × effective tab width.
        let spaceAdvance = CTFontGetAdvancesForGlyphs(font, .horizontal,
                                                      [CTFontGetGlyphWithName(font, "space" as CFString)], nil, 1)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.defaultTabInterval = CGFloat(spaceAdvance) * CGFloat(sourceConfiguration.tabWidth)
        paragraphStyle.tabStops = []
        var rows = 0
        var baseline = contentRect.maxY - fontAscent
        let runs = semanticText == nil ? (sourceDocument?.highlighting.runs ?? []) : []
        var firstRelevantRun = 0
        for lineInfo in lines.lines where rows < rowLimit {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foregroundColor,
                .paragraphStyle: paragraphStyle
            ]
            let attributedLine = NSMutableAttributedString(string: lineInfo.text, attributes: attributes)
            let lineEnd = NSMaxRange(lineInfo.range)
            while firstRelevantRun < runs.count,
                  NSMaxRange(runs[firstRelevantRun].range) <= lineInfo.range.location {
                firstRelevantRun += 1
            }
            var runIndex = firstRelevantRun
            while runIndex < runs.count, runs[runIndex].range.location < lineEnd {
                let run = runs[runIndex]
                let intersection = NSIntersectionRange(run.range, lineInfo.range)
                if intersection.length > 0,
                   let color = tokenColors[run.kind] {
                    attributedLine.addAttribute(
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                        value: color,
                        range: NSRange(location: intersection.location - lineInfo.range.location, length: intersection.length)
                    )
                }
                runIndex += 1
            }
            for segment in Self.wrappedSegments(attributedLine, width: textWidth, configuration: sourceConfiguration,
                                                font: font, color: foregroundColor) {
                guard rows < rowLimit else { break }
                context.textPosition = CGPoint(x: textX, y: baseline)
                CTLineDraw(segment, context)
                baseline -= lineHeight + pointSpacing * resolvedScale
                rows += 1
            }
        }
        context.restoreGState()
        return context.makeImage()
    }


    /// Extracts text lines under both the fixed line cap and the thumbnail's visible geometry.
    static func renderedLines(
        for analysis: TextAnalysis,
        maximumSize: CGSize,
        scale: CGFloat
    ) -> [String] {
        // Bound source extraction by both the fixed line count and the actual thumbnail geometry.
        guard !analysis.isBinary else { return [] }
        guard let size = pixelSize(maximumSize: maximumSize, scale: scale) else { return [] }
        let resolvedScale = scale
        let pointSize: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 7 :
            (maximumSize.width <= 160 || maximumSize.height <= 160 ? 8.5 : 10)
        let pointInset: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 6 :
            (maximumSize.width <= 160 || maximumSize.height <= 160 ? 9 : 13)
        let pointSpacing: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 2 : 3
        let contentRect = CGRect(origin: .zero, size: size)
            .insetBy(dx: pointInset * resolvedScale, dy: pointInset * resolvedScale)
        guard !contentRect.isEmpty else { return [] }
        let fontSize = pointSize * resolvedScale
        let systemFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let font = CTFontCreateWithName(systemFont.fontName as CFString, fontSize, nil)
        return visibleSourceLines(
            in: analysis.text,
            contentRect: contentRect,
            fontAscent: CTFontGetAscent(font),
            lineHeight: CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font),
            lineSpacing: pointSpacing * resolvedScale,
            maximumLines: ThumbnailRenderDefaults.maximumLines
        ).lines.map(\.text)
    }

    /// Extracts source-document lines using the same size-dependent typography as the plain-text path.
    static func renderedLines(
        for sourceDocument: SourceDocument,
        maximumSize: CGSize,
        scale: CGFloat
    ) -> [String] {
        guard let size = pixelSize(maximumSize: maximumSize, scale: scale) else { return [] }
        let pointSize: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 7 :
            (maximumSize.width <= 160 || maximumSize.height <= 160 ? 8.5 : 10)
        let pointInset: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 6 :
            (maximumSize.width <= 160 || maximumSize.height <= 160 ? 9 : 13)
        let pointSpacing: CGFloat = maximumSize.width <= 96 || maximumSize.height <= 96 ? 2 : 3
        let contentRect = CGRect(origin: .zero, size: size)
            .insetBy(dx: pointInset * scale, dy: pointInset * scale)
        let fontSize = pointSize * scale
        let systemFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let font = CTFontCreateWithName(systemFont.fontName as CFString, fontSize, nil)
        return visibleSourceLines(
            in: sourceDocument.source,
            contentRect: contentRect,
            fontAscent: CTFontGetAscent(font),
            lineHeight: CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font),
            lineSpacing: pointSpacing * scale
        ).lines.map(\.text)
    }

    /// Text size in points for a request size: larger canvases get larger text, small icons smaller text.
    private static func basePointSize(for maximumSize: CGSize) -> CGFloat {
        maximumSize.width > 384 && maximumSize.height > 384 ? 14 :
            (maximumSize.width <= 96 || maximumSize.height <= 96 ? 7 :
                (maximumSize.width <= 160 || maximumSize.height <= 160 ? 8.5 : 10))
    }

    /// Creates the Core Text truncation token with the active font and foreground color.
    private static func attributedStringEllipsis(font: CTFont, color: CGColor) -> CTLine {
        let token = NSAttributedString(string: "…", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        return CTLineCreateWithAttributedString(token)
    }

    /// A source line plus its severity tint when the document is recognized as a log.
    struct SourceLine {
        let text: String
        let range: NSRange
    }

    /// The source lines selected for the bounded visible portion of a thumbnail.
    struct VisibleSourceLineSelection {
        let lines: [SourceLine]
        let scannedLineCount: Int
    }

    /// Number of text rows whose glyphs fit inside `contentRect`, capped by Maximum lines.
    static func lineCapacity(contentRect: CGRect, fontAscent: CGFloat, lineHeight: CGFloat,
                             lineSpacing: CGFloat, maximumLines: Int) -> Int {
        let verticalAdvance = lineHeight + lineSpacing
        guard lineHeight.isFinite, lineHeight > 0, verticalAdvance.isFinite, verticalAdvance > 0 else { return 0 }
        var rows = 0
        var baseline = contentRect.maxY - fontAscent
        while rows < min(maximumLines, 4_096) {
            let glyphBottom = baseline - max(0, lineHeight - fontAscent)
            guard glyphBottom >= contentRect.minY else { break }
            rows += 1
            baseline -= verticalAdvance
        }
        return rows
    }

    /// Lays out one logical line the way Quick Look does: Off truncates with "…", Soft wraps at the
    /// available width, Hard wraps at Line length columns (and at the width when that is narrower).
    private static func wrappedSegments(_ line: NSAttributedString, width: CGFloat,
                                        configuration: SourceRenderConfiguration,
                                        font: CTFont, color: CGColor) -> [CTLine] {
        let whole = CTLineCreateWithAttributedString(line)
        guard configuration.wrapMode != .off, line.length > 0 else {
            return [CTLineCreateTruncatedLine(whole, Double(width), .end,
                                              attributedStringEllipsis(font: font, color: color)) ?? whole]
        }
        let typesetter = CTTypesetterCreateWithAttributedString(line)
        var segments: [CTLine] = []
        var start = 0
        while start < line.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if configuration.wrapMode == .hard { count = min(count, max(1, configuration.lineLength)) }
            count = max(1, min(count, line.length - start))
            segments.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return segments
    }

    /// Selects the source lines that fit the target geometry while preserving logical line numbering.
    static func visibleSourceLines(
        in text: String,
        contentRect: CGRect,
        fontAscent: CGFloat,
        lineHeight: CGFloat,
        lineSpacing: CGFloat,
        maximumLines: Int = 4_096
    ) -> VisibleSourceLineSelection {
        // Stop scanning once the visible rectangle is filled; a thumbnail may represent a much larger source.
        guard !text.isEmpty, lineHeight.isFinite, lineHeight > 0,
              lineSpacing.isFinite, lineSpacing >= 0 else {
            return .init(lines: [], scannedLineCount: 0)
        }
        let lineLimit = lineCapacity(contentRect: contentRect, fontAscent: fontAscent, lineHeight: lineHeight,
                                     lineSpacing: lineSpacing, maximumLines: maximumLines)
        guard lineLimit > 0 else { return .init(lines: [], scannedLineCount: 0) }

        let source = text as NSString
        var result: [SourceLine] = []
        result.reserveCapacity(lineLimit)
        var scannedLineCount = 0
        var index = 0
        var lineStart = 0
        while index < source.length, result.count < lineLimit {
            let unit = source.character(at: index)
            guard unit == 10 || unit == 13 else {
                index += 1
                continue
            }
            let range = NSRange(location: lineStart, length: index - lineStart)
            scannedLineCount += 1
            // Preserve the existing fallback for documents beginning with a blank line.
            if result.isEmpty, range.length == 0 {
                return .init(lines: [], scannedLineCount: scannedLineCount)
            }
            result.append(.init(text: source.substring(with: range), range: range))
            index += 1
            if unit == 13, index < source.length, source.character(at: index) == 10 {
                index += 1
            }
            lineStart = index
        }
        if result.count < lineLimit, lineStart < source.length {
            let range = NSRange(location: lineStart, length: source.length - lineStart)
            scannedLineCount += 1
            result.append(.init(text: source.substring(with: range), range: range))
        }
        return .init(lines: result, scannedLineCount: scannedLineCount)
    }
}
