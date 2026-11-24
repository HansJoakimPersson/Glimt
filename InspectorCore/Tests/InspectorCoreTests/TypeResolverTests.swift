import Foundation
import CryptoKit
import Darwin
import XCTest
import InspectorCore

final class TypeResolverTests: XCTestCase {
    func testMermaidCatalogAliasesAndExactUTIProduceCatalogEvidence() {
        let resolver = TypeResolver()
        let alias = resolver.resolve(fileName: "diagram.MMD", systemUTI: "public.swift-source")
        XCTAssertEqual(alias.typeID, "mermaid")
        let extensionEvidence = alias.evidence.first { $0.signalKind == .singleExtension }
        XCTAssertEqual(extensionEvidence?.value, ".mmd")

        let identifierOnly = resolver.resolve(fileName: "sample.unknown", systemUTI: "com.glimt.mermaid-source")
        XCTAssertEqual(identifierOnly.typeID, "mermaid")
        let utiEvidence = identifierOnly.evidence.first { $0.signalKind == .systemUTI }
        XCTAssertEqual(utiEvidence?.value, "com.glimt.mermaid-source")
        XCTAssertEqual(resolver.resolve(fileName: "sample.textbundle", systemUTI: "com.glimt.mermaid-source").typeID,
                       "textbundle", "A supported TextBundle filename outranks an unrelated Mermaid UTI")
    }

    func testSQLiteAndUstarMagicSignaturesIdentifyRenamedBinaryFiles() {
        let sqlite = TypeResolver().resolve(fileName: "renamed.bin",
            leadingBytes: Data("SQLite format 3\0".utf8), sampleIsComplete: true)
        XCTAssertEqual(sqlite.typeID, "sqlite")
        XCTAssertEqual(sqlite.byteEvidence.first?.status, .matched)
        XCTAssertEqual(sqlite.byteEvidence.first?.value, "SQLite format 3")
        XCTAssertTrue(sqlite.byteEvidence.first?.isWinningTypeEvidence == true)

        var tarHeader = Data(repeating: 0, count: 512)
        tarHeader.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
        let tar = TypeResolver().resolve(fileName: "renamed.bin", leadingBytes: tarHeader,
            sampleIsComplete: true)
        XCTAssertEqual(tar.typeID, "tar-archive")
        XCTAssertEqual(tar.byteEvidence.first?.status, .matched)
        XCTAssertEqual(tar.byteEvidence.first?.value, "ustar")
        XCTAssertTrue(tar.byteEvidence.first?.isWinningTypeEvidence == true)
    }

