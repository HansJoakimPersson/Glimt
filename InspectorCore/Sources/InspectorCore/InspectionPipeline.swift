import Foundation

/// Semantic result produced by a registered format inspector. Raw bytes remain on the request/result.
public enum InspectionOutcome: Sendable {
    case text
    case json(JSONInspectionResult)
    case yaml(YAMLInspectionResult)
    case xml(XMLInspectionResult)
    case plist(PlistInspectionResult)
    case markdown(MarkdownDocument)
    case source(SourceDocument)
    case csv(CSVInspectionResult)
    case additional(AdditionalInspectionResult)
    case zip(ZIPArchiveListing)
    case tar(TARArchiveListing)
    case certificate(FormatID, X509CertificateInspection)
    case security(SecurityFormatInspection)
    /// The inspector rejected the input; renderers keep the raw view and surface the diagnostics.
    case fallback([InspectionDiagnostic])
    case cancelled
}

/// The bounded, immutable input shared by registered inspectors.
public struct InspectionRequest: Sendable {
    public let bytes: Data
    public let fileSize: Int
    public let fileName: String
    public let systemUTI: String?
    public let analysis: TextAnalysis
    public let format: FormatDefinition?
    public let sourceLanguage: SourceLanguage?
    public let markdownOptions: MarkdownOptions
    public let csvDelimiter: CSVDelimiter
    /// The inspected file, for inspectors whose metadata lies beyond the bounded prefix.
    public let fileURL: URL?

    /// Creates the shared inspector input, including bounded bytes and precomputed detection evidence.
    init(bytes: Data, fileSize: Int, fileName: String, systemUTI: String?, analysis: TextAnalysis,
         format: FormatDefinition?, sourceLanguage: SourceLanguage?, markdownOptions: MarkdownOptions,
         csvDelimiter: CSVDelimiter, fileURL: URL? = nil) {
        self.bytes = bytes
        self.fileSize = fileSize
        self.fileName = fileName
        self.systemUTI = systemUTI
        self.analysis = analysis
        self.format = format
        self.sourceLanguage = sourceLanguage
        self.markdownOptions = markdownOptions
        self.csvDelimiter = csvDelimiter
        self.fileURL = fileURL
    }
}

/// Implementations are explicitly registered; no reflection or runtime type discovery is used.
public protocol FormatInspector: Sendable {
    var id: InspectorID { get }
    /// Inspects the immutable bounded request and returns its semantic result or Raw fallback.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome
}

/// Explicit dispatcher that maps stable inspector identifiers to one implementation each.
public struct FormatInspectorRegistry: Sendable {
    /// Construction failures raised when multiple implementations claim one identifier.
    public enum RegistrationError: Error, Equatable {
        case duplicateInspector(InspectorID)
    }

    private let inspectors: [InspectorID: any FormatInspector]

    /// Registers exactly one implementation per stable inspector ID and rejects ambiguous dispatch.
    public init(_ inspectors: [any FormatInspector]) throws {
        var registered: [InspectorID: any FormatInspector] = [:]
        for inspector in inspectors {
            // Duplicate IDs would silently shadow an implementation, so reject the registry up front.
            guard registered[inspector.id] == nil else { throw RegistrationError.duplicateInspector(inspector.id) }
            registered[inspector.id] = inspector
        }
        self.inspectors = registered
    }

    /// Reports whether the registry has an implementation for this stable inspector identifier.
    public func contains(_ id: InspectorID) -> Bool { inspectors[id] != nil }

    /// Dispatches to the registered inspector; unknown IDs safely retain the plain-text fallback.
    func inspect(_ id: InspectorID, request: InspectionRequest) throws -> InspectionOutcome {
        guard let inspector = inspectors[id] else { return .text }
        return try inspector.inspect(request)
    }

    public static let builtIn: FormatInspectorRegistry = {
        // The list is the explicit Core extension point for executable inspector implementations.
        let values: [any FormatInspector] = [
            PlainTextFormatInspector(), JSONFormatInspector(), YAMLFormatInspector(), XMLFormatInspector(),
            PlistFormatInspector(), MarkdownFormatInspector(), SourceFormatInspector(), CSVFormatInspector(),
            DiffFormatInspector(), JSONLinesFormatInspector(), LogFormatInspector(),
            ConfigurationFormatInspector(id: .toml, dialect: .toml),
            ConfigurationFormatInspector(id: .ini, dialect: .ini),
            ConfigurationFormatInspector(id: .dotenv, dialect: .dotenv),
            ConfigurationFormatInspector(id: .properties, dialect: .javaProperties),
            FstabFormatInspector(),
            WindowsRegistryFormatInspector(),
            MailCalendarContactFormatInspector(id: .email),
            MailCalendarContactFormatInspector(id: .icalendar),
            MailCalendarContactFormatInspector(id: .vcard),
            ZIPFormatInspector(), TARFormatInspector(), X509CertificateFormatInspector(), SecurityDocumentFormatInspector()
        ]
        guard let registry = try? FormatInspectorRegistry(values) else {
            preconditionFailure("Built-in format inspectors must have unique identifiers")
        }
        return registry
    }()
}

