import Foundation

/// Bounded lexical coloring, not a compiler. Interpolation interiors, JavaScript regex literals
/// and shell heredoc bodies have no dedicated grammar in v1 and retain lexical/plain coloring.
public struct InternalSyntaxHighlighter: SyntaxHighlighting {
    /// Creates the bounded built-in lexer used when no platform highlighter is available.
    public init() {}

    /// Produces UTF-16 token ranges for the supported language subset, failing on time or size limits.
    public func highlight(_ source: String, language: SourceLanguage) throws -> HighlightedSource {
        try highlight(source, language: language, literateHaskell: false)
    }

    /// Highlights the supported language subset, optionally excluding prose in literate Haskell.
    public func highlight(_ source: String, language: SourceLanguage, literateHaskell: Bool) throws -> HighlightedSource {
        var scanner = SourceTokenScanner(source: source, language: language, literateHaskell: literateHaskell)
        return try scanner.scan()
    }
}

/// Scans bounded UTF-16 source and emits language-aware token ranges without parsing or execution.
private struct SourceTokenScanner {
    private enum GraphvizNumberScan {
        case notNumber
        case number(end: Int)
        case plain(end: Int)
    }

    private struct TemplateMarker {
        let opening: [UInt16]
        let closing: [UInt16]
        let language: SourceLanguage?
        let isComment: Bool
    }

    let units: [UInt16]
    let language: SourceLanguage
    let literateHaskell: Bool
    var index = 0
    var runs: [HighlightRun] = []
    private var nextCheckpointIndex = 256

    /// Caps the copied input before scanning so oversized input can be rejected without unbounded work.
    init(source: String, language: SourceLanguage, literateHaskell: Bool = false) {
        units = Array(source.utf16.prefix(1_048_577))
        self.language = language
        self.literateHaskell = literateHaskell && language == .haskell
    }

    /// Scans lexical tokens only; unsupported grammar remains uncolored instead of being guessed.
    mutating func scan() throws -> HighlightedSource {
        guard units.count <= 1_048_576 else { throw SyntaxHighlightingFailure.limit }
        try checkpoint()
        if language.isConfiguration {
            try scanConfiguration()
            return .init(runs: runs)
        }
        if language == .gitignore || language == .dockerignore { return try scanIgnorePatterns() }
        if language == .gitAttributes { return try scanGitAttributes() }
        if language == .goModule { return try scanGoModule() }
        if language == .markdown { return try scanMarkdown() }
        if language == .graphviz { return try scanGraphviz() }
        if language == .bison { return try scanBison() }
        if language == .erb { return try scanERB() }
        if language == .asciidoc { return try scanAsciiDoc() }
        if language == .reStructuredText { return try scanReStructuredText() }
        if language == .org { return try scanOrgMode() }
        if [.asp, .aspx, .jinja, .twig].contains(language) { return try scanTemplate() }
        if language == .makefile { return try scanMakefile() }
        if language == .dtd { return try scanDTD() }
        if language == .xquery { return try scanXQuery() }
        if language == .haml { return try scanHaml() }
        if language == .jsp { return try scanJSP() }
        if language == .latex { return try scanLaTeX() }
        if [.html, .vue, .svelte].contains(language) { return try scanHTML() }
        let words = Self.keywords[language] ?? []
        let types = Self.types[language] ?? []
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if literateHaskell, isLineStart(index), try skipLiterateHaskellText() { continue }
            let start = index
            let unit = units[index]
            if language == .cobol && isCobolFixedFormComment(at: index) {
                try scanLine()
                try append(start, .comment)
            } else if coldFusionCommentStart {
                index += 5
                try scan(until: [45, 45, 45])
                try append(start, .comment)
            } else if coffeescriptBlockCommentStart {
                index += 3
                try scan(until: [35, 35, 35])
                try append(start, .comment)
            } else if clojureKeywordStart {
                index += 1
                while index < units.count && identifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                try append(start, .keyword)
            } else if language == .lisp && unit == 59 {
                index += 1
                try scanLine()
                try append(start, .comment)
            } else if language == .lisp && unit == 35 && next() == 124 {
                index += 2
                try scanLispBlockComment()
                try append(start, .comment)
            } else if visualBasicRemark(at: index) {
                index += 3
                try scanLine()
                try append(start, .comment)
            } else if language == .nim && unit == 35 && next() == 91 {
                index += 2
                try scanNimBlockComment()
                try append(start, .comment)
            } else if language == .webAssemblyText && unit == 59 && next() == 59 {
                index += 2
                try scanLine()
                try append(start, .comment)
            } else if language == .pascal && (unit == 123 || (unit == 40 && next() == 42)) {
                let close: [UInt16] = unit == 123 ? [125] : [42, 41]
                index += unit == 123 ? 1 : 2
                try scan(until: close)
                try append(start, .comment)
            } else if [.openSCAD, .webAssemblyText].contains(language) && unit == 36 {
                index += 1
                while index < units.count && identifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                if index > start + 1 { try append(start, .variable) }
            } else if language == .lua && unit == 45 && next() == 45 {
                if let bracket = luaLongBracket(at: index + 2) {
                    index = bracket.contentStart
                    try scanLuaLongBracket(level: bracket.level)
                } else {
                    index += 2
                    try scanLine()
                }
                try append(start, .comment)
            } else if language == .lua, unit == 91, let bracket = luaLongBracket(at: index) {
                index = bracket.contentStart
                try scanLuaLongBracket(level: bracket.level)
                try append(start, .string)
            } else if language == .julia && unit == 35 && next() == 61 {
                index += 2
                try scanJuliaBlockComment()
                try append(start, .comment)
            } else if (language == .perl && [36, 64, 37].contains(unit))
                        || (language == .r && [36, 64].contains(unit)) {
                try scanSigilVariable()
                if index > start + 1 { try append(start, .variable) }
                else { index += 1 }
            } else if language == .turtle && unit == 60 {
                index += 1
                while index < units.count && units[index] != 62 && units[index] != 10 && units[index] != 13 {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                if index < units.count && units[index] == 62 { index += 1 }
                try append(start, .string)
            } else if let lineCommentLength = lineCommentLength(at: index) {
                index += lineCommentLength
                try scanLine()
                try append(start, .comment)
            } else if let blockComment = blockComment(at: index) {
                index += blockComment.openingLength
                try scanBlockComment(opening: blockComment.opening, closing: blockComment.closing)
                try append(start, .comment)
            } else if language == .eiffel && unit == 45 && next() == 45 {
                index += 2
                try scanLine()
                try append(start, .comment)
            } else if language == .assembly && unit == 59 {
                index += 1
                try scanLine()
                try append(start, .comment)
            } else if (unit == 35 && [.python, .shell, .awk, .fish, .gdscript, .powershell, .dockerfile].contains(language) && hashStartsComment)
                        || (language == .elixir && unit == 35) || (language == .erlang && unit == 37) {
                index += 1
                try scanLine()
                try append(start, start == 0 && index > 1 && units[1] == 33 ? .directive : .comment)
            } else if language == .batch, isBatchRemark(at: index), try linePrefixIsWhitespace() {
                index += 3
                try scanLine()
                try append(start, .comment)
            } else if language == .swift, unit == 35, let quote = rawSwiftQuote() {
                try scanString(quoteIndex: quote, hashes: quote - start)
                try append(start, .string)
            } else if unit == 35 && (language == .c || language == .cpp || language == .objectiveC || language == .swift || language == .assembly || language == .csharp || language == .xcconfig), try linePrefixIsWhitespace() {
                index += 1
                try scanLine()
                try append(start, .directive)
            } else if language == .powershell && (unit == 34 || unit == 39) {
                try scanPowerShellString()
                try append(start, .string)
            } else if [.pascal, .innoSetup].contains(language) && unit == 39 {
                try scanPascalString()
                try append(start, .string)
            } else if language == .cobol && (unit == 34 || unit == 39) {
                try scanCobolString()
                try append(start, .string)
            } else if [.less, .scss].contains(language) && unit == 64 {
                let kind = try scanLessAtRuleOrVariable()
                try append(start, kind)
            } else if language == .scss && unit == 36 {
                index += 1
                while index < units.count && (identifierContinuation(units[index]) || units[index] == 45) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                try append(start, .variable)
            } else if language == .powershell && unit == 36 {
                try scanPowerShellVariable()
                try append(start, .variable)
            } else if language == .nsis && unit == 36 {
                try scanNSISVariable()
                try append(start, .variable)
            } else if language == .php && unit == 36 {
                try scanPHPVariable()
                try append(start, .variable)
            } else if language == .tsql && unit == 64 {
                index += 1
                if index < units.count, units[index] == 64 { index += 1 }
                while index < units.count && (identifierContinuation(units[index]) || (language == .cobol && units[index] == 45)) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                if index > start + 1 { try append(start, .variable) }
            } else if language == .nix && unit == 39 && next() == 39 {
                try scanNixIndentedString()
                try append(start, .string)
            } else if isStringStart(at: index) {
                try scanString(quoteIndex: index)
                try append(start, .string)
            } else if language == .assembly && unit == 46 && index + 1 < units.count && identifierStart(units[index + 1]) {
                index += 2
                while index < units.count && identifierContinuation(units[index]) { index += 1 }
                try append(start, .directive)
            } else if digit(unit) {
                try scanNumber()
                try append(start, .number)
            } else if identifierStart(unit) {
                index += 1
                while index < units.count && identifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                if language == .webAssemblyText, index < units.count, units[index] == 46 {
                    index += 1
                    while index < units.count && identifierContinuation(units[index]) {
                        try checkpointIfNeeded(at: index)
                        index += 1
                    }
                }
                let rawWord = String(decoding: units[start..<index], as: UTF16.self)
                let word = ([.ada, .assembly, .awk, .sql, .plsql, .tsql, .dockerfile, .visualBasic, .nim, .openSCAD, .pascal, .vhdl, .cobol, .deviceTree, .qml, .autoHotkey, .innoSetup, .nsis, .ldif].contains(language)) ? rawWord.lowercased() : rawWord
                if language == .python, Self.pythonPrefixes.contains(word.lowercased()), index < units.count,
                   units[index] == 34 || units[index] == 39 {
                    try scanString(quoteIndex: index)
                    try append(start, .string)
                } else if language == .visualBasic && types.contains(word) {
                    try append(start, .type)
                } else if [.pascal, .verilog, .vhdl, .cobol, .deviceTree, .qml].contains(language) && types.contains(word) {
                    try append(start, .type)
                } else if language == .solidity && (types.contains(word) || Self.solidityTypes.contains(word)) {
                    try append(start, .type)
                } else if words.contains((language == .fortran || language == .cmake) ? word.lowercased() : word)
                            || (language == .cpp && Self.cudaKeywords.contains(word)) {
                    try append(start, .keyword)
                }
                else if types.contains(word) || (language != .shell && language != .yang && (65...90).contains(unit)) { try append(start, .type) }
            } else { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Colors DOT's lexical surface while leaving HTML-like labels opaque and inert.
    private mutating func scanGraphviz() throws -> HighlightedSource {
        let keywords: Set<String> = ["strict", "graph", "digraph", "subgraph", "node", "edge"]
        let delimiters: Set<UInt16> = [123, 125, 91, 93, 61, 58, 59, 44, 43]
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            let unit = units[index]
            if unit == 47, next() == 47 {
                index += 2
                try scanLine()
                try append(start, .comment)
            } else if unit == 47, next() == 42 {
                index += 2
                try scan(until: [42, 47])
                try append(start, .comment)
            } else if unit == 35, try linePrefixIsWhitespace() {
                index += 1
                try scanLine()
                try append(start, .directive)
            } else if unit == 34 {
                try scanGraphvizString()
                try append(start, .string)
            } else if unit == 60 {
                try scanGraphvizLabel()
            } else if unit == 45, next() == 62 || next() == 45 {
                index += 2
                try append(start, .keyword)
            } else if delimiters.contains(unit) {
                index += 1
                try append(start, .keyword)
            } else if unit == 45 || unit == 46 || digit(unit) {
                switch try graphvizNumberScan(from: index) {
                case .number(let end):
                    index = end
                    try append(start, .number)
                case .plain(let end):
                    index = end
                case .notNumber:
                    index += 1
                }
            } else if identifierStart(unit) {
                index += 1
                while index < units.count && graphvizIdentifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                let word = String(decoding: units[start..<index].map(graphvizASCIILowercase), as: UTF16.self)
                if keywords.contains(word) { try append(start, .keyword) }
            } else {
                index += 1
            }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Distinguishes decimals from number-shaped identifiers without losing the following token.
    private mutating func graphvizNumberScan(from start: Int) throws -> GraphvizNumberScan {
        var end = start
        if units[end] == 45 { end += 1 }
        guard end < units.count else { return .notNumber }
        if digit(units[end]) {
            while end < units.count && digit(units[end]) { try checkpointIfNeeded(at: end); end += 1 }
            if end < units.count, units[end] == 46 {
                end += 1
                while end < units.count && digit(units[end]) { try checkpointIfNeeded(at: end); end += 1 }
            }
        } else if units[end] == 46, end + 1 < units.count, digit(units[end + 1]) {
            end += 2
            while end < units.count && digit(units[end]) { try checkpointIfNeeded(at: end); end += 1 }
        } else {
            return .notNumber
        }

        guard end < units.count, graphvizIdentifierStart(units[end]) else { return .number(end: end) }
        let identifierStart = end
        while end < units.count && graphvizIdentifierContinuation(units[end]) {
            try checkpointIfNeeded(at: end)
            end += 1
        }
        if end == identifierStart + 1, [69, 101].contains(units[identifierStart]),
           end < units.count,
           [43, 45].contains(units[end]),
           end + 1 < units.count, digit(units[end + 1]) {
            end += 2
            while end < units.count && graphvizIdentifierContinuation(units[end]) {
                try checkpointIfNeeded(at: end)
                end += 1
            }
        }
        return .plain(end: end)
    }

    /// Consumes a DOT string, honoring escaped Unicode scalars and escaped physical line breaks.
    private mutating func scanGraphvizString() throws {
        index += 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let unit = units[index]
            if unit == 34 { index += 1; return }
            if unit == 10 || unit == 13 { return }
            if unit == 92 {
                guard index + 1 < units.count else { index += 1; return }
                let escaped = units[index + 1]
                if escaped == 10 { index += 2; continue }
                if escaped == 13 {
                    if index + 2 < units.count, units[index + 2] == 10 { index += 3; continue }
                    return
                }
                index += 2
                if (0xD800...0xDBFF).contains(escaped), index < units.count,
                   (0xDC00...0xDFFF).contains(units[index]) { index += 1 }
                continue
            }
            index += 1
        }
    }

    /// Shields a complete angle-delimited label, including nested tags, comments, and attributes.
    private mutating func scanGraphvizLabel() throws {
        if units[index...].starts(with: [60, 33, 45, 45]) {
            index += 4
            try scan(until: [45, 45, 62])
            return
        }
        var depth = 0
        var quote: UInt16?
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if quote == nil, units[index...].starts(with: [60, 33, 45, 45]) {
                index += 4
                try scan(until: [45, 45, 62])
                continue
            }
            let unit = units[index]
            if let activeQuote = quote {
                if unit == activeQuote { quote = nil }
                index += 1
                continue
            }
            if unit == 61, depth >= 2 {
                var valueStart = index + 1
                while valueStart < units.count, [32, 9, 10, 13].contains(units[valueStart]) {
                    try checkpointIfNeeded(at: valueStart)
                    valueStart += 1
                }
                if valueStart < units.count, [34, 39].contains(units[valueStart]) {
                    index = valueStart
                    quote = units[index]
                    index += 1
                    continue
                }
            }
            // DOT edge operators can appear as label text; their `>` is not an HTML-like closer.
            if unit == 62, index > 0, units[index - 1] == 45 {
                index += 1
                continue
            }
            if unit == 60 { depth += 1 }
            else if unit == 62 {
                depth -= 1
                index += 1
                if depth <= 0 { return }
                continue
            }
            index += 1
        }
    }

    private func graphvizIdentifierStart(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit >= 128
    }

    private func graphvizIdentifierContinuation(_ unit: UInt16) -> Bool {
        graphvizIdentifierStart(unit) || digit(unit)
    }

    private func graphvizASCIILowercase(_ unit: UInt16) -> UInt16 {
        (65...90).contains(unit) ? unit + 32 : unit
    }

    /// Colors only the outer Bison grammar and comments, quotes, and semantic references inside C spans.
    private mutating func scanBison() throws -> HighlightedSource {
        enum Section { case declarations, rules }
        var section = Section.declarations
        var markers = 0

        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            let unit = units[index]

            if unit == 47, next() == 47 {
                try scanBisonLineComment(embedded: false)
                try append(start, .comment)
            } else if unit == 47, next() == 42 {
                try scanBisonBlockComment()
                try append(start, .comment)
            } else if unit == 34 || unit == 39 {
                try scanBisonQuote()
                try append(start, .string)
            } else if unit == 37, next() == 123, section == .declarations {
                index += 2
                try append(start, .directive)
                try scanBisonPrologue()
            } else if unit == 37, next() == 37, try bisonSectionMarker(at: index) {
                index += 2
                try append(start, .directive)
                markers += 1
                if markers == 1 {
                    section = .rules
                } else {
                    index = units.count
                }
            } else if unit == 37, index + 1 < units.count, bisonASCIILetter(units[index + 1]) {
                index += 2
                while index < units.count && bisonDirectiveContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                try append(start, .directive)
            } else if unit == 123 {
                index += 1
                try scanBisonBraceSpan()
            } else if section == .rules, bisonLabelStart(unit) {
                if try scanBisonProductionLabel() { continue }
                index += 1
            } else if section == .rules, [58, 124, 59].contains(unit) {
                if bisonGrammarSeparator(at: index) {
                    index += 1
                    try append(start, .keyword)
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Scans a declaration prologue until an unshielded `%}`; code tokens otherwise remain plain.
    private mutating func scanBisonPrologue() throws {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            if units[index] == 37, next() == 125 {
                index += 2
                try append(start, .directive)
                return
            }
            if units[index] == 47, next() == 47 {
                try scanBisonLineComment(embedded: true)
                try append(start, .comment)
            } else if units[index] == 47, next() == 42 {
                try scanBisonBlockComment()
                try append(start, .comment)
            } else if units[index] == 34 || units[index] == 39 {
                try scanBisonQuote()
                try append(start, .string)
            } else if bisonRawStringStart(at: index) {
                index = units.count
            } else {
                index += 1
            }
        }
    }

    /// Scans a nested C action or code block iteratively, limiting brace depth to 256.
    private mutating func scanBisonBraceSpan() throws {
        var depth = 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            let unit = units[index]

            if unit == 47, next() == 47 {
                try scanBisonLineComment(embedded: true)
                try append(start, .comment)
            } else if unit == 47, next() == 42 {
                try scanBisonBlockComment()
                try append(start, .comment)
            } else if unit == 34 || unit == 39 {
                try scanBisonQuote()
                try append(start, .string)
            } else if bisonRawStringStart(at: index) {
                index = units.count
                return
            } else if unit == 123 {
                depth += 1
                guard depth <= 256 else { throw SyntaxHighlightingFailure.limit }
                index += 1
            } else if unit == 125 {
                depth -= 1
                index += 1
                if depth == 0 { return }
            } else if unit == 36 || unit == 64 {
                try scanBisonSemanticReference()
            } else {
                index += 1
            }
        }
    }

    /// Recognizes a token-start raw C string opener and leaves the entire tail uncolored.
    private func bisonRawStringStart(at position: Int) -> Bool {
        guard position == 0 || !bisonCodeIdentifier(units[position - 1]) else { return false }
        for prefix: [UInt16] in [[117, 56, 82, 34], [117, 82, 34], [85, 82, 34], [76, 82, 34], [82, 34]] {
            if position + prefix.count <= units.count,
               Array(units[position..<(position + prefix.count)]) == prefix { return true }
        }
        return false
    }

    /// Emits an entire Bison semantic reference only when sigils and identifier boundaries are whole.
    private mutating func scanBisonSemanticReference() throws {
        let start = index
        let leadingBoundary = start == 0 || !bisonReferenceBoundary(units[start - 1])
        var cursor = start
        var validShape = true

        if units[cursor] == 64 {
            cursor += 1
            guard cursor < units.count else { index = cursor; return }
            if units[cursor] == 36 {
                cursor += 1
            } else if bisonASCIIDigit(units[cursor]) {
                repeat { try checkpointIfNeeded(at: cursor); cursor += 1 }
                    while cursor < units.count && bisonASCIIDigit(units[cursor])
            } else if bisonIdentifierStart(units[cursor]) {
                repeat { try checkpointIfNeeded(at: cursor); cursor += 1 }
                    while cursor < units.count && bisonIdentifierContinuation(units[cursor])
            } else {
                validShape = false
            }
        } else {
            cursor += 1
            if cursor < units.count, units[cursor] == 36 {
                cursor += 1
            } else if cursor < units.count, bisonASCIIDigit(units[cursor]) {
                repeat { try checkpointIfNeeded(at: cursor); cursor += 1 }
                    while cursor < units.count && bisonASCIIDigit(units[cursor])
            } else if cursor < units.count, bisonIdentifierStart(units[cursor]) {
                repeat { try checkpointIfNeeded(at: cursor); cursor += 1 }
                    while cursor < units.count && bisonIdentifierContinuation(units[cursor])
            } else {
                validShape = false
            }
        }

        let baseEnd = cursor
        if cursor < units.count, units[cursor] == 60 || units[cursor] == 91 {
            validShape = false
        }
        let trailingBoundary = cursor == units.count || !bisonReferenceBoundary(units[cursor])
        if !trailingBoundary { validShape = false }

        if validShape && leadingBoundary && trailingBoundary {
            index = cursor
            try append(start..<cursor, .variable)
            return
        }
        cursor = max(cursor, start + 1)
        cursor = try bisonRejectedReferenceEnd(from: cursor)
        index = max(cursor, baseEnd)
    }

    /// Skips the contiguous tail of an invalid reference so no inner fragment can be highlighted.
    private mutating func bisonRejectedReferenceEnd(from initial: Int) throws -> Int {
        var cursor = initial
        while cursor < units.count {
            try checkpointIfNeeded(at: cursor)
            if bisonReferenceBoundary(units[cursor]) || units[cursor] == 46 || units[cursor] == 45 {
                cursor += 1
            } else if units[cursor] == 60 || units[cursor] == 91 {
                let closing: UInt16 = units[cursor] == 60 ? 62 : 93
                cursor += 1
                while cursor < units.count, units[cursor] != closing, units[cursor] != 10, units[cursor] != 13 {
                    try checkpointIfNeeded(at: cursor)
                    cursor += 1
                }
                if cursor < units.count, units[cursor] == closing { cursor += 1 }
            } else {
                break
            }
        }
        return cursor
    }

    /// Colors a production label only when an unambiguous single colon follows on the same line.
    private mutating func scanBisonProductionLabel() throws -> Bool {
        let start = index
        guard start == 0 || !bisonLabelContinuation(units[start - 1]) else { return false }
        var end = start + 1
        while end < units.count, bisonLabelCharacter(units[end]) {
            try checkpointIfNeeded(at: end)
            end += 1
        }
        var colon = end
        while colon < units.count, units[colon] == 32 || units[colon] == 9 { colon += 1 }
        guard colon < units.count, units[colon] == 58,
              colon + 1 == units.count || units[colon + 1] != 58 else { return false }
        index = end
        try append(start..<end, .type)
        return true
    }

    /// Checks that a section marker begins after indentation and has a permitted trailing boundary.
    private func bisonSectionMarker(at position: Int) throws -> Bool {
        guard position + 1 < units.count, units[position] == 37, units[position + 1] == 37 else { return false }
        let after = position + 2
        guard after == units.count || [9, 10, 13, 32].contains(units[after]) else { return false }
        var cursor = position
        while cursor > 0 {
            cursor -= 1
            if cursor % 256 == 0 { try checkpoint() }
            let unit = units[cursor]
            if unit == 10 || unit == 13 { return true }
            if unit != 32 && unit != 9 { return false }
        }
        return true
    }

    /// Leaves adjacent colons or bars plain; semicolons always stand alone as grammar separators.
    private func bisonGrammarSeparator(at position: Int) -> Bool {
        let unit = units[position]
        guard unit == 58 || unit == 124 else { return true }
        return (position == 0 || units[position - 1] != unit)
            && (position + 1 == units.count || units[position + 1] != unit)
    }

    /// Scans a first-close C block comment, retaining an unclosed comment through EOF.
    private mutating func scanBisonBlockComment() throws {
        index += 2
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 42, next() == 47 { index += 2; return }
            index += 1
        }
    }

    /// Scans a line comment; escaped LF/CRLF continues only comments inside embedded C code.
    private mutating func scanBisonLineComment(embedded: Bool) throws {
        index += 2
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 10 {
                if embedded, index > 0, units[index - 1] == 92 { index += 1; continue }
                return
            }
            if units[index] == 13 {
                if embedded, index > 0, units[index - 1] == 92, next() == 10 { index += 2; continue }
                return
            }
            index += 1
        }
    }

    /// Scans a single- or double-quoted C token, keeping escaped scalars and permitted line continuations.
    private mutating func scanBisonQuote() throws {
        let quote = units[index]
        index += 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let unit = units[index]
            if unit == quote { index += 1; return }
            if unit == 10 || unit == 13 { return }
            if unit == 92 {
                if index + 1 < units.count, units[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < units.count, units[index + 1] == 13, units[index + 2] == 10 {
                    index += 3
                    continue
                }
                index += 1
                guard index < units.count, units[index] != 10, units[index] != 13 else { continue }
                if (0xD800...0xDBFF).contains(units[index]), index + 1 < units.count,
                   (0xDC00...0xDFFF).contains(units[index + 1]) { index += 2 }
                else { index += 1 }
                continue
            }
            if (0xD800...0xDBFF).contains(unit), index + 1 < units.count,
               (0xDC00...0xDFFF).contains(units[index + 1]) { index += 2 }
            else { index += 1 }
        }
    }

    private func bisonASCIILetter(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit)
    }
    private func bisonASCIIDigit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    private func bisonIdentifierStart(_ unit: UInt16) -> Bool { bisonASCIILetter(unit) || unit == 95 }
    private func bisonIdentifierContinuation(_ unit: UInt16) -> Bool { bisonIdentifierStart(unit) || bisonASCIIDigit(unit) }
    private func bisonCodeIdentifier(_ unit: UInt16) -> Bool { bisonIdentifierContinuation(unit) || unit >= 128 }
    private func bisonReferenceBoundary(_ unit: UInt16) -> Bool { bisonCodeIdentifier(unit) || unit == 36 || unit == 64 }
    private func bisonLabelStart(_ unit: UInt16) -> Bool { bisonIdentifierStart(unit) }
    private func bisonLabelContinuation(_ unit: UInt16) -> Bool {
        bisonIdentifierContinuation(unit) || unit == 46 || unit == 45 || unit >= 128
    }
    private func bisonLabelCharacter(_ unit: UInt16) -> Bool {
        bisonIdentifierContinuation(unit) || unit == 46 || unit == 45
    }
    private func bisonDirectiveContinuation(_ unit: UInt16) -> Bool {
        bisonASCIILetter(unit) || bisonASCIIDigit(unit) || unit == 95 || unit == 45
    }

