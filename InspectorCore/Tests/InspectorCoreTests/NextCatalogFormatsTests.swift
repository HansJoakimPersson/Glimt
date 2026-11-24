import Foundation
import CryptoKit
import XCTest
@testable import InspectorCore

final class NextCatalogFormatsTests: XCTestCase {
    func testFstabFilenameEvidenceAndRouting() throws {
        let text = Data("UUID=abc / ext4 defaults 1 1\n".utf8)
        let lower = PreviewInspectionResult.prepare(bytes: text, fileSize: text.count, fileName: "fstab", systemUTI: "public.json")
        XCTAssertEqual(lower.selectedFormatID, .fstab)
        XCTAssertEqual(lower.detectionReason, "exactFilename")
        XCTAssertEqual(lower.resolution.typeID, FormatID.fstab.rawValue)
        XCTAssertEqual(lower.resolution.confidence.value, 1)
        XCTAssertTrue(lower.resolution.evidence.contains { $0.signalKind == .utiConflict })

        let folded = TypeResolver().resolve(fileName: "FSTAB", systemUTI: "public.json")
        XCTAssertEqual(folded.typeID, FormatID.fstab.rawValue)
        XCTAssertEqual(folded.confidence.value, 1)
        XCTAssertTrue(folded.evidence.contains { $0.signalKind == .utiConflict })

        let upper = PreviewInspectionResult.prepare(bytes: text, fileSize: text.count, fileName: "FSTAB", systemUTI: nil)
        XCTAssertEqual(upper.formatName, "Plain text")
        XCTAssertEqual(upper.selectedFormatID, .text)
        XCTAssertNil(upper.additionalInspection)
        let upperConflict = PreviewInspectionResult.prepare(bytes: text, fileSize: text.count, fileName: "FSTAB", systemUTI: "public.json")
        XCTAssertEqual(upperConflict.formatName, "Plain text")
        XCTAssertEqual(upperConflict.selectedFormatID, .text)
        XCTAssertNil(upperConflict.additionalInspection)

        let overridden = PreviewInspectionResult.prepare(bytes: text, fileSize: text.count, fileName: "fstab", systemUTI: nil, formatOverride: .text)
        XCTAssertEqual(overridden.selectedFormatID, .text)
        XCTAssertNil(overridden.additionalInspection)

        let plistText = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><string>x</string></plist>".utf8)
        let plistName = PreviewInspectionResult.prepare(bytes: plistText, fileSize: plistText.count, fileName: "fstab", systemUTI: "com.apple.property-list")
        XCTAssertEqual(plistName.selectedFormatID, .fstab)
        let binaryPlist = Data("bplist00".utf8) + Data([0x00, 0x00])
        let signature = PreviewInspectionResult.prepare(bytes: binaryPlist, fileSize: binaryPlist.count, fileName: "fstab", systemUTI: nil)
        XCTAssertEqual(signature.selectedFormatID, .plist)
        XCTAssertEqual(signature.detectionReason, "magicBytes")

        let shell = Data("#!/bin/sh\necho ok\n".utf8)
        let upperShell = PreviewInspectionResult.prepare(bytes: shell, fileSize: shell.count, fileName: "FSTAB", systemUTI: nil)
        XCTAssertEqual(upperShell.sourceDocument?.language, .shell)
        XCTAssertEqual(upperShell.detectionReason, "shebang")

        let unrelated = PreviewInspectionResult.prepare(bytes: text, fileSize: text.count, fileName: "mounts", systemUTI: "public.data")
        XCTAssertEqual(unrelated.formatName, "Plain text")
        XCTAssertNotEqual(unrelated.selectedFormatID, .fstab)
        XCTAssertNil(unrelated.additionalInspection)
        let suffix = PreviewInspectionResult.prepare(bytes: text, fileSize: text.count, fileName: "sample.fstab", systemUTI: nil)
        XCTAssertNotEqual(suffix.selectedFormatID, .fstab)
        XCTAssertNil(suffix.additionalInspection)
    }