/// Routes analyzed plain text without producing a secondary semantic representation.
private struct PlainTextFormatInspector: FormatInspector {
    let id: InspectorID = .text
    /// Plain text needs no semantic conversion; the shared renderer consumes the analyzed request.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome { .text }
}

/// Lists bounded ZIP central-directory metadata without opening or decoding members.
private struct ZIPFormatInspector: FormatInspector {
    let id: InspectorID = .zip
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        // The central directory sits at the end, so an archive beyond the prefix is read by offset instead.
        if request.bytes.count < request.fileSize, let url = request.fileURL {
            return .zip(try ZIPArchiveInspector.inspect(fileAt: url, fileSize: request.fileSize))
        }
        return .zip(try ZIPArchiveInspector.inspect(data: request.bytes, fileSize: request.fileSize))
    }
}

/// Lists bounded TAR headers without extracting or opening member data.
private struct TARFormatInspector: FormatInspector {
    let id: InspectorID = .tar
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let listing: TARArchiveListing
        if request.bytes.count < request.fileSize, let url = request.fileURL {
            listing = try TARArchiveInspector.inspect(fileAt: url, fileSize: request.fileSize)
        } else {
            listing = try TARArchiveInspector.inspect(data: request.bytes, fileSize: request.fileSize)
        }
        return .tar(listing)
    }
}

/// Extracts bounded X.509 certificate facts using Security without trust evaluation.
private struct X509CertificateFormatInspector: FormatInspector {
    let id: InspectorID = .x509Certificate
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        guard let formatID = request.format?.id else { return .text }
        let encoding: X509CertificateEncoding = formatID == .pemCertificate ? .pem : .der
        let result = try X509CertificateInspector.inspect(data: request.bytes, fileSize: request.fileSize,
                                                          encoding: encoding)
        return .certificate(formatID, result)
    }
}

/// Extracts allowlisted facts from local security documents without validating trust or signatures.
private struct SecurityDocumentFormatInspector: FormatInspector {
    let id: InspectorID = .security
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        guard let formatID = request.format?.id else { return .text }
        return .security(try SecurityFormatInspector.inspect(data: request.bytes, fileSize: request.fileSize,
                                                              formatID: formatID, fileURL: request.fileURL))
    }
}

/// Selects strict, JSONC, JSON5, or ZON parsing from the recognized filename extension.
private struct JSONFormatInspector: FormatInspector {
    let id: InspectorID = .json
    /// Converts the bounded bytes into JSON tree and pretty representations.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let extensionName = (request.fileName as NSString).pathExtension.lowercased()
        if extensionName == "zon" {
            return .json(try JSONInspector.inspectZON(bytes: request.bytes, fileSize: request.fileSize))
        }
        let syntax: JSONSyntax
        switch extensionName {
        case "jsonc": syntax = .jsonc
        case "json5": syntax = .json5
        default: syntax = .strict
        }
        let parsed = try JSONInspector.inspect(bytes: request.bytes, fileSize: request.fileSize, syntax: syntax)
        if request.format?.id == .geojson, parsed.diagnostics.isEmpty, let content = parsed.content,
           let summary = try GeoJSONInspector.summarize(content) {
            return .json(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                               rawIsComplete: parsed.rawIsComplete, content: content,
                               prettyText: parsed.prettyText, diagnostics: parsed.diagnostics,
                               domainSummary: summary))
        }
        if request.format?.id == .geojson, parsed.diagnostics.isEmpty {
            return .json(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                               rawIsComplete: parsed.rawIsComplete, content: parsed.content,
                               prettyText: parsed.prettyText,
                               diagnostics: [.init(code: .unsupported,
                                                   message: "Unsupported GeoJSON structure or coordinates. JSON remains available.")]))
        }
        if request.format?.id == .xcodeTestPlan {
            guard parsed.diagnostics.isEmpty, let content = parsed.content,
                  XcodeTestPlanSummary.make(from: content) != nil else {
                let diagnostics = parsed.diagnostics.isEmpty
                    ? [.init(code: .unsupported, message: "Unsupported Xcode test plan structure. Raw remains available.")]
                    : parsed.diagnostics
                return .json(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                                   rawIsComplete: parsed.rawIsComplete, content: nil,
                                   prettyText: nil, diagnostics: diagnostics))
            }
            return .json(parsed)
        }
        guard request.format?.id == .xcstrings else { return .json(parsed) }
        guard parsed.diagnostics.isEmpty, let content = parsed.content,
              AppleStringCatalogSummary.make(from: content) != nil else {
            let diagnostics = parsed.diagnostics.isEmpty
                ? [.init(code: .unsupported, message: "Unsupported string catalog structure. Raw remains available.")]
                : parsed.diagnostics
            return .json(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                               rawIsComplete: parsed.rawIsComplete, content: nil,
                               prettyText: nil, diagnostics: diagnostics))
        }
        return .json(parsed)
    }
}

/// Converts a bounded request into YAML documents and structured projections.
private struct YAMLFormatInspector: FormatInspector {
    let id: InspectorID = .yaml
    /// Converts the bounded bytes into YAML documents and their structured projections.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        .yaml(try YAMLInspector.inspect(bytes: request.bytes, fileSize: request.fileSize))
    }
}

