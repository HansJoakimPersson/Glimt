import Foundation

/// Compression methods admitted by the bounded classic ZIP metadata inspector.
public enum ZIPCompressionMethod: UInt16, Equatable, Sendable {
    case stored = 0
    case deflate = 8
}

/// One inert entry row projected from a classic ZIP central directory.
public struct ZIPArchiveEntry: Equatable, Sendable {
    public let displayName: String
    public let isDirectory: Bool
    public let method: ZIPCompressionMethod
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64

    init(displayName: String, isDirectory: Bool, method: ZIPCompressionMethod,
         compressedSize: UInt64, uncompressedSize: UInt64) {
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.method = method
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
    }
}

/// A complete, ordered listing. A rejected archive never produces a partial listing.
public struct ZIPArchiveListing: Equatable, Sendable {
    public let entries: [ZIPArchiveEntry]

    init(entries: [ZIPArchiveEntry]) {
        self.entries = entries
    }
}

/// Typed failures from bounded ZIP metadata inspection.
public enum ZIPArchiveError: Error, Equatable, Sendable {
    case invalidFileSize
    case incompleteInput
    case malformed
    case unsupported
    case limitExceeded(ZIPArchiveLimit)
    case cancelled
}

/// Fixed safety ceilings for the classic ZIP metadata parser.
public enum ZIPArchiveLimit: Equatable, Sendable {
    case inputBytes
    case entryCount
    case encodedNameBytes
    case escapedNameBytes
    case entryUncompressedBytes
    case totalUncompressedBytes
    case entryExpansionRatio
    case totalExpansionRatio
}

/// Inspects complete, bounded classic ZIP buffers without opening or decoding members.
public enum ZIPArchiveInspector {
    /// Returns ordered central-directory metadata or one typed failure. The caller retains the original bytes.
    public static func inspect(data: Data, fileSize: Int,
                                isCancelled: @escaping () -> Bool = { false }) throws(ZIPArchiveError) -> ZIPArchiveListing {
        var parser = ZIPArchiveParser(bytes: ZIPByteSource(buffer: data), fileSize: fileSize,
                                      isCancelled: isCancelled)
        return try parser.inspect()
    }

    /// Reads only the end record, central directory, and local headers of a file larger than the retained
    /// prefix. `fileSize` is the size observed by the prefix read; a different size means the file changed.
    static func inspect(fileAt url: URL, fileSize: Int,
                        isCancelled: @escaping () -> Bool = { false }) throws(ZIPArchiveError) -> ZIPArchiveListing {
        let file: BoundedFileReader.RandomAccessFile
        do { file = try BoundedFileReader.RandomAccessFile(url: url) } catch { throw .incompleteInput }
        var parser = ZIPArchiveParser(bytes: ZIPByteSource(file: file), fileSize: fileSize,
                                      isCancelled: isCancelled)
        return try parser.inspect()
    }
}

/// Archive bytes read on demand: a complete buffer, or cached file pages so payloads are never read.
private final class ZIPByteSource {
    private static let pageSize = 4_096
    /// Bounds the metadata read from a file: end-record search, central directory, and local headers.
    private static let maximumFetchedBytes = 8 * 1_048_576

    let count: Int
    private let buffer: Data?
    private let file: BoundedFileReader.RandomAccessFile?
    private var pages: [Int: [UInt8]] = [:]
    private var currentPageIndex = -1
    private var currentPage: [UInt8] = []
    private var fetchedBytes = 0

    init(buffer: Data) {
        count = buffer.count
        self.buffer = buffer
        file = nil
    }

    init(file: BoundedFileReader.RandomAccessFile) {
        count = file.fileSize
        buffer = nil
        self.file = file
    }

    /// Callers check `offset` against `count` first.
    func byte(at offset: Int) throws(ZIPArchiveError) -> UInt8 {
        if let buffer { return buffer[buffer.index(buffer.startIndex, offsetBy: offset)] }
        let pageIndex = offset / Self.pageSize
        if pageIndex != currentPageIndex {
            currentPage = try page(pageIndex)
            currentPageIndex = pageIndex
        }
        return currentPage[offset - pageIndex * Self.pageSize]
    }

