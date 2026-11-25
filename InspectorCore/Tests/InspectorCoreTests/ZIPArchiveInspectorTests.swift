import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import InspectorCore

final class ZIPArchiveInspectorTests: XCTestCase {
    func testClassicStoredVersionRangeAndRequiredMinimums() throws {
        var stored = ZIPFixture.archive(entries: [.init(name: [0x61], payload: [])])
        let centralOffset = stored.count - 22 - 47
        stored[4] = 15
        stored[5] = 0
        stored[centralOffset + 6] = 15
        stored[centralOffset + 7] = 0
        XCTAssertEqual(try ZIPArchiveInspector.inspect(data: stored, fileSize: stored.count).entries.count, 1)

        var lowDeflate = ZIPFixture.archive(entries: [.init(name: [0x61], payload: [], method: 8)])
        let deflateCentralOffset = lowDeflate.count - 22 - 47
        lowDeflate[4] = 10
        lowDeflate[5] = 0
        lowDeflate[deflateCentralOffset + 6] = 10
        lowDeflate[deflateCentralOffset + 7] = 0
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: lowDeflate, fileSize: lowDeflate.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }

        var futureVersion = stored
        futureVersion[4] = 21
        futureVersion[centralOffset + 6] = 21
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: futureVersion, fileSize: futureVersion.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .unsupported)
        }
    }

    func testSharedPreviewRoutesSupportedZIPToMetadataListingAndRetainsOriginalBytes() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("first.txt".utf8), payload: Array("alpha\n".utf8), method: 8),
            .init(name: Array("second.txt".utf8), payload: Array("beta\n".utf8), method: 0)
        ])
        let result = PreviewInspectionResult.prepare(bytes: archive, fileSize: archive.count,
                                                     fileName: "sample.ZIP", systemUTI: nil)

        XCTAssertEqual(result.formatDefinition?.id, .zip)
        XCTAssertTrue(result.analysis.isBinary)
        XCTAssertEqual(result.originalBytes, archive)
        XCTAssertEqual(result.additionalInspection?.archiveListing?.entries.map(\.displayName), ["first.txt", "second.txt"])
        XCTAssertEqual(result.additionalInspection?.archiveListing?.entries.map(\.compressedSize), [6, 5])
        XCTAssertEqual(result.additionalInspection?.archiveListing?.entries.map(\.uncompressedSize), [6, 5])
        XCTAssertEqual(result.detectionReason, "fileExtension")
    }

    func testListsStoredAndDeflateEntriesInCentralOrderWithoutReadingPayload() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("second.txt".utf8), payload: [0xDE, 0xAD], uncompressedSize: 20, method: 8),
            .init(name: Array("first.txt".utf8), payload: Array("first".utf8), method: 0)
        ])

        let result = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)

        XCTAssertEqual(result.entries.map(\.displayName), ["second.txt", "first.txt"])
        XCTAssertEqual(result.entries.map(\.method), [.deflate, .stored])
        XCTAssertEqual(result.entries.map(\.compressedSize), [2, 5])
        XCTAssertEqual(result.entries.map(\.uncompressedSize), [20, 5])
    }

    func testListsBothClassicDataDescriptorForms() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("unsigned".utf8), payload: [0x01, 0x02], uncompressedSize: 3,
                  method: 8, usesDescriptor: true),
            .init(name: Array("signed".utf8), payload: [0x03], uncompressedSize: 4,
                  method: 8, usesDescriptor: true, descriptorHasSignature: true)
        ])

        let result = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)

        XCTAssertEqual(result.entries.map(\.displayName), ["unsigned", "signed"])
        XCTAssertEqual(result.entries.map(\.uncompressedSize), [3, 4])
    }

    func testAcceptsEmptyArchivesWithAndWithoutComment() throws {
        for comment in [[], Array("empty archive".utf8)] {
            let archive = ZIPFixture.archive(entries: [], archiveComment: comment)
            let result = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)
            XCTAssertTrue(result.entries.isEmpty)
        }
    }

    func testSupportsDataSliceWithNonzeroStartIndex() throws {
        let archive = ZIPFixture.archive(entries: [.init(name: Array("slice".utf8), payload: [0x42])])
        var padded = Data([0xFF])
        padded.append(archive)
        padded.append(0xEE)
        let slice = padded[1..<(padded.count - 1)]

        let result = try ZIPArchiveInspector.inspect(data: slice, fileSize: archive.count)

        XCTAssertEqual(result.entries.map(\.displayName), ["slice"])
    }

    func testEscapesUnflaggedBytesAndUnicodeFormatScalarsWithoutNormalization() throws {
        let decomposed = Array("e\u{301}".utf8)
        let archive = ZIPFixture.archive(entries: [
            .init(name: [0x61, 0x5C, 0x00, 0x80], payload: []),
            .init(name: decomposed + Array("\u{2028}".utf8), payload: [], flags: 0x0800)
        ])

        let result = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)

        XCTAssertEqual(result.entries[0].displayName, "a\\\\\\x00\\x80")
        XCTAssertEqual(Array(result.entries[1].displayName.unicodeScalars.map(\.value)),
                       [0x65, 0x301, 0x5C, 0x75, 0x7B, 0x32, 0x30, 0x32, 0x38, 0x7D])
        XCTAssertFalse(result.entries[0].isDirectory)
    }

    func testDirectoryMarkerUsesOnlyTrailingRawSlash() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("folder/".utf8), payload: [], uncompressedSize: 0),
            .init(name: Array("folder".utf8), payload: [])
        ])

        let result = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)

        XCTAssertEqual(result.entries.map(\.isDirectory), [true, false])
    }

    func testDuplicateAndPathLikeNamesRemainInCentralOrderAsDisplayData() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("../same".utf8), payload: [1]),
            .init(name: Array("../same".utf8), payload: [2])
        ])

        let result = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)

        XCTAssertEqual(result.entries.map(\.displayName), ["../same", "../same"])
    }

    func testInvalidAndIncompleteLengthsHaveTypedErrors() {
        let bytes = ZIPFixture.archive(entries: [.init(name: Array("a".utf8), payload: [1])])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: bytes, fileSize: -1)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .invalidFileSize)
        }
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: bytes, fileSize: bytes.count - 1)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .invalidFileSize)
        }
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: Data(bytes.dropLast()), fileSize: bytes.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .incompleteInput)
        }
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: Data(), fileSize: 0)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }
    }

    func testArchiveSizeIsNotALimit() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("large.bin".utf8), payload: Array(repeating: 0x41, count: 3 * 1_048_576)),
            .init(name: Array("tail.txt".utf8), payload: Array("end\n".utf8))
        ])
        let listing = try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)
        XCTAssertEqual(listing.entries.map(\.displayName), ["large.bin", "tail.txt"])
    }

    func testPreviewListsAnArchiveLargerThanTheRetainedPrefix() throws {
        let archive = ZIPFixture.archive(entries: [
            .init(name: Array("large.bin".utf8), payload: Array(repeating: 0x41, count: 3 * 1_048_576)),
            .init(name: Array("tail.txt".utf8), payload: Array("end\n".utf8), method: 8, usesDescriptor: true)
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtLargeZIP-\(UUID().uuidString).zip")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try PreviewInspectionResult.read(at: url)
        XCTAssertEqual(result.additionalInspection?.archiveListing?.entries.map(\.displayName), ["large.bin", "tail.txt"])
        XCTAssertEqual(result.originalBytes.count, 1_048_576, "Raw and Hex keep the bounded prefix")
        XCTAssertTrue(result.inspectionDiagnostics.isEmpty)
    }

    func testRejectsAnOversizedCentralDirectoryBeforeReadingIt() {
        let centralSize = 1_048_577
        var bytes = Data(repeating: 0, count: centralSize)
        bytes.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0])
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(centralSize).littleEndian, Array.init))
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: bytes, fileSize: bytes.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.inputBytes))
        }
    }

    func testRejectsAmbiguousEndRecordsAndTruncatedRecords() {
        let valid = ZIPFixture.archive(entries: [])
        var ambiguous = valid
        ambiguous.append(contentsOf: [0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        // Turn the nested EOCD bytes into the outer EOCD comment.
        let commentLengthOffset = valid.count - 2
        ambiguous[commentLengthOffset] = 22
        ambiguous[commentLengthOffset + 1] = 0
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: ambiguous, fileSize: ambiguous.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: Data([0x50, 0x4B, 0x03]), fileSize: 3)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }
    }

    func testRejectsMismatchedLocalHeaderAndMalformedExtras() {
        var mismatch = ZIPFixture.archive(entries: [.init(name: Array("name".utf8), payload: [1])])
        mismatch[30] = 0x78
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: mismatch, fileSize: mismatch.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }

        let malformedExtra = ZIPFixture.archive(entries: [
            .init(name: Array("name".utf8), payload: [], localExtra: [0x34, 0x12, 0x05, 0x00, 0x01])
        ])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: malformedExtra, fileSize: malformedExtra.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }
    }

    func testRejectsZIP64SentinelsAndUnsupportedFeatures() {
        var zip64 = ZIPFixture.archive(entries: [])
        let countOffset = zip64.count - 22 + 8
        zip64[countOffset] = 0xFF
        zip64[countOffset + 1] = 0xFF
        zip64[countOffset + 2] = 0xFF
        zip64[countOffset + 3] = 0xFF
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: zip64, fileSize: zip64.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .unsupported)
        }

        let encrypted = ZIPFixture.archive(entries: [.init(name: Array("secret".utf8), payload: [1], flags: 1)])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: encrypted, fileSize: encrypted.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .unsupported)
        }
    }

    func testRejectsInvalidFlaggedUTF8() {
        let archive = ZIPFixture.archive(entries: [.init(name: [0xC0, 0xAF], payload: [], flags: 0x0800)])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .malformed)
        }
    }

    func testEnforcesEntryCountAndRawNameBoundaries() throws {
        let maxEntries = (0..<512).map { index in
            ZIPFixture.Entry(name: Array("e\(index)".utf8), payload: [])
        }
        let archive = ZIPFixture.archive(entries: maxEntries)
        XCTAssertEqual(try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count).entries.count, 512)

        let tooMany = ZIPFixture.archive(entries: maxEntries + [.init(name: Array("overflow".utf8), payload: [])])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: tooMany, fileSize: tooMany.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.entryCount))
        }

        let maxName = ZIPFixture.archive(entries: [.init(name: Array(repeating: 0x61, count: 1_024), payload: [])])
        XCTAssertEqual(try ZIPArchiveInspector.inspect(data: maxName, fileSize: maxName.count).entries[0].displayName.utf8.count, 1_024)
        let longName = ZIPFixture.archive(entries: [.init(name: Array(repeating: 0x61, count: 1_025), payload: [])])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: longName, fileSize: longName.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.encodedNameBytes))
        }
    }

    func testEnforcesEscapedNameBudgetAtAndAboveBoundary() throws {
        let exact = (0..<64).map { _ in
            ZIPFixture.Entry(name: Array(repeating: 0x80, count: 1_024), payload: [])
        }
        let exactArchive = ZIPFixture.archive(entries: exact)
        XCTAssertEqual(try ZIPArchiveInspector.inspect(data: exactArchive, fileSize: exactArchive.count).entries.count, 64)

        let overArchive = ZIPFixture.archive(entries: exact + [.init(name: [0x61], payload: [])])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: overArchive, fileSize: overArchive.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.escapedNameBytes))
        }
    }

    func testEnforcesExpansionRatioBeforePublishingAnyRows() {
        let ratioLimit = ZIPFixture.archive(entries: [.init(name: Array("ratio".utf8), payload: [0x01], uncompressedSize: 1_000, method: 8)])
        XCTAssertNoThrow(try ZIPArchiveInspector.inspect(data: ratioLimit, fileSize: ratioLimit.count))

        let ratioExceeded = ZIPFixture.archive(entries: [.init(name: Array("ratio".utf8), payload: [0x01], uncompressedSize: 1_001, method: 8)])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: ratioExceeded, fileSize: ratioExceeded.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.entryExpansionRatio))
        }
    }

    func testEntrySizeLimitsAndCheckedAccumulatorBoundaries() throws {
        let maxEntry = ZIPFixture.archive(entries: [.init(name: Array("large".utf8), payload: [0x01], uncompressedSize: 1_073_741_824, method: 8)])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: maxEntry, fileSize: maxEntry.count)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.entryExpansionRatio))
        }

        var budget = ZIPArchiveBudget(compressedTotal: 1, uncompressedTotal: 0, escapedNameUTF8Total: 0, entryCount: 0)
        let before = budget.snapshot
        XCTAssertThrowsError(try budget.add(compressed: 1, uncompressed: 1_073_741_825, escapedNameUTF8: 1)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.entryUncompressedBytes))
        }
        XCTAssertEqual(budget.snapshot, before)

        var total = ZIPArchiveBudget(compressedTotal: 1, uncompressedTotal: 4_294_967_296, escapedNameUTF8Total: 0, entryCount: 0)
        XCTAssertThrowsError(try total.add(compressed: 1, uncompressed: 1, escapedNameUTF8: 0)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.totalUncompressedBytes))
        }
        XCTAssertEqual(total.snapshot.uncompressedTotal, 4_294_967_296)

        var overflow = ZIPArchiveBudget(compressedTotal: UInt64.max, uncompressedTotal: 0, escapedNameUTF8Total: 0, entryCount: 0)
        XCTAssertThrowsError(try overflow.add(compressed: 1, uncompressed: 0, escapedNameUTF8: 0)) {
            XCTAssertEqual($0 as? ZIPArchiveError, .limitExceeded(.totalExpansionRatio))
        }
        XCTAssertEqual(overflow.snapshot.compressedTotal, UInt64.max)
    }

    func testProbeAndTaskCancellationAreTyped() async {
        let archive = ZIPFixture.archive(entries: [.init(name: Array("a".utf8), payload: [])])
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count,
                                                               isCancelled: { true })) {
            XCTAssertEqual($0 as? ZIPArchiveError, .cancelled)
        }

        let cancelled = await runCancelled { try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count) }
        XCTAssertThrowsError(try cancelled.get()) { XCTAssertEqual($0 as? ZIPArchiveError, .cancelled) }
    }

    func testCancellationDuringCentralScanStopsWithoutPartialListing() {
        let entries = (0..<8).map { ZIPFixture.Entry(name: Array("entry\($0)".utf8), payload: []) }
        let archive = ZIPFixture.archive(entries: entries)
        var probes = 0
        XCTAssertThrowsError(try ZIPArchiveInspector.inspect(data: archive, fileSize: archive.count, isCancelled: {
            probes += 1
            return probes > 5
        })) {
            XCTAssertEqual($0 as? ZIPArchiveError, .cancelled)
        }
    }

    func testPayloadBytesAffectOnlyDeclaredMetadataNotListing() throws {
        let first = ZIPFixture.archive(entries: [.init(name: Array("opaque".utf8), payload: [0x01, 0x02, 0x03], method: 8)])
        var second = first
        let payloadOffset = ZIPFixture.firstPayloadOffset(in: first)
        second[payloadOffset] ^= 0xFF
        second[payloadOffset + 1] ^= 0xFF
        second[payloadOffset + 2] ^= 0xFF

        let left = try ZIPArchiveInspector.inspect(data: first, fileSize: first.count)
        let right = try ZIPArchiveInspector.inspect(data: second, fileSize: second.count)
        XCTAssertEqual(left, right)
    }
}

