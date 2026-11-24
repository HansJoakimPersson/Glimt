import Foundation

/// One header or safe MIME fact from an email message.
public struct EmailMessageRow: Equatable, Sendable {
    public let section: String
    public let name: String
    public let value: String
    public let line: Int
}

/// Bounded email metadata and plain text body facts; original content remains on the preview result.
public struct EmailMessageInspection: Sendable {
    public let rows: [EmailMessageRow]
    public let diagnostics: [InspectionDiagnostic]
    public let rawIsComplete: Bool
}

/// Read-only parser for RFC 5322 header blocks and a bounded MIME subset.
public enum EmailMessageInspector {
    /// Parses message headers, multipart boundaries, text/plain bodies and attachment metadata.
    /// Attachment payloads and HTML are not decoded or rendered.
    public static func inspect(
        _ text: String, isComplete: Bool = true,
        maximumLines: Int = 20_000, maximumRows: Int = 10_000
    ) throws -> EmailMessageInspection {
        let lines = text.components(separatedBy: .newlines)
        var parser = Parser(
            lines: lines, isComplete: isComplete,
            maximumLines: maximumLines, maximumRows: maximumRows)
        return try parser.inspect()
    }
}

private struct Parser {
    let lines: [String]
    let isComplete: Bool
    let maximumLines: Int
    let maximumRows: Int
    var rows: [EmailMessageRow] = []
    var diagnostics: [InspectionDiagnostic] = []
    var stoppedByLimit = false

