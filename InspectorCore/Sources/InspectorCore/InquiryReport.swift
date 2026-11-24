import Foundation
import UniformTypeIdentifiers

/// A bounded explanation of an existing preview result, never a second detector or provider probe.
public struct InquiryReport: Equatable, Sendable {
    public let summary: String
    public let details: String
    public let formatName: String
    public let availableRepresentations: [String]

    /// Builds bounded Standard and Advanced explanations from an already completed inspection.
    public static func make(url: URL, inspection: PreviewInspectionResult,
                            declaredTypeIDs: [String]? = nil) -> InquiryReport {
        // Explain the already-computed inspection; never re-read the file or claim Finder provider election.
        let representations = representations(inspection)
        let diagnostics = diagnostics(inspection)
        let format = clean(inspection.formatName)
        let reason = inspection.overrideDescription == nil ? reason(inspection.detectionReason) : "an explicit user mapping"
        let binaryFallback = inspection.analysis.isBinary && inspection.plistInspection == nil
        let structuredFallback = (inspection.jsonInspection != nil || inspection.yamlInspection != nil
            || inspection.xmlInspection != nil || inspection.plistInspection != nil) && !representations.contains("Tree")
        let recognizedTextFallback = inspection.formatDefinition?.recognizedTextFallback == true
            && inspection.formatDefinition?.inspectionKind == .text
        let status = binaryFallback ? (representations.contains("Hex") ? "Binary data; bounded Hex view available." : "Binary information only; no content renderer is available.")
            : structuredFallback ? "Partial support: structured parsing could not provide a Tree. Raw remains available."
            : recognizedTextFallback ? "Partial support: Plain Text fallback; specialized inspection is not available."
            : diagnostics.isEmpty ? "Supported in Glimt." : "Partial support: see the inspection notes below."
        let conflict = conflicts(inspection)
        var summary = ["Detected format: \(format)", "Why: \(reason)", status,
                       "Available views: \(representations.joined(separator: ", "))"]
        if let override = inspection.overrideDescription {
            summary.append("User mapping: \(clean(override))")
            if let automatic = inspection.automaticFormatName { summary.append("Automatic result: \(clean(automatic))") }
        }
        if !conflict.isEmpty { summary.append("Conflicting evidence: \(conflict.joined(separator: "; "))") }
        if inspection.analysis.truncated { summary.append("Only a bounded prefix was inspected; this is not a complete-file assessment.") }
        summary.append(contentsOf: diagnostics.prefix(8).map { "Inspection note: \(clean($0.message))" })
        summary.append("Finder routing is separate: macOS or another provider may win. This report does not identify the active Quick Look provider.")

        let observed = inspection.systemUTI
        let hierarchy = supertypes(observed)
        let ext = url.pathExtension
        var details = ["File: \(clean(url.lastPathComponent))", "Path: \(clean(url.path, maximum: 2_048))",
                       "Size: \(inspection.analysis.fileSize) bytes", "Extension: \(ext.isEmpty ? "none" : clean(ext))",
                       "Observed UTType: \(observed.map { clean($0) } ?? "unavailable")",
                       "Transitive supertypes (bounded): \(hierarchy.isEmpty ? "none available" : hierarchy.joined(separator: ", "))",
                       declaration(observed: observed, hierarchy: hierarchy, declared: declaredTypeIDs),
                       "Encoding: \(inspection.analysis.encoding?.displayName ?? "not decoded")",
                       "BOM: \(inspection.analysis.hasBOM ? "present" : "not observed")",
                       "Line endings: \(inspection.analysis.lineEnding.rawValue)",
                       "Detection sample: \(inspection.sampleByteCount) bytes; \(inspection.sampleIsComplete ? "complete input" : "bounded prefix")",
                       "Selected reason: \(reason)", "Inspector/renderer: \(renderer(inspection))", status,
                       "Available views: \(representations.joined(separator: ", "))"]
        if inspection.analysis.text.hasPrefix("#!") {
            let prefix = inspection.analysis.text.unicodeScalars.prefix(512)
            let line = String(String.UnicodeScalarView(prefix)).prefix { $0 != "\n" && $0 != "\r" }
            details.append("Shebang (bounded, never executed): \(clean(String(line), maximum: 512))")
        }
        for evidence in inspection.resolution.byteEvidence {
            let label = evidence.signalKind == .magicSignature ? "File signature" : "Byte-order mark"
            let value = evidence.encoding?.displayName ?? evidence.value.map { clean($0) }
            details.append("\(label): \(statusLabel(evidence.status))\(value.map { " · " + $0 } ?? "")")
        }
        let evidence = inspection.resolution.evidence.filter { $0.value != "no-match" && !$0.value.isEmpty }
        for item in evidence.prefix(16) { details.append("Evidence · \(signalLabel(item.signalKind)): \(clean(item.value))") }
        details.append(contentsOf: diagnostics.prefix(32).map { "\(diagnosticLabel($0.code)): \(clean($0.message))" })
        details.append("UTType declarations describe eligibility only; Finder chooses the active preview provider.")
        if let definition = inspection.formatDefinition {
            details += ["Catalog format: \(definition.displayName) (\(definition.id.rawValue))",
                        "Supported extensions: \(definition.extensions.map { "." + $0 }.joined(separator: ", "))",
                        "Exact filenames: \(definition.exactFilenames.joined(separator: ", "))",
                        "Settings profile: \(definition.settingsSection)",
                        "Showcase: \(definition.showcaseFixture ?? "none")"]
        }
        return .init(summary: String(summary.joined(separator: "\n\n").prefix(8_192)),
                     details: String(details.joined(separator: "\n").prefix(32_768)),
                     formatName: format, availableRepresentations: representations)
    }

