import CZlib
import CZlibRuntime
import Foundation

/// Kind of inert TAR inventory entry.
public enum TARArchiveEntryKind: String, Equatable, Sendable {
    case file, directory, symbolicLink, hardLink

    public var displayName: String {
        switch self {
        case .file: "File"
        case .directory: "Directory"
        case .symbolicLink: "Symbolic link"
        case .hardLink: "Hard link"
        }
    }
}

/// One entry header projected from a TAR archive. Member contents are never read or extracted.
public struct TARArchiveEntry: Equatable, Sendable {
    public let displayName: String
    public let kind: TARArchiveEntryKind
    public let size: UInt64
    public let linkTarget: String?

    init(displayName: String, kind: TARArchiveEntryKind, size: UInt64, linkTarget: String?) {
        self.displayName = displayName
        self.kind = kind
        self.size = size
        self.linkTarget = linkTarget
    }
}

/// Complete ordered TAR inventory; malformed archives never expose partial entries.
public struct TARArchiveListing: Equatable, Sendable {
    public let entries: [TARArchiveEntry]
    public let isGzipped: Bool

    init(entries: [TARArchiveEntry], isGzipped: Bool) {
        self.entries = entries
        self.isGzipped = isGzipped
    }
}

/// Bounded failures from TAR inspection.
enum TARArchiveError: Error, Equatable {
    case invalidFileSize
    case incompleteInput
    case malformed
    case unsupported
    case compressionUnavailable(Int32)
    case limitExceeded
    case cancelled
}

/// Bounded POSIX ustar and gzip-wrapped ustar metadata inspection.
public enum TARArchiveInspector {
    private static let blockSize = 512
    private static let maximumCompressedBytes = 16 * 1_048_576
    private static let maximumExpandedBytes = 64 * 1_048_576
    fileprivate static let maximumEntries = 2_048
    fileprivate static let maximumNameBytes = 1_024
    fileprivate static let maximumTotalNameBytes = 524_288

    /// Inspects a complete buffer; file-backed previews should use `fileAt` to keep large payloads mapped.
    public static func inspect(data: Data, fileSize: Int,
                               isCancelled: @escaping () -> Bool = { false }) throws -> TARArchiveListing {
        guard fileSize >= 0 else { throw TARArchiveError.invalidFileSize }
        guard data.count == fileSize else { throw TARArchiveError.incompleteInput }
        try checkpoint(isCancelled: isCancelled)
        let expanded: Data
        let isGzipped = data.starts(with: [0x1F, 0x8B])
        if isGzipped {
            guard data.count <= maximumCompressedBytes else { throw TARArchiveError.limitExceeded }
            expanded = try gunzip(data, isCancelled: isCancelled)
        } else {
            expanded = data
        }
        let entries = try TARParser(data: expanded, isCancelled: isCancelled).inspect()
        return .init(entries: entries, isGzipped: isGzipped)
    }

    /// Maps a local archive and reads only TAR headers. Gzip streams remain subject to a compressed-input ceiling.
    static func inspect(fileAt url: URL, fileSize: Int,
                        isCancelled: @escaping () -> Bool = { false }) throws -> TARArchiveListing {
        guard fileSize >= 0 else { throw TARArchiveError.invalidFileSize }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == fileSize else { throw TARArchiveError.incompleteInput }
        let mapped: Data
        do { mapped = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw TARArchiveError.incompleteInput }
        return try inspect(data: mapped, fileSize: fileSize, isCancelled: isCancelled)
    }

    private static func gunzip(_ compressed: Data, isCancelled: @escaping () -> Bool) throws -> Data {
        var stream = z_stream()
        let initResult = glimtInflateGzipInit(&stream)
        guard initResult == Z_OK else { throw TARArchiveError.compressionUnavailable(initResult) }
        defer { glimtInflateFinish(&stream) }

        var output = Data()
        var state: Int32 = Z_OK
        try compressed.withUnsafeBytes { rawInput in
            guard let base = rawInput.bindMemory(to: Bytef.self).baseAddress else { throw TARArchiveError.malformed }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(compressed.count)
            while state == Z_OK {
                try checkpoint(isCancelled: isCancelled)
                var chunk = [UInt8](repeating: 0, count: 32_768)
                let chunkCapacity = chunk.count
                let produced: Int = chunk.withUnsafeMutableBytes { rawOutput in
                    stream.next_out = rawOutput.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkCapacity)
                    state = glimtInflateStream(&stream, Z_NO_FLUSH)
                    return chunkCapacity - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: chunk.prefix(produced)) }
                guard output.count <= maximumExpandedBytes,
                      output.count <= max(1, compressed.count) * 1_000 else { throw TARArchiveError.limitExceeded }
                if state != Z_OK, state != Z_STREAM_END { throw TARArchiveError.malformed }
            }
        }
        guard state == Z_STREAM_END, stream.avail_in == 0 else { throw TARArchiveError.malformed }
        return output
    }

    fileprivate static func checkpoint(isCancelled: () -> Bool) throws {
        if Task.isCancelled || isCancelled() { throw TARArchiveError.cancelled }
    }
}

private struct TARParser {
    private let data: Data
    private let isCancelled: () -> Bool

