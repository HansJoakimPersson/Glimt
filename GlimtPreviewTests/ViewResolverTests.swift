import Foundation
import XCTest
import InspectorCore

/// FV-M2: view categories, inheritance, overrides and the effective view resolver (ADR-022).
final class ViewResolverTests: XCTestCase {
    private typealias View = FormatDefinition.RepresentationID
    private let sourceFormats: [FormatID] = [.swift, .java, .c, .cpp, .python, .javascript, .typescript, .shell, .toml, .ini, .properties]

    // MARK: - Categories and supported views

    func testEverySupportedFormatHasOneViewCategory() {
        let structured: [FormatID] = [.json, .yaml, .xml, .plist, .jsonl, .dotenv]
        for format in structured { XCTAssertEqual(ViewCategoryID.category(for: format), .structuredData, format.rawValue) }
        for format in sourceFormats { XCTAssertEqual(ViewCategoryID.category(for: format), .sourceCode, format.rawValue) }
        XCTAssertEqual(ViewCategoryID.category(for: .csv), .tabularData)
        XCTAssertEqual(ViewCategoryID.category(for: .tsv), .tabularData)
        XCTAssertEqual(ViewCategoryID.category(for: .markdown), .renderedDocuments)
        XCTAssertEqual(ViewCategoryID.category(for: .mermaid), .renderedDocuments)
        XCTAssertEqual(ViewCategoryID.category(for: .text), .plainText)
        XCTAssertEqual(ViewCategoryID.category(for: .diff), .logsAndDiffs)
        XCTAssertEqual(ViewCategoryID.category(for: .log), .logsAndDiffs)
        let listed = ViewCategoryID.allCases.flatMap { $0.formats.map(\.id) }
        XCTAssertEqual(Set(listed), Set(FormatCatalog.supported.map(\.id)))
        XCTAssertEqual(listed.count, FormatCatalog.supported.count, "A format belongs to exactly one category")
    }

    func testPlannedFormatsAreNeverExposed() {
        let planned = FormatCatalog.all.filter { $0.status == .planned }
        XCTAssertFalse(planned.isEmpty)
        for definition in planned {
            XCTAssertEqual(ViewResolver.supported(for: definition.id), [], definition.id.rawValue)
            XCTAssertFalse(ViewCategoryID.allCases.contains { $0.formats.contains { $0.id == definition.id } })
        }
    }

    func testSupportedViewsFollowTheVerifiedInventory() {
        XCTAssertEqual(ViewResolver.supported(for: .json), [.tree, .pretty, .raw, .hex])
        XCTAssertEqual(ViewResolver.supported(for: .yaml), [.tree, .pretty, .raw])
        XCTAssertEqual(ViewResolver.supported(for: .jsonl), [.tree, .raw])
        XCTAssertEqual(ViewResolver.supported(for: .csv), [.table, .raw, .hex])
        XCTAssertEqual(ViewResolver.supported(for: .markdown), [.rendered, .source])
        XCTAssertEqual(ViewResolver.supported(for: .mermaid), [.rendered, .raw])
        XCTAssertEqual(ViewResolver.supported(for: .swift), [.source, .raw, .hex])
        XCTAssertEqual(ViewResolver.supported(for: .diff), [.diff, .raw])
        XCTAssertEqual(ViewResolver.supported(for: .log), [.table, .tree, .raw])
        XCTAssertEqual(ViewResolver.supported(for: .text), [.raw], "Decoded text is always renderable")
        XCTAssertEqual(ViewResolver.supported(for: FormatID(rawValue: "nope")), [])
    }

    func testCategoryColumnsAreTheUnionOfMemberViews() {
        XCTAssertEqual(ViewCategoryID.structuredData.supported, [.tree, .pretty, .table, .raw, .hex])
        XCTAssertEqual(ViewCategoryID.logsAndDiffs.supported, [.tree, .table, .diff, .raw])
        XCTAssertEqual(ViewCategoryID.renderedDocuments.supported, [.rendered, .source, .raw])
        XCTAssertEqual(ViewCategoryID.binaryAndUnknown.supported, [.hex])
        XCTAssertEqual(ViewResolver.matrixColumns, [.tree, .pretty, .table, .rendered, .source, .diff, .raw, .hex])
    }

    // MARK: - Factory resolution

