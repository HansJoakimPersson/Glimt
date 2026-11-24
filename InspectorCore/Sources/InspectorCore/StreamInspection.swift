import Foundation

/// Parsed JSON Lines records, diagnostics, and whether the preview covers the complete input.
public struct JSONLinesInspectionResult: Sendable {
    public let records: [StructuredValue]
    public let diagnostics: [InspectionDiagnostic]
    public let rawIsComplete: Bool
}

/// One normalized log event, retaining its original structured fields when they were available.
public struct LogRecord: Equatable, Sendable {
    public let line: Int
    public let timestamp: String?
    public let level: String?
    public let message: String
    public let fields: [StructuredMember]?

    /// First recognized origin field; the full original value remains in `fields`.
    public var source: String? {
        guard let fields else { return nil }
        if let direct = fields.first(where: {
            ["source", "host", "hostname", "service.name", "service", "app", "logger", "container_name", "container", "device_vendor"].contains($0.key.lowercased())
        }) { return StreamInspector.scalarText(direct.value) }
        guard let resource = fields.first(where: { $0.key.lowercased() == "resource" })?.value,
              case .object(let resourceFields) = resource,
              case .array(let attributes) = resourceFields.first(where: { $0.key == "attributes" })?.value else { return nil }
        for attribute in attributes {
            guard case .object(let members) = attribute,
                  members.first(where: { $0.key == "key" }).map({ StreamInspector.scalarText($0.value) }) == "service.name",
                  let value = members.first(where: { $0.key == "value" })?.value else { continue }
            return StreamInspector.scalarText(value)
        }
        return nil
    }
}

/// Parsed log events with completeness and parsing diagnostics for the displayed prefix.
public struct LogInspectionResult: Sendable {
    public let records: [LogRecord]
    public let diagnostics: [InspectionDiagnostic]
    public let rawIsComplete: Bool

    /// Bounded column projection for a native event table; original values remain in `records` and Raw.
    public var table: LogTable? { LogTable(records: records) }
}

/// Tabular projection of normalized log events, including a bounded set of original fields.
public struct LogTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]

    fileprivate init?(records: [LogRecord], maximumFieldColumns: Int = 16) {
        let maximumFieldsForRows = records.isEmpty ? maximumFieldColumns : max(0, 100_000 / records.count - 5)
        let fieldLimit = min(maximumFieldColumns, maximumFieldsForRows)
        func shouldStop() -> Bool { Task.isCancelled }
        var fieldKeys: [String] = []
        for record in records {
            for field in record.fields ?? [] {
                if !["line", "timestamp", "source", "level", "message"].contains(field.key.lowercased()),
                   !fieldKeys.contains(field.key) {
                    fieldKeys.append(field.key)
                    if fieldKeys.count == fieldLimit { break }
                }
            }
            if fieldKeys.count == fieldLimit { break }
            if shouldStop() { return nil }
        }
        headers = ["Line", "Timestamp", "Source", "Level", "Message"] + fieldKeys
        var projectedRows: [[String]] = []
        projectedRows.reserveCapacity(records.count)
        for record in records {
            if shouldStop() { return nil }
            let fields = record.fields ?? []
            let values = fieldKeys.map { key in
                fields.first(where: { $0.key == key }).map { Self.displayText($0.value) } ?? ""
            }
            projectedRows.append([String(record.line), record.timestamp ?? "", record.source ?? "", record.level ?? "", record.message] + values)
        }
        rows = projectedRows
    }

    private static func displayText(_ value: StructuredValue) -> String {
        switch value {
        case .string(let value), .number(let value): value
        case .boolean(let value): value ? "true" : "false"
        case .null: "null"
        case .array(let values): "[\(values.count) items]"
        case .object(let members): "{\(members.count) fields}"
        }
    }
}

