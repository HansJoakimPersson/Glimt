import Foundation

/// Stable persisted identity. A format is not an extension or a renderer name.
public struct FormatID: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    /// Creates a persisted format identity from its canonical string value.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Decodes the identity from the single-string representation stored in settings.
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    /// Encodes the persisted format identity as the raw string expected by settings files.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    public static var allCases: [FormatID] { FormatCatalog.supported.map(\.id) }
    public static let text = Self(rawValue: "text"), json = Self(rawValue: "json"), yaml = Self(rawValue: "yaml")
    public static let xml = Self(rawValue: "xml"), plist = Self(rawValue: "plist"), markdown = Self(rawValue: "markdown")
    public static let kml = Self(rawValue: "kml"), gpx = Self(rawValue: "gpx")
    public static let geojson = Self(rawValue: "geojson")
    public static let swift = Self(rawValue: "swift"), java = Self(rawValue: "java"), c = Self(rawValue: "c"), cpp = Self(rawValue: "cpp")
    public static let python = Self(rawValue: "python"), javascript = Self(rawValue: "javascript")
    public static let jsx = Self(rawValue: "jsx")
    public static let typescript = Self(rawValue: "typescript"), shell = Self(rawValue: "shell"), diff = Self(rawValue: "diff")
    public static let csv = Self(rawValue: "csv"), tsv = Self(rawValue: "tsv")
    public static let jsonl = Self(rawValue: "jsonl"), log = Self(rawValue: "log")
    public static let mermaid = Self(rawValue: "mermaid")
    public static let toml = Self(rawValue: "toml"), ini = Self(rawValue: "ini")
    public static let dotenv = Self(rawValue: "dotenv"), properties = Self(rawValue: "properties")
    public static let fstab = Self(rawValue: "reference-fstab-config-file")
    public static let editorconfig = Self(rawValue: "editorconfig"), gitignore = Self(rawValue: "gitignore")
    public static let dockerignore = Self(rawValue: "dockerignore")
    public static let systemdUnit = Self(rawValue: "systemd-unit")
    public static let goModule = Self(rawValue: "go-module")
    public static let npmrc = Self(rawValue: "npmrc"), gitattributes = Self(rawValue: "gitattributes")
    public static let gitmodules = Self(rawValue: "gitmodules")
    public static let windowsRegistry = Self(rawValue: "windows-registry")
    public static let email = Self(rawValue: "email"), icalendar = Self(rawValue: "icalendar"), vcard = Self(rawValue: "vcard")
    public static let infoPlist = Self(rawValue: "info-plist"), entitlements = Self(rawValue: "entitlements")
    public static let strings = Self(rawValue: "strings"), stringsdict = Self(rawValue: "stringsdict")
    public static let xcstrings = Self(rawValue: "xcstrings"), xcscheme = Self(rawValue: "xcscheme")
    public static let privacyManifest = Self(rawValue: "privacy-manifest"), xcodeTestPlan = Self(rawValue: "xcode-test-plan")
    public static let d = Self(rawValue: "d"), batch = Self(rawValue: "batch")
    public static let dylan = Self(rawValue: "dylan"), eiffel = Self(rawValue: "eiffel")
    public static let elixir = Self(rawValue: "elixir"), erlang = Self(rawValue: "erlang")
    public static let dtd = Self(rawValue: "dtd"), dockerfile = Self(rawValue: "dockerfile")
    public static let xquery = Self(rawValue: "xquery"), jsp = Self(rawValue: "jsp"), haml = Self(rawValue: "haml")
    public static let kotlin = Self(rawValue: "kotlin"), less = Self(rawValue: "less"), lisp = Self(rawValue: "lisp")
    public static let pascal = Self(rawValue: "pascal"), verilog = Self(rawValue: "verilog"), vhdl = Self(rawValue: "vhdl")
    public static let cobol = Self(rawValue: "cobol"), deviceTree = Self(rawValue: "device-tree-source")
    public static let gettext = Self(rawValue: "gettext")
    public static let erb = Self(rawValue: "erb"), qml = Self(rawValue: "qml"), solidity = Self(rawValue: "solidity")
    public static let org = Self(rawValue: "org"), mdc = Self(rawValue: "mdc"), apib = Self(rawValue: "apib")
    public static let asp = Self(rawValue: "asp"), aspx = Self(rawValue: "aspx")
    public static let jinja = Self(rawValue: "jinja"), twig = Self(rawValue: "twig")
    public static let lua = Self(rawValue: "lua"), powershell = Self(rawValue: "powershell"), miniscript = Self(rawValue: "miniscript")
    public static let rmarkdown = Self(rawValue: "rmarkdown")
    public static let textbundle = Self(rawValue: "textbundle")
    public static let make = Self(rawValue: "make")
    public static let latex = Self(rawValue: "latex"), jenkinsfile = Self(rawValue: "jenkinsfile")
    public static let meson = Self(rawValue: "meson"), plsql = Self(rawValue: "plsql")
    public static let tsql = Self(rawValue: "tsql")
    public static let zip = Self(rawValue: "zip")
    public static let sqlite = Self(rawValue: "sqlite")
    public static let tarArchive = Self(rawValue: "tar-archive")
    public static let codeResources = Self(rawValue: "code-resources")
    public static let pemCertificate = Self(rawValue: "pem-certificate")
    public static let derCertificate = Self(rawValue: "der-certificate")
    public static let pkcs7 = Self(rawValue: "pkcs7")
    public static let pkcs12 = Self(rawValue: "pkcs12")
    public static let mobileprovision = Self(rawValue: "mobileprovision")
    public static let csr = Self(rawValue: "csr")
    public static let pemPublicKey = Self(rawValue: "pem-public-key")
    public static let rego = Self(rawValue: "rego"), ldif = Self(rawValue: "ldif"), turtle = Self(rawValue: "turtle")
    public static let storyboard = Self(rawValue: "storyboard"), xib = Self(rawValue: "xib")
    public static let xsd = Self(rawValue: "xsd"), xslt = Self(rawValue: "xslt")
    public static let rst = Self(rawValue: "rst"), quarto = Self(rawValue: "quarto"), mdx = Self(rawValue: "mdx")
    public static let sshPublicKey = Self(rawValue: "ssh-public-key")
    public static let jwt = Self(rawValue: "jwt"), jwk = Self(rawValue: "jwk"), jwks = Self(rawValue: "jwks")
    public static let cyclonedxSBOM = Self(rawValue: "cyclonedx-sbom"), spdxSBOM = Self(rawValue: "spdx-sbom")
    public static let cyclonedxSBOMXML = Self(rawValue: "cyclonedx-sbom-xml")
    public static let spdxTagValue = Self(rawValue: "spdx-tag-value")
    public static let spdxYAML = Self(rawValue: "spdx-yaml")
    public static let cyclonedxSBOMProtobuf = Self(rawValue: "cyclonedx-sbom-protobuf")
    public static let html = Self(rawValue: "html"), sql = Self(rawValue: "sql")
    public static let rust = Self(rawValue: "rust"), php = Self(rawValue: "php"), ruby = Self(rawValue: "ruby")
    public static let terraform = Self(rawValue: "terraform"), scss = Self(rawValue: "scss")
    public static let tsx = Self(rawValue: "tsx"), vue = Self(rawValue: "vue"), svelte = Self(rawValue: "svelte")
    public static let asciidoc = Self(rawValue: "asciidoc")
    public static let xcconfig = Self(rawValue: "xcconfig"), pbxproj = Self(rawValue: "pbxproj")
    public static let xcworkspace = Self(rawValue: "xcworkspace")
    public static let nix = Self(rawValue: "nix"), cue = Self(rawValue: "cue"), kdl = Self(rawValue: "kdl")
    public static let nim = Self(rawValue: "nim"), openscad = Self(rawValue: "openscad")
    public static let webAssemblyText = Self(rawValue: "webassembly-text")
    public static let objectiveC = Self(rawValue: "objective-c"), perl = Self(rawValue: "perl")
    public static let r = Self(rawValue: "r"), scala = Self(rawValue: "scala"), julia = Self(rawValue: "julia")
}

