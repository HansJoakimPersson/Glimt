import Foundation

/// A deterministic explanation, independent of the legacy resolver's numeric confidence.
public struct SourceDetection: Equatable, Sendable {
    /// Winning reason used to explain the selected language or plain/binary fallback.
    public enum Reason: String, Equatable, Sendable {
        case exactFilename, fileExtension, contentEvidence, systemUTI, shebang, plainText, binary
    }

    /// `nil` selects readable plain/config text, or the existing binary fallback.
    public let language: SourceLanguage?
    public let reason: Reason
}

/// Chooses a source language from already bounded text analysis; never executes a shebang.
public enum SourceDetector {
    /// Prefers explicit format metadata and only considers shebangs after filename and UTI evidence.
    public static func detect(fileName: String, systemUTI: String? = nil,
                              analysis: TextAnalysis) -> SourceDetection {
        // Keep structured/config formats ahead of generic source heuristics to avoid misleading highlighting.
        guard !analysis.isBinary else { return .init(language: nil, reason: .binary) }
        let name = (fileName as NSString).lastPathComponent
        // Catalog-defined structured and configuration formats keep their own inspection path.
        if FormatCatalog.recognizedTextFormat(fileName: name) != nil {
            return .init(language: nil, reason: .exactFilename)
        }
        if let exact = FormatCatalog.match(fileName: name),
           exact.exactFilenames.contains(name), let language = exact.sourceLanguage {
            return .init(language: language, reason: .exactFilename)
        }
        // Eiffel sources may use Elixir's .ex/.exs suffix; strong class evidence wins the tie.
        if ["ex", "exs"].contains((name as NSString).pathExtension.lowercased()), looksLikeEiffel(analysis.text) {
            return .init(language: .eiffel, reason: .fileExtension)
        }
        if (name as NSString).pathExtension.lowercased() == "m" {
            if looksLikeObjectiveC(analysis.text) { return .init(language: .objectiveC, reason: .contentEvidence) }
            if looksLikeMATLAB(analysis.text) { return .init(language: .matlab, reason: .contentEvidence) }
        }
        if (name as NSString).pathExtension.lowercased() == "conf", looksLikeNginx(analysis.text) {
            return .init(language: .nginx, reason: .contentEvidence)
        }
        if (name as NSString).pathExtension.lowercased() == "conf", looksLikeApache(analysis.text) {
            return .init(language: .apache, reason: .contentEvidence)
        }
        if (name as NSString).pathExtension.lowercased() == "sql", looksLikeTSQL(analysis.text) {
            return .init(language: .tsql, reason: .contentEvidence)
        }
        let pathExtension = (name as NSString).pathExtension.lowercased()
        if pathExtension == "v", looksLikeVerilog(analysis.text) {
            return .init(language: .verilog, reason: .contentEvidence)
        }
        if pathExtension == "pp", looksLikePascal(analysis.text) {
            return .init(language: .pascal, reason: .contentEvidence)
        }
        if let format = FormatCatalog.match(fileName: name), let language = format.sourceLanguage {
            return .init(language: language, reason: format.exactFilenames.contains(name) ? .exactFilename : .fileExtension)
        }
        if let systemUTI, let language = FormatCatalog.source(forSystemType: systemUTI) {
            return .init(language: language, reason: .systemUTI)
        }
        if let language = shebangLanguage(in: analysis) {
            return .init(language: language, reason: .shebang)
        }
        return .init(language: nil, reason: .plainText)
    }

