import XCTest
@testable import InspectorCore

final class WindowsRegistryInspectorTests: XCTestCase {
    func testParsesRegistryHeaderKeysAndTypedValuesWithoutApplyingThem() throws {
        let source = """
        Windows Registry Editor Version 5.00

        ; exported example
        [HKEY_CURRENT_USER\\Software\\Glimt]
        @="Default value"
        "Enabled"=dword:00000001
        "Name"="Preview"
        "Binary"=hex:01,02,\\
          03,04
        [-HKEY_CURRENT_USER\\Software\\Glimt\\Old]
        """

        let result = try WindowsRegistryInspector.inspect(source)
        XCTAssertEqual(result.entries.map(\.keyPath), [
            "HKEY_CURRENT_USER\\Software\\Glimt",
            "HKEY_CURRENT_USER\\Software\\Glimt",
            "HKEY_CURRENT_USER\\Software\\Glimt",
            "HKEY_CURRENT_USER\\Software\\Glimt",
            "HKEY_CURRENT_USER\\Software\\Glimt\\Old"
        ])
        XCTAssertEqual(result.entries.map(\.name), ["(Default)", "Enabled", "Name", "Binary", "(key)"])
        XCTAssertEqual(result.entries.map(\.kind), ["string", "dword", "string", "hex", "delete-key"])
        XCTAssertEqual(result.entries.map(\.data), ["Default value", "00000001", "Preview", "01,02,03,04", ""])
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.rawIsComplete)
    }

    func testRejectsInvalidHeaderAndReportsMalformedRecords() throws {
        let invalidHeader = try WindowsRegistryInspector.inspect("not a registry export\n")
        XCTAssertTrue(invalidHeader.diagnostics.contains { $0.code == .unsupported })
        let malformed = try WindowsRegistryInspector.inspect(
            "REGEDIT4\n[HKEY_CURRENT_USER\\Software\\Glimt]\nmissing delimiter\n")
        XCTAssertTrue(malformed.entries.isEmpty)
        XCTAssertTrue(malformed.diagnostics.contains { $0.code == .parseError })
    }

    func testTruncatedExportRetainsParsedFactsAndMarksResultIncomplete() throws {
        let result = try WindowsRegistryInspector.inspect(
            "REGEDIT4\n[HKEY_CURRENT_USER\\Software\\Glimt]\n\"One\"=\"1\"\n",
            isComplete: false
        )
        XCTAssertEqual(result.entries.map(\.name), ["One"])
        XCTAssertFalse(result.rawIsComplete)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .truncated })
    }

    func testUTF16LERegistryExportIsDetectedAndRenderedWithoutChangingOriginalBytes() throws {
        let source = "Windows Registry Editor Version 5.00\n[HKEY_CURRENT_USER\\Software\\Glimt]\n\"Enabled\"=dword:00000001\n"
        let payload = try XCTUnwrap(source.data(using: .utf16LittleEndian))
        let bytes = Data([0xFF, 0xFE]) + payload
        let preview = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "settings.reg", systemUTI: nil)

        XCTAssertEqual(preview.analysis.encoding, .utf16LittleEndian)
        XCTAssertEqual(preview.originalBytes, bytes)
        XCTAssertEqual(preview.formatDefinition?.id, .windowsRegistry)
        XCTAssertFalse(preview.statusSummary.items.contains { $0.kind == .warning })
    }
}