    mutating func inspect() throws -> EmailMessageInspection {
        let lineLimit = min(max(0, maximumLines), 20_000)
        let end = min(lines.count, lineLimit)
        guard end > 0 else {
            diagnostics.append(.init(code: .parseError, message: "Email headers are missing."))
            return result(isComplete: false)
        }
        let headerBlock = parseHeaders(start: 0, end: end)
        for header in headerBlock.headers {
            append(section: "Header", name: header.name, value: header.value, line: header.line)
        }
        if headerBlock.headers.isEmpty {
            diagnostics.append(.init(code: .parseError, message: "Email headers are missing or malformed."))
        }
        guard headerBlock.bodyStart <= end else {
            diagnostics.append(.init(code: .truncated, message: "Email header preview is incomplete; Raw retains the available message."))
            return result(isComplete: false)
        }
        if headerBlock.bodyStart < end {
            let contentType =
                headerBlock.headers.last(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value
                ?? "text/plain"
            let disposition = headerBlock.headers.last(where: { $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame })?.value
            try inspectEntity(
                headers: headerBlock.headers, start: headerBlock.bodyStart, end: end,
                contentType: contentType, disposition: disposition, lineOffset: headerBlock.bodyStart)
        }
        let complete = isComplete && end == lines.count && !stoppedByLimit
        if !complete && !diagnostics.contains(where: { $0.code == .truncated || $0.code == .limitExceeded }) {
            diagnostics.append(.init(code: .truncated, message: "Email preview is incomplete; Raw retains the available message."))
        }
        return result(isComplete: complete)
    }

    private mutating func inspectEntity(
        headers: [Header], start: Int, end: Int, contentType: String,
        disposition: String?, lineOffset: Int, depth: Int = 0
    ) throws {
        guard try !checkLimit() else { return }
        let type = contentType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "text/plain"
        let filename = parameter("filename", in: disposition) ?? parameter("filename", in: contentType)
        let isAttachment = disposition?.lowercased().hasPrefix("attachment") == true || filename != nil
        let partIndex = rows.filter { $0.name == "Content-Type" && $0.section.hasPrefix("MIME part") }.count + 1
        let section = depth == 0 && headers.isEmpty ? "MIME part \(partIndex)" : "MIME part \(partIndex)"
        append(section: section, name: "Content-Type", value: type, line: lineOffset + 1)
        if let disposition { append(section: section, name: "Disposition", value: disposition, line: lineOffset + 1) }
        if let filename { append(section: section, name: "Filename", value: filename, line: lineOffset + 1) }

        if type.hasPrefix("multipart/") {
            guard depth < 8, let boundary = parameter("boundary", in: contentType), !boundary.isEmpty else {
                diagnostics.append(.init(code: .unsupported, message: "Nested or boundaryless MIME structure is unsupported."))
                return
            }
            try inspectMultipart(boundary: boundary, start: start, end: end, depth: depth + 1)
            return
        }
        guard !isAttachment else { return }
        guard type == "text/plain" else {
            diagnostics.append(.init(code: .unsupported, message: "Only text/plain MIME bodies are shown in Tree."))
            return
        }
        let transferEncoding = headers.last(where: { $0.name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame })?.value.lowercased()
        if transferEncoding == "base64" {
            diagnostics.append(.init(code: .unsupported, message: "Base64 text bodies are not decoded; use Raw to inspect the source."))
            return
        }
        var body = lines[start..<end].joined(separator: "\n")
        if transferEncoding == "quoted-printable" { body = Self.decodeQuotedPrintable(body) }
        if body.utf8.count > 65_536 {
            body = String(decoding: body.utf8.prefix(65_536), as: UTF8.self)
            diagnostics.append(.init(code: .limitExceeded, message: "Email body preview was limited."))
        }
        if !body.isEmpty { append(section: section, name: "Text body", value: body, line: lineOffset + 1) }
    }

    private mutating func inspectMultipart(boundary: String, start: Int, end: Int, depth: Int) throws {
        let opening = "--" + boundary
        let closing = opening + "--"
        var segmentStart: Int?
        var sawClosing = false
        for index in start..<end {
            if try checkLimit() { return }
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line == opening || line == closing else { continue }
            if let segmentStart, segmentStart < index {
                let part = parseHeaders(start: segmentStart, end: index)
                guard part.bodyStart <= index else { continue }
                let contentType = part.headers.last(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value ?? "text/plain"
                let disposition = part.headers.last(where: { $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame })?.value
                try inspectEntity(
                    headers: part.headers, start: part.bodyStart, end: index,
                    contentType: contentType, disposition: disposition,
                    lineOffset: segmentStart, depth: depth)
            }
            if line == closing { sawClosing = true; break }
            segmentStart = index + 1
        }
        if !sawClosing {
            diagnostics.append(
                .init(
                    code: isComplete ? .parseError : .truncated,
                    message: "MIME multipart boundary is not closed."))
        }
    }

    private func parseHeaders(start: Int, end: Int) -> HeaderBlock {
        var headers: [Header] = []
        var currentName: String?
        var currentValue = ""
        var currentLine = start + 1
        var bodyStart = end + 1
        for index in start..<end {
            let line = lines[index]
            if line.isEmpty {
                if let currentName { headers.append(.init(name: currentName, value: currentValue, line: currentLine)) }
                bodyStart = index + 1
                break
            }
            if line.first == " " || line.first == "\t" {
                if currentName != nil { currentValue += " " + line.trimmingCharacters(in: .whitespaces) } else { headers.append(.init(name: "", value: line, line: index + 1)) }
                continue
            }
            if let currentName { headers.append(.init(name: currentName, value: currentValue, line: currentLine)) }
            guard let colon = line.firstIndex(of: ":") else {
                headers.append(.init(name: "", value: line, line: index + 1))
                currentName = nil
                currentValue = ""
                continue
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }) else {
                headers.append(.init(name: "", value: line, line: index + 1))
                currentName = nil
                currentValue = ""
                continue
            }
            currentName = name
            currentValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            currentLine = index + 1
        }
        if bodyStart == end + 1, let currentName { headers.append(.init(name: currentName, value: currentValue, line: currentLine)) }
        return .init(headers: headers.filter { !$0.name.isEmpty }, bodyStart: bodyStart)
    }

    private mutating func append(section: String, name: String, value: String, line: Int) {
        guard rows.count < min(max(0, maximumRows), 10_000) else {
            if !stoppedByLimit { diagnostics.append(.init(code: .limitExceeded, message: "Email record limit reached.")) }
            stoppedByLimit = true
            return
        }
        rows.append(.init(section: section, name: name, value: value, line: line))
    }

    private mutating func checkLimit() throws -> Bool {
        try Task.checkCancellation()
        return stoppedByLimit
    }

    private func result(isComplete: Bool) -> EmailMessageInspection {
        .init(rows: rows, diagnostics: diagnostics, rawIsComplete: isComplete && !stoppedByLimit)
    }

    private func parameter(_ name: String, in value: String?) -> String? {
        guard let value else { return nil }
        let segments = Self.splitParameters(value)
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            if segment[..<equals].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                var result = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if result.count >= 2, result.first == "\"", result.last == "\"" { result = String(result.dropFirst().dropLast()) }
                return String(result).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
        return nil
    }

    private static func splitParameters(_ value: String) -> [String] {
        var parts: [String] = []
        var start = value.startIndex
        var quoted = false
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\"", !escaped { quoted.toggle() }
            if character == ";", !quoted { parts.append(String(value[start..<index])); start = value.index(after: index) }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        parts.append(String(value[start...]))
        return parts
    }

    private static func decodeQuotedPrintable(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 1 < bytes.count {
                if bytes[index + 1] == 10 { index += 2; continue }
                if bytes[index + 1] == 13, index + 2 < bytes.count, bytes[index + 2] == 10 { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    decoded.append((high << 4) | low); index += 3; continue
                }
            }
            decoded.append(bytes[index]); index += 1
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48;
        case 65...70: byte - 55;
        case 97...102: byte - 87;
        default: nil
        }
    }
}

private struct Header {
    let name: String
    let value: String
    let line: Int
}

private struct HeaderBlock {
    let headers: [Header]
    let bodyStart: Int
}