    private func page(_ index: Int) throws(ZIPArchiveError) -> [UInt8] {
        if let cached = pages[index] { return cached }
        guard let file else { throw .malformed }
        let start = index * Self.pageSize
        let range = start..<min(count, start + Self.pageSize)
        fetchedBytes += range.count
        guard fetchedBytes <= Self.maximumFetchedBytes else { throw .limitExceeded(.inputBytes) }
        let bytes: [UInt8]
        do { bytes = try file.read(range) } catch { throw .incompleteInput }
        pages[index] = bytes
        return bytes
    }
}

struct ZIPArchiveBudget: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let compressedTotal: UInt64
        let uncompressedTotal: UInt64
        let escapedNameUTF8Total: UInt64
        let entryCount: UInt64
    }

    private(set) var compressedTotal: UInt64
    private(set) var uncompressedTotal: UInt64
    private(set) var escapedNameUTF8Total: UInt64
    private(set) var entryCount: UInt64

    var snapshot: Snapshot {
        .init(compressedTotal: compressedTotal, uncompressedTotal: uncompressedTotal,
              escapedNameUTF8Total: escapedNameUTF8Total, entryCount: entryCount)
    }

    init(compressedTotal: UInt64 = 0, uncompressedTotal: UInt64 = 0,
         escapedNameUTF8Total: UInt64 = 0, entryCount: UInt64 = 0) {
        self.compressedTotal = compressedTotal
        self.uncompressedTotal = uncompressedTotal
        self.escapedNameUTF8Total = escapedNameUTF8Total
        self.entryCount = entryCount
    }

    mutating func add(compressed: UInt64, uncompressed: UInt64, escapedNameUTF8: UInt64) throws(ZIPArchiveError) {
        var next = self
        guard next.entryCount < 512 else { throw .limitExceeded(.entryCount) }
        guard uncompressed <= 1_073_741_824 else { throw .limitExceeded(.entryUncompressedBytes) }

        let (newUncompressed, uncompressedOverflow) = next.uncompressedTotal.addingReportingOverflow(uncompressed)
        guard !uncompressedOverflow, newUncompressed <= 4_294_967_296 else {
            throw .limitExceeded(.totalUncompressedBytes)
        }
        guard Self.ratioIsWithinLimit(uncompressed: uncompressed, compressed: compressed) else {
            throw .limitExceeded(.entryExpansionRatio)
        }

        let (newCompressed, compressedOverflow) = next.compressedTotal.addingReportingOverflow(compressed)
        guard !compressedOverflow else { throw .limitExceeded(.totalExpansionRatio) }
        let (newEscaped, escapedOverflow) = next.escapedNameUTF8Total.addingReportingOverflow(escapedNameUTF8)
        guard !escapedOverflow, newEscaped <= 262_144 else { throw .limitExceeded(.escapedNameBytes) }
        let (newCount, countOverflow) = next.entryCount.addingReportingOverflow(1)
        guard !countOverflow, newCount <= 512 else { throw .limitExceeded(.entryCount) }

        next.compressedTotal = newCompressed
        next.uncompressedTotal = newUncompressed
        next.escapedNameUTF8Total = newEscaped
        next.entryCount = newCount
        self = next
    }

    func checkTotalExpansionRatio() throws(ZIPArchiveError) {
        guard Self.ratioIsWithinLimit(uncompressed: uncompressedTotal, compressed: compressedTotal) else {
            throw .limitExceeded(.totalExpansionRatio)
        }
    }

    private static func ratioIsWithinLimit(uncompressed: UInt64, compressed: UInt64) -> Bool {
        if compressed == 0 { return uncompressed == 0 }
        let quotient = uncompressed / compressed
        let remainder = uncompressed % compressed
        return quotient < 1_000 || (quotient == 1_000 && remainder == 0)
    }
}

