import Foundation
import XCTest
@testable import InspectorCore

final class ConfigurationSyntaxTests: XCTestCase {
    func testValidAndEdgeFixturesAreDetectedAndHighlightedByTheirFormat() throws {
        let fixtures: [(String, FormatID, SourceLanguage?)] = [
            ("Cases/config/toml/valid/features.toml", .toml, .toml),
            ("Cases/config/toml/edge/lexical-cases.toml", .toml, .toml),
            ("Cases/config/ini/valid/features.ini", .ini, .ini),
            ("Cases/config/ini/edge/lexical-cases.ini", .ini, .ini),
            ("Cases/config/dotenv/valid/features.env", .dotenv, nil),
            ("Cases/config/dotenv/edge/lexical-cases.env", .dotenv, nil),
            ("Cases/config/properties/valid/features.properties", .properties, .properties),
            ("Cases/config/properties/edge/lexical-cases.properties", .properties, .properties)
        ]

        var tokenKindsByLanguage: [SourceLanguage: Set<SyntaxTokenKind>] = [:]
        for (path, formatID, language) in fixtures {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: (path as NSString).lastPathComponent, systemUTI: nil)
            XCTAssertEqual(inspection.formatDefinition?.id, formatID, path)
            if let language {
                let source = try XCTUnwrap(inspection.sourceDocument, path)
                XCTAssertEqual(source.language, language, path)
                XCTAssertEqual(source.source, inspection.analysis.text, path)
                XCTAssertTrue(source.highlighting.runs.contains { $0.kind == .type }, "Keys or sections are highlighted: \(path)")
                XCTAssertTrue(source.highlighting.runs.contains { $0.kind == .comment }, "Comments are highlighted: \(path)")
                XCTAssertFalse(source.diagnostics.contains { $0.code == .limitExceeded }, path)
                tokenKindsByLanguage[language, default: []].formUnion(source.highlighting.runs.map(\.kind))
            } else {
                XCTAssertNotNil(inspection.additionalStructuredContent, path)
                XCTAssertEqual(inspection.originalBytes, bytes, path)
            }
        }

        XCTAssertTrue(tokenKindsByLanguage[.toml]?.isSuperset(of: [.string, .number, .keyword]) == true)
        XCTAssertTrue(tokenKindsByLanguage[.ini]?.isSuperset(of: [.string, .number, .keyword]) == true)
        XCTAssertTrue(tokenKindsByLanguage[.properties]?.contains(.number) == true)

        let dotenvTokens = try InternalSyntaxHighlighter().highlight("KEY=42 # comment\n", language: .dotenv).runs
        XCTAssertTrue(dotenvTokens.contains { $0.kind == .type })
        XCTAssertTrue(dotenvTokens.contains { $0.kind == .number })
        XCTAssertTrue(dotenvTokens.contains { $0.kind == .comment })
    }

    func testDotenvUsesItsOwnCatalogRouteAndStructuredView() throws {
        let source = "# local settings\nexport API_URL=\"https://example.invalid\"\nRETRIES=3\n"
        let bytes = Data(source.utf8)
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: ".env.local", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .dotenv)
        XCTAssertEqual(inspection.formatDefinition?.availableRepresentations, [.tree, .raw])
        XCTAssertEqual(inspection.formatDefinition?.defaultRepresentation, .tree)
        XCTAssertEqual(inspection.originalBytes, bytes)
        guard case .array(let entries) = inspection.additionalStructuredContent,
              case .object(let members) = entries.first else {
            return XCTFail("Expected parsed dotenv entries")
        }
        XCTAssertTrue(members.contains { $0.key == "key" && $0.value == .string("API_URL") })
    }

    func testDotenvMalformedAndTruncatedInputsKeepRawAndDiagnostics() {
        let malformed = Data("=missing-name\nKEY=value\n".utf8)
        let malformedResult = PreviewInspectionResult.prepare(bytes: malformed, fileSize: malformed.count,
            fileName: ".env", systemUTI: nil)
        XCTAssertEqual(malformedResult.formatDefinition?.id, .dotenv)
        XCTAssertTrue(malformedResult.inspectionDiagnostics.contains { $0.code == .parseError })
        XCTAssertEqual(malformedResult.originalBytes, malformed)

        let prefix = Data("KEY=partial".utf8)
        let truncatedResult = PreviewInspectionResult.prepare(bytes: prefix, fileSize: prefix.count + 8,
            fileName: ".env", systemUTI: nil)
        XCTAssertEqual(truncatedResult.formatDefinition?.id, .dotenv)
        XCTAssertTrue(truncatedResult.inspectionDiagnostics.contains { $0.code == .truncated })
        XCTAssertEqual(truncatedResult.originalBytes, prefix)
    }

    func testCUESyntaxIsDetectedAndPreservesExactText() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/config/unsupported.cue"))
        let inspection = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "unsupported.cue", systemUTI: nil)

        XCTAssertEqual(inspection.formatDefinition?.id, .cue)
        XCTAssertEqual(inspection.sourceDocument?.language, .cue)
        XCTAssertEqual(inspection.sourceDocument?.source, String(decoding: bytes, as: UTF8.self))
    }

    func testConfigurationTokensDoNotColorValuesInsideStringsAsSyntax() throws {
        let source = "name = \"true # not a comment\" # comment\n"
        let tokens = try InternalSyntaxHighlighter().highlight(source, language: .toml).runs
        let text = tokens.map { (source as NSString).substring(with: $0.range) }

        XCTAssertEqual(text, ["name", "\"true # not a comment\"", "# comment"])
        XCTAssertEqual(tokens.map(\.kind), [.type, .string, .comment])
    }
}
