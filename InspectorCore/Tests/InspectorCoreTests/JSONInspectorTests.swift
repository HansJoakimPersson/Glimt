import Foundation
import XCTest
@testable import InspectorCore

final class JSONInspectorTests: XCTestCase {
    func testJSONRoutingUsesExistingEvidenceScoresWithoutContentSniffing() {
        let resolver = TypeResolver()
        let bytes = Data("{}".utf8)
        let byName = resolver.resolve(fileName: "sample.JSON", leadingBytes: bytes)
        XCTAssertEqual(byName.typeID, "json")
        XCTAssertEqual(byName.confidence.value, 0.95)
        let byUTI = resolver.resolve(fileName: "sample", leadingBytes: bytes, systemUTI: "public.json")
        XCTAssertEqual(byUTI.typeID, "json")
        XCTAssertEqual(byUTI.confidence.value, 0.60)
        XCTAssertEqual(resolver.resolve(fileName: "sample", leadingBytes: bytes).typeID, "unknown")
    }

    func testTypedTreePrettyAndExactOriginal() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/json/valid/nested.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        let result = try JSONInspector.inspect(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, text)
        XCTAssertTrue(result.rawIsComplete)
        XCTAssertTrue(result.diagnostics.isEmpty)
        guard case .object(let members) = result.content else { return XCTFail("Expected object") }
        XCTAssertEqual(members.map(\.key), ["a", "a"], "Duplicate keys and order are retained")
        XCTAssertEqual(members[0].value, .array([.boolean(true), .null, .number("9007199254740993"), .number("-1.25e+3"), .string("å\n🙂")]))
        let pretty = try XCTUnwrap(result.prettyText)
        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertEqual(try JSONInspector.inspect(bytes: Data(pretty.utf8)).content, result.content)
    }

    func testScalarsUnicodeAndEscapedDelimiters() throws {
        for source in ["true", "false", "null", "0", "-0", "1e-3", "\"\\uD83D\\uDE42\"", "{\"[{\\\"\":\"}\\n]\\t\"}", "[]", "{}"] {
            let result = try JSONInspector.inspect(bytes: Data(source.utf8))
            XCTAssertNotNil(result.content, source)
            XCTAssertTrue(result.diagnostics.isEmpty, source)
            _ = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.prettyText).utf8), options: [.fragmentsAllowed])
        }
    }

    func testMalformedInputRetainsRawAndNeverPretendsToHaveATree() throws {
        for source in [String(decoding: try Data(contentsOf: fixtureURL("Cases/json/invalid/malformed.json")), as: UTF8.self), String(decoding: try Data(contentsOf: fixtureURL("Cases/json/invalid/truncated.json")), as: UTF8.self), "", " ", "{", "[1,]", "{\"x\":1,}", "{x:1}", "01", "+1", "1.", "1e", "NaN", "true false", "\"\\x\"", "\"\\uD800\"", "\"line\nfeed\"", "[null"] {
            let bytes = Data(source.utf8)
            let result = try JSONInspector.inspect(bytes: bytes)
            XCTAssertNil(result.content, source)
            XCTAssertNil(result.prettyText, source)
            XCTAssertEqual(result.rawBytes, bytes)
            XCTAssertEqual(result.rawText, source)
            XCTAssertEqual(result.diagnostics.first?.code, .parseError, source)
        }
        XCTAssertNil(try JSONInspector.inspect(bytes: Data([0x22, 0xFF, 0x22])).content)
    }

    func testZONNotationFormatsAsJSONAndRetainsOriginalRaw() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/requested-formats/build.zon"))
        let result = try JSONInspector.inspectZON(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, String(decoding: bytes, as: UTF8.self))
        XCTAssertTrue(result.rawIsComplete)
        guard case .object(let fields) = result.content else { return XCTFail("Expected a JSON object") }
        XCTAssertEqual(fields.map(\.key), ["name", "version", "fingerprint", "paths"])
        XCTAssertEqual(fields[2].value, .number("4660"))
        XCTAssertEqual(fields[3].value, .array([.string("build.zig"), .string("build.zig.zon")]))
        XCTAssertTrue(try XCTUnwrap(result.prettyText).contains("\"fingerprint\": 4660"))

        let commentsAndEnum = Data(".{ .mode = .debug, .enabled = true, // comment\n .empty = .{}, }".utf8)
        let withComments = try JSONInspector.inspectZON(bytes: commentsAndEnum)
        guard case .object(let members) = withComments.content else { return XCTFail("Expected an object") }
        XCTAssertEqual(members[0].value, .string("debug"))
        XCTAssertEqual(members[1].value, .boolean(true))
        XCTAssertEqual(members[2].value, .object([]))
    }

    func testZONMalformedTruncatedAndOverBudgetInputStayRaw() throws {
        let malformed = try Data(contentsOf: fixtureURL("Cases/requested-formats/invalid/build.zon"))
        let invalid = try JSONInspector.inspectZON(bytes: malformed)
        XCTAssertNil(invalid.content)
        XCTAssertEqual(invalid.rawBytes, malformed)
        XCTAssertEqual(invalid.rawText, String(decoding: malformed, as: UTF8.self))
        XCTAssertEqual(invalid.diagnostics.first?.code, .parseError)

        let valid = Data(".{ .nested = .{ .value = 1 } }".utf8)
        let limited = try JSONInspector.inspectZON(bytes: valid, limits: .init(maximumDepth: 1))
        XCTAssertNil(limited.content)
        XCTAssertEqual(limited.diagnostics.first?.code, .limitExceeded)
        XCTAssertEqual(limited.rawBytes, valid)
        let emptyContainer = try JSONInspector.inspectZON(bytes: Data(".{}".utf8), limits: .init(maximumDepth: 0))
        XCTAssertNil(emptyContainer.content)
        XCTAssertEqual(emptyContainer.diagnostics.first?.code, .limitExceeded)

        let truncated = try JSONInspector.inspectZON(bytes: Data(".{ .name = \"sample\" }".utf8), fileSize: 100)
        XCTAssertNil(truncated.content)
        XCTAssertEqual(truncated.diagnostics.last?.code, .truncated)
        XCTAssertFalse(truncated.rawIsComplete)
    }

    func testIncompleteAndOversizedInputNeverParsesACompleteLookingPrefix() throws {
        let bytes = Data("{}".utf8)
        let truncated = try JSONInspector.inspect(bytes: bytes, fileSize: 20)
        XCTAssertNil(truncated.content)
        XCTAssertFalse(truncated.rawIsComplete)
        XCTAssertEqual(truncated.diagnostics.first?.code, .truncated)
        let bounded = try JSONInspector.inspect(bytes: Data("{} trailing".utf8), limits: .init(maximumBytes: 2))
        XCTAssertEqual(bounded.rawBytes, bytes)
        XCTAssertNil(bounded.content)
        XCTAssertFalse(bounded.rawIsComplete)
        XCTAssertTrue(bounded.diagnostics.contains { $0.code == .limitExceeded })
        let alreadyClipped = try JSONInspector.inspect(bytes: bytes, fileSize: 20, limits: .init(maximumBytes: 10))
        XCTAssertNil(alreadyClipped.content)
        XCTAssertTrue(alreadyClipped.diagnostics.contains { $0.code == .limitExceeded })
    }

    func testDepthValueAndOutputLimits() throws {
        for (source, limits) in [
            ("[[[]]]", JSONInspectionLimits(maximumDepth: 2)),
            ("[1,2]", .init(maximumValues: 2)),
            ("{\"key\":\"value\"}", .init(maximumOutputBytes: 3)),
            ("[]", .init(maximumDepth: 0)),
            ("null", .init(maximumValues: 0))
        ] {
            let result = try JSONInspector.inspect(bytes: Data(source.utf8), limits: limits)
            XCTAssertNil(result.content)
            XCTAssertNil(result.prettyText)
            XCTAssertEqual(result.diagnostics.first?.code, .limitExceeded, source)
            XCTAssertEqual(result.rawText, source)
        }
        XCTAssertNotNil(try JSONInspector.inspect(bytes: Data("[[[]]]".utf8), limits: .init(maximumDepth: 3)).content)
        let limits = JSONInspectionLimits(maximumBytes: .max, maximumDepth: .max, maximumValues: .max, maximumOutputBytes: .max)
        XCTAssertEqual(limits, .init())
    }

    func testBOMMarkedUnicodeKeepsOriginalBytesAndDecodedText() throws {
        let text = "{\"value\":\"café\"}\r\n"
        for bytes in [Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), Data([0xFF, 0xFE]) + (try XCTUnwrap(text.data(using: .utf16LittleEndian)))] {
            let result = try JSONInspector.inspect(bytes: bytes)
            XCTAssertEqual(result.rawBytes, bytes)
            XCTAssertEqual(result.rawText, text)
            XCTAssertNotNil(result.content)
        }
    }

    func testHostileDepthWidthAndCancellation() async throws {
        for source in [String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65),
                       String(repeating: "[", count: 100_000) + "0" + String(repeating: "]", count: 100_000),
                       "\"" + String(repeating: "a", count: 1_048_576) + "\"",
                       "[" + Array(repeating: "0", count: 10_001).joined(separator: ",") + "]"] {
            let result = try JSONInspector.inspect(bytes: Data(source.utf8))
            XCTAssertNil(result.content)
            XCTAssertEqual(result.diagnostics.first?.code, .limitExceeded)
        }
        let bytes = Data("[1,2,3]".utf8)
        let cancelled = await runCancelled { try JSONInspector.inspect(bytes: bytes) }
        XCTAssertThrowsError(try cancelled.get()) { XCTAssertTrue($0 is CancellationError) }
        // Formatting expands whitespace and escaping, but must not publish partial output.
        let expansion = try JSONInspector.inspect(bytes: Data("[\"\\u0000\",0]".utf8), limits: .init(maximumOutputBytes: 12))
        XCTAssertNil(expansion.prettyText)
        XCTAssertEqual(expansion.diagnostics.first?.code, .limitExceeded)
    }

    func testGenuineJSON() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["INSPECTORCORE_FR008_REAL_INPUT"] else {
            if environment["INSPECTORCORE_FR008_REQUIRE_REAL_INPUT"] == "1" {
                return XCTFail("Required genuine JSON input is missing")
            }
            throw XCTSkip("Genuine JSON input is not configured")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try JSONInspector.inspect(bytes: bytes)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, String(data: bytes, encoding: .utf8))
        guard case .object(let members) = result.content else { return XCTFail("Expected genuine object") }
        XCTAssertFalse(members.isEmpty)
        let original = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
        let pretty = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.prettyText).utf8)) as? NSDictionary
        XCTAssertNotNil(original)
        XCTAssertEqual(original, pretty)
    }
}