private struct ZIPArchiveParser {
    private static let maximumCentralDirectoryBytes = 1_048_576
    private static let maximumEntryCount = 512
    private static let maximumNameBytes = 1_024
    private static let maximumEOCDSearchBytes = 65_557
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let zip64EOCDSignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let dataDescriptorSignature: UInt32 = 0x0807_4B50
    private static let zip64ExtraID: UInt16 = 0x0001
    private static let hexadecimalDigits = Array("0123456789ABCDEF".utf8)

    private struct CentralEntry {
        let name: [UInt8]
        let flags: UInt16
        let method: ZIPCompressionMethod
        let versionNeeded: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: Int
        let isDirectory: Bool
    }

    private let bytes: ZIPByteSource
    private let fileSize: Int
    private let isCancelled: () -> Bool
    private var cancellationObserved = false

    init(bytes: ZIPByteSource, fileSize: Int, isCancelled: @escaping () -> Bool) {
        self.bytes = bytes
        self.fileSize = fileSize
        self.isCancelled = isCancelled
    }

    mutating func inspect() throws(ZIPArchiveError) -> ZIPArchiveListing {
        try checkpoint()
        guard fileSize >= 0, bytes.count <= fileSize else { throw .invalidFileSize }
        guard bytes.count == fileSize else { throw .incompleteInput }
        guard bytes.count > 0 else { throw .malformed }

        let eocdOffset = try findEOCD()
        let eocd = try parseEOCD(at: eocdOffset)
        let entries = try parseCentralDirectory(eocd)
        try validateLocalSpans(entries, centralOffset: eocd.centralOffset)
        let listing = try project(entries)
        try budget.checkTotalExpansionRatio()
        try checkpoint()
        return listing
    }

    private mutating func checkpoint() throws(ZIPArchiveError) {
        if Task.isCancelled || isCancelled() { cancellationObserved = true }
        if cancellationObserved { throw .cancelled }
    }

    private mutating func findEOCD() throws(ZIPArchiveError) -> Int {
        let start = max(0, bytes.count - Self.maximumEOCDSearchBytes)
        var candidates: [Int] = []
        if bytes.count >= 22 {
            for offset in start...(bytes.count - 22) {
                if (offset - start) & 0x3F == 0 { try checkpoint() }
                // Reject on the first signature byte so the scan costs one read per offset.
                guard try bytes.byte(at: offset) == 0x50,
                      try read32IfAvailable(at: offset) == Self.eocdSignature else { continue }
                let commentLength = Int(try read16(at: offset + 20))
                let (end, overflow) = offset.addingReportingOverflow(22 + commentLength)
                if !overflow, end == bytes.count { candidates.append(offset) }
            }
        }
        try checkpoint()
        guard candidates.count == 1, let candidate = candidates.first else { throw .malformed }
        return candidate
    }

    private struct EOCD {
        let offset: Int
        let disk: UInt16
        let centralDisk: UInt16
        let entriesOnDisk: UInt16
        let entryCount: UInt16
        let centralSize: UInt32
        let centralOffset: UInt32
    }

    private mutating func parseEOCD(at offset: Int) throws(ZIPArchiveError) -> EOCD {
        let disk = try read16(at: offset + 4)
        let centralDisk = try read16(at: offset + 6)
        let entriesOnDisk = try read16(at: offset + 8)
        let entryCount = try read16(at: offset + 10)
        let centralSize = try read32(at: offset + 12)
        let centralOffset = try read32(at: offset + 16)

        if try hasAnchoredZIP64Locator(before: offset) { throw .unsupported }
        if entriesOnDisk == UInt16.max || entryCount == UInt16.max || centralSize == UInt32.max || centralOffset == UInt32.max {
            throw .unsupported
        }
        guard disk == 0, centralDisk == 0, entriesOnDisk == entryCount else { throw .unsupported }

        let start = Int(centralOffset)
        let length = Int(centralSize)
        let (end, overflow) = start.addingReportingOverflow(length)
        guard !overflow, end == offset else { throw .malformed }
        guard length <= Self.maximumCentralDirectoryBytes else { throw .limitExceeded(.inputBytes) }
        if entryCount == 0 {
            guard centralSize == 0, centralOffset == 0, offset == 0 else { throw .malformed }
        } else {
            guard centralSize > 0 else { throw .malformed }
        }
        guard Int(entryCount) <= Self.maximumEntryCount else { throw .limitExceeded(.entryCount) }
        return EOCD(offset: offset, disk: disk, centralDisk: centralDisk,
                    entriesOnDisk: entriesOnDisk, entryCount: entryCount,
                    centralSize: centralSize, centralOffset: centralOffset)
    }

