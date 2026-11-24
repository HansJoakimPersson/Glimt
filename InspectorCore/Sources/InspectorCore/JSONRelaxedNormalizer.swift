import Foundation

/// Converts the bounded comment/trailing-comma subset shared by JSONC and JSON5 into strict JSON.
/// JSON5 additionally accepts single-quoted strings and unquoted object keys. Original bytes are
/// kept separately by `JSONInspector`; this transformation is only used for semantic inspection.
enum JSONRelaxedNormalizer {
    static func normalize(_ bytes: [UInt8], json5: Bool) throws -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false

        while index < bytes.count {
            if index & 0xFF == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            if inString {
                output.append(byte)
                index += 1
                if byte == 0x5C, index < bytes.count {
                    output.append(bytes[index])
                    index += 1
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            if byte == 0x22 {
                inString = true
                output.append(byte)
                index += 1
                continue
            }

            if json5, byte == 0x27 {
                guard let end = try appendSingleQuotedString(bytes, from: index, to: &output) else { return nil }
                index = end
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                index += 2
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    output.append(0x20)
                    index += 1
                }
                continue
            }

            if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                var closed = false
                while index + 1 < bytes.count {
                    if bytes[index] == 0x2A, bytes[index + 1] == 0x2F {
                        index += 2
                        closed = true
                        break
                    }
                    output.append(bytes[index] == 0x0A || bytes[index] == 0x0D ? bytes[index] : 0x20)
                    index += 1
                }
                guard closed else { return nil }
                continue
            }

            if json5, isIdentifierStart(byte) {
                let start = index
                index += 1
                while index < bytes.count, isIdentifierContinuation(bytes[index]) { index += 1 }
                var lookahead = index
                while lookahead < bytes.count, isJSONWhitespace(bytes[lookahead]) { lookahead += 1 }
                if lookahead < bytes.count, bytes[lookahead] == 0x3A {
                    output.append(0x22)
                    output.append(contentsOf: bytes[start..<index])
                    output.append(0x22)
                } else {
                    output.append(contentsOf: bytes[start..<index])
                }
                continue
            }

            if byte == 0x2C {
                var lookahead = index + 1
                while lookahead < bytes.count, isJSONWhitespace(bytes[lookahead]) { lookahead += 1 }
                if lookahead < bytes.count, bytes[lookahead] == 0x7D || bytes[lookahead] == 0x5D {
                    index += 1
                    continue
                }
            }

            output.append(byte)
            index += 1
        }

        return output
    }

    private static func appendSingleQuotedString(_ bytes: [UInt8], from start: Int,
                                                 to output: inout [UInt8]) throws -> Int? {
        output.append(0x22)
        var index = start + 1
        while index < bytes.count {
            if (index - start) & 0xFF == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            if byte == 0x27 {
                output.append(0x22)
                return index + 1
            }
            if byte == 0x0A || byte == 0x0D { return nil }
            if byte == 0x5C {
                guard index + 1 < bytes.count else { return nil }
                let escaped = bytes[index + 1]
                if escaped == 0x27 {
                    output.append(0x27)
                } else {
                    if escaped == 0x22 { output.append(0x5C) }
                    output.append(escaped)
                }
                index += 2
                continue
            }
            if byte == 0x22 { output.append(0x5C) }
            output.append(byte)
            index += 1
        }
        return nil
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool { [0x09, 0x0A, 0x0D, 0x20].contains(byte) }
    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F || byte == 0x24
    }
    private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (0x30...0x39).contains(byte)
    }
}