private enum ZIPFixture {
    struct Entry {
        var name: [UInt8]
        var payload: [UInt8]
        var uncompressedSize: UInt32?
        var method: UInt16 = 0
        var flags: UInt16 = 0
        var crc: UInt32 = 0x1234_5678
        var localExtra: [UInt8] = []
        var centralExtra: [UInt8] = []
        var comment: [UInt8] = []
        var usesDescriptor = false
        var descriptorHasSignature = false

        init(name: [UInt8], payload: [UInt8], uncompressedSize: UInt32? = nil, method: UInt16 = 0,
             flags: UInt16 = 0, crc: UInt32 = 0x1234_5678, localExtra: [UInt8] = [],
             centralExtra: [UInt8] = [], comment: [UInt8] = [], usesDescriptor: Bool = false,
             descriptorHasSignature: Bool = false) {
            self.name = name
            self.payload = payload
            self.uncompressedSize = uncompressedSize
            self.method = method
            self.flags = flags | (usesDescriptor ? 0x0008 : 0)
            self.crc = crc
            self.localExtra = localExtra
            self.centralExtra = centralExtra
            self.comment = comment
            self.usesDescriptor = usesDescriptor
            self.descriptorHasSignature = descriptorHasSignature
        }
    }

    static func archive(entries: [Entry], archiveComment: [UInt8] = []) -> Data {
        var locals: [UInt8] = []
        var central: [UInt8] = []
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(locals.count)
            let expanded = entry.uncompressedSize ?? UInt32(entry.payload.count)
            let localCRC = entry.usesDescriptor ? 0 : entry.crc
            let localCompressed = entry.usesDescriptor ? 0 : UInt32(entry.payload.count)
            let localUncompressed = entry.usesDescriptor ? 0 : expanded
            append(UInt32(0x0403_4B50), to: &locals)
            append(UInt16(entry.method == 0 ? 10 : 20), to: &locals)
            append(entry.flags, to: &locals)
            append(entry.method, to: &locals)
            append(UInt16(0), to: &locals)
            append(UInt16(0), to: &locals)
            append(localCRC, to: &locals)
            append(localCompressed, to: &locals)
            append(localUncompressed, to: &locals)
            append(UInt16(entry.name.count), to: &locals)
            append(UInt16(entry.localExtra.count), to: &locals)
            locals += entry.name + entry.localExtra + entry.payload
            if entry.usesDescriptor {
                if entry.descriptorHasSignature { append(UInt32(0x0807_4B50), to: &locals) }
                append(entry.crc, to: &locals)
                append(UInt32(entry.payload.count), to: &locals)
                append(expanded, to: &locals)
            }
        }
        let centralOffset = locals.count
        for (entry, localOffset) in zip(entries, offsets) {
            let expanded = entry.uncompressedSize ?? UInt32(entry.payload.count)
            append(UInt32(0x0201_4B50), to: &central)
            append(UInt16(0x031E), to: &central)
            append(UInt16(entry.method == 0 ? 10 : 20), to: &central)
            append(entry.flags, to: &central)
            append(entry.method, to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(entry.crc, to: &central)
            append(UInt32(entry.payload.count), to: &central)
            append(expanded, to: &central)
            append(UInt16(entry.name.count), to: &central)
            append(UInt16(entry.centralExtra.count), to: &central)
            append(UInt16(entry.comment.count), to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(UInt32(0), to: &central)
            append(UInt32(localOffset), to: &central)
            central += entry.name + entry.centralExtra + entry.comment
        }
        var result = locals + central
        append(UInt32(0x0605_4B50), to: &result)
        append(UInt16(0), to: &result)
        append(UInt16(0), to: &result)
        append(UInt16(entries.count), to: &result)
        append(UInt16(entries.count), to: &result)
        append(UInt32(central.count), to: &result)
        append(UInt32(centralOffset), to: &result)
        append(UInt16(archiveComment.count), to: &result)
        result += archiveComment
        return Data(result)
    }

    static func firstPayloadOffset(in archive: Data) -> Int {
        30 + Int(read16(archive, at: 26)) + Int(read16(archive, at: 28))
    }

    private static func read16(_ bytes: Data, at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
    }
}