/// Bounded line-oriented readers. Input is treated as inert text and never executed or transmitted.
public enum StreamInspector {
    private static let regexCache = RegularExpressionCache()
    /// Identifies distinctive log signatures without relying on a filename extension.
    static func recognizesLogContent(_ text: String) -> Bool {
        // Sniff a bounded prefix of each line; the log patterns backtrack quadratically on very long lines.
        let lines = text.split(whereSeparator: \.isNewline).prefix(12).map { String($0.prefix(4_096)) }
        guard !lines.isEmpty else { return false }
        if lines.contains(where: { $0.hasPrefix("CEF:") || $0.hasPrefix("LEEF:") || $0.hasPrefix("#Fields:") }) { return true }
        if lines.contains(where: { parseKubernetesCRI($0, lineNumber: 1) != nil || parseNginxError($0, lineNumber: 1) != nil
            || parseSyslog($0, lineNumber: 1) != nil || parseAccessLog($0, lineNumber: 1) != nil
            || parseLog4j($0, lineNumber: 1) != nil }) { return true }
        if lines.contains(where: { line in
            guard let fields = parseLogfmt(line, lineNumber: 1)?.fields, fields.count >= 2 else { return false }
            return fields.contains { ["time", "ts", "timestamp", "level", "severity", "msg", "message"].contains($0.key.lowercased()) }
        }) { return true }

        if lines.count > 1 {
            for line in lines.prefix(4) {
                guard let first = line.first, first == "{" || first == "[",
                      let parsed = try? JSONInspector.inspect(bytes: Data(line.utf8), limits: .init(
                        maximumBytes: 1_048_576, maximumDepth: 32, maximumValues: 2_000,
                        maximumOutputBytes: 524_288)),
                      let value = parsed.content, isStructuredLogEvent(value) else { continue }
                return true
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let parsed = try? JSONInspector.inspect(bytes: Data(trimmed.utf8), limits: .init(
                maximumBytes: 1_048_576, maximumDepth: 32, maximumValues: 4_000,
                maximumOutputBytes: 1_048_576)),
              let root = parsed.content else { return false }
        let candidates: [StructuredValue]
        if case .array(let values) = root { candidates = Array(values.prefix(8)) }
        else { candidates = [root] }
        return candidates.contains(where: isStructuredLogEvent)
    }

    /// Checks whether an object has the field combinations characteristic of a structured log.
    private static func isStructuredLogEvent(_ value: StructuredValue) -> Bool {
        guard case .object(let fields) = value else { return false }
        let keys = Set(fields.map { $0.key.lowercased() })
        if keys.isSuperset(of: ["log", "stream", "time"]) || keys.isSuperset(of: ["version", "host", "short_message"]) { return true }
        if keys.contains("resourcelogs") || keys.contains("logrecords") || keys.contains("scopelogs") { return true }
        let hasTime = !keys.isDisjoint(with: ["timestamp", "@timestamp", "time", "ts", "timeunixnano"])
        let hasLevel = !keys.isDisjoint(with: ["level", "severity", "severitytext", "log.level"])
        let hasMessage = !keys.isDisjoint(with: ["message", "msg", "event", "body"])
        return (hasTime && hasLevel && hasMessage) || (keys.contains("severitytext") && keys.contains("body"))
    }

    /// Parses each non-empty line independently and retains malformed records as diagnostics.
    public static func jsonLines(_ text: String, isComplete: Bool = true,
                                 maximumLines: Int = 5_000) throws -> JSONLinesInspectionResult {
        let lines = text.components(separatedBy: .newlines)
        let count = max(0, min(lines.count, min(maximumLines, 5_000)))
        var records: [StructuredValue] = []
        var diagnostics: [InspectionDiagnostic] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let result = try JSONInspector.inspect(bytes: Data(line.utf8), limits: .init(maximumBytes: 1_048_576, maximumDepth: 64, maximumValues: 10_000, maximumOutputBytes: 2_097_152))
            if let value = result.content {
                records.append(value)
            } else {
                diagnostics.append(.init(code: .parseError, message: "Invalid JSON Lines record at line \(index + 1)."))
                records.append(.object([.init(key: "line", value: .number(String(index + 1))), .init(key: "error", value: .string("Invalid JSON"))]))
            }
        }
        let complete = isComplete && count == lines.count && !diagnostics.contains { $0.code == .limitExceeded }
        if !complete && !diagnostics.contains(where: { $0.code == .truncated || $0.code == .limitExceeded }) {
            diagnostics.append(.init(code: .truncated, message: "JSON Lines preview is incomplete; Raw retains the available text."))
        }
        return .init(records: records, diagnostics: diagnostics, rawIsComplete: complete)
    }

    /// Parses supported structured and conventional log formats within line bounds.
    public static func log(_ text: String, isComplete: Bool = true,
                           maximumLines: Int = 20_000) throws -> LogInspectionResult {
        let boundedLines = max(0, min(maximumLines, 20_000))
        if boundedLines > 0, let records = try jsonLogDocument(text) {
            let prefix = Array(records.prefix(boundedLines))
            let complete = isComplete && records.count <= boundedLines
            let diagnostics: [InspectionDiagnostic] = complete ? [] : [.init(code: .truncated, message: "Log preview is incomplete; Raw retains the available text.")]
            return .init(records: prefix, diagnostics: diagnostics, rawIsComplete: complete)
        }
        let lines = text.components(separatedBy: .newlines)
        let count = max(0, min(lines.count, boundedLines))
        var records: [LogRecord] = []
        var diagnostics: [InspectionDiagnostic] = []
        var w3cFields: [String]?
        for (offset, line) in lines.prefix(count).enumerated() {
            try Task.checkCancellation()
            if line.isEmpty { continue }
            if line.hasPrefix("#Fields:") {
                w3cFields = line.dropFirst("#Fields:".count).split(whereSeparator: \.isWhitespace).map(String.init)
                continue
            }
            if line.hasPrefix("#") { continue }

            let jsonRecords = parseJSONLine(line, lineNumber: offset + 1)
            if let jsonRecords { records.append(contentsOf: jsonRecords); continue }
            let parsed = parseW3C(line, lineNumber: offset + 1, names: w3cFields)
                ?? parseCEF(line, lineNumber: offset + 1)
                ?? parseLEEF(line, lineNumber: offset + 1)
                ?? parseKubernetesCRI(line, lineNumber: offset + 1)
                ?? parseLog4j(line, lineNumber: offset + 1)
                ?? parseNginxError(line, lineNumber: offset + 1)
                ?? parseSyslog(line, lineNumber: offset + 1)
                ?? parseAccessLog(line, lineNumber: offset + 1)
                ?? parseLogfmt(line, lineNumber: offset + 1)
            if let parsed {
                if let tag = fieldValue("tag", in: parsed.fields), ["P", "F"].contains(tag),
                   let previous = records.indices.last,
                   records[previous].timestamp == parsed.timestamp,
                   fieldValue("stream", in: records[previous].fields) == fieldValue("stream", in: parsed.fields),
                   fieldValue("tag", in: records[previous].fields) == "P" {
                    let old = records[previous]
                    var fields = old.fields ?? []
                    if let tagIndex = fields.firstIndex(where: { $0.key == "tag" }) {
                        fields[tagIndex] = member("tag", tag)
                    }
                    records[previous] = .init(line: old.line, timestamp: old.timestamp, level: old.level,
                                              message: old.message + parsed.message, fields: fields)
                    continue
                }
                records.append(parsed)
                continue
            }
            if line.first == "{" || line.first == "[" {
                diagnostics.append(.init(code: .parseError, message: "Invalid JSON log record at line \(offset + 1)."))
                records.append(.init(line: offset + 1, timestamp: nil, level: nil, message: line, fields: nil))
                continue
            }

            let (timestamp, level, message) = parseConventionalLine(line)
            if timestamp == nil && level == nil, let previous = records.indices.last {
                let old = records[previous]
                records[previous] = .init(line: old.line, timestamp: old.timestamp, level: old.level,
                                          message: old.message + "\n" + line, fields: old.fields)
            } else {
                records.append(.init(line: offset + 1, timestamp: timestamp, level: level,
                                     message: message.isEmpty ? line : message, fields: nil))
            }
        }
        let complete = isComplete && count == lines.count && !diagnostics.contains { $0.code == .limitExceeded }
        if !complete && !diagnostics.contains(where: { $0.code == .truncated || $0.code == .limitExceeded }) {
            diagnostics.append(.init(code: .truncated, message: "Log preview is incomplete; Raw retains the available text."))
        }
        return .init(records: records, diagnostics: diagnostics, rawIsComplete: complete)
    }

    private static let levels: Set<String> = ["TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "WARNING", "ERROR", "FATAL", "CRITICAL"]
    private static let syslogLevels = ["EMERGENCY", "ALERT", "CRITICAL", "ERROR", "WARNING", "NOTICE", "INFO", "DEBUG"]

    /// Parses a JSON object or array document and expands OpenTelemetry resource logs into events.
    private static func jsonLogDocument(_ text: String) throws -> [LogRecord]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[" || trimmed.first == "{" else { return nil }
        try Task.checkCancellation()
        let parsed = try JSONInspector.inspect(bytes: Data(trimmed.utf8), limits: .init(
            maximumBytes: 1_048_576, maximumDepth: 64, maximumValues: 10_000,
            maximumOutputBytes: 2_097_152))
        guard let content = parsed.content else { return nil }
        let values: [StructuredValue]
        if case .array(let items) = content { values = items } else { values = [content] }
        var records: [LogRecord] = []
        for value in values {
            let events = openTelemetryRecords(value) ?? [value]
            records.append(contentsOf: events.enumerated().map { logRecord($0.element, line: records.count + $0.offset + 1) })
        }
        return records
    }

    /// Converts a single JSON log line into one or more normalized events when it is valid JSON.
    private static func parseJSONLine(_ line: String, lineNumber: Int) -> [LogRecord]? {
        guard let first = line.first, first == "{" || first == "[" else { return nil }
        guard let parsed = try? JSONInspector.inspect(bytes: Data(line.utf8), limits: .init(
            maximumBytes: 1_048_576, maximumDepth: 64, maximumValues: 10_000,
            maximumOutputBytes: 2_097_152)), let value = parsed.content else { return nil }
        let events = openTelemetryRecords(value) ?? [value]
        return events.enumerated().map { logRecord($0.element, line: lineNumber + $0.offset) }
    }

    /// Maps a structured event's common timestamp, severity, and message aliases to a log record.
    private static func logRecord(_ value: StructuredValue, line: Int) -> LogRecord {
        guard case .object(let fields) = value else {
            return .init(line: line, timestamp: nil, level: nil, message: scalarText(value), fields: nil)
        }
        /// Looks up the first structured event field matching a case-insensitive alias.
        func field(_ aliases: [String]) -> StructuredValue? {
            fields.first { aliases.contains($0.key.lowercased()) }?.value
        }
        let timestamp = field(["timestamp", "time", "@timestamp", "ts", "timeunixnano", "observedtimeunixnano"]).map(normalizedTimestamp)
        let rawLevel = field(["level", "severitytext", "severity", "severitynumber", "loglevel", "log.level"])
        let numeric = rawLevel.flatMap { if case .number(let value) = $0 { return Int(value) }; return nil }
        let level = rawLevel.flatMap { value in
            if case .string(let text) = value { return text.uppercased() }
            if let numeric, fields.contains(where: { $0.key.lowercased() == "severitynumber" }) { return openTelemetryLevel(numeric) }
            if let numeric, (0...7).contains(numeric) { return gelfLevel(numeric) }
            return nil
        }
        let message = field(["message", "msg", "event", "text", "log", "short_message", "body"]).map(scalarText) ?? ""
        return .init(line: line, timestamp: timestamp, level: level, message: message, fields: fields)
    }

    /// Converts scalar values and common OpenTelemetry AnyValue objects to readable text.
    fileprivate static func scalarText(_ value: StructuredValue) -> String {
        switch value {
        case .string(let value), .number(let value): return value
        case .boolean(let value): return String(value)
        case .null: return "null"
        case .object(let members):
            if let value = members.first(where: { ["stringvalue", "intvalue", "doublevalue", "boolvalue", "bytesvalue"].contains($0.key.lowercased()) }) {
                return scalarText(value.value)
            }
            return "{…}"
        case .array: return "[…]"
        }
    }

    /// Preserves ISO timestamps and converts supported epoch units to a stable ISO-8601 string.
    private static func normalizedTimestamp(_ value: StructuredValue) -> String {
        let raw = scalarText(value)
        if case .string(let text) = value, text.count >= 20,
           text.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }), text.contains("T") {
            return text
        }
        let seconds: TimeInterval?
        if case .number(let number) = value, let numeric = Double(number) {
            seconds = epochSeconds(numeric)
        } else if let numeric = Double(raw), raw.allSatisfy({ $0.isNumber || $0 == "." }) {
            seconds = epochSeconds(numeric)
        } else {
            seconds = nil
        }
        if let seconds, seconds.isFinite { return ISO8601TimestampEncoder.shared.string(from: Date(timeIntervalSince1970: seconds)) }
        return raw
    }

    /// Infers seconds, milliseconds, microseconds, or nanoseconds from an epoch magnitude.
    private static func epochSeconds(_ value: Double) -> TimeInterval {
        if abs(value) >= 1e17 { return value / 1e9 }
        if abs(value) >= 1e14 { return value / 1e6 }
        if abs(value) >= 1e11 { return value / 1e3 }
        return value
    }

    /// Flattens an OpenTelemetry `resourceLogs` envelope into its contained log records.
    private static func openTelemetryRecords(_ value: StructuredValue) -> [StructuredValue]? {
        guard case .object(let root) = value,
              case .array(let resourceLogs) = root.first(where: { $0.key == "resourceLogs" })?.value else { return nil }
        var events: [StructuredValue] = []
        for resourceLog in resourceLogs {
            guard case .object(let resourceLogFields) = resourceLog,
                  case .array(let scopeLogs) = resourceLogFields.first(where: { $0.key == "scopeLogs" })?.value else { continue }
            let resource = resourceLogFields.first(where: { $0.key == "resource" })?.value
            for scopeLog in scopeLogs {
                guard case .object(let scopeLogFields) = scopeLog,
                      case .array(let records) = scopeLogFields.first(where: { $0.key == "logRecords" })?.value else { continue }
                let scope = scopeLogFields.first(where: { $0.key == "scope" })?.value
                for record in records {
                    guard case .object(var fields) = record else { continue }
                    if let resource { fields.append(.init(key: "resource", value: resource)) }
                    if let scope { fields.append(.init(key: "scope", value: scope)) }
                    events.append(.object(fields))
                }
            }
        }
        return events
    }

    /// Parses the supported RFC-style Syslog timestamp, host, process, and message fields.
    private static func parseSyslog(_ line: String, lineNumber: Int) -> LogRecord? {
        let rfc5424 = #"^<(\d{1,3})>1\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+((?:\[(?:\\.|[^\]])*\])+|-)\s*(.*)$"#
        if let groups = captures(rfc5424, in: line), let priority = groups[0].flatMap(Int.init), priority <= 191,
           let timestamp = groups[1], let host = groups[2], let app = groups[3],
           let procid = groups[4], let msgid = groups[5], let data = groups[6], let message = groups[7] {
            let fields = [member("host", host), member("app", app), member("procid", procid),
                          member("msgid", msgid), member("structured_data", data), member("priority", String(priority))]
            return .init(line: lineNumber, timestamp: timestamp, level: syslogLevels[priority % 8], message: message, fields: fields)
        }
        let rfc3164 = #"^(?:<(\d{1,3})>)?([A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+(\S+)\s+([^:\s]+):\s?(.*)$"#
        guard let groups = captures(rfc3164, in: line), let timestamp = groups[1], let host = groups[2],
              let app = groups[3], let message = groups[4] else { return nil }
        let priority = groups[0].flatMap(Int.init)
        guard priority.map({ $0 <= 191 }) ?? true else { return nil }
        var fields = [member("host", host), member("app", app)]
        if let priority { fields.append(member("priority", String(priority))) }
        return .init(line: lineNumber, timestamp: timestamp, level: priority.map { syslogLevels[$0 % 8] }, message: message, fields: fields)
    }

    /// Parses common Apache and Nginx access-log lines into request and response fields.
    private static func parseAccessLog(_ line: String, lineNumber: Int) -> LogRecord? {
        let pattern = #"^(\S+)\s+\S+\s+(\S+)\s+\[([^\]]+)\]\s+"([^"]*)"\s+(\d{3})\s+(\S+)(?:\s+"([^"]*)")?(?:\s+"([^"]*)")?$"#
        guard let g = captures(pattern, in: line), let host = g[0], let user = g[1], let timestamp = g[2],
              let request = g[3], let status = g[4], let bytes = g[5] else { return nil }
        var fields = [member("remote_addr", host), member("user", user), member("request", request),
                      member("status", status), member("bytes", bytes)]
        if let referer = g[6] { fields.append(member("referer", referer)) }
        if let agent = g[7] { fields.append(member("user_agent", agent)) }
        let level = status.first == "5" ? "ERROR" : status.first == "4" ? "WARNING" : "INFO"
        return .init(line: lineNumber, timestamp: timestamp, level: level,
                     message: "\(request) \(status) \(bytes)", fields: fields)
    }

    /// Parses whitespace-delimited `key=value` fields while respecting quoted values.
    private static func parseLogfmt(_ line: String, lineNumber: Int) -> LogRecord? {
        let pattern = #"([A-Za-z_][A-Za-z0-9_.-]*)=(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)'|([^\s]+))"#
        guard let regex = regexCache.expression(for: pattern) else { return nil }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else { return nil }
        let fields = matches.compactMap { match -> StructuredMember? in
            let key = nsLine.substring(with: match.range(at: 1))
            guard let valueIndex = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            let raw = nsLine.substring(with: match.range(at: valueIndex))
            return member(key, raw.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\"))
        }
        /// Returns the first parsed field matching one of the logfmt metadata aliases.
        func value(_ aliases: [String]) -> String? { fields.first { aliases.contains($0.key.lowercased()) }.map { scalarText($0.value) } }
        guard !fields.isEmpty else { return nil }
        return .init(line: lineNumber, timestamp: value(["ts", "time", "timestamp", "@timestamp"]),
                     level: value(["level", "severity"]).map { $0.uppercased() },
                     message: value(["msg", "message"]) ?? line, fields: fields)
    }

    /// Parses common Log4j and Logback timestamp, level, logger, and message layouts.
    private static func parseLog4j(_ line: String, lineNumber: Int) -> LogRecord? {
        let pattern = #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+([A-Za-z]+)\s+(?:\[([^\]]*)\]\s+)?([^\s]+)\s+-\s+(.*)$"#
        if let g = captures(pattern, in: line), let timestamp = g[0], let rawLevel = g[1],
           let level = normalizedLevel(rawLevel), let logger = g[3], let message = g[4] {
            var fields = [member("logger", logger)]
            if let thread = g[2] { fields.append(member("thread", thread)) }
            return .init(line: lineNumber, timestamp: timestamp, level: level, message: message, fields: fields)
        }
        let logbackPattern = #"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+\[([^\]]*)\]\s+([A-Za-z]+)\s+([^\s]+)\s+-\s+(.*)$"#
        guard let g = captures(logbackPattern, in: line), let timestamp = g[0], let thread = g[1],
              let level = g[2].flatMap(normalizedLevel), let logger = g[3], let message = g[4] else { return nil }
        return .init(line: lineNumber, timestamp: timestamp, level: level, message: message,
                     fields: [member("thread", thread), member("logger", logger)])
    }

    /// Parses the timestamped severity and message fields from an Nginx error-log line.
    private static func parseNginxError(_ line: String, lineNumber: Int) -> LogRecord? {
        let pattern = #"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[([a-z]+)\] (\d+)#(\d+):(?: \*(\d+))?\s*(.*)$"#
        guard let g = captures(pattern, in: line), let timestamp = g[0], let rawLevel = g[1],
              let level = normalizedLevel(rawLevel), let pid = g[2], let tid = g[3], let message = g[5] else { return nil }
        var fields = [member("pid", pid), member("tid", tid)]
        if let connection = g[4] { fields.append(member("connection", connection)) }
        return .init(line: lineNumber, timestamp: timestamp, level: level, message: message, fields: fields)
    }

    /// Parses a Kubernetes CRI timestamp, stream, partial/full tag, and message.
    private static func parseKubernetesCRI(_ line: String, lineNumber: Int) -> LogRecord? {
        let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) (stdout|stderr) ([FP]) (.*)$"#
        guard let g = captures(pattern, in: line), let timestamp = g[0], let stream = g[1],
              let tag = g[2], let message = g[3] else { return nil }
        return .init(line: lineNumber, timestamp: timestamp, level: stream == "stderr" ? "ERROR" : nil,
                     message: message, fields: [member("stream", stream), member("tag", tag)])
    }

    /// Maps a W3C extended-log row using the most recently declared `#Fields` header.
    private static func parseW3C(_ line: String, lineNumber: Int, names: [String]?) -> LogRecord? {
        guard let names, !names.isEmpty else { return nil }
        let values = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard names.count == values.count else { return nil }
        let fields = zip(names, values).map { member($0.0, $0.1) }
        /// Returns the first non-placeholder W3C field matching one of the requested aliases.
        func value(_ aliases: [String]) -> String? { fields.first { aliases.contains($0.key.lowercased()) && scalarText($0.value) != "-" }.map { scalarText($0.value) } }
        let status = value(["sc-status", "status", "statuscode"])
        let level = status.flatMap(Int.init).map { $0 >= 500 ? "ERROR" : $0 >= 400 ? "WARNING" : "INFO" }
        let message = [value(["cs-method", "method"]), value(["cs-uri-stem", "uri", "cs-uri"]), status].compactMap { $0 }.joined(separator: " ")
        let timestamp: String?
        if let date = value(["date"]), let time = value(["time"]) { timestamp = date + " " + time }
        else { timestamp = value(["datetime", "timestamp", "date", "time"]) }
        return .init(line: lineNumber, timestamp: timestamp, level: level,
                     message: message.isEmpty ? line : message, fields: fields)
    }

    /// Parses CEF headers and extension fields without treating escaped delimiters as separators.
    private static func parseCEF(_ line: String, lineNumber: Int) -> LogRecord? {
        guard line.hasPrefix("CEF:") else { return nil }
        let parts = splitEscaped(line, separator: "|", maximumSplits: 7)
        guard parts.count == 8, parts[0].hasPrefix("CEF:"), let severity = Int(parts[6]), (0...10).contains(severity) else { return nil }
        let keys = ["version", "device_vendor", "device_product", "device_version", "signature_id", "name"]
        var fields = zip(keys, parts[0...5]).map { member($0.0, unescape(partsValue: $0.1.replacingOccurrences(of: "CEF:", with: ""))) }
        fields.append(member("severity", parts[6]))
        fields.append(contentsOf: parseExtensions(parts[7], separators: " "))
        let level = severity >= 8 ? "ERROR" : severity >= 5 ? "WARNING" : "INFO"
        return .init(line: lineNumber, timestamp: nil, level: level, message: parts[5], fields: fields)
    }

    /// Parses a LEEF header and tab-delimited extension fields into a normalized event.
    private static func parseLEEF(_ line: String, lineNumber: Int) -> LogRecord? {
        guard line.hasPrefix("LEEF:") else { return nil }
        let parts = splitEscaped(line, separator: "|", maximumSplits: 6)
        guard (parts.count == 6 || parts.count == 7), parts[0].hasPrefix("LEEF:") else { return nil }
        let keys = ["version", "vendor", "product", "product_version", "event_id"]
        var fields = zip(keys, parts[0...4]).map { member($0.0, unescape(partsValue: $0.1.replacingOccurrences(of: "LEEF:", with: ""))) }
        let extensionText = parts.count == 7 ? parts[6] : parts[5]
        let delimiter = parts.count == 7 ? String(parts[5].first ?? "\t") : "\t"
        fields.append(contentsOf: parseExtensions(extensionText, separators: delimiter))
        let rawLevel = fields.first(where: { ["severity", "level"].contains($0.key.lowercased()) }).map { scalarText($0.value).uppercased() }
        let level = rawLevel.map { value -> String in
            switch value {
            case "VERY-HIGH", "CRITICAL", "FATAL": "ERROR"
            case "HIGH", "WARNING", "WARN": "WARNING"
            case "MEDIUM", "NOTICE", "INFO": "INFO"
            case "LOW", "DEBUG", "TRACE": "DEBUG"
            default: value
            }
        }
        let timestamp = fields.first(where: { ["devtime", "timestamp", "time"].contains($0.key.lowercased()) }).map { scalarText($0.value) }
        let message = fields.first(where: { ["msg", "message", "name"].contains($0.key.lowercased()) }).map { scalarText($0.value) } ?? parts[4]
        return .init(line: lineNumber, timestamp: timestamp, level: level, message: message, fields: fields)
    }

    /// Splits at unescaped separators while preserving escaped characters for later decoding.
    private static func splitEscaped(_ value: String, separator: Character, maximumSplits: Int) -> [String] {
        var parts: [String] = [], part = "", escaped = false
        for character in value {
            if escaped { part.append(character); escaped = false; continue }
            if character == "\\" { part.append(character); escaped = true; continue }
            if character == separator && parts.count < maximumSplits { parts.append(part); part = "" }
            else { part.append(character) }
        }
        parts.append(part)
        return parts
    }

    /// Parses key/value extension text using the format's permitted separator characters.
    private static func parseExtensions(_ text: String, separators: String) -> [StructuredMember] {
        let separatorSet = CharacterSet(charactersIn: separators)
        var tokens: [String] = []
        var token = ""
        var escaped = false
        for character in text {
            if escaped { token.append("\\"); token.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character.unicodeScalars.allSatisfy(separatorSet.contains) {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(character) }
        }
        if escaped { token.append("\\") }
        if !token.isEmpty { tokens.append(token) }
        return tokens.compactMap { token in
            guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return nil }
            let key = String(token[..<equals])
            let raw = String(token[token.index(after: equals)...])
            let value = unescape(partsValue: raw)
            return member(key, value)
        }
    }

    /// Decodes the supported backslash escapes in CEF and LEEF field values.
    private static func unescape(partsValue value: String) -> String {
        var result = "", escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    /// Returns capture groups for a cached regular expression, or nil when matching fails.
    private static func captures(_ pattern: String, in value: String) -> [String?]? {
        guard let regex = regexCache.expression(for: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let range = Range(range, in: value) else { return nil }
            return String(value[range])
        }
    }

    /// Builds a structured string field for normalized log metadata.
    private static func member(_ key: String, _ value: String) -> StructuredMember {
        .init(key: key, value: .string(value))
    }

    /// Reads a named string field from a normalized record's optional field collection.
    private static func fieldValue(_ key: String, in fields: [StructuredMember]?) -> String? {
        fields?.first(where: { $0.key == key }).map { scalarText($0.value) }
    }

    /// Canonicalizes recognized severity labels while rejecting unrelated tokens.
    private static func normalizedLevel(_ token: String) -> String? {
        let raw = token.trimmingCharacters(in: CharacterSet(charactersIn: "[]():")).uppercased()
        let value: String
        switch raw {
        case "EMERG": value = "EMERGENCY"
        case "CRIT": value = "CRITICAL"
        case "ERR": value = "ERROR"
        default: value = raw
        }
        return levels.contains(value) ? value : nil
    }

    /// Extracts a leading timestamp and severity from otherwise unstructured log text.
    private static func parseConventionalLine(_ line: String) -> (String?, String?, String) {
        let prefixPattern = #"^(\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?)\s+(?:\[?([A-Za-z]+)\]?\s+)?(.*)$"#
        if let groups = captures(prefixPattern, in: line), let timestamp = groups[0] {
            return (timestamp, groups[1].flatMap(normalizedLevel), groups[2] ?? line)
        }
        let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return (nil, nil, line) }
        let firstLevel = normalizedLevel(parts[0])
        let firstTimestamp = looksLikeTimestamp(parts[0]) ? parts[0] : nil
        if let firstTimestamp {
            let level = parts.count > 1 ? normalizedLevel(parts[1]) : nil
            return (firstTimestamp, level, parts.dropFirst(level == nil ? 1 : 2).joined(separator: " "))
        }
        if let firstLevel {
            let timestamp = parts.count > 1 && looksLikeTimestamp(parts[1]) ? parts[1] : nil
            return (timestamp, firstLevel, parts.dropFirst(timestamp == nil ? 1 : 2).joined(separator: " "))
        }
        return (nil, nil, line)
    }

    /// Maps GELF's numeric severity values to their conventional names.
    private static func gelfLevel(_ value: Int) -> String {
        switch value { case 0: "EMERGENCY"; case 1: "ALERT"; case 2: "CRITICAL"; case 3: "ERROR"; case 4: "WARNING"; case 5: "NOTICE"; case 6: "INFO"; default: "DEBUG" }
    }

    /// Maps OpenTelemetry severity numbers to their TRACE-through-FATAL text levels.
    private static func openTelemetryLevel(_ value: Int) -> String? {
        switch value {
        case 1...4: "TRACE"
        case 5...8: "DEBUG"
        case 9...12: "INFO"
        case 13...16: "WARN"
        case 17...20: "ERROR"
        case 21...24: "FATAL"
        default: nil
        }
    }

    /// Recognizes the bounded timestamp shapes accepted by the conventional-line parser.
    private static func looksLikeTimestamp(_ value: String) -> Bool {
        value.count >= 10 && value.prefix(4).allSatisfy(\.isNumber) && value.dropFirst(4).first == "-"
    }
}

/// Shares compiled log-format expressions safely across concurrent inspection requests.
private final class RegularExpressionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var expressions: [String: NSRegularExpression] = [:]

    /// Returns a cached compiled expression, synchronizing creation and cache access.
    func expression(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let expression = expressions[pattern] { return expression }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        expressions[pattern] = expression
        return expression
    }
}

/// Reuses an ISO-8601 formatter without sharing mutable formatter state between threads.
private final class ISO8601TimestampEncoder: @unchecked Sendable {
    static let shared = ISO8601TimestampEncoder()
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    /// Configures the cached formatter to emit deterministic internet date/time strings.
    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Formats a date while serializing access to the shared Foundation formatter.
    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
