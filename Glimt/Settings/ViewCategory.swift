import Foundation
import InspectorCore

/// Presentation grouping used by Formats & Views (ADR-022). Separate from the catalog `Category`,
/// which describes what a format is; a view category describes how its documents are shown. The
/// mapping is derived from the inspection kind, so a new provider of an existing kind joins its
/// category without code changes.
enum ViewCategoryID: String, Codable, CaseIterable, Sendable {
    case structuredData, tabularData, renderedDocuments, sourceCode, plainText, logsAndDiffs, binaryAndUnknown

    var displayName: String {
        switch self {
        case .structuredData: "Structured Data"
        case .tabularData: "Tabular Data"
        case .renderedDocuments: "Rendered Documents"
        case .sourceCode: "Source Code"
        case .plainText: "Plain Text"
        case .logsAndDiffs: "Logs & Diffs"
        case .binaryAndUnknown: "Binary & Unknown"
        }
    }

    /// Ordered active views a category starts with. Only views a member supports take effect.
    var factoryProfile: [FormatDefinition.RepresentationID] {
        switch self {
        case .structuredData: [.table, .tree, .pretty, .raw]
        case .tabularData: [.table, .raw]
        case .renderedDocuments: [.rendered, .source, .raw]
        case .sourceCode: [.source, .raw]
        case .plainText: [.raw]
        case .logsAndDiffs: [.table, .diff, .tree, .raw]
        case .binaryAndUnknown: [.hex]
        }
    }

    /// Supported catalog formats in this category, by display name. Planned entries are never listed.
    var formats: [FormatDefinition] {
        FormatCatalog.supported.filter { Self.category(for: $0) == self }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Views at least one member supports, in matrix column order. Binary & Unknown has no catalog
    /// member; its only view is the Hex fallback.
    var supported: [FormatDefinition.RepresentationID] {
        if self == .binaryAndUnknown { return [.hex] }
        let union = Set(formats.flatMap { ViewResolver.supported(for: $0.id) })
        return ViewResolver.matrixColumns.filter(union.contains)
    }

    static func category(for format: FormatID) -> ViewCategoryID {
        FormatCatalog.definition(for: format).map(category(for:)) ?? .plainText
    }

    static func category(for definition: FormatDefinition) -> ViewCategoryID {
        if definition.id == .mermaid { return .renderedDocuments }
        return switch definition.inspectionKind {
        case .json, .yaml, .xml, .plist, .jsonl, .certificate, .security, .dotenv, .windowsRegistry, .fstab, .email, .icalendar, .vcard: .structuredData
        case .csv, .zip, .tar: .tabularData
        case .markdown: .renderedDocuments
        case .source, .toml, .ini, .properties: .sourceCode
        case .diff, .log: .logsAndDiffs
        case .text: .plainText
        }
    }
}