    /// Selects T-SQL for ambiguous `.sql` files only when multiple SQL Server markers occur outside comments and strings.
    private static func looksLikeTSQL(_ text: String) -> Bool {
        let bytes = Array(text.utf8.prefix(65_536))
        var cleaned: [UInt8] = []
        cleaned.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if index + 1 < bytes.count, bytes[index] == 45, bytes[index + 1] == 45 {
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
            } else if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
                var commentDepth = 1
                index += 2
                while index + 1 < bytes.count, commentDepth > 0 {
                    if bytes[index] == 47, bytes[index + 1] == 42 {
                        commentDepth += 1
                        guard commentDepth <= 64 else { return false }
                        index += 2
                    } else if bytes[index] == 42, bytes[index + 1] == 47 {
                        commentDepth -= 1
                        index += 2
                    } else { index += 1 }
                }
            } else if bytes[index] == 39 {
                index += 1
                while index < bytes.count {
                    if bytes[index] == 39 {
                        if index + 1 < bytes.count, bytes[index + 1] == 39 { index += 2; continue }
                        index += 1
                        break
                    }
                    index += 1
                }
            } else {
                let byte = bytes[index]
                cleaned.append((65...90).contains(byte) ? byte + 32 : byte)
                index += 1
            }
        }
        let source = String(decoding: cleaned, as: UTF8.self)
        let markers = [
            #"(?m)^\s*go\s*;?\s*$"#,
            #"\bdeclare\s+@[a-z_]"#,
            #"\bset\s+nocount\s+on\b"#,
            #"\b(?:n?varchar|datetime2|uniqueidentifier)\b"#,
            #"\bidentity\s*\("#,
            #"\btop\s*(?:\(\s*\d+\s*\)|\d+)"#,
            #"\b(?:isnull|getdate|try_convert|raiserror)\s*\("#,
            #"\bbegin\s+try\b"#
        ]
        return markers.reduce(into: 0) { count, pattern in
            if source.range(of: pattern, options: .regularExpression) != nil { count += 1 }
        } >= 2
    }

    /// Resolves the shared `.v` suffix only when module boundaries and Verilog-specific tokens agree.
    private static func looksLikeVerilog(_ text: String) -> Bool {
        let source = maskVerilogCommentsAndStrings(text)
        let hasModule = source.range(of: #"\bmodule\b"#, options: .regularExpression) != nil
        let hasEndmodule = source.range(of: #"\bendmodule\b"#, options: .regularExpression) != nil
        guard hasModule, hasEndmodule else { return false }
        let markers = [
            #"\balways(?:_ff|_comb|_latch)?\b"#, #"\b(?:input|output|inout)\b"#,
            #"\b(?:logic|wire|reg)\b"#, #"\bassign\b"#, #"\b(?:posedge|negedge)\b"#
        ]
        return markers.contains { source.range(of: $0, options: .regularExpression) != nil }
    }

    /// Removes comments and string contents before using conservative Verilog content evidence.
    private static func maskVerilogCommentsAndStrings(_ text: String) -> String {
        let bytes = Array(text.utf8.prefix(65_536))
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 47 {
                index += 2
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
                output.append(32)
            } else if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
                guard index + 1 < bytes.count else { return "" }
                index += 2
                output.append(32)
            } else if bytes[index] == 34 {
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += min(2, bytes.count - index) }
                    else if bytes[index] == 34 { index += 1; break }
                    else { index += 1 }
                }
                output.append(32)
            } else {
                let byte = bytes[index]
                output.append((65...90).contains(byte) ? byte + 32 : byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Uses Pascal unit/program structure to disambiguate `.pp` from Puppet manifests.
    private static func looksLikePascal(_ text: String) -> Bool {
        let source = maskPascalCommentsAndStrings(text)
        let isProgram = source.range(of: #"\b(?:program|library)\b"#, options: .regularExpression) != nil
            && source.range(of: #"\bbegin\b"#, options: .regularExpression) != nil
        let isUnit = source.range(of: #"\bunit\b"#, options: .regularExpression) != nil
            && source.range(of: #"\binterface\b"#, options: .regularExpression) != nil
            && source.range(of: #"\bimplementation\b"#, options: .regularExpression) != nil
        return isProgram || isUnit
    }

    /// Masks Pascal brace/parenthesized comments, line comments, and quoted strings for `.pp` evidence.
    private static func maskPascalCommentsAndStrings(_ text: String) -> String {
        let bytes = Array(text.utf8.prefix(65_536))
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 47 {
                index += 2
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
                output.append(32)
            } else if bytes[index] == 123 {
                index += 1
                while index < bytes.count, bytes[index] != 125 { index += 1 }
                if index < bytes.count { index += 1 }
                output.append(32)
            } else if index + 1 < bytes.count, bytes[index] == 40, bytes[index + 1] == 42 {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 42 && bytes[index + 1] == 41) { index += 1 }
                guard index + 1 < bytes.count else { return "" }
                index += 2
                output.append(32)
            } else if bytes[index] == 39 {
                index += 1
                while index < bytes.count {
                    if bytes[index] == 39, index + 1 < bytes.count, bytes[index + 1] == 39 { index += 2 }
                    else if bytes[index] == 39 { index += 1; break }
                    else { index += 1 }
                }
                output.append(32)
            } else {
                let byte = bytes[index]
                output.append((65...90).contains(byte) ? byte + 32 : byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Resolves only unmistakable Eiffel class skeletons for suffixes shared with Elixir.
    private static func looksLikeEiffel(_ text: String) -> Bool {
        let prefix = String(decoding: text.utf8.prefix(65_536), as: UTF8.self).lowercased()
        let words = Set(prefix.split { !$0.isLetter && !$0.isNumber })
        return words.contains("class") && words.contains("feature")
            && (words.contains("do") || words.contains("inherit")) && words.contains("end")
    }

    /// Resolves the shared `.m` suffix only when MATLAB declarations provide positive evidence.
    private static func looksLikeMATLAB(_ text: String) -> Bool {
        let prefix = String(decoding: text.utf8.prefix(65_536), as: UTF8.self)
        let lines = prefix.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let objectiveCMarkers = ["#import", "#include", "@interface", "@implementation", "@protocol", "@autoreleasepool"]
        if lines.contains(where: { line in objectiveCMarkers.contains(where: { line.hasPrefix($0) }) }) { return false }
        let matlabMarkers = ["function ", "classdef ", "arguments", "parfor ", "spmd", "%%"]
        return lines.contains { line in
            let lowered = line.lowercased()
            return matlabMarkers.contains(where: { lowered.hasPrefix($0) })
                || lowered.range(of: #"^\s*[a-z_][a-z0-9_]*\s*=\s*(zeros|ones|eye|plot|table|readtable|fprintf)\s*\("#, options: .regularExpression) != nil
        }
    }

    /// Detects Objective-C `.m` source before considering MATLAB, leaving ambiguous text unclassified.
    private static func looksLikeObjectiveC(_ text: String) -> Bool {
        let prefix = String(decoding: text.utf8.prefix(65_536), as: UTF8.self)
        let markers = ["#import", "@interface", "@implementation", "@protocol", "@autoreleasepool", "@property"]
        return prefix.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return markers.contains(where: { trimmed.hasPrefix($0) })
                || trimmed.contains("NSLog(")
        }
    }

    /// Recognizes Nginx directives in generic `.conf` files without claiming ordinary key/value config.
    private static func looksLikeNginx(_ text: String) -> Bool {
        let prefix = String(decoding: text.utf8.prefix(65_536), as: UTF8.self)
        let lines = prefix.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let markers = ["upstream ", "proxy_pass", "worker_processes", "server_name", "fastcgi_pass", "try_files", "proxy_set_header", "ssl_certificate"]
        let matches = lines.filter { line in
            let lowered = line.lowercased()
            return markers.contains(where: { lowered.contains($0) })
        }
        let hasServerBlock = lines.contains { $0.lowercased().hasPrefix("server {") }
        let hasProxyPass = lines.contains { $0.lowercased().contains("proxy_pass") }
        let hasTLSListener = lines.contains { $0.lowercased().contains("listen") && $0.lowercased().contains("ssl") }
        return matches.count >= 2 || (hasServerBlock && (hasProxyPass || hasTLSListener))
    }

    /// Recognizes Apache directives in generic `.conf` files while leaving ambiguous text untouched.
    private static func looksLikeApache(_ text: String) -> Bool {
        let prefix = String(decoding: text.utf8.prefix(65_536), as: UTF8.self)
        let lines = prefix.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let markers = ["<virtualhost", "loadmodule ", "servername ", "documentroot ", "rewriterule ", "proxypass ", "require "]
        let matches = lines.filter { line in
            let lowered = line.lowercased()
            return markers.contains(where: { lowered.hasPrefix($0) })
        }
        return matches.count >= 2
    }

    /// Classifies supported interpreter names from a complete bounded first line without executing them.
    private static func shebangLanguage(in analysis: TextAnalysis) -> SourceLanguage? {
        // Inspect only the first bounded line and classify the interpreter name without executing it.
        let maximumBytes = 65_536
        let prefix = Array(analysis.text.utf8.prefix(maximumBytes))
        guard prefix.starts(with: [35, 33]) else { return nil }
        let firstEnding = prefix.firstIndex { $0 == 10 || $0 == 13 }
        let end: Int
        if let firstEnding { end = firstEnding }
        else {
            // A capped or incomplete first line must not turn a truncated interpreter into
            // a supported name. A genuinely complete EOF-terminated shebang is valid.
            guard !analysis.truncated, prefix.count < maximumBytes else { return nil }
            end = prefix.count
        }
        guard let line = String(bytes: prefix[2..<end], encoding: .utf8) else { return nil }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let command = words.first else { return nil }
        var interpreter = (String(command) as NSString).lastPathComponent
        if interpreter == "env" {
            var index = 1
            if words.count > index, words[index] == "-S" || words[index] == "--" { index += 1 }
            guard words.count > index else { return nil }
            interpreter = String(words[index])
        }
        if ["sh", "bash", "zsh"].contains(interpreter) { return .shell }
        if interpreter == "python" || interpreter == "python3" { return .python }
        if interpreter.hasPrefix("python3.") {
            let version = interpreter.dropFirst("python3.".count)
            if !version.isEmpty, version.allSatisfy({ $0.isASCII && $0.isNumber }) { return .python }
        }
        return nil
    }
}
