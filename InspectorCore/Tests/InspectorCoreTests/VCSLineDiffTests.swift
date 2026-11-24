import XCTest
@testable import InspectorCore

final class VCSLineDiffTests: XCTestCase {
    func testGroupsAdjacentEditsAndDistinguishesAddsDeletesAndModifications() throws {
        let result = try VCSLineDiff.compare(baseline: Data("a\nb\nc\ne\n".utf8), working: Data("a\nx\ne\nf\n".utf8))
        XCTAssertEqual(result.changes, [
            .init(kind: .modified, baselineLines: 1..<3, workingLines: 1..<2),
            .init(kind: .added, baselineLines: 4..<4, workingLines: 3..<4)
        ])
    }

    func testDeletionBoundaryIncludesEndOfFileAndEmptyFiles() throws {
        let deleted = try VCSLineDiff.compare(baseline: Data("one\ntwo".utf8), working: Data("one".utf8))
        XCTAssertEqual(deleted.changes, [.init(kind: .deleted, baselineLines: 1..<2, workingLines: 1..<1)])
        let empty = try VCSLineDiff.compare(baseline: Data(), working: Data())
        XCTAssertEqual(empty.baselineLineCount, 0)
        XCTAssertTrue(empty.changes.isEmpty)
        let wholeFile = try VCSLineDiff.compare(baseline: Data("x".utf8), working: Data())
        XCTAssertEqual(wholeFile.changes.first?.workingLines, 0..<0)
    }

    func testCRLFAndFinalTerminatorAloneAreNotChanges() throws {
        let same = try VCSLineDiff.compare(baseline: Data("a\r\nb".utf8), working: Data("a\nb\n".utf8))
        XCTAssertTrue(same.changes.isEmpty)
        let changed = try VCSLineDiff.compare(baseline: Data("café\n".utf8), working: Data("cafe\n".utf8))
        XCTAssertEqual(changed.changes.first?.kind, .modified)
    }

    func testEncodingDifferenceIsConservativeAndBinaryIsRejected() throws {
        let utf8 = Data("café\n".utf8)
        let windows1252 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        XCTAssertEqual(try VCSLineDiff.compare(baseline: utf8, working: windows1252).changes.first?.kind, .modified)
        XCTAssertThrowsError(try VCSLineDiff.compare(baseline: Data([0, 1]), working: Data([0, 1]))) {
            XCTAssertEqual($0 as? VCSLineDiffError, .binaryContent)
        }
    }

    func testInputAndMatrixLimitsAreEnforced() throws {
        let limits = VCSLineDiff.Limits(maximumBytes: 32, maximumMatrixCells: 4)
        XCTAssertThrowsError(try VCSLineDiff.compare(baseline: Data(repeating: 97, count: 33), working: Data(), limits: limits)) {
            XCTAssertEqual($0 as? VCSLineDiffError, .inputTooLarge)
        }
        XCTAssertThrowsError(try VCSLineDiff.compare(baseline: Data("a\nb".utf8), working: Data("a\nb".utf8), limits: limits)) {
            XCTAssertEqual($0 as? VCSLineDiffError, .comparisonTooLarge)
        }
    }

    func testCancellationAndDeadlineAreHonored() async {
        let cancelled = Task { () throws -> VCSLineDiff in
            try Task.checkCancellation()
            return try VCSLineDiff.compare(baseline: Data(repeating: 97, count: 20), working: Data(repeating: 98, count: 20))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }

        XCTAssertThrowsError(try VCSLineDiff.compare(baseline: Data(), working: Data(), limits: .init(maximumDuration: .zero))) {
            XCTAssertEqual($0 as? VCSLineDiffError, .timeLimitReached)
        }
    }
}
