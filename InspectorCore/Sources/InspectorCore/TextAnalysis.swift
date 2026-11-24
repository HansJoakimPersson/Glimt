import Foundation

/// The encoding selected for a bounded text prefix.
public enum TextEncoding: String, Equatable, Hashable, Sendable {
    case utf8
    case utf8BOM
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case windows1252

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf32LittleEndian: "UTF-32 LE"
        case .utf32BigEndian: "UTF-32 BE"
        case .windows1252: "Windows-1252"
        }
    }
}

/// The line terminator kinds found in the decoded prefix.
public enum TextLineEnding: String, Equatable, Hashable, Sendable {
    case none
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case mixed
}

/// A bounded, pure analysis of the bytes already read for a preview.
public struct TextAnalysis: Equatable, Sendable {
    public let text: String
    public let encoding: TextEncoding?
    public let hasBOM: Bool
    public let lineEnding: TextLineEnding
    public let isBinary: Bool
    public let binaryProbability: Double
    public let fileSize: Int
    public let lineCount: Int
    public let lineCountIsLowerBound: Bool

    /// `truncated` means the analyzed prefix is shorter than the metadata file size.
    public var truncated: Bool { lineCountIsLowerBound }

    /// Analyzes at most `maximumBytes` (and never more than the 1 MiB preview ceiling).
    ///
    /// `fileSize` is exact metadata supplied by the caller. A malformed BOM-marked Unicode
    /// sequence is treated as binary; if the bounded prefix ends in an incomplete code unit or
    /// scalar, that incomplete tail is omitted. BOM-less UTF-16/32 is intentionally not inferred.
    /// For unmarked bytes, NUL is always binary and disallowed C0 controls are measured against
    /// the analyzed prefix byte count; `binaryProbability` reports that fraction, and strictly
    /// more than 10% is classified as binary.
    public static func analyze(bytes: Data, fileSize: Int, maximumBytes: Int) -> TextAnalysis {
        let exactFileSize = max(0, fileSize)
        let byteLimit = min(max(0, maximumBytes), previewByteLimit)
        let analyzedByteCount = min(bytes.count, byteLimit, exactFileSize)
        let prefix = Data(bytes.prefix(analyzedByteCount))
        let hasMoreFileBytes = analyzedByteCount < exactFileSize

        if let markedEncoding = bomEncoding(in: prefix) {
            let payload = Data(prefix.dropFirst(markedEncoding.bomLength))
            guard let decoded = decodeMarked(payload, encoding: markedEncoding.encoding, allowIncompleteTail: hasMoreFileBytes) else {
                return binaryResult(fileSize: exactFileSize, hasBOM: true, lowerBound: hasMoreFileBytes)
            }
            return textResult(
                decoded,
                encoding: markedEncoding.encoding,
                hasBOM: true,
                fileSize: exactFileSize,
                lowerBound: hasMoreFileBytes
            )
        }

        let binarySignal = binaryControlProbability(in: prefix)
        guard !binarySignal.isBinary else {
            return binaryResult(
                fileSize: exactFileSize,
                hasBOM: false,
                lowerBound: hasMoreFileBytes,
                binaryProbability: binarySignal.probability
            )
        }

        if let decoded = decodeUTF8(prefix, allowIncompleteTail: hasMoreFileBytes) {
            return textResult(
                decoded,
                encoding: .utf8,
                hasBOM: false,
                fileSize: exactFileSize,
                lowerBound: hasMoreFileBytes,
                binaryProbability: binarySignal.probability
            )
        }

        if let decoded = String(data: prefix, encoding: .windowsCP1252) {
            return textResult(
                decoded,
                encoding: .windows1252,
                hasBOM: false,
                fileSize: exactFileSize,
                lowerBound: hasMoreFileBytes,
                binaryProbability: binarySignal.probability
            )
        }

        return binaryResult(fileSize: exactFileSize, hasBOM: false, lowerBound: hasMoreFileBytes)
    }

    private static let previewByteLimit = 1_048_576

    /// Builds a text result and derives line metadata from the retained decoded prefix.
    private static func textResult(
        _ text: String,
        encoding: TextEncoding,
        hasBOM: Bool,
        fileSize: Int,
        lowerBound: Bool,
        binaryProbability: Double = 0
    ) -> TextAnalysis {
        // Derive line metadata from the retained decoded prefix; lowerBound carries truncation separately.
        let lineSummary = summarizeLines(in: text)
        return TextAnalysis(
            text: text,
            encoding: encoding,
            hasBOM: hasBOM,
            lineEnding: lineSummary.ending,
            isBinary: false,
            binaryProbability: binaryProbability,
            fileSize: fileSize,
            lineCount: lineSummary.count,
            lineCountIsLowerBound: lowerBound
        )
    }

