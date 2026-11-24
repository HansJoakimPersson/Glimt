import Foundation
import XCTest
@testable import InspectorCore

final class InspectorCoreTests: XCTestCase {
    func testReadsFixtureWithExactUTF8Contents() throws {
        let url = try fixtureURL("Showcase/text/plain.txt")
        let result = try InspectorCore.readUTF8Text(from: url, maximumBytes: 1_024)

        XCTAssertEqual(result, "Glimt line 1\nRad två med åäö och emoji 🙂\nThird line: tabs\tand spaces.\n")
    }

    func testAcceptsInputAtExactByteLimit() throws {
        let bytes = Data("åäö".utf8)
        let url = try makeTemporaryFile(contents: bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try InspectorCore.readUTF8Text(from: url, maximumBytes: bytes.count), "åäö")
    }

    func testRejectsInputOverByteLimit() throws {
        let bytes = Data("abcd".utf8)
        let url = try makeTemporaryFile(contents: bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try InspectorCore.readUTF8Text(from: url, maximumBytes: bytes.count - 1)) { error in
            XCTAssertEqual(error as? InspectorCoreError, .fileTooLarge(limit: bytes.count - 1))
        }
    }

    func testRejectsInvalidUTF8() throws {
        let url = try makeTemporaryFile(contents: Data([0xC3, 0x28]))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try InspectorCore.readUTF8Text(from: url, maximumBytes: 16)) { error in
            XCTAssertEqual(error as? InspectorCoreError, .invalidUTF8)
        }
    }

    func testAnalyzesUTF8AndBOMMarkedEncodings() throws {
        let cases: [(Data, TextEncoding, Bool, String)] = [
            (Data("plain".utf8), .utf8, false, "plain"),
            (try Data(contentsOf: fixtureURL("Cases/text/utf8-bom.txt")), .utf8BOM, true, "plain"),
            (try Data(contentsOf: fixtureURL("Cases/text/utf16le.txt")), .utf16LittleEndian, true, "pl"),
            (Data([0xFE, 0xFF, 0x00, 0x70, 0x00, 0x6C]), .utf16BigEndian, true, "pl"),
            (Data([0xFF, 0xFE, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00]), .utf32LittleEndian, true, "p"),
            (Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x70]), .utf32BigEndian, true, "p")
        ]

        for (bytes, expectedEncoding, expectedBOM, expectedText) in cases {
            let result = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_024)
            XCTAssertEqual(result.encoding, expectedEncoding)
            XCTAssertEqual(result.hasBOM, expectedBOM)
            XCTAssertEqual(result.text, expectedText)
            XCTAssertFalse(result.isBinary)
        }
    }

    func testFallsBackToWindows1252ForLegacyEightBitText() {
        let result = TextAnalysis.analyze(bytes: Data([0x63, 0x61, 0x66, 0xE9]), fileSize: 4, maximumBytes: 4)

        XCTAssertEqual(result.encoding, .windows1252)
        XCTAssertEqual(result.text, "café")
        XCTAssertFalse(result.hasBOM)
        XCTAssertFalse(result.isBinary)
    }

    func testSummarizesLineEndingsAndLogicalLineCounts() {
        let cases: [(String, TextLineEnding, Int)] = [
            ("one\ntwo", .lf, 2),
            ("one\r\ntwo\r\n", .crlf, 2),
            ("one\rtwo", .cr, 2),
            ("one\ntwo\rthree", .mixed, 3),
            ("unterminated", .none, 1),
            ("", .none, 0),
            ("one\n", .lf, 1),
            ("\n\n", .lf, 2)
        ]

        for (text, expectedEnding, expectedCount) in cases {
            let bytes = Data(text.utf8)
            let result = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_024)
            XCTAssertEqual(result.lineEnding, expectedEnding, "Input: \(text.debugDescription)")
            XCTAssertEqual(result.lineCount, expectedCount, "Input: \(text.debugDescription)")
        }
    }

    func testUsesExactFileSizeAndMarksPrefixLineCountAsLowerBound() {
        let prefix = Data("one\ntwo\nthree".utf8)
        let result = TextAnalysis.analyze(bytes: prefix, fileSize: prefix.count + 20, maximumBytes: prefix.count)

        XCTAssertEqual(result.fileSize, prefix.count + 20)
        XCTAssertEqual(result.lineCount, 3)
        XCTAssertTrue(result.lineCountIsLowerBound)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text, "one\ntwo\nthree")
    }

    func testOmitsIncompleteTruncatedUnicodeTailAndRejectsMalformedUnicode() {
        let utf8Prefix = Data([0x41, 0xF0, 0x9F])
        let utf8 = TextAnalysis.analyze(bytes: utf8Prefix, fileSize: 5, maximumBytes: 3)
        XCTAssertEqual(utf8.encoding, .utf8)
        XCTAssertEqual(utf8.text, "A")
        XCTAssertTrue(utf8.lineCountIsLowerBound)

        let malformedUTF8 = TextAnalysis.analyze(bytes: Data([0xC3, 0x28]), fileSize: 2, maximumBytes: 2)
        XCTAssertEqual(malformedUTF8.encoding, .windows1252)
        XCTAssertEqual(malformedUTF8.text, "Ã(")

        let malformedBOMMarked = TextAnalysis.analyze(
            bytes: Data([0xFF, 0xFE, 0x00, 0xD8]),
            fileSize: 4,
            maximumBytes: 4
        )
        XCTAssertTrue(malformedBOMMarked.isBinary)
        XCTAssertTrue(malformedBOMMarked.hasBOM)
        XCTAssertEqual(malformedBOMMarked.text, "")

        let truncatedBOMMarked = TextAnalysis.analyze(
            bytes: Data([0xFF, 0xFE, 0x41, 0x00, 0x00, 0xD8]),
            fileSize: 8,
            maximumBytes: 6
        )
        XCTAssertEqual(truncatedBOMMarked.encoding, .utf16LittleEndian)
        XCTAssertEqual(truncatedBOMMarked.text, "A")
    }

    func testDetectsNULAndExcessDisallowedControlsAsBinary() {
        let nul = TextAnalysis.analyze(bytes: Data([0x61, 0x00, 0x62]), fileSize: 3, maximumBytes: 3)
        XCTAssertTrue(nul.isBinary)
        XCTAssertNil(nul.encoding)
        XCTAssertEqual(nul.lineEnding, .none)
        XCTAssertEqual(nul.lineCount, 0)

        let overThreshold = TextAnalysis.analyze(
            bytes: Data([0x61, 0x01, 0x02, 0x62, 0x63]),
            fileSize: 5,
            maximumBytes: 5
        )
        XCTAssertTrue(overThreshold.isBinary)
        XCTAssertEqual(overThreshold.binaryProbability, 0.4, accuracy: 0.000_001)

        let exactlyThreshold = TextAnalysis.analyze(
            bytes: Data([0x01, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69]),
            fileSize: 10,
            maximumBytes: 10
        )
        XCTAssertFalse(exactlyThreshold.isBinary)
        XCTAssertEqual(exactlyThreshold.binaryProbability, 0.1, accuracy: 0.000_001)
    }

    func testEnforcesOneMiBAnalysisCeiling() {
        let bytes = Data(repeating: 0x61, count: 1_048_576 + 10)
        let result = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: bytes.count)

        XCTAssertEqual(result.fileSize, bytes.count)
        XCTAssertEqual(result.text.utf8.count, 1_048_576)
        XCTAssertEqual(result.lineCount, 1)
        XCTAssertTrue(result.lineCountIsLowerBound)
    }

    private func makeTemporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try contents.write(to: url)
        return url
    }
}
