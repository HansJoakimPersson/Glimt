import Foundation

/// One inert value declaration from a Windows Registry export.
public struct WindowsRegistryEntry: Equatable, Sendable {
    public let keyPath: String
    public let name: String
    public let kind: String
    public let data: String
    public let line: Int
}

/// Bounded facts extracted from a Windows Registry export; no registry APIs are called.
public struct WindowsRegistryInspection: Sendable {
    public let entries: [WindowsRegistryEntry]
    public let diagnostics: [InspectionDiagnostic]
    public let rawIsComplete: Bool
}

/// Reads the textual subset of `.reg` exports without applying, expanding, or evaluating values.
public enum WindowsRegistryInspector {
    /// Parses a bounded export and preserves the original input separately in the preview pipeline.
    public static func inspect(_ text: String, isComplete: Bool = true,
                               maximumLines: Int = 20_000) throws -> WindowsRegistryInspection {
        let lines = text.components(separatedBy: .newlines)
        let limit = min(maximumLines, 20_000)
        var entries: [WindowsRegistryEntry] = []
        var diagnostics: [InspectionDiagnostic] = []
        var keyPath: String?
        var hasHeader = false

        var offset = 0
        while offset < min(lines.count, limit) {
            try Task.checkCancellation()
            let lineNumber = offset + 1
            let line = lines[offset].trimmingCharacters(in: .whitespaces)
            offset += 1
            if line.isEmpty { continue }
            if !hasHeader {
                if line == "REGEDIT4" || line == "Windows Registry Editor Version 5.00" {
                    hasHeader = true
                    continue
                }
                diagnostics.append(.init(code: .unsupported, message: "Unsupported Windows Registry export header."))
                break
            }
            if line.hasPrefix(";") { continue }
            if line.first == "[", line.last == "]" {
                let rawPath = String(line.dropFirst().dropLast())
                let isDeletion = rawPath.hasPrefix("-")
                let path = isDeletion ? String(rawPath.dropFirst()) : rawPath
                guard Self.isRegistryPath(path) else {
                    keyPath = nil
                    diagnostics.append(.init(code: .parseError, message: "Invalid registry key at line \(lineNumber)."))
                    continue
                }
                keyPath = path
                if isDeletion {
                    entries.append(.init(keyPath: path, name: "(key)", kind: "delete-key", data: "", line: lineNumber))
                }
                continue
            }
            guard let keyPath else {
                diagnostics.append(.init(code: .parseError, message: "Registry value appears before a valid key at line \(lineNumber)."))
                continue
            }
            guard let separator = Self.assignmentSeparator(in: line) else {
                diagnostics.append(.init(code: .parseError, message: "Malformed registry value at line \(lineNumber)."))
                continue
            }
            let rawName = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var rawData = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard let name = Self.decodeName(rawName), !rawData.isEmpty else {
                diagnostics.append(.init(code: .parseError, message: "Malformed registry value at line \(lineNumber)."))
                continue
            }
            let kind: String
            let data: String
            if rawData == "-" {
                kind = "delete-value"
                data = ""
            } else if rawData.lowercased().hasPrefix("dword:") || rawData.lowercased().hasPrefix("hex:")
                || rawData.range(of: #"^hex\([0-9a-f]+\):"#, options: [.regularExpression, .caseInsensitive]) != nil {
                if rawData.lowercased().hasPrefix("hex"), rawData.hasSuffix("\\") {
                    while rawData.hasSuffix("\\"), offset < min(lines.count, limit) {
                        rawData.removeLast()
                        rawData += lines[offset].trimmingCharacters(in: .whitespaces)
                        offset += 1
                    }
                }
                let split = rawData.firstIndex(of: ":")
                kind = split.map { String(rawData[..<$0]).lowercased() } ?? "value"
                data = split.map { String(rawData[rawData.index(after: $0)...]) } ?? rawData
            } else if rawData.first == "\"", rawData.last == "\"", rawData.count >= 2 {
                kind = "string"
                data = String(rawData.dropFirst().dropLast())
            } else {
                diagnostics.append(.init(code: .unsupported, message: "Unsupported registry value syntax at line \(lineNumber)."))
                continue
            }
            entries.append(.init(keyPath: keyPath, name: name, kind: kind, data: data, line: lineNumber))
            if entries.count >= 10_000 {
                diagnostics.append(.init(code: .limitExceeded, message: "Registry entry limit reached."))
                break
            }
        }

        if !hasHeader && diagnostics.isEmpty {
            diagnostics.append(.init(code: .unsupported, message: "Windows Registry export header is missing."))
        }
        let inspectedAllLines = offset >= lines.count
        var complete = isComplete && inspectedAllLines && !diagnostics.contains { $0.code == .limitExceeded }
        if !complete && !diagnostics.contains(where: { $0.code == .truncated || $0.code == .limitExceeded }) {
            diagnostics.append(.init(code: .truncated, message: "Registry preview is incomplete; Raw retains the available text."))
        }
        if !hasHeader { complete = false }
        return .init(entries: entries, diagnostics: diagnostics, rawIsComplete: complete)
    }

    private static func assignmentSeparator(in line: String) -> String.Index? {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\"", !escaped { quoted.toggle() }
            if character == "=", !quoted { return index }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        return nil
    }

    private static func decodeName(_ raw: String) -> String? {
        if raw == "@" { return "(Default)" }
        guard raw.first == "\"", raw.last == "\"", raw.count >= 2 else { return nil }
        return String(raw.dropFirst().dropLast()).replacingOccurrences(of: #"\\""#, with: "\"")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
    }

    private static func isRegistryPath(_ path: String) -> Bool {
        let candidate = path.lowercased()
        let hives = ["hkey_classes_root", "hkey_current_user", "hkey_local_machine", "hkey_users", "hkey_current_config"]
        return hives.contains { candidate == $0 || candidate.hasPrefix($0 + "\\") }
    }
}
