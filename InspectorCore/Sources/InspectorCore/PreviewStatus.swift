import Foundation

/// Compact facts derived from the inspection, independent of settings, views or storage.
public struct PreviewStatusSummary: Equatable, Sendable {
    /// One visible status line and its semantic accessibility/visual role.
    public struct Item: Equatable, Sendable {
        /// Presentation category used to distinguish facts, valid results, and warnings.
        public enum Kind: Equatable, Sendable { case information, valid, warning }
        public let text: String
        public let kind: Kind
        public init(text: String, kind: Kind) { self.text = text; self.kind = kind }
    }
    /// Highest priority first; a narrow presentation may omit trailing items.
    public let items: [Item]
}

extension PreviewInspectionResult {
    public var statusSummary: PreviewStatusSummary {
        typealias Item = PreviewStatusSummary.Item
        var items: [Item] = []
        let diagnostics = (jsonInspection?.diagnostics ?? yamlInspection?.diagnostics ?? xmlInspection?.diagnostics
            ?? plistInspection?.diagnostics ?? markdownDocument?.diagnostics ?? sourceDocument?.diagnostics)
            ?? additionalInspection?.diagnostics ?? inspectionDiagnostics
        let rawComplete = jsonInspection?.rawIsComplete ?? additionalInspection?.rawIsComplete ?? yamlInspection?.rawIsComplete
            ?? xmlInspection?.rawIsComplete ?? plistInspection?.rawIsComplete ?? true
        let truncated = analysis.truncated || !rawComplete || sourceDocument?.truncated == true || diagnostics.contains { $0.code == .truncated }
        if truncated { items.append(.init(text: "Truncated", kind: .warning)) }
        else if diagnostics.contains(where: { $0.code == .limitExceeded }) {
            items.append(.init(text: "Preview limit reached", kind: .warning))
        }
        let structuredName: String?
        let validated: Bool
        if let json = jsonInspection { structuredName = "JSON"; validated = json.content != nil }
        else if let yaml = yamlInspection { structuredName = "YAML"; validated = yaml.documents != nil }
        else if let xml = xmlInspection { structuredName = "XML"; validated = xml.root != nil }
        else if let plist = plistInspection { structuredName = "plist"; validated = plist.content != nil }
        else { structuredName = nil; validated = false }
        if let name = structuredName {
            if diagnostics.contains(where: { $0.code == .parseError }) {
                items.append(.init(text: "Invalid " + name, kind: .warning))
            } else if validated {
                if diagnostics.contains(where: { $0.code == .unsupported }) {
                    items.append(.init(text: "Pretty unavailable", kind: .warning))
                }
                items.append(.init(text: "Valid " + name, kind: .valid))
            } else {
                if !truncated && !diagnostics.contains(where: { $0.code == .limitExceeded }) {
                    items.append(.init(text: "Structured preview unavailable", kind: .warning))
                }
                items.append(.init(text: name, kind: .information))
            }
        } else if let security = additionalInspection?.securityInspection, security.content != nil {
            items.append(.init(text: security.summary, kind: .information))
        } else {
            if diagnostics.contains(where: { $0.code == .unsupported || $0.code == .parseError }) {
                items.append(.init(text: "Preview fallback", kind: .warning))
            }
            let name = sourceDocument?.language.displayName ?? (markdownDocument != nil ? "Markdown" : analysis.isBinary ? "Binary data" : formatName == "Plain text" ? "Plain Text" : formatName)
            items.append(.init(text: name, kind: .information))
        }
        if let documents = yamlInspection?.documents {
            items.append(.init(text: "\(documents.count) \(documents.count == 1 ? "document" : "documents")", kind: .information))
        }
        let binaryPlist = plistInspection?.isBinary == true
        if plistInspection != nil { items.append(.init(text: binaryPlist ? "Binary" : "XML", kind: .information)) }
        if !binaryPlist && !analysis.isBinary {
            if let encoding = analysis.encoding { items.append(.init(text: encoding.displayName, kind: .information)) }
            if analysis.lineEnding != .none { items.append(.init(text: analysis.lineEnding.rawValue, kind: .information)) }
        }
        let size = max(0, analysis.fileSize)
        let formatted: String
        if size < 1_000 { formatted = "\(size) \(size == 1 ? "byte" : "bytes")" }
        else if size < 1_000_000 { formatted = String(format: "%.1f KB", locale: Locale(identifier: "en_US_POSIX"), Double(size) / 1_000) }
        else { formatted = String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), Double(size) / 1_000_000) }
        items.append(.init(text: formatted + (truncated ? " total" : ""), kind: .information))
        // Partial retained data need not have the same line count as the text-analysis prefix.
        if !binaryPlist && !analysis.isBinary && !truncated {
            let count = sourceDocument?.lineCount ?? analysis.lineCount
            items.append(.init(text: "\(count) \(count == 1 ? "line" : "lines")", kind: .information))
        }
        return .init(items: items)
    }
}
