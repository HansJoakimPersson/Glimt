import Foundation
import XCTest
@testable import InspectorCore

final class DiffInspectorTests: XCTestCase {
    func testUnifiedDiffRetainsFilesHunksAndLineKinds() throws {
        let source = """
        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        --- a/old.txt
        +++ b/new.txt
        @@ -2,2 +2,3 @@ heading
         context
        -removed
        +added
        +second addition
        """

        let result = try DiffInspector.inspect(text: source, fileSize: source.utf8.count)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].oldPath, "old.txt")
        XCTAssertEqual(result.files[0].newPath, "new.txt")
        XCTAssertEqual(result.files[0].change, .rename)
        XCTAssertEqual(result.files[0].hunks.count, 1)
        XCTAssertEqual(result.files[0].hunks[0].oldStart, 2)
        XCTAssertEqual(result.files[0].hunks[0].oldCount, 2)
        XCTAssertEqual(result.files[0].hunks[0].newStart, 2)
        XCTAssertEqual(result.files[0].hunks[0].newCount, 3)
        XCTAssertEqual(result.files[0].hunks[0].lines.map(\.kind), [.context, .deletion, .addition, .addition])
        XCTAssertEqual(result.addedLineCount, 2)
        XCTAssertEqual(result.removedLineCount, 1)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.rawText, source)
    }

    func testCreateDeleteBinaryAndMalformedHunksAreReportedWithoutLosingRaw() throws {
        let source = """
        diff --git a/new.bin b/new.bin
        new file mode 100644
        --- /dev/null
        +++ b/new.bin
        GIT binary patch
        literal 4
        @@ -1,2 +1,1 @@
        -too many removed lines
        """

        let result = try DiffInspector.inspect(text: source, fileSize: source.utf8.count)

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].change, .create)
        XCTAssertTrue(result.files[0].isBinary)
        XCTAssertFalse(result.diagnostics.isEmpty)
        XCTAssertEqual(result.rawText, source)
    }

    func testInputAndOutputLimitsAreBoundedAndCancellationIsHonored() async throws {
        let source = (0..<32).map { "+line-\($0)" }.joined(separator: "\n")
        let limited = try DiffInspector.inspect(text: source, fileSize: source.utf8.count,
            limits: .init(maximumLines: 4))
        XCTAssertLessThanOrEqual(limited.lineCount, 4)
        XCTAssertTrue(limited.isTruncated)
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .limitExceeded })

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DiffInspector.inspect(text: source, fileSize: source.utf8.count)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled diff inspection should throw")
        } catch is CancellationError {
            // Expected: the inspector observes cancellation before scanning input.
        }
    }

    func testBinaryGitHeaderDecodesQuotedPathsWithSpacesAndEscapes() throws {
        let source = "diff --git \"a/folder/name with \\\"quote\\\"\\\\file.bin\" \"b/folder/name with \\\"quote\\\"\\\\file.bin\"\nGIT binary patch\nliteral 0\n"
        let result = try DiffInspector.inspect(text: source, fileSize: source.utf8.count)
        XCTAssertEqual(result.files.first?.oldPath, "folder/name with \"quote\"\\file.bin")
        XCTAssertEqual(result.files.first?.newPath, "folder/name with \"quote\"\\file.bin")

        let octal = "diff --git \"a/name\\040with\\040spaces.bin\" \"b/name\\040with\\040spaces.bin\"\nGIT binary patch\n"
        let octalResult = try DiffInspector.inspect(text: octal, fileSize: octal.utf8.count)
        XCTAssertEqual(octalResult.files.first?.newPath, "name with spaces.bin")
    }
}
