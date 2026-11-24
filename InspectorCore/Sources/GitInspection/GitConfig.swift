import Foundation

/// The subset of Git's config syntax needed for repository-local settings. Includes are not followed.
struct GitConfig {
    /// Keys are `section.key` or `section.subsection.key`; section and key are lowercased.
    private(set) var values: [String: String] = [:]

    init() {}

    init(parsing data: Data) {
        var section = ""
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)[...]
        while var line = lines.popFirst() {
            // A trailing backslash continues the value on the next line.
            while line.hasSuffix("\\"), let next = lines.popFirst() { line = String(line.dropLast()) + next }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                guard let close = trimmed.lastIndex(of: "]") else { continue }
                section = Self.sectionName(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                let remainder = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty, !remainder.hasPrefix("#"), !remainder.hasPrefix(";") {
                    assign(remainder, in: section)
                }
                continue
            }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), !section.isEmpty else { continue }
            assign(trimmed, in: section)
        }
    }

    /// Later files override earlier ones, as Git's configuration levels do.
    mutating func merge(_ other: GitConfig) {
        values.merge(other.values) { _, new in new }
    }

    func string(_ key: String) -> String? {
        values[key]
    }

    /// Git's boolean spellings; an unrecognized value is treated as absent.
    func bool(_ key: String) -> Bool? {
        switch values[key]?.lowercased() {
        case "true", "yes", "on", "1", "": true
        case "false", "no", "off", "0": false
        default: nil
        }
    }

    /// Lowercased key names and values set under one section without a subsection.
    func entries(inSection section: String) -> [(String, String)] {
        let prefix = section.lowercased() + "."
        return values.compactMap { key, value in
            let name = key.dropFirst(prefix.count)
            guard key.hasPrefix(prefix), !name.contains(".") else { return nil }
            return (String(name), value)
        }
    }

    private static func sectionName(_ header: Substring) -> String {
        guard let quote = header.firstIndex(of: "\"") else {
            // The legacy `[section.subsection]` form lowercases the whole name.
            return header.trimmingCharacters(in: .whitespaces).lowercased()
        }
        let name = header[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
        var subsection = ""
        var escaped = false
        for character in header[header.index(after: quote)...] {
            if escaped {
                subsection.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                subsection.append(character)
            }
        }
        return name + "." + subsection
    }

    private mutating func assign(_ line: String, in section: String) {
        guard let equals = line.firstIndex(of: "=") else {
            let name = line.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            if !name.isEmpty { values[section + "." + name.lowercased()] = "" }
            return
        }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        values[section + "." + name] = Self.value(line[line.index(after: equals)...])
    }

    /// Unquotes a value, applies escapes and drops a trailing comment outside quotes.
    private static func value(_ raw: Substring) -> String {
        var result = ""
        var quoted = false
        var pendingSpaces = ""
        var iterator = raw.drop { $0 == " " || $0 == "\t" }.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                result += pendingSpaces
                pendingSpaces = ""
                quoted.toggle()
            case "\\":
                guard let escaped = iterator.next() else { break }
                result += pendingSpaces
                pendingSpaces = ""
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "b": result = String(result.dropLast())
                default: result.append(escaped)
                }
            case "#" where !quoted, ";" where !quoted:
                return result
            case " " where !quoted, "\t" where !quoted:
                pendingSpaces.append(character)
            default:
                result += pendingSpaces
                pendingSpaces = ""
                result.append(character)
            }
        }
        return result
    }
}
