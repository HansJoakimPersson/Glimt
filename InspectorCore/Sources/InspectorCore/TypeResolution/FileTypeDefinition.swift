/// Declarative detection rules and capabilities for one content type.
/// Magic signatures identify fixed format markers; they do not parse the matched format.
public enum MagicSignature: String, Codable, Equatable, Sendable {
    /// The exact eight-byte `bplist00` binary-plist header.
    case binaryPlist
    /// SQLite's fixed 16-byte database header.
    case sqlite
    /// POSIX ustar marker at offset 257 in the first header block.
    case tarUStar
}

/// Declarative matching signals and format capabilities used by the type resolver.
public struct FileTypeDefinition: Codable, Equatable, Sendable {
    public let typeID: String
    public let filenames: [String]
    public let filenamePrefixes: [String]
    public let multiExtensions: [String]
    public let singleExtensions: [String]
    public let shebangInterpreters: [String]
    public let systemUTIIdentifiers: [String]
    public let supportsYAMLContentDetection: Bool
    public let magicSignatures: [MagicSignature]
    public let usesCatalogFilenames: Bool
    public let usesCatalogExtensions: Bool
    public let usesCatalogUTIs: Bool

    /// Creates declarative match rules; `FileTypeRegistry` validates literals before using them.
    public init(
        typeID: String,
        filenames: [String] = [],
        filenamePrefixes: [String] = [],
        multiExtensions: [String] = [],
        singleExtensions: [String] = [],
        shebangInterpreters: [String] = [],
        systemUTIIdentifiers: [String] = [],
        supportsYAMLContentDetection: Bool = false,
        magicSignatures: [MagicSignature] = [],
        usesCatalogFilenames: Bool = false,
        usesCatalogExtensions: Bool = false,
        usesCatalogUTIs: Bool = false
    ) {
        self.typeID = typeID
        self.filenames = filenames
        self.filenamePrefixes = filenamePrefixes
        self.multiExtensions = multiExtensions
        self.singleExtensions = singleExtensions
        self.shebangInterpreters = shebangInterpreters
        self.systemUTIIdentifiers = systemUTIIdentifiers
        self.supportsYAMLContentDetection = supportsYAMLContentDetection
        self.magicSignatures = magicSignatures
        self.usesCatalogFilenames = usesCatalogFilenames
        self.usesCatalogExtensions = usesCatalogExtensions
        self.usesCatalogUTIs = usesCatalogUTIs
    }

    private enum CodingKeys: String, CodingKey {
        case typeID, filenames, filenamePrefixes, multiExtensions, singleExtensions
        case shebangInterpreters, systemUTIIdentifiers, supportsYAMLContentDetection, magicSignatures
        case usesCatalogFilenames, usesCatalogExtensions, usesCatalogUTIs
    }

    /// Decodes older catalog data with empty/false defaults for fields added in later schema versions.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        typeID = try values.decode(String.self, forKey: .typeID)
        filenames = try values.decodeIfPresent([String].self, forKey: .filenames) ?? []
        filenamePrefixes = try values.decodeIfPresent([String].self, forKey: .filenamePrefixes) ?? []
        multiExtensions = try values.decodeIfPresent([String].self, forKey: .multiExtensions) ?? []
        singleExtensions = try values.decodeIfPresent([String].self, forKey: .singleExtensions) ?? []
        shebangInterpreters = try values.decodeIfPresent([String].self, forKey: .shebangInterpreters) ?? []
        systemUTIIdentifiers = try values.decodeIfPresent([String].self, forKey: .systemUTIIdentifiers) ?? []
        supportsYAMLContentDetection = try values.decodeIfPresent(Bool.self, forKey: .supportsYAMLContentDetection) ?? false
        magicSignatures = try values.decodeIfPresent([MagicSignature].self, forKey: .magicSignatures) ?? []
        usesCatalogFilenames = try values.decodeIfPresent(Bool.self, forKey: .usesCatalogFilenames) ?? false
        usesCatalogExtensions = try values.decodeIfPresent(Bool.self, forKey: .usesCatalogExtensions) ?? false
        usesCatalogUTIs = try values.decodeIfPresent(Bool.self, forKey: .usesCatalogUTIs) ?? false
    }
}