    /// Lists only views the selected renderer can actually supply for this inspection result.
    private static func representations(_ result: PreviewInspectionResult) -> [String] {
        if let definition = result.formatDefinition {
            let available = Set(definition.availableRepresentations)
            var names: [String] = []
            let hasRenderedContent = result.markdownDocument?.renderedText != nil
                || (definition.id == .mermaid && !result.analysis.isBinary)
            if available.contains(.rendered), hasRenderedContent { names.append("Rendered") }
            let hasTree = result.jsonInspection?.content != nil || result.yamlInspection?.documents != nil
                || result.xmlInspection?.root != nil || result.plistInspection?.content != nil
                || result.additionalStructuredContent != nil
            if available.contains(.tree), hasTree { names.append("Tree") }
            let pretty = result.jsonInspection?.prettyText ?? result.yamlInspection?.prettyText
                ?? result.xmlInspection?.prettyText ?? result.plistInspection?.prettyText
            if available.contains(.pretty), pretty != nil { names.append("Pretty") }
            if available.contains(.diff), result.diffInspection?.files.isEmpty == false { names.append("Diff") }
            if available.contains(.source), result.sourceDocument != nil { names.append("Source") }
            if available.contains(.raw) {
                names.append(result.plistInspection?.isBinary == true ? "Raw (bounded hex)" : "Raw")
            }
            if available.contains(.hex) { names.append("Hex") }
            if !names.isEmpty { return names }
        }
        if let inspection = result.jsonInspection { return structured(tree: inspection.content != nil, pretty: inspection.prettyText != nil) }
        if let inspection = result.yamlInspection { return structured(tree: inspection.documents != nil, pretty: inspection.prettyText != nil) }
        if let inspection = result.xmlInspection { return structured(tree: inspection.root != nil, pretty: inspection.prettyText != nil) }
        if let inspection = result.plistInspection {
            return structured(tree: inspection.content != nil, pretty: inspection.prettyText != nil,
                              raw: inspection.isBinary ? "Raw (bounded hex)" : "Raw")
        }
        if let document = result.markdownDocument { return document.renderedText == nil ? ["Source"] : ["Rendered", "Source"] }
        if result.sourceDocument != nil { return ["Highlighted source (original text)"] }
        return result.analysis.isBinary ? ["Hex"] : ["Raw text"]
    }

    /// Builds the structured fallback view list while always preserving a Raw representation.
    private static func structured(tree: Bool, pretty: Bool, raw: String = "Raw") -> [String] {
        (tree ? ["Tree"] : []) + (pretty ? ["Pretty"] : []) + [raw]
    }

    /// Selects diagnostics from the inspector that actually produced the preview's semantic result.
    private static func diagnostics(_ result: PreviewInspectionResult) -> [InspectionDiagnostic] {
        result.jsonInspection?.diagnostics ?? result.yamlInspection?.diagnostics ?? result.xmlInspection?.diagnostics
            ?? result.plistInspection?.diagnostics ?? result.sourceDocument?.diagnostics ?? result.markdownDocument?.diagnostics
            ?? result.additionalInspection?.diagnostics ?? []
    }

    /// Names the inspector/renderer path used, with text or binary fallback when none specialized.
    private static func renderer(_ result: PreviewInspectionResult) -> String {
        if result.formatDefinition?.id == .mermaid {
            return "MermaidKit native diagram renderer"
        }
        if result.jsonInspection != nil { return "JSON inspector / native structured views" }
        if result.yamlInspection != nil { return "YAML inspector / native structured views" }
        if result.xmlInspection != nil { return "XML inspector / native structured views" }
        if result.plistInspection != nil { return "Property list inspector / native structured views" }
        if let markdown = result.markdownDocument {
            return markdown.mermaidBlocks.isEmpty
                ? "Markdown inspector / native text rendering"
                : "Markdown inspector / native text and Mermaid rendering"
        }
        if result.diffInspection != nil { return "Diff inspector / native Diff rendering" }
        if result.additionalStructuredContent != nil { return "Record inspector / native structured tree" }
        if result.sourceDocument != nil { return "Source inspector / native syntax highlighting" }
        return result.analysis.isBinary ? "Binary fallback" : "Text analysis / native text rendering"
    }