/// Parses bounded XML into a safe semantic tree with a Raw fallback on errors.
private struct XMLFormatInspector: FormatInspector {
    let id: InspectorID = .xml
    /// Converts the bounded bytes into an XML tree while preserving Raw on parse failure.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let parsed = try XMLInspector.inspect(bytes: request.bytes, fileSize: request.fileSize)
        if let formatID = request.format?.id, [.kml, .gpx].contains(formatID), parsed.diagnostics.isEmpty {
            if let root = parsed.root, let summary = GeospatialXMLInspector.summarize(root: root, formatID: formatID) {
                return .xml(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                                  rawIsComplete: parsed.rawIsComplete, root: parsed.root,
                                  prettyText: parsed.prettyText, diagnostics: parsed.diagnostics,
                                  domainSummary: summary))
            }
            return .xml(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                              rawIsComplete: parsed.rawIsComplete, root: parsed.root,
                              prettyText: parsed.prettyText,
                              diagnostics: [.init(code: .unsupported,
                                                  message: "The XML root or coordinates are unsupported for the selected geospatial format. XML remains available.")]))
        }
        guard request.format?.id == .xcscheme else { return .xml(parsed) }
        guard parsed.diagnostics.isEmpty, case .element(let root)? = parsed.root,
              root.name.split(separator: ":").last == "Scheme",
              let version = root.attributes.first(where: { $0.name == "version" })?.value,
              version.split(separator: ".").count == 2,
              version.split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            let diagnostics = parsed.diagnostics.isEmpty
                ? [.init(code: .unsupported, message: "Unsupported Xcode scheme structure. Raw remains available.")]
                : parsed.diagnostics
            return .xml(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                              rawIsComplete: parsed.rawIsComplete, root: nil,
                              prettyText: nil, diagnostics: diagnostics))
        }
        return .xml(parsed)
    }
}

/// Parses XML or binary property lists after the inspector's structural preflight.
private struct PlistFormatInspector: FormatInspector {
    let id: InspectorID = .plist
    /// Converts XML or binary property lists after their bounded structural preflight.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let parsed = try PlistInspector.inspect(bytes: request.bytes, fileSize: request.fileSize)
        guard let formatID = request.format?.id,
              [.privacyManifest, .codeResources].contains(formatID) else { return .plist(parsed) }
        let isValid = parsed.diagnostics.isEmpty && parsed.content.map { content in
            formatID == .privacyManifest
                ? ApplePrivacyManifestSummary.make(from: content) != nil
                : AppleCodeResourcesSummary.make(from: content) != nil
        } == true
        guard isValid else {
            let diagnostics = parsed.diagnostics.isEmpty
                ? [.init(code: .unsupported, message: "Unsupported Apple metadata structure. Raw remains available.")]
                : parsed.diagnostics
            return .plist(.init(rawBytes: parsed.rawBytes, rawText: parsed.rawText,
                                rawIsComplete: parsed.rawIsComplete, content: nil,
                                prettyText: nil, diagnostics: diagnostics, isBinary: parsed.isBinary))
        }
        return .plist(parsed)
    }
}

/// Applies the request's explicit Markdown options and returns semantic Markdown metadata.
private struct MarkdownFormatInspector: FormatInspector {
    let id: InspectorID = .markdown
    /// Builds Markdown semantics from the already decoded text and explicit render options.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        .markdown(try MarkdownInspector.inspect(analysis: request.analysis, options: request.markdownOptions))
    }
}

/// Applies source highlighting only to readable text with a resolved language.
private struct SourceFormatInspector: FormatInspector {
    let id: InspectorID = .source
    /// Uses source highlighting only when both readable text and a resolved language are available.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        guard !request.analysis.isBinary, let language = request.sourceLanguage else { return .text }
        let literateHaskell = (request.fileName as NSString).pathExtension.lowercased() == "lhs"
        return .source(try SourceCodeInspector.inspect(analysis: request.analysis, language: language,
                                                       literateHaskell: literateHaskell))
    }
}

/// Parses a table using the delimiter selected by the catalog and settings.
private struct CSVFormatInspector: FormatInspector {
    let id: InspectorID = .csv
    /// Parses the catalog-selected delimiter without guessing a different CSV dialect.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        .csv(try CSVInspector.inspect(bytes: request.bytes, fileSize: request.fileSize,
                                      delimiter: request.csvDelimiter))
    }
}

/// Parses unified diff text and exposes its result as an additional structured representation.
private struct DiffFormatInspector: FormatInspector {
    let id: InspectorID = .diff

    /// Inspects the request's analyzed text and wraps the bounded diff model.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        .additional(.diff(try DiffInspector.inspect(text: request.analysis.text, fileSize: request.fileSize)))
    }
}

/// Parses newline-delimited JSON and adapts records to the common structured representation.
private struct JSONLinesFormatInspector: FormatInspector {
    let id: InspectorID = .jsonl
    /// Parses complete input lines while preserving truncation and time-limit diagnostics.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let result = try StreamInspector.jsonLines(request.analysis.text, isComplete: !request.analysis.truncated && !request.analysis.isBinary)
        return .additional(.records(.jsonl, .array(result.records), result.diagnostics, result.rawIsComplete, nil))
    }
}

