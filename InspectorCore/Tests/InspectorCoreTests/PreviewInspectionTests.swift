import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import InspectorCore

final class PreviewInspectionTests: XCTestCase {
    func testRegularFileSelectionPrecedesContinuationAtExactCutoffs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for size in [65_535, 65_536, 65_537] {
            let url = directory.appendingPathComponent("sample-\(size).txt")
            let bytes = Data(repeating: 0x61, count: size)
            try bytes.write(to: url)
            let events = RegularFileEventRecorder()
            let result = try PreviewInspectionResult.readRegularFile(at: url,
                contentTypeIdentifier: { _ in nil }, observe: { events.append($0) })
            let values = events.values
            guard let selectionIndex = values.firstIndex(where: {
                if case .selectionCommitted = $0 { return true }
                return false
            }) else { return XCTFail("Selection event missing for \(size) bytes") }
            let readsBeforeSelection = values[..<selectionIndex].compactMap { event -> (Int, Int)? in
                guard case .read(let offset, let requested, _, _) = event else { return nil }
                return (offset, requested)
            }
            XCTAssertFalse(readsBeforeSelection.isEmpty)
            XCTAssertTrue(values[(selectionIndex + 1)...].contains(where: {
                if case .continuationAppended = $0 { return true }
                return false
            }) == (size == 65_537))
            XCTAssertEqual(result.sampleByteCount, min(size, 65_536))
            XCTAssertEqual(result.sampleIsComplete, size <= 65_536)
            XCTAssertEqual(result.originalBytes, bytes)
            if case .selectionCommitted(let routed, let distinct) = values[selectionIndex] {
                XCTAssertEqual(routed, min(size, 65_536))
                XCTAssertEqual(distinct, min(size, 65_536))
                XCTAssertLessThanOrEqual(distinct, 65_536)
            }
        }
    }

    func testStagedReaderRetriesInterruptsAndAdvancesAfterShortReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let bytes = Data("short reads still retain every byte\n".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = StagedReadProbe()
        let events = RegularFileEventRecorder()
        let result = try PreviewInspectionResult.readRegularFileForTesting(at: url,
            contentTypeIdentifier: { _ in nil }, observe: { events.append($0) }, readOperation: { fd, buffer, count, offset in
                if probe.shouldInterrupt { return .init(byteCount: -1, errorCode: EINTR) }
                let shortCount = min(count, 7)
                let actual = Darwin.pread(fd, buffer, shortCount, offset)
                return .init(byteCount: actual, errorCode: actual < 0 ? errno : nil)
            })
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertEqual(result.sampleByteCount, bytes.count)
        let requests = events.values.compactMap { event -> (Int, Int, Int32?)? in
            guard case .read(let offset, let requested, _, let error) = event else { return nil }
            return (offset, requested, error)
        }
        XCTAssertEqual(requests.first?.2, EINTR)
        XCTAssertEqual(requests.dropFirst().first?.0, 0)
        XCTAssertEqual(requests.dropFirst(2).first?.0, 7, "A short read must continue at the first unfilled offset")
        XCTAssertEqual(result.sampleByteCount, bytes.count)
    }

    func testRegularFileReadHandlesEmptyLimitsUnicodeOverrideAndIOLoss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let emptyURL = directory.appendingPathComponent("empty")
        try Data().write(to: emptyURL)
        let empty = try PreviewInspectionResult.readRegularFile(at: emptyURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(empty.originalBytes, Data())
        XCTAssertEqual(empty.sampleByteCount, 0)
        XCTAssertTrue(empty.sampleIsComplete)

        let largeURL = directory.appendingPathComponent("large.txt")
        try Data(repeating: 0x61, count: 70_000).write(to: largeURL)
        let limited = try PreviewInspectionResult.readRegularFile(at: largeURL, maximumBytes: 101,
            contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(limited.originalBytes.count, 101)
        XCTAssertEqual(limited.sampleByteCount, 101)
        XCTAssertFalse(limited.sampleIsComplete)
        XCTAssertTrue(limited.analysis.truncated)

        var unicode = Data(repeating: 0x61, count: 65_535)
        unicode.append(contentsOf: [0xE2, 0x82, 0xAC])
        let unicodeURL = directory.appendingPathComponent("unicode.txt")
        try unicode.write(to: unicodeURL)
        let decoded = try PreviewInspectionResult.readRegularFile(at: unicodeURL, contentTypeIdentifier: { _ in nil })
        XCTAssertTrue(decoded.analysis.text.hasSuffix("€"))
        let sample = try XCTUnwrap(decoded.analysis.text.utf8.dropLast().last)
        XCTAssertEqual(sample, 0x82, "The full content analysis should include continuation bytes after the clipped routing sample")

        let jsonURL = directory.appendingPathComponent("config.json")
        let json = Data("{\"value\": 1}\n".utf8)
        try json.write(to: jsonURL)
        let overrideEvents = RegularFileEventRecorder()
        let overridden = try PreviewInspectionResult.readRegularFile(at: jsonURL, formatOverride: .yaml,
            overrideDescription: "YAML choice", contentTypeIdentifier: { _ in nil },
            observe: { overrideEvents.append($0) })
        XCTAssertEqual(overridden.automaticFormatName, "JSON")
        XCTAssertEqual(overridden.overrideDescription, "YAML choice")
        XCTAssertEqual(overridden.selectedInspectorID, .yaml)
        let dispatchedInspectors = overrideEvents.values.compactMap { event -> InspectorID? in
            guard case .dispatchStarted(let inspectorID) = event else { return nil }
            return inspectorID
        }
        XCTAssertEqual(dispatchedInspectors, [.yaml], "An explicit override dispatches only its effective inspector")

        let events = RegularFileEventRecorder()
        XCTAssertThrowsError(try PreviewInspectionResult.readRegularFileForTesting(at: largeURL,
            contentTypeIdentifier: { _ in nil }, observe: { events.append($0) },
            readOperation: { _, _, _, _ in .init(byteCount: -1, errorCode: EIO) })) { error in
                XCTAssertEqual(error as? BoundedFileReader.ReadError, .readFailed(EIO))
            }
        XCTAssertTrue(events.values.contains(where: {
            if case .read(_, _, _, let code) = $0 { return code == EIO }
            return false
        }))
    }

    func testRegularFileReadRetainsTheOriginalSizeWhenTheFileShrinksOrGrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = Data(repeating: 0x61, count: 70_000)
        let shrinkingURL = directory.appendingPathComponent("shrinking.txt")
        try original.write(to: shrinkingURL)
        let shrunk = try PreviewInspectionResult.readRegularFile(at: shrinkingURL,
            contentTypeIdentifier: { _ in nil }, observe: { event in
                guard case .selectionCommitted = event else { return }
                let handle = try? FileHandle(forWritingTo: shrinkingURL)
                try? handle?.truncate(atOffset: 65_536)
                try? handle?.close()
            })
        XCTAssertEqual(shrunk.analysis.fileSize, original.count)
        XCTAssertEqual(shrunk.originalBytes.count, 65_536)
        XCTAssertTrue(shrunk.analysis.truncated)

        let growingURL = directory.appendingPathComponent("growing.txt")
        try original.write(to: growingURL)
        let grown = try PreviewInspectionResult.readRegularFile(at: growingURL,
            contentTypeIdentifier: { _ in nil }, observe: { event in
                guard case .selectionCommitted = event else { return }
                let handle = try? FileHandle(forWritingTo: growingURL)
                _ = try? handle?.seekToEnd()
                try? handle?.write(contentsOf: Data(repeating: 0x62, count: 5_000))
                try? handle?.close()
            })
        XCTAssertEqual(grown.analysis.fileSize, original.count)
        XCTAssertEqual(grown.originalBytes.count, original.count)
        XCTAssertEqual(grown.originalBytes, original)
    }

    func testBinaryRouteStaysFrozenWhenCompletedAnalysisBecomesText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        var bytes = Data(repeating: 0x61, count: 100_000)
        // Non-NUL disallowed controls cross the sample's 10% threshold, then drop below it
        // after the printable continuation is retained. NUL remains unconditionally binary.
        bytes.replaceSubrange(0..<7_000, with: Data(repeating: 0x01, count: 7_000))
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PreviewInspectionResult.readRegularFile(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(result.formatName, "Binary data")
        XCTAssertEqual(result.detectionReason, "binary")
        XCTAssertEqual(result.selectedInspectorID, .text)
        XCTAssertFalse(result.analysis.isBinary)
        XCTAssertFalse(result.analysis.text.isEmpty)
    }

    func testLateSourceDialectEvidenceDoesNotChangeTheFrozenRoute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let padding = Data(repeating: 0x20, count: 65_536)
        let fileName = "late.m"
        let lateEvidence = Data("@interface LateEvidence\n@end\n".utf8)
        let plainTail = Data("x = 1;\n".utf8)
        let sampleAnalysis = TextAnalysis.analyze(bytes: padding, fileSize: padding.count + lateEvidence.count,
                                                 maximumBytes: 65_536)
        let resolution = TypeResolver().resolve(fileName: fileName, leadingBytes: padding,
            systemUTI: nil, sampleIsComplete: false)
        let selected = InspectionPipeline.select(fileName: fileName, systemUTI: nil, bytes: padding,
            analysis: sampleAnalysis, resolution: resolution, formatOverride: nil).effective.sourceLanguage
        let routes: [(InspectorID, String, String, SourceLanguage?)] = try [lateEvidence, plainTail].map { tail in
            let url = directory.appendingPathComponent(fileName)
            try (padding + tail).write(to: url)
            let result = try PreviewInspectionResult.readRegularFile(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.selectedInspectorID, InspectionPipeline.select(fileName: fileName,
                systemUTI: nil, bytes: padding, analysis: sampleAnalysis, resolution: resolution,
                formatOverride: nil).effective.inspectorID)
            XCTAssertEqual(result.sourceDocument?.language, selected)
            return (result.selectedInspectorID, result.formatName, result.detectionReason,
                    result.sourceDocument?.language)
        }
        XCTAssertEqual(routes[0].0, routes[1].0)
        XCTAssertEqual(routes[0].1, routes[1].1)
        XCTAssertEqual(routes[0].2, routes[1].2)
        XCTAssertEqual(routes[0].3, routes[1].3)
    }

    func testStagedSharedSuffixFreezesWhileByteBackedPreparationKeepsFullPrefixRouting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m")
        var bytes = Data("#import <Foundation/Foundation.h>\n@implementation Greeter\n@end\n".utf8)
        bytes.append(Data(repeating: 0x20, count: 65_536 - bytes.count))
        bytes.append(0)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: url.lastPathComponent, systemUTI: nil)
        let stagedRoute = SelectedLanguageRecorder()
        let staged = try PreviewInspectionResult.readRegularFile(at: url, contentTypeIdentifier: { _ in nil },
            onSnapshot: { snapshot in stagedRoute.store(snapshot.effectiveRoute.sourceLanguage) })

        XCTAssertTrue(legacy.analysis.isBinary)
        XCTAssertEqual(legacy.selectedInspectorID, .text)
        XCTAssertTrue(staged.analysis.isBinary)
        XCTAssertEqual(staged.selectedInspectorID, .source)
        XCTAssertEqual(stagedRoute.value, .objectiveC)
        XCTAssertNil(staged.sourceDocument)
        XCTAssertNotEqual(legacy.detectionReason, staged.detectionReason)
    }

    func testNFRP02RealInputs() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["NFR_P02_REQUIRE_REAL_INPUT"] == "1"
        guard let directoryPath = environment["NFR_P02_REAL_INPUT_DIR"] else {
            if required {
                XCTFail("Required NFR-P02 real-input directory is missing")
            } else {
                throw XCTSkip("NFR-P02 real inputs are opt-in")
            }
            return
        }
        let inputDirectory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: inputDirectory.path) else {
            XCTFail("Required NFR-P02 real-input directory is missing")
            return
        }
        let inputs: [(String, String)] = [
            ("glib-mkenums", "6b144d7044beeddcde563f4588cd7e3aed74f4dbc9198af1223b2993de9a9ea5"),
            ("fr005-magic.plist", "3c1bc045cd817974ee631bd4a9da86d4113b8d0d90016248f9b2005f033f30ea"),
            ("words", "be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9")
        ]
        let urls = try inputs.map { name, expectedHash -> URL in
            let url = inputDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("Required NFR-P02 input is missing: \(name)")
                return url
            }
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Self.sha256(data), expectedHash, name)
            return url
        }
        func assertRouting(_ recorder: RegularFileEventRecorder, sample: Int, distinct: Int, complete: Bool) {
            let selection = recorder.values.compactMap { event -> (Int, Int)? in
                guard case .selectionCommitted(let count, let offsets) = event else { return nil }
                return (count, offsets)
            }
            XCTAssertEqual(selection.count, 1)
            XCTAssertEqual(selection.first?.0, sample)
            XCTAssertEqual(selection.first?.1, distinct)
            XCTAssertLessThanOrEqual(distinct, 65_536)
            XCTAssertEqual(complete, sample < 65_536)
        }
        let pythonEvents = RegularFileEventRecorder()
        let python = try PreviewInspectionResult.readRegularFile(at: urls[0], contentTypeIdentifier: { _ in nil },
            observe: { pythonEvents.append($0) })
        assertRouting(pythonEvents, sample: 32_278, distinct: 32_278, complete: true)
        XCTAssertEqual(python.selectedInspectorID, .source)
        XCTAssertEqual(python.sourceDocument?.language, .python)
        XCTAssertEqual(python.sampleByteCount, 32_278)
        XCTAssertTrue(python.sampleIsComplete)
        XCTAssertEqual(python.originalBytes, try Data(contentsOf: urls[0]))

        let plistURL = FileManager.default.temporaryDirectory.appendingPathComponent("fr005-magic")
        try Data(contentsOf: urls[1]).write(to: plistURL)
        defer { try? FileManager.default.removeItem(at: plistURL) }
        let plistEvents = RegularFileEventRecorder()
        let plist = try PreviewInspectionResult.readRegularFile(at: plistURL, contentTypeIdentifier: { _ in nil },
            observe: { plistEvents.append($0) })
        assertRouting(plistEvents, sample: 3_333, distinct: 3_333, complete: true)
        XCTAssertEqual(plist.selectedInspectorID, .plist)
        XCTAssertEqual(plist.sampleByteCount, 3_333)
        XCTAssertTrue(plist.sampleIsComplete)
        XCTAssertNotNil(plist.plistInspection?.content)
        XCTAssertEqual(plist.originalBytes, try Data(contentsOf: urls[1]))

        let words = try Data(contentsOf: urls[2])
        let dictionaryEvents = RegularFileEventRecorder()
        let dictionary = try PreviewInspectionResult.readRegularFile(at: urls[2], contentTypeIdentifier: { _ in nil },
            observe: { dictionaryEvents.append($0) })
        assertRouting(dictionaryEvents, sample: 65_536, distinct: 65_536, complete: false)
        XCTAssertEqual(dictionary.selectedInspectorID, .text)
        XCTAssertEqual(dictionary.sampleByteCount, 65_536)
        XCTAssertFalse(dictionary.sampleIsComplete)
        XCTAssertEqual(dictionary.originalBytes.count, 1_048_576)
        XCTAssertEqual(dictionary.originalBytes, Data(words.prefix(1_048_576)))
        XCTAssertTrue(dictionary.analysis.truncated)
        let routingAnalysis = TextAnalysis.analyze(bytes: Data(words.prefix(65_536)), fileSize: words.count, maximumBytes: 65_536)
        XCTAssertGreaterThan(dictionary.analysis.lineCount, routingAnalysis.lineCount)

        let changed = Data(words.prefix(65_536)) + Data([0]) + Data(words.dropFirst(65_537))
        let derivativeURL = FileManager.default.temporaryDirectory.appendingPathComponent("words")
        try changed.write(to: derivativeURL)
        defer { try? FileManager.default.removeItem(at: derivativeURL) }
        let binaryEvents = RegularFileEventRecorder()
        let binary = try PreviewInspectionResult.readRegularFile(at: derivativeURL, contentTypeIdentifier: { _ in nil },
            observe: { binaryEvents.append($0) })
        assertRouting(binaryEvents, sample: 65_536, distinct: 65_536, complete: false)
        XCTAssertEqual(binary.selectedInspectorID, .text)
        XCTAssertTrue(binary.analysis.isBinary)
        XCTAssertEqual(binary.originalBytes.count, dictionary.originalBytes.count)
        XCTAssertEqual(binary.originalBytes, Data(changed.prefix(1_048_576)))
        XCTAssertTrue(binary.analysis.text.isEmpty)
    }

    func testSharedPipelineReadsSevenRepresentativeFormats() throws {
        for (path, format) in [
            ("Cases/json/valid/simple.json", "JSON"), ("Showcase/yaml/yaml.yaml", "YAML"),
            ("Cases/xml/valid/simple.xml", "XML"), ("Cases/plist/xml/simple.plist", "Property list"),
            ("Cases/source/Example.swift", "Swift"), ("Cases/markdown/basic.md", "Markdown"),
            ("Showcase/text/plain.txt", "Plain text")
        ] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatName, format, path)
            XCTAssertFalse(result.detectionReason.isEmpty, path)
            XCTAssertEqual(result.analysis.fileSize, bytes.count, path)
            XCTAssertEqual(result.sampleByteCount, min(bytes.count, 65_536), path)
            XCTAssertTrue(result.sampleIsComplete, path)
            switch format {
            case "JSON": XCTAssertNotNil(result.jsonInspection?.content)
            case "YAML": XCTAssertNotNil(result.yamlInspection?.documents)
            case "XML": XCTAssertNotNil(result.xmlInspection?.root)
            case "Property list": XCTAssertNotNil(result.plistInspection?.content)
            case "Swift": XCTAssertEqual(result.sourceDocument?.language, .swift)
            case "Markdown": XCTAssertNotNil(result.markdownDocument?.renderedText)
            default: XCTAssertEqual(result.analysis.text, String(data: bytes, encoding: .utf8))
            }
        }
    }

    func testRequestedStructuredAliasesParseValidInputsAndRetainMalformedRawBytes() throws {
        for (path, expectedFormat) in [
            ("Cases/xml/font-tool.ttx", "XML"), ("Cases/xml/places.kml", "KML"),
            ("Cases/xml/valid/track.gpx", "GPX"), ("Cases/json/scene.gltf", "JSON")
        ] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatName, expectedFormat, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            if expectedFormat == "JSON" {
                XCTAssertNotNil(result.jsonInspection?.content, path)
            } else {
                XCTAssertNotNil(result.xmlInspection?.root, path)
            }
        }

        for (path, expectedFormat) in [
            ("Cases/fileformats/fontool-edge.ttx", "XML"),
            ("Cases/fileformats/kml-edge.kml", "KML"),
            ("Cases/fileformats/gpx-edge.gpx", "GPX")
        ] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatName, expectedFormat, path)
            XCTAssertEqual(result.xmlInspection?.rawBytes, bytes, path)
            XCTAssertFalse(result.xmlInspection?.diagnostics.isEmpty ?? true, path)
        }
        let gltfURL = try fixtureURL("Cases/fileformats/gltf-edge.gltf")
        let gltfBytes = try Data(contentsOf: gltfURL)
        let gltf = try PreviewInspectionResult.read(at: gltfURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(gltf.formatName, "JSON")
        XCTAssertEqual(gltf.jsonInspection?.rawBytes, gltfBytes)
        XCTAssertFalse(gltf.jsonInspection?.diagnostics.isEmpty ?? true)
    }

    func testLiterateHaskellExtensionUsesItsCodeTrackMode() throws {
        let url = try fixtureURL("Cases/fileformats/haskell-literate-valid.lhs")
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
        let source = try XCTUnwrap(result.sourceDocument)
        let proseLength = (source.source as NSString).lineRange(for: NSRange(location: 0, length: 0)).length
        XCTAssertEqual(result.formatDefinition?.id.rawValue, "haskell")
        XCTAssertTrue(source.highlighting.runs.allSatisfy { $0.range.location >= proseLength })
        XCTAssertTrue(source.highlighting.runs.contains { $0.kind == .keyword })
    }

    func testPlistMagicAndSemanticRoutingTakePrecedence() throws {
        let binary = try Data(contentsOf: fixtureURL("Showcase/plist/binary.plist"))
        let result = PreviewInspectionResult.prepare(bytes: binary, fileSize: binary.count, fileName: "misleading.xml", systemUTI: "public.xml")
        XCTAssertEqual(result.formatName, "Property list")
        XCTAssertEqual(result.detectionReason, "magicBytes")
        XCTAssertTrue(result.plistInspection?.isBinary ?? false)
        guard case .dictionary = result.plistInspection?.content else { return XCTFail("Expected typed binary dictionary") }
        XCTAssertNil(result.xmlInspection)
        let xml = try Data(contentsOf: fixtureURL("Cases/plist/xml/simple.plist"))
        let content = PreviewInspectionResult.prepare(bytes: xml, fileSize: xml.count, fileName: "misleading.xml", systemUTI: nil)
        XCTAssertEqual(content.detectionReason, "contentProbe")
        XCTAssertNotNil(content.plistInspection?.content)
        XCTAssertNil(content.xmlInspection)
    }

    func testKnownFormatsBeatConflictingStructuredUTIOnlyHints() throws {
        for (path, expected) in [
            ("Cases/json/valid/simple.json", "JSON"), ("Showcase/yaml/yaml.yaml", "YAML"),
            ("Cases/markdown/headings.md", "Markdown"), ("Cases/source/Example.swift", "Swift"),
            ("Showcase/source/typescript.ts", "TypeScript"), ("Cases/xml/valid/simple.xml", "XML"),
            ("Cases/ambiguous/Makefile", "Makefile")
        ] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            for uti in ["public.xml", "com.apple.xml-property-list", "com.apple.binary-property-list"] {
                let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                    fileName: url.lastPathComponent, systemUTI: uti)
                XCTAssertEqual(result.formatName, expected, "\(path) / \(uti)")
            }
        }
        let binary = Data([0, 1, 2])
        XCTAssertEqual(PreviewInspectionResult.prepare(bytes: binary, fileSize: binary.count,
            fileName: "misleading.swift", systemUTI: "com.apple.binary-property-list").formatName, "Binary data")
        let plist = try Data(contentsOf: fixtureURL("Cases/plist/xml/simple.plist"))
        for name in ["misleading.json", "misleading.md", "misleading.swift"] {
            let result = PreviewInspectionResult.prepare(bytes: plist, fileSize: plist.count, fileName: name, systemUTI: "public.xml")
            XCTAssertNotNil(result.plistInspection?.content, name)
            XCTAssertEqual(result.formatName, "Property list", name)
            XCTAssertEqual(result.detectionReason, "contentProbe", name)
        }
    }

    func testMermaidIdentityAndStructuredContentPrecedenceUseFinalInspectionMetadata() throws {
        let diagram = Data("flowchart TD\nA --> B\n".utf8)
        for (name, uti, reason) in [
            ("sample.mmd", "public.swift-source", "fileExtension"),
            ("sample.MERMAID", "public.xml", "fileExtension"),
            ("sample.mmd", "com.apple.log", "fileExtension")
        ] {
            let result = PreviewInspectionResult.prepare(bytes: diagram, fileSize: diagram.count,
                fileName: name, systemUTI: uti)
            XCTAssertEqual(result.formatDefinition?.id, .mermaid, name)
            XCTAssertEqual(result.formatDefinition?.effectiveInspectorID, .text, name)
            XCTAssertEqual(result.formatName, "Mermaid source", name)
            XCTAssertEqual(result.detectionReason, reason, name)
            XCTAssertEqual(result.analysis.text, String(decoding: diagram, as: UTF8.self), name)
            XCTAssertNil(result.sourceDocument, name)
        }

        let blocked = PreviewInspectionResult.prepare(bytes: diagram, fileSize: diagram.count,
            fileName: "sample.swift", systemUTI: "com.glimt.mermaid-source")
        XCTAssertEqual(blocked.formatDefinition?.id, .swift)
        XCTAssertEqual(blocked.formatName, "Swift")
        XCTAssertEqual(blocked.detectionReason, "fileExtension")

        let textBundleNamed = PreviewInspectionResult.prepare(bytes: diagram, fileSize: diagram.count,
            fileName: "sample.textbundle", systemUTI: "com.glimt.mermaid-source")
        XCTAssertEqual(textBundleNamed.formatDefinition?.id, .textbundle)
        XCTAssertEqual(textBundleNamed.formatName, "TextBundle")
        XCTAssertEqual(textBundleNamed.detectionReason, "fileExtension")

        let unqualified = PreviewInspectionResult.prepare(bytes: diagram, fileSize: diagram.count,
            fileName: "sample.textbundle", systemUTI: nil)
        XCTAssertEqual(unqualified.formatDefinition?.id, .textbundle)
        XCTAssertEqual(unqualified.analysis.text, String(decoding: diagram, as: UTF8.self))

        let logLike = Data("2026-11-19T10:00:00Z ERROR api: failed\n".utf8)
        let namedLog = PreviewInspectionResult.prepare(bytes: logLike, fileSize: logLike.count,
            fileName: "events.log", systemUTI: "com.glimt.mermaid-source")
        XCTAssertEqual(namedLog.formatDefinition?.id, .log)
        let namedDiagramLog = PreviewInspectionResult.prepare(bytes: logLike, fileSize: logLike.count,
            fileName: "events.mmd", systemUTI: nil)
        XCTAssertEqual(namedDiagramLog.formatDefinition?.id, .mermaid)

        let xml = Data("<?xml version=\"1.0\"?><root><value>ok</value></root>".utf8)
        let xmlResult = PreviewInspectionResult.prepare(bytes: xml, fileSize: xml.count,
            fileName: "diagram.mmd", systemUTI: nil)
        XCTAssertEqual(xmlResult.formatDefinition?.id, .xml)
        XCTAssertEqual(xmlResult.detectionReason, "contentProbe")
        XCTAssertNotNil(xmlResult.xmlInspection?.root)

        let plistBytes = try Data(contentsOf: fixtureURL("Cases/plist/xml/simple.plist"))
        let plistResult = PreviewInspectionResult.prepare(bytes: plistBytes, fileSize: plistBytes.count,
            fileName: "diagram.mermaid", systemUTI: nil)
        XCTAssertEqual(plistResult.formatDefinition?.id, .plist)
        XCTAssertNotNil(plistResult.plistInspection?.content)

        let binaryPlist = try Data(contentsOf: fixtureURL("Showcase/plist/binary.plist"))
        let binaryPlistResult = PreviewInspectionResult.prepare(bytes: binaryPlist, fileSize: binaryPlist.count,
            fileName: "diagram.mmd", systemUTI: nil)
        XCTAssertEqual(binaryPlistResult.formatDefinition?.id, .plist)
        XCTAssertEqual(binaryPlistResult.detectionReason, "magicBytes")
        let genericBinary = Data([0, 1, 2, 3])
        let binaryResult = PreviewInspectionResult.prepare(bytes: genericBinary, fileSize: genericBinary.count,
            fileName: "diagram.mmd", systemUTI: nil)
        XCTAssertNil(binaryResult.formatDefinition)
        XCTAssertEqual(binaryResult.formatName, "Binary data")
        XCTAssertEqual(binaryResult.detectionReason, "binary")

        let mappedToMermaid = PreviewInspectionResult.prepare(bytes: diagram, fileSize: diagram.count,
            fileName: "plain.txt", systemUTI: nil, formatOverride: .mermaid)
        XCTAssertEqual(mappedToMermaid.formatDefinition?.id, .mermaid)
        XCTAssertEqual(mappedToMermaid.detectionReason, "userOverride")
        let mappedAway = PreviewInspectionResult.prepare(bytes: diagram, fileSize: diagram.count,
            fileName: "diagram.mmd", systemUTI: nil, formatOverride: .source(.swift))
        XCTAssertEqual(mappedAway.formatDefinition?.id, .swift)
        XCTAssertEqual(mappedAway.detectionReason, "userOverride")
        let binaryOverride = PreviewInspectionResult.prepare(bytes: genericBinary, fileSize: genericBinary.count,
            fileName: "diagram.mmd", systemUTI: nil, formatOverride: .mermaid)
        XCTAssertNil(binaryOverride.formatDefinition)
        XCTAssertEqual(binaryOverride.formatName, "Binary data")
        let binaryPlistOverride = PreviewInspectionResult.prepare(bytes: binaryPlist, fileSize: binaryPlist.count,
            fileName: "diagram.mmd", systemUTI: nil, formatOverride: .mermaid)
        XCTAssertEqual(binaryPlistOverride.formatName, "Binary data")
        XCTAssertEqual(binaryPlistOverride.detectionReason, "userOverride")
    }

    func testMalformedInputsRetainRawAndMissingMetadataFallsBack() throws {
        for path in ["Cases/json/invalid/malformed.json", "Cases/yaml/invalid/malformed.yaml", "Cases/xml/invalid/malformed.xml", "Cases/plist/invalid/malformed.plist"] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in throw CocoaError(.fileReadUnknown) })
            let retained = result.jsonInspection?.rawBytes ?? result.yamlInspection?.rawBytes ?? result.xmlInspection?.rawBytes ?? result.plistInspection?.rawBytes
            XCTAssertEqual(retained, bytes, path)
            let diagnostics = result.jsonInspection?.diagnostics ?? result.yamlInspection?.diagnostics ?? result.xmlInspection?.diagnostics ?? result.plistInspection?.diagnostics ?? []
            XCTAssertFalse(diagnostics.isEmpty, path)
        }
        let missing = try fixtureURL("Showcase/text/plain.txt").appendingPathComponent("missing")
        XCTAssertThrowsError(try PreviewInspectionResult.read(at: missing))
    }

    func testReadAndPrepareRemainBounded() throws {
        let bytes = Data(repeating: 97, count: 1_048_577)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtPreviewInspection-\(UUID().uuidString).txt")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(result.analysis.text.utf8.count, 1_048_576)
        XCTAssertTrue(result.analysis.truncated)
        XCTAssertEqual(result.sampleByteCount, 65_536)
        XCTAssertFalse(result.sampleIsComplete)
    }

    func testReadRejectsFIFOWithoutBlocking() throws {
        let fifo = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlimtPreviewFIFO-\(UUID().uuidString)")
        let result = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(result, 0, "mkfifo errno=\(errno)")
        defer { try? FileManager.default.removeItem(at: fifo) }

        assertReadThrowsWithinTimeout { _ = try PreviewInspectionResult.read(at: fifo) }
        let symlink = fifo.deletingLastPathComponent().appendingPathComponent("GlimtPreviewFIFO-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fifo)
        defer { try? FileManager.default.removeItem(at: symlink) }
        assertReadThrowsWithinTimeout { _ = try PreviewInspectionResult.read(at: symlink) }
    }

    func testCoreV1PrecedenceAndAmbiguousInputs() throws {
        let cases: [(String, String, String?, String)] = [
            ("Cases/plist/xml/simple.plist", "settings.plist", "public.xml", "Property list"),
            ("Showcase/plist/binary.plist", "settings.plist", nil, "Property list"),
            ("Cases/json/valid/simple.json", "settings.json", "public.python-script", "JSON"),
            ("Showcase/yaml/yaml.yaml", "settings.yaml", "public.python-script", "YAML"),
            ("Showcase/yaml/yaml.yaml", "settings.yml", nil, "YAML"),
            ("Cases/markdown/basic.md", "notes.md", "public.python-script", "Markdown"),
            ("Cases/source/Example.swift", "example.swift", "public.text", "Swift"),
            ("Showcase/source/typescript.ts", "typescript.ts", "public.mpeg-2-transport-stream", "TypeScript"),
            ("Cases/ambiguous/extensionless-python", "script", nil, "Python"),
            ("Cases/ambiguous/shell-script", "script", nil, "Shell"),
            ("Showcase/text/plain.txt", "unknown", nil, "Plain text"),
            ("Cases/binary/extensionless", "unknown", nil, "Binary data"),
            ("Cases/binary/binary.ts", "misleading.swift", "public.swift-source", "Binary data"),
            ("Cases/binary/extensionless", "misleading.txt", "public.text", "Binary data")
        ]
        for (path, name, uti, expected) in cases {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: name, systemUTI: uti)
            XCTAssertEqual(result.formatName, expected, "\(path) / \(uti ?? "none")")
            if expected == "Binary data" { XCTAssertNil(result.sourceDocument); XCTAssertTrue(result.analysis.isBinary) }
        }
    }

    func testAllFormatReadsRetainOnlyBoundedPrefixes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = String(repeating: "x", count: 1_048_600)
        for (name, bytes) in [
            ("large.txt", Data(payload.utf8)), ("large.swift", Data(("// " + payload).utf8)),
            ("large.md", Data(("# " + payload).utf8)), ("large.json", Data(("[\"" + payload + "\"]").utf8)),
            ("large.yaml", Data(("value: " + payload).utf8)), ("large.xml", Data(("<root>" + payload + "</root>").utf8)),
            ("large.plist", try PropertyListSerialization.data(fromPropertyList: ["value": payload], format: .binary, options: 0))
        ] {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertTrue(result.analysis.truncated, name)
            XCTAssertLessThanOrEqual(result.analysis.text.utf8.count, 1_048_576, name)
            XCTAssertFalse(result.sampleIsComplete, name)
            XCTAssertNil(result.jsonInspection?.content, name)
            XCTAssertNil(result.yamlInspection?.documents, name)
            XCTAssertNil(result.xmlInspection?.root, name)
            XCTAssertNil(result.plistInspection?.content, name)
            XCTAssertNil(result.markdownDocument?.renderedText, name)
            let raw = result.jsonInspection?.rawBytes ?? result.yamlInspection?.rawBytes ?? result.xmlInspection?.rawBytes ?? result.plistInspection?.rawBytes
            if let raw { XCTAssertEqual(raw, bytes.prefix(1_048_576), name) }
        }
    }

    func testUserPreviewPreferenceCannotRaiseTheReadCeiling() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let bytes = Data(repeating: 97, count: 1_048_577)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let small = try PreviewInspectionResult.read(at: url, maximumBytes: 65_536, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(small.analysis.text.utf8.count, 65_536)
        XCTAssertTrue(small.analysis.truncated)
        let overCeiling = try PreviewInspectionResult.read(at: url, maximumBytes: Int.max, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(overCeiling.analysis.text.utf8.count, 1_048_576)
        XCTAssertTrue(overCeiling.analysis.truncated)
    }

    func testExplicitMappingPrecedesAutomaticDetectionWithoutChangingOriginalData() {
        let bytes = Data("hello world\n".utf8)
        let mapped = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.foo", systemUTI: "public.data", formatOverride: .yaml, overrideDescription: "User override (*.foo)")
        XCTAssertEqual(mapped.formatName, "YAML")
        XCTAssertEqual(mapped.detectionReason, "userOverride")
        XCTAssertEqual(mapped.automaticFormatName, "Plain text")
        XCTAssertEqual(mapped.systemUTI, "public.data")
        XCTAssertEqual(mapped.yamlInspection?.rawBytes, bytes)
        let json = Data("{\"value\":42}".utf8)
        let text = PreviewInspectionResult.prepare(bytes: json, fileSize: json.count, fileName: "sample.json", systemUTI: "public.json", formatOverride: .text)
        XCTAssertEqual(text.formatName, "Plain text")
        XCTAssertNil(text.jsonInspection)
        XCTAssertEqual(text.analysis.text, String(decoding: json, as: UTF8.self))
        let binary = PreviewInspectionResult.prepare(bytes: Data([0, 1, 2]), fileSize: 3, fileName: "sample.foo", systemUTI: nil, formatOverride: .source(.python))
        XCTAssertNil(binary.sourceDocument)
        XCTAssertEqual(binary.formatName, "Binary data")
    }

    func testLegacyOverridePreparesAutomaticInspectorForItsLabel() throws {
        let dispatches = InspectorDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            DispatchRecordingInspector(id: .json, recorder: dispatches),
            DispatchRecordingInspector(id: .yaml, recorder: dispatches)
        ])
        let bytes = Data("{\"value\": 1}\n".utf8)

        let result = PreviewInspectionResult.prepareForTesting(bytes: bytes, fileSize: bytes.count,
            fileName: "sample.json", systemUTI: nil, formatOverride: .yaml, registry: registry)

        XCTAssertEqual(result.automaticFormatName, "JSON")
        XCTAssertEqual(result.formatName, "YAML")
        XCTAssertEqual(dispatches.values, [.json, .yaml],
                       "Legacy override preparation inspects the automatic route for its label, then the effective route")
    }

    func testCancelledReadDoesNotStartMetadataAccess() async throws {
        let url = try fixtureURL("Showcase/text/plain.txt")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in
                XCTFail("Cancelled read must not request metadata")
                return nil
            })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func assertReadThrowsWithinTimeout(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @Sendable () throws -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = BoundedReadTestOutcome()
        DispatchQueue.global().async {
            do { try operation(); outcome.record(didThrow: false) }
            catch { outcome.record(didThrow: true) }
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(completed, "Special-file read did not return within two seconds", file: file, line: line)
        XCTAssertTrue(outcome.didThrow, "Special-file read should fail", file: file, line: line)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class BoundedReadTestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDidThrow = false
    var didThrow: Bool { lock.lock(); defer { lock.unlock() }; return storedDidThrow }
    func record(didThrow: Bool) { lock.lock(); storedDidThrow = didThrow; lock.unlock() }
}

private final class RegularFileEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [RegularFileReadEvent] = []
    var values: [RegularFileReadEvent] { lock.lock(); defer { lock.unlock() }; return storedValues }
    func append(_ value: RegularFileReadEvent) { lock.lock(); storedValues.append(value); lock.unlock() }
}

private final class StagedReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    var shouldInterrupt: Bool {
        lock.lock(); defer { lock.unlock() }
        if interrupted { return false }
        interrupted = true
        return true
    }
}

private final class SelectedLanguageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SourceLanguage?
    var value: SourceLanguage? { lock.lock(); defer { lock.unlock() }; return stored }
    func store(_ value: SourceLanguage?) { lock.lock(); stored = value; lock.unlock() }
}

private final class InspectorDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [InspectorID] = []
    var values: [InspectorID] { lock.lock(); defer { lock.unlock() }; return storedValues }
    func append(_ value: InspectorID) { lock.lock(); storedValues.append(value); lock.unlock() }
}

private struct DispatchRecordingInspector: FormatInspector {
    let id: InspectorID
    let recorder: InspectorDispatchRecorder

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        recorder.append(id)
        return .text
    }
}
