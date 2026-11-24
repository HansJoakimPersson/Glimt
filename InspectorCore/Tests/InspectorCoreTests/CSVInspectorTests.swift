import Foundation
import XCTest
@testable import InspectorCore

final class CSVInspectorTests: XCTestCase {
    func testCSVParsesHeadersQuotesEscapesAndEmbeddedNewlines() throws {
        let bytes = Data("name,note\r\nAda,\"first line\r\nsecond line\"\r\n\"Grace \"\"Amazing\"\"\",compiler\r\n".utf8)
        let result = try CSVInspector.inspect(bytes: bytes, fileSize: bytes.count, delimiter: .comma)

        XCTAssertEqual(result.table?.headers, ["name", "note"])
        XCTAssertEqual(result.table?.rows, [["Ada", "first line\r\nsecond line"], ["Grace \"Amazing\"", "compiler"]])
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, String(decoding: bytes, as: UTF8.self))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testTSVUsesTabDelimiterAndPreservesRaggedRows() throws {
        let bytes = Data("key\tvalue\na\t1\textra\nb\t2\n".utf8)
        let result = try CSVInspector.inspect(bytes: bytes, fileSize: bytes.count, delimiter: .tab)

        XCTAssertEqual(result.table?.headers, ["key", "value"])
        XCTAssertEqual(result.table?.rows, [["a", "1", "extra"], ["b", "2"]])
    }

    func testMalformedOrIncompleteDataRetainsRawAndReportsDiagnostics() throws {
        let malformed = Data("a,b\n1,\"unfinished".utf8)
        let failed = try CSVInspector.inspect(bytes: malformed, fileSize: malformed.count, delimiter: .comma)
        XCTAssertNil(failed.table)
        XCTAssertEqual(failed.rawBytes, malformed)
        XCTAssertEqual(failed.diagnostics.map(\.code), [.parseError])

        let prefix = Data("a,b\n1,".utf8)
        let incomplete = try CSVInspector.inspect(bytes: prefix, fileSize: prefix.count + 10, delimiter: .comma)
        XCTAssertNil(incomplete.table)
        XCTAssertEqual(incomplete.rawBytes, prefix)
        XCTAssertEqual(incomplete.diagnostics.map(\.code), [.truncated])
    }

    func testLimitsAndCancellationAreHonored() async throws {
        let bytes = Data(String(repeating: "a,", count: 32).utf8)
        let limited = try CSVInspector.inspect(bytes: bytes, fileSize: bytes.count, delimiter: .comma,
            limits: .init(maximumColumns: 8))
        XCTAssertNil(limited.table)
        XCTAssertEqual(limited.diagnostics.map(\.code), [.limitExceeded])

        let task = Task {
            try CSVInspector.inspect(bytes: Data(repeating: 97, count: 200_000), fileSize: 200_000,
                delimiter: .comma)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled inspection should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