/// Parses supported log formats and maps normalized event fields into structured rows.
private struct LogFormatInspector: FormatInspector {
    let id: InspectorID = .log
    /// Converts parsed log records into line, timestamp, source, severity, and message fields.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let result = try StreamInspector.log(request.analysis.text, isComplete: !request.analysis.truncated && !request.analysis.isBinary)
        let rows = result.records.map { record in
            var values: [StructuredMember] = [
                .init(key: "line", value: .number(String(record.line))),
                .init(key: "timestamp", value: record.timestamp.map(StructuredValue.string) ?? .null),
                .init(key: "source", value: record.source.map(StructuredValue.string) ?? .null),
                .init(key: "level", value: record.level.map(StructuredValue.string) ?? .null),
                .init(key: "message", value: .string(record.message))
            ]
            if let fields = record.fields { values.append(.init(key: "source_fields", value: .object(fields))) }
            return StructuredValue.object(values)
        }
        return .additional(.records(.log, .array(rows), result.diagnostics, result.rawIsComplete, result.table))
    }
}

/// Parses one catalog-selected configuration dialect and adapts entries to structured rows.
private struct ConfigurationFormatInspector: FormatInspector {
    let id: InspectorID
    let dialect: ConfigurationDialect
    /// Parses the configured dialect while carrying input completeness into the result.
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let result = try ConfigurationInspector.inspect(request.analysis.text, dialect: dialect,
                                                        isComplete: !request.analysis.truncated && !request.analysis.isBinary)
        let rows = result.entries.map { entry in
            StructuredValue.object([
                .init(key: "line", value: .number(String(entry.line))),
                .init(key: "section", value: entry.section.map(StructuredValue.string) ?? .null),
                .init(key: "key", value: .string(entry.key)),
                .init(key: "value", value: .string(entry.value))
            ])
        }
        return .additional(.records(FormatID(rawValue: id.rawValue), .array(rows), result.diagnostics, result.rawIsComplete, nil))
    }
}

/// Parses the catalog-selected fstab text and adapts inert mount rows to the shared Tree renderer.
private struct FstabFormatInspector: FormatInspector {
    let id: InspectorID = .fstab

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        guard let formatID = request.format?.id else { return .text }
        let result = try FstabInspector.inspect(request.analysis.text, isComplete: !request.analysis.truncated)
        return .additional(.records(formatID, .array(result.rows), result.diagnostics, result.rawIsComplete, nil))
    }
}

/// Parses `.reg` exports into inert rows; it never applies registry changes.
private struct WindowsRegistryFormatInspector: FormatInspector {
    let id: InspectorID = .windowsRegistry

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let result = try WindowsRegistryInspector.inspect(request.analysis.text,
            isComplete: !request.analysis.truncated && !request.analysis.isBinary)
        let rows = result.entries.map { entry in
            StructuredValue.object([
                .init(key: "line", value: .number(String(entry.line))),
                .init(key: "key", value: .string(entry.keyPath)),
                .init(key: "name", value: .string(entry.name)),
                .init(key: "type", value: .string(entry.kind)),
                .init(key: "data", value: .string(entry.data))
            ])
        }
        return .additional(.records(.windowsRegistry, .array(rows), result.diagnostics, result.rawIsComplete, nil))
    }
}

/// Adapts bounded mail, calendar, and contact facts to the common structured renderer.
private struct MailCalendarContactFormatInspector: FormatInspector {
    let id: InspectorID

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        let result: CalendarContactInspection?
        let emailResult: EmailMessageInspection?
        switch id {
        case .email:
            emailResult = try EmailMessageInspector.inspect(request.analysis.text,
                isComplete: !request.analysis.truncated && !request.analysis.isBinary)
            result = nil
        case .icalendar:
            result = try CalendarContactInspector.inspectICalendar(request.analysis.text,
                isComplete: !request.analysis.truncated && !request.analysis.isBinary)
            emailResult = nil
        case .vcard:
            result = try CalendarContactInspector.inspectVCard(request.analysis.text,
                isComplete: !request.analysis.truncated && !request.analysis.isBinary)
            emailResult = nil
        default: return .text
        }
        let formatID = FormatID(rawValue: id.rawValue)
        let rows: [StructuredValue]
        let diagnostics: [InspectionDiagnostic]
        let isComplete: Bool
        if let emailResult {
            rows = emailResult.rows.map { row in
                .object([.init(key: "section", value: .string(row.section)), .init(key: "name", value: .string(row.name)),
                         .init(key: "value", value: .string(row.value)), .init(key: "line", value: .number(String(row.line)))])
            }
            diagnostics = emailResult.diagnostics
            isComplete = emailResult.rawIsComplete
        } else if let result {
            rows = result.rows.map { row in
                .object([.init(key: "section", value: .string(row.section)), .init(key: "name", value: .string(row.name)),
                         .init(key: "parameters", value: .string(row.parameters)), .init(key: "value", value: .string(row.value)),
                         .init(key: "line", value: .number(String(row.line)))])
            }
            diagnostics = result.diagnostics
            isComplete = result.rawIsComplete
        } else { return .text }
        return .additional(.records(formatID, .array(rows), diagnostics, isComplete, nil))
    }
}

/// Records the selected inspector, format metadata, and detection explanation for an inspection.
struct InspectionRoute: Sendable {
    let inspectorID: InspectorID
    let format: FormatDefinition?
    let sourceLanguage: SourceLanguage?
    let formatName: String
    let detectionReason: String
}