/// Stable identifier used to dispatch a format to its semantic inspector.
public enum InspectorID: String, Codable, Equatable, Sendable {
    case text, json, yaml, xml, plist, markdown, source, csv, diff, jsonl, log, toml, ini, dotenv, properties, windowsRegistry, fstab, email, icalendar, vcard, zip, tar, x509Certificate, security
}

/// Renderer strategy selected for the catalog's Finder thumbnail representation.
public enum ThumbnailStrategyID: String, Codable, Equatable, Sendable {
    case textLines, sourceCode, table
}

/// Settings section whose controls apply to a format's rendering behavior.
public enum FormatSettingsProfile: String, Codable, Equatable, Sendable {
    case text, source, markdown, structured, table, none
}

/// Delimiter identifiers shared by catalog metadata and table inspection settings.
public enum TableDelimiterID: String, Codable, Equatable, Sendable {
    case comma, tab
}

/// Versioned metadata describing a format's identity, detection, inspection, and presentations.
public struct FormatDefinition: Codable, Equatable, Sendable {
    /// Catalog lifecycle state; planned entries do not claim support or detection.
    public enum Status: String, Codable, Sendable { case supported, planned }
    /// Core inspector family selected for a supported catalog format.
    public enum InspectionKind: String, Codable, Sendable { case text, source, json, yaml, xml, plist, markdown, csv, diff, jsonl, log, toml, ini, dotenv, properties, windowsRegistry, fstab, email, icalendar, vcard, zip, tar, certificate, security }
    /// Stable settings and browsing category for a format definition.
    public enum Category: String, Codable, CaseIterable, Sendable {
        case text = "Text & Markup", source = "Source Code", web = "Web", configuration = "Configuration"
        case structured = "Structured Data", build = "Build & DevOps", security = "Security & Identity"
        case apple = "Apple", data = "Data"
    }
    /// Presentation identifiers are data contracts; renderers and their input adapters live in the UI layer.
    public enum RepresentationID: String, Codable, CaseIterable, Equatable, Sendable {
        case tree, pretty, raw, rendered, hex, source, table, diff
    }
    public let id: FormatID
    public let displayName: String
    public let category: Category
    public let extensions: [String]
    public let exactFilenames: [String]
    public let contentTypeIdentifiers: [String]
    public let inspectionKind: InspectionKind
    public let inspectorID: InspectorID?
    public let detectionRules: [FileTypeDefinition]?
    public let thumbnailStrategy: ThumbnailStrategyID?
    public let settingsProfile: FormatSettingsProfile?
    public let tableDelimiter: TableDelimiterID?
    public let defaultRepresentation: RepresentationID?
    public let sourceLanguage: SourceLanguage?
    /// Fixture reference used by the Settings preview sample picker.
    public struct ShowcaseExample: Codable, Equatable, Sendable {
        public let title: String
        public let path: String
    }
    public let showcaseFixture: String?
    public let showcaseVariants: [ShowcaseExample]?
    public let status: Status
    public let recognizedTextFallback: Bool?
    public let representations: [RepresentationID]?
    public let presentationOrder: [RepresentationID]?
    /// Per-format factory view order, used when the user has no category or format override.
    public let defaultViews: [RepresentationID]?