    init(data: Data, isCancelled: @escaping () -> Bool) {
        self.data = data
        self.isCancelled = isCancelled
    }

    func inspect() throws -> [TARArchiveEntry] {
        guard data.count >= 1_024 else { throw TARArchiveError.incompleteInput }
        var cursor = 0
        var entries: [TARArchiveEntry] = []
        var totalNameBytes = 0
        var sawEnd = false
        while cursor <= data.count - 512 {
            try TARArchiveInspector.checkpoint(isCancelled: isCancelled)
            let header = bytes(at: cursor, count: 512)
            if header.allSatisfy({ $0 == 0 }) {
                guard cursor <= data.count - 1_024,
                      bytes(at: cursor + 512, count: 512).allSatisfy({ $0 == 0 }) else {
                    throw TARArchiveError.incompleteInput
                }
                let tailStart = cursor + 1_024
                guard data[data.index(data.startIndex, offsetBy: tailStart)...].allSatisfy({ $0 == 0 }) else {
                    throw TARArchiveError.malformed
                }
                sawEnd = true
                break
            }

            try validateHeader(header)
            let name = field(header, range: 0..<100)
            let prefix = field(header, range: 345..<500)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard !name.isEmpty, path.utf8.count <= TARArchiveInspector.maximumNameBytes else { throw TARArchiveError.limitExceeded }
            totalNameBytes += path.utf8.count
            guard totalNameBytes <= TARArchiveInspector.maximumTotalNameBytes,
                  entries.count < TARArchiveInspector.maximumEntries else { throw TARArchiveError.limitExceeded }
            let size = try octal(header, range: 124..<136)
            let linkName = field(header, range: 157..<257)
            let type = header[156]
            let kind: TARArchiveEntryKind
            switch type {
            case 0, 48, 55: kind = .file
            case 53: kind = .directory
            case 50: kind = .symbolicLink
            case 49: kind = .hardLink
            case 120, 103, 76, 75: throw TARArchiveError.unsupported // PAX and GNU long-name records.
            default: throw TARArchiveError.unsupported
            }
            if kind == .directory, size != 0 { throw TARArchiveError.malformed }
            let linkTarget = kind == .symbolicLink || kind == .hardLink ? linkName : nil
            entries.append(.init(displayName: path, kind: kind, size: size, linkTarget: linkTarget))

            let (rounded, overflow) = size.addingReportingOverflow(511)
            guard !overflow, rounded <= UInt64(Int.max) else { throw TARArchiveError.limitExceeded }
            let payloadBlocks = Int(rounded / 512)
            let (blockCount, blockOverflow) = payloadBlocks.addingReportingOverflow(1)
            let (nextOffset, offsetOverflow) = blockCount.multipliedReportingOverflow(by: 512)
            guard !blockOverflow, !offsetOverflow, nextOffset <= data.count - cursor else {
                throw TARArchiveError.incompleteInput
            }
            cursor += nextOffset
        }
        guard sawEnd else { throw TARArchiveError.incompleteInput }
        return entries
    }

    private func validateHeader(_ header: [UInt8]) throws {
        guard Array(header[257..<263]) == Array("ustar\0".utf8),
              Array(header[263..<265]) == [0x30, 0x30] else { throw TARArchiveError.unsupported }
        let declared = try octal(header, range: 148..<156)
        var checksum: UInt64 = 0
        for index in header.indices {
            checksum += (148..<156).contains(index) ? 32 : UInt64(header[index])
        }
        guard declared == checksum else { throw TARArchiveError.malformed }
    }

    private func bytes(at offset: Int, count: Int) -> [UInt8] {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        return Array(data[start..<end])
    }

    private func field(_ header: [UInt8], range: Range<Int>) -> String {
        let bytes = Array(header[range].prefix { $0 != 0 })
        return Self.display(bytes)
    }

    private static func display(_ bytes: [UInt8]) -> String {
        guard let decoded = String(bytes: bytes, encoding: .utf8) else {
            return bytes.map { byte in
                if (0x20...0x7E).contains(byte), byte != 0x5C { return String(UnicodeScalar(byte)) }
                return String(format: "\\x%02X", byte)
            }.joined()
        }
        return decoded.unicodeScalars.map { scalar in
            if scalar.value == 0x5C { return "\\\\" }
            if CharacterSet.controlCharacters.contains(scalar)
                || [0x202A...0x202E, 0x2066...0x2069].contains(where: { $0.contains(scalar.value) }) {
                return String(format: "\\u{%X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }

    private func octal(_ bytes: [UInt8], range: Range<Int>) throws -> UInt64 {
        var result: UInt64 = 0
        var sawDigit = false
        for byte in bytes[range] {
            if byte == 0 || byte == 32 {
                if sawDigit { break }
                continue
            }
            guard (48...55).contains(byte) else { throw TARArchiveError.unsupported }
            sawDigit = true
            let (timesEight, multiplyOverflow) = result.multipliedReportingOverflow(by: 8)
            let (next, addOverflow) = timesEight.addingReportingOverflow(UInt64(byte - 48))
            guard !multiplyOverflow, !addOverflow else { throw TARArchiveError.limitExceeded }
            result = next
        }
        return result
    }
}