    private func hasAnchoredZIP64Locator(before eocdOffset: Int) throws(ZIPArchiveError) -> Bool {
        guard eocdOffset >= 20,
              try read32IfAvailable(at: eocdOffset - 20) == Self.zip64LocatorSignature else { return false }
        let locatorOffset = eocdOffset - 20
        guard let recordOffsetField = try read64IfAvailable(at: locatorOffset + 8),
              let recordOffset = Int(exactly: recordOffsetField), recordOffset >= 0,
              let signature = try read32IfAvailable(at: recordOffset), signature == Self.zip64EOCDSignature,
              let recordSize = try read64IfAvailable(at: recordOffset + 4), recordSize >= 44,
              let sizeAsInt = Int(exactly: recordSize), sizeAsInt <= Int.max - 12 else { return false }
        let (recordEnd, overflow) = recordOffset.addingReportingOverflow(12 + sizeAsInt)
        guard !overflow, recordEnd == locatorOffset else { return false }
        return true
    }

    private mutating func parseCentralDirectory(_ eocd: EOCD) throws(ZIPArchiveError) -> [CentralEntry] {
        let directoryStart = Int(eocd.centralOffset)
        let directoryEnd = eocd.offset
        var cursor = directoryStart
        var entries: [CentralEntry] = []
        entries.reserveCapacity(Int(eocd.entryCount))

        for _ in 0..<Int(eocd.entryCount) {
            try checkpoint()
            guard cursor <= directoryEnd, directoryEnd - cursor >= 46,
                  try read32(at: cursor) == Self.centralHeaderSignature else { throw .malformed }
            let versionNeeded = try read16(at: cursor + 6)
            let flags = try read16(at: cursor + 8)
            let methodCode = try read16(at: cursor + 10)
            let crc = try read32(at: cursor + 16)
            let compressedSize = try read32(at: cursor + 20)
            let uncompressedSize = try read32(at: cursor + 24)
            let nameLength = Int(try read16(at: cursor + 28))
            let extraLength = Int(try read16(at: cursor + 30))
            let commentLength = Int(try read16(at: cursor + 32))
            let diskStart = try read16(at: cursor + 34)
            let localOffsetField = try read32(at: cursor + 42)

            let variableLength = nameLength.addingReportingOverflow(extraLength)
            guard !variableLength.overflow else { throw .malformed }
            let withComment = variableLength.partialValue.addingReportingOverflow(commentLength)
            guard !withComment.overflow else { throw .malformed }
            let recordLength = 46.addingReportingOverflow(withComment.partialValue)
            guard !recordLength.overflow, recordLength.partialValue <= directoryEnd - cursor else { throw .malformed }
            let recordEnd = cursor + recordLength.partialValue
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let commentStart = extraStart + extraLength

            try validateExtras(at: extraStart, length: extraLength)
            guard nameLength <= Self.maximumNameBytes else { throw .limitExceeded(.encodedNameBytes) }
            guard nameLength > 0 else { throw .malformed }
            if compressedSize == UInt32.max || uncompressedSize == UInt32.max || localOffsetField == UInt32.max || diskStart == UInt16.max {
                throw .unsupported
            }
            guard diskStart == 0 else { throw .unsupported }
            guard let method = validateMethodAndFlags(methodCode, flags: flags) else {
                throw .unsupported
            }
            try validateRequiredVersion(versionNeeded, method: method, flags: flags)
            guard commentStart + commentLength == recordEnd else { throw .malformed }
            let name = try copyBytes(in: nameStart..<extraStart)
            entries.append(CentralEntry(name: name, flags: flags, method: method,
                                        versionNeeded: versionNeeded, crc: crc,
                                        compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                                        localOffset: Int(localOffsetField),
                                        isDirectory: name.last == 0x2F))
            cursor = recordEnd
        }
        guard cursor == directoryEnd else { throw .malformed }
        return entries
    }