    /// Highlights ignore-file comments and pattern rows without evaluating filesystem matches.
    private mutating func scanIgnorePatterns() throws -> HighlightedSource {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let end = try lineEnd(from: index)
            var first = index
            while first < end && whitespace(units[first]) { first += 1 }
            if first < end {
                let escapedMarker = first + 1 < end && units[first] == 92 && (units[first + 1] == 35 || units[first + 1] == 33)
                if units[first] == 35 && (language == .gitignore || first == index) {
                    try append(first..<end, .comment)
                } else if !escapedMarker {
                    if units[first] == 33 {
                        try append(first..<(first + 1), .keyword)
                        if first + 1 < end { try append((first + 1)..<end, .directive) }
                    } else {
                        try append(first..<end, .directive)
                    }
                } else {
                    try append(first..<end, .directive)
                }
            }
            index = nextLine(after: end)
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights Git attribute path patterns and assignments without consulting Git configuration.
    private mutating func scanGitAttributes() throws -> HighlightedSource {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            let end = try lineEnd(from: start)
            var patternStart = start
            while patternStart < end && whitespace(units[patternStart]) { patternStart += 1 }
            if patternStart < end {
                if units[patternStart] == 35 && patternStart == start {
                    try append(patternStart..<end, .comment)
                } else {
                    var patternEnd = patternStart
                    while patternEnd < end {
                        try checkpointIfNeeded(at: patternEnd)
                        if whitespace(units[patternEnd]) { break }
                        if units[patternEnd] == 92 { patternEnd += min(2, end - patternEnd) }
                        else { patternEnd += 1 }
                    }
                    if patternEnd > patternStart { try append(patternStart..<patternEnd, .type) }
                    var attributeStart = patternEnd
                    while attributeStart < end {
                        try checkpointIfNeeded(at: attributeStart)
                        while attributeStart < end && whitespace(units[attributeStart]) { attributeStart += 1 }
                        let tokenStart = attributeStart
                        while attributeStart < end && !whitespace(units[attributeStart]) {
                            try checkpointIfNeeded(at: attributeStart)
                            if units[attributeStart] == 92 { attributeStart += min(2, end - attributeStart) }
                            else { attributeStart += 1 }
                        }
                        if attributeStart > tokenStart { try append(tokenStart..<attributeStart, .directive) }
                    }
                }
            }
            index = nextLine(after: end)
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights Go module directives and operands as inert source without validating or resolving modules.
    private mutating func scanGoModule() throws -> HighlightedSource {
        let directives: Set<String> = ["module", "go", "toolchain", "require", "exclude", "replace", "retract", "use", "tool", "godebug"]
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let end = try lineEnd(from: index)
            var cursor = index
            while cursor < end && whitespace(units[cursor]) { cursor += 1 }
            if cursor < end {
                if isGoModuleComment(at: cursor, end: end) {
                    try append(cursor..<end, .comment)
                } else {
                    var isFirstToken = true
                    while cursor < end {
                        try checkpointIfNeeded(at: cursor)
                        while cursor < end && whitespace(units[cursor]) { cursor += 1 }
                        guard cursor < end else { break }
                        if isGoModuleComment(at: cursor, end: end) {
                            try append(cursor..<end, .comment)
                            break
                        }
                        let tokenStart = cursor
                        while cursor < end && !whitespace(units[cursor]) && !isGoModuleComment(at: cursor, end: end) {
                            try checkpointIfNeeded(at: cursor)
                            cursor += 1
                        }
                        guard cursor > tokenStart else { break }
                        let token = String(decoding: units[tokenStart..<cursor], as: UTF16.self)
                        if token != "(" && token != ")" {
                            if isFirstToken && directives.contains(token) { try append(tokenStart..<cursor, .keyword) }
                            else { try append(tokenStart..<cursor, isFirstToken ? .type : .directive) }
                        }
                        isFirstToken = false
                    }
                }
            }
            index = nextLine(after: end)
        }
        try checkpoint()
        return .init(runs: runs)
    }

    private func isGoModuleComment(at position: Int, end: Int) -> Bool {
        position + 1 < end && units[position] == 47 && units[position + 1] == 47
    }

    /// Highlights HTML template text and bounded Ruby expressions without evaluating either.
    private mutating func scanERB() throws -> HighlightedSource {
        var cursor = 0
        while cursor < units.count {
            try checkpointIfNeeded(at: cursor)
            guard let opening = try findERBOpening(from: cursor) else {
                try appendNested(cursor..<units.count, language: .html)
                break
            }
            if cursor < opening { try appendNested(cursor..<opening, language: .html) }
            guard let close = try findERBClosing(from: opening + 2) else {
                if opening + 2 < units.count { try append(opening..<units.count, .directive) }
                break
            }
            let isComment = opening + 2 < units.count && units[opening + 2] == 35
            let contentStart = opening + 2 + ((opening + 2 < units.count && [35, 61, 45].contains(units[opening + 2])) ? 1 : 0)
            let closeStart = close >= 3 && units[close - 3] == 45 ? close - 3 : close - 2
            if isComment {
                try append(opening..<close, .comment)
            } else {
                if opening < contentStart { try append(opening..<contentStart, .directive) }
                if contentStart < closeStart { try appendNested(contentStart..<closeStart, language: .ruby) }
                if closeStart < close { try append(closeStart..<close, .directive) }
            }
            cursor = close
        }
        return .init(runs: runs)
    }

    /// Highlights template delimiters, their bounded embedded language and surrounding HTML.
    /// Template code is never evaluated; malformed blocks remain visible as one lexical span.
    private mutating func scanTemplate() throws -> HighlightedSource {
        let markers: [TemplateMarker]
        switch language {
        case .asp:
            markers = [
                .init(opening: [60, 37, 45, 45], closing: [45, 45, 37, 62], language: nil, isComment: true),
                .init(opening: [60, 37], closing: [37, 62], language: .visualBasic, isComment: false)
            ]
        case .aspx:
            markers = [
                .init(opening: [60, 37, 45, 45], closing: [45, 45, 37, 62], language: nil, isComment: true),
                .init(opening: [60, 37], closing: [37, 62], language: .csharp, isComment: false)
            ]
        case .jinja:
            markers = [
                .init(opening: [123, 35], closing: [35, 125], language: nil, isComment: true),
                .init(opening: [123, 123], closing: [125, 125], language: .python, isComment: false),
                .init(opening: [123, 37], closing: [37, 125], language: .python, isComment: false)
            ]
        case .twig:
            markers = [
                .init(opening: [123, 35], closing: [35, 125], language: nil, isComment: true),
                .init(opening: [123, 123], closing: [125, 125], language: .php, isComment: false),
                .init(opening: [123, 37], closing: [37, 125], language: .php, isComment: false)
            ]
        default:
            return .init(runs: [])
        }

        var cursor = 0
        while cursor < units.count {
            try checkpointIfNeeded(at: cursor)
            guard let next = try nextTemplateMarker(from: cursor, markers: markers) else {
                try appendNested(cursor..<units.count, language: .html)
                break
            }
            let (opening, marker) = next
            if cursor < opening { try appendNested(cursor..<opening, language: .html) }
            let contentStart = opening + marker.opening.count
            guard let closing = try findTemplateClosing(from: contentStart, marker: marker) else {
                if opening < units.count {
                    try append(opening..<units.count, marker.isComment ? .comment : .directive)
                }
                break
            }
            let closingEnd = closing + marker.closing.count
            if marker.isComment {
                try append(opening..<closingEnd, .comment)
            } else {
                var bodyStart = contentStart
                if bodyStart < closing, units[bodyStart] == 45 || units[bodyStart] == 43 { bodyStart += 1 }
                var bodyEnd = closing
                if bodyEnd > bodyStart, units[bodyEnd - 1] == 45 || units[bodyEnd - 1] == 43 { bodyEnd -= 1 }
                if opening < bodyStart { try append(opening..<bodyStart, .directive) }
                if bodyStart < bodyEnd, let embeddedLanguage = marker.language {
                    try appendNested(bodyStart..<bodyEnd, language: embeddedLanguage)
                }
                if bodyEnd < closingEnd { try append(bodyEnd..<closingEnd, .directive) }
            }
            cursor = closingEnd
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Finds the nearest template opener, checking longer comment delimiters first at each offset.
    private mutating func nextTemplateMarker(from start: Int, markers: [TemplateMarker]) throws -> (Int, TemplateMarker)? {
        guard start < units.count else { return nil }
        let orderedMarkers = markers.sorted { $0.opening.count > $1.opening.count }
        var position = start
        while position < units.count {
            try checkpointIfNeeded(at: position)
            for marker in orderedMarkers where position + marker.opening.count <= units.count {
                if units[position...].starts(with: marker.opening) { return (position, marker) }
            }
            position += 1
        }
        return nil
    }

    /// Finds a block terminator without mistaking a quoted close sequence for the real delimiter.
    private mutating func findTemplateClosing(from start: Int, marker: TemplateMarker) throws -> Int? {
        guard start < units.count else { return nil }
        var position = start
        var quote: UInt16?
        var escaped = false
        while position + marker.closing.count <= units.count {
            try checkpointIfNeeded(at: position)
            if marker.isComment {
                if units[position...].starts(with: marker.closing) { return position }
                position += 1
                continue
            }
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if units[position] == 92 { escaped = true }
                else if units[position] == activeQuote { quote = nil }
                position += 1
                continue
            }
            if units[position] == 34 || units[position] == 39 {
                quote = units[position]
                position += 1
            } else if units[position...].starts(with: marker.closing) {
                return position
            } else {
                position += 1
            }
        }
        return nil
    }

    /// Finds the next ERB opener while keeping all work inside the existing scanner budget.
    private mutating func findERBOpening(from start: Int) throws -> Int? {
        guard start + 1 < units.count else { return nil }
        var position = start
        while position + 1 < units.count {
            try checkpointIfNeeded(at: position)
            if units[position] == 60 && units[position + 1] == 37 { return position }
            position += 1
        }
        return nil
    }

    /// Finds `%>` and `-%>` closing delimiters in one bounded ERB segment.
    private mutating func findERBClosing(from start: Int) throws -> Int? {
        guard start + 1 < units.count else { return nil }
        var position = start
        var quote: UInt16?
        var escaped = false
        while position + 1 < units.count {
            try checkpointIfNeeded(at: position)
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if units[position] == 92 { escaped = true }
                else if units[position] == activeQuote { quote = nil }
                position += 1
                continue
            }
            if [34, 39, 96].contains(units[position]) {
                quote = units[position]
                position += 1
                continue
            }
            if units[position] == 37 && units[position + 1] == 62 { return position + 2 }
            if position + 2 < units.count, units[position] == 45, units[position + 1] == 37, units[position + 2] == 62 {
                return position + 3
            }
            position += 1
        }
        return nil
    }

    /// Applies a nested bounded lexer to a UTF-16 slice and offsets its runs into the original source.
    private mutating func appendNested(_ range: Range<Int>, language: SourceLanguage) throws {
        guard !range.isEmpty else { return }
        let fragment = String(decoding: units[range], as: UTF16.self)
        var scanner = SourceTokenScanner(source: fragment, language: language)
        let nested = try scanner.scan()
        guard runs.count + nested.runs.count <= 50_000 else { throw SyntaxHighlightingFailure.limit }
        runs.append(contentsOf: nested.runs.map {
            HighlightRun(range: NSRange(location: range.lowerBound + $0.range.location, length: $0.range.length), kind: $0.kind)
        })
    }

    /// Highlights assignments and common scalar tokens without interpreting or rewriting the source.
    private mutating func scanConfiguration() throws {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            let end = try lineEnd(from: start)
            var first = start
            while first < end && whitespace(units[first]) {
                try checkpointIfNeeded(at: first)
                first += 1
            }
            if first == end { index = nextLine(after: end); continue }

            if isConfigurationComment(units[first]) {
                index = end
                try append(first..<end, .comment)
                index = nextLine(after: end)
                continue
            }
            if (language == .toml || language == .ini), units[first] == 91 {
                var contentStart = first
                while contentStart < end && units[contentStart] == 91 { contentStart += 1 }
                if let close = try sectionEnd(from: contentStart, to: end) {
                    var contentEnd = close
                    while contentEnd > contentStart && units[contentEnd - 1] == 93 { contentEnd -= 1 }
                    if contentEnd > contentStart { try append(contentStart..<contentEnd, .type) }
                }
            }

            let delimiter = try assignmentDelimiter(from: first, to: end)
            if let delimiter, delimiter > first {
                var keyEnd = delimiter
                while keyEnd > first && whitespace(units[keyEnd - 1]) {
                    try checkpointIfNeeded(at: keyEnd)
                    keyEnd -= 1
                }
                if keyEnd > first { try append(first..<keyEnd, .type) }
                try scanConfigurationValue(from: delimiter + 1, to: end, lineStart: start)
            }
            index = nextLine(after: max(end, index))
        }
        try checkpoint()
    }