    func testFstabCatalogAndReferenceRows() throws {
        let format = try XCTUnwrap(FormatCatalog.definition(for: .fstab))
        XCTAssertEqual(format.status, .supported)
        XCTAssertEqual(format.displayName, "fstab")
        XCTAssertEqual(format.category, .configuration)
        XCTAssertEqual(format.exactFilenames, ["fstab"])
        XCTAssertTrue(format.extensions.isEmpty)
        XCTAssertTrue(format.contentTypeIdentifiers.isEmpty)
        XCTAssertEqual(format.effectiveInspectorID, .fstab)
        XCTAssertEqual(format.availableRepresentations, [.tree, .raw])
        XCTAssertEqual(format.presentationOrder, [.tree, .raw])
        XCTAssertEqual(format.effectiveDefaultRepresentation, .tree)
        XCTAssertEqual(format.effectiveSettingsProfile, .text)
        XCTAssertEqual(format.effectiveThumbnailStrategy, .textLines)

        let fixture = try Data(contentsOf: fixtureURL("Showcase/config/fstab"))
        let result = PreviewInspectionResult.prepare(bytes: fixture, fileSize: fixture.count, fileName: "fstab", systemUTI: nil)
        XCTAssertEqual(result.originalBytes, fixture)
        XCTAssertEqual(result.analysis.text, String(decoding: fixture, as: UTF8.self))
        guard case .records(let id, .array(let rows), let diagnostics, let complete, _) = try XCTUnwrap(result.additionalInspection) else {
            return XCTFail("fstab should produce structured records")
        }
        XCTAssertEqual(id, .fstab)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertTrue(complete)
        XCTAssertEqual(rows.map { member($0, "Line") }, [.number("2"), .number("3"), .number("4")])
        XCTAssertEqual(rows.map { member($0, "Filesystem specification") }, [.string("UUID=1234-ABCD"), .string("/dev/sda2"), .string("tmpfs")])
        XCTAssertEqual(rows.map { member($0, "Mount point") }, [.string("/boot/efi"), .string("/"), .string("/tmp")])
        XCTAssertEqual(rows.map { member($0, "Filesystem type") }, [.string("vfat"), .string("ext4"), .string("tmpfs")])
        XCTAssertEqual(rows.map { member($0, "Options") }, [.string("umask=0077"), .string("defaults"), .string("nosuid")])
        XCTAssertEqual(rows.map { member($0, "Dump frequency") }, [.number("0"), .number("0"), .number("0")])
        XCTAssertEqual(rows.map { member($0, "Pass number") }, [.number("1"), .number("1"), .number("0")])
        XCTAssertEqual(rows.first.map { objectKeys($0) }, ["Line", "Filesystem specification", "Mount point", "Filesystem type", "Options", "Dump frequency", "Pass number"])
    }

    func testExtensionlessPublicDataUsesGenericTextFallback() {
        let mountTable = Data("UUID=abc / ext4 defaults 1 1\n".utf8)
        let result = PreviewInspectionResult.prepare(bytes: mountTable, fileSize: mountTable.count,
                                                     fileName: "mount-table", systemUTI: "public.data")
        XCTAssertEqual(result.formatName, "Plain text")
        XCTAssertNotEqual(result.selectedFormatID, .fstab)
        XCTAssertNil(result.additionalInspection)
    }