struct InspectionSelection: Sendable {
    let automatic: InspectionRoute
    let effective: InspectionRoute
}

/// Applies existing precedence policy, then delegates parsing by the selected definition's inspector ID.
enum InspectionPipeline {
    /// Reported when the watchdog stopped the selected inspector (ADR-040).
    static let timeoutDiagnostic = InspectionDiagnostic(code: .limitExceeded,
                                                        message: "Inspection took too long; showing raw content")

    /// Selects and runs one inspector against the same bounded request, mapping parser failures to Raw fallback.
    /// With `runsInspector` false the route is still selected, but the outcome is the timeout fallback.
    static func inspect(bytes: Data, fileSize: Int, fileName: String, systemUTI: String?,
                        markdownOptions: MarkdownOptions, formatOverride: PreviewInspectionResult.FormatOverride?,
                        analysis: TextAnalysis, resolution: ResolvedContentType, fileURL: URL? = nil,
                        registry: FormatInspectorRegistry = .builtIn,
                        runsInspector: Bool = true) -> (InspectionRoute, InspectionOutcome) {
        let routes = select(fileName: fileName, systemUTI: systemUTI, bytes: bytes, analysis: analysis,
                            resolution: resolution, formatOverride: formatOverride)
        return inspect(route: routes.effective, bytes: bytes, fileSize: fileSize, fileName: fileName,
                       systemUTI: systemUTI, markdownOptions: markdownOptions, analysis: analysis,
                       fileURL: fileURL, registry: registry, rejectBinaryTextRoute: false,
                       runsInspector: runsInspector)
    }

    /// Inspects with a route frozen from earlier, bounded routing evidence.
    static func inspect(route: InspectionRoute, bytes: Data, fileSize: Int, fileName: String, systemUTI: String?,
                        markdownOptions: MarkdownOptions, analysis: TextAnalysis, fileURL: URL? = nil,
                        registry: FormatInspectorRegistry = .builtIn,
                        rejectBinaryTextRoute: Bool = true,
                        runsInspector: Bool = true) -> (InspectionRoute, InspectionOutcome) {
        guard runsInspector else { return (route, .fallback([timeoutDiagnostic])) }
        if rejectBinaryTextRoute && analysis.isBinary && [.source, .markdown, .log, .diff, .toml, .ini, .dotenv, .properties,
                                 .windowsRegistry, .fstab, .email, .icalendar, .vcard].contains(route.inspectorID) {
            return (route, .fallback([InspectionDiagnostic(code: .unsupported,
                message: "Input is binary; showing raw content")]))
        }
        let request = InspectionRequest(bytes: bytes, fileSize: fileSize, fileName: fileName,
            systemUTI: systemUTI, analysis: analysis, format: route.format,
            sourceLanguage: route.sourceLanguage, markdownOptions: markdownOptions,
            csvDelimiter: route.format?.tableDelimiter == .tab ? .tab : .comma, fileURL: fileURL)
        do {
            return (route, try registry.inspect(route.inspectorID, request: request))
        } catch is CancellationError {
            // Preserve cancellation as a distinct outcome so callers can discard stale work.
            return (route, .cancelled)
        } catch TARArchiveError.cancelled {
            return (route, .cancelled)
        } catch {
            // Inspector failures keep the original text/raw representation available to renderers.
            return (route, .fallback([fallbackDiagnostic(for: error)]))
        }
    }

    /// Classifies an inspector failure without echoing input-derived detail.
    private static func fallbackDiagnostic(for error: Error) -> InspectionDiagnostic {
        switch error {
        case ZIPArchiveError.incompleteInput, X509CertificateError.incompleteInput:
            return InspectionDiagnostic(code: .truncated, message: "Input is incomplete; showing raw content")
        case ZIPArchiveError.limitExceeded, X509CertificateError.inputLimitExceeded,
             X509CertificateError.certificateCountLimitExceeded:
            return InspectionDiagnostic(code: .limitExceeded, message: "Inspection limit reached; showing raw content")
        case ZIPArchiveError.unsupported:
            return InspectionDiagnostic(code: .unsupported, message: "Unsupported structure; showing raw content")
        case TARArchiveError.incompleteInput:
            return InspectionDiagnostic(code: .truncated, message: "Input is incomplete; showing raw content")
        case TARArchiveError.limitExceeded:
            return InspectionDiagnostic(code: .limitExceeded, message: "Inspection limit reached; showing raw content")
        case TARArchiveError.unsupported, TARArchiveError.compressionUnavailable:
            return InspectionDiagnostic(code: .unsupported, message: "Unsupported structure; showing raw content")
        default:
            return InspectionDiagnostic(code: .parseError, message: "Could not be parsed; showing raw content")
        }
    }

    /// Applies explicit overrides first, then structured signatures and filename evidence, and
    /// finally falls back to a safe text or binary route.
    static func select(fileName: String, systemUTI: String?, bytes: Data, analysis: TextAnalysis,
                       resolution: ResolvedContentType,
                       formatOverride: PreviewInspectionResult.FormatOverride?) -> InspectionSelection {
        let automatic = selectRoute(fileName: fileName, systemUTI: systemUTI, bytes: bytes, analysis: analysis,
                                    resolution: resolution, formatOverride: nil)
        let effective = formatOverride == nil ? automatic : selectRoute(fileName: fileName, systemUTI: systemUTI,
            bytes: bytes, analysis: analysis, resolution: resolution, formatOverride: formatOverride)
        return InspectionSelection(automatic: automatic, effective: effective)
    }