    private mutating func validateLocalSpans(_ entries: [CentralEntry], centralOffset: UInt32) throws(ZIPArchiveError) {
        try checkpoint()
        let ordered = entries.sorted { $0.localOffset < $1.localOffset }
        try checkpoint()
        var cursor = 0
        for (index, entry) in ordered.enumerated() {
            try checkpoint()
            guard entry.localOffset == cursor else { throw .malformed }
            guard cursor >= 0, cursor <= Int(centralOffset), Int(centralOffset) - cursor >= 30,
                  try read32(at: cursor) == Self.localHeaderSignature else { throw .malformed }

            let version = try read16(at: cursor + 4)
            let flags = try read16(at: cursor + 6)
            let methodCode = try read16(at: cursor + 8)
            let crc = try read32(at: cursor + 14)
            let compressedSize = try read32(at: cursor + 18)
            let uncompressedSize = try read32(at: cursor + 22)
            let nameLength = Int(try read16(at: cursor + 26))
            let extraLength = Int(try read16(at: cursor + 28))
            let variableLength = nameLength.addingReportingOverflow(extraLength)
            guard !variableLength.overflow, variableLength.partialValue <= Int(centralOffset) - cursor - 30 else {
                throw .malformed
            }
            let nameStart = cursor + 30
            let extraStart = nameStart + nameLength
            let payloadStart = extraStart + extraLength

            try validateExtras(at: extraStart, length: extraLength)
            guard nameLength <= Self.maximumNameBytes else { throw .limitExceeded(.encodedNameBytes) }
            guard nameLength > 0 else { throw .malformed }
            guard let localMethod = validateMethodAndFlags(methodCode, flags: flags) else {
                throw .unsupported
            }
            try validateRequiredVersion(version, method: localMethod, flags: flags)
            guard version == entry.versionNeeded, flags == entry.flags, localMethod == entry.method,
                  try bytesEqual(in: nameStart..<extraStart, to: entry.name) else { throw .malformed }
            guard (flags & 0x0001) == 0 else { throw .unsupported }

            let hasDescriptor = (flags & 0x0008) != 0
            if hasDescriptor {
                guard (crc == 0 || crc == entry.crc),
                      (compressedSize == 0 || compressedSize == entry.compressedSize),
                      (uncompressedSize == 0 || uncompressedSize == entry.uncompressedSize) else { throw .malformed }
            } else {
                guard crc == entry.crc, compressedSize == entry.compressedSize,
                      uncompressedSize == entry.uncompressedSize else { throw .malformed }
            }
            if entry.method == .stored, entry.compressedSize != entry.uncompressedSize { throw .malformed }
            if entry.isDirectory, entry.uncompressedSize != 0 { throw .malformed }

            let payloadLength = Int(entry.compressedSize)
            let (payloadEnd, payloadOverflow) = payloadStart.addingReportingOverflow(payloadLength)
            guard !payloadOverflow, payloadEnd <= Int(centralOffset) else { throw .malformed }
            let nextLocalOffset = index + 1 < ordered.count ? ordered[index + 1].localOffset : Int(centralOffset)
            if hasDescriptor {
                try validateDescriptor(at: payloadEnd, spanEnd: nextLocalOffset, entry: entry)
            } else {
                guard payloadEnd == nextLocalOffset else { throw .malformed }
            }
            cursor = nextLocalOffset
        }
        guard cursor == Int(centralOffset) else { throw .malformed }
    }

    private mutating func validateDescriptor(at offset: Int, spanEnd: Int, entry: CentralEntry) throws(ZIPArchiveError) {
        let length = spanEnd - offset
        guard length == 12 || length == 16 else { throw .malformed }
        var fieldOffset = offset
        if length == 16 {
            guard try read32(at: offset) == Self.dataDescriptorSignature else { throw .malformed }
            fieldOffset += 4
        }
        try checkpoint()
        guard try read32(at: fieldOffset) == entry.crc,
              try read32(at: fieldOffset + 4) == entry.compressedSize,
              try read32(at: fieldOffset + 8) == entry.uncompressedSize else { throw .malformed }
    }

