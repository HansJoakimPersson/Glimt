import Foundation
import XCTest
@testable import InspectorCore

final class SQLiteTARFormatTests: XCTestCase {
    func testSQLiteReadsSchemaOnlyAndSupportsMagicByteRouting() throws {
        let url = try fixtureURL("Showcase/data/inventory.sqlite")
        let before = try Data(contentsOf: url)
        let inspection = try PreviewInspectionResult.read(at: url)

        XCTAssertEqual(inspection.formatDefinition?.id, .sqlite)
        XCTAssertEqual(inspection.detectionReason, "fileExtension")
        XCTAssertEqual(inspection.originalBytes, before)
        XCTAssertTrue(inspection.additionalInspection?.securityInspection?.summary.contains("row data not read") == true)
        guard case .object(let members) = inspection.additionalStructuredContent,
              case .array(let schema)? = members.first(where: { $0.key == "Schema" })?.value else {
            return XCTFail("Expected SQLite schema tree")
        }
        XCTAssertEqual(schema.count, 2)
        XCTAssertFalse(String(describing: inspection.additionalStructuredContent).contains("sample row value"))
        XCTAssertEqual(try Data(contentsOf: url), before, "Inspection must not modify the database")

        let renamed = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtSQLiteMagic-\(UUID().uuidString).db")
        try before.write(to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }
        let magicRouted = try PreviewInspectionResult.read(at: renamed, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(magicRouted.formatDefinition?.id, .sqlite)
        XCTAssertEqual(magicRouted.detectionReason, "magicBytes")
        XCTAssertNotNil(magicRouted.additionalStructuredContent)
    }

    func testSQLiteBadAndTruncatedFilesKeepRawRecovery() throws {
        let url = try fixtureURL("Cases/sqlite/invalid/truncated.sqlite")
        let bytes = try Data(contentsOf: url)
        let inspection = try PreviewInspectionResult.read(at: url)
        XCTAssertEqual(inspection.formatDefinition?.id, .sqlite)
        XCTAssertEqual(inspection.originalBytes, bytes)
        XCTAssertNotNil(inspection.inspectionDiagnostics.first)
        XCTAssertNil(inspection.additionalStructuredContent)
    }

    func testTARAndGzipTARProduceOrderedMetadataWithoutPayloads() throws {
        let plainURL = try fixtureURL("Showcase/data/inventory.tar")
        let plain = try PreviewInspectionResult.read(at: plainURL)
        XCTAssertEqual(plain.formatDefinition?.id, .tarArchive)
        XCTAssertEqual(plain.additionalInspection?.tarArchiveListing?.entries.map(\.displayName), ["csv.csv"])
        XCTAssertFalse(plain.additionalInspection?.tarArchiveListing?.isGzipped ?? true)

        let gzipURL = try fixtureURL("Cases/tar/valid/compressed.tar.gz")
        let gzip = try PreviewInspectionResult.read(at: gzipURL)
        XCTAssertEqual(gzip.formatDefinition?.id, .tarArchive)
        XCTAssertEqual(gzip.additionalInspection?.tarArchiveListing?.entries.map(\.displayName), ["csv.csv"])
        XCTAssertTrue(gzip.additionalInspection?.tarArchiveListing?.isGzipped == true)
        let csvSize = try Data(contentsOf: fixtureURL("Showcase/data/csv.csv")).count
        XCTAssertEqual(gzip.additionalInspection?.tarArchiveListing?.entries.first?.size, UInt64(csvSize))
    }

    func testTARRejectsBrokenChecksumAndPreservesRaw() throws {
        let url = try fixtureURL("Cases/tar/invalid/bad-checksum.tar")
        let inspection = try PreviewInspectionResult.read(at: url)
        XCTAssertEqual(inspection.formatDefinition?.id, .tarArchive)
        XCTAssertNil(inspection.additionalInspection?.tarArchiveListing)
        XCTAssertTrue(inspection.inspectionDiagnostics.contains { [.parseError, .unsupported, .truncated].contains($0.code) })
    }
}
