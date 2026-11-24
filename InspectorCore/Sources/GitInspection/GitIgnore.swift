import Foundation

/// Git's exclude rules from `core.excludesFile`, `info/exclude` and per-directory `.gitignore`
/// files, evaluated as `git check-ignore` does. Global excludes are not consulted.
final class GitIgnore {
    private struct Rule {
        let pattern: [UInt8]
        let base: [UInt8]
        let negated: Bool
        let directoryOnly: Bool
        let matchesPath: Bool
    }

    private static let maximumFileBytes = 1 << 20
    private let worktree: URL
    private let globalRules: [Rule]
    private var directoryRules: [String: [Rule]] = [:]

    init(worktree: URL, sources: [URL]) throws {
        self.worktree = worktree
        globalRules = try sources.flatMap { try Self.rules(at: $0, base: []) }
    }

    /// Whether an untracked file at `relativePath` is excluded, directly or through a parent directory.
    func isIgnored(relativePath: String) throws -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        var groups = [globalRules, try rules(inDirectory: "")]
        for depth in 1..<components.count {
            let directory = components[..<depth].joined(separator: "/")
            // An excluded directory is never entered, so nothing inside it can be re-included.
            if decision(for: Array(directory.utf8), isDirectory: true, groups) { return true }
            groups.append(try rules(inDirectory: directory))
        }
        return decision(for: Array(relativePath.utf8), isDirectory: false, groups)
    }

    /// The last matching rule wins; later groups are deeper and so take precedence.
    private func decision(for path: [UInt8], isDirectory: Bool, _ groups: [[Rule]]) -> Bool {
        let name = path.split(separator: UInt8(ascii: "/")).last.map(Array.init) ?? path
        for rules in groups.reversed() {
            for rule in rules.reversed() {
                guard !rule.directoryOnly || isDirectory else { continue }
                let matched: Bool
                if rule.matchesPath {
                    guard path.starts(with: rule.base) else { continue }
                    matched = GitWildmatch.matches(rule.pattern[...], Array(path.dropFirst(rule.base.count))[...])
                } else {
                    matched = GitWildmatch.matches(rule.pattern[...], name[...])
                }
                if matched { return !rule.negated }
            }
        }
        return false
    }

    private func rules(inDirectory directory: String) throws -> [Rule] {
        if let cached = directoryRules[directory] { return cached }
        let file = directory.isEmpty
            ? worktree.appendingPathComponent(".gitignore")
            : worktree.appending(path: directory).appendingPathComponent(".gitignore")
        // Git does not follow a symlinked `.gitignore` inside the worktree.
        let rules = VCSPath.kind(file) == .regular
            ? try Self.rules(at: file, base: directory.isEmpty ? [] : Array((directory + "/").utf8)) : []
        directoryRules[directory] = rules
        return rules
    }

    private static func rules(at file: URL, base: [UInt8]) throws -> [Rule] {
        guard let data = try GitMetadata.read(file, maximumBytes: maximumFileBytes) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { rule(Array($0), base: base) }
    }

    private static func rule(_ line: [UInt8], base: [UInt8]) -> Rule? {
        var pattern = line
        if pattern.last == UInt8(ascii: "\r") { pattern.removeLast() }
        guard let first = pattern.first, first != UInt8(ascii: "#") else { return nil }
        trimTrailingSpaces(&pattern)
        var negated = false
        if pattern.first == UInt8(ascii: "!") {
            negated = true
            pattern.removeFirst()
        }
        var directoryOnly = false
        if pattern.last == UInt8(ascii: "/") {
            directoryOnly = true
            pattern.removeLast()
        }
        guard !pattern.isEmpty else { return nil }
        let matchesPath = pattern.contains(UInt8(ascii: "/"))
        if pattern.first == UInt8(ascii: "/") { pattern.removeFirst() }
        return Rule(pattern: pattern, base: base, negated: negated, directoryOnly: directoryOnly,
                    matchesPath: matchesPath)
    }

    /// Removes unescaped trailing spaces, as Git does before parsing a pattern.
    private static func trimTrailingSpaces(_ pattern: inout [UInt8]) {
        while pattern.last == UInt8(ascii: " ") {
            let backslashes = pattern.dropLast().reversed().prefix { $0 == UInt8(ascii: "\\") }.count
            if backslashes % 2 == 1 { return }
            pattern.removeLast()
        }
    }
}

