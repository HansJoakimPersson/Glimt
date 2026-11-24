import Foundation
import InspectorCore

/// Literal filename or single-extension mappings. This never registers a macOS file association.
struct FileAssociation: Codable, Equatable, Sendable {
    /// Whether the mapping matches a literal filename or a filename extension.
    enum Kind: String, Codable, CaseIterable, Sendable { case filename, fileExtension }
    typealias Target = FormatID
    var kind: Kind
    var value: String
    var target: Target
    var displayPattern: String { kind == .filename ? value : "*." + value }
    /// Matches only the stored literal filename or extension; this is preview routing and does not
    /// alter Launch Services or the user's system-level file associations.
    func matches(_ filename: String) -> Bool {
        if target == .zip, (filename as NSString).pathExtension.lowercased() != "zip" { return false }
        return kind == .filename ? filename == value : (filename as NSString).pathExtension.lowercased() == value
    }
    /// Normalizes the user-entered pattern and rejects path syntax, wildcards, and unsupported targets.
    func validated() -> FileAssociation? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .fileExtension {
            if value.hasPrefix("*.") { value.removeFirst(2) }
            if value.hasPrefix(".") { value.removeFirst() }
            value = value.lowercased()
        }
        guard FormatCatalog.definition(for: target)?.status == .supported, !value.isEmpty, value.utf8.count <= 128,
              !value.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" || $0 == "*" || $0 == "?" || $0.isNewline }),
              kind == .filename || !value.contains(".") else { return nil }
        if target == .zip {
            let extensionName = kind == .filename ? (value as NSString).pathExtension.lowercased() : value
            guard extensionName == "zip" else { return nil }
        }
        return .init(kind: kind, value: value, target: target)
    }
}

/// Only explicitly changed fields override Source defaults; nil always inherits.
struct SourceLanguageOverride: Codable, Equatable, Sendable {
    var lightTheme: SourceThemePreset?
    var darkTheme: SourceThemePreset?
    var lightCustomThemeID: String?
    var darkCustomThemeID: String?
    var indentationGuides: Bool?
    var fontFamily: String?
    var fontSize: Double?
    var showLineNumbers: Bool?
    var wordWrap: Bool?
    var tabWidth: Int?
    var isEmpty: Bool { lightTheme == nil && darkTheme == nil && lightCustomThemeID == nil && darkCustomThemeID == nil && indentationGuides == nil && fontFamily == nil && fontSize == nil && showLineNumbers == nil && wordWrap == nil && tabWidth == nil }
}

extension FormatID {
    var displayName: String { FormatCatalog.definition(for: self)?.displayName ?? rawValue }
    var inspectionOverride: PreviewInspectionResult.FormatOverride {
        guard let definition = FormatCatalog.definition(for: self) else { return .text }
        if self == .mermaid { return .mermaid }
        if definition.effectiveInspectorID == .source, let language = definition.sourceLanguage { return .source(language) }
        switch definition.effectiveInspectorID {
        case .text: return .text
        case .json: return .json
        case .yaml: return .yaml
        case .xml: return .xml
        case .plist: return .plist
        case .markdown: return .markdown
        case .diff: return .diff
        case .jsonl: return .jsonl
        case .log: return .log
        case .toml: return .toml
        case .ini: return .ini
        case .dotenv: return .dotenv
        case .properties: return .properties
        case .windowsRegistry: return .windowsRegistry
        case .fstab: return .text
        case .email: return .email
        case .icalendar: return .icalendar
        case .vcard: return .vcard
        case .zip: return .zip
        case .tar: return .tar
        case .x509Certificate: return .certificate(self)
        case .security: return .security(self)
        case .csv: return .csv(self)
        case .source: return .text
        }
    }
}
