import Foundation
import XCTest
@testable import InspectorCore

final class RequestedFormatCoverageTests: XCTestCase {
    func testSharedSuffixesAndBinarySourceCases() throws {
        for path in ["Cases/requested-formats/eiffel/shared.ex", "Cases/requested-formats/eiffel/shared.exs"] {
            let result = try PreviewInspectionResult.read(at: fixtureURL(path), contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.sourceDocument?.language, .eiffel, path)
            XCTAssertEqual(result.formatDefinition?.id, .eiffel, path)
        }
        let elixirURL = try fixtureURL("Cases/requested-formats/elixir/script.exs")
        let elixir = try PreviewInspectionResult.read(at: elixirURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(elixir.sourceDocument?.language, .elixir)
        XCTAssertEqual(elixir.formatDefinition?.id, .elixir)

        for filename in ["binary.d", "binary.bat", "binary.dylan", "binary.e", "binary.ex", "binary.erl"] {
            let bytes = Data([0, 1, 2, 3])
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: filename, systemUTI: nil)
            XCTAssertTrue(result.analysis.isBinary, filename)
            XCTAssertNil(result.sourceDocument, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
        }
    }

    func testMalformedXMLRetainsRawAndDTDNeverEntersXMLParser() throws {
        let malformedURL = try fixtureURL("Cases/requested-formats/xml/malformed.designspace")
        let malformedBytes = try Data(contentsOf: malformedURL)
        let malformed = try PreviewInspectionResult.read(at: malformedURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(malformed.formatDefinition?.id, .xml)
        XCTAssertNil(malformed.xmlInspection?.root)
        XCTAssertEqual(malformed.originalBytes, malformedBytes)
        XCTAssertTrue(malformed.analysis.text.contains("<designspace>"))

        let externalDTDURL = try fixtureURL("Cases/requested-formats/xml/external.dtd")
        let dtd = try PreviewInspectionResult.read(at: externalDTDURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(dtd.formatDefinition?.id, .dtd)
        XCTAssertNil(dtd.xmlInspection)
        XCTAssertTrue(dtd.analysis.text.contains("https://example.invalid/external.dtd"))
    }

    func testDockerfileAndHEExUseFaithfulRawTextAndEnvUsesDotenv() throws {
        let dockerURL = try fixtureURL("Showcase/build/dockerfile.dockerfile")
        let dockerBytes = try Data(contentsOf: dockerURL)
        let docker = try PreviewInspectionResult.read(at: dockerURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(docker.formatDefinition?.id.rawValue, "dockerfile")
        XCTAssertEqual(docker.analysis.text, String(decoding: dockerBytes, as: UTF8.self))
        XCTAssertEqual(docker.formatDefinition?.availableRepresentations, [.source, .raw, .hex])
        XCTAssertEqual(docker.sourceDocument?.language, .dockerfile)

        let heexURL = try fixtureURL("Cases/requested-formats/elixir/template.heex")
        let heexBytes = try Data(contentsOf: heexURL)
        let heex = try PreviewInspectionResult.read(at: heexURL, contentTypeIdentifier: { _ in nil })
        XCTAssertNil(heex.sourceDocument)
        XCTAssertEqual(heex.analysis.text, String(decoding: heexBytes, as: UTF8.self))

        let envURL = try fixtureURL("Cases/requested-formats/ini/duplicate.env")
        let env = try PreviewInspectionResult.read(at: envURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(env.formatDefinition?.id, .dotenv)
        XCTAssertNil(env.sourceDocument)
        XCTAssertNotNil(env.additionalStructuredContent)
        let exactEnvURL = try fixtureURL("Cases/requested-formats/ini/.env")
        let exactEnv = try PreviewInspectionResult.read(at: exactEnvURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(exactEnv.formatDefinition?.id, .dotenv)

        let diffURL = try fixtureURL("Cases/requested-formats/diff/changes.diff")
        let diff = try PreviewInspectionResult.read(at: diffURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(diff.formatDefinition?.id, .diff)
        XCTAssertEqual(diff.diffInspection?.addedLineCount, 1)
        XCTAssertNil(FormatCatalog.match(fileName: "main.dart"))
    }
}