    /// Builds a binary result with no decoded payload so renderers cannot expose mojibake.
    private static func binaryResult(
        fileSize: Int,
        hasBOM: Bool,
        lowerBound: Bool,
        binaryProbability: Double = 1
    ) -> TextAnalysis {
        // Binary results intentionally expose no decoded text, preventing renderers from showing mojibake.
        TextAnalysis(
            text: "",
            encoding: nil,
            hasBOM: hasBOM,
            lineEnding: .none,
            isBinary: true,
            binaryProbability: binaryProbability,
            fileSize: fileSize,
            lineCount: 0,
            lineCountIsLowerBound: lowerBound
        )
    }

    /// Detects BOMs longest-first so UTF-32 prefixes are not mistaken for UTF-16.
    private static func bomEncoding(in bytes: Data) -> (encoding: TextEncoding, bomLength: Int)? {
        // Check four-byte BOMs before their two-byte prefixes so UTF-32 is not misread as UTF-16.
        let values = Array(bytes.prefix(4))
        if values.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return (.utf32BigEndian, 4)
        }
        if values.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return (.utf32LittleEndian, 4)
        }
        if values.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (.utf8BOM, 3)
        }
        if values.starts(with: [0xFF, 0xFE]) {
            return (.utf16LittleEndian, 2)
        }
        if values.starts(with: [0xFE, 0xFF]) {
            return (.utf16BigEndian, 2)
        }
        return nil
    }

    /// Uses the BOM-selected decoder without falling through to a more permissive encoding.
    private static func decodeMarked(
        _ bytes: Data,
        encoding: TextEncoding,
        allowIncompleteTail: Bool
    ) -> String? {
        // A BOM is authoritative: malformed marked text does not fall through to a permissive encoding.
        switch encoding {
        case .utf8BOM:
            return decodeUTF8(bytes, allowIncompleteTail: allowIncompleteTail)
        case .utf16LittleEndian:
            return decodeUTF16(bytes, littleEndian: true, allowIncompleteTail: allowIncompleteTail)
        case .utf16BigEndian:
            return decodeUTF16(bytes, littleEndian: false, allowIncompleteTail: allowIncompleteTail)
        case .utf32LittleEndian:
            return decodeUTF32(bytes, littleEndian: true, allowIncompleteTail: allowIncompleteTail)
        case .utf32BigEndian:
            return decodeUTF32(bytes, littleEndian: false, allowIncompleteTail: allowIncompleteTail)
        case .utf8, .windows1252:
            return nil
        }
    }

    /// Validates UTF-8 scalar ranges and accepts a partial final scalar only for a known clipped prefix.
    private static func decodeUTF8(_ bytes: Data, allowIncompleteTail: Bool) -> String? {
        // Validate scalar ranges explicitly to reject overlong forms, surrogates, and out-of-range values.
        let values = Array(bytes)
        var scalars = String.UnicodeScalarView()
        var index = 0

        while index < values.count {
            let first = values[index]
            let length: Int
            let minimum: UInt32
            var scalarValue: UInt32

            switch first {
            case 0x00...0x7F:
                length = 1
                minimum = 0
                scalarValue = UInt32(first)
            case 0xC2...0xDF:
                length = 2
                minimum = 0x80
                scalarValue = UInt32(first & 0x1F)
            case 0xE0...0xEF:
                length = 3
                minimum = 0x800
                scalarValue = UInt32(first & 0x0F)
            case 0xF0...0xF4:
                length = 4
                minimum = 0x10000
                scalarValue = UInt32(first & 0x07)
            default:
                return nil
            }

            if index + length > values.count {
                guard allowIncompleteTail else { return nil }
                for continuationIndex in (index + 1)..<values.count {
                    guard (0x80...0xBF).contains(values[continuationIndex]) else { return nil }
                }
                return String(scalars)
            }

            if length > 1 {
                for continuationIndex in 1..<length {
                    let continuation = values[index + continuationIndex]
                    guard (0x80...0xBF).contains(continuation) else { return nil }
                    scalarValue = (scalarValue << 6) | UInt32(continuation & 0x3F)
                }
                guard scalarValue >= minimum,
                      scalarValue <= 0x10FFFF,
                      !(0xD800...0xDFFF).contains(scalarValue)
                else {
                    return nil
                }
            }

            guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
            scalars.append(scalar)
            index += length
        }

        return String(scalars)
    }

    /// Decodes endian-specific UTF-16 while rejecting unpaired surrogates and incomplete full files.
    private static func decodeUTF16(_ bytes: Data, littleEndian: Bool, allowIncompleteTail: Bool) -> String? {
        // Decode surrogate pairs as one scalar and omit only an incomplete terminal unit from a truncated prefix.
        let values = Array(bytes)
        let usableCount = values.count - (values.count % 2)
        if usableCount != values.count && !allowIncompleteTail { return nil }

        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < usableCount {
            let first = readUInt16(values, at: index, littleEndian: littleEndian)
            index += 2

            if (0xD800...0xDBFF).contains(first) {
                guard index < usableCount else {
                    return allowIncompleteTail ? String(scalars) : nil
                }
                let second = readUInt16(values, at: index, littleEndian: littleEndian)
                guard (0xDC00...0xDFFF).contains(second) else { return nil }
                index += 2
                let value = 0x10000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(second) - 0xDC00)
                guard let scalar = Unicode.Scalar(value) else { return nil }
                scalars.append(scalar)
            } else {
                guard !(0xDC00...0xDFFF).contains(first), let scalar = Unicode.Scalar(first) else { return nil }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Decodes endian-specific UTF-32 and rejects values outside Unicode's scalar range.
    private static func decodeUTF32(_ bytes: Data, littleEndian: Bool, allowIncompleteTail: Bool) -> String? {
        // Reject invalid Unicode scalars; only a known truncated prefix may end in a partial code unit.
        let values = Array(bytes)
        let usableCount = values.count - (values.count % 4)
        if usableCount != values.count && !allowIncompleteTail { return nil }

        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < usableCount {
            let value = readUInt32(values, at: index, littleEndian: littleEndian)
            guard let scalar = Unicode.Scalar(value) else { return nil }
            scalars.append(scalar)
            index += 4
        }
        return String(scalars)
    }

    /// Reads one already-bounds-checked UTF-16 code unit in the requested byte order.
    private static func readUInt16(_ bytes: [UInt8], at index: Int, littleEndian: Bool) -> UInt16 {
        // Callers validate the full code-unit width before reading; this helper only applies byte order.
        let first = UInt16(bytes[index])
        let second = UInt16(bytes[index + 1])
        return littleEndian ? first | (second << 8) : (first << 8) | second
    }

    /// Reads one already-bounds-checked UTF-32 code unit in the requested byte order.
    private static func readUInt32(_ bytes: [UInt8], at index: Int, littleEndian: Bool) -> UInt32 {
        // Keep scalar assembly explicit so Unicode validity checks happen before scalar creation.
        let first = UInt32(bytes[index])
        let second = UInt32(bytes[index + 1])
        let third = UInt32(bytes[index + 2])
        let fourth = UInt32(bytes[index + 3])
        if littleEndian {
            return first | (second << 8) | (third << 16) | (fourth << 24)
        }
        return (first << 24) | (second << 16) | (third << 8) | fourth
    }

    /// Estimates binary likelihood from NUL and disallowed control bytes in the bounded sample.
    private static func binaryControlProbability(in bytes: Data) -> (isBinary: Bool, probability: Double) {
        // NUL is handled as a definite binary signal; this ratio covers the remaining disallowed C0 controls.
        var disallowedControlCount = 0
        for byte in bytes {
            if byte == 0 { return (true, 1) }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0C && byte != 0x0D {
                disallowedControlCount += 1
            }
        }
        guard !bytes.isEmpty else { return (false, 0) }
        let probability = Double(disallowedControlCount) / Double(bytes.count)
        return (probability > 0.1, probability)
    }

    /// Counts physical lines and records the observed terminator style without inventing a final line.
    private static func summarizeLines(in text: String) -> (ending: TextLineEnding, count: Int) {
        // Treat CRLF as one terminator and avoid counting a trailing line break as an extra empty line.
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return (.none, 0) }

        var endings = Set<TextLineEnding>()
        var lineCount = 1
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\r" {
                if index + 1 < scalars.count && scalars[index + 1] == "\n" {
                    endings.insert(.crlf)
                    if index + 2 < scalars.count { lineCount += 1 }
                    index += 2
                    continue
                }
                endings.insert(.cr)
                if index + 1 < scalars.count { lineCount += 1 }
            } else if scalars[index] == "\n" {
                endings.insert(.lf)
                if index + 1 < scalars.count { lineCount += 1 }
            }
            index += 1
        }

        guard !endings.isEmpty else { return (.none, lineCount) }
        if endings.count == 1, let ending = endings.first {
            return (ending, lineCount)
        }
        return (.mixed, lineCount)
    }
}