    /// Legacy catalog entries retain their current capabilities until migrated explicitly.
    public var availableRepresentations: [RepresentationID] {
        if let representations { return representations }
        switch inspectionKind {
        case .zip, .tar: return [.table, .hex]
        case .certificate: return id == .pemCertificate ? [.tree, .raw, .hex] : [.tree, .hex]
        case .security: return id == .mobileprovision || id == .pkcs12 ? [.tree, .hex] : [.tree, .raw, .hex]
        case .markdown: return [.rendered, .source]
        case .json, .yaml, .plist: return [.tree, .pretty, .raw]
        case .fstab: return [.tree, .raw]
        case .xml: return [.table, .tree, .pretty, .raw]
        case .source: return []
        case .csv: return [.table, .raw]
        case .diff: return [.diff, .raw]
        case .jsonl, .toml, .ini, .dotenv, .properties, .windowsRegistry, .email, .icalendar, .vcard: return [.tree, .raw]
        case .log: return [.table, .tree, .raw]
        default: return []
        }
    }

    public var effectiveInspectorID: InspectorID {
        if let inspectorID { return inspectorID }
        switch inspectionKind {
        case .zip: return .zip
        case .tar: return .tar
        case .certificate: return .x509Certificate
        case .security: return .security
        case .json: return .json
        case .yaml: return .yaml
        case .xml: return .xml
        case .plist: return .plist
        case .markdown: return .markdown
        case .source: return .source
        case .csv: return .csv
        case .diff: return .diff
        case .jsonl: return .jsonl
        case .log: return .log
        case .toml: return .toml
        case .ini: return .ini
        case .dotenv: return .dotenv
        case .properties: return .properties
        case .windowsRegistry: return .windowsRegistry
        case .fstab: return .fstab
        case .email: return .email
        case .icalendar: return .icalendar
        case .vcard: return .vcard
        case .text: return .text
        }
    }