    /// DOS batch REM remarks are recognized only as a whole word at the start of a line.
    private func isBatchRemark(at index: Int) -> Bool {
        guard index + 3 <= units.count else { return false }
        let word = units[index..<index + 3].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        return word == [114, 101, 109] && (index + 3 == units.count || !identifierContinuation(units[index + 3]))
    }
    /// Finds the next physical line terminator while enforcing periodic cancellation checks.
    private mutating func lineEnd(from start: Int) throws -> Int {
        var end = start
        while end < units.count && units[end] != 10 && units[end] != 13 {
            try checkpointIfNeeded(at: end)
            end += 1
        }
        return end
    }

    /// Finds a closing INI section bracket within the current bounded line.
    private mutating func sectionEnd(from start: Int, to end: Int) throws -> Int? {
        var cursor = start
        while cursor < end {
            try checkpointIfNeeded(at: cursor)
            if units[cursor] == 93 { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Advances past one LF, CR, or CRLF line terminator.
    private func nextLine(after end: Int) -> Int {
        guard end < units.count else { return end }
        if units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 { return end + 2 }
        return end + 1
    }

    /// Recognizes horizontal whitespace used around configuration keys and values.
    private func whitespace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    /// Returns whether this configuration dialect uses the supplied comment marker.
    private func isConfigurationComment(_ unit: UInt16) -> Bool {
        switch language {
        case .toml, .dotenv: unit == 35
        case .ini: unit == 35 || unit == 59
        case .properties: unit == 35 || unit == 33
        default: false
        }
    }

    /// Finds an unquoted key/value separator using the active configuration dialect's rules.
    private mutating func assignmentDelimiter(from start: Int, to end: Int) throws -> Int? {
        var cursor = start
        var escaped = false
        var quote: UInt16?
        while cursor < end {
            try checkpointIfNeeded(at: cursor)
            let unit = units[cursor]
            if language != .properties {
                if let openQuote = quote {
                    if unit == 92 { cursor += min(2, end - cursor); continue }
                    if unit == openQuote { quote = nil }
                    cursor += 1
                    continue
                }
                if unit == 34 || unit == 39 { quote = unit; cursor += 1; continue }
            }
            if language == .properties {
                if !escaped && (unit == 61 || unit == 58 || whitespace(unit)) { return cursor }
                if unit == 92 { escaped.toggle() } else { escaped = false }
            } else if unit == 61 || (language == .ini && unit == 58) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    /// Colors supported scalar values and comments in one configuration value region.
    private mutating func scanConfigurationValue(from start: Int, to end: Int, lineStart: Int) throws {
        index = start
        while index < end {
            let tokenStart = index
            let unit = units[index]
            if language != .properties && (unit == 34 || unit == 39) {
                try scanString(quoteIndex: index)
                if index > tokenStart { try append(tokenStart, .string) }
            } else if isConfigurationComment(unit), configurationCommentStarts(at: index, lineStart: lineStart) {
                index = end
                try append(tokenStart, .comment)
            } else if digit(unit) {
                try scanNumber()
                try append(tokenStart, .number)
            } else if identifierStart(unit) {
                index += 1
                while index < end && identifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                let word = String(decoding: units[tokenStart..<index], as: UTF16.self).lowercased()
                if ["true", "false", "yes", "no", "on", "off", "null"].contains(word) {
                    try append(tokenStart, .keyword)
                }
            } else { index += 1 }
        }
    }

    /// Applies dialect-specific rules for whether a comment marker starts a trailing comment.
    private func configurationCommentStarts(at position: Int, lineStart: Int) -> Bool {
        switch language {
        case .toml: true
        case .ini, .dotenv: position > lineStart && whitespace(units[position - 1])
        case .properties: false
        default: false
        }
    }

    /// Consumes until a fixed terminator while checking cancellation.
    private mutating func scan(until terminator: [UInt16]) throws {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index...].starts(with: terminator) {
                index += terminator.count
                return
            }
            index += 1
        }
    }

    private var coldFusionCommentStart: Bool { language == .coldfusion && units[index...].starts(with: [60, 33, 45, 45, 45]) }
    private var coffeescriptBlockCommentStart: Bool { language == .coffeescript && units[index...].starts(with: [35, 35, 35]) }
    private var clojureKeywordStart: Bool { language == .clojure && units[index] == 58 && index + 1 < units.count && identifierStart(units[index + 1]) }
    /// Returns the following UTF-16 unit only when it is within the retained source buffer.
    private func next() -> UInt16? { index + 1 < units.count ? units[index + 1] : nil }
    /// Recognizes ASCII decimal digits used by identifiers and numeric literals.
    private func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
    /// Accepts the bounded identifier starts supported by the lightweight lexer.
    private func identifierStart(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit >= 128
            || (unit == 39 && [.fsharp, .haskell].contains(language))
            || (unit == 36 && [.javascript, .jsx, .typescript, .tsx].contains(language))
    }
    /// Extends a lexer identifier with the supported start characters and decimal digits.
    private func identifierContinuation(_ unit: UInt16) -> Bool {
        identifierStart(unit) || digit(unit)
            || (language == .clojure && [45, 63, 33, 42, 43].contains(unit))
            || (language == .yang && [45, 46, 58].contains(unit))
    }

    /// Shell `#` begins a comment only in positions where it cannot be part of a word.
    private var hashStartsComment: Bool {
        if [.python, .awk, .csh, .cmake, .ruby, .coffeescript, .crystal, .cson, .powershell, .perl, .r, .julia].contains(language) || index == 0 { return true }
        return [9, 10, 13, 32, 59, 124, 38, 40, 41].contains(units[index - 1])
    }

    /// Checks directive position by walking to the current line start with cancellation checkpoints.
    private func linePrefixIsWhitespace() throws -> Bool {
        var previous = index
        while previous > 0 {
            previous -= 1
            if previous % 256 == 0 { try checkpoint() }
            let unit = units[previous]
            if unit == 10 || unit == 13 { return true }
            if unit != 32 && unit != 9 { return false }
        }
        return true
    }

    /// Amortizes cancellation checks while bounding work inside long tokens.
    private mutating func checkpointIfNeeded(at position: Int) throws {
        guard position >= nextCheckpointIndex else { return }
        nextCheckpointIndex = position + 256
        try checkpoint()
    }

    /// Checks cancellation during long tokens as well as between tokens.
    private func checkpoint() throws {
        try Task.checkCancellation()
    }

    /// Adds a bounded token span covering the scanner's just-consumed UTF-16 range.
    private mutating func append(_ start: Int, _ kind: SyntaxTokenKind) throws {
        guard runs.count < 50_000 else { throw SyntaxHighlightingFailure.limit }
        runs.append(.init(range: .init(location: start, length: index - start), kind: kind))
    }

    /// Adds an explicit UTF-16 token range after validating source bounds and token capacity.
    private mutating func append(_ range: Range<Int>, _ kind: SyntaxTokenKind) throws {
        guard range.lowerBound >= 0, range.upperBound <= units.count, range.lowerBound < range.upperBound,
              runs.count < 50_000 else { throw SyntaxHighlightingFailure.limit }
        runs.append(.init(range: .init(location: range.lowerBound, length: range.count), kind: kind))
    }

    /// Advances to the next physical newline while checking the lexer budget periodically.
    private mutating func scanLine() throws {
        while index < units.count && units[index] != 10 && units[index] != 13 {
            try checkpointIfNeeded(at: index)
            index += 1
        }
    }

    /// Returns the current language's line-comment marker length at a source position.
    private func lineCommentLength(at position: Int) -> Int? {
        switch language {
        case .terraform: return units[position] == 35 || (units[position] == 47 && next() == 47) ? (units[position] == 35 ? 1 : 2) : nil
        case .nix: return units[position] == 35 ? 1 : nil
        case .nim, .gettext: return units[position] == 35 ? 1 : nil
        case .cobol: return units[position] == 42 && next() == 62 ? 2 : nil
        case .openSCAD: return units[position] == 47 && next() == 47 ? 2 : nil
        case .webAssemblyText: return nil
        case .vhdl: return units[position] == 45 && next() == 45 ? 2 : nil
        case .pascal, .verilog: return units[position] == 47 && next() == 47 ? 2 : nil
        case .scss: return units[position] == 47 && next() == 47 ? 2 : nil
        case .sql, .plsql, .tsql: return units[position] == 45 && next() == 45 ? 2 : nil
        case .shell:
            if position == 0, units[position] == 35, next() == 33 { return nil }
            return units[position] == 35 && hashStartsComment ? 1 : nil
        case .python, .fish, .gdscript, .ruby, .coffeescript, .crystal, .cson, .cmake, .csh, .dockerfile, .perl, .r, .julia, .tcl, .nginx, .apache, .meson: return units[position] == 35 && hashStartsComment ? 1 : nil
        case .autoHotkey, .innoSetup, .nsis: return units[position] == 59 ? 1 : nil
        case .rego, .ldif, .turtle: return units[position] == 35 ? 1 : nil
        case .yang: return units[position] == 47 && next() == 47 ? 2 : nil
        case .clojure: return units[position] == 59 ? 1 : nil
        case .bibtex, .matlab: return units[position] == 37 ? 1 : nil
        case .appleScript: return units[position] == 45 && next() == 45 ? 2 : nil
        case .visualBasic: return units[position] == 39 ? 1 : nil
        case .vimscript: return isVimscriptFullLineComment(at: position) ? 1 : nil
        case .ocaml: return nil
        case .css: return nil
        case .ada: return units[position] == 45 && next() == 45 ? 2 : nil
        case .fortran:
            if units[position] == 33 { return 1 }
            guard isLineStart(position), [67, 99, 42].contains(units[position]) else { return nil }
            return 1
        case .haskell, .elm: return units[position] == 45 && next() == 45 ? 2 : nil
        default: return units[position] == 47 && next() == 47 ? 2 : nil
        }
    }

    /// Vimscript's double-quote comment is recognized only on a comment-only line, where it cannot
    /// be confused with a double-quoted string argument to an Ex command.
    private func isVimscriptFullLineComment(at position: Int) -> Bool {
        guard language == .vimscript, units[position] == 34 else { return false }
        var cursor = position
        while cursor > 0, units[cursor - 1] != 10, units[cursor - 1] != 13 {
            cursor -= 1
            if units[cursor] != 32 && units[cursor] != 9 { return false }
        }
        return true
    }

    /// VB's REM form starts a statement or follows a statement separator, not an identifier.
    private func visualBasicRemark(at position: Int) -> Bool {
        guard language == .visualBasic, position + 3 <= units.count,
              String(decoding: units[position..<position + 3], as: UTF16.self).lowercased() == "rem",
              position + 3 == units.count || !identifierContinuation(units[position + 3]) else { return false }
        var lineStart = position
        while lineStart > 0, units[lineStart - 1] != 10, units[lineStart - 1] != 13 { lineStart -= 1 }
        var cursor = position - 1
        while cursor >= lineStart, units[cursor] == 32 || units[cursor] == 9 { cursor -= 1 }
        return cursor < lineStart || units[cursor] == 58
    }

    /// Checks whether a source position follows a physical line boundary.
    private func isLineStart(_ position: Int) -> Bool {
        position == 0 || units[position - 1] == 10 || units[position - 1] == 13
    }

    /// Restricts literate Haskell tokens to Bird tracks and explicit LaTeX code blocks.
    private mutating func skipLiterateHaskellText() throws -> Bool {
        let lineEnd = units[index...].firstIndex(where: { $0 == 10 || $0 == 13 }) ?? units.count
        let line = String(decoding: units[index..<lineEnd], as: UTF16.self)
        if line.trimmingCharacters(in: .whitespaces) == "\\begin{code}" {
            literateCodeBlock = true
            try scanLine()
            return true
        }
        if line.trimmingCharacters(in: .whitespaces) == "\\end{code}" {
            literateCodeBlock = false
            try scanLine()
            return true
        }
        if literateCodeBlock { return false }
        let firstNonspace = units[index..<lineEnd].firstIndex(where: { $0 != 32 && $0 != 9 })
        guard let firstNonspace, units[firstNonspace] == 62 else {
            // An empty prose line has nothing to skip; returning true would rescan it forever.
            guard index < lineEnd else { return false }
            try scanLine()
            return true
        }
        index = firstNonspace + 1
        if index < lineEnd, units[index] == 32 || units[index] == 9 { index += 1 }
        return false
    }

    private var literateCodeBlock = false

    /// Determines whether a quote begins a string in the active language subset.
    private func isStringStart(at position: Int) -> Bool {
        let unit = units[position]
        if language == .julia { return unit == 34 }
        if language == .rust && unit == 39 {
            var cursor = position + 1
            if cursor < units.count && units[cursor] == 92 { cursor += 1 }
            return cursor + 1 < units.count && units[cursor + 1] == 39
        }
        if unit == 34 || (unit == 96 && [.javascript, .jsx, .typescript, .tsx, .shell, .go, .coffeescript].contains(language)) { return true }
        guard unit == 39 else { return false }
        guard [.fsharp, .haskell].contains(language) else { return true }
        var cursor = position + 1
        if cursor < units.count, units[cursor] == 92 { cursor += 1 }
        return cursor + 1 < units.count && units[cursor + 1] == 39
    }

    /// Returns block-comment delimiters only for languages whose bounded lexer supports them.
    private func blockComment(at position: Int) -> (opening: (UInt16, UInt16), closing: (UInt16, UInt16), openingLength: Int)? {
        guard position + 1 < units.count else { return nil }
        let first = units[position]
        let second = units[position + 1]
        if language == .fsharp {
            return first == 40 && second == 42 ? ((40, 42), (42, 41), 2) : nil
        }
        if language == .haskell || language == .elm {
            return first == 123 && second == 45 ? ((123, 45), (45, 125), 2) : nil
        }
        if language == .ocaml {
            return first == 40 && second == 42 ? ((40, 42), (42, 41), 2) : nil
        }
        if language == .webAssemblyText, first == 40, second == 59 { return ((40, 59), (59, 41), 2) }
        let supportsCBlock = [.swift, .java, .c, .cpp, .objectiveC, .scala, .javascript, .typescript, .tsx, .gleam, .go, .groovy, .csharp, .coldfusion, .sql, .plsql, .tsql, .rust, .php, .cue, .kdl, .vala, .openSCAD, .verilog, .deviceTree, .qml, .solidity, .autoHotkey, .yang].contains(language)
        return supportsCBlock || [.css, .scss, .terraform, .nix].contains(language) ? (first == 47 && second == 42 ? ((47, 42), (42, 47), 2) : nil) : nil
    }

    /// Consumes Nix indented strings as one bounded token without interpreting interpolation.
    private mutating func scanNixIndentedString() throws {
        index += 2
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 39, next() == 39 {
                if index + 2 < units.count, units[index + 2] == 39 {
                    index += 3
                    continue
                }
                index += 2
                return
            }
            index += 1
        }
    }

    /// Supports bounded nested comments in Swift, F#, Haskell, and Elm.
    private mutating func scanBlockComment(opening: (UInt16, UInt16), closing: (UInt16, UInt16)) throws {
        var depth = 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == closing.0 && next() == closing.1 {
                index += 2
                depth -= 1
                if depth == 0 { return }
            } else if [.swift, .fsharp, .haskell, .elm, .kotlin, .rust, .ocaml, .webAssemblyText].contains(language),
                      units[index] == opening.0 && next() == opening.1 {
                depth += 1
                guard depth <= 64 else { throw SyntaxHighlightingFailure.limit }
                index += 2
            } else { index += 1 }
        }
    }

    /// Scans Nim's nested `#[ … ]#` comments with an explicit depth bound.
    private mutating func scanNimBlockComment() throws {
        var depth = 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 35 && next() == 91 {
                depth += 1
                guard depth <= 64 else { throw SyntaxHighlightingFailure.limit }
                index += 2
            } else if units[index] == 93 && next() == 35 {
                index += 2
                depth -= 1
                if depth == 0 { return }
            } else { index += 1 }
        }
    }