/// Git's `wildmatch` with `WM_PATHNAME`: `*`, `?` and classes never match `/`, and `**` between
/// slashes or at either end matches across directories.
enum GitWildmatch {
    static func matches(_ pattern: ArraySlice<UInt8>, _ text: ArraySlice<UInt8>) -> Bool {
        var budget = 100_000
        return match(pattern, text, &budget)
    }

    private static let slash = UInt8(ascii: "/")

    private static func match(_ pattern: ArraySlice<UInt8>, _ text: ArraySlice<UInt8>, _ budget: inout Int) -> Bool {
        budget -= 1
        guard budget > 0 else { return false }
        var p = pattern.startIndex
        var t = text.startIndex
        while p < pattern.endIndex {
            let character = pattern[p]
            if character == UInt8(ascii: "*") {
                let starStart = p
                while p < pattern.endIndex, pattern[p] == UInt8(ascii: "*") { p += 1 }
                let doubled = p - starStart >= 2
                let atSegmentStart = starStart == pattern.startIndex || pattern[starStart - 1] == slash
                if doubled, atSegmentStart, p == pattern.endIndex || pattern[p] == slash {
                    if p == pattern.endIndex { return true }
                    // `**/` matches zero or more leading directories.
                    let rest = pattern[(p + 1)...]
                    if match(rest, text[t...], &budget) { return true }
                    var index = t
                    while index < text.endIndex {
                        if text[index] == slash, match(rest, text[(index + 1)...], &budget) { return true }
                        index += 1
                    }
                    return false
                }
                // A single star (or a `**` that is not a whole segment) stays within one segment.
                let rest = pattern[p...]
                var index = t
                while true {
                    if match(rest, text[index...], &budget) { return true }
                    guard index < text.endIndex, text[index] != slash else { return false }
                    index += 1
                }
            }
            guard t < text.endIndex else { return false }
            switch character {
            case UInt8(ascii: "?"):
                guard text[t] != slash else { return false }
            case UInt8(ascii: "["):
                guard let next = matchClass(pattern, from: p, text[t]) else { return false }
                p = next
                t += 1
                continue
            case UInt8(ascii: "\\"):
                p += 1
                guard p < pattern.endIndex, pattern[p] == text[t] else { return false }
            default:
                guard character == text[t] else { return false }
            }
            p += 1
            t += 1
        }
        return t == text.endIndex
    }

    /// Matches one byte against the class opening at `start`; returns the index after `]` on success.
    private static func matchClass(_ pattern: ArraySlice<UInt8>, from start: Int, _ byte: UInt8) -> Int? {
        guard byte != slash else { return nil }
        var p = start + 1
        var negated = false
        if p < pattern.endIndex, pattern[p] == UInt8(ascii: "!") || pattern[p] == UInt8(ascii: "^") {
            negated = true
            p += 1
        }
        var matched = false
        var first = true
        while p < pattern.endIndex {
            var low = pattern[p]
            if low == UInt8(ascii: "]"), !first { return matched != negated ? p + 1 : nil }
            first = false
            if low == UInt8(ascii: "\\"), p + 1 < pattern.endIndex {
                p += 1
                low = pattern[p]
            }
            if p + 2 < pattern.endIndex, pattern[p + 1] == UInt8(ascii: "-"), pattern[p + 2] != UInt8(ascii: "]") {
                var high = pattern[p + 2]
                p += 2
                if high == UInt8(ascii: "\\"), p + 1 < pattern.endIndex {
                    p += 1
                    high = pattern[p]
                }
                if low <= byte, byte <= high { matched = true }
            } else if low == byte {
                matched = true
            }
            p += 1
        }
        // An unterminated class never matches, as in Git.
        return nil
    }
}