    public var effectiveThumbnailStrategy: ThumbnailStrategyID {
        if let thumbnailStrategy { return thumbnailStrategy }
        return inspectionKind == .source ? .sourceCode : .textLines
    }

    public var effectiveSettingsProfile: FormatSettingsProfile {
        if let settingsProfile { return settingsProfile }
        switch inspectionKind {
        case .zip, .tar: return .table
        case .certificate: return .structured
        case .security: return .structured
        case .source: return .source
        case .text: return .text
        case .markdown: return .markdown
        case .json, .yaml, .xml, .plist, .fstab: return .structured
        case .csv: return .table
        case .diff, .jsonl, .log, .toml, .ini, .dotenv, .properties, .windowsRegistry: return .text
        case .email, .icalendar, .vcard: return .structured
        }
    }

    public var effectiveDefaultRepresentation: RepresentationID? {
        defaultRepresentation ?? availableRepresentations.first
    }

    public var resolvedDetectionRules: [FileTypeDefinition] {
        (detectionRules ?? []).map { rule in
            FileTypeDefinition(
                typeID: rule.typeID,
                filenames: rule.usesCatalogFilenames ? exactFilenames : rule.filenames,
                filenamePrefixes: rule.filenamePrefixes,
                multiExtensions: rule.multiExtensions,
                singleExtensions: rule.usesCatalogExtensions ? extensions.map { "." + $0 } : rule.singleExtensions,
                shebangInterpreters: rule.shebangInterpreters,
                systemUTIIdentifiers: rule.usesCatalogUTIs ? contentTypeIdentifiers : rule.systemUTIIdentifiers,
                supportsYAMLContentDetection: rule.supportsYAMLContentDetection,
                magicSignatures: rule.magicSignatures
            )
        }
    }

    public var settingsSection: String {
        switch effectiveSettingsProfile {
        case .source: "source"
        case .text, .table, .none: "text"
        case .markdown: "markdown"
        case .structured: "structured"
        }
    }
    /// Matches only catalog-facing names and identifiers, keeping search independent of detector heuristics.
    public func matchesSearch(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty || ([displayName, id.rawValue] + extensions + exactFilenames)
            .contains { $0.lowercased().contains(needle.hasPrefix(".") ? String(needle.dropFirst()) : needle) }
    }
}

