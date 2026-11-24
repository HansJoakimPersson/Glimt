import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import InspectorCore

final class MarkdownInspectorTests: XCTestCase {
    private func inspect(_ text: String) throws -> MarkdownDocument {
        let bytes = Data(text.utf8)
        return try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576))
    }

    private struct EmphasisTraits: Equatable {
        var bold = false
        var italic = false
        var code = false
    }

    private struct EmphasisSpan {
        let location: Int
        let length: Int
        let bold: Bool
        let italic: Bool
        let code: Bool
    }

    private struct EmphasisCase {
        let id: String
        let source: String
        let rendered: String
        let spans: [EmphasisSpan]
    }

    /// Unions overlapping style runs onto every UTF-16 code unit after validating all ranges.
    private func emphasisTraitVector(for runs: [MarkdownStyleRun], utf16Count: Int,
                                     invalidRangeMessage: String) -> [EmphasisTraits]? {
        for run in runs {
            let range = run.range
            let isValid = range.location >= 0 && range.length >= 0 && range.location != NSNotFound
                && range.location <= utf16Count && range.length <= utf16Count - range.location
            XCTAssertTrue(isValid, invalidRangeMessage)
            guard isValid else { return nil }
        }

        var traits = [EmphasisTraits](repeating: EmphasisTraits(), count: utf16Count)
        for run in runs {
            let range = run.range
            for index in range.location..<(range.location + range.length) {
                traits[index].bold = traits[index].bold || run.bold
                traits[index].italic = traits[index].italic || run.italic
                traits[index].code = traits[index].code || run.code
            }
        }
        return traits
    }

    private func expectedEmphasisTraitVector(utf16Count: Int, spans: [EmphasisSpan]) -> [EmphasisTraits]? {
        var traits = [EmphasisTraits](repeating: EmphasisTraits(), count: utf16Count)
        for span in spans {
            let isValid = span.location >= 0 && span.length >= 0 && span.location <= utf16Count
                && span.length <= utf16Count - span.location
            XCTAssertTrue(isValid, "Expected emphasis span is invalid")
            guard isValid else { return nil }
            for index in span.location..<(span.location + span.length) {
                traits[index].bold = traits[index].bold || span.bold
                traits[index].italic = traits[index].italic || span.italic
                traits[index].code = traits[index].code || span.code
            }
        }
        return traits
    }

    private func literalUTF16Occurrences(of literal: String, in text: NSString) -> [NSRange] {
        guard !literal.isEmpty else { return [] }
        var occurrences: [NSRange] = []
        var location = 0
        while location <= text.length {
            let searchRange = NSRange(location: location, length: text.length - location)
            let occurrence = text.range(of: literal, options: .literal, range: searchRange)
            guard occurrence.location != NSNotFound else { break }
            occurrences.append(occurrence)
            location = occurrence.location + 1
        }
        return occurrences
    }

    @MainActor
    func testCommonMarkEmphasisConformance() throws {
        let cases = [
            EmphasisCase(id: "em-star", source: "*alpha*", rendered: "alpha",
                         spans: [EmphasisSpan(location: 0, length: 5, bold: false, italic: true, code: false)]),
            EmphasisCase(id: "em-underscore", source: "_alpha_", rendered: "alpha",
                         spans: [EmphasisSpan(location: 0, length: 5, bold: false, italic: true, code: false)]),
            EmphasisCase(id: "strong-star", source: "**alpha**", rendered: "alpha",
                         spans: [EmphasisSpan(location: 0, length: 5, bold: true, italic: false, code: false)]),
            EmphasisCase(id: "strong-underscore", source: "__alpha__", rendered: "alpha",
                         spans: [EmphasisSpan(location: 0, length: 5, bold: true, italic: false, code: false)]),
            EmphasisCase(id: "strong-em", source: "***alpha***", rendered: "alpha",
                         spans: [EmphasisSpan(location: 0, length: 5, bold: true, italic: true, code: false)]),
            EmphasisCase(id: "nested-em", source: "**bold and *italic* end**", rendered: "bold and italic end",
                         spans: [EmphasisSpan(location: 0, length: 19, bold: true, italic: false, code: false),
                                 EmphasisSpan(location: 9, length: 6, bold: false, italic: true, code: false)]),
            EmphasisCase(id: "intraword-underscore", source: "a_b_c", rendered: "a_b_c", spans: []),
            EmphasisCase(id: "unmatched-em", source: "*alpha", rendered: "*alpha", spans: []),
            EmphasisCase(id: "unmatched-strong", source: "**alpha", rendered: "**alpha", spans: []),
            EmphasisCase(id: "escaped-star", source: "\\*alpha\\*", rendered: "*alpha*", spans: []),
            EmphasisCase(id: "code-protection", source: "`*alpha*`", rendered: "*alpha*",
                         spans: [EmphasisSpan(location: 0, length: 7, bold: false, italic: false, code: true)]),
            EmphasisCase(id: "surrogate-offsets", source: "😀 *alpha* **beta**", rendered: "😀 alpha beta",
                         spans: [EmphasisSpan(location: 3, length: 5, bold: false, italic: true, code: false),
                                 EmphasisSpan(location: 9, length: 4, bold: true, italic: false, code: false)])
        ]

        for testCase in cases {
            XCTContext.runActivity(named: testCase.id) { _ in
                do {
                    let document = try inspect(testCase.source)
                    XCTAssertTrue(document.raw.utf8.elementsEqual(testCase.source.utf8), "Raw UTF-8 mismatch")
                    XCTAssertTrue(document.diagnostics.isEmpty, "Diagnostics are not empty for \(testCase.id)")
                    guard let rendered = document.renderedText else {
                        XCTFail("Rendered text is absent for \(testCase.id)")
                        return
                    }
                    XCTAssertTrue(rendered.utf8.elementsEqual(testCase.rendered.utf8), "Rendered UTF-8 mismatch")

                    let utf16Count = rendered.utf16.count
                    guard let actual = emphasisTraitVector(for: document.runs, utf16Count: utf16Count,
                                                           invalidRangeMessage: "Style range is invalid for \(testCase.id)"),
                          let expected = expectedEmphasisTraitVector(utf16Count: testCase.rendered.utf16.count,
                                                                     spans: testCase.spans) else { return }
                    XCTAssertEqual(actual, expected)
                } catch {
                    XCTFail("Inspection failed for \(testCase.id)")
                }
            }
        }
    }

    func testCommonMarkEmphasisRealInput() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_MARKDOWN_EMPHASIS_REQUIRE_REAL_INPUT"] == "1"
        guard let path = environment["INSPECTORCORE_MARKDOWN_EMPHASIS_REAL_INPUT"], !path.isEmpty else {
            let message = "Markdown emphasis real input is not configured"
            if required { XCTFail(message) } else { throw XCTSkip(message) }
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            XCTFail("Markdown emphasis real input is unreadable")
            return
        }
        guard let source = String(data: data, encoding: .utf8) else {
            XCTFail("Markdown emphasis real input is not valid UTF-8")
            return
        }

        let hasAlignedMarker = source.contains("**Aligned.**")
        let hasPurposeMarker = source.contains("*product purpose*")
        XCTAssertTrue(hasAlignedMarker, "aligned-bold: source marker missing")
        XCTAssertTrue(hasPurposeMarker, "purpose-italic: source marker missing")
        guard hasAlignedMarker && hasPurposeMarker else { return }

        let document: MarkdownDocument
        do {
            document = try inspect(source)
        } catch {
            XCTFail("Markdown emphasis inspection failed")
            return
        }

        XCTAssertTrue(document.raw.utf8.elementsEqual(source.utf8), "Raw UTF-8 mismatch")
        XCTAssertTrue(document.diagnostics.isEmpty, "Markdown emphasis diagnostics are not empty")
        guard let rendered = document.renderedText else {
            XCTFail("Markdown emphasis rendered text is absent")
            return
        }

        guard let traits = emphasisTraitVector(for: document.runs, utf16Count: rendered.utf16.count,
                                               invalidRangeMessage: "Markdown emphasis style range is invalid") else { return }
        let renderedNSString = rendered as NSString
        let probes: [(id: String, rendered: String, expectedTrait: (EmphasisTraits) -> Bool, countMessage: String)] = [
            ("aligned-bold", "Aligned.", { $0.bold }, "aligned-bold: styled occurrence count mismatch"),
            ("purpose-italic", "product purpose", { $0.italic }, "purpose-italic: styled occurrence count mismatch")
        ]
        for probe in probes {
            let occurrences = literalUTF16Occurrences(of: probe.rendered, in: renderedNSString)
            let styledCount = occurrences.reduce(into: 0) { count, occurrence in
                let range = occurrence.location..<(occurrence.location + occurrence.length)
                if range.allSatisfy({ probe.expectedTrait(traits[$0]) }) { count += 1 }
            }
            XCTAssertEqual(styledCount, 1, probe.countMessage)
        }
    }

    private struct BoundaryTraits: Equatable {
        var headingLevel: Int?
        var bold = false
        var italic = false
        var strikethrough = false
        var code = false
    }

    private struct BoundaryCase {
        let id: String
        let source: String
        let rendered: String
        let headings: [MarkdownHeading]
        let headingRange: NSRange?
        let headingLevel: Int?
        let codeRange: NSRange?
    }

    /// Unions Boolean traits and heading levels over validated UTF-16 ranges.
    private func boundaryTraitVector(for runs: [MarkdownStyleRun], utf16Count: Int,
                                     invalidRangeMessage: String, conflictMessage: String) -> [BoundaryTraits]? {
        for run in runs {
            let range = run.range
            let isValid = range.location >= 0 && range.length >= 0 && range.location != NSNotFound
                && range.location <= utf16Count && range.length <= utf16Count - range.location
            XCTAssertTrue(isValid, invalidRangeMessage)
            guard isValid else { return nil }
        }

        var traits = [BoundaryTraits](repeating: BoundaryTraits(), count: utf16Count)
        for run in runs {
            let range = run.range
            for index in range.location..<(range.location + range.length) {
                if let level = run.headingLevel {
                    if let existing = traits[index].headingLevel, existing != level {
                        XCTFail(conflictMessage)
                        return nil
                    }
                    traits[index].headingLevel = level
                }
                traits[index].bold = traits[index].bold || run.bold
                traits[index].italic = traits[index].italic || run.italic
                traits[index].strikethrough = traits[index].strikethrough || run.strikethrough
                traits[index].code = traits[index].code || run.code
            }
        }
        return traits
    }

    private func expectedBoundaryTraitVector(utf16Count: Int, headingRange: NSRange?, headingLevel: Int?,
                                             codeRange: NSRange?) -> [BoundaryTraits]? {
        var traits = [BoundaryTraits](repeating: BoundaryTraits(), count: utf16Count)
        for (range, level, isCode) in [(headingRange, headingLevel, false), (codeRange, nil, true)] {
            guard let range else { continue }
            let isValid = range.location >= 0 && range.length >= 0 && range.location != NSNotFound
                && range.location <= utf16Count && range.length <= utf16Count - range.location
            XCTAssertTrue(isValid, "Expected boundary style range is invalid")
            guard isValid else { return nil }
            for index in range.location..<(range.location + range.length) {
                if let level { traits[index].headingLevel = level }
                if isCode { traits[index].code = true }
            }
        }
        return traits
    }

    /// Checks literal quote/list reconstruction without allowing either context to be reclassified as a top-level break.
    private func assertLiteralContainerPreservation(source: String, rendered expectedRendered: String,
                                                    quoteRange expectedQuoteRange: NSRange?,
                                                    expectedListParagraphs: [MarkdownListParagraph],
                                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try inspect(source)
        XCTAssertTrue(document.raw.utf8.elementsEqual(source.utf8), "Raw UTF-8 mismatch", file: file, line: line)
        XCTAssertTrue(document.diagnostics.isEmpty, "Diagnostics are not empty", file: file, line: line)
        guard let rendered = document.renderedText else {
            XCTFail("Rendered text is absent", file: file, line: line)
            return
        }
        XCTAssertTrue(rendered.utf8.elementsEqual(expectedRendered.utf8), "Rendered UTF-8 mismatch", file: file, line: line)
        XCTAssertTrue(document.headings.isEmpty, "Headings are not empty", file: file, line: line)
        XCTAssertNil(document.frontMatter, "Front matter is not nil", file: file, line: line)
        XCTAssertTrue(document.tables.isEmpty, "Tables are not empty", file: file, line: line)
        XCTAssertEqual(document.listParagraphs, expectedListParagraphs, "List paragraphs mismatch", file: file, line: line)
        XCTAssertTrue(document.alerts.isEmpty, "Alerts are not empty", file: file, line: line)
        XCTAssertTrue(document.definitionLists.isEmpty, "Definition lists are not empty", file: file, line: line)

        let utf16Count = rendered.utf16.count
        guard let actualTraits = boundaryTraitVector(for: document.runs, utf16Count: utf16Count,
                                                     invalidRangeMessage: "Style range is invalid",
                                                     conflictMessage: "Conflicting heading levels"),
              let expectedTraits = expectedBoundaryTraitVector(utf16Count: expectedRendered.utf16.count,
                                                               headingRange: nil, headingLevel: nil, codeRange: nil) else { return }
        XCTAssertEqual(actualTraits, expectedTraits, "Boundary traits are not default", file: file, line: line)

        var actualQuote = [Bool](repeating: false, count: utf16Count)
        for run in document.runs where run.quote {
            let range = run.range
            let isValid = range.location >= 0 && range.length >= 0 && range.location != NSNotFound
                && range.location <= utf16Count && range.length <= utf16Count - range.location
            XCTAssertTrue(isValid, "Quote style range is invalid", file: file, line: line)
            guard isValid else { return }
            for index in range.location..<(range.location + range.length) { actualQuote[index] = true }
        }
        var expectedQuote = [Bool](repeating: false, count: expectedRendered.utf16.count)
        if let range = expectedQuoteRange {
            let isValid = range.location >= 0 && range.length >= 0 && range.location != NSNotFound
                && range.location <= expectedQuote.count && range.length <= expectedQuote.count - range.location
            XCTAssertTrue(isValid, "Expected quote style range is invalid", file: file, line: line)
            guard isValid else { return }
            for index in range.location..<(range.location + range.length) { expectedQuote[index] = true }
        }
        XCTAssertEqual(actualQuote, expectedQuote, "Quote coverage mismatch", file: file, line: line)

        for run in document.runs {
            XCTAssertFalse(run.tableCell, "Table-cell trait is set", file: file, line: line)
            XCTAssertFalse(run.highlight, "Highlight trait is set", file: file, line: line)
            XCTAssertFalse(run.isSuperscript, "Superscript trait is set", file: file, line: line)
            XCTAssertFalse(run.isSubscript, "Subscript trait is set", file: file, line: line)
            XCTAssertFalse(run.hashtag, "Hashtag trait is set", file: file, line: line)
            XCTAssertNil(run.syntax, "Syntax token is set", file: file, line: line)
            XCTAssertNil(run.footnote, "Footnote role is set", file: file, line: line)
            XCTAssertNil(run.alert, "Alert kind is set", file: file, line: line)
        }
    }

    func testContainerBoundaryConformance() throws {
        let cases: [(id: String, source: String, rendered: String, quoteRange: NSRange?,
                     listParagraphs: [MarkdownListParagraph])] = [
            ("quote-to-paragraph", "> Q😀\n\nP", "> Q😀\n\nP", NSRange(location: 2, length: 3), []),
            ("unordered-to-paragraph", "- U\n\nP", "• U\n\nP", nil,
             [MarkdownListParagraph(range: NSRange(location: 0, length: 3), depth: 1, markerLength: 2, task: nil)]),
            ("ordered-to-paragraph", "3. O\n\nP", "3. O\n\nP", nil,
             [MarkdownListParagraph(range: NSRange(location: 0, length: 4), depth: 1, markerLength: 3, task: nil)]),
            ("quote-to-unordered", "> Q\n\n- U", "> Q\n\n• U", NSRange(location: 2, length: 1),
             [MarkdownListParagraph(range: NSRange(location: 5, length: 3), depth: 1, markerLength: 2, task: nil)]),
            ("unordered-to-quote", "- U\n\n> Q", "• U\n\n> Q", NSRange(location: 7, length: 1),
             [MarkdownListParagraph(range: NSRange(location: 0, length: 3), depth: 1, markerLength: 2, task: nil)]),
            ("lazy-quote", "> Q\ncontinued\n\nP", "> Q continued\n\nP", NSRange(location: 2, length: 11), []),
            ("lazy-list", "- U\ncontinued\n\nP", "• U continued\n\nP", nil,
             [MarkdownListParagraph(range: NSRange(location: 0, length: 13), depth: 1, markerLength: 2, task: nil)]),
            ("escaped-markers", "\\> Q\n\n\\- U\n\n\\+ V\n\n\\* W\n\n3\\. O",
             "> Q\n\n- U\n\n+ V\n\n* W\n\n3. O", nil, [])
        ]

        for testCase in cases {
            try assertLiteralContainerPreservation(source: testCase.source, rendered: testCase.rendered,
                                                  quoteRange: testCase.quoteRange,
                                                  expectedListParagraphs: testCase.listParagraphs)
        }
    }

    @MainActor
    func testThematicBreakConformance() throws {
        let separators = [
            (id: "thematic-break-hyphens", source: "---"),
            (id: "thematic-break-asterisks", source: "***"),
            (id: "thematic-break-underscores", source: "___"),
            (id: "thematic-break-spaced-asterisks", source: "* * *"),
            (id: "thematic-break-indented-asterisks", source: "   ***")
        ]
        var cases = separators.map { separator in
            BoundaryCase(id: separator.id,
                         source: "before\n\n\(separator.source)\n\nafter", rendered: "before\n\nafter",
                         headings: [], headingRange: nil, headingLevel: nil, codeRange: nil)
        }
        cases += [
            BoundaryCase(id: "thematic-break-no-blank-lines", source: "before\n***\nafter",
                         rendered: "before\n\nafter", headings: [], headingRange: nil, headingLevel: nil, codeRange: nil),
            BoundaryCase(id: "thematic-break-marker-suffix", source: "---x", rendered: "---x",
                         headings: [], headingRange: nil, headingLevel: nil, codeRange: nil),
            BoundaryCase(id: "thematic-break-escaped", source: #"\*\*\*"#, rendered: "***",
                         headings: [], headingRange: nil, headingLevel: nil, codeRange: nil),
            BoundaryCase(id: "thematic-break-inline-code", source: "`***`", rendered: "***",
                         headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: NSRange(location: 0, length: 3)),
            BoundaryCase(id: "thematic-break-escaped-with-blank-lines",
                         source: "before\n\n\\*\\*\\*\n\nafter", rendered: "before\n\n***\n\nafter",
                         headings: [], headingRange: nil, headingLevel: nil, codeRange: nil),
            BoundaryCase(id: "thematic-break-inline-code-with-blank-lines",
                         source: "before\n\n`***`\n\nafter", rendered: "before\n\n***\n\nafter",
                         headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: NSRange(location: 8, length: 3)),
            BoundaryCase(id: "setext-dash-precedence", source: "Title\n---", rendered: "Title",
                         headings: [MarkdownHeading(level: 2, title: "Title", anchor: "title", range: NSRange(location: 0, length: 5))],
                         headingRange: NSRange(location: 0, length: 5), headingLevel: 2, codeRange: nil),
            BoundaryCase(id: "setext-equals-precedence", source: "Title\n===", rendered: "Title",
                         headings: [MarkdownHeading(level: 1, title: "Title", anchor: "title", range: NSRange(location: 0, length: 5))],
                         headingRange: NSRange(location: 0, length: 5), headingLevel: 1, codeRange: nil),
            BoundaryCase(id: "setext-dash-precedence-with-following-paragraph", source: "Title\n---\n\nafter",
                         rendered: "Title\n\nafter",
                         headings: [MarkdownHeading(level: 2, title: "Title", anchor: "title", range: NSRange(location: 0, length: 5))],
                         headingRange: NSRange(location: 0, length: 5), headingLevel: 2, codeRange: nil),
            BoundaryCase(id: "indented-code-preserves-thematic-marker", source: "    ***", rendered: "***\n",
                         headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: NSRange(location: 0, length: 4)),
            BoundaryCase(id: "fenced-code-preserves-thematic-marker", source: "```\n***\n```", rendered: "***\n",
                         headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: NSRange(location: 0, length: 4)),
            BoundaryCase(id: "setext-equals-following-paragraph", source: "Title\n===\n\nafter",
                         rendered: "Title\n\nafter",
                         headings: [MarkdownHeading(level: 1, title: "Title", anchor: "title", range: NSRange(location: 0, length: 5))],
                         headingRange: NSRange(location: 0, length: 5), headingLevel: 1, codeRange: nil),
            BoundaryCase(id: "setext-three-space-underline", source: "Title\n   ---", rendered: "Title",
                         headings: [MarkdownHeading(level: 2, title: "Title", anchor: "title", range: NSRange(location: 0, length: 5))],
                         headingRange: NSRange(location: 0, length: 5), headingLevel: 2, codeRange: nil),
            BoundaryCase(id: "setext-invalid-underline-suffix", source: "Title\n---x", rendered: "Title ---x",
                         headings: [], headingRange: nil, headingLevel: nil, codeRange: nil),
            BoundaryCase(id: "indented-code-multiple-lines", source: "    alpha\n    beta", rendered: "alpha\nbeta\n",
                         headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: NSRange(location: 0, length: 11)),
            BoundaryCase(id: "indented-code-literal-markup", source: "    *literal*", rendered: "*literal*\n",
                         headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: NSRange(location: 0, length: 10)),
            BoundaryCase(id: "indented-code-cannot-interrupt-paragraph", source: "before\n    after",
                         rendered: "before after", headings: [], headingRange: nil, headingLevel: nil,
                         codeRange: nil)
        ]

        for testCase in cases {
            XCTContext.runActivity(named: testCase.id) { _ in
                do {
                    let document = try inspect(testCase.source)
                    XCTAssertTrue(document.raw.utf8.elementsEqual(testCase.source.utf8), "Raw UTF-8 mismatch")
                    XCTAssertTrue(document.diagnostics.isEmpty, "Diagnostics are not empty for \(testCase.id)")
                    XCTAssertNil(document.frontMatter, "Front matter is not nil for \(testCase.id)")
                    guard let rendered = document.renderedText else {
                        XCTFail("Rendered text is absent for \(testCase.id)")
                        return
                    }
                    XCTAssertTrue(rendered.utf8.elementsEqual(testCase.rendered.utf8), "Rendered UTF-8 mismatch")
                    XCTAssertEqual(document.headings, testCase.headings, "Headings mismatch for \(testCase.id)")
                    XCTAssertTrue(document.tables.isEmpty, "Tables are not empty for \(testCase.id)")
                    XCTAssertTrue(document.listParagraphs.isEmpty, "List paragraphs are not empty for \(testCase.id)")
                    XCTAssertTrue(document.alerts.isEmpty, "Alerts are not empty for \(testCase.id)")
                    XCTAssertTrue(document.definitionLists.isEmpty, "Definition lists are not empty for \(testCase.id)")

                    for run in document.runs {
                        XCTAssertFalse(run.quote, "Quote trait is set for \(testCase.id)")
                        XCTAssertFalse(run.tableCell, "Table-cell trait is set for \(testCase.id)")
                        XCTAssertFalse(run.highlight, "Highlight trait is set for \(testCase.id)")
                        XCTAssertFalse(run.isSuperscript, "Superscript trait is set for \(testCase.id)")
                        XCTAssertFalse(run.isSubscript, "Subscript trait is set for \(testCase.id)")
                        XCTAssertFalse(run.hashtag, "Hashtag trait is set for \(testCase.id)")
                        XCTAssertNil(run.syntax, "Syntax token is set for \(testCase.id)")
                        XCTAssertNil(run.footnote, "Footnote role is set for \(testCase.id)")
                        XCTAssertNil(run.alert, "Alert kind is set for \(testCase.id)")
                    }

                    let utf16Count = rendered.utf16.count
                    guard let actual = boundaryTraitVector(for: document.runs, utf16Count: utf16Count,
                                                           invalidRangeMessage: "Style range is invalid for \(testCase.id)",
                                                           conflictMessage: "Conflicting heading levels for \(testCase.id)"),
                          let expected = expectedBoundaryTraitVector(utf16Count: testCase.rendered.utf16.count,
                                                                     headingRange: testCase.headingRange,
                                                                     headingLevel: testCase.headingLevel,
                                                                     codeRange: testCase.codeRange) else { return }
                    XCTAssertEqual(actual, expected, "Style traits mismatch for \(testCase.id)")
                } catch {
                    XCTFail("Inspection failed for \(testCase.id)")
                }
            }
        }

        try assertLiteralContainerPreservation(source: #"> \*\*\*"#, rendered: "> ***",
                                               quoteRange: NSRange(location: 2, length: 3),
                                               expectedListParagraphs: [])
        try assertLiteralContainerPreservation(source: #"- \*\*\*"#, rendered: "• ***",
                                               quoteRange: nil,
                                               expectedListParagraphs: [MarkdownListParagraph(
                                                range: NSRange(location: 0, length: 5), depth: 1,
                                                markerLength: 2, task: nil)])
    }

    func testThematicBreakRealInput() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_MARKDOWN_BREAK_REQUIRE_REAL_INPUT"] == "1"
        guard let path = environment["INSPECTORCORE_MARKDOWN_BREAK_REAL_INPUT"], !path.isEmpty else {
            let message = "Markdown thematic-break real input is not configured"
            if required { XCTFail(message) } else { throw XCTSkip(message) }
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            XCTFail("Markdown thematic-break real input is unreadable")
            return
        }
        guard let source = String(data: data, encoding: .utf8) else {
            XCTFail("Markdown thematic-break real input is not UTF-8")
            return
        }

        let sourceBoundary = "The original intent is in `docs/reference/projektbeskrivning-glimt.md` (Swedish).\n\n---\n\n## Technical stack"
        let sourceOccurrences = literalUTF16Occurrences(of: sourceBoundary, in: source as NSString)
        guard sourceOccurrences.count == 1 else {
            XCTFail("Markdown thematic-break real input has unexpected source boundary")
            return
        }

        let document: MarkdownDocument
        do {
            document = try inspect(source)
        } catch {
            XCTFail("Markdown thematic-break real input inspection failed")
            return
        }

        XCTAssertTrue(document.raw.utf8.elementsEqual(source.utf8), "Markdown thematic-break Raw UTF-8 mismatch")
        XCTAssertTrue(document.diagnostics.isEmpty, "Markdown thematic-break diagnostics are not empty")
        guard let rendered = document.renderedText else {
            XCTFail("Markdown thematic-break Rendered text is absent")
            return
        }

        let renderedBoundary = "The original intent is in docs/reference/projektbeskrivning-glimt.md (Swedish).\n\nTechnical stack"
        let renderedNSString = rendered as NSString
        let renderedOccurrences = literalUTF16Occurrences(of: renderedBoundary, in: renderedNSString)
        XCTAssertEqual(renderedOccurrences.count, 1, "Markdown thematic-break rendered boundary count mismatch")
        guard renderedOccurrences.count == 1 else { return }

        let matchingHeadings = document.headings.filter { $0.level == 2 && $0.title == "Technical stack" && $0.anchor == "technical-stack" }
        XCTAssertEqual(matchingHeadings.count, 1, "Markdown thematic-break Technical stack heading count mismatch")

        guard let traits = boundaryTraitVector(for: document.runs, utf16Count: rendered.utf16.count,
                                               invalidRangeMessage: "Markdown thematic-break style range is invalid",
                                               conflictMessage: "Markdown thematic-break heading levels conflict") else { return }
        let boundary = renderedOccurrences[0]
        let sentence = "The original intent is in docs/reference/projektbeskrivning-glimt.md (Swedish)."
        let headingStart = boundary.location + boundary.length - "Technical stack".utf16.count
        let sentenceAndSeparators = boundary.location..<(headingStart)
        XCTAssertEqual(renderedNSString.substring(with: NSRange(location: boundary.location, length: sentence.utf16.count)),
                       sentence, "Markdown thematic-break rendered sentence mismatch")
        XCTAssertTrue(sentenceAndSeparators.allSatisfy { traits[$0].headingLevel == nil },
                      "Markdown thematic-break heading style covers preceding text or separators")
        let headingRange = headingStart..<(headingStart + "Technical stack".utf16.count)
        XCTAssertTrue(headingRange.allSatisfy { traits[$0].headingLevel == 2 },
                      "Markdown thematic-break heading style does not cover all heading units")
    }

    func testContainerBoundaryRealInput() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_MARKDOWN_CONTAINER_REQUIRE_REAL_INPUT"] == "1"
        guard let path = environment["INSPECTORCORE_MARKDOWN_CONTAINER_REAL_INPUT"], !path.isEmpty else {
            let message = "Markdown container real input is not configured"
            if required { XCTFail(message) } else { throw XCTSkip(message) }
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            XCTFail("Markdown container real input is unreadable")
            return
        }
        guard let source = String(data: data, encoding: .utf8) else {
            XCTFail("Markdown container real input is not UTF-8")
            return
        }

        let document: MarkdownDocument
        do {
            document = try inspect(source)
        } catch {
            XCTFail("Markdown container real input inspection failed")
            return
        }

        XCTAssertTrue(document.raw.utf8.elementsEqual(source.utf8), "Markdown container Raw UTF-8 mismatch")
        XCTAssertTrue(document.diagnostics.isEmpty, "Markdown container diagnostics are not empty")
        guard let rendered = document.renderedText else {
            XCTFail("Markdown container Rendered text is absent")
            return
        }

        let renderedNSString = rendered as NSString
        let renderedLength = renderedNSString.length
        func checkedRange(_ range: NSRange, _ message: String) -> Bool {
            let isValid = range.location >= 0 && range.length >= 0 && range.location != NSNotFound
                && range.location <= renderedLength && range.length <= renderedLength - range.location
            XCTAssertTrue(isValid, message)
            return isValid
        }

        for run in document.runs { _ = checkedRange(run.range, "Markdown container style range is invalid") }
        for table in document.tables {
            for cell in table.cells { _ = checkedRange(cell.range, "Markdown container table-cell range is invalid") }
        }
        for paragraph in document.listParagraphs {
            _ = checkedRange(paragraph.range, "Markdown container list-paragraph range is invalid")
        }
        for alert in document.alerts { _ = checkedRange(alert.range, "Markdown container alert range is invalid") }
        for definitionList in document.definitionLists {
            _ = checkedRange(definitionList.termRange, "Markdown container definition-term range is invalid")
            for range in definitionList.definitionRanges {
                _ = checkedRange(range, "Markdown container definition-body range is invalid")
            }
        }

        let opening = "Compact project context; keep this file under 16 KB. Update when architecture or status changes."
        let bullets = [
            "No media, audio/video codecs, CAD, 3D, DICOM, molecular, or music-notation formats.",
            "No shell commands, external preprocessors, language servers, script execution, or macros.",
            "No network access, remote JavaScript/CSS/images, CDNs, or automatic opening of URLs.",
            "No uncontrolled archive extraction; archives are listed, never unpacked freely.",
            "No GPL code copied into the codebase (Syntax Highlight, QLMarkdown, dotViewer are behavior references only).",
            "No legacy .qlgenerator plugins."
        ]
        let sourceBullets = [
            "No media, audio/video codecs, CAD, 3D, DICOM, molecular, or music-notation formats.",
            "No shell commands, external preprocessors, language servers, script execution, or macros.",
            "No network access, remote JavaScript/CSS/images, CDNs, or automatic opening of URLs.",
            "No uncontrolled archive extraction; archives are listed, never unpacked freely.",
            "No GPL code copied into the codebase (Syntax Highlight, QLMarkdown, dotViewer are behavior references only).",
            "No legacy `.qlgenerator` plugins."
        ]
        let headings = ["Current increment", "Project conventions"]

        func uniqueOccurrence(of value: String, diagnostic: String) -> NSRange? {
            let occurrences = literalUTF16Occurrences(of: value, in: renderedNSString)
            XCTAssertEqual(occurrences.count, 1, diagnostic)
            return occurrences.count == 1 ? occurrences[0] : nil
        }
        let openingRange = uniqueOccurrence(of: opening, diagnostic: "Markdown container opening quote occurrence mismatch")
        var bulletRanges: [NSRange] = []
        for (index, bullet) in bullets.enumerated() {
            let sourceCount = literalUTF16Occurrences(of: sourceBullets[index], in: source as NSString).count
            XCTAssertEqual(sourceCount, 1, "Markdown container source bullet occurrence mismatch at index \(index)")
            if let range = uniqueOccurrence(of: bullet, diagnostic: "Markdown container rendered bullet occurrence mismatch at index \(index)") {
                bulletRanges.append(range)
            }
        }
        guard let boundaryTraits = boundaryTraitVector(for: document.runs, utf16Count: renderedLength,
                                                       invalidRangeMessage: "Markdown container style range is invalid",
                                                       conflictMessage: "Markdown container heading levels conflict") else { return }
        var headingRanges: [(String, NSRange)] = []
        for heading in headings {
            XCTAssertEqual(literalUTF16Occurrences(of: "## \(heading)", in: source as NSString).count, 1,
                           "Markdown container source heading marker mismatch: \(heading)")
            let matchingHeadings = document.headings.filter { $0.title == heading }
            XCTAssertEqual(matchingHeadings.count, 1, "Markdown container heading metadata mismatch: \(heading)")
            let occurrences = literalUTF16Occurrences(of: heading, in: renderedNSString)
            let headingOccurrences = occurrences.filter { range in
                guard let modelHeading = matchingHeadings.first,
                      checkedRange(range, "Markdown container heading text range is invalid") else { return false }
                return (range.location..<(range.location + range.length))
                    .allSatisfy { boundaryTraits[$0].headingLevel == modelHeading.level }
            }
            XCTAssertEqual(headingOccurrences.count, 1,
                           "Markdown container rendered heading occurrence mismatch: \(heading)")
            if headingOccurrences.count == 1, let range = headingOccurrences.first {
                headingRanges.append((heading, range))
            }
        }

        var quoteCoverage = [Bool](repeating: false, count: renderedLength)
        for run in document.runs where run.quote {
            guard checkedRange(run.range, "Markdown container quote range is invalid") else { continue }
            for index in run.range.location..<(run.range.location + run.range.length) { quoteCoverage[index] = true }
        }
        if let openingRange {
            let prefixLength = 2
            let hasGeneratedPrefix = openingRange.location >= prefixLength
                && renderedNSString.substring(with: NSRange(location: openingRange.location - prefixLength,
                                                              length: prefixLength)) == "> "
            XCTAssertTrue(hasGeneratedPrefix, "Markdown container opening quote marker is missing")
            let expectedRange = NSRange(location: openingRange.location, length: openingRange.length)
            let covered = checkedRange(expectedRange, "Markdown container opening quote range is invalid")
                && expectedRange.length > 0
                && (expectedRange.location..<(expectedRange.location + expectedRange.length)).allSatisfy { quoteCoverage[$0] }
            XCTAssertTrue(covered, "Markdown container opening quote content is not fully quoted")
            if hasGeneratedPrefix {
                XCTAssertFalse(quoteCoverage[openingRange.location - prefixLength]
                               || quoteCoverage[openingRange.location - 1],
                               "Markdown container generated quote prefix is styled")
            }
            if hasGeneratedPrefix {
                let prefixStart = openingRange.location - prefixLength
                var precedingSeparatorStart = prefixStart
                while precedingSeparatorStart > 0 && renderedNSString.character(at: precedingSeparatorStart - 1) == 10 {
                    precedingSeparatorStart -= 1
                }
                XCTAssertGreaterThan(precedingSeparatorStart, 0,
                                     "Markdown container preceding separator is absent")
                XCTAssertTrue((precedingSeparatorStart..<prefixStart).allSatisfy { !quoteCoverage[$0] },
                              "Markdown container preceding separator is quoted")
            }

            let contentEnd = openingRange.location + openingRange.length
            var followingSeparatorEnd = contentEnd
            while followingSeparatorEnd < renderedLength && renderedNSString.character(at: followingSeparatorEnd) == 10 {
                followingSeparatorEnd += 1
            }
            XCTAssertGreaterThan(followingSeparatorEnd, contentEnd,
                                 "Markdown container opening quote separator is absent")
            XCTAssertTrue((contentEnd..<followingSeparatorEnd).allSatisfy { !quoteCoverage[$0] },
                          "Markdown container following separator is quoted")
        }

        func listParagraphs(matching contentRange: NSRange) -> [MarkdownListParagraph] {
            let start = contentRange.location - 2
            guard start >= 0 else { return [] }
            return document.listParagraphs.filter {
                $0.range == NSRange(location: start, length: contentRange.length + 2)
                    && $0.depth == 1 && $0.markerLength == 2 && $0.task == nil
            }
        }
        for (index, range) in bulletRanges.enumerated() {
            let paragraphs = listParagraphs(matching: range)
            XCTAssertEqual(paragraphs.count, 1, "Markdown container bullet paragraph mismatch at index \(index)")
            if range.location >= 2 {
                let start = range.location - 2
                XCTAssertEqual(renderedNSString.substring(with: NSRange(location: start, length: 2)), "• ",
                               "Markdown container generated bullet marker mismatch at index \(index)")
            }
            let paragraphRange = NSRange(location: range.location - 2, length: range.length + 2)
            if checkedRange(paragraphRange, "Markdown container expected bullet range is invalid") {
                let overlappingParagraphs = document.listParagraphs.filter {
                    NSIntersectionRange($0.range, paragraphRange).length > 0
                }
                XCTAssertEqual(overlappingParagraphs.count, 1,
                               "Markdown container bullet paragraph overlaps another list range at index \(index)")
                XCTAssertFalse((paragraphRange.location..<(paragraphRange.location + paragraphRange.length))
                    .contains(where: { quoteCoverage[$0] }),
                    "Markdown container bullet paragraph is quoted at index \(index)")
            }
        }

        for (heading, range) in headingRanges {
            let precedingRange = NSRange(location: max(0, range.location - 2), length: min(2, range.location))
            let coveredRange = NSRange(location: precedingRange.location, length: precedingRange.length + range.length)
            if checkedRange(coveredRange, "Markdown container heading boundary range is invalid") {
                XCTAssertFalse((coveredRange.location..<(coveredRange.location + coveredRange.length))
                    .contains(where: { quoteCoverage[$0] }),
                    "Markdown container heading or preceding separators are quoted: \(heading)")
                XCTAssertFalse(document.listParagraphs.contains(where: { NSIntersectionRange($0.range, coveredRange).length > 0 }),
                    "Markdown container heading or preceding separators overlap a list: \(heading)")
            }
            let precedingText = renderedNSString.substring(with: precedingRange)
            XCTAssertTrue(precedingText.isEmpty || precedingText == "\n\n",
                          "Markdown container heading does not follow the expected separator: \(heading)")
        }
    }

    // MARK: - Repository documentation

    private struct DocumentationManifestError: Error, CustomStringConvertible {
        let description: String
    }

    /// Required documents that the docs index cannot list itself: the index and the AI context entry point.
    private static let requiredDocumentation: Set<String> = ["README.md", "00-ai-context.md"]

    /// The project documents are local and untracked (only the public site in `docs/` is versioned), so a
    /// checkout without them skips the repository-document checks instead of failing.
    private func repositoryDocsDirectory() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("docs").path) {
            directory.deleteLastPathComponent()
        }
        let docs = directory.appendingPathComponent("docs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: docs.path) else { throw DocumentationManifestError(description: "docs/ not found") }
        guard FileManager.default.fileExists(atPath: docs.appendingPathComponent("README.md").path) else {
            throw XCTSkip("Local project documents are not present in this checkout")
        }
        return docs
    }

    /// Returns every top-level Markdown document after checking it against the docs index (`docs/README.md`).
    /// Each local top-level `.md` link in the index must resolve to an existing document, so a deleted, renamed or
    /// mistyped indexed document fails; documents added later are scanned without changing this test.
    private func documentationFiles(in docs: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let names = Set(files.map(\.lastPathComponent))
        let missingRequired = Self.requiredDocumentation.subtracting(names)
        guard missingRequired.isEmpty else {
            throw DocumentationManifestError(description: "Missing required documents: \(missingRequired.sorted())")
        }
        let index = try String(decoding: Data(contentsOf: docs.appendingPathComponent("README.md")), as: UTF8.self)
        let link = try NSRegularExpression(pattern: #"\]\(([A-Za-z0-9._-]+\.md)\)"#)
        let indexed = Set(link.matches(in: index, range: NSRange(index.startIndex..., in: index)).compactMap { match in
            Range(match.range(at: 1), in: index).map { String(index[$0]) }
        })
        guard !indexed.isEmpty else { throw DocumentationManifestError(description: "docs/README.md lists no documents") }
        let missingIndexed = indexed.subtracting(names)
        guard missingIndexed.isEmpty else {
            throw DocumentationManifestError(description: "docs/README.md links missing documents: \(missingIndexed.sorted())")
        }
        return files
    }

    func testRepositoryDocumentationManifestRejectsMissingDocuments() throws {
        let docs = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        try Data("# Context\n".utf8).write(to: docs.appendingPathComponent("00-ai-context.md"))
        try Data("# Vision\n".utf8).write(to: docs.appendingPathComponent("01-vision.md"))
        try Data("| [`01`](01-vision.md) | [`plans`](plans/a.md) |\n".utf8).write(to: docs.appendingPathComponent("README.md"))
        XCTAssertEqual(try documentationFiles(in: docs).map(\.lastPathComponent), ["00-ai-context.md", "01-vision.md", "README.md"])
        try Data("[`01`](01-vision.md) [`02`](02-gone.md)\n".utf8).write(to: docs.appendingPathComponent("README.md"))
        XCTAssertThrowsError(try documentationFiles(in: docs)) { XCTAssertTrue("\($0)".contains("02-gone.md")) }
        try Data("No links.\n".utf8).write(to: docs.appendingPathComponent("README.md"))
        XCTAssertThrowsError(try documentationFiles(in: docs))
        try FileManager.default.removeItem(at: docs.appendingPathComponent("00-ai-context.md"))
        XCTAssertThrowsError(try documentationFiles(in: docs)) { XCTAssertTrue("\($0)".contains("00-ai-context.md")) }
    }

    func testDefinitionListRepositoryRegression() throws {
        let files = try documentationFiles(in: repositoryDocsDirectory())
        for file in files {
            let bytes = try Data(contentsOf: file)
            let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
            let document = try MarkdownInspector.inspect(analysis: analysis)
            XCTAssertTrue(document.diagnostics.isEmpty, file.lastPathComponent)
            XCTAssertTrue(document.definitionLists.isEmpty, file.lastPathComponent)
        }
    }

    func testDefinitionListsRecognizeTopLevelGroupsAndUTF16Ranges() throws {
        let raw = "Café 😀 **term**\n: first *definition*\n: second `code`\n\nAfter.\n"
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText)
        let text = rendered as NSString
        XCTAssertEqual(document.definitionLists.count, 1)
        let group = try XCTUnwrap(document.definitionLists.first)
        XCTAssertEqual(text.substring(with: group.termRange), "Café 😀 term")
        XCTAssertEqual(group.definitionRanges.map { text.substring(with: $0) }, ["first definition", "second code"])
        XCTAssertTrue(document.runs.contains { $0.bold && NSIntersectionRange($0.range, group.termRange).length > 0 })
        XCTAssertTrue(document.runs.contains { $0.italic && text.substring(with: $0.range) == "definition" })
        XCTAssertTrue(document.runs.contains { $0.code && text.substring(with: $0.range) == "code" })
        XCTAssertTrue(rendered.hasSuffix("After."))
        for source in ["Term\n: valid\n: bad\n", "Term\n: valid\n    continuation\n", "Term\n: valid\nColon\n: not a group\n",
                       "Term\n: valid\n\n: ordinary\n"] {
            let result = try inspect(source)
            XCTAssertEqual(result.definitionLists.count, 1, source)
        }
        let noSecondGroup = try inspect("Term\n: valid\nordinary\nNext\n: second\n")
        XCTAssertEqual(noSecondGroup.definitionLists.count, 1)
        let noSecondText = try XCTUnwrap(noSecondGroup.renderedText) as NSString
        XCTAssertEqual(noSecondText.substring(with: noSecondGroup.definitionLists[0].termRange), "Term")
        XCTAssertTrue(try inspect("# Heading\n: not a definition\n").definitionLists.isEmpty)
        XCTAssertTrue(try inspect("```md\nTerm\n: code\n```\n").definitionLists.isEmpty)
        XCTAssertTrue(try inspect("- item\n\nTerm\n: valid\n").definitionLists.count == 1)
    }

    func testDefinitionListContinuedDefinitionKeepsStylesAndExactRaw() throws {
        let raw = "Café 😀 **term**\r\n: first line\r\n  continued *definition*\r\n\r\nAfter."
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText)
        let group = try XCTUnwrap(document.definitionLists.first)
        let text = rendered as NSString
        let definition = text.substring(with: group.definitionRanges[0])
        XCTAssertTrue(definition.contains("first line"), definition)
        XCTAssertTrue(definition.contains("continued definition"), definition)
        XCTAssertTrue(document.runs.contains { $0.italic && text.substring(with: $0.range) == "definition" })
        XCTAssertTrue(rendered.hasSuffix("After."), rendered)
    }

    func testDefinitionListPrepassBoundsCRLFAndOffsets() throws {
        let exact = (0..<256).map { index in
            "Term \(index)\n" + (0..<4).map { ": value \($0)\n" }.joined()
        }.joined(separator: "\n")
        let exactResult = try inspect(exact)
        XCTAssertEqual(exactResult.definitionLists.count, 256)
        XCTAssertEqual(exactResult.definitionLists.reduce(0) { $0 + $1.definitionRanges.count }, 1_024)

        let over = (0..<205).map { index in
            "Term \(index)\n" + (0..<5).map { ": value \($0)\n" }.joined()
        }.joined(separator: "\n")
        let overResult = try inspect(over)
        XCTAssertEqual(overResult.definitionLists.count, 204)
        XCTAssertEqual(overResult.definitionLists.reduce(0) { $0 + $1.definitionRanges.count }, 1_020)
        XCTAssertTrue(try XCTUnwrap(overResult.renderedText).contains(": value 0"))

        let groupOver = (0..<257).map { index in "Term \(index)\n: value\n" }.joined(separator: "\n")
        let groupOverResult = try inspect(groupOver)
        XCTAssertEqual(groupOverResult.definitionLists.count, 256)
        XCTAssertTrue(try XCTUnwrap(groupOverResult.renderedText).contains(": value"))

        let overflowWithContinuation = (0..<256).map { "Term \($0)\n: value\n" }.joined(separator: "\n")
            + "\nOverflow\n: first\n  continued\n"
        let overflowResult = try inspect(overflowWithContinuation)
        XCTAssertEqual(overflowResult.definitionLists.count, 256)
        XCTAssertTrue(try XCTUnwrap(overflowResult.renderedText).contains("continued"))


        let crlf = try inspect("😀 term\r\n:\tfirst\r\n:  second\r\n")
        XCTAssertEqual(crlf.definitionLists.count, 1)
        let crlfText = try XCTUnwrap(crlf.renderedText) as NSString
        XCTAssertEqual(crlfText.substring(with: crlf.definitionLists[0].termRange), "😀 term")
        XCTAssertEqual(crlf.definitionLists[0].definitionRanges.map { crlfText.substring(with: $0) }, ["first", "second"])
        let combining = try inspect("Cafe\u{301} 😀\n: value\n")
        let combiningText = try XCTUnwrap(combining.renderedText) as NSString
        XCTAssertEqual(combiningText.substring(with: combining.definitionLists[0].termRange), "Cafe\u{301} 😀")
        let eof = try inspect("Ending term\n: final definition")
        XCTAssertEqual(eof.definitionLists.count, 1)
        let eofText = try XCTUnwrap(eof.renderedText) as NSString
        XCTAssertEqual(eofText.substring(with: eof.definitionLists[0].definitionRanges[0]), "final definition")

        for marker in ["\u{E018}", "\u{E019}", "\u{E01A}", "\u{E021}"] {
            let collision = "- [ ] unchanged\n\nTerm \(marker)\n: literal\n"
            let collisionResult = try inspect(collision)
            XCTAssertTrue(collisionResult.definitionLists.isEmpty)
            let collisionText = try XCTUnwrap(collisionResult.renderedText)
            XCTAssertTrue(collisionText.contains(marker))
            XCTAssertTrue(collisionText.contains("[ ] unchanged"))
            XCTAssertTrue(collisionResult.listParagraphs.allSatisfy { $0.task == nil })
        }

        let withOffsets = "---\ntitle: hidden\n---\n# Heading\n\nTerm [^n]\n: body\n\n[^n]: note\n"
        let bytes = Data(withOffsets.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        let offsetResult = try MarkdownInspector.inspect(analysis: analysis, options: .init(frontMatter: .hide, tableOfContents: true))
        let offsetText = try XCTUnwrap(offsetResult.renderedText) as NSString
        XCTAssertTrue(offsetText.hasPrefix("Contents\n• Heading"))
        XCTAssertEqual(offsetText.substring(with: offsetResult.definitionLists[0].termRange), "Term [1]")
        XCTAssertEqual(offsetText.substring(with: offsetResult.definitionLists[0].definitionRanges[0]), "body")
        XCTAssertTrue(offsetResult.runs.contains { $0.footnote == .reference && NSIntersectionRange($0.range, offsetResult.definitionLists[0].termRange).length > 0 })
    }

    func testRejectedDefinitionCandidateRestoresExactSourceWithoutMarkers() throws {
        let source = "Term\n: - list"
        let bytes = Data(source.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        let document = try MarkdownInspector.inspect(analysis: analysis, options: .init(breakBehavior: .preserveSoftLines))

        XCTAssertEqual(document.raw, source)
        XCTAssertTrue(document.definitionLists.isEmpty)
        XCTAssertEqual(document.renderedText, source)
        XCTAssertFalse(try XCTUnwrap(document.renderedText).unicodeScalars.contains { (0xE000...0xE021).contains($0.value) })
    }

    func testDefinitionListFixture() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/markdown/definition-lists.md"))
        let raw = String(decoding: bytes, as: UTF8.self)
        let document = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count))
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText) as NSString
        XCTAssertEqual(document.definitionLists.count, 3)
        let terms = document.definitionLists.map { rendered.substring(with: $0.termRange) }
        XCTAssertEqual(terms, ["Styled term with Café 😀", "Recovery point objective (RPO)", "Recovery time objective (RTO)"])
        let rpoIndex = try XCTUnwrap(terms.firstIndex(of: "Recovery point objective (RPO)"))
        let rpo = document.definitionLists[rpoIndex]
        XCTAssertEqual(rpo.definitionRanges.map { rendered.substring(with: $0) },
                       ["Maximum acceptable data loss, measured as the time between the latest recoverable backup and an incident."])
        let rtoIndex = try XCTUnwrap(terms.firstIndex(of: "Recovery time objective (RTO)"))
        XCTAssertEqual(document.definitionLists[rtoIndex].definitionRanges.map { rendered.substring(with: $0) },
                       ["Target elapsed time for restoring the service after an incident; this includes validation before users regain access."])
        XCTAssertEqual(document.definitionLists[0].definitionRanges.map { rendered.substring(with: $0) },
                       ["A long definition uses italic, inline code and enough text to wrap at ordinary preview widths without changing Raw. Continued with emphasis and code.",
                        "A second definition keeps the group together."])

        let malformed = try inspect("Term\n: accepted\n:bad\n")
        XCTAssertEqual(malformed.definitionLists.count, 1)
        XCTAssertTrue(try XCTUnwrap(malformed.renderedText).contains(":bad"))
        let continued = try inspect("Term\n: accepted\n    continuation\n: later\n")
        XCTAssertEqual(continued.definitionLists.count, 1)
        XCTAssertTrue(try XCTUnwrap(continued.renderedText).contains("continuation"))
        XCTAssertTrue(try XCTUnwrap(continued.renderedText).contains(": later"))
        let blankColon = try inspect("Term\n: accepted\n\n: ordinary paragraph\n")
        XCTAssertEqual(blankColon.definitionLists.count, 1)
        XCTAssertTrue(try XCTUnwrap(blankColon.renderedText).contains(": ordinary paragraph"))
        let noBoundary = try inspect("Term\n: accepted\nOrdinary\nNext\n: not a second group\n")
        XCTAssertEqual(noBoundary.definitionLists.count, 1)
        XCTAssertEqual((try XCTUnwrap(noBoundary.renderedText) as NSString).substring(with: noBoundary.definitionLists[0].termRange), "Term")

        for content in ["# heading", "- list item", "> quote", "```swift", "| table | row |", "<div>", "---", "[reference]: target"] {
            let source = "Term\n: accepted\n: \(content)\n"
            let result = try inspect(source)
            XCTAssertEqual(result.definitionLists.count, 1, content)
            let output = try XCTUnwrap(result.renderedText)
            XCTAssertTrue(output.contains(": " + content), "Expected source colon preserved for \(content): \(output)")
            let resultText = output as NSString
            XCTAssertEqual(resultText.substring(with: result.definitionLists[0].definitionRanges[0]), "accepted")
        }
    }

    func testCanonicalMarkdownPreservesRawAndRendersBlocks() throws {
        for name in ["basic", "headings", "lists", "links", "blockquote", "inline-code", "fenced-code", "comprehensive"] {
            let bytes = try Data(contentsOf: fixtureURL(name == "comprehensive" ? "Showcase/markdown/markdown.md" : "Cases/markdown/\(name).md"))
            let raw = String(decoding: bytes, as: UTF8.self)
            let result = try inspect(raw)
            XCTAssertEqual(result.raw, raw, name)
            XCTAssertNotNil(result.renderedText, name)
            XCTAssertTrue(result.diagnostics.isEmpty, name)
        }
        let showcase = try String(decoding: Data(contentsOf: fixtureURL("Showcase/markdown/markdown.md")), as: UTF8.self)
        let showcaseDocument = try inspect(showcase)
        XCTAssertEqual(showcaseDocument.alerts.first(where: { $0.kind == .tip })?.title, "A short tip")
        XCTAssertEqual(showcaseDocument.raw, showcase)
        let headings = try inspect("# Title\n\n## Section\n\nText.\n")
        XCTAssertEqual(headings.renderedText, "Title\n\nSection\n\nText.")
        XCTAssertEqual(headings.runs.compactMap(\.headingLevel), [1, 2])
        let lists = try inspect("- one\n- two\n\n1. first\n2. second\n")
        XCTAssertTrue(try XCTUnwrap(lists.renderedText).contains("• one\n• two"))
        XCTAssertTrue(try XCTUnwrap(lists.renderedText).contains("1. first\n2. second"))
    }

    func testOptionsChangeCoreOutputWhileRawAndFencesRemainExact() throws {
        let source = "- [x] done\n\n~~removed~~\n\nfirst\nsecond  \nthird\n\n```swift\nlet text = \"~~code~~\"\n```\n"
        let bytes = Data(source.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        let baseline = try MarkdownInspector.inspect(analysis: analysis)
        let changed = try MarkdownInspector.inspect(analysis: analysis, options: .init(taskLists: false, strikethrough: false, breakBehavior: .preserveSoftLines))
        XCTAssertEqual(changed.raw, source)
        XCTAssertTrue(changed.renderedText?.contains("[x] done") == true)
        XCTAssertTrue(baseline.renderedText?.contains("☑ done") == true)
        XCTAssertFalse(changed.runs.contains(where: \.strikethrough))
        XCTAssertTrue(changed.renderedText?.contains("first\nsecond\nthird") == true)
        XCTAssertTrue(baseline.renderedText?.contains("first second\nthird") == true)
        XCTAssertTrue(changed.renderedText?.contains("\"~~code~~\"") == true)
        XCTAssertTrue(changed.runs.contains { $0.syntax == .keyword })
    }

    func testFrontMatterAndContentsAreBoundedSemanticOptions() throws {
        let raw = "---\ntitle: Local notes\ntags: [safe, local]\n---\n# Main **heading**\n\n## Next\n\n```markdown\n# Not a heading\n```\n"
        let bytes = Data(raw.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        for mode in MarkdownFrontMatterMode.allCases {
            let document = try MarkdownInspector.inspect(analysis: analysis, options: .init(frontMatter: mode, tableOfContents: true))
            XCTAssertEqual(document.raw, raw)
            XCTAssertNotNil(document.frontMatter)
            XCTAssertEqual(document.headings.map(\.title), ["Main heading", "Next"])
            let rendered = try XCTUnwrap(document.renderedText)
            XCTAssertTrue(rendered.contains("Contents\n• Main heading\n  • Next"))
            if mode == .hide { XCTAssertFalse(rendered.contains("Local notes")) }
            else { XCTAssertTrue(rendered.contains("Local notes")) }
            XCTAssertFalse(rendered.contains("---\ntitle:"))
            XCTAssertTrue(document.diagnostics.isEmpty)
        }
        let malformed = "---\nitems: [broken\n---\n# Body\n"
        let malformedBytes = Data(malformed.utf8)
        let result = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: malformedBytes, fileSize: malformedBytes.count, maximumBytes: malformedBytes.count), options: .init(frontMatter: .hide))
        XCTAssertEqual(result.raw, malformed)
        XCTAssertNil(result.renderedText)
        XCTAssertFalse(result.diagnostics.isEmpty)
        let noClosing = try inspect("---\nA thematic opening without a closing metadata fence.")
        XCTAssertNil(noClosing.frontMatter)
        XCTAssertNotNil(noClosing.renderedText)
    }

    func testFrontMatterVariantsAndMetadataContentsLimits() throws {
        for source in ["---\n---\n# Title", "---\r\ntitle: CRLF\r\n...\r\n# Title", "---\ntitle: Literal\n---\n# Title"] {
            let document = try inspect(source)
            XCTAssertEqual(document.raw, source)
            XCTAssertNotNil(document.frontMatter)
            XCTAssertTrue(document.renderedText?.contains("Title") == true)
            XCTAssertTrue(document.diagnostics.isEmpty)
        }
        for source in ["---\n" + String(repeating: "field: value\n", count: 1_500) + "---\n# Body",
                       "---\n" + String(repeating: "x: [", count: 20) + "0" + String(repeating: "]", count: 20) + "\n---\n# Body"] {
            let bytes = Data(source.utf8)
            let result = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count), options: .init(frontMatter: .hide))
            XCTAssertEqual(result.raw, source)
            XCTAssertNil(result.renderedText)
            XCTAssertFalse(result.diagnostics.isEmpty)
        }
        let manyHeadings = Array(repeating: "# Heading", count: 129).joined(separator: "\n\n")
        let bytes = Data(manyHeadings.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        XCTAssertNotNil(try MarkdownInspector.inspect(analysis: analysis).renderedText)
        XCTAssertNil(try MarkdownInspector.inspect(analysis: analysis, options: .init(tableOfContents: true)).renderedText)
        let fenced = try inspect("```yaml\n---\ntitle: Code only\n---\n```\n")
        XCTAssertNil(fenced.frontMatter)
        XCTAssertTrue(fenced.renderedText?.contains("title: Code only") == true)
    }

    func testTasksHaveExactlyOneMarkerAndOrdinaryBulletsRemain() throws {
        let raw = "- [ ] todo\n- [x] **done**\n- ordinary\n"
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.contains("☐ todo"))
        XCTAssertTrue(rendered.contains("☑ done"))
        XCTAssertTrue(rendered.contains("• ordinary"))
        XCTAssertFalse(rendered.contains("• ☐"))
        XCTAssertFalse(rendered.contains("• ☑"))
    }

    func testTaskMarkersAreRecognizedOnlyAtUnescapedItemStarts() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/task-lists.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.contains("☐ todo\n☑ done\n☑ upper"))
        XCTAssertTrue(rendered.contains("1. ☐ first\n2. ☑ second"))
        XCTAssertTrue(rendered.contains("• [ ] escaped\n• [ ]no space\n• [ ]"))
        XCTAssertTrue(rendered.contains("Paragraph [ ] text."))
        XCTAssertTrue(rendered.contains("- [x] fenced"))
        XCTAssertTrue(rendered.contains("> ☑ quoted"))
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xE002).contains($0.value) })
        XCTAssertEqual(document.listParagraphs.compactMap(\.task), [.open, .done, .done, .open, .done, .done, .open])
        let disabled = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: Data(raw.utf8), fileSize: raw.utf8.count, maximumBytes: raw.utf8.count),
                                                     options: .init(taskLists: false))
        XCTAssertTrue(disabled.renderedText?.contains("• [ ] todo\n• [x] done") == true)
        XCTAssertTrue(disabled.listParagraphs.allSatisfy { $0.task == nil })
    }

    func testNestedListsKeepDepthAndContinuationParagraphsHaveNoMarker() throws {
        let document = try inspect("1. parent\n   - [ ] child\n\n     more child\n   - sibling\n\n   more parent\n2. next\n")
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertEqual(rendered, "1. parent\n☐ child\nmore child\n• sibling\nmore parent\n2. next")
        let text = rendered as NSString
        XCTAssertEqual(document.listParagraphs.map { text.substring(with: $0.range) },
                       ["1. parent", "☐ child", "more child", "• sibling", "more parent", "2. next"])
        XCTAssertEqual(document.listParagraphs.map(\.depth), [1, 2, 2, 2, 1, 1])
        XCTAssertEqual(document.listParagraphs.map(\.markerLength), [3, 2, 0, 2, 0, 3])
    }

    func testSourceTaskPlaceholderCharactersDisableTaskMarkersButStayExact() throws {
        let document = try inspect("- [ ] todo \u{E000}\n")
        XCTAssertEqual(document.renderedText, "• [ ] todo \u{E000}")
        XCTAssertTrue(document.listParagraphs.allSatisfy { $0.task == nil })
    }

    func testGitHubAlertsNeedAnUppercaseMarkerAloneOnATopLevelQuoteLine() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/alerts.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        let text = rendered as NSString
        XCTAssertEqual(document.alerts.map(\.kind), [.note, .warning, .important])
        XCTAssertEqual(document.alerts.map { text.substring(with: $0.range) },
                       ["Note\nUseful information. Second line.", "Warning\nFirst paragraph.\n\n• item", "Important"])
        XCTAssertEqual(document.runs.filter { $0.alert != nil }.map { text.substring(with: $0.range) }, ["Note", "Warning", "Important"])
        XCTAssertTrue(document.runs.filter { $0.alert != nil }.allSatisfy(\.bold))
        let note = try XCTUnwrap(document.alerts.first).range
        XCTAssertFalse(document.runs.contains { NSIntersectionRange($0.range, note).length > 0 && $0.quote })
        XCTAssertTrue(rendered.contains("> [!TIP] Not alone on the line."))
        XCTAssertTrue(rendered.contains("> [!note] Lowercase is not an alert."))
        XCTAssertTrue(rendered.contains("> Plain quote."))
        XCTAssertTrue(rendered.contains("• > [!CAUTION] Inside a list stays a quote."))
        XCTAssertTrue(rendered.contains("> [!IMPORTANT]\n"))
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
    }

    func testAdmonitionGrammarAndWholeCandidateBoundaries() throws {
        let accepted = try inspect("!!! note\n    Body")
        XCTAssertEqual(accepted.raw, "!!! note\n    Body")
        XCTAssertEqual(accepted.alerts.map(\.kind), [.note])
        XCTAssertEqual(try XCTUnwrap(accepted.renderedText), "Note\nBody")
        let acceptedText = try XCTUnwrap(accepted.renderedText) as NSString
        XCTAssertEqual(acceptedText.substring(with: try XCTUnwrap(accepted.alerts.first).range), "Note\nBody")

        for body in ["     five", "      six", "       seven", "        eight", "\tTabbed"] {
            let document = try inspect("!!! note\n" + body)
            XCTAssertTrue(document.alerts.isEmpty, body)
        }
        XCTAssertTrue(try inspect("!!! note\n\n    Body").alerts.isEmpty,
                      "The first body line must immediately follow the opener.")

        let internalBlanks = try inspect("!!! note\n    A\n \t\n\n    B\n\n")
        XCTAssertEqual(internalBlanks.alerts.map(\.kind), [.note])
        let internalText = try XCTUnwrap(internalBlanks.renderedText) as NSString
        XCTAssertEqual(internalText.substring(with: try XCTUnwrap(internalBlanks.alerts.first).range), "Note\nA\nB")

        for source in ["!!! NOTE\n    Body", "!!!! note\n    Body", "\\!!! note\n    Body",
                       "!!! note Custom\n    Body", "!!! note\tCustom\n    Body",
                       "Before\n!!! note\n    Body"] {
            XCTAssertTrue(try inspect(source).alerts.isEmpty, source)
        }
        XCTAssertTrue(try inspect("!!! note\n    A\n    !!! unknown").alerts.isEmpty)
    }

    func testAdmonitionCustomTitlesAreBoundedAndPreserveSource() throws {
        let raw = "!!! warning \"Build status\"\n    Running slowly"
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.alerts.map(\.kind), [.warning])
        XCTAssertEqual(document.alerts.first?.title, "Build status")
        XCTAssertEqual(try XCTUnwrap(document.renderedText), "Build status\nRunning slowly")

        let longTitle = String(repeating: "x", count: 81)
        let malformed = try inspect("!!! warning \"\(longTitle)\"\n    Body")
        XCTAssertTrue(malformed.alerts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(malformed.renderedText).contains("!!! warning"))
        XCTAssertTrue(try inspect("!!! warning \"\"\n    Body").alerts.isEmpty)
        XCTAssertTrue(try inspect("!!! warning \"bad\tlabel\"\n    Body").alerts.isEmpty)
        XCTAssertTrue(try inspect("!!! warning \"bad \\\"label\"\n    Body").alerts.isEmpty)
        let boundaryTitle = String(repeating: "x", count: 80)
        let boundary = try inspect("!!! note \"\(boundaryTitle)\"\n    Body")
        XCTAssertEqual(boundary.alerts.first?.title, boundaryTitle)
        XCTAssertEqual(try XCTUnwrap(boundary.renderedText), "\(boundaryTitle)\nBody")
    }

    func testAdmonitionsRespectProtectedContextsAndFootnoteExtraction() throws {
        let rejected = [
            "```md\n!!! note\n    Body\n```",
            "    !!! note\n        Body",
            "> !!! note\n>     Body",
            "- item\n!!! note\n    Body",
            "> quote\n!!! note\n    Body",
            "<div>\n</div>\n!!! note\n    Body"
        ]
        for source in rejected { XCTAssertTrue(try inspect(source).alerts.isEmpty, source) }
        for source in ["- item\n\n!!! note\n    Body", "> quote\n\n!!! note\n    Body",
                       "<div>\n</div>\n\n!!! note\n    Body"] {
            XCTAssertEqual(try inspect(source).alerts.map(\.kind), [.note], source)
        }

        XCTAssertTrue(try inspect("[^n]: note\n!!! note\n    Body").alerts.isEmpty)
        XCTAssertEqual(try inspect("[^n]: note\n\n!!! note\n    Body").alerts.map(\.kind), [.note])
        XCTAssertEqual(try inspect("- item\n\nTerm\n: valid").definitionLists.count, 1)
    }

    func testAdmonitionsRejectUnsupportedBodyContentAsWholeCandidates() throws {
        let rejectedBodies = [
            "# heading", "- list", "- [ ] task", "> quote", "```swift", "    nested",
            "| A | B |", "<div>inline</div>", "***", "A\n---", "A\n===", "A | B\n--- | ---",
            ": alone", ":", "[id]: /target", " [id]: /target", "!!! unknown", "!!! note Custom"
        ]
        for body in rejectedBodies {
            let document = try inspect("!!! note\n    " + body.replacingOccurrences(of: "\n", with: "\n    "))
            XCTAssertTrue(document.alerts.isEmpty, body)
        }
        for body in ["Text <em>inline</em>", "Time: noon", "`code`", "\\!!! note"] {
            XCTAssertEqual(try inspect("!!! note\n    " + body).alerts.map(\.kind), [.note], body)
        }
        for ending in ["!!! unknown", ": alone", ":", "---", "===", "--- | ---", "<em>inline</em>", "[id]: /target"] {
            XCTAssertTrue(try inspect("!!! note\n    A\n" + ending).alerts.isEmpty, ending)
        }
        let outside = try inspect("!!! note\n    A\nOutside")
        let outsideText = try XCTUnwrap(outside.renderedText) as NSString
        XCTAssertEqual(outsideText.substring(with: try XCTUnwrap(outside.alerts.first).range), "Note\nA")
        XCTAssertTrue(outsideText.substring(from: NSMaxRange(try XCTUnwrap(outside.alerts.first).range)).contains("Outside"))
    }

    func testAdmonitionRangesCollisionCRLFAndCombinedAlertBound() throws {
        let source = "---\ntitle: sample\n---\n# Heading\n\n!!! warning\n    Body [^n]\n\n[^n]: footnote text\n"
        let bytes = Data(source.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
        let document = try MarkdownInspector.inspect(analysis: analysis, options: .init(frontMatter: .hide, tableOfContents: true))
        XCTAssertEqual(document.raw, source)
        let rendered = try XCTUnwrap(document.renderedText) as NSString
        let alert = try XCTUnwrap(document.alerts.first)
        XCTAssertEqual(alert.kind, .warning)
        XCTAssertEqual(rendered.substring(with: alert.range), "Warning\nBody [1]")
        XCTAssertTrue(document.runs.contains { $0.footnote == .reference && NSIntersectionRange($0.range, alert.range).length > 0 })
        XCTAssertFalse(document.runs.contains { $0.quote && NSIntersectionRange($0.range, alert.range).length > 0 })

        let crlf = try inspect("!!! tip\r\n    Café 😀\r\n")
        XCTAssertEqual(crlf.raw, "!!! tip\r\n    Café 😀\r\n")
        XCTAssertEqual(crlf.alerts.map(\.kind), [.tip])
        let crlfText = try XCTUnwrap(crlf.renderedText) as NSString
        XCTAssertEqual(crlfText.substring(with: try XCTUnwrap(crlf.alerts.first).range), "Tip\nCafé 😀")

        let collision = "[^n]: \u{E000}\n\n!!! note\n    Body"
        XCTAssertTrue(try inspect(collision).alerts.isEmpty)
        let exact = (0..<256).map { index -> String in
            let kind = MarkdownAlertKind.allCases[index % MarkdownAlertKind.allCases.count]
            if index.isMultiple(of: 2) { return "!!! \(kind.rawValue)\n    Body \(index)" }
            return "> [!\(kind.rawValue.uppercased())]\n> Body \(index)"
        }.joined(separator: "\n\n")
        let exactDocument = try inspect(exact)
        XCTAssertEqual(exactDocument.alerts.count, 256)
        let over = exact + "\n\n!!! tip\n    Overflow"
        let overDocument = try inspect(over)
        XCTAssertEqual(overDocument.raw, over)
        XCTAssertNil(overDocument.renderedText)
        XCTAssertEqual(overDocument.diagnostics.map(\.code), [.limitExceeded])
    }

    func testAdmonitionFixture() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/admonitions.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText)
        let expected = """
        Note
        A note with bold, italic, strike, code, highlight, x2, Café 😀 and [1].
        A second note paragraph with soft wrapping content.

        Tip
        A neighboring GitHub alert.

        Term beside the alerts

        a simple definition.

        Tip
        Tip body.

        Important
        Important body.

        Warning
        Warning body.

        Caution
        Caution body.

        !!! note Five spaces are rejected.

        !!! tip Six spaces are rejected.

        !!! important Seven spaces are rejected.

        !!! warning Eight spaces are rejected.

        !!! caution A leading tab is rejected.

        !!! NOTE Uppercase kind is rejected.

        !!!! note Extra marker is rejected.

        !!! note Custom Custom titles are rejected.

        !!! note
            Fenced content is protected.


        • item !!! note Lazy list continuation is protected.

        > quote !!! note Lazy quote continuation is protected.

        • item

        Note
        A blank boundary allows this.

        !!! note A candidate prefix. !!! unknown

        !!! warning A candidate prefix. : standalone colon rejects it.

        !!! caution A candidate prefix. A | B --- | ---

        Footnotes
        [1] A footnote beside the alerts.
        """
        XCTAssertEqual(rendered, expected)
        let text = rendered as NSString
        XCTAssertEqual(document.alerts.map(\.kind), [.note, .tip, .tip, .important, .warning, .caution, .note])
        XCTAssertEqual(document.alerts.map { text.substring(with: $0.range) }, [
            "Note\nA note with bold, italic, strike, code, highlight, x2, Café 😀 and [1].\nA second note paragraph with soft wrapping content.",
            "Tip\nA neighboring GitHub alert.", "Tip\nTip body.", "Important\nImportant body.",
            "Warning\nWarning body.", "Caution\nCaution body.", "Note\nA blank boundary allows this."
        ])
        XCTAssertEqual(document.runs.filter { $0.alert != nil }.map { text.substring(with: $0.range) },
                       ["Note", "Tip", "Tip", "Important", "Warning", "Caution", "Note"])
        XCTAssertTrue(document.runs.contains { $0.bold && text.substring(with: $0.range) == "bold" })
        XCTAssertTrue(document.runs.contains { $0.italic && text.substring(with: $0.range) == "italic" })
        XCTAssertTrue(document.runs.contains { $0.strikethrough && text.substring(with: $0.range) == "strike" })
        XCTAssertTrue(document.runs.contains { $0.code && text.substring(with: $0.range) == "code" })
        XCTAssertTrue(document.runs.contains { $0.highlight && text.substring(with: $0.range) == "highlight" })
        XCTAssertTrue(document.runs.contains { $0.isSuperscript && text.substring(with: $0.range) == "2" })
        XCTAssertTrue(document.runs.contains { $0.footnote == .reference && text.substring(with: $0.range) == "[1]" })
        XCTAssertEqual(document.definitionLists.count, 1)
        XCTAssertEqual(text.substring(with: document.definitionLists[0].termRange), "Term beside the alerts")

        let unsupported = ["!!! note\n     five", "!!! note\n\tTabbed", "!!! NOTE\n    Body",
                           "!!!! note\n    Body", "\\!!! note\n    Body", "!!! note Custom\n    Body",
                           "```md\n!!! note\n    Body\n```", "    !!! note\n        Body", "> !!! note\n>     Body",
                           "- item\n!!! note\n    Body", "> quote\n!!! note\n    Body",
                           "!!! note\n    A\n    !!! unknown", "!!! note\n    A\n    : alone",
                           "!!! note\n    A\n    A | B\n    --- | ---"]
        for source in unsupported {
            let result = try inspect(source)
            XCTAssertTrue(result.alerts.isEmpty, source)
            XCTAssertFalse(result.runs.contains { $0.alert != nil }, source)
        }
    }

    func testAdmonitionRepositoryRegression() throws {
        let files = try documentationFiles(in: repositoryDocsDirectory())
        for file in files {
            let bytes = try Data(contentsOf: file)
            let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)
            let document = try MarkdownInspector.inspect(analysis: analysis)
            XCTAssertTrue(document.diagnostics.isEmpty, file.lastPathComponent)
            XCTAssertTrue(document.alerts.isEmpty, file.lastPathComponent)
        }
    }

    func testHeadingsGetUniqueAnchorsAndExplicitIDsAreHidden() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/heading-anchors.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.headings.map(\.title), ["Getting Started", "Getting Started", "Getting Started!",
                                                       "Café & Co. — v2.0", "Custom spacing", "Not an anchor {#1bad}",
                                                       "Mid {#mid} text"])
        XCTAssertEqual(document.headings.map(\.anchor), ["start", "getting-started", "getting-started-1",
                                                        "café--co--v20", "custom-id", "not-an-anchor-1bad", "mid-mid-text"])
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.hasPrefix("Getting Started\n\nGetting Started\n\nGetting Started!"))
        XCTAssertTrue(rendered.contains("Custom spacing\n\n"))
        XCTAssertFalse(rendered.contains("{#start}"))
        XCTAssertFalse(rendered.contains("{#custom-id}"))
        XCTAssertTrue(rendered.contains("# Indented code {#code}"))
        XCTAssertTrue(rendered.contains("# Fenced {#fenced}"))
        XCTAssertTrue(rendered.contains("Paragraph with {#inline} braces."))
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        let contents = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: Data(raw.utf8), fileSize: raw.utf8.count,
                                                                                   maximumBytes: 1_048_576),
                                                     options: .init(tableOfContents: true))
        XCTAssertTrue(try XCTUnwrap(contents.renderedText).hasPrefix("Contents\n• Getting Started\n  • Getting Started\n"))
    }

    func testHeadingModelProvidesAllSixLevelsAndExcludesFencedSource() throws {
        let raw = "# First\n\n## Second\n\n### Café **Bold** _Title_\n\n#### Fourth\n\n##### Fifth\n\n###### Sixth\n\n```markdown\n# Not a heading\n## Neither this\n```\n"
        let document = try inspect(raw)

        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.headings.map(\.level), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(document.headings.map(\.title), ["First", "Second", "Café Bold Title", "Fourth", "Fifth", "Sixth"])
        XCTAssertEqual(document.headings.map(\.anchor), ["first", "second", "café-bold-title", "fourth", "fifth", "sixth"])
        XCTAssertFalse(document.headings.contains { $0.title.contains("Not a heading") || $0.title.contains("Neither") })
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.contains("# Not a heading\n## Neither this"), "Code examples stay rendered source and do not become navigable headings.")
    }

    func testTOCAndPercentEncodedFragmentsResolveUniqueUnicodeAnchors() throws {
        let raw = "# Café & Tea\n\n# Café & Tea\n\n## **Bold** *Heading* {#explicit-id}\n\n## Duplicate explicit {#explicit-id}\n\n[second](#caf%C3%A9--tea-1) [explicit](#explicit-id-1) [missing](#missing) [malformed](#bad%ZZ) [external](https://example.invalid)"
        let bytes = Data(raw.utf8)
        let document = try MarkdownInspector.inspect(
            analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count),
            options: .init(tableOfContents: true))
        XCTAssertEqual(document.raw, raw)
        let text = try XCTUnwrap(document.renderedText) as NSString
        XCTAssertEqual(document.headings.map(\.anchor), ["café--tea", "café--tea-1", "explicit-id", "explicit-id-1"])
        XCTAssertEqual(document.headings.map { text.substring(with: $0.range) }, ["Café & Tea", "Café & Tea", "Bold Heading", "Duplicate explicit"])
        XCTAssertEqual(document.navigationLinks.count, 6)
        XCTAssertTrue(document.navigationLinks.allSatisfy { NSMaxRange($0.range) <= text.length && NSMaxRange($0.targetRange) <= text.length })
        let links = document.navigationLinks.map { text.substring(with: $0.range) }
        XCTAssertTrue(links.contains("second"))
        XCTAssertTrue(links.contains("explicit"))
        XCTAssertFalse(links.contains("missing"))
        XCTAssertFalse(links.contains("malformed"))
        XCTAssertFalse(links.contains("external"))
        let second = try XCTUnwrap(document.navigationLinks.first { text.substring(with: $0.range) == "second" })
        XCTAssertEqual(text.substring(with: second.targetRange), "Café & Tea")
        XCTAssertEqual(document.headings.map(\.anchor).count, Set(document.headings.map(\.anchor)).count)
    }

    func testHighlightNeedsTightMarkersOnOneLineOutsideCode() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/highlight.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        let text = rendered as NSString
        XCTAssertTrue(rendered.contains("Plain marked text and two mixed words here."))
        XCTAssertEqual(document.runs.filter(\.highlight).map { text.substring(with: $0.range) }, ["marked", "two ", "mixed", " words", "cell"])
        XCTAssertTrue(try XCTUnwrap(document.runs.first { $0.highlight && text.substring(with: $0.range) == "mixed" }).italic)
        XCTAssertTrue(rendered.contains("Not marked: == spaced ==, ==open only, a===b, ==in code== and ==escaped==."))
        XCTAssertTrue(rendered.contains("a ==b"))
        XCTAssertTrue(rendered.contains("c== d"))
        XCTAssertTrue(rendered.contains("==fenced=="))
        XCTAssertFalse(document.runs.contains { $0.highlight && $0.code })
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        let heading = try inspect("# A ==b== c\n")
        XCTAssertEqual(heading.headings.map(\.title), ["A b c"])
        XCTAssertEqual(heading.renderedText, "A b c")
    }

    func testSuperscriptAndSubscriptUseCaretsOrGitHubTags() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/super-subscript.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        let text = rendered as NSString
        XCTAssertTrue(rendered.contains("E = mc2, H2O, xn and 19th century."))
        XCTAssertEqual(document.runs.filter(\.isSuperscript).map { text.substring(with: $0.range) }, ["2", "n", "th"])
        XCTAssertEqual(document.runs.filter(\.isSubscript).map { text.substring(with: $0.range) }, ["2"])
        XCTAssertTrue(try XCTUnwrap(document.runs.first { $0.isSuperscript && text.substring(with: $0.range) == "n" }).italic)
        XCTAssertTrue(rendered.contains("Not marked: 2^10, ^ spaced ^, a^b^, x^2^, <sup>open only, strike and a footnote-like [^x] [^y]."))
        XCTAssertTrue(rendered.contains("<SUP>upper</SUP> and empty <sup></sup> tags stay literal."))
        XCTAssertTrue(rendered.contains("x^2^ and H<sub>2</sub>O"))
        XCTAssertTrue(try XCTUnwrap(document.runs.first { text.substring(with: $0.range) == "strike" }).strikethrough)
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
    }

    func testWikilinksShowTheirLabelAndStayInert() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/wikilinks.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        let text = rendered as NSString
        XCTAssertTrue(rendered.contains("See Home, the setup guide and Notes#Part 2."))
        XCTAssertTrue(try XCTUnwrap(document.runs.first { text.substring(with: $0.range) == "setup" }).italic)
        XCTAssertTrue(rendered.contains("Not links: [[escaped]], ![[embed.png]], [[ ]], [[a|b|c]], [[unclosed and [[in code]]."))
        XCTAssertTrue(rendered.contains("[[Fenced|Label]]"))
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        XCTAssertEqual(try inspect("# Go to [[Page|Label]]\n").headings.map(\.title), ["Go to Label"])
    }

    func testHashtagsNeedALetterAfterWhitespaceOutsideCodeLinksAndHeadings() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/hashtags.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        let rendered = try XCTUnwrap(document.renderedText)
        let text = rendered as NSString
        XCTAssertTrue(rendered.contains("#start of a line, mid #project/alpha-2 and hot #tag in bold #strong."))
        XCTAssertEqual(document.runs.filter(\.hashtag).map { text.substring(with: $0.range) },
                       ["#start", "#project/alpha-2", "#tag", "#strong", "#listed", "#quoted", "#trailing"])
        XCTAssertTrue(try XCTUnwrap(document.runs.first { $0.hashtag && text.substring(with: $0.range) == "#tag" }).highlight)
        XCTAssertTrue(try XCTUnwrap(document.runs.first { $0.hashtag && text.substring(with: $0.range) == "#strong" }).bold)
        XCTAssertTrue(rendered.contains("Not tags: #123, a#b, #escaped, #code, link #linked, https://example.com/#frag, #trailing- and # spaced."))
        XCTAssertTrue(rendered.contains("#indented"))
        XCTAssertTrue(rendered.contains("#fenced"))
        XCTAssertFalse(document.runs.contains { $0.hashtag && ($0.code || $0.headingLevel != nil) })
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        XCTAssertEqual(document.headings.map(\.title), ["Hashtags #heading"])
        XCTAssertEqual(document.headings.map(\.anchor), ["hashtags-heading"])
    }

    func testFootnotesKeepDefinitionTextAndNumberByFirstReference() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/footnotes.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.contains("Alpha[1] and beta[2] again[1]."), rendered)
        XCTAssertTrue(rendered.contains("Undefined [^missing] stays literal."), rendered)
        XCTAssertTrue(rendered.contains("[^a]: inside a fence"), rendered)
        XCTAssertTrue(rendered.contains("[^a] in a code span is not a reference."), rendered)
        XCTAssertTrue(rendered.hasSuffix("Footnotes\n[1] Second note continues here.\n[2] First note."), rendered)
        XCTAssertFalse(rendered.contains("Never referenced"))
        let text = rendered as NSString
        let references = document.runs.filter { $0.footnote == .reference }.map { text.substring(with: $0.range) }
        XCTAssertEqual(references, ["[1]", "[2]", "[1]"])
        XCTAssertTrue(document.runs.contains { $0.footnote == .definition && $0.italic && text.substring(with: $0.range) == "note" })
        XCTAssertFalse(document.runs.contains { $0.footnote == .reference && $0.code })
    }

    func testFootnoteDefinitionsAreBounded() throws {
        let references = (0..<257).map { "x[^\($0)]" }.joined(separator: " ")
        let definitions = (0..<257).map { "[^\($0)]: note \($0)" }.joined(separator: "\n")
        let hostile = references + "\n\n" + definitions + "\n"
        let bounded = try inspect(hostile)
        XCTAssertNil(bounded.renderedText)
        XCTAssertEqual(bounded.diagnostics.first?.code, .limitExceeded)
        XCTAssertEqual(bounded.raw, hostile)
    }

    func testTableMetadataKeepsEmptyCellPositionsAndBoundsExpandedGrid() throws {
        let raw = "| Name | Value |\n|---|---|\n| | *two* |\n"
        let document = try inspect(raw)
        let table = try XCTUnwrap(document.tables.first)
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.cells.map(\.column), [0, 1, 1])
        XCTAssertEqual(table.cells.map(\.row), [0, 0, 1])
        XCTAssertEqual(document.raw, raw)
        let wideHeader = "|" + Array(repeating: "x", count: 64).joined(separator: "|") + "|\n"
        let separator = "|" + Array(repeating: "---", count: 64).joined(separator: "|") + "|\n"
        let row = "|x" + String(repeating: "|", count: 64) + "\n"
        let hostile = wideHeader + separator + String(repeating: row, count: 130)
        let bounded = try inspect(hostile)
        XCTAssertNil(bounded.renderedText)
        XCTAssertEqual(bounded.diagnostics.first?.code, .limitExceeded)
        XCTAssertEqual(bounded.raw, hostile)
    }

    func testCodeStylingAndGFM() throws {
        let code = try inspect("```swift\nlet value = 42\n```\n")
        XCTAssertTrue(code.runs.contains { $0.syntax == .keyword })
        XCTAssertTrue(code.runs.contains { $0.syntax == .number })
        XCTAssertTrue(code.runs.contains( where: \.code))
        let gfm = try inspect(String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/gfm.md")), as: UTF8.self))
        XCTAssertTrue(gfm.runs.contains(where: \.strikethrough))
        let text = try XCTUnwrap(gfm.renderedText)
        XCTAssertTrue(text.contains("☐ todo"))
        XCTAssertTrue(text.contains("☑ done"))
        XCTAssertTrue(text.contains("Name\tValue\none\ttwo"), text)
    }

    func testNewSourceLanguagesHighlightInsideMarkdownFences() throws {
        let cases: [(String, String)] = [
            ("objective-c", "@interface Greeter : NSObject\nint answer = 42;\n@end"),
            ("perl", "my $answer = 42;"),
            ("r", "answer <- function() 42"),
            ("scala", "object Main { val answer = 42 }"),
            ("julia", "function answer() return 42 end")
        ]
        for (language, code) in cases {
            let document = try inspect("```\(language)\n\(code)\n```\n")
            XCTAssertTrue(document.runs.contains { $0.code }, language)
            XCTAssertTrue(document.runs.contains { $0.syntax == .keyword }, language)
            XCTAssertTrue(document.runs.contains { $0.syntax == .number }, language)
        }
    }

    func testMermaidFlowchartModelAndUnsupportedFenceFallback() throws {
        let raw = """
# Flow

```mermaid
flowchart TD
A[Start] --> B{Ready?}
B -->|Yes| C(Continue)
B -.->|No| D[<script>literal</script>]
```

```mermaid
classDiagram
  class Unsupported
```

After
"""
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.mermaidBlocks.count, 2)
        let supported = try XCTUnwrap(document.mermaidBlocks.first)
        XCTAssertEqual(supported.diagnostic, nil)
        let flowchart = try XCTUnwrap(supported.flowchart)
        XCTAssertEqual(flowchart.direction, .topDown)
        XCTAssertEqual(flowchart.nodes.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(flowchart.nodes.map(\.label), ["Start", "Ready?", "Continue", "<script>literal</script>"])
        XCTAssertEqual(flowchart.nodes.map(\.shape), [.rectangle, .diamond, .rounded, .rectangle])
        XCTAssertEqual(flowchart.edges.map(\.label), [nil, "Yes", "No"])
        XCTAssertEqual(flowchart.edges.map(\.style), [.arrow, .arrow, .dottedArrow])
        let layout = try XCTUnwrap(supported.layout)
        XCTAssertEqual(layout.nodeFrames.count, flowchart.nodes.count)
        XCTAssertLessThanOrEqual(layout.size.width, MermaidFlowchartLayoutEngine.maximumWidth)
        XCTAssertLessThanOrEqual(layout.size.height, MermaidFlowchartLayoutEngine.maximumHeight)
        for leftIndex in flowchart.nodes.indices {
            let left = try XCTUnwrap(layout.nodeFrames[flowchart.nodes[leftIndex].id])
            for rightIndex in flowchart.nodes.indices where rightIndex > leftIndex {
                let right = try XCTUnwrap(layout.nodeFrames[flowchart.nodes[rightIndex].id])
                let overlaps = left.x < right.x + right.width && right.x < left.x + left.width
                    && left.y < right.y + right.height && right.y < left.y + left.height
                XCTAssertFalse(overlaps, "Flowchart node frames must not overlap.")
            }
        }
        let rendered = try XCTUnwrap(document.renderedText) as NSString
        XCTAssertTrue(rendered.substring(with: supported.range).contains("A[Start]"))

        let unsupported = try XCTUnwrap(document.mermaidBlocks.last)
        XCTAssertEqual(unsupported.classDiagram?.classes.map(\.id), ["Unsupported"])
        XCTAssertNil(unsupported.diagnostic)
        XCTAssertTrue(try XCTUnwrap(document.renderedText).hasSuffix("After"))

        let reversed = try inspect("```mermaid\ngraph RL\nA[東京 🚀] ==> B\nB --- C\n```\n")
        XCTAssertEqual(reversed.mermaidBlocks.first?.flowchart?.direction, .rightLeft)
        XCTAssertEqual(reversed.mermaidBlocks.first?.flowchart?.edges.map(\.style), [.thickArrow, .line])
    }

    func testMermaidFlowchartParserRejectsMalformedCyclicAndOverLimitGraphs() throws {
        let malformed = try inspect("```mermaid\nflowchart LR\nA[Start] -->\n```\n")
        XCTAssertEqual(malformed.mermaidBlocks.first?.diagnostic, .malformedSyntax)
        XCTAssertNil(malformed.mermaidBlocks.first?.flowchart)

        let cyclic = try inspect("```mermaid\nflowchart TD\nA --> B\nB --> A\n```\n")
        XCTAssertEqual(cyclic.mermaidBlocks.first?.diagnostic, .unsupportedLayout)
        XCTAssertNil(cyclic.mermaidBlocks.first?.flowchart)

        let nodes = (0...64).map { "N\($0)[Node \($0)]" }.joined(separator: "\n")
        let overLimit = try inspect("```mermaid\nflowchart TD\n\(nodes)\n```\n")
        XCTAssertEqual(overLimit.mermaidBlocks.first?.diagnostic, .resourceLimit)
        XCTAssertNil(overLimit.mermaidBlocks.first?.flowchart)

        let tooManyEdges = (0...128).map { _ in "A --> B" }.joined(separator: "\n")
        let overEdgeLimit = try inspect("```mermaid\nflowchart TD\n\(tooManyEdges)\n```\n")
        XCTAssertEqual(overEdgeLimit.mermaidBlocks.first?.diagnostic, .resourceLimit)
        XCTAssertNil(overEdgeLimit.mermaidBlocks.first?.flowchart)

        let oversizedSource = try inspect("```mermaid\nflowchart TD\n%%\(String(repeating: "x", count: 8_200))\n```\n")
        XCTAssertEqual(oversizedSource.mermaidBlocks.first?.diagnostic, .resourceLimit)
        XCTAssertNil(oversizedSource.mermaidBlocks.first?.flowchart)

        let deepFlow = (0..<21).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        let tooDeep = try inspect("```mermaid\nflowchart TD\n\(deepFlow)\n```\n")
        XCTAssertEqual(tooDeep.mermaidBlocks.first?.diagnostic, .resourceLimit)
        XCTAssertNil(tooDeep.mermaidBlocks.first?.flowchart)

        let manyDiagrams = (0..<17).map { _ in "```mermaid\nflowchart TD\nA --> B\n```" }.joined(separator: "\n\n")
        let boundedDiagrams = try inspect(manyDiagrams)
        XCTAssertEqual(boundedDiagrams.raw, manyDiagrams)
        XCTAssertEqual(boundedDiagrams.mermaidBlocks.count, 16)
    }

    func testMermaidFlowchartParserChecksCancellationBetweenStatements() throws {
        var checkpoints = 0
        XCTAssertThrowsError(try MermaidFlowchartParser.parse("flowchart TD\nA --> B", checkpoint: {
            checkpoints += 1
            if checkpoints == 2 { throw CancellationError() }
        })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMermaidSequenceDiagramModelAndUnsupportedFallback() throws {
        let longMessage = String(repeating: "response ", count: 10).trimmingCharacters(in: .whitespaces)
        let raw = """
```mermaid
sequenceDiagram
participant Alice as Client with a deliberately long display label
participant Server
Alice->>Server: Request 東京 🚀
Server-->>Alice: \(longMessage)
```

```mermaid
sequenceDiagram
Alice->>Server: Before
alt accepted
  Server-->>Alice: After
end
```
"""
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.mermaidBlocks.count, 2)
        let supported = try XCTUnwrap(document.mermaidBlocks.first)
        let sequence = try XCTUnwrap(supported.sequenceDiagram)
        XCTAssertEqual(sequence.participants.map(\.id), ["Alice", "Server"])
        XCTAssertEqual(sequence.participants.map(\.label), ["Client with a deliberately long display label", "Server"])
        XCTAssertEqual(sequence.messages.map(\.text), ["Request 東京 🚀", longMessage])
        XCTAssertEqual(sequence.messages.map(\.style), [.solidArrow, .dashedArrow])
        let layout = try XCTUnwrap(supported.sequenceLayout)
        XCTAssertEqual(layout.participantCenters.count, sequence.participants.count)
        XCTAssertEqual(layout.messageYPositions.count, sequence.messages.count)
        XCTAssertTrue(zip(layout.messageYPositions, layout.messageYPositions.dropFirst()).allSatisfy(<))
        XCTAssertGreaterThan(layout.participantHeaderHeights["Alice"] ?? 0, 32)
        XCTAssertGreaterThan(layout.messageLabelHeights[1], 16)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.contains("Alice->>Server"), "Core retains source until the native renderer replaces it.")
        XCTAssertTrue(rendered.contains("alt accepted"))
        XCTAssertEqual(document.mermaidBlocks.last?.diagnostic, .unsupportedSyntax)
        XCTAssertNil(document.mermaidBlocks.last?.sequenceDiagram)
    }

    func testMermaidSequenceDiagramLimitsAndCancellation() throws {
        let manyMessages = (0..<129).map { "A->>B: Message \($0)" }.joined(separator: "\n")
        let oversized = try inspect("```mermaid\nsequenceDiagram\n\(manyMessages)\n```\n")
        XCTAssertEqual(oversized.mermaidBlocks.first?.diagnostic, .resourceLimit)
        XCTAssertNil(oversized.mermaidBlocks.first?.sequenceDiagram)

        let participants = (0..<33).map { "participant P\($0)" }.joined(separator: "\n")
            + "\nP0->>P1: Start"
        let tooManyParticipants = try inspect("```mermaid\nsequenceDiagram\n\(participants)\n```\n")
        XCTAssertEqual(tooManyParticipants.mermaidBlocks.first?.diagnostic, .resourceLimit)
        XCTAssertNil(tooManyParticipants.mermaidBlocks.first?.sequenceDiagram)

        var checkpoints = 0
        XCTAssertThrowsError(try MermaidSequenceParser.parse("sequenceDiagram\nA->>B: Hi", checkpoint: {
            checkpoints += 1
            if checkpoints == 1 { throw CancellationError() }
        })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMermaidClassAndStateModelsBoundsAndFallbacks() throws {
        let raw = """
```mermaid
classDiagram
class Order {
  +String résumé
  +submit() 🚀
}
Order <|-- SpecialOrder : inherits
Order --> Account : billed to
```

```mermaid
stateDiagram-v2
[*] --> Idle
Idle --> Active : démarrer 🚀
Active --> [*] : terminé
```

```mermaid
stateDiagram-v2
state Parent {
  Child --> Other
}
```
"""
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertEqual(document.mermaidBlocks.count, 3)
        let classes = try XCTUnwrap(document.mermaidBlocks[0].classDiagram)
        XCTAssertEqual(classes.classes.map(\.id), ["Order", "SpecialOrder", "Account"])
        XCTAssertEqual(classes.classes[0].members.map(\.text), ["+String résumé", "+submit() 🚀"])
        XCTAssertEqual(classes.relations.map(\.label), ["inherits", "billed to"])
        XCTAssertEqual(document.mermaidBlocks[0].classLayout?.classFrames.count, 3)
        let longRelationLabel = "a deliberately long relation label that wraps at narrow widths"
        let longLabels = try inspect("```mermaid\nclassDiagram\nclass A {\n +\(String(repeating: "displayName", count: 5))\n}\nA --> B : \(longRelationLabel)\n```\n")
        XCTAssertEqual(longLabels.mermaidBlocks.first?.classDiagram?.relations.first?.label, longRelationLabel)
        XCTAssertGreaterThan(longLabels.mermaidBlocks.first?.classLayout?.size.height ?? 0, 200)
        let states = try XCTUnwrap(document.mermaidBlocks[1].stateDiagram)
        XCTAssertEqual(states.edges.map(\.label), [nil, "démarrer 🚀", "terminé"])
        XCTAssertNotNil(document.mermaidBlocks[1].layout)
        XCTAssertEqual(document.mermaidBlocks[2].diagnostic, .unsupportedSyntax)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.contains("classDiagram"))
        XCTAssertTrue(rendered.contains("state Parent"))
        let invalidClass = try inspect("```mermaid\nclassDiagram\nclass A {\n +name\n```\n")
        XCTAssertEqual(invalidClass.mermaidBlocks.first?.diagnostic, .malformedSyntax)
        let manyClasses = (0..<33).map { "class C\($0)" }.joined(separator: "\n")
        let largeClass = try inspect("```mermaid\nclassDiagram\n\(manyClasses)\n```\n")
        XCTAssertEqual(largeClass.mermaidBlocks.first?.diagnostic, .resourceLimit)
        let deepMembers = (0..<25).map { " member\($0)" }.joined(separator: "\n")
        let largeClassBody = try inspect("```mermaid\nclassDiagram\nclass A {\n\(deepMembers)\n}\n```\n")
        XCTAssertEqual(largeClassBody.mermaidBlocks.first?.diagnostic, .resourceLimit)

        let cycle = try inspect("```mermaid\nstateDiagram\nA --> B\nB --> A\n```\n")
        XCTAssertEqual(cycle.mermaidBlocks.first?.diagnostic, .unsupportedLayout)
        let tooMany = (0..<49).map { "S\($0) --> T\($0)" }.joined(separator: "\n")
        let oversized = try inspect("```mermaid\nstateDiagram\n\(tooMany)\n```\n")
        XCTAssertEqual(oversized.mermaidBlocks.first?.diagnostic, .resourceLimit)
        var checks = 0
        XCTAssertThrowsError(try MermaidClassParser.parse("classDiagram\nclass A", checkpoint: { checks += 1; if checks == 1 { throw CancellationError() } })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try MermaidStateParser.parse("stateDiagram\nA --> B", checkpoint: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testUntrustedLinksImagesHTMLAndMalformedRemainInertText() throws {
        let document = try inspect("[link](javascript:alert) ![alt](https://example.invalid/image)\n\n<script>alert(1)</script>\n\n```swift\nlet value = 42")
        XCTAssertTrue(try XCTUnwrap(document.renderedText).contains("link alt"))
        XCTAssertTrue(try XCTUnwrap(document.renderedText).contains("<script>"))
        XCTAssertTrue(document.images.allSatisfy { $0.data == nil }, "Byte-only inspection never reads image files.")
        XCTAssertEqual(try inspect("").renderedText, "")
    }

    func testLocalImagesStayWithinTheDocumentDirectoryAndRespectDecodeBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownImages-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownImages-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
        try png.write(to: root.appendingPathComponent("pixel.png"))
        try png.write(to: nested.appendingPathComponent("pixel.png"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4_097, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4_097 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let wideImage = try XCTUnwrap(context.makeImage())
        let encodedWideImage = NSMutableData()
        let imageDestination = try XCTUnwrap(CGImageDestinationCreateWithData(encodedWideImage,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, wideImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(imageDestination))
        try (encodedWideImage as Data).write(to: root.appendingPathComponent("wide.png"))
        try png.write(to: outside.appendingPathComponent("outside.png"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("bad.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.png"),
                                                   withDestinationURL: outside.appendingPathComponent("outside.png"))
        let markdown = "![local](pixel.png) ![traversal](../\(outside.lastPathComponent)/outside.png) ![symlink](escape.png) ![bad](bad.png) ![remote](https://example.invalid/x.png) ![large](large.png) ![wide](wide.png) ![nested](nested/pixel.png)\n\n```md\n![code](pixel.png)\n```\n\n`![inline](pixel.png)`"
        let documentURL = root.appendingPathComponent("readme.md")
        try Data(markdown.utf8).write(to: documentURL)
        try Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1).write(to: root.appendingPathComponent("large.png"))

        let prepared = try PreviewInspectionResult.read(at: documentURL)
        let images = try XCTUnwrap(prepared.markdownDocument?.images)
        XCTAssertEqual(images.count, 8)
        XCTAssertEqual(images.map(\.data).map { $0 != nil }, [true, false, false, false, false, false, false, true])
        XCTAssertEqual(images.first?.pixelWidth, 1)
        XCTAssertEqual(images.first?.pixelHeight, 1)
        XCTAssertTrue(try XCTUnwrap(prepared.markdownDocument?.renderedText).contains("local traversal symlink bad remote"))
        XCTAssertEqual(prepared.markdownDocument?.raw, markdown)
    }

    func testMathExpressionsAreBoundedAndIdentifiedOutsideCode() throws {
        let raw = "Inline $x^2$ and **$\\alpha_i$**, \\(y + 1\\).\n\n$$\nx = \\frac{1}{2}\n$$\n\n\\[\n \\sqrt{x}\n\\]\n\n`$code$` and \\$escaped\\$.\n\n```mermaid\nflowchart TD\n  A --> B\n```\n"
        let document = try inspect(raw)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(rendered.contains("$x^2$"))
        XCTAssertEqual(document.mathExpressions.map(\.latex), ["x^2", "\\alpha_i", "y + 1", "x = \\frac{1}{2}", "\\sqrt{x}"])
        XCTAssertEqual(document.mathExpressions.map(\.mode), [.inline, .inline, .inline, .display, .display])
        XCTAssertTrue(document.mathExpressions.allSatisfy { NSMaxRange($0.range) <= rendered.utf16.count })
        XCTAssertTrue(rendered.contains("$code$"))
        XCTAssertTrue(rendered.contains("$escaped$"))
        XCTAssertTrue(rendered.contains("flowchart TD\n  A --> B"))
        let renderedNSString = rendered as NSString
        let mermaid = try XCTUnwrap(document.runs.first {
            $0.code && renderedNSString.substring(with: $0.range).contains("flowchart TD")
        })
        XCTAssertNil(mermaid.syntax, "A Mermaid label does not claim to be a rendered diagram or source language.")

        let overlong = try inspect("$" + String(repeating: "x", count: 2_049) + "$")
        XCTAssertTrue(overlong.mathExpressions.isEmpty)
        let tooMany = try inspect(String(repeating: "$x$ ", count: 130))
        XCTAssertEqual(tooMany.mathExpressions.count, 128)
        let fencedMath = try inspect("```tex\n" + String(repeating: "$f$ ", count: 130) + "\n```\n\n$visible$")
        XCTAssertEqual(fencedMath.mathExpressions.map(\.latex), ["visible"])
    }

    func testEmojiShortcodesUseOnlyBundledMappingsOutsideCode() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/emoji-shortcodes.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertTrue(rendered.hasPrefix("😄 ❤️ 🚀 🎉 ⚠️ 👍 :unknown: :smile :smile: :heart:"), rendered)
        XCTAssertTrue(rendered.contains(":rocket:"), rendered)
        XCTAssertFalse(rendered.unicodeScalars.contains { (0xE000...0xE022).contains($0.value) })
        let text = rendered as NSString
        XCTAssertTrue(document.runs.contains { $0.code && text.substring(with: $0.range) == ":heart:" })
        let codeRuns = document.runs.filter(\.code).map { text.substring(with: $0.range) }
        XCTAssertTrue(codeRuns.contains { $0.contains(":rocket:") }, "Fenced code changed: \(codeRuns)")

        let collision = try inspect("\u{E01B} :smile:")
        XCTAssertEqual(collision.raw, "\u{E01B} :smile:")
        XCTAssertEqual(collision.renderedText, "\u{E01B} :smile:")
    }

    func testCommonMarkReferencesAutolinksAndEntitiesStayInert() throws {
        let raw = try String(decoding: Data(contentsOf: fixtureURL("Cases/markdown/commonmark-inline.md")), as: UTF8.self)
        let document = try inspect(raw)
        XCTAssertEqual(document.raw, raw)
        XCTAssertTrue(document.diagnostics.isEmpty)
        let rendered = try XCTUnwrap(document.renderedText)
        XCTAssertEqual(rendered, "Guide style and shortcut.\n\nAutolinks: https://example.invalid/path reader@example.invalid and https://example.invalid/bare.\n\nEntities: & © 😀 &not-an-entity;.\n\nEscapes: *literal* and > marker.\n\n[broken][missing] and script.")
    }

    func testBoundsAndCancellationKeepRaw() async throws {
        let oversized = String(repeating: "a", count: 1_048_577)
        let result = try inspect(oversized)
        XCTAssertEqual(result.raw.utf8.count, 1_048_576)
        XCTAssertTrue(oversized.hasPrefix(result.raw))
        XCTAssertNil(result.renderedText)
        XCTAssertEqual(result.diagnostics.first?.code, .truncated)
        let bytes = Data("# Heading\n".utf8)
        let partial = try MarkdownInspector.inspect(analysis: TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count + 1, maximumBytes: 1_048_576))
        XCTAssertNil(partial.renderedText)
        XCTAssertEqual(partial.diagnostics.first?.code, .truncated)
        let input = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MarkdownInspector.inspect(analysis: input)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
