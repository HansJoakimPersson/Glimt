import Foundation

/// Resolves a filename and bounded leading byte sample into a registered type.
public struct TypeResolver: Sendable {
    private let registry: FileTypeRegistry

    /// Uses a validated registry so matching rules are deterministic and safe to inspect.
    public init(registry: FileTypeRegistry = .default) {
        self.registry = registry
    }

    /// Returns the deterministic winning match, its confidence, and ordered detector evidence.
    /// Combines registered filename, signature, content, and system-type evidence into one stable
    /// result. The bounded sample is evidence only; it is never interpreted as trusted content.
    public func resolve(
        fileName: String,
        leadingBytes: Data = Data(),
        systemUTI: String? = nil,
        sampleIsComplete: Bool = false
    ) -> ResolvedContentType {
        let basename = fileName.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let foldedBasename = Self.asciiFold(basename)
        var candidates: [Candidate] = []
        // Only a genuinely complete bounded sample can prove that a signature is not truncated.
        let confirmedEOF = sampleIsComplete && leadingBytes.count <= Self.maximumSampleBytes

        for definition in registry.definitions {
            for filename in definition.filenames {
                let foldedFilename = Self.asciiFold(filename)
                if foldedBasename == foldedFilename {
                    candidates.append(Candidate(
                        typeID: definition.typeID,
                        signalKind: .filename,
                        evidenceValue: foldedBasename,
                        matchedLiteral: foldedFilename
                    ))
                }
            }

            for prefix in definition.filenamePrefixes {
                let foldedPrefix = Self.asciiFold(prefix)
                if foldedBasename != foldedPrefix, foldedBasename.hasPrefix(foldedPrefix) {
                    candidates.append(Candidate(
                        typeID: definition.typeID,
                        signalKind: .filename,
                        evidenceValue: foldedBasename,
                        matchedLiteral: foldedPrefix
                    ))
                }
            }

            for suffix in definition.multiExtensions {
                let foldedSuffix = Self.asciiFold(suffix)
                if Self.hasNonemptyPrefix(before: foldedSuffix, in: foldedBasename) {
                    candidates.append(Candidate(
                        typeID: definition.typeID,
                        signalKind: .multiExtension,
                        evidenceValue: foldedSuffix,
                        matchedLiteral: foldedSuffix
                    ))
                }
            }

            for suffix in definition.singleExtensions {
                let foldedSuffix = Self.asciiFold(suffix)
                if Self.hasNonemptyPrefix(before: foldedSuffix, in: foldedBasename) {
                    candidates.append(Candidate(
                        typeID: definition.typeID,
                        signalKind: .singleExtension,
                        evidenceValue: foldedSuffix,
                        matchedLiteral: foldedSuffix
                    ))
                }
            }
        }

        if let interpreter = Self.shebangInterpreter(in: leadingBytes, sampleIsComplete: sampleIsComplete) {
            for definition in registry.definitions {
                for registeredInterpreter in definition.shebangInterpreters where registeredInterpreter == interpreter {
                    candidates.append(Candidate(
                        typeID: definition.typeID,
                        signalKind: .shebang,
                        evidenceValue: interpreter,
                        matchedLiteral: registeredInterpreter
                    ))
                }
            }
        }

        let legacyWinner = candidates.min(by: Self.precedes)
        let filenameWinner = Self.bestCandidate(in: candidates, for: .filename)
        let multiExtensionWinner = Self.bestCandidate(in: candidates, for: .multiExtension)
        let singleExtensionWinner = Self.bestCandidate(in: candidates, for: .singleExtension)
        let shebangWinner = Self.bestCandidate(in: candidates, for: .shebang)
        let magicDetection = Self.detectMagicSignature(in: leadingBytes, definitions: registry.definitions, confirmedEOF: confirmedEOF)
        let bomDetection = Self.detectBOM(in: leadingBytes, confirmedEOF: confirmedEOF)
        let hasYAMLEligibility = registry.definitions.contains(where: \.supportsYAMLContentDetection)
        let yamlMatch = hasYAMLEligibility
            ? Self.detectYAML(in: leadingBytes, sampleIsComplete: sampleIsComplete)
            : nil
        let yamlTypeID = yamlMatch == nil ? nil : registry.definitions
            .filter(\.supportsYAMLContentDetection)
            .map(\.typeID)
            .sorted(by: Self.typeIDPrecedes)
            .first
        let uti = Self.conclusiveUTI(systemUTI, definitions: registry.definitions)
        let utiTypes = uti.map { identifier in
            registry.definitions.filter { $0.systemUTIIdentifiers.contains(identifier) }
                .map(\.typeID)
        } ?? []
        let conflictOnly = systemUTI == "public.mpeg-2-transport-stream"
        let winnerTypeID: String
        let confidenceValue: Double
        let magicSelectedWinner: Bool

        // Preserve established filename/shebang precedence; stronger byte signatures are considered
        // only when those explicit identifiers provide no match.
        if let legacyWinner {
            winnerTypeID = legacyWinner.typeID
            confidenceValue = Self.score(for: legacyWinner.signalKind)
            magicSelectedWinner = false
        } else if let magicTypeID = magicDetection.typeID {
            winnerTypeID = magicTypeID
            confidenceValue = 0.85
            magicSelectedWinner = true
        } else if let yamlTypeID, let yamlMatch {
            winnerTypeID = yamlTypeID
            confidenceValue = yamlMatch.marker ? 0.80 : 0.75
            magicSelectedWinner = false
        } else if !utiTypes.isEmpty, !conflictOnly, let fallbackTypeID = utiTypes.sorted(by: Self.typeIDPrecedes).first {
            winnerTypeID = fallbackTypeID
            confidenceValue = 0.60
            magicSelectedWinner = false
        } else {
            winnerTypeID = "unknown"
            confidenceValue = 0
            magicSelectedWinner = false
        }

        let supportsWinner = uti.map { identifier in
            utiTypes.contains(winnerTypeID)
                || (identifier == "com.microsoft.typescript" && ["typescript", "typescript-declaration"].contains(winnerTypeID))
        } ?? false
        let specialConflict = conflictOnly && [
            "typescript", "typescript-declaration", "dotenv", "makefile", "dockerfile", "python", "yaml", "plist"
        ].contains(winnerTypeID)

        let evidence: [DetectionEvidence] = [
            Self.evidence(for: filenameWinner, signalKind: .filename, score: 1.0),
            Self.evidence(for: multiExtensionWinner, signalKind: .multiExtension, score: 0.98),
            Self.evidence(for: singleExtensionWinner, signalKind: .singleExtension, score: 0.95),
            Self.evidence(for: shebangWinner, signalKind: .shebang, score: 0.90),
            Self.evidence(
                signalKind: .yamlMapping,
                value: yamlMatch == nil ? "no-match" : "yaml-mapping",
                score: yamlMatch == nil ? 0 : 0.75
            ),
            Self.evidence(
                signalKind: .yamlDocumentMarker,
                value: yamlMatch?.marker == true ? "yaml-document-marker" : "no-match",
                score: yamlMatch?.marker == true ? 0.80 : 0
            ),
            Self.evidence(
                signalKind: .systemUTI,
                value: uti ?? "no-match",
                score: uti != nil && !conflictOnly ? 0.60 : 0
            )
        ] + ((winnerTypeID != "unknown" && (specialConflict || (uti != nil && !conflictOnly && !supportsWinner)))
            ? [Self.evidence(signalKind: .utiConflict, value: uti ?? "", score: 0)]
            : [])

        return ResolvedContentType(
            typeID: winnerTypeID,
            confidence: DetectionConfidence(trustedValue: confidenceValue),
            evidence: evidence,
            byteEvidence: [
                ByteDetectionEvidence(
                    signalKind: .magicSignature,
                    status: magicDetection.status,
                    value: magicDetection.value,
                    typeID: magicDetection.typeID,
                    encoding: nil,
                    score: DetectionConfidence(trustedValue: magicDetection.typeID == nil ? 0 : 0.85),
                    isWinningTypeEvidence: magicSelectedWinner
                ),
                ByteDetectionEvidence(
                    signalKind: .bom,
                    status: bomDetection.status,
                    value: bomDetection.encoding?.rawValue,
                    typeID: nil,
                    encoding: bomDetection.encoding,
                    score: DetectionConfidence(trustedValue: 0),
                    isWinningTypeEvidence: false
                )
            ]
        )
    }

