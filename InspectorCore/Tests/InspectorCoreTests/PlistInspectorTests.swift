import Foundation
import XCTest
@testable import InspectorCore

final class PlistInspectorTests: XCTestCase {
    private func bytes(_ path: String) throws -> Data { try Data(contentsOf: fixtureURL(path)) }

    func testXMLAndBinaryCanonicalModelAndPrettyRoundTrip() throws {
        let xml = try bytes("Cases/plist/xml/simple.plist")
        let binary = try bytes("Showcase/plist/binary.plist")
        let first = try PlistInspector.inspect(bytes: xml)
        let second = try PlistInspector.inspect(bytes: binary)
        XCTAssertEqual(first.content, second.content)
        XCTAssertFalse(first.isBinary)
        XCTAssertTrue(second.isBinary)
        XCTAssertEqual(first.rawBytes, xml)
        XCTAssertEqual(first.rawText, String(data: xml, encoding: .utf8))
        XCTAssertEqual(second.rawBytes, binary)
        XCTAssertNil(second.rawText)
        XCTAssertTrue(first.diagnostics.isEmpty)
        XCTAssertTrue(second.diagnostics.isEmpty)
        guard case .dictionary(let members) = second.content else { return XCTFail("Expected dictionary") }
        XCTAssertEqual(members.map(\.key), ["count", "enabled", "name"])
        XCTAssertEqual(members.map(\.value), [.integer("42"), .boolean(true), .string("Glimt")])
        for result in [first, second] {
            let pretty = try XCTUnwrap(result.prettyText)
            XCTAssertEqual(try PlistInspector.inspect(bytes: Data(pretty.utf8)).content, result.content)
        }
    }

    func testOpenStepStringsDecompileToXMLAndKeepExactRawSource() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/requested-formats/localizable.strings"))
        let result = try PlistInspector.inspect(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        XCTAssertEqual(result.rawText, String(decoding: bytes, as: UTF8.self))
        XCTAssertNotNil(result.content)
        let pretty = try XCTUnwrap(result.prettyText)
        XCTAssertTrue(pretty.contains("<plist"))
        XCTAssertTrue(pretty.contains("Hello, \"world\"!"))
        XCTAssertNil(try PlistInspector.inspect(bytes: Data(contentsOf: fixtureURL("Cases/requested-formats/invalid/localizable.strings"))).content)

        let nested = Data("{ \"outer\" = { \"inner\" = \"value\"; }; }".utf8)
        let limited = try PlistInspector.inspect(bytes: nested, limits: .init(maximumDepth: 1))
        XCTAssertNil(limited.content)
        XCTAssertEqual(limited.diagnostics.first?.code, .limitExceeded)
        XCTAssertEqual(limited.rawBytes, nested)
    }

    func testAllTypesAndNestedStructures() throws {
        let result = try PlistInspector.inspect(bytes: bytes("Cases/plist/xml/all-types.plist"))
        guard case .dictionary(let members) = result.content else { return XCTFail("Expected all types") }
        let values = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
        XCTAssertEqual(values["string"], .string("Glimt"))
        XCTAssertEqual(values["integer"], .integer("-42"))
        XCTAssertEqual(values["real"], .real(3.5))
        XCTAssertEqual(values["boolean"], .boolean(true))
        XCTAssertEqual(values["data"], .data(Data([0, 1, 2, 255])))
        guard case .date(let date) = values["date"] else { return XCTFail("Expected date") }
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2026-01-02T03:04:05Z")
        XCTAssertEqual(values["array"], .array([.string("one"), .integer("2"), .boolean(false)]))
        XCTAssertNotNil(try PlistInspector.inspect(bytes: bytes("Showcase/plist/plist.plist")).content)
        let unsigned = try PropertyListSerialization.data(fromPropertyList: NSNumber(value: UInt64.max), format: .binary, options: 0)
        XCTAssertEqual(try PlistInspector.inspect(bytes: unsigned).content, .integer(String(UInt64.max)))
    }

