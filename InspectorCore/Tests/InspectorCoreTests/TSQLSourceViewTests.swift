import Foundation
import XCTest
@testable import InspectorCore

final class TSQLSourceViewTests: XCTestCase {
    func testDialectEvidenceRoutesToTSQLAndPreservesOriginalBytes() throws {
        let source = "DECLARE @limit int = 10;\nSELECT TOP (@limit) ISNULL(name, N'unknown') FROM dbo.Users;\nGO\n"
        let bytes = Data(source.utf8)
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: "query.sql", systemUTI: nil)

        XCTAssertEqual(result.formatDefinition?.id, .tsql)
        XCTAssertEqual(result.sourceDocument?.language, .tsql)
        XCTAssertEqual(result.sourceDocument?.source, source)
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertEqual(result.sourceDocument?.highlighting.runs.map { (source as NSString).substring(with: $0.range) }.filter { $0.lowercased() == "declare" || $0.lowercased() == "top" }, ["DECLARE", "TOP"])
        XCTAssertTrue(result.sourceDocument?.highlighting.runs.contains {
            $0.kind == .variable && (source as NSString).substring(with: $0.range) == "@limit"
        } ?? false)
    }

    func testTSQLFormatHasBoundedRawAndHexRepresentations() throws {
        let definition = try XCTUnwrap(FormatCatalog.definition(for: .tsql))
        XCTAssertEqual(definition.status, .supported)
        XCTAssertEqual(definition.extensions, ["tsql", "mssql"])
        XCTAssertEqual(definition.availableRepresentations, [.source, .raw, .hex])
        XCTAssertEqual(definition.defaultRepresentation, .source)
    }
}
