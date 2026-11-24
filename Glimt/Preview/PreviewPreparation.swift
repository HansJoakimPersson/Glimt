import Foundation
import InspectorCore

typealias PreviewPreparation = PreviewInspectionResult

/// Raw input each preview renderer requires from the shared inspection result.
enum RepresentationInputRequirement: Equatable {
    case originalBytes, decodedText, semanticModel
}

/// Renderer implementation selected for one supported representation.
enum RepresentationRenderer: Equatable {
    case nativeText, structuredTree, markdownText, mermaidDiagram, sourceCode, table, hexBytes, diff
}

/// Settings group consumed by a renderer when building its view.
enum RepresentationSettingsScope: Equatable {
    case none, text, markdown, structured, source, table
}

/// Registry entry connecting a representation to its input, settings, and renderer.
struct RepresentationRendererDefinition {
    let renderer: RepresentationRenderer
    let input: RepresentationInputRequirement
    let settings: RepresentationSettingsScope
}

/// UI-owned renderers are resolved centrally; the Core catalog only declares capability IDs.
enum RepresentationRegistry {
    // Keep renderer selection and required input explicit so a capability cannot accidentally
    // send raw bytes to a semantic renderer (or expose settings unsupported by that format).
    static let definitions: [FormatDefinition.RepresentationID: RepresentationRendererDefinition] = [
        .tree: .init(renderer: .structuredTree, input: .semanticModel, settings: .structured),
        .pretty: .init(renderer: .nativeText, input: .semanticModel, settings: .structured),
        .raw: .init(renderer: .nativeText, input: .decodedText, settings: .text),
        .source: .init(renderer: .sourceCode, input: .semanticModel, settings: .source),
        .table: .init(renderer: .table, input: .semanticModel, settings: .table),
        .diff: .init(renderer: .diff, input: .semanticModel, settings: .text),
        .hex: .init(renderer: .hexBytes, input: .originalBytes, settings: .none)
    ]

    private static let contextualDefinitions: [FormatID: [FormatDefinition.RepresentationID: RepresentationRendererDefinition]] = [
        .markdown: [.rendered: .init(renderer: .markdownText, input: .semanticModel, settings: .markdown)],
        .mermaid: [.rendered: .init(renderer: .mermaidDiagram, input: .decodedText, settings: .text)]
    ]

    /// Resolves a capability using both its identity and inspection kind, so Rendered can safely
    /// serve Markdown's semantic model and standalone Mermaid's exact decoded source.
    static func definition(for representation: FormatDefinition.RepresentationID,
                           inspection: PreviewPreparation) -> RepresentationRendererDefinition? {
        if representation == .rendered,
           inspection.formatDefinition?.inspectionKind == .markdown {
            return contextualDefinitions[.markdown]?[.rendered]
        }
        if let id = inspection.formatDefinition?.id,
           let contextual = contextualDefinitions[id]?[representation] { return contextual }
        return definitions[representation]
    }

    /// Produces text only for representations rendered by the shared text view; specialized views
    /// consume the same semantic inspection directly.
    static func render(_ representation: FormatDefinition.RepresentationID, inspection: PreviewPreparation) -> String? {
        guard let definition = definitions[representation] else { return nil }
        switch definition.renderer {
        case .hexBytes: return HexPreview.format(inspection.originalBytes)
        case .nativeText, .structuredTree, .markdownText, .mermaidDiagram, .sourceCode, .table, .diff: return nil
        }
    }
}

enum StandaloneMermaidAdmission {
    static let maximumSourceBytes = 8_192
    static let maximumLines = 256

    case notStandalone
    case rejected(Reason)
    case admitted(MarkdownMermaidBlock)

    enum Reason { case truncated, noSource, exceedsLimits }
}

extension PreviewInspectionResult {
    /// Creates an adapter-only block from complete recognized text without changing Core data.
    var standaloneMermaidAdmission: StandaloneMermaidAdmission {
        guard formatDefinition?.id == .mermaid else { return .notStandalone }
        if analysis.truncated { return .rejected(.truncated) }
        let source = analysis.text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.noSource)
        }
        guard source.utf8.count <= StandaloneMermaidAdmission.maximumSourceBytes,
              analysis.lineCount <= StandaloneMermaidAdmission.maximumLines else { return .rejected(.exceedsLimits) }
        return .admitted(MarkdownMermaidBlock(
            range: NSRange(location: 0, length: source.utf16.count), source: source,
            flowchart: nil, layout: nil, diagnostic: nil
        ))
    }
}

extension PreviewInspectionResult {
    /// Normalizes format-specific structured results for the shared tree renderer while retaining
    /// multi-document YAML as an ordered array.
    var structuredContent: StructuredValue? {
        if let jsonInspection { return jsonInspection.domainSummary ?? jsonInspection.content }
        if let content = additionalStructuredContent { return content }
        if let domainSummary = xmlInspection?.domainSummary { return domainSummary }
        guard let documents = yamlInspection?.documents else { return nil }
        return documents.count == 1 ? documents.first : .array(documents)
    }

    var structuredPrettyText: String? { jsonInspection?.prettyText ?? yamlInspection?.prettyText ?? plistInspection?.prettyText ?? xmlInspection?.prettyText }
    var hasStructuredContent: Bool { structuredContent != nil || plistInspection?.content != nil || xmlInspection?.root != nil }
    var structuredRawText: String {
        if let plist = plistInspection {
            if !plist.isBinary { return plist.rawText ?? analysis.text }
            return HexPreview.format(plist.rawBytes)
        }
        return xmlInspection?.rawText ?? analysis.text
    }
    var structuredDiagnostics: [InspectionDiagnostic] { jsonInspection?.diagnostics ?? yamlInspection?.diagnostics ?? plistInspection?.diagnostics ?? xmlInspection?.diagnostics ?? additionalInspection?.diagnostics ?? [] }
    var isStructured: Bool {
        jsonInspection != nil || yamlInspection != nil || plistInspection != nil || xmlInspection != nil
            || additionalStructuredContent != nil || additionalInspection?.formatID == .jsonl
            || additionalInspection?.formatID == .log
            || additionalInspection?.securityInspection?.content != nil
    }

}
