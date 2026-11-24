import Foundation

/// Presentation-only Hard wrap (ADR-016). The displayed string gets inserted line breaks and
/// hanging indents; `original` is never changed and remains what copy returns.
struct HardWrapLayout: Equatable, Sendable {
    /// Text inserted before `originalLocation` (UTF-16 offset into `original`).
    struct Insertion: Equatable, Sendable {
        let originalLocation: Int
        let text: String
        var length: Int { (text as NSString).length }
    }

    let original: String
    let displayed: String
    let insertions: [Insertion]

    /// No insertions; used for Off and Soft wrap so callers can share one code path.
    /// Returns a zero-change mapping so selection and copying use the same conversion path as wrapped text.
    static func identity(_ text: String) -> HardWrapLayout { .init(original: text, displayed: text, insertions: []) }

    // MARK: Layout

    /// Columns are extended grapheme clusters; East Asian Wide/Fullwidth and emoji presentation count
    /// 2, control characters 0, everything else 1. Tabs advance to the next multiple of `tabStop`.
    /// A break goes after the last whitespace at or before `lineLength`; a longer run breaks at the
    /// limit. Continuations repeat the line's leading whitespace, capped at half the line length.
    static func wrap(_ text: String, lineLength: Int, tabStop: Int) throws -> HardWrapLayout {
        // Wrapping is presentation-only; insertions preserve a reversible mapping to the unchanged source.
        let limit = max(1, lineLength)
        let stop = max(1, tabStop)
        var insertions: [Insertion] = []
        // CRLF is one Character, so lines are split on any newline cluster, not on "\n" alone.
        var lineStart = text.startIndex
        var lineOffset = 0
        var offset = 0
        var linesSinceCheck = 0
        var index = text.startIndex
        while true {
            let atEnd = index == text.endIndex
            guard atEnd || text[index].isNewline else {
                offset += text[index].utf16.count
                index = text.index(after: index)
                continue
            }
            wrapLine(text[lineStart..<index], startingAt: lineOffset, limit: limit, tabStop: stop, into: &insertions)
            if atEnd { break }
            linesSinceCheck += 1
            if linesSinceCheck >= 1_024 { linesSinceCheck = 0; try Task.checkCancellation() }
            offset += text[index].utf16.count
            index = text.index(after: index)
            lineStart = index
            lineOffset = offset
        }
        guard !insertions.isEmpty else { return identity(text) }
        let source = text as NSString
        let displayed = NSMutableString()
        var cursor = 0
        for insertion in insertions {
            displayed.append(source.substring(with: NSRange(location: cursor, length: insertion.originalLocation - cursor)))
            displayed.append(insertion.text)
            cursor = insertion.originalLocation
        }
        displayed.append(source.substring(from: cursor))
        return .init(original: text, displayed: displayed as String, insertions: insertions)
    }

    /// Splits one physical line at display-column boundaries without breaking grapheme clusters.
    private static func wrapLine(_ line: Substring, startingAt lineOffset: Int, limit: Int, tabStop: Int,
                                 into insertions: inout [Insertion]) {
        // Work in grapheme clusters for display width while recording insertion offsets in UTF-16 for AppKit.
        let clusters = Array(line)
        guard !clusters.isEmpty else { return }
        // Leading whitespace forms the hanging indent, measured in columns and capped at limit / 2.
        var indent = ""
        var indentColumns = 0
        for character in clusters {
            guard character == " " || character == "\t" else { break }
            let next = character == "\t" ? (indentColumns / tabStop + 1) * tabStop : indentColumns + 1
            guard next <= limit / 2 else { break }
            indent.append(character)
            indentColumns = next
        }
        let continuation = "\n" + indent
        // Breaking inside the leading whitespace would only move the indent onto its own line.
        let leading = clusters.prefix { $0 == " " || $0 == "\t" }.count

        var column = 0
        var offset = lineOffset
        var lastBreak: (offset: Int, columnAfter: Int, clusterIndex: Int)?
        var index = 0
        var segmentStart = 0
        while index < clusters.count {
            let character = clusters[index]
            let width = character == "\t" ? (column / tabStop + 1) * tabStop - column : columns(of: character)
            if character == " ", column + width > limit {
                // A space at the limit stays at the end of the line; the next cluster starts the continuation.
                offset += 1
                index += 1
                if index < clusters.count, index > leading { lastBreak = (offset, column, index) }
                continue
            }
            if column + width > limit, index > segmentStart, width > 0 {
                if let candidate = lastBreak, candidate.clusterIndex > segmentStart {
                    insertions.append(.init(originalLocation: candidate.offset, text: continuation))
                    column = indentColumns + (column - candidate.columnAfter)
                    segmentStart = candidate.clusterIndex
                    lastBreak = nil
                    // Re-measure the carried run against the new line before placing this cluster.
                    continue
                }
                insertions.append(.init(originalLocation: offset, text: continuation))
                column = indentColumns
                segmentStart = index
                lastBreak = nil
                continue
            }
            column += width
            offset += character.utf16.count
            index += 1
            if character.isWhitespace, index < clusters.count, index > leading { lastBreak = (offset, column, index) }
        }
    }

    /// Returns terminal-style cell width used to choose a hard-wrap boundary.
    static func columns(of character: Character) -> Int {
        // Tabs are handled by the caller because their width depends on the current column.
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.properties.generalCategory == .control { return 0 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
            || (character.unicodeScalars.count > 1 && character.unicodeScalars.contains(where: { $0.value == 0xFE0F })) { return 2 }
        return isWide(scalar.value) ? 2 : 1
    }

    /// East Asian Wide (W) and Fullwidth (F) blocks from UAX #11.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1B000...0x1B2FF, 0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: Mapping

    /// Inserted text before an original location shifts it in the displayed string.
    func displayedLocation(forOriginal location: Int) -> Int {
        // Sum only insertions before the source location; an insertion at the location belongs after it.
        var shift = 0
        for insertion in insertions {
            guard insertion.originalLocation <= location else { break }
            shift += insertion.length
        }
        return location + shift
    }

    /// Maps an original UTF-16 range into displayed text, accounting for inserted hard breaks.
    func displayedRange(forOriginal range: NSRange) -> NSRange {
        // Map both endpoints independently, then trim an insertion exactly at the range's end.
        let start = displayedLocation(forOriginal: range.location)
        let end = displayedLocation(forOriginal: NSMaxRange(range))
        // A range that ends exactly at an insertion does not include the inserted text.
        let trimmed = insertions.first { $0.originalLocation == NSMaxRange(range) }.map { end - $0.length } ?? end
        return NSRange(location: start, length: max(0, (range.length == 0 ? start : max(start, trimmed)) - start))
    }

    /// Displayed positions inside inserted text map to the following original character.
    func originalLocation(forDisplayed location: Int) -> Int {
        // Carets inside generated indentation snap to the source character following that insertion.
        var shift = 0
        for insertion in insertions {
            let displayedStart = insertion.originalLocation + shift
            if location < displayedStart { break }
            if location < displayedStart + insertion.length { return insertion.originalLocation }
            shift += insertion.length
        }
        return location - shift
    }

    /// The original text a displayed selection covers, without inserted breaks or indents.
    func originalText(forDisplayed range: NSRange) -> String {
        // Copy from the original buffer so generated hard-wrap breaks never enter the pasteboard.
        let start = originalLocation(forDisplayed: range.location)
        let end = originalLocation(forDisplayed: NSMaxRange(range))
        let source = original as NSString
        let lower = min(max(0, start), source.length)
        let upper = min(max(lower, end), source.length)
        return source.substring(with: NSRange(location: lower, length: upper - lower))
    }
}