    private func validateMethodAndFlags(_ rawMethod: UInt16, flags: UInt16) -> ZIPCompressionMethod? {
        guard let method = ZIPCompressionMethod(rawValue: rawMethod) else { return nil }
        let allowedFlags: UInt16 = method == .stored ? 0x0808 : 0x080E
        guard flags & ~allowedFlags == 0 else { return nil }
        return method
    }

    private func validateRequiredVersion(_ version: UInt16, method: ZIPCompressionMethod,
                                         flags: UInt16) throws(ZIPArchiveError) {
        guard version <= 20 else { throw .unsupported }
        let minimumVersion: UInt16 = method == .deflate || flags & 0x0008 != 0 ? 20 : 10
        guard version >= minimumVersion else { throw .malformed }
    }

    private mutating func validateExtras(at offset: Int, length: Int) throws(ZIPArchiveError) {
        let end = offset + length
        var cursor = offset
        while cursor < end {
            try checkpoint()
            guard end - cursor >= 4 else { throw .malformed }
            let identifier = try read16(at: cursor)
            let fieldLength = Int(try read16(at: cursor + 2))
            let (fieldEnd, overflow) = (cursor + 4).addingReportingOverflow(fieldLength)
            guard !overflow, fieldEnd <= end else { throw .malformed }
            if identifier == Self.zip64ExtraID { throw .unsupported }
            cursor = fieldEnd
        }
        guard cursor == end else { throw .malformed }
    }

    private mutating func project(_ centralEntries: [CentralEntry]) throws(ZIPArchiveError) -> ZIPArchiveListing {
        var result: [ZIPArchiveEntry] = []
        result.reserveCapacity(centralEntries.count)
        var budget = ZIPArchiveBudget()
        for entry in centralEntries {
            try checkpoint()
            let displayName = try escapedName(entry.name, isUTF8: entry.flags & 0x0800 != 0,
                                              remainingBudget: 262_144 - Int(budget.escapedNameUTF8Total))
            try budget.add(compressed: UInt64(entry.compressedSize),
                           uncompressed: UInt64(entry.uncompressedSize),
                           escapedNameUTF8: UInt64(displayName.utf8.count))
            result.append(ZIPArchiveEntry(displayName: displayName, isDirectory: entry.isDirectory,
                                          method: entry.method, compressedSize: UInt64(entry.compressedSize),
                                          uncompressedSize: UInt64(entry.uncompressedSize)))
        }
        self.budget = budget
        return ZIPArchiveListing(entries: result)
    }

    private var budget = ZIPArchiveBudget()

    private mutating func escapedName(_ rawName: [UInt8], isUTF8: Bool, remainingBudget: Int) throws(ZIPArchiveError) -> String {
        guard !rawName.isEmpty else { throw .malformed }
        var output: [UInt8] = []
        output.reserveCapacity(min(rawName.count * 2, remainingBudget))

        if isUTF8 {
            guard let decoded = String(bytes: rawName, encoding: .utf8) else { throw .malformed }
            var work = 0
            for scalar in decoded.unicodeScalars {
                if work & 0x3F == 0 { try checkpoint() }
                if scalar == "\\" {
                    try appendBackslash(to: &output, remainingBudget: remainingBudget)
                } else if Self.requiresUnicodeEscape(scalar) {
                    try appendUnicodeEscape(scalar.value, to: &output, remainingBudget: remainingBudget)
                } else {
                    try appendBytes(scalar.utf8, to: &output, remainingBudget: remainingBudget)
                }
                work += 1
            }
            try checkpoint()
            return String(decoding: output, as: UTF8.self)
        }

        for (index, byte) in rawName.enumerated() {
            if index & 0x3F == 0 { try checkpoint() }
            if (0x20...0x7E).contains(byte), byte != 0x5C {
                guard output.count < remainingBudget else { throw .limitExceeded(.escapedNameBytes) }
                output.append(byte)
            } else if byte == 0x5C {
                try appendBackslash(to: &output, remainingBudget: remainingBudget)
            } else {
                try appendByteEscape(byte, to: &output, remainingBudget: remainingBudget)
            }
        }
        try checkpoint()
        return String(decoding: output, as: UTF8.self)
    }

