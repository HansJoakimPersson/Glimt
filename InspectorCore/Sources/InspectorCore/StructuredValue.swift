import Foundation

/// Ordered structured values shared by the JSON and YAML inspectors. Raw is retained separately.
public indirect enum StructuredValue: Equatable, Sendable {
    case object([StructuredMember])
    case array([StructuredValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

/// One ordered key/value pair in a structured object.
public struct StructuredMember: Equatable, Sendable {
    public let key: String
    public let value: StructuredValue
}

/// Caller limits may reduce, but never disable, the security ceilings.
public struct StructuredInspectionLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumDepth: Int
    public let maximumValues: Int
    public let maximumOutputBytes: Int

    public init(maximumBytes: Int = 1_048_576, maximumDepth: Int = 64,
                maximumValues: Int = 10_000, maximumOutputBytes: Int = 2_097_152) {
        self.maximumBytes = min(max(maximumBytes, 0), 1_048_576)
        self.maximumDepth = min(max(maximumDepth, 0), 64)
        self.maximumValues = min(max(maximumValues, 0), 10_000)
        self.maximumOutputBytes = min(max(maximumOutputBytes, 0), 2_097_152)
    }
}

/// User-safe parser outcome that explains incomplete, invalid, or unsupported content.
public struct InspectionDiagnostic: Equatable, Sendable {
    /// Stable machine-readable diagnostic category shared by inspectors and renderers.
    public enum Code: String, Sendable { case parseError = "PARSE_ERROR", limitExceeded = "LIMIT_EXCEEDED", truncated = "TRUNCATED", unsupported = "UNSUPPORTED" }
    public let code: Code
    public let message: String
}
