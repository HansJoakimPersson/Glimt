import Foundation

/// One unfolded iCalendar or vCard content line.
public struct CalendarContactRow: Equatable, Sendable {
    public let section: String
    public let name: String
    public let parameters: String
    public let value: String
    public let line: Int
}

/// Bounded rows and diagnostics for iCalendar or vCard source.
public struct CalendarContactInspection: Sendable {
    public let rows: [CalendarContactRow]
    public let diagnostics: [InspectionDiagnostic]
    public let rawIsComplete: Bool
}

/// Static, read-only parsers for iCalendar and vCard content lines.
public enum CalendarContactInspector {
    /// Parses component structure and content lines without resolving time zones or expanding recurrence.
    public static func inspectICalendar(
        _ text: String, isComplete: Bool = true,
        maximumLines: Int = 20_000, maximumRows: Int = 10_000
    ) throws -> CalendarContactInspection {
        var parser = ContentLineParser(
            text: text, isComplete: isComplete, maximumLines: maximumLines,
            maximumRows: maximumRows)
        return try parser.inspectICalendar()
    }

    /// Parses one or more cards without importing contacts or decoding embedded binary properties.
    public static func inspectVCard(
        _ text: String, isComplete: Bool = true,
        maximumLines: Int = 20_000, maximumRows: Int = 10_000
    ) throws -> CalendarContactInspection {
        var parser = ContentLineParser(
            text: text, isComplete: isComplete, maximumLines: maximumLines,
            maximumRows: maximumRows)
        return try parser.inspectVCards()
    }
}

private struct LogicalContentLine {
    var text: String
    let sourceLine: Int
}

private struct ParsedContentLine {
    let name: String
    let parameters: String
    let value: String
}

private struct ContentLineParser {
    let text: String
    let isComplete: Bool
    let maximumLines: Int
    let maximumRows: Int
    var rows: [CalendarContactRow] = []
    var diagnostics: [InspectionDiagnostic] = []
    var stoppedByLimit = false

    mutating func inspectICalendar() throws -> CalendarContactInspection {
        var components: [String] = []
        var sawCalendar = false
        for logical in logicalLines() {
            if try checkLimit() { break }
            guard let property = Self.parse(logical.text) else {
                addDiagnostic(.parseError, "Malformed iCalendar content line at line \(logical.sourceLine).")
                continue
            }
            if property.name == "BEGIN" {
                let component = property.value.uppercased()
                guard Self.validToken(component), components.count < 32 else {
                    addDiagnostic(.unsupported, "Unsupported iCalendar component at line \(logical.sourceLine).")
                    continue
                }
                if components.isEmpty {
                    guard component == "VCALENDAR", !sawCalendar else {
                        addDiagnostic(.parseError, "iCalendar root must be VCALENDAR at line \(logical.sourceLine).")
                        continue
                    }
                    sawCalendar = true
                }
                components.append(component)
                append(section: components.joined(separator: "/"), property: property, line: logical.sourceLine)
                continue
            }
            if property.name == "END" {
                let component = property.value.uppercased()
                guard components.last == component else {
                    addDiagnostic(.parseError, "Mismatched iCalendar component at line \(logical.sourceLine).")
                    continue
                }
                append(section: components.joined(separator: "/"), property: property, line: logical.sourceLine)
                components.removeLast()
                continue
            }
            guard !components.isEmpty else {
                addDiagnostic(.parseError, "iCalendar property appears outside a component at line \(logical.sourceLine).")
                continue
            }
            let value =
                property.name == "ATTACH" && property.parameters.localizedCaseInsensitiveContains("ENCODING=BASE64")
                ? "[payload omitted]" : property.value
            append(section: components.joined(separator: "/"), property: property, value: value, line: logical.sourceLine)
        }
        if !sawCalendar { addDiagnostic(.parseError, "VCALENDAR root is missing.") }
        let isUnclosed = !components.isEmpty
        if isUnclosed {
            addDiagnostic(
                isComplete ? .parseError : .truncated,
                isComplete ? "iCalendar component is not closed." : "iCalendar preview ends inside a component.")
        }
        return result(complete: isComplete && !stoppedByLimit && !isUnclosed)
    }