    func testFstabRowRecoveryAndLimits() throws {
        let mixed = "# heading\n\nroot / ext4 defaults 0001 0002\nsource\\040name /mnt\\040x ext4 opts\npath#tag /p ext4 x 0\t0 # comment\r\ncommented /ignored ext4 x # inert\r\n"
        let parsed = try FstabInspector.inspect(mixed)
        XCTAssertEqual(parsed.rows.count, 4)
        XCTAssertTrue(parsed.diagnostics.isEmpty)
        XCTAssertTrue(parsed.rawIsComplete)
        XCTAssertEqual(parsed.rows.map { member($0, "Line") }, [.number("3"), .number("4"), .number("5"), .number("6")])
        XCTAssertEqual(member(parsed.rows[0], "Dump frequency"), .number("1"))
        XCTAssertEqual(member(parsed.rows[0], "Pass number"), .number("2"))
        XCTAssertEqual(member(parsed.rows[1], "Filesystem specification"), .string("source\\040name"))
        XCTAssertEqual(member(parsed.rows[1], "Mount point"), .string("/mnt\\040x"))
        XCTAssertEqual(member(parsed.rows[2], "Filesystem specification"), .string("path#tag"))
        XCTAssertEqual(member(parsed.rows[3], "Dump frequency"), .null)
        XCTAssertEqual(member(parsed.rows[3], "Pass number"), .null)

        let malformed = try FstabInspector.inspect("bad\na / t o +1\nb / t o 18446744073709551616 0\nc / t o ٠ 0\nd / t o\rrest\nok / t o 0 0\n")
        XCTAssertEqual(malformed.rows.count, 1)
        XCTAssertEqual(malformed.diagnostics.map(\.code), [.parseError, .parseError, .parseError, .parseError, .parseError])
        XCTAssertTrue(malformed.diagnostics.allSatisfy { $0.message.contains("line ") })
        XCTAssertEqual(member(malformed.rows[0], "Line"), .number("6"))
        let allBad = try FstabInspector.inspect("bad\nstill bad\n")
        XCTAssertTrue(allBad.rows.isEmpty)
        XCTAssertEqual(allBad.diagnostics.map(\.code), [.parseError, .parseError])
        let empty = try FstabInspector.inspect("\n # only\n\t# comment\n")
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertTrue(empty.diagnostics.isEmpty)

        let numbers = try FstabInspector.inspect("a / t o 9223372036854775807 000\nb / t o 0\n")
        XCTAssertEqual(member(numbers.rows[0], "Dump frequency"), .number("9223372036854775807"))
        XCTAssertEqual(member(numbers.rows[0], "Pass number"), .number("0"))
        XCTAssertEqual(member(numbers.rows[1], "Dump frequency"), .number("0"))
        XCTAssertEqual(member(numbers.rows[1], "Pass number"), .null)

        let saturated = try FstabInspector.inspect(String(repeating: "bad\n", count: 105))
        XCTAssertEqual(saturated.rows.count, 0)
        XCTAssertEqual(saturated.diagnostics.count, 98)

        let exactLines = try FstabInspector.inspect("\na / t o\n", limits: .init(maximumLines: 2))
        XCTAssertTrue(exactLines.diagnostics.isEmpty)
        let extraLine = try FstabInspector.inspect("a / t o\nb / t o\nc / t o\n", limits: .init(maximumLines: 2))
        XCTAssertEqual(extraLine.rows.count, 2)
        XCTAssertEqual(extraLine.diagnostics.map(\.code), [.limitExceeded])
        XCTAssertTrue(extraLine.diagnostics[0].message.contains("line 3"))

        let exactRecords = try FstabInspector.inspect("a / t o\n", limits: .init(maximumRecords: 1))
        XCTAssertTrue(exactRecords.diagnostics.isEmpty)
        let extraRecord = try FstabInspector.inspect("a / t o\nb / t o\n", limits: .init(maximumRecords: 1))
        XCTAssertEqual(extraRecord.rows.count, 1)
        XCTAssertEqual(extraRecord.diagnostics.map(\.code), [.limitExceeded])
        XCTAssertTrue(extraRecord.diagnostics[0].message.contains("line 2"))

        let completeUnterminated = try FstabInspector.inspect("a / t o 0 0")
        XCTAssertEqual(completeUnterminated.rows.count, 1)
        let truncatedFragment = try FstabInspector.inspect("a / t o 0 0\nbroken", isComplete: false)
        XCTAssertEqual(truncatedFragment.rows.count, 1)
        XCTAssertEqual(truncatedFragment.diagnostics.map(\.code), [.truncated])
        XCTAssertTrue(truncatedFragment.diagnostics[0].message.contains("line 2"))
        let truncatedCR = try FstabInspector.inspect("a / t o 0 0\nbroken\r", isComplete: false)
        XCTAssertEqual(truncatedCR.rows.count, 1)
        XCTAssertEqual(truncatedCR.diagnostics.map(\.code), [.truncated])
        let truncatedAtLF = try FstabInspector.inspect("a / t o 0 0\n", isComplete: false)
        XCTAssertEqual(truncatedAtLF.rows.count, 1)
        XCTAssertEqual(truncatedAtLF.diagnostics.map(\.code), [.truncated])

        let combinedStop = try FstabInspector.inspect("a / t o 0 0\nb / t o 0 0\nfragment",
                                                       isComplete: false,
                                                       limits: .init(maximumRecords: 1))
        XCTAssertEqual(combinedStop.rows.count, 1)
        XCTAssertEqual(combinedStop.diagnostics.map(\.code), [.limitExceeded, .truncated])
        XCTAssertTrue(combinedStop.diagnostics[1].message.contains("line 3"))
    }