    private static func selectRoute(fileName: String, systemUTI: String?, bytes: Data, analysis: TextAnalysis,
                                    resolution: ResolvedContentType,
                                    formatOverride: PreviewInspectionResult.FormatOverride?) -> InspectionRoute {
        let named = FormatCatalog.match(fileName: fileName)
        let sourceDetection = SourceDetector.detect(fileName: fileName, systemUTI: systemUTI, analysis: analysis)
        if let formatOverride {
            if formatOverride == .zip {
                let isZipName = (fileName as NSString).pathExtension.lowercased() == "zip"
                if isZipName, let zip = FormatCatalog.definition(for: .zip), zip.status == .supported {
                    return route(.zip, format: zip, reason: "userOverride")
                }
            }
            if formatOverride == .tar, let tar = FormatCatalog.definition(for: .tarArchive), tar.status == .supported {
                return route(.tar, format: tar, reason: "userOverride")
            }
            if case .certificate(let formatID) = formatOverride,
               let definition = FormatCatalog.definition(for: formatID), definition.status == .supported,
               Self.certificateEncoding(for: formatID, fileName: fileName) != nil {
                return route(.x509Certificate, format: definition, reason: "userOverride")
            }
            if case .security(let formatID) = formatOverride,
               let definition = FormatCatalog.definition(for: formatID), definition.status == .supported,
               definition.effectiveInspectorID == .security,
               (formatID != .pkcs12 || Self.hasPKCS12Suffix(fileName)) {
                return route(.security, format: definition, reason: "userOverride")
            }
            if analysis.isBinary, formatOverride != .plist {
                return route(.text, format: nil, name: "Binary data", reason: "userOverride")
            }
            switch formatOverride {
            case .zip: return route(.text, format: nil, name: "Binary data", reason: "invalidOverride")
            case .tar: return route(.text, format: nil, name: "Binary data", reason: "invalidOverride")
            case .certificate: return route(.text, format: nil, name: "Binary data", reason: "invalidOverride")
            case .security: return route(.text, format: nil, name: "Binary data", reason: "invalidOverride")
            case .text:
                return route(.text, format: FormatCatalog.definition(for: .text), name: "Plain text", reason: "userOverride")
            case .json: return route(.json, format: .json, reason: "userOverride")
            case .yaml: return route(.yaml, format: .yaml, reason: "userOverride")
            case .xml: return route(.xml, format: .xml, reason: "userOverride")
            case .plist: return route(.plist, format: .plist, reason: "userOverride")
            case .markdown: return route(.markdown, format: .markdown, reason: "userOverride")
            case .mermaid: return route(.text, format: .mermaid, reason: "userOverride")
            case .diff: return route(.diff, format: .diff, reason: "userOverride")
            case .jsonl: return route(.jsonl, format: .jsonl, reason: "userOverride")
            case .log: return route(.log, format: .log, reason: "userOverride")
            case .toml: return route(.toml, format: .toml, reason: "userOverride")
            case .ini: return explicitRoute(.ini, format: .ini, reason: "userOverride")
            case .dotenv: return explicitRoute(.dotenv, format: .dotenv, reason: "userOverride")
            case .properties: return explicitRoute(.properties, format: .properties, reason: "userOverride")
            case .windowsRegistry: return explicitRoute(.windowsRegistry, format: .windowsRegistry, reason: "userOverride")
            case .email: return explicitRoute(.email, format: .email, reason: "userOverride")
            case .icalendar: return explicitRoute(.icalendar, format: .icalendar, reason: "userOverride")
            case .vcard: return explicitRoute(.vcard, format: .vcard, reason: "userOverride")
            case .source(let language):
                return route(.source, format: FormatCatalog.supported.first { $0.sourceLanguage == language },
                             sourceLanguage: language, name: language.displayName, reason: "userOverride")
            case .csv(let id):
                let format = FormatCatalog.definition(for: id)
                return route(.csv, format: format, name: format?.displayName ?? "CSV", reason: "userOverride")
            }
        }

        if let named, named.id == .zip, named.status == .supported {
            return route(.zip, format: named, reason: "fileExtension")
        }
        if let named, named.id == .tarArchive, named.status == .supported {
            return route(.tar, format: named, reason: "fileExtension")
        }
        if let named, named.id == .pkcs12, named.status == .supported {
            return route(.security, format: named, reason: "fileExtension")
        }
        if let named, named.id == .sqlite, named.status == .supported {
            return route(.security, format: named, reason: "fileExtension")
        }
        if resolution.typeID == FormatID.sqlite.rawValue,
           let sqlite = FormatCatalog.definition(for: .sqlite), sqlite.status == .supported {
            return route(.security, format: sqlite,
                         reason: resolution.byteEvidence.first(where: { $0.signalKind == .magicSignature })?.isWinningTypeEvidence == true ? "magicBytes" : "fileExtension")
        }
        if resolution.typeID == FormatID.tarArchive.rawValue,
           let tar = FormatCatalog.definition(for: .tarArchive), tar.status == .supported {
            return route(.tar, format: tar,
                         reason: resolution.byteEvidence.first(where: { $0.signalKind == .magicSignature })?.isWinningTypeEvidence == true ? "magicBytes" : "fileExtension")
        }
        let isPublicKeyFile = (fileName as NSString).pathExtension.lowercased() == "pub"
            && [FormatID.pemPublicKey, .sshPublicKey].contains(named?.id ?? .text)
        if isPublicKeyFile {
            if SecurityFormatInspector.recognizesOpenSSHPublicKey(bytes),
               let format = FormatCatalog.definition(for: .sshPublicKey), format.status == .supported {
                return route(.security, format: format, reason: "contentProbe")
            }
            if SecurityFormatInspector.recognizesPEMPublicKey(bytes),
               let format = FormatCatalog.definition(for: .pemPublicKey), format.status == .supported {
                return route(.security, format: format, reason: "contentProbe")
            }
            return route(.text, format: nil, name: "Public key text", reason: "contentProbe")
        }
        if let named, [.pemCertificate, .derCertificate].contains(named.id), named.status == .supported {
            return route(.x509Certificate, format: named, reason: "fileExtension")
        }
        if let named, named.id == .sshPublicKey, named.status == .supported {
            guard !analysis.isBinary, SecurityFormatInspector.recognizesOpenSSHPublicKey(bytes) else {
                let name = analysis.isBinary ? "Binary data" : "Public key text"
                return route(.text, format: nil, name: name, reason: "contentProbe")
            }
            return route(.security, format: named, reason: "contentProbe")
        }
        if let named, named.effectiveInspectorID == .security, named.status == .supported {
            return route(.security, format: named, reason: "fileExtension")
        }

        if let named, named.id == .fstab, named.status == .supported,
           fileName == "fstab", !analysis.isBinary,
           !bytes.starts(with: Data("bplist00".utf8)) {
            return route(.fstab, format: named, reason: "exactFilename")
        }

        let mermaidUTI = "com.glimt.mermaid-source"
        let hasMermaidIdentity = named?.id == .mermaid || (named == nil && systemUTI == mermaidUTI)
        let canProbeLogContent = !hasMermaidIdentity && (named == nil || [.json, .jsonl, .text].contains(named?.id ?? .text))
        if !analysis.isBinary, canProbeLogContent, sourceDetection.language == nil,
           StreamInspector.recognizesLogContent(analysis.text) {
            return route(.log, format: .log, reason: "contentProbe")
        }

        let isJSONOrYAML = [FormatID.json, .yaml].contains(named?.id ?? .text)
            || named?.effectiveInspectorID == .json
        let hasXMLPrefix = analysis.text.utf8.drop(while: { [9, 10, 13, 32].contains($0) }).first == 60
        let plistUTIs = ["com.apple.property-list", "com.apple.xml-property-list", "com.apple.binary-property-list"]
        let binaryPlist = bytes.starts(with: Data("bplist00".utf8))
        let hasKnownFormatName = isJSONOrYAML || [FormatID.plist, .xml, .markdown, .mermaid, .csv, .tsv].contains(named?.id ?? .text)
            || sourceDetection.reason == .fileExtension || sourceDetection.reason == .exactFilename
        let mayUseStructuredUTI = !hasKnownFormatName && !analysis.isBinary
        let isPlist = named?.effectiveInspectorID == .plist || binaryPlist
            || (named?.id != FormatID(rawValue: "mobileconfig") && hasXMLPrefix
                && PlistInspector.looksLikePropertyList(bytes: bytes))
            || (mayUseStructuredUTI && plistUTIs.contains(systemUTI ?? ""))
        if isPlist {
            let plistFormat = named?.effectiveInspectorID == .plist ? named : FormatCatalog.definition(for: .plist)
            return route(.plist, format: plistFormat,
                         reason: binaryPlist ? "magicBytes" : named?.effectiveInspectorID == .plist ? "fileExtension" : plistUTIs.contains(systemUTI ?? "") ? "systemUTI" : "contentProbe")
        }

        let isXML = !isJSONOrYAML && (named?.effectiveInspectorID == .xml
            || [FormatID.xml, FormatID(rawValue: "mobileconfig")].contains(named?.id ?? .text)
            || (mayUseStructuredUTI && systemUTI == "public.xml")
            || (hasXMLPrefix && analysis.text.hasPrefix("<?xml") && sourceDetection.language == nil
                && ![FormatID.markdown, .csv, .tsv].contains(named?.id ?? .text)))
        if isXML {
            let format = named?.effectiveInspectorID == .xml ? named : FormatCatalog.definition(for: .xml)
            return route(.xml, format: format,
                         reason: named?.effectiveInspectorID == .xml ? "fileExtension" : systemUTI == "public.xml" ? "systemUTI" : "contentProbe")
        }

        if !analysis.isBinary, hasMermaidIdentity {
            return route(.text, format: .mermaid, reason: named?.id == .mermaid ? "fileExtension" : "systemUTI")
        }

        let isMarkdown = named?.inspectionKind == .markdown
            || (named == nil && systemUTI == "net.daringfireball.markdown" && sourceDetection.language == nil)
        if isMarkdown {
            return route(.markdown, format: named ?? FormatCatalog.definition(for: .markdown),
                         reason: named == nil ? "systemUTI" : "fileExtension")
        }

        let specialized = isJSONOrYAML || isPlist || isXML
        if !analysis.isBinary, !specialized, let language = sourceDetection.language {
            let format = named?.sourceLanguage == language ? named : FormatCatalog.supported.first { $0.sourceLanguage == language }
            return route(.source, format: format, sourceLanguage: language, name: format?.displayName ?? language.displayName,
                         reason: sourceDetection.reason.rawValue)
        }
        if !analysis.isBinary, resolution.typeID == FormatID.fstab.rawValue {
            return route(.text, format: FormatCatalog.definition(for: .text), name: "Plain text",
                         reason: fallbackReason(resolution))
        }
        if !analysis.isBinary, let format = named, format.effectiveInspectorID != .text {
            return route(format.effectiveInspectorID, format: format, sourceLanguage: format.sourceLanguage,
                         reason: "fileExtension")
        }
        if !analysis.isBinary, let format = named {
            let name = format.id == .text ? "Plain text" : format.displayName
            return route(.text, format: format, name: name, reason: "fileExtension")
        }
        if !analysis.isBinary, let format = FormatCatalog.definition(for: FormatID(rawValue: resolution.typeID)),
           format.id != .fstab,
           format.status == .supported, format.effectiveInspectorID != .text {
            let reason = resolution.evidence.contains { $0.signalKind == .systemUTI } ? "systemUTI" : fallbackReason(resolution)
            return route(format.effectiveInspectorID, format: format, sourceLanguage: format.sourceLanguage,
                         name: format.sourceLanguage?.displayName, reason: reason)
        }
        if !analysis.isBinary, let format = named, format.status == .supported,
           format.effectiveInspectorID == .text {
            return route(.text, format: format, reason: "fileExtension")
        }
        if analysis.isBinary { return route(.text, format: nil, name: "Binary data", reason: "binary") }
        if let named, named.status == .supported, named.id != .text,
           named.effectiveInspectorID == .text {
            return route(.text, format: named, name: named.displayName, reason: "fileExtension")
        }
        let fallback = FormatCatalog.recognizedTextFormat(fileName: (fileName as NSString).lastPathComponent)
        return route(.text, format: fallback, name: fallback.map { fallbackName(resolution.typeID, defaultName: $0.displayName) } ?? fallbackName(resolution.typeID),
                     reason: fallbackReason(resolution))
    }

