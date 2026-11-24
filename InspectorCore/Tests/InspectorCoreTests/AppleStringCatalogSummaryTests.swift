import Foundation
import XCTest
@testable import InspectorCore

final class AppleStringCatalogSummaryTests: XCTestCase {
    func testSummaryCountsStringsAndLocalesWithoutIncludingLocalizedContent() throws {
        let source = #"{"sourceLanguage":"en","version":"1.0","strings":{"greeting":{"localizations":{"en":{"value":"Secret English"},"sv":{"value":"Secret Swedish"}}},"farewell":{"localizations":{"fr":{"value":"Secret French"}}}}}"#
        let parsed = try JSONInspector.inspect(bytes: Data(source.utf8))
        let summary = try XCTUnwrap(parsed.content).flatMapSummary

        XCTAssertEqual(summary, "String catalog · 2 strings · 3 languages")
        XCTAssertFalse(summary?.contains("Secret") == true)
    }

    func testSummaryRequiresStringDictionary() throws {
        let parsed = try JSONInspector.inspect(bytes: Data(#"{"sourceLanguage":"en","version":"1.0","strings":[]}"#.utf8))
        XCTAssertNil(try XCTUnwrap(parsed.content).flatMapSummary)
    }

    func testSummaryRejectsDuplicateSecurityRelevantMembers() throws {
        let parsed = try JSONInspector.inspect(bytes: Data(#"{"sourceLanguage":"en","version":"1.0","strings":{},"strings":{}}"#.utf8))
        XCTAssertNil(try XCTUnwrap(parsed.content).flatMapSummary)
    }
}

private extension StructuredValue {
    var flatMapSummary: String? { AppleStringCatalogSummary.make(from: self) }
}