    /// Converts internal detection reason identifiers into report-friendly explanations.
    private static func reason(_ reason: String) -> String {
        switch reason {
        case "fileExtension": return "the filename extension"
        case "exactFilename": return "the recognized filename"
        case "systemUTI": return "the system-reported file type"
        case "shebang": return "the interpreter named in the shebang"
        case "magicBytes": return "a recognized byte signature"
        case "contentProbe": return "the inspected content"
        case "binary": return "the input was classified as binary"
        case "plainText": return "readable text without a specialized format match"
        case "userMapping": return "an explicit user mapping"
        default: return clean(reason)
        }
    }

    /// Maps detector evidence kinds to stable report labels.
    private static func signalLabel(_ signal: DetectionEvidence.SignalKind) -> String {
        switch signal {
        case .filename: "Recognized filename"
        case .multiExtension: "Compound extension"
        case .singleExtension: "Filename extension"
        case .shebang: "Script interpreter"
        case .yamlMapping: "YAML mapping"
        case .yamlDocumentMarker: "YAML document marker"
        case .systemUTI: "System file type"
        case .utiConflict: "Conflicting system type"
        }
    }

    /// Converts byte-signature states into concise user-facing terms.
    private static func statusLabel(_ status: ByteDetectionEvidence.Status) -> String {
        switch status {
        case .matched: "recognized"
        case .noMatch: "not found"
        case .incomplete: "insufficient bytes"
        case .unavailable: "not available"
        }
    }

    /// Maps diagnostic codes to report section labels without exposing implementation details.
    private static func diagnosticLabel(_ code: InspectionDiagnostic.Code) -> String {
        switch code {
        case .parseError: "Parse error"
        case .limitExceeded: "Processing limit"
        case .truncated: "Incomplete input"
        case .unsupported: "Unsupported content"
        }
    }

    /// Explains known disagreements between content detection and system type metadata.
    private static func conflicts(_ result: PreviewInspectionResult) -> [String] {
        if result.sourceDocument?.language == .typescript,
           result.systemUTI == "public.mpeg-2-transport-stream" {
            return ["This file contains readable TypeScript, but macOS identifies .ts as MPEG video. Glimt can preview it; Finder may use a video preview instead."]
        }
        let notes = result.resolution.evidence.filter { $0.signalKind == .utiConflict }.map { _ in
            "The system file type disagrees with Glimt's selected format. Finder may choose a different preview."
        }
        return notes
    }

    /// Collects a bounded, cycle-safe hierarchy of declared UTType supertypes.
    private static func supertypes(_ identifier: String?) -> [String] {
        guard let identifier, identifier.utf8.count <= 512, let type = UTType(identifier) else { return [] }
        var visited: Set<String> = [identifier]
        var pending = [type]
        var output: [String] = []
        while let current = pending.popLast(), visited.count <= 64 {
            for parent in current.supertypes.sorted(by: { $0.identifier < $1.identifier }) {
                guard visited.count < 64 else { break }
                if visited.insert(parent.identifier).inserted {
                    output.append(clean(parent.identifier, maximum: 512)); pending.append(parent)
                }
            }
        }
        return output.sorted()
    }

    /// Explains whether the observed type is covered by the app's embedded preview declarations.
    private static func declaration(observed: String?, hierarchy: [String], declared: [String]?) -> String {
        guard let declared else { return "Embedded preview declarations: unavailable; eligibility not assessed." }
        guard let observed else { return "Embedded preview declarations: observed UTType unavailable; eligibility not assessed." }
        let candidates = Set([observed] + hierarchy)
        let matches = declared.prefix(256).filter { $0.utf8.count <= 512 && candidates.contains($0) }.map { clean($0, maximum: 512) }
        return matches.isEmpty ? "Embedded preview declarations: no match for the observed UTType in the bounded declaration check."
            : "Embedded preview declarations match: \(matches.joined(separator: ", ")). This does not prove provider selection."
    }

    /// Removes control characters and caps report strings before they reach UI or clipboard output.
    private static func clean(_ text: String, maximum: Int = 1_024) -> String {
        // Bound and sanitize report strings because file metadata and parser diagnostics are untrusted input.
        var output = ""
        for scalar in text.unicodeScalars.prefix(maximum) {
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { output += " " }
            else { output.unicodeScalars.append(scalar) }
        }
        if text.unicodeScalars.dropFirst(maximum).first != nil { output += "…" }
        return output
    }
}