    /// Combines catalog routing with explicit fallback metadata used when no definition matches.
    private static func route(_ fallbackID: InspectorID, format: FormatDefinition?, sourceLanguage: SourceLanguage? = nil,
                              name: String? = nil, reason: String) -> InspectionRoute {
        InspectionRoute(inspectorID: format?.effectiveInspectorID ?? fallbackID, format: format,
                        sourceLanguage: sourceLanguage ?? format?.sourceLanguage,
                        formatName: name ?? format?.displayName ?? "Plain text",
                        detectionReason: reason)
    }

    /// Resolves a stable format ID through the catalog before using the shared route constructor.
    private static func route(_ fallbackID: InspectorID, format: FormatID, reason: String) -> InspectionRoute {
        route(fallbackID, format: FormatCatalog.definition(for: format), reason: reason)
    }

    /// Applies an explicit dialect override even when the catalog's normal preview uses Source.
    private static func explicitRoute(_ inspectorID: InspectorID, format: FormatID, reason: String) -> InspectionRoute {
        let definition = FormatCatalog.definition(for: format)
        return InspectionRoute(inspectorID: inspectorID, format: definition,
                               sourceLanguage: definition?.sourceLanguage,
                               formatName: definition?.displayName ?? "Plain text",
                               detectionReason: reason)
    }