    private func appendBackslash(to output: inout [UInt8], remainingBudget: Int) throws(ZIPArchiveError) {
        guard output.count <= remainingBudget - 2 else { throw .limitExceeded(.escapedNameBytes) }
        output.append(0x5C)
        output.append(0x5C)
    }

    private func appendBytes<S: Sequence>(_ bytes: S, to output: inout [UInt8], remainingBudget: Int) throws(ZIPArchiveError)
    where S.Element == UInt8 {
        for byte in bytes {
            guard output.count < remainingBudget else { throw .limitExceeded(.escapedNameBytes) }
            output.append(byte)
        }
    }

    private func appendByteEscape(_ value: UInt8, to output: inout [UInt8], remainingBudget: Int) throws(ZIPArchiveError) {
        guard output.count <= remainingBudget - 4 else { throw .limitExceeded(.escapedNameBytes) }
        output.append(0x5C)
        output.append(0x78)
        appendHex(UInt32(value), minimumDigits: 2, to: &output)
    }

    private func appendUnicodeEscape(_ value: UInt32, to output: inout [UInt8], remainingBudget: Int) throws(ZIPArchiveError) {
        let digits = max(4, Self.hexDigitCount(value))
        let required = 4 + digits
        guard output.count <= remainingBudget - required else { throw .limitExceeded(.escapedNameBytes) }
        output.append(0x5C)
        output.append(0x75)
        output.append(0x7B)
        appendHex(value, minimumDigits: 4, to: &output)
        output.append(0x7D)
    }

    private static func hexDigitCount(_ value: UInt32) -> Int {
        var remaining = value
        var count = 1
        while remaining > 0xF {
            remaining >>= 4
            count += 1
        }
        return count
    }

    private func appendHex(_ value: UInt32, minimumDigits: Int, to output: inout [UInt8]) {
        let digitCount = max(minimumDigits, Self.hexDigitCount(value))
        for digitIndex in stride(from: digitCount - 1, through: 0, by: -1) {
            let shift = digitIndex * 4
            output.append(Self.hexadecimalDigits[Int((value >> shift) & 0xF)])
        }
    }

    private static func requiresUnicodeEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    private func read16(at offset: Int) throws(ZIPArchiveError) -> UInt16 {
        guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 2 else { throw .malformed }
        return UInt16(try bytes.byte(at: offset)) | (UInt16(try bytes.byte(at: offset + 1)) << 8)
    }

    private func read32(at offset: Int) throws(ZIPArchiveError) -> UInt32 {
        guard let value = try read32IfAvailable(at: offset) else { throw .malformed }
        return value
    }

    private func read32IfAvailable(at offset: Int) throws(ZIPArchiveError) -> UInt32? {
        guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 4 else { return nil }
        return UInt32(try bytes.byte(at: offset)) | (UInt32(try bytes.byte(at: offset + 1)) << 8)
            | (UInt32(try bytes.byte(at: offset + 2)) << 16) | (UInt32(try bytes.byte(at: offset + 3)) << 24)
    }

    private func read64IfAvailable(at offset: Int) throws(ZIPArchiveError) -> UInt64? {
        guard let low = try read32IfAvailable(at: offset),
              offset <= bytes.count - 8,
              let high = try read32IfAvailable(at: offset + 4) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }

    private func copyBytes(in range: Range<Int>) throws(ZIPArchiveError) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(range.count)
        for offset in range { result.append(try bytes.byte(at: offset)) }
        return result
    }

    private func bytesEqual(in range: Range<Int>, to expected: [UInt8]) throws(ZIPArchiveError) -> Bool {
        guard range.count == expected.count else { return false }
        for (offset, byte) in zip(range, expected) {
            if try bytes.byte(at: offset) != byte { return false }
        }
        return true
    }
}