    func testFormatProbeUsesContentAndSkipsGenericXML() throws {
        XCTAssertTrue(PlistInspector.looksLikePropertyList(bytes: try bytes("Cases/plist/xml/simple.plist")))
        XCTAssertTrue(PlistInspector.looksLikePropertyList(bytes: try bytes("Showcase/plist/binary.plist")))
        for text in ["<root><plist/></root>", "<!-- <plist> --><root/>", "ordinary words"] {
            XCTAssertFalse(PlistInspector.looksLikePropertyList(bytes: Data(text.utf8)))
        }
        let text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><plist version=\"1.0\"><string>å🙂</string></plist>"
        let utf16 = Data([255, 254]) + (try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        XCTAssertTrue(PlistInspector.looksLikePropertyList(bytes: utf16))
        XCTAssertEqual(try PlistInspector.inspect(bytes: utf16).content, .string("å🙂"))
    }

    func testMalformedAndTruncatedKeepRaw() throws {
        let malformed = try bytes("Cases/plist/invalid/malformed.plist")
        let result = try PlistInspector.inspect(bytes: malformed)
        XCTAssertNil(result.content)
        XCTAssertNil(result.prettyText)
        XCTAssertEqual(result.rawBytes, malformed)
        XCTAssertEqual(result.diagnostics.first?.code, .parseError)
        let incomplete = try PlistInspector.inspect(bytes: Data("<plist/>".utf8), fileSize: 100)
        XCTAssertNil(incomplete.content)
        XCTAssertFalse(incomplete.rawIsComplete)
        XCTAssertEqual(incomplete.diagnostics.first?.code, .truncated)
    }

    func testLimitsAndEntitiesFailBeforeNativeExpansion() throws {
        let deep = "<plist>" + String(repeating: "<array>", count: 65) + "<string>x</string>" + String(repeating: "</array>", count: 65) + "</plist>"
        let entity = "<!DOCTYPE plist [<!ENTITY x 'expanded'>]><plist><string>&x;</string></plist>"
        let external = "<!DOCTYPE plist SYSTEM 'file:///etc/passwd'><plist><string>x</string></plist>"
        for source in [deep, entity, external] {
            let result = try PlistInspector.inspect(bytes: Data(source.utf8))
            XCTAssertNil(result.content)
            XCTAssertEqual(result.rawText, source)
            XCTAssertFalse(result.diagnostics.isEmpty)
        }
        for limits in [StructuredInspectionLimits(maximumValues: 2), .init(maximumOutputBytes: 10), .init(maximumBytes: 10)] {
            let result = try PlistInspector.inspect(bytes: bytes("Cases/plist/xml/simple.plist"), limits: limits)
            XCTAssertNil(result.content)
            XCTAssertTrue(result.diagnostics.contains { $0.code == .limitExceeded })
        }
    }

    func testBinaryGraphCyclesSharedExpansionAndTrailerLimits() throws {
        // Object zero is an array whose single reference points back to itself.
        var cyclic = Data("bplist00".utf8) + Data([0xA1, 0x00, 0x08])
        cyclic += Data(repeating: 0, count: 6) + Data([1, 1])
        cyclic += be(1) + be(0) + be(10)
        let result = try PlistInspector.inspect(bytes: cyclic)
        XCTAssertNil(result.content)
        XCTAssertTrue(result.isBinary)
        XCTAssertEqual(result.rawBytes, cyclic)
        var excessive = try bytes("Showcase/plist/binary.plist")
        excessive.replaceSubrange((excessive.count - 24)..<(excessive.count - 16), with: be(UInt64.max))
        XCTAssertNil(try PlistInspector.inspect(bytes: excessive).content)
        // Four arrays share the preceding array ten times: actual expansion exceeds the node cap.
        var objects = Data([0x51, 0x78])
        var offsets: [UInt8] = [8]
        for index in 1...5 {
            offsets.append(UInt8(8 + objects.count))
            objects += Data([0xAA]) + Data(repeating: UInt8(index - 1), count: 10)
        }
        var bomb = Data("bplist00".utf8) + objects
        let table = bomb.count
        bomb += Data(offsets)
        bomb += Data(repeating: 0, count: 6) + Data([1, 1]) + be(6) + be(5) + be(UInt64(table))
        XCTAssertEqual(try PlistInspector.inspect(bytes: bomb).diagnostics.first?.code, .limitExceeded)
        let repeated = Data(repeating: 120, count: 65_536)
        var payloadBomb = Data("bplist00".utf8) + Data([0x4F, 0x12, 0, 1, 0, 0]) + repeated
        let arrayOffset = payloadBomb.count
        payloadBomb += Data([0xAF, 0x10, 64]) + Data(repeating: 0, count: 64)
        let payloadTable = payloadBomb.count
        payloadBomb += be(8).suffix(4) + be(UInt64(arrayOffset)).suffix(4)
        payloadBomb += Data(repeating: 0, count: 6) + Data([4, 1]) + be(2) + be(1) + be(UInt64(payloadTable))
        XCTAssertEqual(try PlistInspector.inspect(bytes: payloadBomb).diagnostics.first?.code, .limitExceeded)
    }

    func testFractionalDateKeepsTreeAndRawWithoutLossyPretty() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1.25)
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["date": date], format: .binary, options: 0)
        let result = try PlistInspector.inspect(bytes: bytes)
        XCTAssertEqual(result.rawBytes, bytes)
        guard case .dictionary(let members) = result.content else { return XCTFail("Expected date dictionary") }
        XCTAssertEqual(members.first?.value, .date(date))
        XCTAssertNil(result.prettyText)
        XCTAssertEqual(result.diagnostics.first?.code, .unsupported)
    }

    func testCancellationPropagates() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PlistInspector.inspect(bytes: Data("<plist><string>x</string></plist>".utf8))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func be(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
}
