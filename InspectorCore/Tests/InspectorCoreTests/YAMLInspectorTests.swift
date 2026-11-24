import Foundation
import XCTest
@testable import InspectorCore

final class YAMLInspectorTests: XCTestCase {
    func testGenuineYAML() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["INSPECTORCORE_FR009_REAL_INPUT"] else {
            if environment["INSPECTORCORE_FR009_REQUIRE_REAL_INPUT"] == "1" {
                return XCTFail("Required genuine YAML is missing")
            }
            throw XCTSkip("Genuine YAML is not configured")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try YAMLInspector.inspect(bytes: bytes)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, String(data: bytes, encoding: .utf8))
        XCTAssertEqual(result.documents?.count, 1)
        guard case .object(let members) = result.documents?.first else { return XCTFail("Expected workflow mapping") }
        XCTAssertEqual(members.first { $0.key == "name" }?.value, .string("SwiftPM"))
        XCTAssertNotNil(members.first { $0.key == "jobs" })
        XCTAssertEqual(try YAMLInspector.inspect(bytes: Data(try XCTUnwrap(result.prettyText).utf8)).documents, result.documents)
    }

    func testEmptyUnicodeAndScalarTypes() throws {
        let empty = try YAMLInspector.inspect(bytes: Data())
        XCTAssertEqual(empty.documents, [])
        XCTAssertEqual(empty.prettyText, "")
        let source = "text: \"true\"\nflag: true\ninteger: 0xFF\nvalue: null\nbody: >\n  first\n  second\n"
        let bytes = Data([0xFF, 0xFE]) + (try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        let result = try YAMLInspector.inspect(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, source)
        guard case .object(let members) = result.documents?.first else { return XCTFail("Expected mapping") }
        XCTAssertEqual(members.first { $0.key == "text" }?.value, .string("true"))
        XCTAssertEqual(members.first { $0.key == "flag" }?.value, .boolean(true))
        XCTAssertEqual(members.first { $0.key == "integer" }?.value, .number("0xFF"))
        XCTAssertEqual(members.first { $0.key == "value" }?.value, .null)
        XCTAssertEqual(members.first { $0.key == "body" }?.value, .string("first second\n"))
    }

    func testCancellationAndUnsupportedKeys() async throws {
        let bytes = Data("a: 1\n".utf8)
        let cancelled = await runCancelled { try YAMLInspector.inspect(bytes: bytes) }
        XCTAssertThrowsError(try cancelled.get()) { XCTAssertTrue($0 is CancellationError) }
        let complex = try YAMLInspector.inspect(bytes: Data("? [a, b]\n: value\n".utf8))
        XCTAssertEqual(complex.diagnostics.first?.code, .unsupported)
        XCTAssertNil(complex.documents)
    }

    func testMultipleDocumentsAndBlockScalarsPreserveRaw() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/yaml/valid/multi-document.yaml"))
        let source = String(decoding: bytes, as: UTF8.self)
        let result = try YAMLInspector.inspect(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, source)
        XCTAssertTrue(result.rawIsComplete)
        XCTAssertTrue(result.diagnostics.isEmpty)
        let documents = try XCTUnwrap(result.documents)
        XCTAssertEqual(documents.count, 3)
        guard case .object(let members) = documents[0] else { return XCTFail("Expected mapping") }
        XCTAssertEqual(members.first { $0.key == "body" }?.value, .string("line one\nline two\n"))
        guard case .object(let second) = documents[1] else { return XCTFail("Expected second mapping") }
        XCTAssertEqual(second.first?.value, .array([.boolean(true), .null, .number("2")]))
        let pretty = try XCTUnwrap(result.prettyText)
        XCTAssertEqual(try YAMLInspector.inspect(bytes: Data(pretty.utf8)).documents, documents)
    }

    func testOrdinaryAliasesRemainBoundedAndReadable() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/yaml/valid/aliases.yaml"))
        let result = try YAMLInspector.inspect(bytes: bytes)
        guard case .object(let members) = result.documents?.first else { return XCTFail("Expected mapping") }
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].value, members[1].value)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testAliasBombAndResourceLimitsKeepRaw() throws {
        var bomb = "a: &a [x, x, x, x, x, x, x, x, x, x]\n"
        for level in 1...8 {
            let current = String(UnicodeScalar(97 + level) ?? "a")
            let previous = String(UnicodeScalar(96 + level) ?? "a")
            bomb += "\(current): &\(current) [" + Array(repeating: "*\(previous)", count: 10).joined(separator: ", ") + "]\n"
        }
        for (source, limits, documents) in [
            (bomb, JSONInspectionLimits(), 64),
            (String(repeating: "[", count: 100_000) + "0" + String(repeating: "]", count: 100_000), .init(), 64),
            ("a: [1, 2, 3]\n", .init(maximumValues: 3), 64),
            ("---\na: 1\n---\nb: 2\n", .init(), 1),
            ("a: some text\n", .init(maximumOutputBytes: 2), 64)
        ] {
            let result = try YAMLInspector.inspect(bytes: Data(source.utf8), limits: limits, maximumDocuments: documents)
            XCTAssertNil(result.documents)
            XCTAssertNil(result.prettyText)
            XCTAssertEqual(result.rawText, source)
            XCTAssertEqual(result.diagnostics.first?.code, .limitExceeded)
        }
    }

    func testMalformedAndIncompleteInputDoNotMasqueradeAsCompleteDocuments() throws {
        for source in ["a: [1, 2\n", "a: *missing\n", "a: &self [*self]\n", "a: 1\na: 2\n", "a: \"unfinished\n"] {
            let result = try YAMLInspector.inspect(bytes: Data(source.utf8))
            XCTAssertNil(result.documents, source)
            XCTAssertFalse(result.diagnostics.isEmpty, source)
            XCTAssertEqual(result.rawText, source)
        }
        let incomplete = try YAMLInspector.inspect(bytes: Data("a: 1\n".utf8), fileSize: 100)
        XCTAssertFalse(incomplete.rawIsComplete)
        XCTAssertNil(incomplete.documents)
        XCTAssertTrue(incomplete.diagnostics.contains { $0.code == .truncated })
        let clipped = try YAMLInspector.inspect(bytes: Data("a: 1\n".utf8), limits: .init(maximumBytes: 2))
        XCTAssertEqual(clipped.rawBytes.count, 2)
        XCTAssertNil(clipped.documents)
        XCTAssertTrue(clipped.diagnostics.contains { $0.code == .limitExceeded })
    }
}