    private static let maximumSampleBytes = 65_536
    private struct MagicDetection {
        let status: ByteDetectionEvidence.Status
        let typeID: String?
        let value: String?
    }

    private struct BOMDetection {
        let status: ByteDetectionEvidence.Status
        let encoding: TextEncoding?
    }

    /// Detects registered byte markers without treating an incomplete possible match as a miss.
    private static func detectMagicSignature(
        in sample: Data,
        definitions: [FileTypeDefinition],
        confirmedEOF: Bool
    ) -> MagicDetection {
        let candidates = definitions.flatMap { definition in
            definition.magicSignatures.map { (definition.typeID, $0) }
        }.sorted {
            if $0.0 != $1.0 { return typeIDPrecedes($0.0, $1.0) }
            return $0.1.rawValue < $1.1.rawValue
        }
        guard !candidates.isEmpty else {
            return MagicDetection(status: .unavailable, typeID: nil, value: nil)
        }

        var hasIncompleteCandidate = false
        for (typeID, signature) in candidates {
            let marker: [UInt8]
            let offset: Int
            let label: String
            switch signature {
            case .binaryPlist:
                marker = Array("bplist00".utf8)
                offset = 0
                label = "bplist00"
            case .sqlite:
                marker = Array("SQLite format 3\0".utf8)
                offset = 0
                label = "SQLite format 3"
            case .tarUStar:
                marker = Array("ustar".utf8)
                offset = 257
                label = "ustar"
            }

            if sample.count >= offset + marker.count {
                let actual = Array(sample.dropFirst(offset).prefix(marker.count))
                if actual == marker {
                    return MagicDetection(status: .matched, typeID: typeID, value: label)
                }
            } else if !confirmedEOF {
                if sample.count <= offset, offset == 0 {
                    hasIncompleteCandidate = true
                } else if sample.count > offset {
                    let actual = Array(sample.dropFirst(offset))
                    if Array(marker.prefix(actual.count)) == actual {
                        hasIncompleteCandidate = true
                    }
                }
            }
        }
        return MagicDetection(status: hasIncompleteCandidate ? .incomplete : .noMatch,
                              typeID: nil, value: nil)
    }