/// Canonical product catalog. Planned entries never acquire detection claims implicitly.
public enum FormatCatalog {
    public static let all: [FormatDefinition] = {
        // This is versioned application data, verified by catalog/schema/showcase tests.
        guard let url = Bundle.module.url(forResource: "formats", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let definitions = try? JSONDecoder().decode([FormatDefinition].self, from: data) else {
            preconditionFailure("The bundled format catalog must be valid")
        }
        return definitions
    }()
    public static let supported: [FormatDefinition] = all.filter { $0.status == .supported }
    /// Returns the canonical metadata record, including planned entries used by settings explanations.
    public static func definition(for id: FormatID) -> FormatDefinition? { all.first { $0.id == id } }
    /// Filename matching is literal and case-sensitive; extensions are case-insensitive.
    public static func match(fileName: String) -> FormatDefinition? {
        // Basename matching avoids path prefixes; exact names win before a case-folded extension lookup.
        let name = (fileName as NSString).lastPathComponent
        if let exact = supported.first(where: { $0.exactFilenames.contains(name) }) { return exact }
        let normalizedName = name.lowercased()
        return supported
            .flatMap { definition in definition.extensions.map { (definition, $0.lowercased()) } }
            .filter { definition, suffix in
                if suffix.contains(".") { return normalizedName.hasSuffix("." + suffix) }
                return (name as NSString).pathExtension.lowercased() == suffix
            }
            .max {
                if $0.1.count != $1.1.count { return $0.1.count < $1.1.count }
                if $0.1 == "pub", $0.0.id != $1.0.id {
                    return $0.0.id == .pemPublicKey && $1.0.id == .sshPublicKey
                }
                return $0.0.sourceLanguage == nil && $1.0.sourceLanguage != nil
            }?.0
    }
    /// Finds exact filenames intentionally kept as plain-text fallbacks.
    public static func recognizedTextFormat(fileName: String) -> FormatDefinition? {
        // These exact filenames deliberately remain text fallbacks instead of claiming system UTIs.
        let extensionName = (fileName as NSString).pathExtension.lowercased()
        return all.first {
            $0.recognizedTextFallback == true
                && ($0.exactFilenames.contains(fileName)
                    || ($0.status == .supported && $0.extensions.contains { $0.lowercased() == extensionName }))
        }
    }
    /// Resolves a system type only when a supported catalog entry declares that language.
    public static func source(forSystemType identifier: String) -> SourceLanguage? {
        supported.first { $0.sourceLanguage != nil && $0.contentTypeIdentifiers.contains(identifier) }?.sourceLanguage
    }
    /// Searches catalog-facing labels and returns stable localized ordering, including planned entries.
    public static func search(_ query: String) -> [FormatDefinition] {
        // Search includes planned catalog entries; the settings UI separately filters unsupported entries.
        all.filter { $0.matchesSearch(query) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

extension PreviewInspectionResult {
    /// Actual renderer capability wins over a misleading filename or a planned catalog entry.
    public var formatDefinition: FormatDefinition? {
        // The completed inspector outcome takes precedence because detection can intentionally fall back.
        let id: FormatID
        if let additionalInspection { id = additionalInspection.formatID }
        else if plistInspection != nil,
                let selectedFormatID,
                FormatCatalog.definition(for: selectedFormatID)?.effectiveInspectorID == .plist { id = selectedFormatID }
        else if plistInspection != nil { id = .plist }
        else if jsonInspection != nil,
                let selectedFormatID,
                FormatCatalog.definition(for: selectedFormatID)?.effectiveInspectorID == .json { id = selectedFormatID }
        else if jsonInspection != nil { id = .json }
        else if csvInspection != nil {
            id = selectedFormatID ?? .init(rawValue: resolution.typeID == "tsv" ? "tsv" : "csv")
        }
        else if yamlInspection != nil { id = .yaml }
        else if xmlInspection != nil,
                let selectedFormatID,
                FormatCatalog.definition(for: selectedFormatID)?.effectiveInspectorID == .xml { id = selectedFormatID }
        else if xmlInspection != nil { id = .xml }
        else if markdownDocument != nil { id = selectedFormatID ?? .markdown }
        else if let sourceDocument, let selectedFormatID,
                FormatCatalog.definition(for: selectedFormatID)?.sourceLanguage == sourceDocument.language { id = selectedFormatID }
        else if let sourceDocument { id = .init(rawValue: sourceDocument.language.rawValue) }
        else if let selectedFormatID, let selected = FormatCatalog.definition(for: selectedFormatID),
                selected.status == .supported, selected.effectiveInspectorID == .text { id = selectedFormatID }
        else if let detected = FormatCatalog.definition(for: .init(rawValue: resolution.typeID)),
                detected.recognizedTextFallback == true, !detected.availableRepresentations.isEmpty { id = detected.id }
        else if let selectedFormatID,
                FormatCatalog.definition(for: selectedFormatID)?.status == .supported { id = selectedFormatID }
        else if let selectedFormatID, selectedFormatID != .text { id = selectedFormatID }
        else if !analysis.isBinary { id = .text }
        else { return nil }
        return FormatCatalog.definition(for: id)
    }
}