    private static func certificateEncoding(for formatID: FormatID, fileName: String) -> X509CertificateEncoding? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if formatID == .pemCertificate, ["pem", "crt"].contains(ext) { return .pem }
        if formatID == .derCertificate, ["der", "cer"].contains(ext) { return .der }
        return nil
    }

    private static func hasPKCS12Suffix(_ fileName: String) -> Bool {
        ["p12", "pfx"].contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Maps a small set of generic detector IDs to user-facing names for the text fallback.
    private static func fallbackName(_ typeID: String, defaultName: String = "Plain text") -> String {
        switch typeID {
        case "makefile": "Makefile"
        case "dockerfile": "Dockerfile"
        case "dotenv": "dotenv"
        case "generic-local": "Generic Local"
        default: defaultName
        }
    }

    /// Converts the winning detector signal into the stable reason vocabulary shown in Inquiry.
    private static func fallbackReason(_ resolution: ResolvedContentType) -> String {
        guard resolution.confidence.value > 0,
              let signal = resolution.evidence.first(where: { $0.signalKind != .utiConflict && $0.score.value == resolution.confidence.value })?.signalKind else { return "plainText" }
        return switch signal {
        case .filename: "exactFilename"
        case .multiExtension, .singleExtension: "fileExtension"
        case .systemUTI: "systemUTI"
        case .shebang: "shebang"
        case .yamlMapping, .yamlDocumentMarker: "contentProbe"
        case .utiConflict: "plainText"
        }
    }
}