    /// Consumes a Pascal single-quoted string, including the doubled quote escape.
    private mutating func scanPascalString() throws {
        index += 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 39 {
                if next() == 39 { index += 2; continue }
                index += 1
                return
            }
            if units[index] == 10 || units[index] == 13 { return }
            index += 1
        }
    }

    /// Consumes a COBOL literal and its doubled-quote escape without interpreting continuation syntax.
    private mutating func scanCobolString() throws {
        let quote = units[index]
        index += 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == quote {
                if next() == quote { index += 2; continue }
                index += 1
                return
            }
            if units[index] == 10 || units[index] == 13 { return }
            index += 1
        }
    }

    /// Detects fixed-format COBOL comment indicators in column seven, at the start of a line.
    private func isCobolFixedFormComment(at position: Int) -> Bool {
        guard language == .cobol, isLineStart(position), position + 6 < units.count else { return false }
        var lineEnd = position
        while lineEnd < units.count && units[lineEnd] != 10 && units[lineEnd] != 13 { lineEnd += 1 }
        guard lineEnd > position + 6 else { return false }
        return units[position + 6] == 42 || units[position + 6] == 47
    }

    /// Scans Lisp `#| … |#` comments while preserving a bounded nested-comment depth.
    private mutating func scanLispBlockComment() throws {
        var depth = 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 35 && next() == 124 {
                depth += 1
                guard depth <= 64 else { throw SyntaxHighlightingFailure.limit }
                index += 2
            } else if units[index] == 124 && next() == 35 {
                index += 2
                depth -= 1
                if depth == 0 { return }
            } else { index += 1 }
        }
    }

    /// Scans Lua's basic long-comment form without interpreting source text.
    private func luaLongBracket(at start: Int) -> (contentStart: Int, level: Int)? {
        guard start < units.count, units[start] == 91 else { return nil }
        var cursor = start + 1
        while cursor < units.count && units[cursor] == 61 && cursor - start <= 64 { cursor += 1 }
        guard cursor < units.count, units[cursor] == 91 else { return nil }
        return (cursor + 1, cursor - start - 1)
    }

    /// Scans a Lua long string or comment, matching the exact `]=…=]` delimiter depth.
    private mutating func scanLuaLongBracket(level: Int) throws {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 93, index + level + 1 < units.count {
                var cursor = index + 1
                while cursor < index + level + 1 && units[cursor] == 61 { cursor += 1 }
                if cursor == index + level + 1 && units[cursor] == 93 { index = cursor + 1; return }
            }
            index += 1
        }
    }

    /// Highlights Perl and R scalar/container names while consuming their leading sigil.
    private mutating func scanSigilVariable() throws {
        index += 1
        guard index < units.count, identifierStart(units[index]) else { return }
        index += 1
        while index < units.count && identifierContinuation(units[index]) {
            try checkpointIfNeeded(at: index)
            index += 1
        }
    }

    /// Scans Julia's nested `#= … =#` comments with an explicit depth bound.
    private mutating func scanJuliaBlockComment() throws {
        var depth = 1
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == 35 && next() == 61 {
                depth += 1
                guard depth <= 64 else { throw SyntaxHighlightingFailure.limit }
                index += 2
            } else if units[index] == 61 && next() == 35 {
                index += 2
                depth -= 1
                if depth == 0 { return }
            } else { index += 1 }
        }
    }

    /// Handles PowerShell quoted strings, doubled apostrophes, backtick escapes and here-strings.
    private mutating func scanPowerShellString() throws {
        let quote = units[index]
        let quoteIndex = index
        let isHereString = quoteIndex > 0 && units[quoteIndex - 1] == 64
            && quoteIndex + 1 < units.count && (units[quoteIndex + 1] == 10 || units[quoteIndex + 1] == 13)
        index += 1
        if isHereString {
            while index < units.count && units[index] != 10 && units[index] != 13 { index += 1 }
            if index < units.count && units[index] == 13 { index += 1 }
            if index < units.count && units[index] == 10 { index += 1 }
            while index < units.count {
                try checkpointIfNeeded(at: index)
                if (index == 0 || units[index - 1] == 10 || units[index - 1] == 13),
                   index + 1 < units.count, units[index] == quote, units[index + 1] == 64 {
                    index += 2
                    return
                }
                index += 1
            }
            return
        }
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if quote == 34 && units[index] == 96 {
                index += min(2, units.count - index)
            } else if quote == 39 && units[index] == 39 && next() == 39 {
                index += 2
            } else if units[index] == quote {
                index += 1
                return
            } else {
                index += 1
            }
        }
    }

    /// Highlights a PowerShell variable including scoped and braced spellings as one token.
    private mutating func scanPowerShellVariable() throws {
        index += 1
        guard index < units.count else { return }
        if units[index] == 123 {
            index += 1
            while index < units.count && units[index] != 125 {
                try checkpointIfNeeded(at: index)
                index += 1
            }
            if index < units.count { index += 1 }
            return
        }
        if [36, 63, 94, 95].contains(units[index]) { index += 1; return }
        while index < units.count && (identifierContinuation(units[index]) || units[index] == 58 || units[index] == 45) {
            try checkpointIfNeeded(at: index)
            index += 1
        }
    }

    /// Highlights NSIS `$NAME`, `${NAME}` and numeric register references as a single token.
    private mutating func scanNSISVariable() throws {
        index += 1
        guard index < units.count else { return }
        if units[index] == 123 {
            index += 1
            while index < units.count && units[index] != 125 {
                try checkpointIfNeeded(at: index)
                index += 1
            }
            if index < units.count { index += 1 }
            return
        }
        while index < units.count && (identifierContinuation(units[index]) || digit(units[index])) {
            try checkpointIfNeeded(at: index)
            index += 1
        }
    }

    /// Highlights PHP variable names and braced variable-variable forms.
    private mutating func scanPHPVariable() throws {
        index += 1
        guard index < units.count else { return }
        if units[index] == 123 {
            index += 1
            while index < units.count && units[index] != 125 {
                try checkpointIfNeeded(at: index)
                index += 1
            }
            if index < units.count { index += 1 }
            return
        }
        guard identifierStart(units[index]) else { return }
        index += 1
        while index < units.count && identifierContinuation(units[index]) {
            try checkpointIfNeeded(at: index)
            index += 1
        }
    }

    /// Classifies LESS variables while leaving CSS at-rules as directives.
    private mutating func scanLessAtRuleOrVariable() throws -> SyntaxTokenKind {
        index += 1
        let nameStart = index
        while index < units.count && (identifierContinuation(units[index]) || units[index] == 45) {
            try checkpointIfNeeded(at: index)
            index += 1
        }
        let name = String(decoding: units[nameStart..<index], as: UTF16.self)
        if ["charset", "container", "font-face", "import", "keyframes", "layer", "media", "namespace", "page", "supports",
            "use", "forward", "mixin", "include", "function", "extend", "at-root", "content", "return", "if", "else",
            "each", "for", "while", "debug", "warn", "error"].contains(name) {
            return .directive
        }
        return .variable
    }

    /// Highlights HTML comments, tags, attributes and literal values without parsing or loading content.
    private mutating func scanHTML() throws -> HighlightedSource {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            guard units[index] == 60 else { index += 1; continue }
            if units[index...].starts(with: [60, 33, 45, 45]) {
                index += 4
                try scan(until: [45, 45, 62])
                try append(start, .comment)
                continue
            }
            guard index + 1 < units.count else { index += 1; continue }
            if units[index + 1] == 33 || units[index + 1] == 63 {
                try scan(until: [62])
                try append(start, .directive)
                continue
            }
            index += 1
            if index < units.count, units[index] == 47 { index += 1 }
            let nameStart = index
            while index < units.count && identifierContinuation(units[index]) {
                try checkpointIfNeeded(at: index)
                index += 1
            }
            guard index > nameStart else { continue }
            try append(nameStart..<index, .type)
            while index < units.count {
                try checkpointIfNeeded(at: index)
                if units[index] == 62 { index += 1; break }
                if units[index] == 34 || units[index] == 39 {
                    let valueStart = index
                    try scanString(quoteIndex: index)
                    if index > valueStart { try append(valueStart, .string) }
                } else if identifierStart(units[index]) {
                    let attributeStart = index
                    index += 1
                    while index < units.count && (identifierContinuation(units[index]) || units[index] == 45 || units[index] == 58) {
                        try checkpointIfNeeded(at: index)
                        index += 1
                    }
                    try append(attributeStart, .keyword)
                } else if digit(units[index]) {
                    let numberStart = index
                    try scanNumber()
                    try append(numberStart, .number)
                } else { index += 1 }
            }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights make directives, assignment names, targets, comments and variable references only.
    private mutating func scanMakefile() throws -> HighlightedSource {
        let directives = Self.wordSet("define endef export unexport override private vpath include sinclude ifeq ifneq ifdef ifndef else endif")
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let lineStart = index
            let end = try lineEnd(from: lineStart)
            var first = lineStart
            while first < end && [32, 9].contains(units[first]) {
                try checkpointIfNeeded(at: first)
                first += 1
            }
            if first < end {
                if units[first] == 35 {
                    index = end
                    try append(first..<end, .comment)
                } else {
                    var commentStart: Int?
                    var cursor = first
                    while cursor < end {
                        try checkpointIfNeeded(at: cursor)
                        if units[cursor] == 92 { cursor += min(2, end - cursor); continue }
                        if units[cursor] == 35 { commentStart = cursor; break }
                        cursor += 1
                    }
                    let contentEnd = commentStart ?? end
                    var scanFrom = first
                    if first < contentEnd, units[lineStart] != 9 {
                        var wordEnd = first
                        while wordEnd < contentEnd && identifierContinuation(units[wordEnd]) {
                            try checkpointIfNeeded(at: wordEnd)
                            wordEnd += 1
                        }
                        let firstWord = String(decoding: units[first..<wordEnd], as: UTF16.self)
                        if directives.contains(firstWord) {
                            try append(first..<wordEnd, .directive)
                            scanFrom = wordEnd
                        } else {
                            var equals: Int?
                            var colon: Int?
                            cursor = first
                            while cursor < contentEnd {
                                if units[cursor] == 36, let after = try makeVariableEnd(at: cursor, limit: contentEnd) { cursor = after; continue }
                                if [34, 39].contains(units[cursor]) {
                                    let quote = units[cursor]
                                    cursor += 1
                                    while cursor < contentEnd && units[cursor] != quote {
                                        if units[cursor] == 92 { cursor += min(2, contentEnd - cursor) } else { cursor += 1 }
                                    }
                                    if cursor < contentEnd { cursor += 1 }
                                    continue
                                }
                                if units[cursor] == 61, equals == nil { equals = cursor }
                                if units[cursor] == 58, colon == nil,
                                   (cursor + 1 >= contentEnd || ![61, 58].contains(units[cursor + 1])) { colon = cursor }
                                cursor += 1
                            }
                            if let equals, equals > first {
                                var nameEnd = equals
                                while nameEnd > first && [32, 9].contains(units[nameEnd - 1]) { nameEnd -= 1 }
                                if nameEnd > first { try append(first..<nameEnd, .type) }
                                scanFrom = equals + 1
                            } else if let colon, colon > first {
                                try append(first..<colon, .type)
                                scanFrom = colon + 1
                            }
                        }
                    }
                    index = scanFrom
                    while index < contentEnd {
                        try checkpointIfNeeded(at: index)
                        if units[index] == 36, let after = try makeVariableEnd(at: index, limit: contentEnd) {
                            let start = index
                            index = after
                            try append(start, .variable)
                        } else { index += 1 }
                    }
                    if let commentStart, commentStart < end {
                        index = end
                        try append(commentStart..<end, .comment)
                    }
                }
            }
            index = end
            if index < units.count && units[index] == 13 { index += 1 }
            if index < units.count && units[index] == 10 { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    private mutating func makeVariableEnd(at start: Int, limit: Int) throws -> Int? {
        guard start + 1 < limit, units[start] == 36 else { return nil }
        if units[start + 1] == 40 || units[start + 1] == 123 {
            let close: UInt16 = units[start + 1] == 40 ? 41 : 125
            var depth = 1
            var cursor = start + 2
            while cursor < limit {
                try checkpointIfNeeded(at: cursor)
                if units[cursor] == units[start + 1] { depth += 1 }
                guard depth <= 64 else { throw SyntaxHighlightingFailure.limit }
                if units[cursor] == close {
                    depth -= 1
                    if depth == 0 { return cursor + 1 }
                }
                cursor += 1
            }
            return limit
        }
        if [64, 60, 62, 94, 63, 42, 36].contains(units[start + 1]) { return start + 2 }
        var cursor = start + 1
        while cursor < limit && (identifierContinuation(units[cursor]) || [45, 46].contains(units[cursor])) {
            try checkpointIfNeeded(at: cursor)
            cursor += 1
        }
        return cursor
    }

    /// Highlights DTD declaration syntax without parsing, expanding or fetching any entity.
    private mutating func scanDTD() throws -> HighlightedSource {
        let declarations: Set<String> = ["<!ELEMENT", "<!ATTLIST", "<!ENTITY", "<!NOTATION", "<!DOCTYPE"]
        let words = Self.wordSet("ANY EMPTY SYSTEM PUBLIC NDATA CDATA ID IDREF IDREFS ENTITY ENTITIES NMTOKEN NMTOKENS NOTATION PCDATA IMPLIED REQUIRED FIXED")
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            if units[index...].starts(with: [60, 33, 45, 45]) {
                index += 4
                try scan(until: [45, 45, 62])
                try append(start, .comment)
            } else if units[index] == 60 && next() == 33 {
                index += 2
                while index < units.count && (identifierContinuation(units[index]) || units[index] == 33) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                let declaration = String(decoding: units[start..<index], as: UTF16.self).uppercased()
                if declarations.contains(declaration) { try append(start, .directive) }
            } else if [34, 39].contains(units[index]) {
                try scanString(quoteIndex: index)
                try append(start, .string)
            } else if [37, 38].contains(units[index]), let end = try entityReferenceEnd(at: index) {
                index = end
                try append(start, .variable)
            } else if units[index] == 35, index + 1 < units.count, identifierStart(units[index + 1]) {
                index += 2
                while index < units.count && identifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                try append(start, .keyword)
            } else if identifierStart(units[index]) {
                index += 1
                while index < units.count && identifierContinuation(units[index]) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                let word = String(decoding: units[start..<index], as: UTF16.self).uppercased()
                if words.contains(word) { try append(start, .keyword) }
            } else { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    private mutating func entityReferenceEnd(at start: Int) throws -> Int? {
        var cursor = start + 1
        guard cursor < units.count, identifierStart(units[cursor]) else { return nil }
        cursor += 1
        while cursor < units.count && (identifierContinuation(units[cursor]) || units[cursor] == 58 || units[cursor] == 45) {
            try checkpointIfNeeded(at: cursor)
            cursor += 1
        }
        return cursor < units.count && units[cursor] == 59 ? cursor + 1 : nil
    }

    /// Highlights XQuery lexical constructs, including bounded nested comments and variable names.
    private mutating func scanXQuery() throws -> HighlightedSource {
        let keywords = Self.wordSet("allowing and ascending at attribute base-uri boundary-space by case castable cast child collation collection construction copy declare default descending div document-node element else empty every except external false following-sibling for function ge gt idiv if import in instance-of intersect is item le let lt module namespace ne node not of option or order ordered parent preceding-sibling processing-instruction return satisfies schema-element self-node some stable start strip strict then to treat typeswitch union unordered validate variable version where xquery zero-or-one true false")
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            if index + 1 < units.count && units[index] == 40 && units[index + 1] == 58 {
                index += 2
                var depth = 1
                while index < units.count && depth > 0 {
                    try checkpointIfNeeded(at: index)
                    if index + 1 < units.count && units[index] == 40 && units[index + 1] == 58 {
                        depth += 1
                        guard depth <= 64 else { throw SyntaxHighlightingFailure.limit }
                        index += 2
                    } else if index + 1 < units.count && units[index] == 58 && units[index + 1] == 41 {
                        depth -= 1
                        index += 2
                    } else { index += 1 }
                }
                try append(start, .comment)
            } else if units[index] == 34 || units[index] == 39 {
                let quote = units[index]
                index += 1
                while index < units.count {
                    try checkpointIfNeeded(at: index)
                    if units[index] == quote {
                        if index + 1 < units.count && units[index + 1] == quote { index += 2; continue }
                        index += 1
                        break
                    }
                    index += 1
                }
                try append(start, .string)
            } else if units[index] == 36 && index + 1 < units.count && identifierStart(units[index + 1]) {
                index += 2
                while index < units.count && (identifierContinuation(units[index]) || [58, 45].contains(units[index])) { index += 1 }
                try append(start, .variable)
            } else if digit(units[index]) {
                try scanNumber()
                try append(start, .number)
            } else if identifierStart(units[index]) {
                index += 1
                while index < units.count && (identifierContinuation(units[index]) || [58, 45].contains(units[index])) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if keywords.contains(word) { try append(start, .keyword) }
            } else { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights Haml structural markers, comments, attributes and interpolation without evaluation.
    private mutating func scanHaml() throws -> HighlightedSource {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let lineStart = index
            let end = try lineEnd(from: lineStart)
            var first = lineStart
            while first < end && [32, 9].contains(units[first]) {
                try checkpointIfNeeded(at: first)
                first += 1
            }
            if first < end && units[first] == 47 {
                index = end
                try append(first..<end, .comment)
            } else {
                index = first
                while index < end {
                    try checkpointIfNeeded(at: index)
                    let start = index
                    if units[index] == 37 || units[index] == 46 || units[index] == 35 {
                        index += 1
                        while index < end && (identifierContinuation(units[index]) || [45, 58].contains(units[index])) {
                            try checkpointIfNeeded(at: index)
                            index += 1
                        }
                        if index > start + 1 { try append(start, units[start] == 37 ? .type : .keyword) }
                    } else if units[index] == 61 || units[index] == 45, start == first {
                        index += 1
                        try append(start, .directive)
                    } else if units[index] == 34 || units[index] == 39 {
                        try scanString(quoteIndex: index)
                        try append(start, .string)
                    } else if units[index] == 64 && index + 1 < end && identifierStart(units[index + 1]) {
                        index += 2
                        while index < end && identifierContinuation(units[index]) {
                            try checkpointIfNeeded(at: index)
                            index += 1
                        }
                        try append(start, .variable)
                    } else { index += 1 }
                }
            }
            index = end
            if index < units.count && units[index] == 13 { index += 1 }
            if index < units.count && units[index] == 10 { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights JSP/HTML boundaries and Java tokens in scriptlets; no server code is executed.
    private mutating func scanJSP() throws -> HighlightedSource {
        let javaKeywords = Self.wordSet("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new null package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient true try var void volatile while yield")
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            if units[index...].starts(with: [60, 37]) {
                let openerLength = index + 2 < units.count && [64, 61, 33].contains(units[index + 2]) ? 3 : 2
                index += openerLength
                try append(start..<index, .directive)
                while index < units.count && !units[index...].starts(with: [37, 62]) {
                    try checkpointIfNeeded(at: index)
                    let token = index
                    if index + 1 < units.count && units[index] == 47 && units[index + 1] == 47 {
                        index += 2
                        try scanLine()
                        if index > token { try append(token, .comment) }
                    } else if index + 1 < units.count && units[index] == 47 && units[index + 1] == 42 {
                        index += 2
                        try scan(until: [42, 47])
                        try append(token, .comment)
                    } else if units[index] == 34 || units[index] == 39 {
                        try scanString(quoteIndex: index)
                        try append(token, .string)
                    } else if identifierStart(units[index]) {
                        index += 1
                        while index < units.count && identifierContinuation(units[index]) {
                            try checkpointIfNeeded(at: index)
                            index += 1
                        }
                        let word = String(decoding: units[token..<index], as: UTF16.self)
                        if javaKeywords.contains(word) { try append(token, .keyword) }
                        else if ["String", "Object", "Integer", "Boolean", "Long", "Double"].contains(word) { try append(token, .type) }
                    } else if digit(units[index]) {
                        try scanNumber()
                        try append(token, .number)
                    } else { index += 1 }
                }
                if index + 1 < units.count {
                    index += 2
                    try append(index - 2..<index, .directive)
                }
            } else if units[index...].starts(with: [60, 33, 45, 45]) {
                index += 4
                try scan(until: [45, 45, 62])
                try append(start, .comment)
            } else if units[index] == 60 && index + 1 < units.count && (units[index + 1] == 47 || identifierStart(units[index + 1])) {
                index += 1
                if index < units.count && units[index] == 47 { index += 1 }
                let nameStart = index
                while index < units.count && (identifierContinuation(units[index]) || [45, 58].contains(units[index])) {
                    try checkpointIfNeeded(at: index)
                    index += 1
                }
                if index > nameStart { try append(nameStart..<index, .type) }
                while index < units.count && units[index] != 62 {
                    try checkpointIfNeeded(at: index)
                    if units[index] == 34 || units[index] == 39 {
                        let value = index
                        try scanString(quoteIndex: index)
                        try append(value, .string)
                    } else if identifierStart(units[index]) {
                        let attribute = index
                        index += 1
                        while index < units.count && (identifierContinuation(units[index]) || [45, 58].contains(units[index])) {
                            try checkpointIfNeeded(at: index)
                            index += 1
                        }
                        try append(attribute, .keyword)
                    } else { index += 1 }
                }
                if index < units.count { index += 1 }
            } else { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights LaTeX control words and comments without expanding macros or input files.
    private mutating func scanLaTeX() throws -> HighlightedSource {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let start = index
            if units[index] == 37, try isEscaped(at: index) == false {
                index += 1
                try scanLine()
                try append(start, .comment)
            } else if units[index] == 92 {
                index += 1
                if index < units.count, identifierStart(units[index]) {
                    while index < units.count && (identifierContinuation(units[index]) || units[index] == 64) {
                        try checkpointIfNeeded(at: index)
                        index += 1
                    }
                    try append(start, .keyword)
                } else if index < units.count { index += 1 }
            } else if units[index] == 34 || units[index] == 39 {
                try scanString(quoteIndex: index)
                try append(start, .string)
            } else if digit(units[index]) {
                try scanNumber()
                try append(start, .number)
            } else { index += 1 }
        }
        return .init(runs: runs)
    }

    /// Counts preceding backslashes to distinguish escaped TeX comment markers.
    private mutating func isEscaped(at position: Int) throws -> Bool {
        var cursor = position
        var slashCount = 0
        while cursor > 0 && units[cursor - 1] == 92 {
            slashCount += 1
            if slashCount.isMultiple(of: 256) { try checkpoint() }
            cursor -= 1
        }
        return !slashCount.isMultiple(of: 2)
    }

    /// Highlights Markdown headings, fences and inline code while preserving every source scalar.
    private mutating func scanMarkdown() throws -> HighlightedSource {
        var insideFence: (marker: UInt16, count: Int)?
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let lineStart = index
            var lineEnd = index
            while lineEnd < units.count && units[lineEnd] != 10 && units[lineEnd] != 13 {
                try checkpointIfNeeded(at: lineEnd)
                lineEnd += 1
            }
            var contentStart = lineStart
            while contentStart < lineEnd && contentStart - lineStart < 4 && units[contentStart] == 32 { contentStart += 1 }
            let fenceMarker = contentStart < lineEnd && (units[contentStart] == 96 || units[contentStart] == 126) ? units[contentStart] : nil
            var fenceCount = 0
            if let fenceMarker {
                while contentStart + fenceCount < lineEnd && units[contentStart + fenceCount] == fenceMarker { fenceCount += 1 }
            }
            if let fenceMarker, fenceCount >= 3 {
                if let openFence = insideFence {
                    if openFence.marker == fenceMarker && fenceCount >= openFence.count {
                        try appendRange(lineStart, lineEnd, .directive)
                        insideFence = nil
                    }
                } else {
                    insideFence = (fenceMarker, fenceCount)
                    try appendRange(lineStart, lineEnd, .directive)
                }
            } else if insideFence == nil {
                var headingEnd = contentStart
                while headingEnd < lineEnd && units[headingEnd] == 35 && headingEnd - contentStart < 6 { headingEnd += 1 }
                if headingEnd > contentStart, headingEnd < lineEnd, units[headingEnd] == 32 {
                    try appendRange(lineStart, lineEnd, .keyword)
                } else {
                    var cursor = lineStart
                    while cursor < lineEnd {
                        try checkpointIfNeeded(at: cursor)
                        guard units[cursor] == 96 else { cursor += 1; continue }
                        var delimiterEnd = cursor
                        while delimiterEnd < lineEnd && units[delimiterEnd] == 96 { delimiterEnd += 1 }
                        let count = delimiterEnd - cursor
                        var close = delimiterEnd
                        while close < lineEnd {
                            if units[close] == 96 {
                                var closeEnd = close
                                while closeEnd < lineEnd && units[closeEnd] == 96 { closeEnd += 1 }
                                if closeEnd - close == count { try appendRange(cursor, closeEnd, .string); cursor = closeEnd; break }
                                close = closeEnd
                            } else { close += 1 }
                        }
                        if close >= lineEnd { cursor = delimiterEnd }
                    }
                }
            }
            index = lineEnd
            if index < units.count, units[index] == 13 { index += 1 }
            if index < units.count, units[index] == 10 { index += 1 }
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights AsciiDoc headings, block delimiters, attributes and comments without rendering them.
    private mutating func scanAsciiDoc() throws -> HighlightedSource {
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let lineStart = index
            let lineEnd = try self.lineEnd(from: lineStart)
            var first = lineStart
            while first < lineEnd && whitespace(units[first]) { first += 1 }
            if first < lineEnd {
                if units[first..<lineEnd].starts(with: [47, 47]) {
                    try appendRange(lineStart, lineEnd, .comment)
                } else if units[first] == 61 {
                    var headingEnd = first
                    while headingEnd < lineEnd && headingEnd - first < 6 && units[headingEnd] == 61 { headingEnd += 1 }
                    if headingEnd > first && headingEnd < lineEnd && units[headingEnd] == 32 {
                        try appendRange(lineStart, lineEnd, .keyword)
                    }
                } else if units[first] == 58, let closing = units[(first + 1)..<lineEnd].firstIndex(of: 58), closing > first + 1 {
                    try append(first..<closing, .variable)
                } else if units[first] == 91 && units[(first + 1)..<lineEnd].contains(93) {
                    try appendRange(lineStart, lineEnd, .directive)
                } else if units[first..<lineEnd].allSatisfy({ $0 == 45 }) && lineEnd - first >= 4 {
                    try appendRange(lineStart, lineEnd, .directive)
                }
            }
            index = nextLine(after: lineEnd)
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights reStructuredText headings and directive lines without resolving roles or references.
    private mutating func scanReStructuredText() throws -> HighlightedSource {
        let adornments: Set<UInt16> = [34, 35, 42, 43, 45, 46, 58, 61, 94, 96, 126]
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let lineStart = index
            let lineEnd = try self.lineEnd(from: lineStart)
            var first = lineStart
            while first < lineEnd && whitespace(units[first]) { first += 1 }
            if first < lineEnd {
                let marker = units[first]
                let isAdornment = adornments.contains(marker)
                    && lineEnd - first >= 2
                    && units[first..<lineEnd].allSatisfy { $0 == marker }
                if isAdornment {
                    try appendRange(lineStart, lineEnd, .directive)
                } else if units[first..<lineEnd].starts(with: [46, 46, 32]) {
                    var hasDirectiveMarker = false
                    if lineEnd - first >= 4 {
                        for position in (first + 2)..<(lineEnd - 1) where units[position] == 58 && units[position + 1] == 58 {
                            hasDirectiveMarker = true
                            break
                        }
                    }
                    try appendRange(lineStart, lineEnd, hasDirectiveMarker ? .directive : .comment)
                } else {
                    try highlightReStructuredTextInline(from: lineStart, to: lineEnd)
                }
            }
            index = nextLine(after: lineEnd)
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Highlights Org Mode structural markers only; blocks and metadata are never evaluated.
    private mutating func scanOrgMode() throws -> HighlightedSource {
        let todoStates: Set<String> = ["TODO", "NEXT", "WAIT", "HOLD", "DONE", "CANCELED"]
        while index < units.count {
            try checkpointIfNeeded(at: index)
            let lineStart = index
            let end = try lineEnd(from: lineStart)
            var first = lineStart
            while first < end && whitespace(units[first]) { first += 1 }
            if first < end {
                if units[first] == 35, first + 1 < end, units[first + 1] == 32 {
                    try appendRange(lineStart, end, .comment)
                } else if first + 1 < end, units[first] == 35, units[first + 1] == 43 {
                    var markerEnd = first + 2
                    while markerEnd < end && !whitespace(units[markerEnd]) && units[markerEnd] != 58 { markerEnd += 1 }
                    try append(first..<markerEnd, .directive)
                } else if units[first] == 42 {
                    var markerEnd = first
                    while markerEnd < end && units[markerEnd] == 42 { markerEnd += 1 }
                    if markerEnd < end && whitespace(units[markerEnd]) {
                        try append(first..<markerEnd, .keyword)
                        var wordStart = markerEnd
                        while wordStart < end && whitespace(units[wordStart]) { wordStart += 1 }
                        var wordEnd = wordStart
                        while wordEnd < end && identifierContinuation(units[wordEnd]) { wordEnd += 1 }
                        let state = String(decoding: units[wordStart..<wordEnd], as: UTF16.self)
                        if todoStates.contains(state) { try append(wordStart..<wordEnd, .keyword) }
                    }
                }
            }
            index = nextLine(after: end)
        }
        try checkpoint()
        return .init(runs: runs)
    }

    /// Marks short inline emphasis and literal spans while avoiding unbounded delimiter searches.
    private mutating func highlightReStructuredTextInline(from start: Int, to end: Int) throws {
        var cursor = start
        while cursor < end {
            try checkpointIfNeeded(at: cursor)
            let marker = units[cursor]
            guard marker == 42 || marker == 96 else { cursor += 1; continue }
            let markerCount = marker == 42 && cursor + 1 < end && units[cursor + 1] == marker ? 2 : 1
            let searchEnd = min(end, cursor + 258)
            var closing = cursor + markerCount
            var found: Int?
            while closing < searchEnd {
                try checkpointIfNeeded(at: closing)
                if units[closing] == marker {
                    let closeCount = marker == 42 && closing + 1 < end && units[closing + 1] == marker ? 2 : 1
                    if closeCount == markerCount { found = closing; break }
                    closing += closeCount
                } else {
                    closing += 1
                }
            }
            if let found {
                let spanEnd = found + markerCount
                try appendRange(cursor, spanEnd, marker == 96 ? .string : .keyword)
                cursor = spanEnd
            } else {
                cursor += markerCount
            }
        }
    }

    /// Appends a non-overlapping source span in the format required by NSTextStorage.
    private mutating func appendRange(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) throws {
        guard end > start, runs.count < 50_000 else { throw SyntaxHighlightingFailure.limit }
        runs.append(.init(range: .init(location: start, length: end - start), kind: kind))
    }

    /// Returns the quote after a bounded run of Swift raw-string hash markers, if present.
    private func rawSwiftQuote() -> Int? {
        var quote = index
        while quote < units.count && units[quote] == 35 && quote - index < 64 { quote += 1 }
        return quote < units.count && units[quote] == 34 ? quote : nil
    }

    /// Consumes a string literal using only delimiter rules shared by the supported language subset.
    private mutating func scanString(quoteIndex: Int, hashes: Int = 0) throws {
        let quote = units[quoteIndex]
        if language == .yang {
            index = quoteIndex + 1
            while index < units.count {
                try checkpointIfNeeded(at: index)
                if units[index] == quote {
                    index += 1
                    return
                }
                if quote == 34 && units[index] == 92 {
                    index += min(2, units.count - index)
                    if index < units.count, (0xDC00...0xDFFF).contains(units[index]),
                       (0xD800...0xDBFF).contains(units[index - 1]) { index += 1 }
                } else {
                    index += 1
                }
            }
            return
        }
        let supportsTriple = language == .python || language == .julia || language == .scala
            || (language == .elm && quote == 34)
            || (language == .nim && quote == 34)
            || (quote == 34 && [.swift, .java, .groovy, .toml, .kotlin].contains(language))
        let triple = supportsTriple && quoteIndex + 2 < units.count && units[quoteIndex + 1] == quote && units[quoteIndex + 2] == quote
        let delimiterCount = triple ? 3 : 1
        index = quoteIndex + delimiterCount
        while index < units.count {
            try checkpointIfNeeded(at: index)
            if units[index] == quote, matchesDelimiter(at: index, quote: quote, count: delimiterCount, hashes: hashes) {
                if language == .visualBasic, quote == 34, next() == quote {
                    index += 2
                    continue
                }
                if language == .ada, quote == 34, index > quoteIndex + 1, next() == quote {
                    index += 2
                    continue
                }
                index += delimiterCount + hashes
                return
            }
            if language == .elm && !triple && units[index] == 92 && index + 1 < units.count
                && [10, 13].contains(units[index + 1]) {
                index += 1
                return
            }
            if units[index] == 92 && hashes == 0
                && !(language == .shell && quote == 39)
                && !(language == .go && quote == 96)
                && !(language == .kotlin && triple) {
                index += min(2, units.count - index)
                // Do not end a run between a UTF-16 surrogate pair after an escaped scalar.
                if index < units.count, (0xDC00...0xDFFF).contains(units[index]), (0xD800...0xDBFF).contains(units[index - 1]) { index += 1 }
            } else if !triple && quote != 96 && language != .shell && (units[index] == 10 || units[index] == 13) { return }
            else { index += 1 }
        }
    }

    /// Tests a complete quote/hash terminator without crossing the retained UTF-16 buffer.
    private func matchesDelimiter(at start: Int, quote: UInt16, count: Int, hashes: Int) -> Bool {
        guard start + count + hashes <= units.count else { return false }
        for offset in 0..<count where units[start + offset] != quote { return false }
        for offset in 0..<hashes where units[start + count + offset] != 35 { return false }
        return true
    }

    /// Consumes the supported decimal or radix-prefixed numeric subset without parsing its value.
    private mutating func scanNumber() throws {
        if units[index] == 48, let next = next(), [88, 120, 66, 98, 79, 111].contains(next) {
            index += 2
            while index < units.count && ((48...57).contains(units[index]) || (65...70).contains(units[index]) || (97...102).contains(units[index]) || units[index] == 95) {
                try checkpointIfNeeded(at: index)
                index += 1
            }
            return
        }
        while index < units.count && (digit(units[index]) || units[index] == 95) {
            try checkpointIfNeeded(at: index)
            index += 1
        }
        if index + 1 < units.count, units[index] == 46, digit(units[index + 1]) {
            index += 1
            while index < units.count && (digit(units[index]) || units[index] == 95) {
                try checkpointIfNeeded(at: index)
                index += 1
            }
        }
        if index < units.count && (units[index] == 69 || units[index] == 101) {
            var exponent = index + 1
            if exponent < units.count && (units[exponent] == 43 || units[exponent] == 45) { exponent += 1 }
            let digitsStart = exponent
            while exponent < units.count && digit(units[exponent]) {
                try checkpointIfNeeded(at: exponent)
                exponent += 1
            }
            if exponent > digitsStart { index = exponent }
        }
    }

    private static let pythonPrefixes: Set<String> = ["r", "u", "b", "f", "br", "rb", "fr", "rf"]
    /// Converts a space-delimited keyword list to a lookup set.
    private static func wordSet(_ value: String) -> Set<String> {
        Set(value.split(separator: " ").map(String.init))
    }
    private static let cudaKeywords: Set<String> = ["__global__", "__device__", "__host__", "__shared__", "__constant__", "__managed__", "__restrict__", "__forceinline__", "__launch_bounds__"]
    private static let keywords: [SourceLanguage: Set<String>] = [
        .rust: wordSet("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while").union(wordSet("abstract become box do final macro override priv typeof unsized virtual yield")),
        .php: wordSet("abstract and array as break callable case catch class clone const continue declare default die do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile eval exit extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list namespace new or print private protected public require require_once return static switch throw trait try unset use var while xor yield yield_from true false null self parent"),
        .terraform: wordSet("terraform required_providers required_version backend cloud provider variable locals module output resource data import moved removed check run ephemeral action for_each count depends_on lifecycle provisioner connection dynamic source version type default description sensitive nullable validation condition true false null self each path module var local"),
        .tsx: wordSet("abstract any as asserts async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number of private protected public readonly require return set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield"),
        .sql: wordSet("add all alter analyze and any as asc begin between by case cast check collate column commit constraint create cross current_date current_time database default delete desc distinct drop else end except exists explain false fetch for foreign from full function grant group having in index inner insert intersect into is join key left like limit natural not null offset on or order outer primary procedure references right rollback row select set table then true truncate union unique update using values view when where with"),
        .plsql: wordSet("add all alter and array as begin between body boolean bulk by case char close commit constant continue create cursor date declare default delete drop else elsif end exception execute exit false fetch for forall from function if immediate in insert integer into is limit loop merge null number open or order package pragma procedure raise raw record ref return rollback rowtype select set sql sysdate table then true type update using values varchar2 when while with"),
        .tsql: wordSet("add all alter and any as asc authorization begin between break browse bulk by cascade case catch check checkpoint close clustered coalesce collate column commit compute constraint contains containstable continue convert create current current_date current_time current_timestamp current_user cursor database dbcc deallocate declare default delete deny desc disk distinct distributed double drop else end errlvl escape except exec execute exists exit external fetch file fillfactor first follow for foreign from full function goto grant group having holdlock identity if index inner insert intersect into is join key kill left like line load lock login loop match max merge national nocheck nonclustered not null nullif of off offsets on open option or order outer over percent pivot plan precision primary print proc procedure public raiserror read readtext reconfigure references replication restore restrict return returns revoke right rollback rowcount rowguidcol rule save schema select session_user set setuser shutdown some statistics sum system_user table tablesample textsize then to top tran transaction trigger truncate try_convert union unique unpivot update use user using values view waitfor when where while with work writetext"),
        .meson: wordSet("and assert break continue elif else endif endfor endforeach endfunction endmacro endmodule endproject error false foreach if import include install_data install_headers install_man install_subdir library message project range run_command shared_library shared_module static_library subdir subdir_done test true warning declare_dependency executable files find_program get_option import join_paths library meson_version_options option configuration_data configure_file custom_target both_libraries"),
        .swift: Set("actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect init inout internal is lazy let mutating nil nonisolated nonmutating open operator optional override package private protocol public repeat required rethrows return self Self set some static struct subscript super switch throws throw true try typealias unowned var weak where while willSet".split(separator: " ").map(String.init)),
        .java: Set("abstract assert boolean break byte case catch char class const continue default do else enum extends final finally float for goto if implements import instanceof interface long native new null package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient true false try var void volatile while yield".split(separator: " ").map(String.init)),
        .c: Set("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local".split(separator: " ").map(String.init)),
        .cpp: Set("alignas alignof asm auto break case catch class concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do dynamic_cast else enum explicit export extern false for friend goto if inline mutable namespace new noexcept nullptr operator private protected public register reinterpret_cast requires return sizeof static static_assert static_cast struct switch template this thread_local throw true try typedef typeid typename union using virtual volatile while".split(separator: " ").map(String.init)),
        .python: Set("False None True and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield".split(separator: " ").map(String.init)),
        .javascript: Set("async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield".split(separator: " ").map(String.init)),
        .jsx: Set("async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield".split(separator: " ").map(String.init)),
        .typescript: Set("abstract any as asserts async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number of private protected public readonly require return set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield".split(separator: " ").map(String.init)),
        .shell: Set("if then else elif fi case esac for select while until do done in function time coproc true false export local readonly declare typeset unset return break continue exit source alias unalias".split(separator: " ").map(String.init)),
        .zig: Set("addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while".split(separator: " ").map(String.init)),
        .ada: Set("abort abs abstract accept access aliased all and array at begin body case constant declare delay delta digits do else elsif end entry exception exit for function generic goto if in interface is limited loop mod new not null of or others out package pragma private procedure protected raise range record rem renames requeue return reverse select separate subtype synchronized tagged task terminate then type until use when while with xor".split(separator: " ").map(String.init)),
        .actionscript: Set("as break case catch class const continue default delete do else extends false finally for function if implements import in include instanceof interface internal is namespace native new null package private protected public return static super switch this throw true try typeof use var void while with".split(separator: " ").map(String.init)),
        .assembly: Set("adc add addi addiu and b beq bge bgt ble blt bne br call cmp dec div inc j jmp jr lda lea li load lod mov move mul nop or pop push ret return rol ror rts sbc shl shr sta store sub syscall test xor".split(separator: " ").map(String.init)),
        .awk: Set("begin end beginfile endfile break continue delete do else exit for function if in next nextfile print printf return while".split(separator: " ").map(String.init)),
        .fsharp: Set("abstract and as assert asr base begin class default delegate do done downcast downto elif else end exception extern false finally for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new null of open or override private public rec return sig static struct then to true try type upcast use val void when while with yield".split(separator: " ").map(String.init)),
        .fish: Set("and begin break case command continue else end eval exec exit for function if not or read return set switch test then while".split(separator: " ").map(String.init)),
        .fortran: Set("allocatable allocate assignment block call case character class close common complex contains continue cycle data deallocate default do double precision else elseif end enddo endif entry equivalence exit external format function if implicit in integer interface intent intrinsic module namelist nullify only open operator parameter pointer print private procedure program public read real recursive result return save select stop subroutine target then type use value volatile where write".split(separator: " ").map(String.init)),
        .gdscript: Set("and as assert await break class_name class_name const continue elif else enum extends false for func if in is match namespace not or pass preload return self signal static func static var super true var while yield".split(separator: " ").map(String.init)),
        .gleam: Set(" as assert case const echo else fn if import let opaque panic pub todo try type use".split(separator: " ").map(String.init)),
        .go: Set("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var".split(separator: " ").map(String.init)),
        .groovy: Set("as assert break case catch class const continue def default do else enum extends false finally for if implements import in instanceof interface new null package private protected public return static super switch this throw throws trait try true while".split(separator: " ").map(String.init)),
        .haskell: Set("as case class data default deriving do else hiding if import in infix infixl infixr instance let module newtype of qualified then type where".split(separator: " ").map(String.init)),
        .d: Set("abstract alias align asm assert auto body break case cast catch class const continue delegate deprecated do else enum export extern false final finally for foreach foreach_reverse function goto if immutable import in inout interface invariant is lazy macro mixin module new nothrow null out override package pragma private protected public pure ref return scope shared static struct super switch synchronized template this throw true try typedef typeid typeof union unittest version void volatile while with".split(separator: " ").map(String.init)),
        .batch: Set("call cd chcp cls color copy del dir echo endlocal for goto if md mkdir move path pause popd pushd rd rem ren rename rmdir set setlocal shift start title type ver verify vol".split(separator: " ").map(String.init)),
        .dylan: Set("begin block case class define constant generic method macro variable end do else elseif finally for if let local module select unless until use while".split(separator: " ").map(String.init)),
        .eiffel: Set("across agent alias all and as assign attribute check class convert creation create Current debug deferred do else elseif end ensure expanded export external feature from frozen if implies indexing inherit inspect invariant like local loop not old once only or precursor redefine rename require rescue retry select separate then undefine until variant void when xor".split(separator: " ").map(String.init)),
        .elixir: Set("after alias and case catch cond def defdelegate defexception defimpl defmacro defmodule defoverridable defp defprotocol defstruct do else end false fn for if import in not or quote raise receive require rescue reraise super throw true try unless use when with".split(separator: " ").map(String.init)),
        .erlang: Set("after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let module not of orelse receive rem try when xor".split(separator: " ").map(String.init)),
        .clojure: wordSet("def defn defn- defmacro defmulti defmethod defrecord deftype defprotocol defonce ns require use import let loop recur fn if if-let if-not when when-let when-not cond case do doseq dotimes for try catch finally throw quote var set! binding comment and or not nil true false"),
        .csh: wordSet("if then else endif switch case default breaksw foreach while end repeat goto set setenv unset unsetenv alias unalias source onintr return break continue exit"),
        .csharp: wordSet("abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var"),
        .cmake: wordSet("add_compile_definitions add_compile_options add_custom_command add_custom_target add_definitions add_executable add_library add_subdirectory add_test aux_source_directory break build_command cmake_minimum_required cmake_policy configure_file continue else elseif endforeach endfunction endif endmacro endwhile execute_process file find_package foreach function get_filename_component if include list macro mark_as_advanced message option project return set separate_arguments set_target_properties string unset while"),
        .ruby: wordSet("alias and begin BEGIN break case class def defined do else elsif end END ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"),
        .coffeescript: wordSet("and break catch class continue delete do else extends false finally for from function if in is isnt loop new no not off on or of return switch then throw try true typeof until when while yes null undefined this super"),
        .coldfusion: wordSet("cfabort cfargument cfbreak cfcase cfcatch cfcomponent cfdirectory cfelse cfelseif cfexecute cfexit cffile cffinally cfflush cffunction cfhttp cfif cfimport cfinvoke cfloop cfoutput cfparam cfquery cfreturn cfsavecontent cfscript cfset cfswitch cfthrow cftry cfwhile component function"),
        .crystal: wordSet("abstract alias annotation as asm begin break case class def do else elsif end ensure enum extend false for fun if in include instance_sizeof is lib macro module next nil of out pointerof private protected require rescue responds_to? return select self sizeof struct super then true typeof union unless until when while with yield"),
        .cson: wordSet("and break catch class continue delete do else extends false finally for from function if in is isnt loop new no not off on or of return switch then throw try true typeof until when while yes null undefined this super"),
        .css: wordSet("important inherit initial unset revert revert-layer auto none normal transparent currentcolor solid dotted dashed hidden display position absolute relative fixed sticky flex grid block inline inline-block color background border margin padding width height min-width max-width font font-family font-size font-weight text-align content transform transition animation"),
        .bibtex: wordSet("article book booklet conference inbook incollection inproceedings manual mastersthesis misc phdthesis proceedings techreport unpublished address annote author booktitle chapter crossref edition editor howpublished institution journal key month note number organization pages publisher school series title type volume year"),
        .kotlin: Set("as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam suspend where actual abstract annotation companion const crossinline data enum external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg".split(separator: " ").map(String.init)),
        .less: Set("and not or true false when important each extend default".split(separator: " ").map(String.init)),
        .lisp: Set("defun defvar defparameter defconstant lambda let let* if when unless cond progn quote function setq setf car cdr cons list append mapcar reduce apply funcall loop do dolist dotimes block return-from catch throw unwind-protect defmacro defstruct defclass defmethod defgeneric in-package require provide".split(separator: " ").map(String.init)),
        .lua: Set("and break do else elseif end false for function goto if in local nil not or repeat return then true until while".split(separator: " ").map(String.init)),
        .powershell: Set("begin break catch class continue data define do dynamicparam else elseif end exit filter finally for foreach from function if in param process return static switch throw trap try until using var while workflow".split(separator: " ").map(String.init)),
        .miniscript: Set("and break class continue do else for func if import in is not null or pass return self super then true false var while".split(separator: " ").map(String.init)),
        .dockerfile: Set("add arg cmd copy entrypoint env expose from healthcheck label maintainer onbuild run shell standoff user volume workdir".split(separator: " ").map(String.init)),
        .nix: wordSet("assert else false if inherit in let null or rec then true with"),
        .cue: wordSet("false for if import in let null package true"),
        .kdl: wordSet("false inf nan null true"),
        .objectiveC: wordSet("auto break case char const continue default do double else enum extern false float for goto if inline int long register restrict return short sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex _Imaginary interface implementation protocol property synthesize dynamic selector optional required end self super nil YES NO"),
        .matlab: wordSet("arguments break case catch classdef continue else elseif end for function global if otherwise parfor persistent return spmd switch try while methods properties events enumeration import"),
        .ocaml: wordSet("and as assert begin class constraint do done downto else end exception external false for fun function functor if in include inherit initializer lazy let match method module mutable new object of open private rec sig struct then to true try type val virtual when while with"),
        .tcl: wordSet("after append apply array break catch cd chan clock close concat continue dict encoding eof error eval exec exit expr file for foreach format gets glob global if incr info join lappend lindex linsert list llength namespace open package pid proc puts pwd read regexp regsub rename return scan seek set socket source split string subst switch tell time trace try unset update uplevel upvar variable vwait while"),
        .appleScript: wordSet("about after and as at back before beginning behind below beside between by copy div do else end equal error every false get if in is it its me mod my not of on or over put ref repeat return script set tell then through to try until where while with without true"),
        .nginx: wordSet("accept_mutex access_log alias allow auth_basic autoindex break client_body_timeout client_max_body_size client_header_timeout connection_pool_size deny error_log error_page events expires fastcgi_pass gzip http if include index internal keepalive_timeout listen location log_format map multi_accept proxy_buffer_size proxy_cache proxy_pass proxy_read_timeout proxy_redirect proxy_set_header return rewrite root sendfile server server_name server_tokens ssl ssl_certificate ssl_certificate_key tcp_nodelay try_files types upstream user worker_connections worker_processes"),
        .apache: wordSet("AddDefaultCharset AddHandler AddType Allow AllowOverride AuthType CustomLog Deny Directory DirectoryIndex DocumentRoot ErrorLog Files FilesMatch FollowSymLinks Header IfModule Include LoadModule LogFormat Options Order ProxyPass ProxyPassReverse Redirect Require RewriteCond RewriteEngine RewriteRule ServerAlias ServerName ServerRoot SetHandler SSLCertificateFile SSLCertificateKeyFile SSLEngine VirtualHost"),
        .perl: wordSet("and cmp continue do else elsif eq exp for foreach ge given gt if last le local lt m ne next no not or package redo require return s state sub tr unless until use when while xor my our shift undef wantarray __DATA__ __END__"),
        .r: wordSet("break else FALSE for function if Inf in NA NaN next NULL repeat return TRUE while"),
        .scala: wordSet("abstract case catch class def do else extends false final finally for forSome if implicit import lazy match new null object override package private protected return sealed super this throw trait try true type val var while with yield"),
        .julia: wordSet("baremodule begin break catch const continue do else elseif end export false finally for function global if import let local macro module mutable primitive quote return struct true try using where while"),
        .visualBasic: wordSet("addhandler addressof alias and andalso as boolean byref byte byval call case catch cbool cbyte cchar cdate cdec cdbl char cint class clng cobj const continue csbyte cshort csng cstr ctype date decimal declare default delegate dim directcast do double each else elseif end enum erase error event exit false finally for friend function get gettype getxmlnamespace global gosub goto handles if implements imports in inherits integer interface is isnot let lib like long loop me mod module mustinherit mustoverride mybase myclass namespace narrowing new next not nothing notinheritable notoverridable object of on operator option optional or orelse out overloads overridable overrides paramarray partial private property protected public raiseevent readonly redim rem removehandler resume return sbyte select set shadows shared short single static step stop string structure sub synclock then throw to true try trycast typeof uinteger ulong ushort using when while widening with withevents writeonly xor"),
        .vala: wordSet("abstract as async base bool break case catch class const continue default delegate delete do else ensures enum errordomain extern false finally for foreach gettype if implements in inline internal interface is lock namespace new null out owned override private protected public ref requires return set signal sizeof static struct switch this throws throw true try typeof unowned using value void volatile weak while yield"),
        .vimscript: wordSet("append argadd argdelete argdo autocmd augroup break call catch cdo cdiff center changes checktime cnext copen copy cprevious cquit cscope cwindow delete doall echo echoerr echohl echomsg echon else elseif endfor endfunction endif endtry endwhile execute exit file finish for function global goto if import keepjumps let lockmark map marks menu messages mkexrc move next noautocmd normal number only open pedit pop print put quit qall read redo return runtime saveas sbuffer set setglobal setlocal shell sort source split stop suspend tabclose tabedit tabnext tabnew tabonly tabprevious tabrewind throw try unlet unlock vglobal view vimgrep vmap wall while wincmd window write xit"),
        .nim: wordSet("addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod module nil not notin object of or out proc ptr raise ref result return static template try tuple type using var when while xor yield"),
        .openSCAD: wordSet("assert assign children color cube cylinder difference dxf_dim dxf_cross each else echo else for function hull if import intersection intersection_for let linear_extrude minkowski mirror module multmatrix offset polygon polyhedron projection render resize rotate rotate_extrude scale sphere square surface text translate union use"),
        .webAssemblyText: wordSet("module func param result local global import export memory table start elem data type call call_indirect drop select block loop if then else end br br_if br_table return unreachable nop ref.null ref.func ref.is_null local.get local.set local.tee global.get global.set memory.size memory.grow i32.const i64.const f32.const f64.const i32.add i32.sub i32.mul i32.div_s i32.div_u i64.add i64.sub i64.mul f32.add f32.sub f32.mul f64.add f64.sub f64.mul"),
        .pascal: wordSet("absolute abstract and array asm assembler begin case const constructor destructor dispid div do downto else end except exports external far file finalization finally for forward function goto if implementation in inherited initialization inline interface is label library mod nil not object of on operator or packed private procedure program property protected public published raise record repeat resourcestring set shl shr then threadvar to try type unit until uses var virtual while xor"),
        .verilog: wordSet("always always_comb always_ff always_latch and assign automatic begin buf case casex casez cell config deassign default defparam design disable edge else end endcase endfunction endgenerate endmodule endprimitive endspecify endtable endtask event for force forever fork function generate genvar if initial inout input integer join localparam macromodule module nand negedge nmos nor not or output parameter posedge primitive pullup pulldown reg release repeat rnmos rpmos rtran rtranif0 signed specify specparam strong0 strong1 supply0 supply1 table task time tran tranif0 tranif1 tri tri0 tri1 triand trior trireg unsigned use vectored wait wand weak0 weak1 while wire wor xnor xor always_ff always_comb interface modport package endinterface endpackage import export logic"),
        .vhdl: wordSet("abs access after alias all and architecture array assert assume assume_guarantee attribute begin block body buffer bus case component configuration constant context cover disconnect downto else elsif end entity exit fairness file force function generate generic group guarded if impure in inertial inout is label library linkage literal loop map mod nand new next nor not null of on open or others out package parameter port postponed procedure process property protected pure range record register reject release rem report restrict return rol ror select sequence severity shared signal sla sll sra srl strong subtype then to transport type unaffected units until use variable vmode vprop vunit wait when while with xnor xor"),
        .cobol: wordSet("accept add address advancing after all alphabet alphabetic alphabetic-lower alphabetic-upper alphanumeric alphanumeric-edited also alter alternate and are area areas arithmetic ascending assign at author before by call cancel character class clock-units close code codes collating column columns comm commutative common communicating comp-1 comp-2 comp-3 comp-4 comp-5 computational computational-1 computational-2 computational-3 computational-4 computational-5 compute configuration contains content continue control controls converting copy corr correspondence count currency data date-compiled date-written day day-of-week de debugging decimal-point declaratives delete delimited delimiter depending descending destination detail disable display divide division down duplicate dynamic egi else end end-accept end-add end-call end-compute end-delete end-divide end-evaluate end-if end-multiply end-of-page end-perform end-read end-return end-rewrite end-search end-start end-string end-subtract end-unstring end-write ending erase error exception exception-object exception-status exit extend external false fd file file-control fill final first for from function generate giving global goback greater group heading high-value high-values i-o i-o-control id identification if in index index-1 index-2 index-3 indexed indicator initialize input input-output insert inspect installation install into invalid is key label last leading left length less limit limits linkage local-storage lock low-value low-values memory merge message mode modules move multiple multiply native negative no not numeric numeric-edited object objective occurs of off omit on open optional or order organization other output overflow page page-counter paragraph perform pf ph pic picture plus pointer positive printing procedure procedures proceed process program program-id purge random read ready receive record records redefines reel reference references relative release remainder removal rename replacing report report-writer reports rereun reset return returning reverse rewind rewrite rf rh right rounded run same sd search section security segment segment-limit select self send sentence separate sequence sequential set shared sharing sign size sort source source-computer source-code source-computer special-names standard start status stop string subtract sum suppress symbol symbolic sync synchronized table tallying tape task terminate than then through thru time times to top trailer true type uncle unstring until upon usage use using value values varying when with words working-storage write zero zeroes zeros") ,
        .deviceTree: wordSet("address-cells aliases append boot_cpuid_phys chosen compatible cpus delete-node delete-property device_type dma-ranges dts-v1 interrupt-map interrupt-parent interrupt-controller interrupts memory model name phandle ranges reg reserve-map reserved-memory status stdout-path virtual-dma") ,
        .gettext: wordSet("msgctxt msgid msgid_plural msgstr"),
        .erb: wordSet("alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield"),
        .qml: wordSet("as break case catch class const continue debugger default delete do else export extends false finally for function if import in instanceof let new null of property readonly required return signal static switch this throw true try typeof undefined var void while with id alias component enum import inline list namespace on pragma property readonly required signal singleton var"),
        .solidity: wordSet("abstract after alias apply auto case catch constant constructor contract continue delete do else emit enum event external false for function if implements import in indexed interface internal is library mapping memory modifier new payable pragma private public pure receive return returns revert selfdestruct storage string switch this throw true try using view while"),
        .autoHotkey: wordSet("and break catch class continue else exitapp false finally for global gosub goto hotif hotkey hotstring if local loop msgbox return send settimer sleep static switch throw true try until while"),
        .innoSetup: wordSet("appname appversion appid apppublisher appcopyright appcomments appreadmefilename appcontact appsupporturl appupdatesurl defaultdirname defaultgroupname outputdir outputbasefilename setup uninstalldisplayicon architecturesinstallin64bitmode privilegesrequired files icons tasks types components languages run registry deleteinifile"),
        .nsis: wordSet("addsize abort allowrootdirinstall brandingtext call caption delete detailprint dirtext else elseif end endfunction endif endmacro endsection exec execshell file function goto hidewindow if ifdef ifndef ifmacro ifnmacro instfiles installcolors installbuttontext installcontinue install dirinfo name outfile page section sectionend setautoclose setcompress setdatetime setdetailsview seterrors setoutpath setshellvarcontext showinstdetails showuninstdetails silentinstall silentuninstall sleep strcmp uninstpage uninsttext var version"),
        .rego: wordSet("allow as default else every false if import in not null package some test true with"),
        .ldif: wordSet("add delete dn changetype control include modify moddn modrdn newrdn newsuperior objectclass"),
        .turtle: wordSet("a base prefix true false"),
        .yang: wordSet("module submodule yang-version namespace prefix import include belongs-to organization contact description reference revision revision-date typedef grouping uses container list leaf leaf-list key type enumeration enum identity base feature if-feature augment deviation rpc input output notification config mandatory default status units range length pattern must when"),
        .elm: wordSet("alias as case else exposing if import in infix let module of port then type")
    ]
    private static let solidityTypes: Set<String> = {
        let widths = stride(from: 8, through: 256, by: 8).map(String.init)
        return Set(widths.flatMap { ["int\($0)", "uint\($0)"] }
            + (1...32).map { "bytes\($0)" } + ["fixed", "ufixed"])
    }()
    private static let types: [SourceLanguage: Set<String>] = [
        .rust: ["bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "String", "u8", "u16", "u32", "u64", "u128", "usize", "Vec"],
        .php: ["bool", "false", "float", "int", "iterable", "mixed", "never", "object", "string", "void"],
        .terraform: ["bool", "number", "string", "list", "map", "set", "object", "tuple", "any"],
        .cue: ["bool", "bytes", "float", "int", "number", "string", "uint"],
        .sql: [], .tsql: ["bigint", "binary", "bit", "char", "date", "datetime", "datetime2", "datetimeoffset", "decimal", "float", "int", "money", "nchar", "ntext", "numeric", "nvarchar", "real", "smalldatetime", "smallint", "smallmoney", "sql_variant", "text", "time", "timestamp", "tinyint", "uniqueidentifier", "varbinary", "varchar"], .html: [],
        .swift: ["Int", "String", "Bool", "Double", "Float", "Array", "Dictionary", "Set"],
        .java: ["int", "double", "String", "Integer", "Object"],
        .c: ["int", "char", "short", "long", "float", "double", "void", "signed", "unsigned", "bool", "size_t"],
        .cpp: ["int", "char", "short", "long", "float", "double", "void", "signed", "unsigned", "bool", "size_t"],
        .python: ["int", "str", "bool", "float", "list", "dict", "tuple", "set", "bytes"],
        .javascript: [], .jsx: [], .typescript: [], .shell: [], .zig: [],
        .ada: ["Boolean", "Character", "Duration", "Float", "Integer", "Natural", "Positive", "String"],
        .actionscript: ["Array", "Boolean", "Class", "Function", "int", "Number", "Object", "String", "uint", "void"],
        .assembly: ["eax", "ebx", "ecx", "edx", "rax", "rbp", "rsp"], .awk: [],
        .fsharp: ["bool", "byte", "char", "decimal", "float", "int", "list", "option", "string"],
        .fish: [], .fortran: ["integer", "real", "logical", "character", "complex"],
        .gdscript: ["Array", "Dictionary", "Node", "String", "Vector2", "Vector3"],
        .gleam: ["Bool", "Float", "Int", "List", "Result", "String"],
        .go: ["bool", "byte", "error", "int", "rune", "string", "uint", "uintptr"],
        .groovy: ["boolean", "def", "int", "long", "String"], .haskell: ["Bool", "Char", "Either", "IO", "Int", "Maybe", "String"],
        .d: [], .batch: [], .dylan: [], .eiffel: [], .elixir: [], .erlang: [],
        .kotlin: ["Any", "Boolean", "Byte", "Char", "Double", "Float", "Int", "List", "Long", "Map", "Nothing", "Number", "Set", "Short", "String", "Unit"],
        .less: [], .lisp: [], .lua: [], .powershell: [], .miniscript: [], .markdown: [],
        .objectiveC: ["BOOL", "Class", "instancetype", "NSInteger", "NSObject", "NSString", "NSUInteger", "void"],
        .perl: [], .r: [], .scala: ["Any", "Boolean", "Int", "List", "Nothing", "Option", "String", "Unit"],
        .julia: ["AbstractArray", "Bool", "DataFrame", "Float64", "Int", "Nothing", "String", "Vector"],
        .matlab: ["cell", "char", "double", "int32", "logical", "single", "string", "struct", "table"],
        .ocaml: ["bool", "char", "float", "int", "list", "option", "ref", "string", "unit"],
        .tcl: [], .appleScript: [], .nginx: [], .apache: [],
        .visualBasic: ["boolean", "byte", "char", "date", "decimal", "double", "integer", "long", "object", "sbyte", "short", "single", "string", "uinteger", "ulong", "ushort"],
        .vala: ["bool", "char", "double", "float", "int", "int8", "int16", "int32", "int64", "long", "short", "size_t", "string", "uint", "ulong", "ushort", "void"],
        .vimscript: [],
        .nim: ["bool", "char", "float", "float32", "float64", "int", "int8", "int16", "int32", "int64", "string", "uint", "uint8", "uint16", "uint32", "uint64"],
        .openSCAD: [], .webAssemblyText: ["anyfunc", "externref", "f32", "f64", "funcref", "i32", "i64", "v128"],
        .pascal: ["ansistring", "boolean", "byte", "char", "currency", "double", "extended", "integer", "longint", "qword", "real", "shortint", "single", "smallint", "string", "variant", "word"],
        .verilog: ["bit", "byte", "int", "integer", "logic", "longint", "reg", "realtime", "real", "shortint", "string", "time", "tri", "wire"],
        .vhdl: ["bit", "bit_vector", "boolean", "character", "integer", "natural", "positive", "real", "signed", "std_logic", "std_logic_vector", "string", "time", "unsigned"],
        .cobol: ["binary", "comp", "comp-1", "comp-2", "comp-3", "comp-4", "comp-5", "display", "pic", "picture", "packed-decimal"],
        .deviceTree: ["phandle", "uint8", "uint16", "uint32", "uint64"],
        .gettext: [],
        .erb: [], .qml: ["bool", "double", "int", "real", "string", "var"],
        .solidity: ["address", "bool", "bytes", "fixed", "int", "mapping", "string", "uint", "ufixed"]
    ]
}