    func testFstabCancellation() async throws {
        let input = "a / t o 0 0\n"
        let beforeCommit = FstabCancellationCounter()
        XCTAssertThrowsError(try FstabInspector.inspect(input, cancellationCheck: {
            if beforeCommit.increment() == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }

        let alongsideLimit = FstabCancellationCounter()
        XCTAssertThrowsError(try FstabInspector.inspect(input, limits: .init(maximumRecords: 0), cancellationCheck: {
            if alongsideLimit.increment() == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }

        let bytes = Data(input.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
        let resolution = TypeResolver().resolve(fileName: "fstab", leadingBytes: bytes, sampleIsComplete: true)
        let registry = try FormatInspectorRegistry([CancellingFstabFormatInspector()])
        let (route, outcome) = InspectionPipeline.inspect(bytes: bytes, fileSize: bytes.count,
            fileName: "fstab", systemUTI: nil, markdownOptions: .init(), formatOverride: nil,
            analysis: analysis, resolution: resolution, registry: registry)
        XCTAssertEqual(route.inspectorID, .fstab)
        if case .cancelled = outcome {} else { XCTFail("pipeline should map inspector cancellation") }

        let prepared = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: "fstab", systemUTI: nil)
        }.value
        XCTAssertEqual(prepared.selectedFormatID, .fstab)
        XCTAssertEqual(prepared.analysis.text, input)
        XCTAssertEqual(prepared.originalBytes, bytes)
        XCTAssertTrue(prepared.sampleIsComplete)
        XCTAssertNil(prepared.additionalInspection)
        XCTAssertTrue(prepared.inspectionDiagnostics.isEmpty)

        let partialBytes = Data(input.utf8) + Data([0xE2, 0x82])
        let incompleteTail = PreviewInspectionResult.prepare(bytes: partialBytes,
            fileSize: partialBytes.count + 1, fileName: "fstab", systemUTI: nil)
        XCTAssertEqual(incompleteTail.originalBytes, partialBytes)
        XCTAssertFalse(incompleteTail.sampleIsComplete)
        XCTAssertEqual(incompleteTail.analysis.text, input)
        XCTAssertEqual(incompleteTail.additionalInspection?.rawIsComplete, false)
        XCTAssertEqual(incompleteTail.inspectionDiagnostics.map(\.code), [.truncated])
    }

    func testFstabRealInput() throws {
        let environment = ProcessInfo.processInfo.environment
        let requiredValue = environment["GLIMT_REQUIRE_FSTAB_REAL_INPUT"] ?? "0"
        guard requiredValue == "0" || requiredValue == "1" else {
            return XCTFail("Fstab real-input required-mode flag must be 0 or 1")
        }
        let required = requiredValue == "1"
        guard let rawPath = environment["GLIMT_FSTAB_REAL_INPUT"] else {
            if required { return XCTFail("Required fstab real-input path is unset") }
            throw XCTSkip("Optional fstab real input is not configured")
        }
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return XCTFail("Fstab real-input path must not be empty")
        }

        let inputURL = URL(fileURLWithPath: rawPath)
        let receiptURL = inputURL.deletingLastPathComponent().appendingPathComponent("provenance.txt")
        let specimen = try BoundedFileReader.readPrefix(at: inputURL, maximumBytes: 1_048_576)
        let receiptPrefix = try BoundedFileReader.readPrefix(at: receiptURL, maximumBytes: 4_096)
        XCTAssertTrue(!specimen.data.isEmpty && specimen.data.count == specimen.fileSize && specimen.fileSize <= 1_048_576,
                      "Fstab specimen is nonempty, complete and within the read bound")
        XCTAssertTrue(!receiptPrefix.data.isEmpty && receiptPrefix.isComplete && receiptPrefix.fileSize <= 4_096,
                      "Fstab provenance receipt is nonempty, complete and within the read bound")

        guard let receiptText = String(data: receiptPrefix.data, encoding: .utf8) else {
            return XCTFail("Fstab provenance receipt is valid UTF-8")
        }
        var receiptLines = receiptText.components(separatedBy: "\n")
        if receiptLines.last == "" { receiptLines.removeLast() }
        guard receiptLines.count == 3 else { return XCTFail("Fstab provenance receipt has exactly three lines") }
        XCTAssertTrue(receiptLines[0] == "Upstream util-linux v2.42.4 Documentation/example.files/fstab (published reference file)",
                      "Fstab provenance identifies the pinned upstream source")
        guard let checksumMatch = receiptLines[1].range(of: #"^[0-9a-f]{64}  .+$"#, options: .regularExpression) else {
            return XCTFail("Fstab provenance checksum line is well formed")
        }
        _ = checksumMatch
        let receiptDigest = String(receiptLines[1].prefix(64))
        let receiptPath = String(receiptLines[1].dropFirst(66))
        guard !receiptPath.isEmpty else { return XCTFail("Fstab provenance checksum path is nonempty") }
        guard let activeMatch = receiptLines[2].range(of: #"^active=[0-9]+$"#, options: .regularExpression),
              let receiptActiveCount = Int(receiptLines[2].dropFirst("active=".count)) else {
            return XCTFail("Fstab provenance active-row count is well formed")
        }
        _ = activeMatch

        let specimenDigest = Self.sha256(specimen.data)
        let pinnedDigest = "c48c63f2f4d41acf0824578f3cd64082f041c13fa81a484e55bb8634a8f4079f"
        XCTAssertTrue(specimenDigest == receiptDigest && specimenDigest == pinnedDigest,
                      "Fstab specimen digest matches the receipt and pinned fingerprint")
        let independentActiveCount = Self.activePhysicalLineCount(specimen.data)
        XCTAssertTrue(independentActiveCount == receiptActiveCount && independentActiveCount == 6,
                      "Fstab independently counted active physical lines match the receipt and pin")

        let sharedRead = try PreviewInspectionResult.read(at: inputURL)
        XCTAssertTrue(sharedRead.originalBytes.count == specimen.data.count
                      && Self.sha256(sharedRead.originalBytes) == specimenDigest,
                      "Fstab shared bounded read matches specimen byte count and digest")
        let sharedRawText = String(decoding: specimen.data, as: UTF8.self)
        XCTAssertTrue(sharedRead.analysis.text == sharedRawText && sharedRead.originalBytes == specimen.data,
                      "Fstab shared Raw text and original bytes preserve the specimen")
        XCTAssertTrue(sharedRead.detectionReason == "exactFilename"
                      && sharedRead.resolution.evidence.contains { $0.signalKind == .filename && $0.score.value == 1 },
                      "Fstab shared route retains exact filename evidence")

        guard case .records(let id, .array(let rows), let diagnostics, let rawComplete, _) = try XCTUnwrap(sharedRead.additionalInspection) else {
            return XCTFail("Pinned fstab specimen produces structured records")
        }
        let expectedLines = (10...15).map { StructuredValue.number(String($0)) }
        let expectedMounts = ["/", "/boot", "/proc", "/sys", "/dev/shm", "/dev/pts"].map(StructuredValue.string)
        let expectedTypes = ["ext4", "ext4", "proc", "sysfs", "tmpfs", "devpts"].map(StructuredValue.string)
        let opaqueUUIDsMatch = rows.prefix(2).allSatisfy { row in
            guard case .string(let value)? = member(row, "Filesystem specification") else { return false }
            return value.hasPrefix("UUID=") && value.count > "UUID=".count
        }
        let remainingSpecifications = rows.dropFirst(2).map { member($0, "Filesystem specification") }
        let rowsMatch = id == .fstab && rows.count == 6
            && rows.map { member($0, "Line") } == expectedLines
            && rows.map { member($0, "Mount point") } == expectedMounts
            && rows.map { member($0, "Filesystem type") } == expectedTypes
            && opaqueUUIDsMatch
            && remainingSpecifications == ["proc", "sysfs", "tmpfs", "devpts"].map(StructuredValue.string)
            && member(rows[0], "Options") == .string("defaults")
            && member(rows[0], "Dump frequency") == .number("1")
            && member(rows[0], "Pass number") == .number("1")
            && member(rows[5], "Options") == .string("gid=5,mode=620")
            && member(rows[5], "Dump frequency") == .number("0")
            && member(rows[5], "Pass number") == .number("0")
        XCTAssertTrue(rowsMatch, "Fstab parsed rows match the pinned ordered field properties")
        XCTAssertTrue(diagnostics.isEmpty && rawComplete && sharedRead.analysis.text == sharedRawText,
                      "Fstab pinned result has no diagnostics, complete Raw and exact decoded text")

        let malformedControl = Data("invalid\n# comment\n".utf8)
        let controlActiveCount = Self.activePhysicalLineCount(malformedControl)
        let controlParsed = try FstabInspector.inspect(String(decoding: malformedControl, as: UTF8.self))
        XCTAssertTrue(controlActiveCount == 1 && controlParsed.rows.isEmpty
                      && controlParsed.diagnostics.map(\.code) == [.parseError],
                      "Independent active-line count includes malformed noncomment input")
        print("fstab real-input checks: bytes=\(specimen.data.count), active=\(independentActiveCount), parsed=\(rows.count), diagnostics=\(diagnostics.count), rawComplete=\(rawComplete)")
    }

    private func member(_ value: StructuredValue, _ key: String) -> StructuredValue? {
        guard case .object(let members) = value else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    private func objectKeys(_ value: StructuredValue) -> [String]? {
        guard case .object(let members) = value else { return nil }
        return members.map(\.key)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func activePhysicalLineCount(_ data: Data) -> Int {
        let bytes = Array(data)
        var active = 0
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 10 { end += 1 }
            var contentEnd = end
            if contentEnd > start, bytes[contentEnd - 1] == 13 { contentEnd -= 1 }
            var first = start
            while first < contentEnd, bytes[first] == 32 || bytes[first] == 9 { first += 1 }
            if first < contentEnd, bytes[first] != 35 { active += 1 }
            start = end < bytes.count ? end + 1 : bytes.count
        }
        return active
    }

    func testCatalogFormatsResolveToBoundedSourceViewsAndPreserveBytes() throws {
        let cases: [(String, String, SourceLanguage)] = [
            ("Showcase/source/latex.tex", "sample.tex", .latex),
            ("Showcase/build/Jenkinsfile", "Jenkinsfile", .groovy),
            ("Showcase/build/meson.build", "meson.build", .meson),
            ("Showcase/source/procedure.pkb", "procedure.pkb", .plsql)
        ]
        for (path, fileName, language) in cases {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertEqual(result.originalBytes, bytes, fileName)
            XCTAssertEqual(result.sourceDocument?.language, language, fileName)
            XCTAssertEqual(result.sourceDocument?.source, String(decoding: bytes, as: UTF8.self), fileName)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, fileName)
            XCTAssertEqual(result.formatDefinition?.status, .supported, fileName)
        }
        for (fileName, id) in [("sample.sty", FormatID.latex), ("Jenkinsfile", .jenkinsfile),
                               ("meson_options.txt", .meson), ("sample.PKB", .plsql)] {
            XCTAssertEqual(FormatCatalog.match(fileName: fileName)?.id, id, fileName)
        }
    }

    func testFourSpecializedLexersRecognizeRepresentativeSyntax() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.latex, "% note\n\\documentclass{article}\n\\title{42}\n\\texttt{\"hello\"}\n", "\\documentclass"),
            (.meson, "# note\nproject('demo', version: '1.0')\nexecutable('app', 'main.c')\n", "project"),
            (.plsql, "-- note\nCREATE OR REPLACE PROCEDURE greet AS\nBEGIN v_message := 'hello'; NULL; END;\n", "PROCEDURE")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0.caseInsensitiveCompare(keyword) == .orderedSame && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            if language != .latex { XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue) }
        }
    }
}

private final class FstabCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private struct CancellingFstabFormatInspector: FormatInspector {
    let id: InspectorID = .fstab
    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome { throw CancellationError() }
}