    func testFR005MagicBOMBinaryPlistSignatureRespectsStrongerNames() throws {
        let signature = Data("bplist00".utf8)

        let plist = TypeResolver().resolve(
            fileName: "sample",
            leadingBytes: signature,
            sampleIsComplete: true
        )
        XCTAssertEqual(plist.typeID, "plist")
        XCTAssertEqual(plist.confidence.value, 0.85)
        assertByteEvidence(
            plist,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "plist",
            magicScore: 0.85,
            magicWins: true,
            bomStatus: .noMatch
        )
        assertEvidenceVector(
            plist,
            values: Array(repeating: "no-match", count: 7),
            scores: Array(repeating: 0, count: 7)
        )

        let typedScript = TypeResolver().resolve(
            fileName: "foo.ts",
            leadingBytes: signature,
            sampleIsComplete: true
        )
        XCTAssertEqual(typedScript.typeID, "typescript")
        XCTAssertEqual(typedScript.confidence.value, 0.95)
        assertByteEvidence(
            typedScript,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "plist",
            magicScore: 0.85,
            bomStatus: .noMatch
        )
        assertEvidenceVector(
            typedScript,
            values: ["no-match", "no-match", ".ts", "no-match", "no-match", "no-match", "no-match"],
            scores: [0, 0, 0.95, 0, 0, 0, 0]
        )

        let namedFile = TypeResolver().resolve(
            fileName: "Makefile",
            leadingBytes: signature,
            sampleIsComplete: true
        )
        XCTAssertEqual(namedFile.typeID, "make")
        XCTAssertEqual(namedFile.confidence.value, 1)
        XCTAssertEqual(namedFile.evidence.first?.value, "makefile")
        XCTAssertFalse(namedFile.byteEvidence[0].isWinningTypeEvidence)

        let multiExtension = TypeResolver().resolve(
            fileName: "declaration.d.ts",
            leadingBytes: signature,
            sampleIsComplete: true
        )
        XCTAssertEqual(multiExtension.typeID, "typescript-declaration")
        XCTAssertEqual(multiExtension.confidence.value, 0.98)
        XCTAssertFalse(multiExtension.byteEvidence[0].isWinningTypeEvidence)

        let sameTypeRegistry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "plist", filenames: ["sample"], magicSignatures: [.binaryPlist])
        ]))
        let filenameWinner = TypeResolver(registry: sameTypeRegistry).resolve(
            fileName: "sample",
            leadingBytes: signature,
            sampleIsComplete: true
        )
        XCTAssertEqual(filenameWinner.typeID, "plist")
        XCTAssertEqual(filenameWinner.confidence.value, 1)
        XCTAssertFalse(filenameWinner.byteEvidence[0].isWinningTypeEvidence)
    }

    func testFR005MagicBOMSignatureEligibilityTiesAndConflicts() throws {
        let signature = Data("bplist00".utf8)
        let customDefinitions = [
            FileTypeDefinition(typeID: "zeta-plist", magicSignatures: [.binaryPlist, .binaryPlist]),
            FileTypeDefinition(typeID: "alpha-plist", magicSignatures: [.binaryPlist])
        ]
        let forward = TypeResolver(registry: try XCTUnwrap(FileTypeRegistry(definitions: customDefinitions)))
        let reverse = TypeResolver(registry: try XCTUnwrap(FileTypeRegistry(definitions: Array(customDefinitions.reversed()))))

        let first = forward.resolve(fileName: "sample", leadingBytes: signature, sampleIsComplete: true)
        let second = reverse.resolve(fileName: "sample", leadingBytes: signature, sampleIsComplete: true)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.typeID, "alpha-plist")
        XCTAssertEqual(first.confidence.value, 0.85)
        assertByteEvidence(
            first,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "alpha-plist",
            magicScore: 0.85,
            magicWins: true,
            bomStatus: .noMatch
        )

        let conflict = TypeResolver().resolve(
            fileName: "sample",
            leadingBytes: signature,
            systemUTI: "public.mpeg-2-transport-stream",
            sampleIsComplete: true
        )
        XCTAssertEqual(conflict.typeID, "plist")
        XCTAssertEqual(conflict.evidence.last?.signalKind, .utiConflict)
        XCTAssertEqual(conflict.evidence.count, 8)
        assertByteEvidence(
            conflict,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "plist",
            magicScore: 0.85,
            magicWins: true,
            bomStatus: .noMatch
        )

        let mappedUTI = TypeResolver().resolve(
            fileName: "sample",
            leadingBytes: signature,
            systemUTI: "public.yaml",
            sampleIsComplete: true
        )
        XCTAssertEqual(mappedUTI.typeID, "plist")
        XCTAssertEqual(mappedUTI.confidence.value, 0.85)
        XCTAssertEqual(mappedUTI.evidence.last?.signalKind, .utiConflict)
        XCTAssertEqual(mappedUTI.evidence.last?.value, "public.yaml")
        XCTAssertTrue(mappedUTI.byteEvidence[0].isWinningTypeEvidence)

        let noSignatures = TypeResolver(registry: try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "custom")
        ]))).resolve(fileName: "sample", leadingBytes: signature)
        assertByteEvidence(
            noSignatures,
            magicStatus: .unavailable,
            bomStatus: .noMatch
        )

        let emptyRegistry = TypeResolver(registry: try XCTUnwrap(FileTypeRegistry(definitions: [])))
        let emptyRegistryMagic = emptyRegistry.resolve(fileName: "sample", leadingBytes: signature)
        XCTAssertEqual(emptyRegistryMagic.typeID, "unknown")
        assertByteEvidence(
            emptyRegistryMagic,
            magicStatus: .unavailable,
            bomStatus: .noMatch
        )
        let emptyRegistryBOM = emptyRegistry.resolve(fileName: "sample", leadingBytes: Data([0xEF, 0xBB, 0xBF]))
        assertByteEvidence(
            emptyRegistryBOM,
            magicStatus: .unavailable,
            bomStatus: .matched,
            bomValue: TextEncoding.utf8BOM.rawValue,
            bomEncoding: .utf8BOM
        )
        let unavailablePrefix = emptyRegistry.resolve(fileName: "sample", leadingBytes: Data("bpl".utf8))
        assertByteEvidence(
            unavailablePrefix,
            magicStatus: .unavailable,
            bomStatus: .noMatch
        )
    }

    func testFR005MagicBOMSignaturePrefixesOffsetsAndExactHeader() {
        let resolver = TypeResolver()
        let signature = Array("bplist00".utf8)
        for length in 1..<signature.count {
            let incomplete = resolver.resolve(fileName: "sample", leadingBytes: Data(signature.prefix(length)))
            assertByteEvidence(incomplete, magicStatus: .incomplete, bomStatus: .noMatch)

            let confirmed = resolver.resolve(
                fileName: "sample",
                leadingBytes: Data(signature.prefix(length)),
                sampleIsComplete: true
            )
            assertByteEvidence(confirmed, magicStatus: .noMatch, bomStatus: .noMatch)
        }

        for wrongHeader in [
            Data("xbplist00".utf8),
            Data("bplist01".utf8),
            Data("BPLIST00".utf8)
        ] {
            let result = resolver.resolve(fileName: "sample", leadingBytes: wrongHeader, sampleIsComplete: true)
            XCTAssertEqual(result.typeID, "unknown")
            assertByteEvidence(result, magicStatus: .noMatch, bomStatus: .noMatch)
        }

        let malformedPayload = resolver.resolve(
            fileName: "sample",
            leadingBytes: Data(Array(signature) + [0x00, 0xFF]),
            sampleIsComplete: true
        )
        XCTAssertEqual(malformedPayload.typeID, "plist")
        assertByteEvidence(
            malformedPayload,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "plist",
            magicScore: 0.85,
            magicWins: true,
            bomStatus: .noMatch
        )

        let emptyInput = resolver.resolve(fileName: "sample", leadingBytes: Data(), sampleIsComplete: true)
        assertByteEvidence(emptyInput, magicStatus: .noMatch, bomStatus: .noMatch)
    }

    func testFR005MagicBOMBOMEncodingsAndEOFOverlapRules() {
        let resolver = TypeResolver()
        let encodings: [([UInt8], TextEncoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8BOM),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian)
        ]

        for (bytes, encoding) in encodings {
            let result = resolver.resolve(fileName: "sample", leadingBytes: Data(bytes), sampleIsComplete: true)
            XCTAssertEqual(result.typeID, "unknown", encoding.rawValue)
            XCTAssertEqual(result.confidence.value, 0, encoding.rawValue)
            assertByteEvidence(
                result,
                magicStatus: .noMatch,
                bomStatus: .matched,
                bomValue: encoding.rawValue,
                bomEncoding: encoding
            )
        }

        for prefix in [[UInt8(0xEF)], [0xEF, 0xBB], [0xFE], [0xFF], [0x00], [0x00, 0x00], [0x00, 0x00, 0xFE]] {
            let result = resolver.resolve(fileName: "sample", leadingBytes: Data(prefix))
            assertByteEvidence(result, magicStatus: .noMatch, bomStatus: .incomplete)

            let confirmed = resolver.resolve(fileName: "sample", leadingBytes: Data(prefix), sampleIsComplete: true)
            assertByteEvidence(confirmed, magicStatus: .noMatch, bomStatus: .noMatch)
        }

        for prefix in [[UInt8(0xFF), 0xFE], [0xFF, 0xFE, 0x00]] {
            let unconfirmed = resolver.resolve(fileName: "sample", leadingBytes: Data(prefix))
            assertByteEvidence(unconfirmed, magicStatus: .noMatch, bomStatus: .incomplete)

            let confirmed = resolver.resolve(fileName: "sample", leadingBytes: Data(prefix), sampleIsComplete: true)
            assertByteEvidence(
                confirmed,
                magicStatus: .noMatch,
                bomStatus: .matched,
                bomValue: TextEncoding.utf16LittleEndian.rawValue,
                bomEncoding: .utf16LittleEndian
            )
        }

        let mismatchAfterUTF16LE = resolver.resolve(
            fileName: "sample",
            leadingBytes: Data([0xFF, 0xFE, 0x00, 0x01])
        )
        assertByteEvidence(
            mismatchAfterUTF16LE,
            magicStatus: .noMatch,
            bomStatus: .matched,
            bomValue: TextEncoding.utf16LittleEndian.rawValue,
            bomEncoding: .utf16LittleEndian
        )

        let malformedRepeated = resolver.resolve(
            fileName: "sample",
            leadingBytes: Data([0xEF, 0xBB, 0xBF, 0x00, 0xEF, 0xBB, 0xBF]),
            sampleIsComplete: true
        )
        XCTAssertEqual(malformedRepeated.typeID, "unknown")
        assertByteEvidence(
            malformedRepeated,
            magicStatus: .noMatch,
            bomStatus: .matched,
            bomValue: TextEncoding.utf8BOM.rawValue,
            bomEncoding: .utf8BOM
        )
    }

    func testFR005MagicBOMOversizedSamplesUseOnlyTheSharedPrefix() {
        let sharedPrefix = Array("bplist00".utf8) + Array(repeating: 0x00, count: 65_536 - 8)
        let first = Data(sharedPrefix + [0x01])
        let second = Data(sharedPrefix + [0x02, 0x03, 0x04])
        let resolver = TypeResolver()
        let firstResult = resolver.resolve(fileName: "sample", leadingBytes: first, sampleIsComplete: true)
        let secondResult = resolver.resolve(fileName: "sample", leadingBytes: second, sampleIsComplete: true)
        XCTAssertEqual(firstResult, secondResult)
    }

    func testFR005cEvidenceVectorContract() throws {
        let resolver = TypeResolver()
        let yamlBytes = Data("name: Glimt\nversion: 1\n".utf8)
        let yaml = resolver.resolve(fileName: "config", leadingBytes: yamlBytes)
        XCTAssertEqual(yaml.typeID, "yaml")
        XCTAssertEqual(yaml.confidence.value, 0.75)
        assertEvidenceVector(
            yaml,
            values: ["no-match", "no-match", "no-match", "no-match", "yaml-mapping", "no-match", "no-match"],
            scores: [0, 0, 0, 0, 0.75, 0, 0]
        )

        let marked = resolver.resolve(fileName: "config", leadingBytes: Data("---\nname: Glimt\n".utf8))
        XCTAssertEqual(marked.typeID, "yaml")
        XCTAssertEqual(marked.confidence.value, 0.80)
        assertEvidenceVector(
            marked,
            values: ["no-match", "no-match", "no-match", "no-match", "yaml-mapping", "yaml-document-marker", "no-match"],
            scores: [0, 0, 0, 0, 0.75, 0.80, 0]
        )

        let negative = resolver.resolve(fileName: "ordinary")
        XCTAssertEqual(negative.typeID, "unknown")
        XCTAssertEqual(negative.confidence.value, 0)
        assertEvidenceVector(negative, values: Array(repeating: "no-match", count: 7), scores: Array(repeating: 0, count: 7))

        let losingShebang = resolver.resolve(fileName: "file.ts", leadingBytes: Data("#!/usr/bin/env python3\n".utf8))
        XCTAssertEqual(losingShebang.typeID, "typescript")
        XCTAssertEqual(losingShebang.confidence.value, 0.95)
        assertEvidenceVector(
            losingShebang,
            values: ["no-match", "no-match", ".ts", "python3", "no-match", "no-match", "no-match"],
            scores: [0, 0, 0.95, 0.90, 0, 0, 0]
        )

        let losingYAMLAndUTI = resolver.resolve(
            fileName: ".env.local",
            leadingBytes: Data("name: Glimt\nversion: 1\n".utf8),
            systemUTI: "public.yaml"
        )
        XCTAssertEqual(losingYAMLAndUTI.typeID, "dotenv")
        XCTAssertEqual(losingYAMLAndUTI.confidence.value, 1.0)
        assertEvidenceVector(
            losingYAMLAndUTI,
            values: [".env.local", "no-match", ".local", "no-match", "yaml-mapping", "no-match", "public.yaml"],
            scores: [1.0, 0, 0.95, 0, 0.75, 0, 0.60],
            conflict: "public.yaml"
        )

        let acceptedIncompletePrefix = resolver.resolve(
            fileName: "config",
            leadingBytes: Data(Array("a: b\nc: d\n".utf8) + [0xE2, 0x82])
        )
        XCTAssertEqual(acceptedIncompletePrefix.typeID, "yaml")
        assertEvidenceVector(
            acceptedIncompletePrefix,
            values: ["no-match", "no-match", "no-match", "no-match", "yaml-mapping", "no-match", "no-match"],
            scores: [0, 0, 0, 0, 0.75, 0, 0]
        )

        let transportStreamConflict = resolver.resolve(
            fileName: "foo.ts",
            systemUTI: "public.mpeg-2-transport-stream"
        )
        assertEvidenceVector(
            transportStreamConflict,
            values: ["no-match", "no-match", ".ts", "no-match", "no-match", "no-match", "public.mpeg-2-transport-stream"],
            scores: [0, 0, 0.95, 0, 0, 0, 0],
            conflict: "public.mpeg-2-transport-stream"
        )

        let transportStreamUnknown = resolver.resolve(
            fileName: "ordinary",
            systemUTI: "public.mpeg-2-transport-stream"
        )
        XCTAssertEqual(transportStreamUnknown.typeID, "unknown")
        assertEvidenceVector(
            transportStreamUnknown,
            values: ["no-match", "no-match", "no-match", "no-match", "no-match", "no-match", "public.mpeg-2-transport-stream"],
            scores: Array(repeating: 0, count: 7)
        )

        let customRegistry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "custom", filenames: ["Custom"])
        ]))
        let transportStreamCustom = TypeResolver(registry: customRegistry).resolve(
            fileName: "Custom",
            systemUTI: "public.mpeg-2-transport-stream"
        )
        XCTAssertEqual(transportStreamCustom.typeID, "custom")
        assertEvidenceVector(
            transportStreamCustom,
            values: ["custom", "no-match", "no-match", "no-match", "no-match", "no-match", "public.mpeg-2-transport-stream"],
            scores: [1.0, 0, 0, 0, 0, 0, 0]
        )
    }

    func testPublicConstructionAndDefaults() throws {
        let confidence = try XCTUnwrap(DetectionConfidence(value: 0.72))
        XCTAssertEqual(confidence.value, 0.72)

        let definition = FileTypeDefinition(typeID: "custom")
        XCTAssertEqual(definition.typeID, "custom")
        XCTAssertTrue(definition.filenames.isEmpty)
        XCTAssertTrue(definition.filenamePrefixes.isEmpty)
        XCTAssertTrue(definition.multiExtensions.isEmpty)
        XCTAssertTrue(definition.singleExtensions.isEmpty)
        XCTAssertTrue(definition.shebangInterpreters.isEmpty)
        XCTAssertTrue(definition.systemUTIIdentifiers.isEmpty)
        XCTAssertFalse(definition.supportsYAMLContentDetection)
        XCTAssertTrue(definition.magicSignatures.isEmpty)

        let suppliedRules = FileTypeDefinition(
            typeID: "preserved",
            filenames: ["Exact", "other"],
            filenamePrefixes: ["Prefix."],
            multiExtensions: [".d.ts"],
            singleExtensions: [".ts"],
            shebangInterpreters: ["Tool"],
            systemUTIIdentifiers: ["public.custom"],
            supportsYAMLContentDetection: true
        )
        XCTAssertEqual(suppliedRules.filenames, ["Exact", "other"])
        XCTAssertEqual(suppliedRules.filenamePrefixes, ["Prefix."])
        XCTAssertEqual(suppliedRules.multiExtensions, [".d.ts"])
        XCTAssertEqual(suppliedRules.singleExtensions, [".ts"])
        XCTAssertEqual(suppliedRules.shebangInterpreters, ["Tool"])
        XCTAssertEqual(suppliedRules.systemUTIIdentifiers, ["public.custom"])
        XCTAssertTrue(suppliedRules.supportsYAMLContentDetection)

        let magicRules = FileTypeDefinition(typeID: "plist", magicSignatures: [.binaryPlist])
        XCTAssertEqual(magicRules.magicSignatures, [.binaryPlist])

        let registry = try XCTUnwrap(FileTypeRegistry(definitions: [definition]))
        XCTAssertEqual(registry.definitions, [definition])
        XCTAssertEqual(TypeResolver().resolve(fileName: "file").typeID, "unknown")
    }

    func testDetectionConfidenceRejectsInvalidValues() {
        XCTAssertNil(DetectionConfidence(value: -0.000_001))
        XCTAssertNil(DetectionConfidence(value: 1.000_001))
        XCTAssertNil(DetectionConfidence(value: .nan))
        XCTAssertNil(DetectionConfidence(value: .infinity))
        XCTAssertNil(DetectionConfidence(value: -.infinity))
        XCTAssertNotNil(DetectionConfidence(value: 0))
        XCTAssertNotNil(DetectionConfidence(value: 1))
    }

    func testRegistryRejectsInvalidTypeIDsAndDuplicateIDs() {
        XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "")]))
        XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "unknown")]))
        XCTAssertNil(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "custom"), FileTypeDefinition(typeID: "custom")
        ]))
        XCTAssertNil(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "é"), FileTypeDefinition(typeID: "e\u{301}")
        ]))
    }

    func testRegistryRejectsInvalidFilenameAndPrefixLiterals() {
        XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "a", filenames: [""])]))
        XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "a", filenames: ["dir/file"])]))
        XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "a", filenamePrefixes: [""])]))
        XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "a", filenamePrefixes: [".env/"])]))
    }

    func testRegistryRejectsInvalidSuffixes() {
        for suffix in ["", "ts", ".", "..", "...", ".dir/file"] {
            XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "a", singleExtensions: [suffix])]))
            XCTAssertNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "a", multiExtensions: [suffix])]))
        }
    }

    func testRegistryRejectsInvalidInterpreterTokens() {
        for interpreter in ["", "usr/bin/python3", "python 3", "python\t3", "python\u{0}3", "'python3'", "\"python3\"", "-python", "python=3"] {
            XCTAssertNil(FileTypeRegistry(definitions: [
                FileTypeDefinition(typeID: "a", shebangInterpreters: [interpreter])
            ]), "Accepted invalid interpreter: \(interpreter.debugDescription)")
        }
    }

    func testRegistryAllowsEmptyRulesDuplicateLiteralsAndEmptyRegistry() throws {
        let first = FileTypeDefinition(typeID: "first", singleExtensions: [".same", ".same"])
        let second = FileTypeDefinition(typeID: "second", singleExtensions: [".same"])
        XCTAssertNotNil(FileTypeRegistry(definitions: []))
        XCTAssertNotNil(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "empty")]))
        XCTAssertEqual(FileTypeRegistry(definitions: [first, second])?.definitions, [first, second])
    }

    func testDuplicateRulesAndDefinitionOrderProduceOneBestDetectorResult() throws {
        let definitions = [
            FileTypeDefinition(typeID: "zeta", singleExtensions: [".same", ".same"]),
            FileTypeDefinition(typeID: "alpha", singleExtensions: [".same"])
        ]
        for ordered in [definitions, Array(definitions.reversed())] {
            let registry = try XCTUnwrap(FileTypeRegistry(definitions: ordered))
            let result = TypeResolver(registry: registry).resolve(fileName: "file.same")
            XCTAssertEqual(result.typeID, "alpha")
            XCTAssertEqual(result.confidence.value, 0.95)
            XCTAssertEqual(result.evidence.map(\.signalKind), Self.vectorKinds)
            XCTAssertEqual(result.evidence[2].value, ".same")
            XCTAssertEqual(result.evidence[2].score.value, 0.95)
        }
    }

    func testRegistryValidatesUTIIdentifiersWithoutNormalizingThem() throws {
        for identifier in ["", ".public", "public.", "public..text", "public text", "public/text", "public.é", "public_foo"] {
            XCTAssertNil(FileTypeRegistry(definitions: [
                FileTypeDefinition(typeID: "custom", systemUTIIdentifiers: [identifier])
            ]), identifier)
        }
        let registry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "custom", systemUTIIdentifiers: ["Public.Type-1", "Public.Type-1"])
        ]))
        XCTAssertEqual(registry.definitions[0].systemUTIIdentifiers, ["Public.Type-1", "Public.Type-1"])

        let overlapping = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "first", systemUTIIdentifiers: ["public.shared"]),
            FileTypeDefinition(typeID: "second", systemUTIIdentifiers: ["public.shared"])
        ]))
        XCTAssertEqual(overlapping.definitions.map(\.systemUTIIdentifiers), [["public.shared"], ["public.shared"]])
    }

    func testUTIMappingsSupportOrConflictWithLegacyWinner() {
        let resolver = TypeResolver()
        let supportedDeclaration = resolver.resolve(fileName: "foo.d.ts", systemUTI: "com.microsoft.typescript")
        XCTAssertEqual(supportedDeclaration.typeID, "typescript-declaration")
        XCTAssertEqual(supportedDeclaration.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(supportedDeclaration.evidence[1].value, ".d.ts")
        XCTAssertEqual(supportedDeclaration.evidence[1].score.value, 0.98)
        XCTAssertEqual(supportedDeclaration.evidence[6].score.value, 0.60)

        let pythonConflict = resolver.resolve(fileName: "file.ts", systemUTI: "public.python-script")
        XCTAssertEqual(pythonConflict.typeID, "typescript")
        XCTAssertEqual(pythonConflict.confidence.value, 0.95)
        XCTAssertEqual(pythonConflict.evidence.map(\.signalKind), Self.vectorKinds + [.utiConflict])
        XCTAssertEqual(pythonConflict.evidence[6].score.value, 0.60)
        XCTAssertEqual(pythonConflict.evidence.last?.value, "public.python-script")
        XCTAssertEqual(pythonConflict.evidence.last?.score.value, 0)
    }

    func testAC0051TransportStreamUTIConflict() {
        let result = TypeResolver().resolve(fileName: "foo.ts", systemUTI: "public.mpeg-2-transport-stream")
        XCTAssertEqual(result.typeID, "typescript")
        XCTAssertEqual(result.confidence.value, 0.95)
        XCTAssertEqual(result.evidence.map(\.signalKind), Self.vectorKinds + [.utiConflict])
        XCTAssertEqual(result.evidence[6].value, "public.mpeg-2-transport-stream")
        XCTAssertEqual(result.evidence.last?.value, "public.mpeg-2-transport-stream")
        XCTAssertEqual(result.evidence.last?.score.value, 0)
    }

    private func assertEvidenceVector(
        _ result: ResolvedContentType,
        values: [String],
        scores: [Double],
        conflict: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expectedKinds = Self.vectorKinds
        var expectedValues = values
        var expectedScores = scores
        if let conflict {
            expectedKinds.append(.utiConflict)
            expectedValues.append(conflict)
            expectedScores.append(0)
        }
        XCTAssertEqual(values.count, 7, file: file, line: line)
        XCTAssertEqual(scores.count, 7, file: file, line: line)
        XCTAssertEqual(result.evidence.map(\.signalKind), expectedKinds, file: file, line: line)
        XCTAssertEqual(result.evidence.map(\.value), expectedValues, file: file, line: line)
        XCTAssertEqual(result.evidence.map { $0.score.value }, expectedScores, file: file, line: line)
        XCTAssertTrue(result.evidence.allSatisfy { $0.score.value.isFinite }, file: file, line: line)
    }

    private func assertByteEvidence(
        _ result: ResolvedContentType,
        magicStatus: ByteDetectionEvidence.Status,
        magicValue: String? = nil,
        magicTypeID: String? = nil,
        magicScore: Double = 0,
        magicWins: Bool = false,
        bomStatus: ByteDetectionEvidence.Status,
        bomValue: String? = nil,
        bomEncoding: TextEncoding? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.byteEvidence.count, 2, file: file, line: line)
        XCTAssertEqual(result.byteEvidence.map(\.signalKind), [.magicSignature, .bom], file: file, line: line)
        guard result.byteEvidence.count == 2 else { return }

        let magic = result.byteEvidence[0]
        XCTAssertEqual(magic.status, magicStatus, file: file, line: line)
        XCTAssertEqual(magic.value, magicValue, file: file, line: line)
        XCTAssertEqual(magic.typeID, magicTypeID, file: file, line: line)
        XCTAssertNil(magic.encoding, file: file, line: line)
        XCTAssertEqual(magic.score.value, magicScore, file: file, line: line)
        XCTAssertEqual(magic.isWinningTypeEvidence, magicWins, file: file, line: line)

        let bom = result.byteEvidence[1]
        XCTAssertEqual(bom.status, bomStatus, file: file, line: line)
        XCTAssertEqual(bom.value, bomValue, file: file, line: line)
        XCTAssertNil(bom.typeID, file: file, line: line)
        XCTAssertEqual(bom.encoding, bomEncoding, file: file, line: line)
        XCTAssertEqual(bom.score.value, 0, file: file, line: line)
        XCTAssertFalse(bom.isWinningTypeEvidence, file: file, line: line)
    }

    private static let vectorKinds: [DetectionEvidence.SignalKind] = [
        .filename, .multiExtension, .singleExtension, .shebang,
        .yamlMapping, .yamlDocumentMarker, .systemUTI
    ]

    func testUTIFallbackTiesAreStableAndTypeScriptDeclarationIsCompatible() throws {
        let resolver = TypeResolver()
        let typescript = resolver.resolve(fileName: "plain", systemUTI: "com.microsoft.typescript")
        XCTAssertEqual(typescript.typeID, "typescript")
        XCTAssertEqual(typescript.confidence.value, 0.60)
        XCTAssertEqual(typescript.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(typescript.evidence[6].value, "com.microsoft.typescript")
        XCTAssertEqual(typescript.evidence[6].score.value, 0.60)
        XCTAssertEqual(resolver.resolve(fileName: "plain", systemUTI: "public.python-script").typeID, "python")
        let yaml = resolver.resolve(fileName: "plain", systemUTI: "public.yaml")
        XCTAssertEqual(yaml.typeID, "yaml")
        XCTAssertEqual(yaml.confidence.value, 0.60)
        XCTAssertEqual(yaml.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(yaml.evidence[6].value, "public.yaml")

        let definitions = [
            FileTypeDefinition(typeID: "zeta", systemUTIIdentifiers: ["public.shared"]),
            FileTypeDefinition(typeID: "alpha", systemUTIIdentifiers: ["public.shared"])
        ]
        for ordered in [definitions, Array(definitions.reversed())] {
            let registry = try XCTUnwrap(FileTypeRegistry(definitions: ordered))
            XCTAssertEqual(TypeResolver(registry: registry).resolve(fileName: "plain", systemUTI: "public.shared").typeID, "alpha")
        }
    }

    func testUTIInconclusiveRuntimeValuesAndConflictBoundaries() throws {
        let resolver = TypeResolver()
        for value in ["COM.MICROSOFT.TYPESCRIPT", "com..microsoft.typescript", " com.microsoft.typescript", "public.data", "public.content", "public.text", "public.plain-text", "dyn.foo", "public.unknown"] {
            XCTAssertEqual(resolver.resolve(fileName: "plain", systemUTI: value).typeID, "unknown", value)
            let losing = resolver.resolve(fileName: "file.ts", systemUTI: value)
            XCTAssertEqual(losing.evidence.count, 7, value)
            XCTAssertEqual(losing.evidence[6].value, "no-match", value)
            XCTAssertEqual(losing.evidence[6].score.value, 0, value)
        }
        XCTAssertEqual(resolver.resolve(fileName: "file.local", systemUTI: "public.mpeg-2-transport-stream").evidence.count, 7)

        let customRegistry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "custom", filenames: ["Custom"], systemUTIIdentifiers: ["public.mpeg-2-transport-stream"])
        ]))
        let custom = TypeResolver(registry: customRegistry).resolve(
            fileName: "Custom", systemUTI: "public.mpeg-2-transport-stream"
        )
        XCTAssertEqual(custom.typeID, "custom")
        XCTAssertEqual(custom.evidence.map(\.signalKind), Self.vectorKinds)

        let reservedMapping = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "typescript", singleExtensions: [".ts"], systemUTIIdentifiers: ["public.mpeg-2-transport-stream"])
        ]))
        let reservedConflict = TypeResolver(registry: reservedMapping).resolve(
            fileName: "foo.ts", systemUTI: "public.mpeg-2-transport-stream"
        )
        XCTAssertEqual(reservedConflict.evidence.map(\.signalKind), Self.vectorKinds + [.utiConflict])

        let registeredGeneric = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "data", systemUTIIdentifiers: ["public.data"])
        ]))
        XCTAssertEqual(TypeResolver(registry: registeredGeneric).resolve(fileName: "plain", systemUTI: "public.data").typeID, "unknown")

        let registeredInconclusives = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(
                typeID: "generic",
                systemUTIIdentifiers: ["public.data", "public.content", "public.text", "public.plain-text", "dyn.foo"]
            )
        ]))
        for identifier in ["public.data", "public.content", "public.text", "public.plain-text", "dyn.foo"] {
            XCTAssertEqual(
                TypeResolver(registry: registeredInconclusives).resolve(fileName: "plain", systemUTI: identifier).typeID,
                "unknown",
                identifier
            )
        }

        let dynamicRegistry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "dynamic", systemUTIIdentifiers: ["dyn.foo", "Dyn.foo"])
        ]))
        let dynamicResolver = TypeResolver(registry: dynamicRegistry)
        XCTAssertEqual(dynamicResolver.resolve(fileName: "plain", systemUTI: "dyn.foo").typeID, "unknown")
        XCTAssertEqual(dynamicResolver.resolve(fileName: "plain", systemUTI: "Dyn.foo").typeID, "dynamic")
        let conflictOnly = resolver.resolve(fileName: "plain", systemUTI: "public.mpeg-2-transport-stream")
        XCTAssertEqual(conflictOnly.typeID, "unknown")
        XCTAssertEqual(conflictOnly.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(conflictOnly.evidence[6].value, "public.mpeg-2-transport-stream")

        let emptyRegistry = try XCTUnwrap(FileTypeRegistry(definitions: []))
        let emptyRegistryConflictOnly = TypeResolver(registry: emptyRegistry).resolve(
            fileName: "plain", systemUTI: "public.mpeg-2-transport-stream"
        )
        XCTAssertEqual(emptyRegistryConflictOnly.typeID, "unknown")
        XCTAssertEqual(emptyRegistryConflictOnly.evidence[6].value, "public.mpeg-2-transport-stream")
        XCTAssertEqual(emptyRegistryConflictOnly.evidence[6].score.value, 0)
    }

    func testAC0052ExtensionlessYAML() {
        let result = TypeResolver().resolve(
            fileName: "config",
            leadingBytes: Data("name: Glimt\nversion: 1\n".utf8)
        )
        XCTAssertEqual(result.typeID, "yaml")
        XCTAssertEqual(result.confidence.value, 0.75)
        assertEvidenceVector(
            result,
            values: ["no-match", "no-match", "no-match", "no-match", "yaml-mapping", "no-match", "no-match"],
            scores: [0, 0, 0, 0, 0.75, 0, 0]
        )
    }

    func testYAMLContentEligibilityAndFilenameIndependence() throws {
        let sample = Data("name: Glimt\nversion: 1\n".utf8)
        let resolver = TypeResolver()
        for name in ["config", "config.unrecognized", ".config"] {
            XCTAssertEqual(resolver.resolve(fileName: name, leadingBytes: sample).typeID, "yaml", name)
        }
        XCTAssertEqual(resolver.resolve(fileName: "config", leadingBytes: sample).evidence.map(\.signalKind), Self.vectorKinds)

        let contradictingUTI = resolver.resolve(fileName: ".env.local", leadingBytes: sample, systemUTI: "public.yaml")
        XCTAssertEqual(contradictingUTI.typeID, "dotenv")
        XCTAssertEqual(contradictingUTI.evidence[0].score.value, 1.0)
        XCTAssertEqual(contradictingUTI.evidence[2].score.value, 0.95)
        XCTAssertEqual(contradictingUTI.evidence[4].score.value, 0.75)
        XCTAssertEqual(contradictingUTI.evidence[6].score.value, 0.60)
        XCTAssertEqual(contradictingUTI.evidence.last?.signalKind, .utiConflict)

        let custom = try XCTUnwrap(FileTypeRegistry(definitions: [FileTypeDefinition(typeID: "custom")]))
        let disabledYAML = TypeResolver(registry: custom).resolve(fileName: "config", leadingBytes: sample)
        XCTAssertEqual(disabledYAML.typeID, "unknown")
        assertEvidenceVector(disabledYAML, values: Array(repeating: "no-match", count: 7), scores: Array(repeating: 0, count: 7))
        let noDefinitions = TypeResolver(registry: try XCTUnwrap(FileTypeRegistry(definitions: [])))
            .resolve(fileName: "config", leadingBytes: sample)
        XCTAssertEqual(noDefinitions.typeID, "unknown")
        assertEvidenceVector(noDefinitions, values: Array(repeating: "no-match", count: 7), scores: Array(repeating: 0, count: 7))

        let stronger = resolver.resolve(fileName: ".env.local", leadingBytes: sample)
        XCTAssertEqual(stronger.typeID, "dotenv")
        XCTAssertEqual(stronger.confidence.value, 1.0)
        XCTAssertEqual(stronger.evidence.map(\.signalKind), Self.vectorKinds)

        let eligibleDefinitions = [
            FileTypeDefinition(typeID: "zeta-yaml", supportsYAMLContentDetection: true),
            FileTypeDefinition(typeID: "alpha-yaml", supportsYAMLContentDetection: true)
        ]
        let orderedRegistry = try XCTUnwrap(FileTypeRegistry(definitions: Array(eligibleDefinitions.reversed())))
        XCTAssertEqual(TypeResolver(registry: orderedRegistry).resolve(fileName: "config", leadingBytes: sample).typeID, "alpha-yaml")
    }

    func testYAMLMarkerEvidenceAndEvidenceOrdering() {
        let marked = TypeResolver().resolve(
            fileName: "config",
            leadingBytes: Data("# config\r\n--- \t# document\r\ngem: tapioca\r\n".utf8)
        )
        XCTAssertEqual(marked.typeID, "yaml")
        XCTAssertEqual(marked.confidence.value, 0.80)
        XCTAssertEqual(marked.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(marked.evidence[4].score.value, 0.75)
        XCTAssertEqual(marked.evidence[5].score.value, 0.80)

        let withUTI = TypeResolver().resolve(
            fileName: "config",
            leadingBytes: Data("---\na: b\n".utf8),
            systemUTI: "public.yaml"
        )
        XCTAssertEqual(withUTI.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(withUTI.confidence.value, 0.80)
        XCTAssertEqual(withUTI.evidence[6].score.value, 0.60)

        let markerOnly = TypeResolver().resolve(fileName: "config", leadingBytes: Data("---\n".utf8))
        XCTAssertEqual(markerOnly.typeID, "unknown")
        XCTAssertEqual(markerOnly.evidence[4].score.value, 0)
        XCTAssertEqual(markerOnly.evidence[5].score.value, 0)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data("one: value\n".utf8)).typeID, "unknown")
    }

    func testYAMLGrammarAcceptsMappingsCommentsAndIndentedSequences() {
        let accepted = [
            "a: b\nc: d\n",
            "# first\n   # second\nname: Glimt\nversion:\t1\n",
            "a:\n  nested: yes\nlist:\n  - one\n  -\t two\n",
            "a: b\rc: d\r",
            "a: b\r\nc: d\r\n"
        ]
        for input in accepted {
            XCTAssertEqual(
                TypeResolver().resolve(fileName: "config", leadingBytes: Data(input.utf8)).typeID,
                "yaml",
                input.debugDescription
            )
        }
    }

    func testYAMLGrammarRejectsUnsupportedAndNonYAMLInputs() {
        let rejected = [
            "ordinary prose\nnext line\n", "https://example.test/path\nname: value\n",
            "{\"name\": \"value\"}\n", "[one, two]\n", "'quoted key': value\nother: value\n",
            "? complex\nkey: value\n", "\tkey: value\nother: value\n", "key : value\nother: value\n",
            "key:value\nother: value\n", "- item\nkey: value\n", "-\nkey: value\n",
            "key:\n- item\n", "key: value\n!tag\n", "key: value\n*alias\n", "key: value\n{flow: map}\n",
            "key: value\n---\nother: value\n", "---\na: b\n---\n", "---x\na: b\n",
            "key: value\n\0other: value\n", "key: value\n\u{7F}\n", "key: value\n\u{01}\n"
        ]
        for input in rejected {
            XCTAssertEqual(
                TypeResolver().resolve(fileName: "config", leadingBytes: Data(input.utf8)).typeID,
                "unknown",
                input.debugDescription
            )
        }
        XCTAssertEqual(
            TypeResolver().resolve(fileName: "config", leadingBytes: Data([0x61, 0x3A, 0x20, 0xFF, 0x0A, 0x62, 0x3A, 0x20, 0x63, 0x0A])).typeID,
            "unknown"
        )
    }

    func testYAMLBOMAndExactWhitespaceBoundaries() {
        let bomSample = Data([0xEF, 0xBB, 0xBF] + Array("a: b\nc: d\n".utf8))
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: bomSample).typeID, "yaml")

        let markerCases = ["---\na: b\n", "--- # x\na: b\n", "---\t# x\na: b\n", "--- \t# x\na: b\n"]
        for input in markerCases {
            XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(input.utf8)).typeID, "yaml", input)
        }
        for input in ["---#x\na: b\n", "---\n\ta: b\n"] {
            XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(input.utf8)).typeID, "unknown", input)
        }

        var bomAtLimit = [UInt8](arrayLiteral: 0xEF, 0xBB, 0xBF)
        bomAtLimit.append(contentsOf: Array("a:".utf8))
        bomAtLimit.append(contentsOf: repeatElement(0x20, count: 4_092))
        bomAtLimit.append(0x0A)
        bomAtLimit.append(contentsOf: Array("b: c\n".utf8))
        XCTAssertEqual(bomAtLimit.prefix(4_097).count, 4_097)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(bomAtLimit)).typeID, "unknown")

        var bomExact = [UInt8](arrayLiteral: 0xEF, 0xBB, 0xBF)
        bomExact.append(contentsOf: Array("a:".utf8))
        bomExact.append(contentsOf: repeatElement(0x20, count: 4_091))
        bomExact.append(0x0A)
        bomExact.append(contentsOf: Array("b: c\n".utf8))
        XCTAssertEqual(bomExact.prefix(4_096).count, 4_096)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(bomExact)).typeID, "yaml")
    }

    func testYAMLLineAndPhysicalLineLimitsPreservePriorEvidence() {
        var exactLine = Array("a:".utf8)
        exactLine.append(contentsOf: repeatElement(0x20, count: 4_094))
        exactLine.append(0x0A)
        exactLine.append(contentsOf: Array("b: c\n".utf8))
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(exactLine)).typeID, "yaml")

        var tooLongFirstLine = Array("a:".utf8)
        tooLongFirstLine.append(contentsOf: repeatElement(0x20, count: 4_095))
        tooLongFirstLine.append(0x0A)
        tooLongFirstLine.append(contentsOf: Array("b: c\nc: d\n".utf8))
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(tooLongFirstLine)).typeID, "unknown")

        var priorEvidence = Array("a: b\nc: d\n".utf8)
        priorEvidence.append(contentsOf: repeatElement(0x20, count: 4_097))
        priorEvidence.append(0x0A)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(priorEvidence)).typeID, "yaml")

        let comments254 = String(repeating: "# ignored\n", count: 254)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data((comments254 + "a: b\nc: d\n").utf8)).typeID, "yaml")
        let crlfComments254 = String(repeating: "# ignored\r\n", count: 254)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data((crlfComments254 + "a: b\r\nc: d\r\n").utf8)).typeID, "yaml")
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data((comments254 + "a: b\nc: d\nignored: value\n").utf8)).typeID, "yaml")
        let comments255 = String(repeating: "# ignored\n", count: 255)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data((comments255 + "a: b\nc: d\n").utf8)).typeID, "unknown")
    }

    func testYAMLIncompleteTailAndByteCeilingDoNotAffectAcceptedPrefix() {
        let valid = Array("a: b\nc: d\n".utf8)
        let incomplete = TypeResolver().resolve(fileName: "config", leadingBytes: Data(valid + [0xE2, 0x82]))
        XCTAssertEqual(incomplete.typeID, "yaml")
        XCTAssertEqual(incomplete.evidence[4].value, "yaml-mapping")
        XCTAssertEqual(incomplete.evidence[4].score.value, 0.75)
        XCTAssertEqual(incomplete.evidence[5].score.value, 0)
        let incompleteMarked = TypeResolver().resolve(
            fileName: "config", leadingBytes: Data(Array("---\na: b\n".utf8) + [0xE2, 0x82])
        )
        XCTAssertEqual(incompleteMarked.typeID, "yaml")
        XCTAssertEqual(incompleteMarked.evidence[4].score.value, 0.75)
        XCTAssertEqual(incompleteMarked.evidence[5].score.value, 0.80)
        let malformedComplete = TypeResolver().resolve(
            fileName: "config", leadingBytes: Data(valid + [0xE2, 0x82]), sampleIsComplete: true
        )
        XCTAssertEqual(malformedComplete.typeID, "unknown")
        XCTAssertEqual(malformedComplete.evidence.map { $0.score.value }, Array(repeating: 0, count: 7))

        var exactlyAtLimit = Array("a: b\n".utf8)
        let secondMapping = Array("b:".utf8)
        var remaining = 65_536 - exactlyAtLimit.count - secondMapping.count
        while remaining > 4_096 {
            exactlyAtLimit.append(contentsOf: repeatElement(0x20, count: 4_095))
            exactlyAtLimit.append(0x0A)
            remaining -= 4_096
        }
        exactlyAtLimit.append(contentsOf: secondMapping)
        exactlyAtLimit.append(contentsOf: repeatElement(0x20, count: remaining))
        XCTAssertEqual(exactlyAtLimit.count, 65_536)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(exactlyAtLimit), sampleIsComplete: true).typeID, "yaml")
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(exactlyAtLimit)).typeID, "unknown")
        exactlyAtLimit.append(0x20)
        XCTAssertEqual(TypeResolver().resolve(fileName: "config", leadingBytes: Data(exactlyAtLimit), sampleIsComplete: true).typeID, "unknown")

        var acceptedAtCeiling = Array("a: b\nc: d\n".utf8)
        for _ in 0..<15 {
            acceptedAtCeiling.append(0x23)
            acceptedAtCeiling.append(contentsOf: repeatElement(0x20, count: 4_095))
            acceptedAtCeiling.append(0x0A)
        }
        acceptedAtCeiling.append(0x23)
        acceptedAtCeiling.append(contentsOf: repeatElement(0x20, count: 4_069))
        acceptedAtCeiling.append(0x0A)
        XCTAssertEqual(acceptedAtCeiling.count, 65_536)
        acceptedAtCeiling.append(0xFF)
        XCTAssertEqual(
            TypeResolver().resolve(fileName: "config", leadingBytes: Data(acceptedAtCeiling), sampleIsComplete: true).typeID,
            "yaml"
        )
    }

    func testFR005bMetadataComparisonAndShortReadContract() throws {
        let original = InputFileMetadata(
            device: 1, inode: 2, size: 3, modificationSeconds: 4,
            modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 7
        )
        XCTAssertTrue(original.hasSameSnapshot(as: original))
        let changedSnapshots = [
            InputFileMetadata(device: 2, inode: 2, size: 3, modificationSeconds: 4, modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 7),
            InputFileMetadata(device: 1, inode: 3, size: 3, modificationSeconds: 4, modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 7),
            InputFileMetadata(device: 1, inode: 2, size: 4, modificationSeconds: 4, modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 7),
            InputFileMetadata(device: 1, inode: 2, size: 3, modificationSeconds: 5, modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 7),
            InputFileMetadata(device: 1, inode: 2, size: 3, modificationSeconds: 4, modificationNanoseconds: 6, changeSeconds: 6, changeNanoseconds: 7),
            InputFileMetadata(device: 1, inode: 2, size: 3, modificationSeconds: 4, modificationNanoseconds: 5, changeSeconds: 7, changeNanoseconds: 7),
            InputFileMetadata(device: 1, inode: 2, size: 3, modificationSeconds: 4, modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 8)
        ]
        for changed in changedSnapshots {
            XCTAssertFalse(original.hasSameSnapshot(as: changed))
        }

        let source = Data([1, 2, 3, 4, 5])
        var offset = 0
        var requests: [Int] = []
        let read = try XCTUnwrap(Self.boundedRead(count: source.count) { request in
            requests.append(request)
            let count = min(request, [2, 1, 8].dropFirst(requests.count - 1).first ?? request)
            let chunk = source.subdata(in: offset..<(offset + count))
            offset += count
            return chunk
        })
        XCTAssertEqual(read, source)
        XCTAssertEqual(requests, [5, 3, 2])
        XCTAssertNil(try Self.boundedRead(count: 2) { _ in nil })
        XCTAssertNil(try Self.boundedRead(count: 2) { request in Data(repeating: 0, count: request + 1) })
    }

    func testFR005bRealInputs() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_FR005B_REQUIRE_REAL_INPUT"] == "1"
        guard let directoryPath = environment["INSPECTORCORE_FR005B_REAL_INPUT_DIR"] else {
            if required {
                XCTFail("Required FR-005b real-input directory is not set")
                return
            }
            throw XCTSkip("INSPECTORCORE_FR005B_REAL_INPUT_DIR is not set")
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let yamlURL = directory.appendingPathComponent("fr005b-tapioca.yml")
        let scriptURL = directory.appendingPathComponent("glib-mkenums")
        guard FileManager.default.fileExists(atPath: yamlURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path)
        else {
            XCTFail("Required FR-005b real-input files are missing")
            return
        }

        let yaml = try Self.readStableSample(from: yamlURL)
        guard yaml.complete else {
            XCTFail("The YAML sample must be fully read for its fingerprint check")
            return
        }
        let yamlFingerprint = SHA256.hash(data: yaml.bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(yamlFingerprint, "0cca808009e7f0b76c4667cd211f0b196aa97b25e489cbb8a09aa472f5b68adb")

        let yamlResult = TypeResolver().resolve(fileName: "config", leadingBytes: yaml.bytes, sampleIsComplete: yaml.complete)
        XCTAssertEqual(yamlResult.typeID, "yaml")
        XCTAssertEqual(yamlResult.confidence.value, 0.80)
        XCTAssertEqual(yamlResult.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(yamlResult.evidence.map { $0.score.value }, [0, 0, 0, 0, 0.75, 0.80, 0])
        XCTAssertEqual(yamlResult.evidence.map(\.value), ["no-match", "no-match", "no-match", "no-match", "yaml-mapping", "yaml-document-marker", "no-match"])
        XCTAssertEqual(yamlResult.evidence.count, 7, "No UTI was supplied, so no conflict is expected")

        let yamlUnderTypeScriptName = TypeResolver().resolve(
            fileName: "foo.ts", leadingBytes: yaml.bytes, sampleIsComplete: yaml.complete
        )
        XCTAssertEqual(yamlUnderTypeScriptName.typeID, "typescript")
        XCTAssertEqual(yamlUnderTypeScriptName.confidence.value, 0.95)
        XCTAssertEqual(yamlUnderTypeScriptName.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(yamlUnderTypeScriptName.evidence.map { $0.score.value }, [0, 0, 0.95, 0, 0.75, 0.80, 0])
        XCTAssertEqual(yamlUnderTypeScriptName.evidence.count, 7, "No UTI was supplied, so no conflict is expected")

        let script = try Self.readStableSample(from: scriptURL)
        guard script.complete else {
            XCTFail("The Python sample must be fully read for its fingerprint check")
            return
        }
        let scriptFingerprint = SHA256.hash(data: script.bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(scriptFingerprint, "55f570b961936febd92cc7f4c62fad18d18a99c73e420713c0cb71354483b70f")
        let scriptResult = TypeResolver().resolve(
            fileName: scriptURL.lastPathComponent,
            leadingBytes: script.bytes,
            sampleIsComplete: script.complete
        )
        XCTAssertEqual(scriptResult.typeID, "python")
        XCTAssertEqual(scriptResult.confidence.value, 0.90)
        XCTAssertEqual(scriptResult.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(scriptResult.evidence.map(\.value), ["no-match", "no-match", "no-match", "python3", "no-match", "no-match", "no-match"])
        XCTAssertEqual(scriptResult.evidence.map { $0.score.value }, [0, 0, 0, 0.90, 0, 0, 0])
        XCTAssertEqual(scriptResult.evidence.first(where: { $0.score.value > 0 })?.value, "python3")

        guard let firstTerminator = script.bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
            XCTFail("Real script first line has no line terminator")
            return
        }
        let firstLine = Data(script.bytes[..<firstTerminator])
        XCTAssertTrue(firstLine == Data("#!/usr/bin/env python3".utf8))
        let confirmedEOF = TypeResolver().resolve(fileName: "script", leadingBytes: firstLine, sampleIsComplete: true)
        let unconfirmed = TypeResolver().resolve(fileName: "script", leadingBytes: firstLine)
        var terminatedLineEnd = firstTerminator + 1
        if script.bytes[firstTerminator] == 0x0D,
           terminatedLineEnd < script.bytes.count,
           script.bytes[terminatedLineEnd] == 0x0A {
            terminatedLineEnd += 1
        }
        let terminatedFirstLine = Data(script.bytes[..<terminatedLineEnd])
        let unconfirmedTerminatedLine = TypeResolver().resolve(
            fileName: "script", leadingBytes: terminatedFirstLine, sampleIsComplete: false
        )
        XCTAssertEqual(confirmedEOF.typeID, "python")
        XCTAssertEqual(confirmedEOF.confidence.value, 0.90)
        XCTAssertEqual(confirmedEOF.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(confirmedEOF.evidence.map { $0.score.value }, [0, 0, 0, 0.90, 0, 0, 0])
        XCTAssertEqual(unconfirmed.typeID, "unknown")
        XCTAssertEqual(unconfirmed.evidence.map(\.value), Array(repeating: "no-match", count: 7))
        XCTAssertEqual(unconfirmed.evidence.map { $0.score.value }, Array(repeating: 0, count: 7))
        XCTAssertEqual(unconfirmedTerminatedLine.typeID, "python")
        XCTAssertEqual(unconfirmedTerminatedLine.confidence.value, 0.90)
        XCTAssertEqual(unconfirmedTerminatedLine.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(unconfirmedTerminatedLine.evidence.map { $0.score.value }, [0, 0, 0, 0.90, 0, 0, 0])

        print("FR005C_REAL_INPUT yaml type=\(yamlResult.typeID) confidence=\(yamlResult.confidence.value) scores=\(yamlResult.evidence.map { $0.score.value })")
        print("FR005C_REAL_INPUT yaml-ts type=\(yamlUnderTypeScriptName.typeID) confidence=\(yamlUnderTypeScriptName.confidence.value) scores=\(yamlUnderTypeScriptName.evidence.map { $0.score.value })")
        print("FR005C_REAL_INPUT python type=\(scriptResult.typeID) confidence=\(scriptResult.confidence.value) scores=\(scriptResult.evidence.map { $0.score.value })")
        print("FR005C_REAL_INPUT python-eof type=\(confirmedEOF.typeID) confidence=\(confirmedEOF.confidence.value) scores=\(confirmedEOF.evidence.map { $0.score.value })")
        print("FR005C_REAL_INPUT python-unconfirmed type=\(unconfirmed.typeID) confidence=\(unconfirmed.confidence.value) scores=\(unconfirmed.evidence.map { $0.score.value })")
        print("FR005C_REAL_INPUT python-terminated type=\(unconfirmedTerminatedLine.typeID) confidence=\(unconfirmedTerminatedLine.confidence.value) scores=\(unconfirmedTerminatedLine.evidence.map { $0.score.value })")
    }

    func testFR005MagicBOMRealInputs() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_FR005_MAGIC_BOM_REQUIRE_REAL_INPUT"] == "1"
        guard let directoryPath = environment["INSPECTORCORE_FR005_MAGIC_BOM_REAL_INPUT_DIR"] else {
            if required {
                XCTFail("Required FR-005 magic/BOM real-input directory is not set")
                return
            }
            throw XCTSkip("INSPECTORCORE_FR005_MAGIC_BOM_REAL_INPUT_DIR is not set")
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let plistURL = directory.appendingPathComponent("fr005-magic.plist")
        let bomURL = directory.appendingPathComponent("fr005-bom.go")
        guard FileManager.default.fileExists(atPath: plistURL.path),
              FileManager.default.fileExists(atPath: bomURL.path)
        else {
            XCTFail("Required FR-005 magic/BOM real-input files are missing")
            return
        }

        let plistSample = try Self.readStableSample(from: plistURL)
        guard plistSample.complete else {
            XCTFail("The binary-plist sample must be fully read for its fingerprint check")
            return
        }
        let plistFingerprint = SHA256.hash(data: plistSample.bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(plistFingerprint, "3c1bc045cd817974ee631bd4a9da86d4113b8d0d90016248f9b2005f033f30ea")

        let plist = TypeResolver().resolve(
            fileName: "sample",
            leadingBytes: plistSample.bytes,
            sampleIsComplete: plistSample.complete
        )
        XCTAssertEqual(plist.typeID, "plist")
        XCTAssertEqual(plist.confidence.value, 0.85)
        assertByteEvidence(
            plist,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "plist",
            magicScore: 0.85,
            magicWins: true,
            bomStatus: .noMatch
        )
        assertEvidenceVector(
            plist,
            values: Array(repeating: "no-match", count: 7),
            scores: Array(repeating: 0, count: 7)
        )

        let renamedPlist = TypeResolver().resolve(
            fileName: "foo.ts",
            leadingBytes: plistSample.bytes,
            sampleIsComplete: plistSample.complete
        )
        XCTAssertEqual(renamedPlist.typeID, "typescript")
        XCTAssertEqual(renamedPlist.confidence.value, 0.95)
        assertByteEvidence(
            renamedPlist,
            magicStatus: .matched,
            magicValue: "bplist00",
            magicTypeID: "plist",
            magicScore: 0.85,
            bomStatus: .noMatch
        )
        assertEvidenceVector(
            renamedPlist,
            values: ["no-match", "no-match", ".ts", "no-match", "no-match", "no-match", "no-match"],
            scores: [0, 0, 0.95, 0, 0, 0, 0]
        )

        let bomSample = try Self.readStableSample(from: bomURL)
        guard bomSample.complete else {
            XCTFail("The BOM sample must be fully read for its fingerprint check")
            return
        }
        let bomFingerprint = SHA256.hash(data: bomSample.bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(bomFingerprint, "617545be6e48e924b0e078c73662aba44103adf3fcb0f78376a42f1650f7d56b")

        let bomOnlyTypeEvidence = TypeResolver().resolve(
            fileName: "sample",
            leadingBytes: bomSample.bytes,
            sampleIsComplete: bomSample.complete
        )
        XCTAssertEqual(bomOnlyTypeEvidence.typeID, "unknown")
        XCTAssertEqual(bomOnlyTypeEvidence.confidence.value, 0)
        assertByteEvidence(
            bomOnlyTypeEvidence,
            magicStatus: .noMatch,
            bomStatus: .matched,
            bomValue: TextEncoding.utf8BOM.rawValue,
            bomEncoding: .utf8BOM
        )
        assertEvidenceVector(
            bomOnlyTypeEvidence,
            values: Array(repeating: "no-match", count: 7),
            scores: Array(repeating: 0, count: 7)
        )
    }

    func testDefaultRegistryDefinitionsPassPublicValidation() throws {
        let registry = try XCTUnwrap(FileTypeRegistry(definitions: FileTypeRegistry.default.definitions))
        XCTAssertEqual(registry.definitions, FileTypeRegistry.default.definitions)
    }

    func testDefaultRegistryMappingsAndEvidence() {
        let cases: [(String, String, DetectionEvidence.SignalKind, String, Double)] = [
            ("file.ts", "typescript", .singleExtension, ".ts", 0.95),
            ("file.d.ts", "typescript-declaration", .multiExtension, ".d.ts", 0.98),
            (".env", "dotenv", .filename, ".env", 1.0),
            (".env.local", "dotenv", .filename, ".env.local", 1.0),
            ("Makefile", "make", .filename, "makefile", 1.0),
            ("Dockerfile", "dockerfile", .filename, "dockerfile", 1.0),
            ("file.local", "generic-local", .singleExtension, ".local", 0.95),
            ("file.py", "python", .singleExtension, ".py", 0.95)
        ]

        for (name, expectedType, kind, value, score) in cases {
            let result = TypeResolver().resolve(fileName: name)
            XCTAssertEqual(result.typeID, expectedType, name)
            XCTAssertEqual(result.confidence.value, score, name)
            XCTAssertEqual(result.evidence.count, 7, name)
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.signalKind, kind, name)
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, value, name)
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.score.value, score, name)
        }
        XCTAssertEqual(TypeResolver().resolve(fileName: "id_ed25519.pub").typeID, "unknown",
                       "The shared .pub suffix alone cannot distinguish SSH from PEM public keys.")
    }

    func testDefaultRegistryIsOnlyThePlannedCoverage() {
        let resolver = TypeResolver()
        XCTAssertEqual(resolver.resolve(fileName: "file.yaml").typeID, "yaml")
        XCTAssertEqual(resolver.resolve(fileName: "file.YML").typeID, "yaml")
        XCTAssertEqual(resolver.resolve(fileName: "file.tsx").typeID, "tsx")
        for name in ["python3.12", "python3-config", "file.PYTHON"] {
            XCTAssertEqual(resolver.resolve(fileName: name).typeID, "unknown", name)
        }
    }

    func testASCIIOnlyCaseFoldingAndCanonicalEquivalentMatching() throws {
        let registry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "composed", filenames: ["café"]),
            FileTypeDefinition(typeID: "ascii", singleExtensions: [".ts"])
        ]))
        let resolver = TypeResolver(registry: registry)

        XCTAssertEqual(resolver.resolve(fileName: "FILE.TS").typeID, "ascii")
        XCTAssertEqual(resolver.resolve(fileName: "CAFÉ").typeID, "unknown")
        XCTAssertEqual(resolver.resolve(fileName: "café").typeID, "composed")
        XCTAssertEqual(resolver.resolve(fileName: "cafe\u{301}").typeID, "composed")
        XCTAssertEqual(resolver.resolve(fileName: "café").evidence.first(where: { $0.score.value > 0 })?.value, "café")
    }

    func testBasenameAndExtensionBoundaries() {
        let resolver = TypeResolver()
        XCTAssertEqual(resolver.resolve(fileName: "dir/foo.ts").typeID, "typescript")
        XCTAssertEqual(resolver.resolve(fileName: "").typeID, "unknown")
        XCTAssertEqual(resolver.resolve(fileName: "dir/").typeID, "unknown")
        XCTAssertEqual(resolver.resolve(fileName: ".ts").typeID, "unknown")
        XCTAssertEqual(resolver.resolve(fileName: ".py").typeID, "unknown")
        XCTAssertEqual(resolver.resolve(fileName: ".local").typeID, "unknown")
        XCTAssertEqual(resolver.resolve(fileName: ".d.ts").typeID, "typescript")
        XCTAssertEqual(resolver.resolve(fileName: ".env.").typeID, "unknown")
    }

    func testUnknownResultHasZeroConfidenceAndNoEvidence() {
        let result = TypeResolver().resolve(fileName: "unrecognized")
        XCTAssertEqual(result.typeID, "unknown")
        XCTAssertEqual(result.confidence.value, 0)
        XCTAssertEqual(result.evidence.count, 7)
        XCTAssertEqual(result.evidence.map { $0.score.value }, Array(repeating: 0, count: 7))
        XCTAssertEqual(result.evidence.map(\.value), Array(repeating: "no-match", count: 7))
    }

    func testRuleClassPrecedenceAndLongerLiterals() throws {
        let definitions = [
            FileTypeDefinition(typeID: "short", singleExtensions: [".local"]),
            FileTypeDefinition(typeID: "long", multiExtensions: [".d.ts"]),
            FileTypeDefinition(typeID: "prefix", filenamePrefixes: ["foo"]),
            FileTypeDefinition(typeID: "exact", filenames: ["foo.d.ts"])
        ]

        for ordered in [definitions, Array(definitions.reversed())] {
            let resolver = TypeResolver(registry: try XCTUnwrap(FileTypeRegistry(definitions: ordered)))
            XCTAssertEqual(resolver.resolve(fileName: "foo.d.ts").typeID, "exact")
            XCTAssertEqual(resolver.resolve(fileName: "x.d.ts").typeID, "long")
            XCTAssertEqual(resolver.resolve(fileName: "foo.local").typeID, "prefix")
        }
    }

    func testLongestRuleWinsWithinClassIndependentOfDefinitionOrder() throws {
        let definitions = [
            FileTypeDefinition(typeID: "short", singleExtensions: [".local"]),
            FileTypeDefinition(typeID: "long", singleExtensions: [".production.local"])
        ]
        for ordered in [definitions, Array(definitions.reversed())] {
            let registry = try XCTUnwrap(FileTypeRegistry(definitions: Array(ordered)))
            let result = TypeResolver(registry: registry).resolve(fileName: "x.production.local")
            XCTAssertEqual(result.typeID, "long")
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, ".production.local")
        }
    }

    func testEqualLengthTypeIDAndLiteralTiesAreDeterministic() throws {
        let definitions = [
            FileTypeDefinition(typeID: "zeta", singleExtensions: [".same"]),
            FileTypeDefinition(typeID: "alpha", singleExtensions: [".same"])
        ]
        for ordered in [definitions, Array(definitions.reversed())] {
            let registry = try XCTUnwrap(FileTypeRegistry(definitions: Array(ordered)))
            XCTAssertEqual(TypeResolver(registry: registry).resolve(fileName: "x.same").typeID, "alpha")
        }

        let literalRegistry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "type", singleExtensions: [".é", ".e\u{301}"])
        ]))
        let literalResult = TypeResolver(registry: literalRegistry).resolve(fileName: "x.e\u{301}")
        XCTAssertEqual(literalResult.typeID, "type")
        XCTAssertEqual(literalResult.evidence.first(where: { $0.score.value > 0 })?.value, ".e\u{301}")
    }

    func testCanonicalEquivalentExactAndPrefixTieUsesTypeID() throws {
        let definitions = [
            FileTypeDefinition(typeID: "zeta-exact", filenames: ["éx"]),
            FileTypeDefinition(typeID: "alpha-prefix", filenamePrefixes: ["e\u{301}"])
        ]

        for ordered in [definitions, Array(definitions.reversed())] {
            let registry = try XCTUnwrap(FileTypeRegistry(definitions: ordered))
            let result = TypeResolver(registry: registry).resolve(fileName: "éx")
            XCTAssertEqual(result.typeID, "alpha-prefix")
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.signalKind, .filename)
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "éx")
        }
    }

    func testFilenamePrefixAndExtensionBoundaries() {
        let resolver = TypeResolver()
        XCTAssertEqual(resolver.resolve(fileName: ".env.local").typeID, "dotenv")
        XCTAssertEqual(resolver.resolve(fileName: ".env.production.local").typeID, "dotenv")
        XCTAssertEqual(resolver.resolve(fileName: "foo.env.local").typeID, "generic-local")
        XCTAssertEqual(resolver.resolve(fileName: "foo.d.ts").typeID, "typescript-declaration")
        XCTAssertEqual(resolver.resolve(fileName: "foo.d.ts.local").typeID, "generic-local")
        XCTAssertEqual(resolver.resolve(fileName: ".env.d.ts").typeID, "typescript-declaration")
    }

    func testAC0054FilenameAndMultiExtensionPrecedence() {
        let resolver = TypeResolver()
        let declaration = resolver.resolve(fileName: "foo.d.ts")
        XCTAssertEqual(declaration.typeID, "typescript-declaration")
        XCTAssertEqual(declaration.evidence.first(where: { $0.score.value > 0 })?.signalKind, .multiExtension)
        let local = resolver.resolve(fileName: ".env.local")
        XCTAssertEqual(local.typeID, "dotenv")
        XCTAssertEqual(local.evidence.first(where: { $0.score.value > 0 })?.signalKind, .filename)
        XCTAssertEqual(local.evidence.first(where: { $0.score.value > 0 })?.value, ".env.local")
    }

    func testEvidenceReportsWinningAndLosingDetectorsWithFixedScores() {
        let resolver = TypeResolver()
        let result = resolver.resolve(fileName: "file.ts", leadingBytes: Data("#!/usr/bin/env python3\n".utf8))
        XCTAssertEqual(result.typeID, "typescript")
        XCTAssertEqual(result.confidence.value, 0.95)
        XCTAssertEqual(result.evidence.count, 7)
        XCTAssertEqual(result.evidence.map(\.signalKind), Self.vectorKinds)
        XCTAssertEqual(result.evidence.map(\.value), ["no-match", "no-match", ".ts", "python3", "no-match", "no-match", "no-match"])
        XCTAssertEqual(result.evidence.map { $0.score.value }, [0, 0, 0.95, 0.90, 0, 0, 0])
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.signalKind, .singleExtension)
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, ".ts")
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.score.value, result.confidence.value)
    }

    func testAC0053EnvPythonShebang() {
        let result = TypeResolver().resolve(
            fileName: "script",
            leadingBytes: Data("#!/usr/bin/env python3\nprint('hello')\n".utf8)
        )
        XCTAssertEqual(result.typeID, "python")
        XCTAssertEqual(result.confidence.value, 0.90)
        XCTAssertEqual(result.evidence.count, 7)
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.signalKind, .shebang)
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "python3")
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.score.value, 0.90)
    }

    func testAC0053EnvPythonShebangConfirmedEOF() {
        let resolver = TypeResolver()
        for input in ["#!/usr/bin/python3 -u", "#!/usr/bin/env python3 -u", "#!/usr/bin/env -S python3 -u"] {
            let bytes = Data(input.utf8)
            let unconfirmed = resolver.resolve(fileName: "script", leadingBytes: bytes)
            XCTAssertEqual(unconfirmed.typeID, "unknown", input)
            XCTAssertEqual(unconfirmed.evidence.map(\.value), Array(repeating: "no-match", count: 7), input)
            XCTAssertEqual(unconfirmed.evidence.map { $0.score.value }, Array(repeating: 0, count: 7), input)
            let result = resolver.resolve(fileName: "script", leadingBytes: bytes, sampleIsComplete: true)
            XCTAssertEqual(result.typeID, "python", input)
            XCTAssertEqual(result.confidence.value, 0.90, input)
            XCTAssertEqual(result.evidence.map(\.signalKind), Self.vectorKinds, input)
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "python3", input)
        }

        for input in ["#!/usr/bin/env", "#!/usr/bin/env -S", "#!/usr/bin/", "#!/usr/bin/env -S PYTHONPATH=x"] {
            XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(input.utf8), sampleIsComplete: true).typeID, "unknown", input)
        }
        XCTAssertEqual(
            resolver.resolve(fileName: "script", leadingBytes: Data([0x23, 0x21, 0xFF]), sampleIsComplete: true).typeID,
            "unknown"
        )
    }

    func testShebangConfirmedEOFRespectsExactByteCeiling() {
        let resolver = TypeResolver()
        let firstLine = Array("#!/usr/bin/env python3".utf8)
        var exact = firstLine
        exact.append(contentsOf: repeatElement(0x20, count: 65_536 - exact.count))
        XCTAssertEqual(exact.count, 65_536)
        XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(exact), sampleIsComplete: true).typeID, "python")
        XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(exact)).typeID, "unknown")

        var oversized = exact
        oversized.append(0x20)
        XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(oversized), sampleIsComplete: true).typeID, "unknown")

        var outsideTerminator = exact
        outsideTerminator.append(0x0A)
        XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(outsideTerminator), sampleIsComplete: true).typeID, "unknown")
    }

    func testShebangRecognizesDirectAndEnvFormsAndArguments() {
        let resolver = TypeResolver()
        for input in [
            "#!/usr/bin/python3 -u\n",
            "#!/usr/bin/env python3 -u\n",
            "#!/usr/bin/env -S python3 -u\n"
        ] {
            let result = resolver.resolve(fileName: "script", leadingBytes: Data(input.utf8))
            XCTAssertEqual(result.typeID, "python", input)
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "python3", input)
        }
    }

    func testShebangAllowsOnlyConfiguredLeadingSpacesAndTabsAfterMarker() {
        let resolver = TypeResolver()
        for marker in ["#! /usr/bin/env python3\n", "#!\t/usr/bin/env python3\n", "#!  \t/usr/bin/env python3\n"] {
            XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(marker.utf8)).typeID, "python")
        }
    }

    func testEmptyBasenameCanStillResolveFromShebang() {
        let result = TypeResolver().resolve(
            fileName: "directory/",
            leadingBytes: Data("#!/usr/bin/env python3\n".utf8)
        )
        XCTAssertEqual(result.typeID, "python")
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.signalKind, .shebang)
    }

    func testShebangDirectEvidenceContainsOnlyInterpreterBasename() {
        let result = TypeResolver().resolve(
            fileName: "script",
            leadingBytes: Data("#!/usr/local/bin/python3 -u\n".utf8)
        )
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "python3")
    }

    func testShebangGrammarRejectsMalformedEnvAndRelativePaths() {
        let resolver = TypeResolver()
        let rejected = [
            "#!/usr/bin/env -i python3\n",
            "#!/usr/bin/env PYTHONPATH=x python3\n",
            "#!/usr/bin/env -S\n",
            "#!/usr/bin/env -S PYTHONPATH=x python3\n",
            "#!/usr/bin/env 'python3'\n",
            "#!/usr/bin/env \"python3\"\n",
            "#!/usr/bin/env python3.12\n",
            "#!/usr/bin/env Python3\n",
            "#!python3\n",
            "#!/usr/bin/env-other python3\n"
        ]

        for input in rejected {
            XCTAssertEqual(
                resolver.resolve(fileName: "script", leadingBytes: Data(input.utf8)).typeID,
                "unknown",
                input
            )
        }
    }

    func testShebangSupportsCustomInterpretersAndUsesDeterministicTies() throws {
        let first = FileTypeDefinition(typeID: "zeta", shebangInterpreters: ["tool"])
        let second = FileTypeDefinition(typeID: "alpha", shebangInterpreters: ["tool"])
        for definitions in [[first, second], [second, first]] {
            let registry = try XCTUnwrap(FileTypeRegistry(definitions: definitions))
            let result = TypeResolver(registry: registry).resolve(
                fileName: "script",
                leadingBytes: Data("#!/usr/bin/env tool\n".utf8)
            )
            XCTAssertEqual(result.typeID, "alpha")
            XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "tool")
        }
    }

    func testCustomInterpreterWorksForDirectAndEnvFormsCaseSensitively() throws {
        let registry = try XCTUnwrap(FileTypeRegistry(definitions: [
            FileTypeDefinition(typeID: "custom", shebangInterpreters: ["Tool"])
        ]))
        let resolver = TypeResolver(registry: registry)
        for input in ["#!/opt/bin/Tool\n", "#!/usr/bin/env Tool\n"] {
            XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(input.utf8)).typeID, "custom")
        }
        XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data("#!/usr/bin/env tool\n".utf8)).typeID, "unknown")
    }

    func testShebangRequiresAFirstLineTerminatorAndStrictUTF8() {
        let resolver = TypeResolver()
        for unterminated in ["#!/usr/bin/env python3", "#!/usr/bin/env python3 "] {
            XCTAssertEqual(resolver.resolve(fileName: "script", leadingBytes: Data(unterminated.utf8)).typeID, "unknown")
        }
        XCTAssertEqual(
            resolver.resolve(fileName: "script", leadingBytes: Data([0x23, 0x21, 0xFF, 0x0A])).typeID,
            "unknown"
        )
    }

    func testShebangLineTerminatorsAndFirstLineIsolation() {
        let resolver = TypeResolver()
        for terminator in ["\n", "\r", "\r\n"] {
            let valid = Data(Array("#!/usr/bin/env python3\(terminator)".utf8) + [0xFF])
            let result = resolver.resolve(fileName: "script", leadingBytes: valid)
            XCTAssertEqual(result.typeID, "python")
            XCTAssertEqual(result.evidence[3].value, "python3")
            XCTAssertEqual(result.evidence[3].score.value, 0.90)
        }
        XCTAssertEqual(
            resolver.resolve(fileName: "script", leadingBytes: Data(" #!/usr/bin/env python3\n".utf8)).typeID,
            "unknown"
        )
        XCTAssertEqual(
            resolver.resolve(fileName: "script", leadingBytes: Data([0xEF, 0xBB, 0xBF] + Array("#!/usr/bin/env python3\n".utf8))).typeID,
            "unknown"
        )
        XCTAssertEqual(
            resolver.resolve(fileName: "script", leadingBytes: Data("print(1)\n#!/usr/bin/env python3\n".utf8)).typeID,
            "unknown"
        )
    }

    func testShebangTerminatorBoundaryIsBoundedAt65536Bytes() {
        let resolver = TypeResolver()
        let firstLine = Array("#!/usr/bin/env python3".utf8)
        for (offset, expected) in [(65_535, "python"), (65_536, "unknown")] {
            var bytes = firstLine
            bytes.append(contentsOf: repeatElement(0x20, count: offset - bytes.count))
            bytes.append(0x0A)
            XCTAssertEqual(
                resolver.resolve(fileName: "script", leadingBytes: Data(bytes)).typeID,
                expected,
                "Terminator offset \(offset)"
            )
        }
    }

    func testStrongerFilenameAndExtensionRulesBeatShebang() {
        let resolver = TypeResolver()
        XCTAssertEqual(
            resolver.resolve(fileName: "Dockerfile", leadingBytes: Data("#!/usr/bin/env python3\n".utf8)).typeID,
            "dockerfile"
        )
        XCTAssertEqual(
            resolver.resolve(fileName: "file.py", leadingBytes: Data("#!/usr/bin/env python3\n".utf8)).typeID,
            "python"
        )
    }

    func testRealInputPythonShebang() throws {
        guard let path = ProcessInfo.processInfo.environment["INSPECTORCORE_REAL_INPUT"] else {
            throw XCTSkip("INSPECTORCORE_REAL_INPUT is not set")
        }

        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try XCTUnwrap(handle.read(upToCount: 65_536))
        let result = TypeResolver().resolve(fileName: url.lastPathComponent, leadingBytes: bytes)

        XCTAssertEqual(result.typeID, "python")
        XCTAssertEqual(result.confidence.value, 0.90)
        XCTAssertEqual(result.evidence.count, 7)
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.signalKind, .shebang)
        XCTAssertEqual(result.evidence.first(where: { $0.score.value > 0 })?.value, "python3")
        print("FR005_REAL_INPUT type=python confidence=0.90 evidence=shebang")
    }

    private struct InputFileMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(
            device: UInt64,
            inode: UInt64,
            size: Int64,
            modificationSeconds: Int64,
            modificationNanoseconds: Int64,
            changeSeconds: Int64,
            changeNanoseconds: Int64
        ) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modificationSeconds = modificationSeconds
            self.modificationNanoseconds = modificationNanoseconds
            self.changeSeconds = changeSeconds
            self.changeNanoseconds = changeNanoseconds
        }

        init?(fileDescriptor: Int32) {
            var value = stat()
            guard fstat(fileDescriptor, &value) == 0,
                  (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  value.st_size >= 0
            else { return nil }
            self.init(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino),
                size: Int64(value.st_size),
                modificationSeconds: Int64(value.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changeSeconds: Int64(value.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
            )
        }

        func hasSameSnapshot(as other: InputFileMetadata) -> Bool {
            device == other.device && inode == other.inode && size == other.size
                && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
                && changeSeconds == other.changeSeconds && changeNanoseconds == other.changeNanoseconds
        }
    }

    private struct BoundedSample {
        let bytes: Data
        let complete: Bool
    }

    private static func boundedRead(
        count: Int,
        readChunk: (Int) throws -> Data?
    ) throws -> Data? {
        guard count >= 0 else { return nil }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            guard let chunk = try readChunk(remaining), !chunk.isEmpty, chunk.count <= remaining else { return nil }
            result.append(chunk)
        }
        return result.count == count ? result : nil
    }

    private static func readStableSample(from url: URL) throws -> BoundedSample {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let before = InputFileMetadata(fileDescriptor: handle.fileDescriptor) else {
            throw NSError(domain: "TypeResolverTests", code: 1)
        }

        let byteLimit: Int64 = 65_536
        let requestedCount = Int(min(before.size, byteLimit))
        try handle.seek(toOffset: 0)
        var readError: Error?
        let maybeBytes: Data?
        do {
            maybeBytes = try boundedRead(count: requestedCount) { request in
                try handle.read(upToCount: request)
            }
        } catch {
            maybeBytes = nil
            readError = error
        }

        guard let after = InputFileMetadata(fileDescriptor: handle.fileDescriptor),
              before.hasSameSnapshot(as: after)
        else {
            throw NSError(domain: "TypeResolverTests", code: 2)
        }
        if let readError { throw readError }
        guard let bytes = maybeBytes, bytes.count == requestedCount else {
            throw NSError(domain: "TypeResolverTests", code: 3)
        }
        return BoundedSample(bytes: bytes, complete: before.size <= byteLimit)
    }
}
