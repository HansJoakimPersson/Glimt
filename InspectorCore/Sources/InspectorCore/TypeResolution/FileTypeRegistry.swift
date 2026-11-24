/// An ordered collection of validated type definitions.
public struct FileTypeRegistry: Equatable, Sendable {
    public let definitions: [FileTypeDefinition]

    /// Rejects duplicate type IDs and unsafe detector literals before they enter resolution.
    public init?(definitions: [FileTypeDefinition]) {
        guard Self.areValid(definitions) else { return nil }
        self.definitions = definitions
    }

    private init(trustedDefinitions: [FileTypeDefinition]) {
        self.definitions = trustedDefinitions
    }

    /// Built-in detector definitions are owned by the canonical format catalog.
    public static let `default` = FileTypeRegistry(
        trustedDefinitions: FormatCatalog.all.flatMap(\.resolvedDetectionRules) + [
            FileTypeDefinition(typeID: "generic-local", singleExtensions: [".local"])
        ]
    )

    /// Validates the entire registry so resolution never has to defend against malformed rule data.
    private static func areValid(_ definitions: [FileTypeDefinition]) -> Bool {
        var typeIDs = Set<String>()
        for definition in definitions {
            guard !definition.typeID.isEmpty,
                  definition.typeID != "unknown",
                  typeIDs.insert(definition.typeID).inserted,
                  definition.filenames.allSatisfy(isValidFilenameLiteral),
                  definition.filenamePrefixes.allSatisfy(isValidFilenameLiteral),
                  definition.multiExtensions.allSatisfy(isValidSuffix),
                  definition.singleExtensions.allSatisfy(isValidSuffix),
                  definition.shebangInterpreters.allSatisfy(isValidInterpreter),
                  definition.systemUTIIdentifiers.allSatisfy(isValidUTIIdentifier)
            else {
                return false
            }
        }
        return true
    }

    /// Filename rules are literal basenames and cannot traverse directories.
    private static func isValidFilenameLiteral(_ literal: String) -> Bool {
        !literal.isEmpty && !literal.contains("/")
    }

    /// Extension rules must include a dot and at least one following byte.
    private static func isValidSuffix(_ suffix: String) -> Bool {
        suffix.hasPrefix(".") && suffix.utf8.contains(where: { $0 != 0x2E }) && !suffix.contains("/")
    }

    /// Interpreter rules are single command tokens, never paths, options, assignments, or quoted input.
    private static func isValidInterpreter(_ interpreter: String) -> Bool {
        guard !interpreter.isEmpty,
              !interpreter.hasPrefix("-"),
              !interpreter.contains("="),
              !interpreter.contains("/"),
              !interpreter.contains("\0"),
              !interpreter.contains("'"),
              !interpreter.contains("\"")
        else {
            return false
        }

        return !interpreter.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x09...0x0D, 0x20:
                true
            default:
                false
            }
        }
    }

    /// Checks runtime UTIs against the restricted ASCII grammar accepted from host metadata.
    static func isRuntimeUTIIdentifierValid(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else { return false }
        return identifier.utf8.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x2E
        }
    }

    /// Validates the stable identifier grammar before catalog UTIs enter runtime matching.
    private static func isValidUTIIdentifier(_ identifier: String) -> Bool {
        isRuntimeUTIIdentifierValid(identifier)
    }
}
