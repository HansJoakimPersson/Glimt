import Foundation
import XCTest
@testable import InspectorCore

final class GeospatialXMLInspectorTests: XCTestCase {
    func testKMLUsesGeospatialSummaryAndKeepsXMLSource() throws {
        let url = try fixtureURL("Showcase/geospatial/places.kml")
        let bytes = try Data(contentsOf: url)
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })

        XCTAssertEqual(result.formatDefinition?.id, .kml)
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertNotNil(result.xmlInspection?.root)
        XCTAssertEqual(result.xmlInspection?.rawText, String(decoding: bytes, as: UTF8.self))
        guard case .object(let members)? = result.xmlInspection?.domainSummary,
              case .array(let features)? = members.first(where: { $0.key == "Features" })?.value else {
            return XCTFail("Expected KML feature summary")
        }
        XCTAssertEqual(features.count, 2)
        guard case .object(let first)? = features.first else { return XCTFail("Expected placemark") }
        XCTAssertEqual(first.first(where: { $0.key == "Name" })?.value, .string("Town Hall"))
        XCTAssertEqual(first.first(where: { $0.key == "Coordinate count" })?.value, .number("1"))
    }

    func testGPXSummarizesWaypointsRoutesAndTracksWithoutResolvingLinks() throws {
        let url = try fixtureURL("Showcase/geospatial/route.gpx")
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })

        XCTAssertEqual(result.formatDefinition?.id, .gpx)
        XCTAssertFalse(result.inspectionDiagnostics.contains { $0.code == .parseError })
        guard case .object(let members)? = result.xmlInspection?.domainSummary,
              case .array(let waypoints)? = members.first(where: { $0.key == "Waypoints" })?.value,
              case .array(let routes)? = members.first(where: { $0.key == "Routes" })?.value,
              case .array(let tracks)? = members.first(where: { $0.key == "Tracks" })?.value else {
            return XCTFail("Expected GPX summary")
        }
        XCTAssertEqual(waypoints.count, 1)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(tracks.count, 1)
        guard case .object(let route)? = routes.first,
              case .object(let bounds)? = route.first(where: { $0.key == "Bounds" })?.value else {
            return XCTFail("Expected route bounds")
        }
        XCTAssertEqual(bounds.first(where: { $0.key == "South" })?.value, .number("59.3293"))
    }

    func testMalformedAndWrongRootGeospatialXMLNeverPublishesSummary() throws {
        for path in ["Cases/geospatial/invalid/malformed.kml", "Cases/geospatial/invalid/malformed.gpx"] {
            let result = try PreviewInspectionResult.read(at: fixtureURL(path), contentTypeIdentifier: { _ in nil })
            XCTAssertNil(result.xmlInspection?.domainSummary, path)
            XCTAssertFalse(result.inspectionDiagnostics.isEmpty, path)
        }

        let wrongRoot = PreviewInspectionResult.prepare(bytes: Data("<root/>".utf8), fileSize: 7,
                                                        fileName: "places.kml", systemUTI: nil)
        XCTAssertNil(wrongRoot.xmlInspection?.domainSummary)
        XCTAssertTrue(wrongRoot.inspectionDiagnostics.contains { $0.code == .unsupported })

        let invalidCoordinateXML = #"<gpx version="1.1"><wpt lat="91" lon="0"/></gpx>"#
        let invalidCoordinate = PreviewInspectionResult.prepare(bytes: Data(invalidCoordinateXML.utf8),
            fileSize: invalidCoordinateXML.utf8.count, fileName: "invalid.gpx", systemUTI: nil)
        XCTAssertNil(invalidCoordinate.xmlInspection?.domainSummary)
        XCTAssertTrue(invalidCoordinate.inspectionDiagnostics.contains { $0.code == .unsupported })
    }
}
