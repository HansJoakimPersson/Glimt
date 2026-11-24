import Foundation
import XCTest
@testable import InspectorCore

final class GeoJSONInspectorTests: XCTestCase {
    func testFeatureCollectionShowsFeatureNamesGeometryCountsAndBounds() throws {
        let url = try fixtureURL("Showcase/geospatial/countries.geojson")
        let bytes = try Data(contentsOf: url)
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })

        XCTAssertEqual(result.formatDefinition?.id, .geojson)
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertEqual(result.jsonInspection?.rawText, String(decoding: bytes, as: UTF8.self))
        guard case .object(let members)? = result.jsonInspection?.domainSummary,
              case .array(let features)? = members.first(where: { $0.key == "Features" })?.value else {
            return XCTFail("Expected GeoJSON feature summary")
        }
        XCTAssertEqual(members.first(where: { $0.key == "Feature count" })?.value, .number("2"))
        XCTAssertEqual(features.count, 2)
        guard case .object(let first)? = features.first,
              case .object(let geometry)? = first.first(where: { $0.key == "Geometry" })?.value,
              case .object(let bounds)? = geometry.first(where: { $0.key == "Bounds" })?.value else {
            return XCTFail("Expected summarized polygon and bounds")
        }
        XCTAssertEqual(first.first(where: { $0.key == "Name" })?.value, .string("Harbor Island"))
        XCTAssertEqual(geometry.first(where: { $0.key == "Coordinate count" })?.value, .number("4"))
        XCTAssertEqual(bounds.first(where: { $0.key == "West" })?.value, .number("18.0"))
    }

    func testMalformedAndUnsupportedGeoJSONKeepsJSONWithoutPartialSummary() throws {
        let malformedURL = try fixtureURL("Cases/geospatial/invalid/malformed.geojson")
        let malformed = try PreviewInspectionResult.read(at: malformedURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(malformed.formatDefinition?.id, .geojson)
        XCTAssertNil(malformed.jsonInspection?.domainSummary)
        XCTAssertTrue(malformed.inspectionDiagnostics.contains { $0.code == .unsupported })

        let wrongRootText = #"{"type":"NotGeoJSON","value":42}"#
        let wrongRoot = PreviewInspectionResult.prepare(bytes: Data(wrongRootText.utf8),
            fileSize: wrongRootText.utf8.count, fileName: "unknown.geojson", systemUTI: nil)
        XCTAssertNil(wrongRoot.jsonInspection?.domainSummary)
        XCTAssertNotNil(wrongRoot.jsonInspection?.content)
        XCTAssertTrue(wrongRoot.inspectionDiagnostics.contains { $0.code == .unsupported })

        let outOfRangeText = #"{"type":"Point","coordinates":[181,0]}"#
        let outOfRange = PreviewInspectionResult.prepare(bytes: Data(outOfRangeText.utf8),
            fileSize: outOfRangeText.utf8.count, fileName: "invalid.geojson", systemUTI: nil)
        XCTAssertNil(outOfRange.jsonInspection?.domainSummary)
        XCTAssertTrue(outOfRange.inspectionDiagnostics.contains { $0.code == .unsupported })
    }
}
