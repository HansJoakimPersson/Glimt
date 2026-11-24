import XCTest
@testable import InspectorCore

final class ConfigurationInspectorTests: XCTestCase {
    func testTOMLSubsetRetainsSectionsAndRejectsRepeatedOrUnsupportedStructures() throws {
        let result = try ConfigurationInspector.inspect("title = \"Glimt\"\n[preview]\nlimit = 3\nlimit = 4\n[[items]]\n", dialect: .toml)
        XCTAssertEqual(result.entries.map(\.key), ["title", "limit", "limit"])
        XCTAssertEqual(result.entries.first?.value, "Glimt")
        XCTAssertEqual(result.entries[1].section, "preview")
        XCTAssertTrue(result.diagnostics.contains { $0.code == .parseError })
        XCTAssertTrue(result.diagnostics.contains { $0.code == .unsupported })
    }

    func testINIDotenvAndPropertiesKeepOrderAndDialectDetails() throws {
        let ini = try ConfigurationInspector.inspect("[a]\nx=1\nx=2\n", dialect: .ini)
        XCTAssertEqual(ini.entries.map(\.value), ["1", "2"])
        XCTAssertTrue(ini.diagnostics.contains { $0.code == .unsupported })

        let dotenv = try ConfigurationInspector.inspect("export TOKEN='safe value'\nTOKEN=next\n", dialect: .dotenv)
        XCTAssertEqual(dotenv.entries.map(\.key), ["TOKEN", "TOKEN"])
        XCTAssertEqual(dotenv.entries[0].value, "safe value")
        XCTAssertEqual(dotenv.diagnostics.count, 1)

        let properties = try ConfigurationInspector.inspect("name=Glimt\\\n  Preview\nunicode=\\u263A\n", dialect: .javaProperties)
        XCTAssertEqual(properties.entries.map(\.value), ["GlimtPreview", "☺"])
        XCTAssertTrue(properties.diagnostics.isEmpty)
    }

    func testLimitAndCancellationAreBounded() async throws {
        let limited = try ConfigurationInspector.inspect("a=1\nb=2", dialect: .ini, maximumLines: 1)
        XCTAssertFalse(limited.rawIsComplete)
        let gate = InspectionStartGate()
        let task = Task {
            await gate.wait()
            return try ConfigurationInspector.inspect("a=1", dialect: .ini)
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
    }

    func testMalformedPropertiesUnicodeEscapesAreDiagnosedAndSkipped() throws {
        let source = "ok=\\u263A\nbad=\\u12XZ\nshort=\\u12\n\\u12Q4=value\n"
        let result = try ConfigurationInspector.inspect(source, dialect: .javaProperties)
        XCTAssertEqual(result.entries.map(\.key), ["ok"])
        XCTAssertEqual(result.entries.first?.value, "☺")
        XCTAssertEqual(result.diagnostics.filter { $0.code == .parseError }.count, 3)

        let bytes = Data(source.utf8)
        let preview = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "malformed.properties", systemUTI: nil, formatOverride: .properties)
        XCTAssertEqual(preview.originalBytes, bytes)
        XCTAssertEqual(preview.analysis.text, source)
        XCTAssertTrue(preview.inspectionDiagnostics.contains { $0.code == .parseError })
    }
}

private actor InspectionStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