    func testFactoryDefaultsInheritCategoryProfiles() {
        let settings = GlimtSettingsV3.factoryDefaults
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.tree, .pretty, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .jsonl).configured, [.tree, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .csv).configured, [.table, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .markdown).configured, [.rendered, .source])
        XCTAssertEqual(ViewCategoryID.renderedDocuments.factoryProfile, [.rendered, .source, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid).configured, [.rendered, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .swift).configured, [.source, .raw])
        let elm = FormatID(rawValue: "reference-elm")
        XCTAssertEqual(ViewResolver.resolve(settings, for: elm).configured, [.source, .raw, .hex])
        XCTAssertEqual(ViewResolver.resolve(settings, for: elm).defaultView, .source)
        XCTAssertEqual(ViewResolver.resolve(settings, for: .diff).configured, [.diff, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .log).configured, [.table, .tree, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .text).configured, [.raw])
        for definition in FormatCatalog.supported {
            let resolved = ViewResolver.resolve(settings, for: definition.id)
            XCTAssertEqual(resolved.origin, .inherited, definition.id.rawValue)
            XCTAssertEqual(resolved.defaultView, resolved.configured.first)
            XCTAssertFalse(resolved.configured.isEmpty, definition.id.rawValue)
        }
    }

    func testElmCatalogDefaultViewsRespectUserOverrides() {
        let settings = GlimtSettingsV3.factoryDefaults
        let elm = FormatID(rawValue: "reference-elm")
        var categoryCustomized = settings
        categoryCustomized.categoryProfiles[ViewCategoryID.sourceCode.rawValue] = ["source", "raw"]
        XCTAssertEqual(ViewResolver.resolve(categoryCustomized, for: elm).configured, [.source, .raw])

        var formatCustomized = settings
        formatCustomized.formatOverrides[elm.rawValue] = ["raw", "hex", "source"]
        XCTAssertEqual(ViewResolver.resolve(formatCustomized, for: elm).configured, [.raw, .hex, .source])
    }

    func testMermaidProfilesFilterWithoutBackfillAndRecoverWithoutWriting() throws {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.categoryProfiles[ViewCategoryID.renderedDocuments.rawValue] = ["raw", "rendered", "source"]
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid).configured, [.raw, .rendered])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .markdown).configured, [.rendered, .source],
                       "The stored profile replaces factory order, then each format filters unsupported views")

        settings.formatOverrides[FormatID.mermaid.rawValue] = ["rendered", "raw"]
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid).configured, [.rendered, .raw],
                       "A format override takes precedence over the category profile")
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: encoded)
        XCTAssertEqual(decoded, settings)

        settings.formatOverrides[FormatID.mermaid.rawValue] = ["source"]
        let beforeRecovery = settings
        let noConfiguredView = ViewResolver.resolve(settings, for: .mermaid)
        XCTAssertEqual(noConfiguredView.configured, [], "Unsupported stored views are not backfilled")
        XCTAssertEqual(noConfiguredView.presented(available: [.raw], isBinary: false),
                       .init(views: [.raw], isRecovery: true))
        XCTAssertEqual(settings, beforeRecovery, "Presentation recovery never writes settings")

        settings.formatOverrides[FormatID.mermaid.rawValue] = ["rendered"]
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid).configured, [.rendered])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid)
            .presented(available: [.raw], isBinary: false), .init(views: [.raw], isRecovery: true))
        XCTAssertEqual(ViewResolver.presented(configured: [], available: [.hex], isBinary: true),
                       .init(views: [.hex], isRecovery: true))

        settings.resetViews(for: .format(.mermaid))
        XCTAssertNil(settings.formatOverrides[FormatID.mermaid.rawValue])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid).configured, [.raw, .rendered])
        settings.resetViews(for: .category(.renderedDocuments))
        XCTAssertNil(settings.categoryProfiles[ViewCategoryID.renderedDocuments.rawValue])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .mermaid).configured, [.rendered, .raw])
    }

    func testEffectiveViewsIntersectAvailabilityInConfiguredOrder() {
        let resolved = ViewResolver.resolve(.factoryDefaults, for: .json)
        XCTAssertEqual(resolved.effective(available: [.raw, .tree, .pretty, .hex]), [.tree, .pretty, .raw])
        XCTAssertEqual(resolved.effective(available: [.raw, .hex]), [.raw], "An unparsable document keeps its active Raw view")
    }

    func testRecoveryIsUsedOnlyWhenNoConfiguredViewIsAvailable() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.formatOverrides["json"] = ["tree"]
        let resolved = ViewResolver.resolve(settings, for: .json)
        XCTAssertEqual(resolved.presented(available: [.tree, .raw], isBinary: false), .init(views: [.tree], isRecovery: false))
        XCTAssertEqual(resolved.presented(available: [.raw, .hex], isBinary: false), .init(views: [.raw], isRecovery: true))
        XCTAssertEqual(resolved.presented(available: [.hex], isBinary: true), .init(views: [.hex], isRecovery: true))
        XCTAssertEqual(settings.formatOverrides["json"], ["tree"], "Recovery never rewrites settings")
    }

    // MARK: - Customization

    func testEditingAnInheritedFormatMaterializesItsEffectiveConfiguration() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.setView(.hex, enabled: true, for: .format(.swift))
        XCTAssertEqual(settings.formatOverrides["swift"], ["source", "raw", "hex"])
        let resolved = ViewResolver.resolve(settings, for: .swift)
        XCTAssertEqual(resolved.origin, .customized)
        XCTAssertEqual(resolved.configured, [.source, .raw, .hex])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .java).origin, .inherited, "Siblings keep inheriting")
    }

    func testDisablingRemovesAndReenablingAppends() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.setView(.tree, enabled: false, for: .format(.json))
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.pretty, .raw])
        settings.setView(.tree, enabled: true, for: .format(.json))
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.pretty, .raw, .tree])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).defaultView, .pretty)
    }

    func testUnsupportedViewsCannotBeEnabled() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.setView(.table, enabled: true, for: .format(.json))
        XCTAssertEqual(settings, .factoryDefaults)
        XCTAssertEqual(ViewResolver.state(of: .table, in: settings, for: .format(.json)), .unsupported)
    }

    func testTheLastActiveViewCannotBeDisabled() {
        var settings = GlimtSettingsV3.factoryDefaults
        XCTAssertFalse(ViewResolver.canDisable(.raw, in: settings, for: .format(.text)))
        settings.setView(.raw, enabled: false, for: .format(.text))
        XCTAssertEqual(settings, .factoryDefaults)
        settings.setView(.diff, enabled: false, for: .format(.diff))
        XCTAssertFalse(ViewResolver.canDisable(.raw, in: settings, for: .format(.diff)))
    }

    func testCategoryEditsReachInheritingFormatsOnly() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.setView(.hex, enabled: true, for: .format(.json))
        settings.setView(.pretty, enabled: false, for: .category(.structuredData))
        XCTAssertEqual(settings.categoryProfiles["structuredData"], ["table", "tree", "raw"])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .yaml).configured, [.tree, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.tree, .pretty, .raw, .hex], "Customized format keeps its list")
        XCTAssertTrue(ViewResolver.isCustomized(.category(.structuredData), in: settings))
    }

    func testCategoryCannotLeaveAnInheritingFormatWithoutViews() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.setView(.raw, enabled: false, for: .category(.logsAndDiffs))
        settings.setView(.table, enabled: false, for: .category(.logsAndDiffs))
        XCTAssertEqual(ViewResolver.resolve(settings, for: .diff).configured, [.diff])
        XCTAssertFalse(ViewResolver.canDisable(.tree, in: settings, for: .category(.logsAndDiffs)), "Log would have no view")
        XCTAssertFalse(ViewResolver.canDisable(.diff, in: settings, for: .category(.logsAndDiffs)), "Diff would have no view")
    }

    func testMovingReordersAndTheFirstViewBecomesTheDefault() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.moveView(from: 2, to: 0, for: .format(.json))
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.raw, .tree, .pretty])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).defaultView, .raw)
        settings.moveView(from: 0, to: 2, for: .format(.json))
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.tree, .pretty, .raw])
        settings.moveView(from: 7, to: 0, for: .format(.json))
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.tree, .pretty, .raw], "Out-of-range moves are ignored")
    }

    func testResetToCategoryAndRestoreCategoryDefaults() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.setView(.hex, enabled: true, for: .format(.csv))
        settings.setView(.raw, enabled: false, for: .category(.tabularData))
        settings.resetViews(for: .format(.csv))
        XCTAssertNil(settings.formatOverrides["csv"])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .csv).configured, [.table])
        settings.resetViews(for: .category(.tabularData))
        XCTAssertEqual(settings, .factoryDefaults)
    }

    func testCustomizedListsDoNotGainNewViewsAndKeepUnknownIDs() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.categoryProfiles["structuredData"] = ["tree", "futureView", "raw"]
        settings.formatOverrides["json"] = ["raw", "removedView"]
        XCTAssertEqual(ViewResolver.resolve(settings, for: .yaml).configured, [.tree, .raw])
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json).configured, [.raw])
        settings.setView(.tree, enabled: true, for: .format(.json))
        XCTAssertEqual(settings.formatOverrides["json"], ["raw", "tree", "removedView"], "Hidden IDs are kept as compatibility data")
        settings.moveView(from: 1, to: 0, for: .format(.json))
        XCTAssertEqual(settings.formatOverrides["json"], ["tree", "raw", "removedView"])
        XCTAssertEqual(settings.normalized(), settings)
    }

    func testMatrixStatesDistinguishEnabledDisabledAndUnsupported() {
        let settings = GlimtSettingsV3.factoryDefaults
        XCTAssertEqual(ViewResolver.state(of: .tree, in: settings, for: .format(.json)), .enabled)
        XCTAssertEqual(ViewResolver.state(of: .hex, in: settings, for: .format(.json)), .disabled)
        XCTAssertEqual(ViewResolver.state(of: .source, in: settings, for: .format(.json)), .unsupported)
        XCTAssertEqual(ViewResolver.state(of: .hex, in: settings, for: .category(.structuredData)), .disabled)
        XCTAssertEqual(ViewResolver.state(of: .table, in: settings, for: .category(.structuredData)), .enabled)
        XCTAssertEqual(ViewResolver.state(of: .rendered, in: settings, for: .category(.structuredData)), .unsupported)
        XCTAssertEqual(ViewResolver.state(of: .hex, in: settings, for: .category(.binaryAndUnknown)), .enabled)
        XCTAssertFalse(ViewResolver.isEditable(.category(.binaryAndUnknown)))
    }

    func testResolverIsDeterministicAndSideEffectFree() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.formatOverrides["json"] = ["pretty", "tree"]
        let copy = settings
        XCTAssertEqual(ViewResolver.resolve(settings, for: .json), ViewResolver.resolve(settings, for: .json))
        XCTAssertEqual(settings, copy)
    }

    func testRenderConfigurationCarriesConfiguredViewsForEveryFormat() {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.formatOverrides["markdown"] = ["source", "rendered"]
        let configuration = RenderConfiguration(settings: settings)
        XCTAssertEqual(configuration.configuredViews(for: .markdown), [.source, .rendered])
        XCTAssertEqual(configuration.configuredViews(for: .json), [.tree, .pretty, .raw])
        XCTAssertEqual(configuration.configuredViews(for: nil), [.hex], "Unknown binary keeps Hex")
    }

    // MARK: - Persistence

    func testViewListsRoundTripAndNormalizationIsIdempotent() throws {
        var settings = GlimtSettingsV3.factoryDefaults
        settings.categoryProfiles["sourceCode"] = ["raw", "source", "raw"]
        settings.formatOverrides["json"] = ["hex", "tree"]
        let normalized = settings.normalized()
        XCTAssertEqual(normalized.categoryProfiles["sourceCode"], ["raw", "source"], "Duplicates are collapsed")
        XCTAssertEqual(normalized.normalized(), normalized)
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: JSONEncoder().encode(normalized))
        XCTAssertEqual(decoded, normalized)
    }

    func testInvalidViewListsFallBackWithoutDiscardingTheFile() throws {
        let data = Data(#"{"schemaVersion":4,"general":{"lineNumbers":false},"categoryProfiles":{"sourceCode":"raw","plainText":["raw"]},"formatOverrides":7}"#.utf8)
        let decoded = try JSONDecoder().decode(GlimtSettingsV3.self, from: data)
        XCTAssertFalse(decoded.general.lineNumbers)
        XCTAssertEqual(decoded.categoryProfiles, ["plainText": ["raw"]])
        XCTAssertEqual(decoded.formatOverrides, [:])
    }
}