    mutating func inspectVCards() throws -> CalendarContactInspection {
        var cardNumber = 0
        var inCard = false
        for logical in logicalLines() {
            if try checkLimit() { break }
            guard let property = Self.parse(logical.text) else {
                addDiagnostic(.parseError, "Malformed vCard content line at line \(logical.sourceLine).")
                continue
            }
            if property.name == "BEGIN" {
                guard property.value.uppercased() == "VCARD", !inCard, cardNumber < 1_000 else {
                    addDiagnostic(
                        cardNumber >= 1_000 ? .limitExceeded : .parseError,
                        "Unexpected vCard component at line \(logical.sourceLine).")
                    continue
                }
                cardNumber += 1
                inCard = true
                append(section: "Card \(cardNumber)", property: property, line: logical.sourceLine)
                continue
            }
            if property.name == "END" {
                guard property.value.uppercased() == "VCARD", inCard else {
                    addDiagnostic(.parseError, "Unexpected vCard end at line \(logical.sourceLine).")
                    continue
                }
                append(section: "Card \(cardNumber)", property: property, line: logical.sourceLine)
                inCard = false
                continue
            }
            guard inCard else {
                addDiagnostic(.parseError, "vCard property appears outside a card at line \(logical.sourceLine).")
                continue
            }
            let value: String
            if ["PHOTO", "LOGO", "SOUND", "KEY"].contains(property.name)
                || (property.name == "ATTACH" && property.parameters.localizedCaseInsensitiveContains("ENCODING=BASE64"))
            {
                value = "[payload omitted]"
            } else if property.value.utf8.count > 8_192 {
                value = String(decoding: property.value.utf8.prefix(8_192), as: UTF8.self)
                addDiagnostic(.limitExceeded, "vCard property value was limited at line \(logical.sourceLine).")
            } else {
                value = property.value
            }
            append(section: "Card \(cardNumber)", property: property, value: value, line: logical.sourceLine)
        }
        if cardNumber == 0 { addDiagnostic(.parseError, "VCARD component is missing.") }
        if inCard {
            addDiagnostic(
                isComplete ? .parseError : .truncated,
                isComplete ? "vCard is not closed." : "vCard preview ends inside a card.")
        }
        return result(complete: isComplete && !stoppedByLimit && !inCard)
    }

    private func logicalLines() -> [LogicalContentLine] {
        let physical = text.components(separatedBy: .newlines)
        let lineLimit = min(max(0, maximumLines), 20_000)
        var result: [LogicalContentLine] = []
        for (offset, line) in physical.prefix(lineLimit).enumerated() {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t", !result.isEmpty {
                result[result.count - 1].text += String(line.dropFirst())
            } else {
                result.append(.init(text: line, sourceLine: offset + 1))
            }
        }
        return result
    }

    private static func parse(_ line: String) -> ParsedContentLine? {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\"", !escaped { quoted.toggle() }
            if character == ":", !quoted {
                let left = String(line[..<index])
                let value = String(line[line.index(after: index)...])
                let name = left.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? ""
                let parameters = left.firstIndex(of: ";").map { String(left[left.index(after: $0)...]) } ?? ""
                guard Self.validPropertyName(name) else { return nil }
                return .init(name: name, parameters: parameters, value: value)
            }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        return nil
    }

    private static func validPropertyName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private mutating func append(section: String, property: ParsedContentLine, value: String? = nil, line: Int) {
        guard rows.count < min(max(0, maximumRows), 10_000) else {
            addDiagnostic(.limitExceeded, "Calendar/contact record limit reached.")
            stoppedByLimit = true
            return
        }
        rows.append(
            .init(
                section: section, name: property.name, parameters: property.parameters,
                value: value ?? property.value, line: line))
    }

    private mutating func checkLimit() throws -> Bool {
        try Task.checkCancellation()
        return stoppedByLimit
    }

    private mutating func addDiagnostic(_ code: InspectionDiagnostic.Code, _ message: String) {
        if !diagnostics.contains(where: { $0.code == code && $0.message == message }) {
            diagnostics.append(.init(code: code, message: message))
        }
    }

    private func result(complete: Bool) -> CalendarContactInspection {
        let lineLimit = min(max(0, maximumLines), 20_000)
        let sourceWasLimited = text.components(separatedBy: .newlines).count > lineLimit
        var allDiagnostics = diagnostics
        let rawIsComplete = complete && !sourceWasLimited
        if !rawIsComplete && !allDiagnostics.contains(where: { $0.code == .limitExceeded || $0.code == .truncated }) {
            allDiagnostics.append(.init(code: .truncated, message: "Calendar/contact preview is incomplete; Raw retains the source."))
        }
        return .init(rows: rows, diagnostics: allDiagnostics, rawIsComplete: rawIsComplete)
    }
}