    /// Distinguishes a complete encoding marker from a clipped prefix that may still match one.
    private static func detectBOM(in sample: Data, confirmedEOF: Bool) -> BOMDetection {
        // Longest encodings are checked first because UTF-32LE shares UTF-16LE's initial two bytes.
        let bytes = Array(sample.prefix(4))
        let signatures: [([UInt8], TextEncoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8BOM),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian)
        ]

        for (signature, encoding) in signatures where bytes.count >= signature.count {
            if Array(bytes.prefix(signature.count)) == signature {
                if encoding == .utf16LittleEndian,
                   (bytes.count == 2 || bytes == [0xFF, 0xFE, 0x00]),
                   !confirmedEOF {
                    return BOMDetection(status: .incomplete, encoding: nil)
                }
                return BOMDetection(status: .matched, encoding: encoding)
            }
        }

        let isProperPrefix = !bytes.isEmpty && signatures.contains { entry in
            bytes.count < entry.0.count && Array(entry.0.prefix(bytes.count)) == bytes
        }
        if isProperPrefix, !confirmedEOF {
            return BOMDetection(status: .incomplete, encoding: nil)
        }
        return BOMDetection(status: .noMatch, encoding: nil)
    }

    private struct Candidate {
        let typeID: String
        let signalKind: DetectionEvidence.SignalKind
        let evidenceValue: String
        let matchedLiteral: String

        var classPriority: Int {
            // This ordering is intentional policy: explicit names/extensions outrank content guesses.
            switch signalKind {
            case .filename: 0
            case .multiExtension: 1
            case .singleExtension: 2
            case .shebang: 3
            case .yamlMapping, .yamlDocumentMarker: 4
            case .systemUTI, .utiConflict: 5
            }
        }
    }

    /// Applies detector-class precedence followed by bytewise tie-breaks independent of locale.
    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        // Stable tie-breaking keeps identical evidence deterministic across runs and registry ordering.
        if lhs.classPriority != rhs.classPriority {
            return lhs.classPriority < rhs.classPriority
        }

        let leftLiteralBytes = Array(lhs.matchedLiteral.utf8)
        let rightLiteralBytes = Array(rhs.matchedLiteral.utf8)
        if leftLiteralBytes.count != rightLiteralBytes.count {
            return leftLiteralBytes.count > rightLiteralBytes.count
        }

        let leftTypeIDBytes = Array(lhs.typeID.utf8)
        let rightTypeIDBytes = Array(rhs.typeID.utf8)
        if leftTypeIDBytes != rightTypeIDBytes {
            return leftTypeIDBytes.lexicographicallyPrecedes(rightTypeIDBytes)
        }

        if leftLiteralBytes != rightLiteralBytes {
            return leftLiteralBytes.lexicographicallyPrecedes(rightLiteralBytes)
        }

        return false
    }

    /// Selects the strongest candidate for one evidence class, independent of the final type winner.
    private static func bestCandidate(in candidates: [Candidate], for signalKind: DetectionEvidence.SignalKind) -> Candidate? {
        // Evidence reports the strongest match for each signal class independently of the final winner.
        candidates.filter { $0.signalKind == signalKind }.min(by: precedes)
    }

    /// Produces evidence for an optional match while retaining an explicit zero-score no-match row.
    private static func evidence(
        for candidate: Candidate?,
        signalKind: DetectionEvidence.SignalKind,
        score: Double
    ) -> DetectionEvidence {
        // Missing signals remain visible with a zero score rather than disappearing from diagnostics.
        evidence(
            signalKind: signalKind,
            value: candidate?.evidenceValue ?? "no-match",
            score: candidate == nil ? 0 : score
        )
    }

    /// Converts a numeric signal score through the validated confidence model.
    private static func evidence(
        signalKind: DetectionEvidence.SignalKind,
        value: String,
        score: Double
    ) -> DetectionEvidence {
        // All scores pass through the validating confidence type before becoming public evidence.
        DetectionEvidence(
            signalKind: signalKind,
            value: value,
            score: DetectionConfidence(trustedValue: score)
        )
    }

    /// Keeps numeric confidence only for established filename, extension and shebang signals.
    private static func score(for signalKind: DetectionEvidence.SignalKind) -> Double {
        switch signalKind {
        case .filename: 1.0
        case .multiExtension: 0.98
        case .singleExtension: 0.95
        case .shebang: 0.90
        case .yamlMapping, .yamlDocumentMarker, .systemUTI, .utiConflict: 0
        }
    }

    /// Accepts only known, stable UTIs so generic or dynamic metadata cannot dominate content evidence.
    private static func conclusiveUTI(_ identifier: String?, definitions: [FileTypeDefinition]) -> String? {
        // Generic, dynamic, and malformed UTIs are weak hints and must not override stronger evidence.
        guard let identifier, FileTypeRegistry.isRuntimeUTIIdentifierValid(identifier),
              identifier != "public.data", identifier != "public.content", identifier != "public.text",
              identifier != "public.plain-text", !identifier.hasPrefix("dyn.")
        else { return nil }
        if identifier == "public.mpeg-2-transport-stream" { return identifier }
        return definitions.contains(where: { $0.systemUTIIdentifiers.contains(identifier) }) ? identifier : nil
    }

    /// Orders equal-confidence type identifiers by UTF-8 bytes for reproducible results.
    private static func typeIDPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
    }

    private struct YAMLMatch {
        let marker: Bool
    }

    /// Performs a deliberately conservative leading-sample probe; YAMLInspector owns full syntax validation.
    private static func detectYAML(in sample: Data, sampleIsComplete: Bool) -> YAMLMatch? {
        // This cheap probe recognizes only conservative mapping/marker shapes; full parsing belongs to YAMLInspector.
        let byteLimit = 65_536
        let lineLimit = 256
        let maximumLineLength = 4_096
        let isClipped = sample.count > byteLimit
        let bytes = Array(sample.prefix(byteLimit))
        let confirmedEOF = sampleIsComplete && !isClipped
        var lineStart = 0
        var physicalLines = 0
        var mappingCount = 0
        var sawMarker = false
        var sawMeaningfulLine = false
        var sawMappingBeforeSequence = false

        while lineStart < bytes.count, physicalLines < lineLimit {
            var terminatorIndex = lineStart
            while terminatorIndex < bytes.count, bytes[terminatorIndex] != 0x0A, bytes[terminatorIndex] != 0x0D {
                terminatorIndex += 1
            }

            let isTerminated = terminatorIndex < bytes.count
            let lineEnd = terminatorIndex
            let isLastUnterminatedLine = !isTerminated && lineEnd == bytes.count
            if lineEnd - lineStart > maximumLineLength { break }
            if isLastUnterminatedLine && !confirmedEOF { break }

            var line = Array(bytes[lineStart..<lineEnd])
            if physicalLines == 0, line.starts(with: [0xEF, 0xBB, 0xBF]) {
                line.removeFirst(3)
            }
            guard isStrictUTF8(line), !containsRejectedControl(line) else { return nil }
            physicalLines += 1

            let indentation = line.prefix(while: { $0 == 0x20 }).count
            let content = Array(line.dropFirst(indentation))
            if content.isEmpty {
                // Spaces-only lines are blank.
            } else if content.first == 0x23 {
                // A comment begins at the first nonspace byte.
            } else if indentation == 0, isYAMLMarker(content) {
                guard !sawMeaningfulLine else { return nil }
                sawMarker = true
                sawMeaningfulLine = true
            } else if isYAMLSequence(content, indentation: indentation) {
                guard sawMappingBeforeSequence else { return nil }
                sawMeaningfulLine = true
            } else if isYAMLMapping(content) {
                mappingCount += 1
                sawMappingBeforeSequence = true
                sawMeaningfulLine = true
            } else {
                return nil
            }

            guard isTerminated else { break }
            if bytes[terminatorIndex] == 0x0D,
               terminatorIndex + 1 < bytes.count,
               bytes[terminatorIndex + 1] == 0x0A {
                lineStart = terminatorIndex + 2
            } else {
                lineStart = terminatorIndex + 1
            }
        }

        guard mappingCount >= 2 || (sawMarker && mappingCount >= 1) else { return nil }
        return YAMLMatch(marker: sawMarker)
    }

    /// Rejects lossy UTF-8 decoding during format detection to avoid false-positive text signatures.
    private static func isStrictUTF8(_ bytes: [UInt8]) -> Bool {
        // Content detection rejects lossy decoding so malformed bytes cannot create a YAML false positive.
        String(bytes: bytes, encoding: .utf8) != nil
    }

    /// Treats binary control bytes as disqualifying while allowing YAML's horizontal tab.
    private static func containsRejectedControl(_ bytes: [UInt8]) -> Bool {
        // Tabs are valid YAML indentation; other C0 controls and DEL are treated as binary noise.
        bytes.contains { byte in
            byte == 0x7F || (byte < 0x20 && byte != 0x09)
        }
    }

    /// Recognizes only a standalone YAML document marker with permitted trailing text.
    private static func isYAMLMarker(_ content: [UInt8]) -> Bool {
        // Accept only a standalone document-start marker, optionally followed by whitespace or a comment.
        guard content.starts(with: [0x2D, 0x2D, 0x2D]) else { return false }
        let remainder = content.dropFirst(3)
        guard remainder.isEmpty || remainder.first == 0x20 || remainder.first == 0x09 else { return false }
        let trailing = Array(remainder.drop(while: { $0 == 0x20 || $0 == 0x09 }))
        return trailing.isEmpty || trailing.first == 0x23
    }

    /// Counts a sequence as evidence only beneath an already observed mapping.
    private static func isYAMLSequence(_ content: [UInt8], indentation: Int) -> Bool {
        // A sequence contributes evidence only when indented beneath an earlier mapping.
        indentation > 0 && content.first == 0x2D && content.count > 1
            && (content[1] == 0x20 || content[1] == 0x09)
    }

    /// Recognizes the conservative ASCII key-and-colon subset used by the bounded YAML probe.
    private static func isYAMLMapping(_ content: [UInt8]) -> Bool {
        // Keep the probe narrow: keys use the supported ASCII subset and a colon must end the key.
        var keyEnd = 0
        while keyEnd < content.count, isYAMLKeyByte(content[keyEnd]) { keyEnd += 1 }
        guard keyEnd > 0, keyEnd < content.count, content[keyEnd] == 0x3A else { return false }
        let afterColon = keyEnd + 1
        return afterColon == content.count || content[afterColon] == 0x20 || content[afterColon] == 0x09
    }

    /// Defines the locale-independent ASCII alphabet accepted in a probe key.
    private static func isYAMLKeyByte(_ byte: UInt8) -> Bool {
        // A deliberately small byte-level key alphabet avoids locale-sensitive classification.
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2D
            || byte == 0x2E || byte == 0x2F
    }

    /// Lowercases ASCII identifier bytes without locale-dependent Unicode transformations.
    private static func asciiFold(_ value: String) -> String {
        // File type identifiers use ASCII case folding so matching is independent of user locale.
        let foldedBytes = value.utf8.map { byte in
            (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        }
        return String(decoding: foldedBytes, as: UTF8.self)
    }

    /// Prevents extension matching from treating a filename consisting only of the suffix as a match.
    private static func hasNonemptyPrefix(before suffix: String, in value: String) -> Bool {
        // Prevent a suffix rule from matching a filename that consists only of the extension.
        value != suffix && value.hasSuffix(suffix)
    }

    /// Returns only a complete first-line interpreter token from a bounded, UTF-8 shebang.
    private static func shebangInterpreter(in leadingBytes: Data, sampleIsComplete: Bool) -> String? {
        // Require a complete first line before inferring an interpreter from a clipped sample.
        let limit = 65_536
        let wasClipped = leadingBytes.count > limit
        let bytes = Array(leadingBytes.prefix(limit))
        let lineEnd: Int
        if let terminator = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lineEnd = terminator
        } else {
            guard sampleIsComplete, !wasClipped else { return nil }
            lineEnd = bytes.count
        }

        let rawLine = bytes[..<lineEnd]
        guard rawLine.starts(with: [0x23, 0x21]),
              let line = String(bytes: rawLine, encoding: .utf8)
        else {
            return nil
        }

        let lineBytes = Array(line.utf8)
        guard lineBytes.count >= 2, lineBytes[0] == 0x23, lineBytes[1] == 0x21 else {
            return nil
        }

        var tokenStart = 2
        while tokenStart < lineBytes.count, isShebangWhitespace(lineBytes[tokenStart]) {
            tokenStart += 1
        }
        let tokens = splitShebangTokens(lineBytes, startingAt: tokenStart)
        guard let command = tokens.first else { return nil }

        if command == "/usr/bin/env" {
            let arguments = tokens.dropFirst()
            let interpreter: String?
            if let first = arguments.first, first == "-S" {
                interpreter = arguments.dropFirst().first
            } else {
                interpreter = arguments.first
            }
            guard let interpreter, !interpreter.isEmpty else { return nil }
            return interpreter
        }

        guard command.hasPrefix("/"),
              let basename = command.split(separator: "/", omittingEmptySubsequences: false).last,
              !basename.isEmpty
        else {
            return nil
        }
        return String(basename)
    }

    /// Splits interpreter arguments on horizontal whitespace for classification only; it never invokes them.
    private static func splitShebangTokens(_ bytes: [UInt8], startingAt start: Int) -> [String] {
        // Tokenize only on shebang spaces and tabs; this is identification, never command execution.
        var tokens: [String] = []
        var index = start
        while index < bytes.count {
            while index < bytes.count, isShebangWhitespace(bytes[index]) {
                index += 1
            }
            guard index < bytes.count else { break }

            let tokenStart = index
            while index < bytes.count, !isShebangWhitespace(bytes[index]) {
                index += 1
            }
            let tokenBytes = bytes[tokenStart..<index]
            if let token = String(bytes: tokenBytes, encoding: .utf8) {
                tokens.append(token)
            }
        }
        return tokens
    }

    /// Defines the horizontal separators accepted when tokenizing a shebang interpreter line.
    private static func isShebangWhitespace(_ byte: UInt8) -> Bool {
        // POSIX shebang arguments are separated by horizontal ASCII whitespace here.
        byte == 0x20 || byte == 0x09
    }
}
