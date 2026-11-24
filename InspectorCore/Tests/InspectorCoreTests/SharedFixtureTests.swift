import Foundation
import XCTest
@testable import InspectorCore

final class SharedFixtureTests: XCTestCase {
    func testSensitiveFixtureBytesAndMissingPath() throws {
        let cases: [(String, [UInt8])] = [
            ("Cases/text/empty.txt", []), ("Cases/text/lf.txt", [111,110,101,10,116,119,111]),
            ("Cases/text/crlf.txt", [111,110,101,13,10,116,119,111,13,10]),
            ("Cases/text/utf8-bom.txt", [239,187,191,112,108,97,105,110]),
            ("Cases/text/utf16le.txt", [255,254,112,0,108,0]),
            ("Cases/json/invalid/invalid-utf8.json", [195,40,255]),
            ("Cases/binary/payload.json", [0,1,2]), ("Cases/binary/extensionless", [0,1,2,3,4])
        ]
        for (path, expected) in cases { XCTAssertEqual(try Data(contentsOf: fixtureURL(path)), Data(expected), path) }
        XCTAssertThrowsError(try fixtureURL("missing-fixture"))
    }

    func testSharedJSONRepresentatives() throws {
        for path in ["Cases/json/valid/simple.json", "Cases/json/valid/unicode.json", "Cases/json/valid/nested.json"] {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = try JSONInspector.inspect(bytes: bytes)
            XCTAssertNotNil(result.content, path)
            XCTAssertEqual(result.rawBytes, bytes)
            XCTAssertTrue(result.diagnostics.isEmpty, path)
        }
    }

    func testSharedYAMLRepresentatives() throws {
        for name in ["simple", "multi-document", "block-scalars", "aliases"] {
            let bytes = try Data(contentsOf: fixtureURL(name == "simple" ? "Showcase/yaml/yaml.yaml" : "Cases/yaml/valid/\(name).yaml"))
            let result = try YAMLInspector.inspect(bytes: bytes)
            XCTAssertTrue(result.diagnostics.isEmpty, name)
            XCTAssertNotNil(result.documents, name)
            XCTAssertEqual(result.rawBytes, bytes)
        }
        let bytes = try Data(contentsOf: fixtureURL("Cases/yaml/invalid/malformed.yaml"))
        let invalid = try YAMLInspector.inspect(bytes: bytes)
        XCTAssertNil(invalid.documents)
        XCTAssertEqual(invalid.rawBytes, bytes)
        XCTAssertEqual(invalid.diagnostics.first?.code, .parseError)
    }
}
