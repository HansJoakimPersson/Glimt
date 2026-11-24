import Darwin
import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import InspectorCore

final class TextBundleInspectorTests: XCTestCase {
    func testStagedTextBundleReadsManifestBeforeMarkdownAndContinuesOnSameDescriptor() throws {
        let url = try makeTextBundle(markdown: Data(repeating: 0x61, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url) }

        var attemptDescriptors: [Int32] = []
        var readEventCount = 0
        var trace: [(child: TextBundleReadChild?, descriptor: Int32?)] = []
        var selectionTraceIndex: Int?
        let result = try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: 70_000,
            readOperation: { descriptor, buffer, count in
                attemptDescriptors.append(descriptor)
                let byteCount = Darwin.read(descriptor, buffer, count)
                return .init(byteCount: byteCount, errorCode: byteCount < 0 ? errno : nil)
            }, observe: { event in
                switch event {
                case .read(let child, _, _, _, _):
                    trace.append((child, attemptDescriptors[readEventCount]))
                    readEventCount += 1
                case .selectionCommitted:
                    selectionTraceIndex = trace.count
                    trace.append((nil, nil))
                default:
                    break
                }
            }) { sample, size in
                XCTAssertEqual(sample.count, 65_482)
                XCTAssertEqual(size, 70_000)
                return sample.count
            }

        XCTAssertEqual(result.prefix.data, Data(repeating: 0x61, count: 70_000))
        let markerIndex = try XCTUnwrap(selectionTraceIndex)
        let preselectionReads = trace[..<markerIndex]
        let postselectionReads = trace.dropFirst(markerIndex + 1)
        XCTAssertFalse(preselectionReads.isEmpty)
        XCTAssertTrue(preselectionReads.allSatisfy { $0.child == .manifest || $0.child == .markdown })
        let manifestIndexes = preselectionReads.indices.filter { preselectionReads[$0].child == .manifest }
        let markdownIndexes = preselectionReads.indices.filter { preselectionReads[$0].child == .markdown }
        XCTAssertFalse(manifestIndexes.isEmpty)
        XCTAssertFalse(markdownIndexes.isEmpty)
        let lastManifestIndex = try XCTUnwrap(manifestIndexes.last)
        let firstMarkdownIndex = try XCTUnwrap(markdownIndexes.first)
        XCTAssertLessThan(lastManifestIndex, firstMarkdownIndex,
                          "The complete manifest must be read before Markdown sampling starts")

        let manifestDescriptors = Set(preselectionReads.compactMap { $0.child == .manifest ? $0.descriptor : nil })
        let markdownDescriptorsBefore = Set(preselectionReads.compactMap { $0.child == .markdown ? $0.descriptor : nil })
        let markdownDescriptorsAfter = Set(postselectionReads.compactMap { $0.child == .markdown ? $0.descriptor : nil })
        XCTAssertEqual(manifestDescriptors.count, 1)
        XCTAssertEqual(markdownDescriptorsBefore.count, 1)
        XCTAssertEqual(markdownDescriptorsAfter, markdownDescriptorsBefore,
                       "Continuation must use the descriptor that supplied the routing sample")
        XCTAssertNotEqual(manifestDescriptors, markdownDescriptorsBefore)
        XCTAssertTrue(postselectionReads.allSatisfy { $0.child == .markdown })
    }

    func testStagedTextBundleChargesManifestAndFreezesAtSharedBudgetBoundary() throws {
        let manifest = try Data(contentsOf: fixtureURL("Showcase/markdown-family/note.textbundle/info.json"))
        XCTAssertEqual(manifest.count, 54)

        for length in [65_481, 65_482, 65_483] {
            let url = try makeTextBundle(manifest: manifest, markdown: Data(repeating: 0x61, count: length))
            defer { try? FileManager.default.removeItem(at: url) }
            var events: [TextBundleReadEvent] = []
            var selectedSample: Data?
            var selectedSize: Int?
            let result = try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: 1_048_576,
                observe: { events.append($0) }) { sample, size in
                    selectedSample = sample
                    selectedSize = size
                    return sample.count
                }

            let expectedSampleCount = min(length, 65_536 - manifest.count)
            XCTAssertEqual(selectedSample?.count, expectedSampleCount)
            XCTAssertEqual(selectedSize, length)
            XCTAssertEqual(result.selection, expectedSampleCount)
            XCTAssertEqual(result.prefix.data, Data(repeating: 0x61, count: length))
            XCTAssertEqual(result.prefix.fileSize, length)
            guard case .selectionCommitted(let routingCount, let distinctCount) = events.first(where: {
                if case .selectionCommitted = $0 { return true }
                return false
            }) else { return XCTFail("Expected one selection event") }
            XCTAssertEqual(routingCount, min(65_536, manifest.count + length))
            XCTAssertEqual(distinctCount, routingCount)

            let markerIndex = try XCTUnwrap(events.firstIndex(where: {
                if case .selectionCommitted = $0 { return true }
                return false
            }))
            let postSelectionMarkdownOffsets = events.dropFirst(markerIndex + 1).compactMap { event -> Int? in
                guard case .read(child: .markdown, let offset, _, _, _) = event else { return nil }
                return offset
            }
            XCTAssertTrue(postSelectionMarkdownOffsets.allSatisfy { $0 == expectedSampleCount })
            if length == 65_483 {
                XCTAssertEqual(postSelectionMarkdownOffsets.first, 65_482)
            } else {
                XCTAssertTrue(postSelectionMarkdownOffsets.isEmpty)
            }
        }
    }

    func testStagedTextBundleValidatesManifestAndMarkdownAtZeroRoutingAllowance() throws {
        let baseManifest = try Data(contentsOf: fixtureURL("Showcase/markdown-family/note.textbundle/info.json"))
        let paddedManifest = baseManifest + Data(repeating: 0x20, count: 65_536 - baseManifest.count)
        for markdown in [Data(), Data("payload".utf8)] {
            let url = try makeTextBundle(manifest: paddedManifest, markdown: markdown)
            defer { try? FileManager.default.removeItem(at: url) }
            var sample: Data?
            var observedMarker: (Int, Int)?
            let result = try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: 100,
                observe: { event in
                    if case .selectionCommitted(let count, let distinct) = event { observedMarker = (count, distinct) }
                }) { bytes, _ in
                    sample = bytes
                    return bytes.count
                }
            XCTAssertEqual(sample, Data())
            XCTAssertEqual(result.selection, 0)
            XCTAssertEqual(result.prefix.data, markdown)
            XCTAssertEqual(observedMarker?.0, 65_536)
            XCTAssertEqual(observedMarker?.1, 65_536)
        }

        let oversized = try makeTextBundle(manifest: paddedManifest + Data([0x20]), markdown: nil)
        defer { try? FileManager.default.removeItem(at: oversized) }
        XCTAssertThrowsError(try TextBundleInspector.readMarkdownStaged(at: oversized, maximumBytes: 1) {
            _, _ in XCTFail("Selection must not run for an oversized manifest"); return ()
        }) { error in
            XCTAssertEqual(error as? TextBundleError, .limitExceeded)
        }
    }

    func testStagedTextBundleReportsShortReadsAndRetriesInterruptedReadAtSameOffset() throws {
        let url = try makeTextBundle(markdown: Data("hello world".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var attempts = 0
        var events: [TextBundleReadEvent] = []
        let result = try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: 100,
            readOperation: { descriptor, buffer, count in
                attempts += 1
                if attempts == 1 { return .init(byteCount: -1, errorCode: EINTR) }
                let bounded = min(3, count)
                let readCount = Darwin.read(descriptor, buffer, bounded)
                return .init(byteCount: readCount, errorCode: readCount < 0 ? errno : nil)
            }, observe: { events.append($0) }) { sample, _ in sample.count }

        XCTAssertEqual(result.prefix.data, Data("hello world".utf8))
        let interrupted = try XCTUnwrap(events.first(where: {
            guard case .read(_, _, _, _, let code) = $0 else { return false }
            return code == EINTR
        }))
        guard case .read(child: .manifest, let interruptedOffset, _, 0, EINTR) = interrupted else {
            return XCTFail("Expected interrupted manifest read")
        }
        let interruptedIndex = try XCTUnwrap(events.firstIndex(where: {
            guard case .read(_, _, _, _, let code) = $0 else { return false }
            return code == EINTR
        }))
        let retry = try XCTUnwrap(events.dropFirst(interruptedIndex + 1).first(where: {
            guard case .read(child: .manifest, let offset, _, _, _) = $0 else { return false }
            return offset == interruptedOffset
        }))
        guard case .read(child: .manifest, let retriedOffset, _, let returned, nil) = retry else {
            return XCTFail("Expected a successful retry")
        }
        XCTAssertEqual(retriedOffset, interruptedOffset)
        XCTAssertGreaterThan(returned, 0)
    }

    func testStagedTextBundleFatalReadReportsErrorAndClosesDescriptors() throws {
        let url = try makeTextBundle(markdown: Data("payload".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var descriptors: Set<Int32> = []
        var events: [TextBundleReadEvent] = []
        XCTAssertThrowsError(try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: 10,
            readOperation: { descriptor, _, _ in
                descriptors.insert(descriptor)
                return .init(byteCount: -1, errorCode: EIO)
            }, observe: { events.append($0) }) { _, _ in () }) { error in
                XCTAssertEqual(error as? TextBundleError, .readFailed)
            }
        guard case .read(child: .manifest, let offset, _, 0, EIO) = try XCTUnwrap(events.first(where: {
            if case .read = $0 { true } else { false }
        })) else {
            return XCTFail("Expected a fatal manifest read event")
        }
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(descriptors.count, 1)
        for descriptor in descriptors {
            XCTAssertEqual(Darwin.fcntl(descriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testStagedTextBundlePinsInitialSizeAcrossGrowthAndFailsOnShrink() throws {
        let initial = Data(repeating: 0x61, count: 70_000)
        let growthURL = try makeTextBundle(markdown: initial)
        defer { try? FileManager.default.removeItem(at: growthURL) }
        var grew = false
        let grown = try TextBundleInspector.readMarkdownStaged(at: growthURL, maximumBytes: 100_000,
            observe: { event in
                guard case .selectionCommitted = event, !grew else { return }
                grew = true
                if let handle = try? FileHandle(forWritingTo: growthURL.appendingPathComponent("text.md")) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(repeating: 0x62, count: 5_000))
                    try? handle.close()
                }
            }) { sample, size in
                XCTAssertEqual(size, initial.count)
                return sample.count
            }
        XCTAssertTrue(grew)
        XCTAssertEqual(grown.prefix.data, initial)
        XCTAssertEqual(grown.prefix.fileSize, initial.count)

        let shrinkURL = try makeTextBundle(markdown: initial)
        defer { try? FileManager.default.removeItem(at: shrinkURL) }
        var shrunk = false
        XCTAssertThrowsError(try TextBundleInspector.readMarkdownStaged(at: shrinkURL, maximumBytes: 100_000,
            observe: { event in
                guard case .selectionCommitted = event, !shrunk else { return }
                shrunk = true
                if let handle = try? FileHandle(forWritingTo: shrinkURL.appendingPathComponent("text.md")) {
                    try? handle.truncate(atOffset: 65_482)
                    try? handle.close()
                }
            }) { sample, _ in sample.count }) { error in
                XCTAssertEqual(error as? TextBundleError, .readFailed)
            }
        XCTAssertTrue(shrunk)
    }

    func testTextBundleAcceptsVersionOneAndRejectsNonregularMarkdownAtZeroLimit() throws {
        let manifest = Data("{\"version\":1}\n".utf8)
        let url = try makeTextBundle(manifest: manifest, markdown: Data("# Version one\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let direct = try TextBundleInspector.readMarkdown(at: url, maximumBytes: 0)
        XCTAssertTrue(direct.data.isEmpty)
        XCTAssertEqual(direct.fileSize, 14)
        let result = try PreviewInspectionResult.readTextBundle(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(result.selectedInspectorID, .markdown, "An omitted manifest type defaults to Markdown")

        let nonregularURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-\(UUID().uuidString).textbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: nonregularURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonregularURL) }
        try manifest.write(to: nonregularURL.appendingPathComponent("info.json"))
        let fifoResult: Int32 = nonregularURL.appendingPathComponent("text.md").withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(0o600))
        }
        XCTAssertEqual(fifoResult, 0)
        XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: nonregularURL, maximumBytes: 0)) { error in
            XCTAssertEqual(error as? TextBundleError, .invalidPackage)
        }
    }

    func testTextBundleStagedReadHonorsCancellationBeforeAndAfterSelection() async throws {
        let url = try makeTextBundle(markdown: Data("![local](assets/pixel.png)\n".utf8) + Data(repeating: 0x61, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let assetsURL = url.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
        try pixel.write(to: assetsURL.appendingPathComponent("pixel.png"))
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewInspectionResult.readTextBundle(at: url, contentTypeIdentifier: { _ in nil })
        }
        do { _ = try await preCancelled.value; XCTFail("Expected cancellation before package open") }
        catch { XCTAssertTrue(error is CancellationError) }

        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: dispatches)
        ])
        let markerObserved = TextBundleMetadataRecorder()
        let afterSelection = Task {
            try PreviewInspectionResult.readTextBundle(at: url, contentTypeIdentifier: { _ in nil },
                observe: { event in
                    if case .selectionCommitted = event {
                        markerObserved.increment()
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }, inspectionRegistry: registry)
        }
        do { _ = try await afterSelection.value; XCTFail("Expected cancellation after selection") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(markerObserved.count, 1)
        XCTAssertTrue(dispatches.calls.isEmpty)
    }

    func testSynchronousTextBundleResolvesLocalImageAfterMarkdownInspection() throws {
        let markdown = Data("![local](assets/pixel.png)\n\n# Heading\n".utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let assetsURL = url.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
        try pixel.write(to: assetsURL.appendingPathComponent("pixel.png"))

        let result = try PreviewInspectionResult.readTextBundle(at: url, contentTypeIdentifier: { _ in nil })
        let document = try XCTUnwrap(result.markdownDocument)
        let image = try XCTUnwrap(document.images.first)
        XCTAssertEqual(document.raw, String(decoding: markdown, as: UTF8.self))
        XCTAssertEqual(result.originalBytes, markdown)
        XCTAssertEqual(document.headings.map(\.title), ["Heading"])
        XCTAssertEqual(image.destination, "assets/pixel.png")
        XCTAssertEqual(image.data, pixel)
        XCTAssertEqual(image.pixelWidth, 1)
        XCTAssertEqual(image.pixelHeight, 1)
    }

    func testSynchronousTextBundleResolvesImageAfterEffectiveMarkdownInspectorRuns() throws {
        let markdown = Data("![local](assets/pixel.png)\n".utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let assetURL = url.appendingPathComponent("assets/pixel.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleAssetPublishingMarkdownInspector(assetURL: assetURL, data: pixel, recorder: dispatches)
        ])

        let result = try PreviewInspectionResult.readTextBundle(at: url,
            contentTypeIdentifier: { _ in nil }, inspectionRegistry: registry)

        XCTAssertEqual(dispatches.calls.count, 1)
        XCTAssertEqual(dispatches.calls.first?.inspectorID, .markdown)
        XCTAssertEqual(dispatches.calls.first?.fileURL, url)
        let image = try XCTUnwrap(result.markdownDocument?.images.first)
        XCTAssertEqual(image.data, pixel,
                       "The asset becomes available only while the effective Markdown inspector is running")
    }

    func testTextBundleImagePolicyAllowsOnlyAssetsDescendantsOnBothPreviewRoutes() async throws {
        let allowed: [(String, String)] = [
            ("nested", "assets/pixel.png"),
            ("encoded-first", "%61ssets/pixel.png"),
            ("encoded-separator", "assets%2Fpixel.png"),
            ("direct", "assets/nested/pixel.png")
        ]
        let allowedURL = try makeImageBundle(allowed.map(\.1)) { root, pixel in
            try writePNG(pixel, at: root.appendingPathComponent("assets/pixel.png"))
            try writePNG(pixel, at: root.appendingPathComponent("assets/nested/pixel.png"))
        }
        defer { try? FileManager.default.removeItem(at: allowedURL) }
        try await assertBothPreviewRoutes(url: allowedURL,
            markdown: try Data(contentsOf: allowedURL.appendingPathComponent("text.md")),
            expectations: allowed.enumerated().map { index, item in
                .init(alt: "image-\(index)", destination: item.1, attached: true)
            })

        let denied: [(String, String)] = [
            ("root", "root.png"),
            ("sibling", "sibling/pixel.png"),
            ("other-prefix", "assets-other/pixel.png"),
            ("wrong-case", "Assets/pixel.png")
        ]
        let deniedURL = try makeImageBundle(denied.map(\.1)) { root, pixel in
            try writePNG(pixel, at: root.appendingPathComponent("root.png"))
            try writePNG(pixel, at: root.appendingPathComponent("sibling/pixel.png"))
            try writePNG(pixel, at: root.appendingPathComponent("assets-other/pixel.png"))
            try writePNG(pixel, at: root.appendingPathComponent("Assets/pixel.png"))
        }
        defer { try? FileManager.default.removeItem(at: deniedURL) }
        try await assertBothPreviewRoutes(url: deniedURL,
            markdown: try Data(contentsOf: deniedURL.appendingPathComponent("text.md")),
            expectations: denied.enumerated().map { index, item in
                .init(alt: "image-\(index)", destination: item.1, attached: false)
            })
    }

    func testTextBundleAssetsCaseLookupFollowsFixtureVolume() async throws {
        let reference = "![case-check](assets/pixel.png)\n"
        let markdown = Data(reference.utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let pixel = try onePixelPNG()
        try writePNG(pixel, at: url.appendingPathComponent("Assets/pixel.png"))
        let lowercaseLookup = url.appendingPathComponent("assets/pixel.png").path
        let lookupSucceeded = FileManager.default.fileExists(atPath: lowercaseLookup)
        try await assertBothPreviewRoutes(url: url, markdown: markdown,
            expectations: [.init(alt: "case-check", destination: "assets/pixel.png", attached: lookupSucceeded)])
    }

    func testTextBundleAssetsPathDecodingDepthAndComponentPolicyOnBothRoutes() async throws {
        let destinations = [
            "assets/%2E%2E/root.png", "assets//pixel.png", "assets/./pixel.png",
            "assets/a/b/c/d/e/f/pixel.png", "assets/a/b/c/d/e/f/g/pixel.png",
            "%2561ssets/pixel.png", "assets/%252E%252E/pixel.png"
        ]
        let url = try makeImageBundle(destinations) { root, pixel in
            try writePNG(pixel, at: root.appendingPathComponent("root.png"))
            try writePNG(pixel, at: root.appendingPathComponent("assets/a/b/c/d/e/f/pixel.png"))
            try writePNG(pixel, at: root.appendingPathComponent("assets/a/b/c/d/e/f/g/pixel.png"))
            try writePNG(pixel, at: root.appendingPathComponent("%61ssets/pixel.png"))
            try writePNG(pixel, at: root.appendingPathComponent("assets/%2E%2E/pixel.png"))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertBothPreviewRoutes(url: url,
            markdown: try Data(contentsOf: url.appendingPathComponent("text.md")),
            expectations: destinations.enumerated().map { index, destination in
                .init(alt: "image-\(index)", destination: destination, attached: index == 3 || index == 6)
            })
    }

    func testTextBundlePercentDecodedPunctuationRemainsLiteralFilenameOnBothRoutes() async throws {
        let names = [("backslash", "a\\b.png", "assets/a%5Cb.png"),
                     ("colon", "a:b.png", "assets/a%3Ab.png"),
                     ("question", "a?b.png", "assets/a%3Fb.png"),
                     ("hash", "a#b.png", "assets/a%23b.png")]
        let url = try makeImageBundle(names.map(\.2)) { root, pixel in
            let assetsFD = Darwin.open(root.appendingPathComponent("assets", isDirectory: true).path,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if assetsFD < 0 {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("assets", isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
            let directoryFD = assetsFD >= 0 ? assetsFD : Darwin.open(
                root.appendingPathComponent("assets", isDirectory: true).path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(directoryFD) }
            for (_, basename, _) in names {
                let descriptor = Darwin.openat(directoryFD, basename, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                defer { _ = Darwin.close(descriptor) }
                try pixel.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { throw POSIXError(.EIO) }
                    var written = 0
                    while written < bytes.count {
                        let count = Darwin.write(descriptor, baseAddress.advanced(by: written), bytes.count - written)
                        guard count > 0 else { throw POSIXError(.EIO) }
                        written += count
                    }
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertBothPreviewRoutes(url: url,
            markdown: try Data(contentsOf: url.appendingPathComponent("text.md")),
            expectations: names.enumerated().map { index, item in
                .init(alt: "image-\(index)", destination: item.2, attached: true)
            })
    }

    func testTextBundleRejectsSymlinkedAssetsAndAllowsHardLinksOnBothRoutes() async throws {
        let symlinkCases = [
            ("assets/pixel.png", "assets", "sibling"),
            ("assets/linked/pixel.png", "assets/linked", "../sibling"),
            ("assets/linked.png", "assets/linked.png", "../root.png")
        ]
        for (destination, linkRelativePath, target) in symlinkCases {
            let url = try makeImageBundle([destination]) { root, image in
                try writePNG(image, at: root.appendingPathComponent("sibling/pixel.png"))
                try writePNG(image, at: root.appendingPathComponent("root.png"))
                let linkURL = root.appendingPathComponent(linkRelativePath)
                try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                guard symlink(target, linkURL.path) == 0 else { throw POSIXError(.EIO) }
            }
            defer { try? FileManager.default.removeItem(at: url) }
            try await assertBothPreviewRoutes(url: url,
                markdown: try Data(contentsOf: url.appendingPathComponent("text.md")),
                expectations: [.init(alt: "image-0", destination: destination, attached: false)])
        }

        let missingURL = try makeImageBundle(["assets/pixel.png"]) { _, _ in }
        defer { try? FileManager.default.removeItem(at: missingURL) }
        try await assertBothPreviewRoutes(url: missingURL,
            markdown: try Data(contentsOf: missingURL.appendingPathComponent("text.md")),
            expectations: [.init(alt: "image-0", destination: "assets/pixel.png", attached: false)])

        let regularFileURL = try makeImageBundle(["assets/pixel.png"]) { root, image in
            try writePNG(image, at: root.appendingPathComponent("assets"))
        }
        defer { try? FileManager.default.removeItem(at: regularFileURL) }
        try await assertBothPreviewRoutes(url: regularFileURL,
            markdown: try Data(contentsOf: regularFileURL.appendingPathComponent("text.md")),
            expectations: [.init(alt: "image-0", destination: "assets/pixel.png", attached: false)])

        let hardLinkURL = try makeImageBundle(["assets/hard.png"]) { root, image in
            try writePNG(image, at: root.appendingPathComponent("root.png"))
            let assets = root.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            guard link(root.appendingPathComponent("root.png").path, assets.appendingPathComponent("hard.png").path) == 0
            else { throw POSIXError(.EIO) }
        }
        defer { try? FileManager.default.removeItem(at: hardLinkURL) }
        try await assertBothPreviewRoutes(url: hardLinkURL,
            markdown: try Data(contentsOf: hardLinkURL.appendingPathComponent("text.md")),
            expectations: [.init(alt: "image-0", destination: "assets/hard.png", attached: true)])
    }

    func testTextBundlePolicyDenialsConsumeTheEightAttemptBudgetOnBothRoutes() async throws {
        let destinations = (0..<8).map { _ in "root.png" } + ["assets/pixel.png"]
        let url = try makeImageBundle(destinations) { root, pixel in
            try writePNG(pixel, at: root.appendingPathComponent("root.png"))
            try writePNG(pixel, at: root.appendingPathComponent("assets/pixel.png"))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        try await assertBothPreviewRoutes(url: url,
            markdown: try Data(contentsOf: url.appendingPathComponent("text.md")),
            expectations: destinations.enumerated().map { index, destination in
                .init(alt: "image-\(index)", destination: destination, attached: false)
            })
    }

    func testTextBundleLateAssetPolicyHonorsExplicitMarkdownOverrideOnBothRoutes() async throws {
        let prefix = Data(repeating: 0x20, count: 65_482)
        let markdown = prefix + Data("\n![late-asset](assets/pixel.png) ![late-root](root.png)\n".utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let pixel = try onePixelPNG()
        try writePNG(pixel, at: url.appendingPathComponent("assets/pixel.png"))
        try writePNG(pixel, at: url.appendingPathComponent("root.png"))
        try await assertBothPreviewRoutes(url: url, markdown: markdown,
            expectations: [.init(alt: "late-asset", destination: "assets/pixel.png", attached: true),
                           .init(alt: "late-root", destination: "root.png", attached: false)],
            override: .markdown)
    }

    func testSynchronousTextBundleImageResolutionRevalidatesPackageIdentityAfterObserver() throws {
        for mutation in TextBundlePackageMutation.Kind.allCases {
            let fixture = try makeMutationFixture(mutation: mutation)
            defer { fixture.cleanUp() }
            let observerCount = TextBundleMetadataRecorder()
            let result = try PreviewInspectionResult.readTextBundle(at: fixture.packageURL,
                contentTypeIdentifier: { _ in nil }, observe: { event in
                    if case .assetResolutionStarted = event {
                        observerCount.increment()
                        fixture.mutation.perform()
                    }
                })
            XCTAssertEqual(observerCount.count, 1)
            XCTAssertTrue(fixture.mutation.errors.isEmpty)
            let image = try XCTUnwrap(result.markdownDocument?.images.first)
            XCTAssertEqual(image.data, nil, "Package mutation \(mutation) must not attach substituted bytes")
            XCTAssertNil(image.pixelWidth)
            XCTAssertNil(image.pixelHeight)
            XCTAssertEqual(result.originalBytes, fixture.markdown)
            XCTAssertEqual(image.destination, "assets/pixel.png")
            let rendered = try XCTUnwrap(result.markdownDocument?.renderedText) as NSString
            XCTAssertEqual(image.range, rendered.range(of: "mutation"))
        }
    }

    func testAsyncTextBundleImageResolutionRevalidatesPackageIdentityAfterObserver() async throws {
        for mutation in TextBundlePackageMutation.Kind.allCases {
            let fixture = try makeMutationFixture(mutation: mutation)
            defer { fixture.cleanUp() }
            let observerCount = TextBundleMetadataRecorder()
            let recorder = TextBundleAsyncRecorder()
            let result = try await PreviewInspectionResult.read(at: fixture.packageURL, timeLimit: .seconds(10),
                sleep: { try await Task.sleep(for: $0) }, contentTypeIdentifier: { _ in nil }, inspect: nil,
                textBundleObserve: { event in
                    recorder.record(event)
                    if case .assetResolutionStarted = event {
                        observerCount.increment()
                        fixture.mutation.perform()
                    }
                }, textBundleSnapshotObserver: { recorder.record($0) })
            XCTAssertEqual(observerCount.count, 1)
            XCTAssertEqual(recorder.events.filter { if case .assetResolutionStarted = $0 { true } else { false } }.count, 1)
            XCTAssertTrue(fixture.mutation.errors.isEmpty)
            let image = try XCTUnwrap(result.markdownDocument?.images.first)
            XCTAssertEqual(image.data, nil, "Package mutation \(mutation) must not attach substituted bytes")
            XCTAssertNil(image.pixelWidth)
            XCTAssertNil(image.pixelHeight)
            XCTAssertEqual(result.originalBytes, fixture.markdown)
            XCTAssertEqual(image.destination, "assets/pixel.png")
            let rendered = try XCTUnwrap(result.markdownDocument?.renderedText) as NSString
            XCTAssertEqual(image.range, rendered.range(of: "mutation"))
        }
    }

    func testStagedTextBundleFailsContinuationAfterSelectionWithoutReturningPayload() throws {
        let url = try makeTextBundle(markdown: Data(repeating: 0x61, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url) }
        var didSelect = false
        var failAfterSelection = false
        var sawMarker = false
        XCTAssertThrowsError(try TextBundleInspector.readMarkdownStaged(at: url, maximumBytes: 70_000,
            readOperation: { descriptor, buffer, count in
                if failAfterSelection && count > 0 { return .init(byteCount: -1, errorCode: EIO) }
                let readCount = Darwin.read(descriptor, buffer, count)
                return .init(byteCount: readCount, errorCode: readCount < 0 ? errno : nil)
            }, observe: { event in
                if case .selectionCommitted = event { sawMarker = true; failAfterSelection = true }
            }) { sample, _ in
                didSelect = true
                return sample.count
            }) { error in
                XCTAssertEqual(error as? TextBundleError, .readFailed)
            }
        XCTAssertTrue(didSelect)
        XCTAssertTrue(sawMarker)
    }

    func testSynchronousPreviewFreezesTextBundleRouteBeforeRetainedBinaryEvidence() throws {
        var markdown = Data("# Frozen route\n".utf8)
        markdown.append(Data(repeating: 0x61, count: 65_482 - markdown.count))
        markdown.append(0)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: dispatches),
            TextBundleRecordingInspector(id: .text, recorder: dispatches)
        ])
        var events: [TextBundleReadEvent] = []
        let result = try PreviewInspectionResult.readTextBundle(at: url, contentTypeIdentifier: { _ in nil },
            observe: { events.append($0) }, inspectionRegistry: registry)

        XCTAssertEqual(result.selectedInspectorID, .markdown)
        XCTAssertEqual(result.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(result.detectionReason, "fileExtension")
        XCTAssertEqual(result.sampleByteCount, 65_482)
        XCTAssertFalse(result.sampleIsComplete)
        XCTAssertEqual(result.originalBytes, markdown)
        XCTAssertTrue(result.analysis.isBinary)
        XCTAssertNil(result.markdownDocument)
        XCTAssertNil(result.sourceDocument)
        XCTAssertEqual(result.inspectionDiagnostics.map(\.code), [.unsupported])
        XCTAssertTrue(dispatches.calls.isEmpty, "A retained binary payload must be stopped by the staged text guard")
        guard let marker = events.firstIndex(where: {
            if case .selectionCommitted = $0 { return true }
            return false
        }) else { return XCTFail("Expected the route marker") }
        XCTAssertTrue(events.dropFirst(marker + 1).contains {
            if case .read(child: .markdown, offset: 65_482, _, _, _) = $0 { return true }
            return false
        })
    }

    func testThumbnailTextBundleUsesSharedStagedRouteWithoutAssetResolution() throws {
        let markdown = Data("![local](assets/pixel.png)\n\n# Thumbnail\n".utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = TextBundleAsyncRecorder()
        let completed = ThumbnailPackageCompletionRecorder()
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            ThumbnailCompletionRecordingMarkdownInspector(completion: completed, dispatches: dispatches)
        ])
        let result = try PreviewInspectionResult.readThumbnailTextBundle(at: url, maximumBytes: 262_144,
            markdownOptions: .init(frontMatter: .hide), contentTypeIdentifier: { _ in nil },
            observe: { recorder.record($0) }, onCompletedRead: { completed.record($0) },
            readOperation: nil, inspectionRegistry: registry)

        XCTAssertEqual(result.selectedInspectorID, .markdown)
        XCTAssertEqual(result.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(result.sampleByteCount, markdown.count)
        XCTAssertTrue(result.sampleIsComplete)
        XCTAssertEqual(result.originalBytes, markdown)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.inspectionSnapshotCounts, [1])
        XCTAssertEqual(dispatches.calls.count, 1)
        XCTAssertEqual(recorder.events.filter { if case .selectionCommitted = $0 { true } else { false } }.count, 1)
        XCTAssertFalse(recorder.events.contains { if case .assetResolutionStarted = $0 { true } else { false } })

        let reads = recorder.events.compactMap { event -> (TextBundleReadChild, Int, Int32)? in
            guard case .read(let child, let offset, _, _, _) = event,
                  let descriptorEvent = recorder.events.first(where: {
                      if case .readDescriptor(child, offset, _) = $0 { true } else { false }
                  }),
                  case .readDescriptor(_, _, let descriptor) = descriptorEvent else { return nil }
            return (child, offset, descriptor)
        }
        let markdownDescriptor = try XCTUnwrap(reads.first(where: { $0.0 == .markdown })?.2)
        XCTAssertTrue(reads.filter { $0.0 == .markdown }.allSatisfy { $0.2 == markdownDescriptor })
        XCTAssertTrue(recorder.events.contains {
            if case .descriptorClosed(.markdown, markdownDescriptor) = $0 { true } else { false }
        })

        let baseManifest = try Data(contentsOf: fixtureURL("Showcase/markdown-family/note.textbundle/info.json"))
        let fullBudgetManifest = baseManifest + Data(repeating: 0x20, count: 65_536 - baseManifest.count)
        for payload in [Data(), Data("nonempty".utf8)] {
            let zeroURL = try makeTextBundle(manifest: fullBudgetManifest, markdown: payload)
            defer { try? FileManager.default.removeItem(at: zeroURL) }
            let zero = try PreviewInspectionResult.readThumbnailTextBundle(at: zeroURL, maximumBytes: 262_144,
                markdownOptions: .init(frontMatter: .hide), contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(zero.sampleByteCount, 0)
            XCTAssertEqual(zero.sampleIsComplete, payload.isEmpty)
            XCTAssertEqual(zero.selectedInspectorID, .markdown)
            XCTAssertEqual(zero.formatDefinition?.id, FormatID(rawValue: "textbundle"))
            XCTAssertEqual(zero.originalBytes, payload)
        }

        var lateBinary = Data("# Textual route\n".utf8)
        lateBinary.append(Data(repeating: 0x61, count: 65_482 - lateBinary.count))
        lateBinary.append(0)
        let binaryURL = try makeTextBundle(manifest: baseManifest, markdown: lateBinary)
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let binaryDispatches = TextBundleDispatchRecorder()
        let binaryRegistry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: binaryDispatches),
            TextBundleRecordingInspector(id: .text, recorder: binaryDispatches)
        ])
        let binaryRecorder = TextBundleAsyncRecorder()
        let binary = try PreviewInspectionResult.readThumbnailTextBundle(at: binaryURL, maximumBytes: 262_144,
            markdownOptions: .init(frontMatter: .hide), contentTypeIdentifier: { _ in nil },
            observe: { binaryRecorder.record($0) }, onCompletedRead: { _ in },
            readOperation: nil, inspectionRegistry: binaryRegistry)
        XCTAssertEqual(binary.selectedInspectorID, .markdown)
        XCTAssertEqual(binary.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(binary.sampleByteCount, 65_482)
        XCTAssertFalse(binary.sampleIsComplete)
        XCTAssertEqual(binary.originalBytes, lateBinary)
        XCTAssertTrue(binary.analysis.isBinary)
        XCTAssertNil(binary.markdownDocument)
        XCTAssertNil(binary.sourceDocument)
        XCTAssertEqual(binary.inspectionDiagnostics.map(\.code), [.unsupported])
        XCTAssertTrue(binaryDispatches.calls.isEmpty)
        XCTAssertTrue(binary.inspectionDiagnostics.contains { $0.message == "Input is binary; showing raw content" })
    }

    func testSynchronousPreviewHandlesZeroAllowanceAndClippedBOM() throws {
        let baseManifest = try Data(contentsOf: fixtureURL("Showcase/markdown-family/note.textbundle/info.json"))
        let zeroAllowanceManifest = baseManifest + Data(repeating: 0x20, count: 65_536 - baseManifest.count)
        for markdown in [Data(), Data("nonempty".utf8)] {
            let url = try makeTextBundle(manifest: zeroAllowanceManifest, markdown: markdown)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try PreviewInspectionResult.readTextBundle(at: url,
                maximumBytes: 64, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.sampleByteCount, 0)
            XCTAssertEqual(result.sampleIsComplete, markdown.isEmpty)
            XCTAssertEqual(result.selectedInspectorID, .markdown)
            XCTAssertEqual(result.formatDefinition?.id, FormatID(rawValue: "textbundle"))
            XCTAssertEqual(result.originalBytes, markdown)
        }

        let twoByteAllowanceManifest = baseManifest + Data(repeating: 0x20, count: 65_534 - baseManifest.count)
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# Full BOM\n".utf8)
        let url = try makeTextBundle(manifest: twoByteAllowanceManifest, markdown: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try PreviewInspectionResult.readTextBundle(at: url, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(result.sampleByteCount, 2)
        XCTAssertFalse(result.sampleIsComplete)
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertEqual(Array(result.originalBytes.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(result.markdownDocument?.raw, "# Full BOM\n")

        let smallLimitURL = try makeTextBundle(markdown: Data("0123456789".utf8))
        defer { try? FileManager.default.removeItem(at: smallLimitURL) }
        let smallLimit = try PreviewInspectionResult.readTextBundle(at: smallLimitURL, maximumBytes: 0,
            contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(smallLimit.originalBytes, Data("0".utf8), "Preview keeps its one-byte minimum read")
        XCTAssertEqual(smallLimit.sampleByteCount, 1)
        XCTAssertFalse(smallLimit.sampleIsComplete)
    }

    func testSynchronousPreviewUsesSampleForPlistEvidenceAndAdvisoryUTI() throws {
        let binaryPlist = Data("bplist00sample".utf8)
        let magicURL = try makeTextBundle(markdown: binaryPlist)
        defer { try? FileManager.default.removeItem(at: magicURL) }
        let magic = try PreviewInspectionResult.readTextBundle(at: magicURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(magic.selectedInspectorID, .plist)
        XCTAssertEqual(magic.formatDefinition?.id, .plist)

        let advisoryURL = try makeTextBundle(markdown: Data("# ordinary Markdown\n".utf8))
        defer { try? FileManager.default.removeItem(at: advisoryURL) }
        let metadataCalls = TextBundleMetadataRecorder()
        let advisory = try PreviewInspectionResult.readTextBundle(at: advisoryURL,
            contentTypeIdentifier: { _ in metadataCalls.increment(); return "com.apple.binary-property-list" })
        XCTAssertEqual(metadataCalls.count, 1)
        XCTAssertEqual(advisory.systemUTI, "com.apple.binary-property-list")
        XCTAssertEqual(advisory.selectedInspectorID, .plist)

        let failedLookup = try PreviewInspectionResult.readTextBundle(at: advisoryURL,
            contentTypeIdentifier: { _ in throw CocoaError(.fileReadUnknown) })
        XCTAssertNil(failedLookup.systemUTI)
        XCTAssertEqual(failedLookup.selectedInspectorID, .markdown)

        var lateRoot = Data(repeating: 0x20, count: 65_482)
        lateRoot.append(Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8))
        let lateURL = try makeTextBundle(markdown: lateRoot)
        defer { try? FileManager.default.removeItem(at: lateURL) }
        let late = try PreviewInspectionResult.readTextBundle(at: lateURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(late.sampleByteCount, 65_482)
        XCTAssertEqual(late.selectedInspectorID, .markdown)
        XCTAssertEqual(late.formatDefinition?.id, FormatID(rawValue: "textbundle"))
    }

    func testTextBundleOverrideInspectsAutomaticThenEffectiveRouteWithURLOnlyAfterSelection() throws {
        let payload = Data(repeating: 0x61, count: 1_100_000)
        let url = try makeTextBundle(markdown: payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: dispatches),
            TextBundleRecordingInspector(id: .tar, recorder: dispatches)
        ])
        let result = try PreviewInspectionResult.readTextBundle(at: url, formatOverride: .tar,
            overrideDescription: "Catalog choice", contentTypeIdentifier: { _ in nil },
            inspectionRegistry: registry)

        XCTAssertEqual(result.selectedInspectorID, .tar)
        XCTAssertEqual(result.automaticFormatName, "TextBundle")
        XCTAssertEqual(result.formatName, "TAR archive")
        XCTAssertEqual(result.detectionReason, "userOverride")
        XCTAssertEqual(result.originalBytes, Data(payload.prefix(1_048_576)))
        XCTAssertEqual(dispatches.calls.map(\.inspectorID), [.markdown, .tar])
        XCTAssertNil(dispatches.calls[0].fileURL)
        XCTAssertEqual(dispatches.calls[1].fileURL, url)
        XCTAssertEqual(dispatches.calls[1].fileSize, payload.count)
        XCTAssertEqual(dispatches.calls[1].byteCount, 1_048_576,
                       "The package URL remains available to a truncated effective TAR inspector")
    }

    func testTextBundleTextOverridePreservesMarkdownLabelAndRawPresentation() throws {
        let bytes = Data("# Heading\nbody\n".utf8)
        let url = try makeTextBundle(markdown: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: dispatches),
            TextBundleRecordingInspector(id: .text, recorder: dispatches)
        ])
        let result = try PreviewInspectionResult.readTextBundle(at: url, formatOverride: .text,
            contentTypeIdentifier: { _ in nil }, inspectionRegistry: registry)

        XCTAssertEqual(dispatches.calls.map(\.inspectorID), [.markdown, .text])
        XCTAssertEqual(dispatches.calls[0].fileURL, nil)
        XCTAssertEqual(dispatches.calls[1].fileURL, url)
        XCTAssertEqual(result.automaticFormatName, "TextBundle")
        XCTAssertEqual(result.formatName, "Plain text")
        XCTAssertEqual(result.detectionReason, "userOverride")
        XCTAssertEqual(result.overrideDescription, "User override")
        XCTAssertEqual(result.analysis.text, "# Heading\nbody\n")
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertNil(result.markdownDocument)
        XCTAssertTrue(result.inspectionDiagnostics.isEmpty)
    }

    func testTextBundleSameRouteOverrideStillAttemptsBothDispatches() throws {
        let url = try makeTextBundle(markdown: Data("# Markdown\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: dispatches)
        ])
        _ = try PreviewInspectionResult.readTextBundle(at: url, formatOverride: .markdown,
            contentTypeIdentifier: { _ in nil }, inspectionRegistry: registry)
        XCTAssertEqual(dispatches.calls.map(\.inspectorID), [.markdown, .markdown])
        XCTAssertNil(dispatches.calls[0].fileURL)
        XCTAssertEqual(dispatches.calls[1].fileURL, url)
    }

    func testTextBundleFailedContinuationDoesNotDispatchAnInspector() throws {
        let url = try makeTextBundle(markdown: Data(repeating: 0x61, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let dispatches = TextBundleDispatchRecorder()
        let registry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: dispatches)
        ])
        var markerPublished = false
        XCTAssertThrowsError(try PreviewInspectionResult.readTextBundle(at: url,
            contentTypeIdentifier: { _ in nil }, readOperation: { descriptor, buffer, count in
                if markerPublished { return .init(byteCount: -1, errorCode: EIO) }
                let readCount = Darwin.read(descriptor, buffer, count)
                return .init(byteCount: readCount, errorCode: readCount < 0 ? errno : nil)
            }, observe: { event in
                if case .selectionCommitted = event { markerPublished = true }
            }, inspectionRegistry: registry)) { error in
                XCTAssertEqual(error as? TextBundleError, .readFailed)
            }
        XCTAssertTrue(markerPublished)
        XCTAssertTrue(dispatches.calls.isEmpty)
    }

    func testAsyncTextBundleUsesStagedBudgetAndContinuesOnSameDescriptor() async throws {
        let markdown = Data(repeating: 0x61, count: 70_000)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = TextBundleAsyncRecorder()

        let result = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(5),
            sleep: { try await Task.sleep(for: $0) }, contentTypeIdentifier: { _ in nil },
            textBundleReadOperation: { descriptor, buffer, count in
                recorder.recordDescriptor(descriptor)
                let byteCount = Darwin.read(descriptor, buffer, count)
                return .init(byteCount: byteCount, errorCode: byteCount < 0 ? errno : nil)
            }, textBundleObserve: { recorder.record($0) },
            textBundleSnapshotObserver: { recorder.record($0) })

        XCTAssertEqual(result.selectedInspectorID, .markdown)
        XCTAssertEqual(result.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(result.sampleByteCount, 65_482)
        XCTAssertEqual(result.originalBytes, markdown)
        let events = recorder.events
        guard let markerIndex = events.firstIndex(where: {
            if case .selectionCommitted = $0 { return true }
            return false
        }) else { return XCTFail("Expected one package selection marker") }
        XCTAssertEqual(events.filter { if case .selectionCommitted = $0 { true } else { false } }.count, 1)
        let preselection = events[..<markerIndex].compactMap { event -> (TextBundleReadChild, Int, Int)? in
            guard case .read(let child, let offset, let count, _, _) = event else { return nil }
            return (child, offset, count)
        }
        var requestedOffsets = Set<String>()
        for (child, offset, count) in preselection {
            for byteOffset in offset..<(offset + count) { requestedOffsets.insert("\(child):\(byteOffset)") }
        }
        XCTAssertLessThanOrEqual(requestedOffsets.count, 65_536)
        guard case .selectionCommitted(_, let committedOffsets) = events[markerIndex] else {
            return XCTFail("Expected package selection marker")
        }
        XCTAssertEqual(requestedOffsets.count, committedOffsets)
        let manifestReadCount = events[..<markerIndex].filter {
            if case .read(child: .manifest, _, _, _, _) = $0 { return true }
            return false
        }.count
        let markdownDescriptors = Array(recorder.descriptors.dropFirst(manifestReadCount))
        let continuationOffset = events.dropFirst(markerIndex + 1).compactMap { event -> Int? in
            guard case .read(child: .markdown, let offset, _, _, _) = event else { return nil }
            return offset
        }.first
        XCTAssertEqual(continuationOffset, 65_482)
        XCTAssertEqual(Set(markdownDescriptors).count, 1,
                       "The routing sample and continuation must use one Markdown descriptor")
        XCTAssertEqual(recorder.snapshots.first?.retainedMarkdown.count, 65_482)
        XCTAssertEqual(recorder.snapshots.last?.retainedMarkdown, markdown)
    }

    func testAsyncTextBundleTimeoutBeforeSelectionAndAtEmptySelectionThrows() async throws {
        let beforeURL = try makeTextBundle(markdown: Data("payload".utf8))
        defer { try? FileManager.default.removeItem(at: beforeURL) }
        let readEntered = TextBundleAsyncGate()
        let releaseRead = TextBundleBlockingGate()
        let beforeDescriptorClosed = TextBundleAsyncGate()
        let beforeTask = Task {
            try await PreviewInspectionResult.read(at: beforeURL, timeLimit: .seconds(1),
                sleep: { _ in _ = await readEntered.wait() }, contentTypeIdentifier: { _ in nil },
                textBundleReadOperation: { _, buffer, count in
                    readEntered.signal()
                    releaseRead.wait()
                    let byteCount = Darwin.read(-1, buffer, count)
                    return .init(byteCount: byteCount, errorCode: errno)
                }, textBundleObserve: { event in
                    if case .descriptorClosed = event { beforeDescriptorClosed.signal() }
                })
        }
        do { _ = try await beforeTask.value; XCTFail("Expected timeout before selection") }
        catch { XCTAssertTrue(error is InspectionWatchdog.TimeoutError) }
        releaseRead.signal()
        let beforeClosed = await beforeDescriptorClosed.wait()
        XCTAssertTrue(beforeClosed)
        XCTAssertFalse(readEntered.didTimeOut)
        XCTAssertFalse(releaseRead.didTimeOut)

        let manifest = try Data(contentsOf: fixtureURL("Showcase/markdown-family/note.textbundle/info.json"))
        let fullBudgetManifest = manifest + Data(repeating: 0x20, count: 65_536 - manifest.count)
        let emptyURL = try makeTextBundle(manifest: fullBudgetManifest, markdown: Data("late".utf8))
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let selected = TextBundleAsyncGate()
        let releaseEmptySelection = TextBundleBlockingGate()
        let emptyDescriptorClosed = TextBundleAsyncGate()
        let emptyTask = Task {
            try await PreviewInspectionResult.read(at: emptyURL, timeLimit: .seconds(1),
                sleep: { _ in _ = await selected.wait() }, contentTypeIdentifier: { _ in nil },
                textBundleObserve: { event in
                    if case .descriptorClosed = event { emptyDescriptorClosed.signal() }
                }, textBundleSnapshotObserver: { snapshot in
                    if snapshot.retainedMarkdown.isEmpty {
                        selected.signal()
                        releaseEmptySelection.wait()
                    }
                })
        }
        do { _ = try await emptyTask.value; XCTFail("Expected timeout with an empty selected payload") }
        catch { XCTAssertTrue(error is InspectionWatchdog.TimeoutError) }
        releaseEmptySelection.signal()
        let emptyClosed = await emptyDescriptorClosed.wait()
        XCTAssertTrue(emptyClosed)
        XCTAssertFalse(selected.didTimeOut)
        XCTAssertFalse(releaseEmptySelection.didTimeOut)
    }

    func testAsyncTextBundleRejectsAppendAfterTimerPublicationCutoff() async throws {
        let markdown = Data(repeating: 0x61, count: 70_000)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = TextBundleAsyncRecorder()
        let continuationEntered = TextBundleAsyncGate()
        let releaseContinuation = TextBundleBlockingGate()
        let timerClosed = TextBundleAsyncGate()
        let releaseTimer = TextBundleBlockingGate()
        let appendAttempted = TextBundleAsyncGate()
        let releaseWorker = TextBundleBlockingGate()
        let workerDescriptorClosed = TextBundleAsyncGate()
        let task = Task {
            try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(1),
                sleep: { _ in _ = await continuationEntered.wait() }, contentTypeIdentifier: { _ in nil },
                textBundleReadOperation: { descriptor, buffer, count in
                    let previous = recorder.incrementReadCount(for: descriptor)
                    if previous == 3 {
                        continuationEntered.signal()
                        releaseContinuation.wait()
                    }
                    let byteCount = Darwin.read(descriptor, buffer, count)
                    return .init(byteCount: byteCount, errorCode: byteCount < 0 ? errno : nil)
                }, textBundleObserve: { event in
                    recorder.record(event)
                    if case .descriptorClosed = event { workerDescriptorClosed.signal() }
                    if case .continuationAppended = event {
                        appendAttempted.signal()
                        releaseWorker.wait()
                    }
                }, textBundleSnapshotObserver: { recorder.record($0) },
                textBundleTimerClosed: {
                    timerClosed.signal()
                    releaseTimer.wait()
                })
        }
        let timerDidClose = await timerClosed.wait()
        XCTAssertTrue(timerDidClose)
        releaseContinuation.signal()
        let appendWasAttempted = await appendAttempted.wait()
        XCTAssertTrue(appendWasAttempted)
        releaseTimer.signal()
        let fallback = try await task.value
        XCTAssertEqual(fallback.selectedInspectorID, .markdown)
        XCTAssertEqual(fallback.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(fallback.originalBytes, Data(markdown.prefix(65_482)))
        XCTAssertEqual(fallback.inspectionDiagnostics.map(\.code), [.limitExceeded])
        XCTAssertNil(fallback.markdownDocument)
        XCTAssertEqual(recorder.events.filter { if case .dispatchAttempt = $0 { true } else { false } }.count, 0)
        XCTAssertEqual(recorder.events.filter { if case .assetResolutionStarted = $0 { true } else { false } }.count, 0)
        XCTAssertEqual(recorder.snapshots.count, 1, "The post-cutoff append must not publish a newer snapshot")
        releaseWorker.signal()
        let workerClosed = await workerDescriptorClosed.wait()
        XCTAssertTrue(workerClosed)
        XCTAssertFalse(continuationEntered.didTimeOut)
        XCTAssertFalse(releaseContinuation.didTimeOut)
        XCTAssertFalse(releaseTimer.didTimeOut)
        XCTAssertFalse(releaseWorker.didTimeOut)
    }

    func testAsyncTextBundleTimeoutAtAssetResolutionUsesCompleteFrozenSnapshot() async throws {
        let markdown = Data("![local](assets/pixel.png)\n\n# Heading\n".utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let assetsURL = url.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
        try pixel.write(to: assetsURL.appendingPathComponent("pixel.png"))
        let assetStarted = TextBundleAsyncGate()
        let releaseAssetResolution = TextBundleBlockingGate()
        let assetResolutionReleased = TextBundleAsyncGate()
        let recorder = TextBundleAsyncRecorder()

        let fallback = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(1),
            sleep: { _ in _ = await assetStarted.wait() }, contentTypeIdentifier: { _ in nil }, inspect: nil,
            textBundleObserve: { event in
                recorder.record(event)
                if case .assetResolutionStarted = event {
                    assetStarted.signal()
                    releaseAssetResolution.wait()
                    assetResolutionReleased.signal()
                }
            }, textBundleSnapshotObserver: { recorder.record($0) })

        XCTAssertEqual(fallback.originalBytes, markdown)
        XCTAssertEqual(fallback.sampleByteCount, markdown.count)
        XCTAssertEqual(fallback.inspectionDiagnostics.map(\.code), [.limitExceeded])
        XCTAssertNil(fallback.markdownDocument)
        XCTAssertEqual(recorder.events.filter { if case .dispatchAttempt = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(recorder.events.filter { if case .assetResolutionStarted = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(recorder.snapshots.last?.retainedMarkdown, markdown)
        releaseAssetResolution.signal()
        let assetResolutionDidRelease = await assetResolutionReleased.wait()
        XCTAssertTrue(assetResolutionDidRelease)
        XCTAssertFalse(assetStarted.didTimeOut)
        XCTAssertFalse(releaseAssetResolution.didTimeOut)
    }

    func testAsyncTextBundleParityForLateBinaryAndOverrides() async throws {
        var binary = Data("# Frozen route\n".utf8)
        binary.append(Data(repeating: 0x61, count: 65_482 - binary.count))
        binary.append(0)
        let binaryURL = try makeTextBundle(markdown: binary)
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let synchronousBinary = try PreviewInspectionResult.readTextBundle(at: binaryURL,
            contentTypeIdentifier: { _ in nil })
        let asynchronousBinary = try await readAsyncTextBundle(at: binaryURL)
        XCTAssertEqual(asynchronousBinary.selectedInspectorID, synchronousBinary.selectedInspectorID)
        XCTAssertEqual(asynchronousBinary.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(asynchronousBinary.formatName, "TextBundle")
        XCTAssertEqual(asynchronousBinary.formatName, synchronousBinary.formatName)
        XCTAssertEqual(asynchronousBinary.detectionReason, synchronousBinary.detectionReason)
        XCTAssertEqual(asynchronousBinary.originalBytes, synchronousBinary.originalBytes)
        XCTAssertEqual(asynchronousBinary.inspectionDiagnostics.map(\.code), synchronousBinary.inspectionDiagnostics.map(\.code))
        XCTAssertEqual(asynchronousBinary.inspectionDiagnostics.map(\.code), [.unsupported])
        XCTAssertNil(asynchronousBinary.markdownDocument)

        let textBytes = Data("# Heading\nbody\n".utf8)
        let textURL = try makeTextBundle(markdown: textBytes)
        defer { try? FileManager.default.removeItem(at: textURL) }
        let synchronousText = try PreviewInspectionResult.readTextBundle(at: textURL, formatOverride: .text,
            contentTypeIdentifier: { _ in nil })
        let textDispatches = TextBundleDispatchRecorder()
        let textRegistry = try FormatInspectorRegistry([
            TextBundleRecordingInspector(id: .markdown, recorder: textDispatches),
            TextBundleRecordingInspector(id: .text, recorder: textDispatches)
        ])
        let asynchronousText = try await readAsyncTextBundle(at: textURL, override: .text, registry: textRegistry)
        XCTAssertEqual(asynchronousText.formatName, "Plain text")
        XCTAssertEqual(asynchronousText.automaticFormatName, "TextBundle")
        XCTAssertEqual(asynchronousText.selectedInspectorID, synchronousText.selectedInspectorID)
        XCTAssertEqual(asynchronousText.overrideDescription, synchronousText.overrideDescription)
        XCTAssertEqual(asynchronousText.originalBytes, synchronousText.originalBytes)
        XCTAssertTrue(asynchronousText.inspectionDiagnostics.isEmpty)
        XCTAssertEqual(textDispatches.calls.map(\.inspectorID), [.markdown, .text])
        XCTAssertNil(textDispatches.calls[0].fileURL)
        XCTAssertEqual(textDispatches.calls[1].fileURL, textURL)
    }

    func testAsyncTextBundleResolvesLateImageAndAttemptsEqualOverrideRoutes() async throws {
        let prefix = Data(repeating: 0x20, count: 65_482)
        let markdown = prefix + Data("\n![local](assets/pixel.png)\n".utf8)
        let url = try makeTextBundle(markdown: markdown)
        defer { try? FileManager.default.removeItem(at: url) }
        let assetsURL = url.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
        let assetURL = assetsURL.appendingPathComponent("pixel.png")
        let syncRecorder = TextBundleDispatchRecorder()
        let asyncRecorder = TextBundleDispatchRecorder()
        let syncRegistry = try FormatInspectorRegistry([TextBundleAssetPublishingMarkdownInspector(
            assetURL: assetURL, data: pixel, recorder: syncRecorder)])
        let asyncRegistry = try FormatInspectorRegistry([TextBundleAssetPublishingMarkdownInspector(
            assetURL: assetURL, data: pixel, recorder: asyncRecorder)])
        let synchronous = try PreviewInspectionResult.readTextBundle(at: url, formatOverride: .markdown,
            contentTypeIdentifier: { _ in nil }, inspectionRegistry: syncRegistry)
        try FileManager.default.removeItem(at: assetURL)
        let events = TextBundleAsyncRecorder()
        let asynchronous = try await readAsyncTextBundle(at: url, override: .markdown,
            registry: asyncRegistry, recorder: events)

        XCTAssertEqual(asynchronous.selectedInspectorID, synchronous.selectedInspectorID)
        XCTAssertEqual(asynchronous.formatName, synchronous.formatName)
        XCTAssertEqual(asynchronous.originalBytes, synchronous.originalBytes)
        XCTAssertEqual(asynchronous.inspectionDiagnostics.map(\.code), synchronous.inspectionDiagnostics.map(\.code))
        XCTAssertEqual(asyncRecorder.calls.map(\.inspectorID), [.markdown, .markdown])
        XCTAssertNil(asyncRecorder.calls[0].fileURL)
        XCTAssertEqual(asyncRecorder.calls[1].fileURL, url)
        let image = try XCTUnwrap(asynchronous.markdownDocument?.images.first)
        XCTAssertEqual(image.data, pixel)
        XCTAssertEqual(events.events.filter { if case .dispatchAttempt = $0 { true } else { false } }.count, 2)
        XCTAssertEqual(events.events.filter { if case .assetResolutionStarted = $0 { true } else { false } }.count, 1)
    }

    func testAsyncTextBundleCallerCancellationClosesOpenDescriptors() async throws {
        let url = try makeTextBundle(markdown: Data(repeating: 0x61, count: 70_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let entered = TextBundleAsyncGate()
        let release = TextBundleBlockingGate()
        let descriptorClosed = TextBundleAsyncGate()
        let recorder = TextBundleAsyncRecorder()
        let task = Task {
            try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(60),
                sleep: { try await Task.sleep(for: $0) }, contentTypeIdentifier: { _ in nil },
                textBundleReadOperation: { descriptor, buffer, count in
                    recorder.recordDescriptor(descriptor)
                    entered.signal()
                    release.wait()
                    let byteCount = Darwin.read(descriptor, buffer, count)
                    return .init(byteCount: byteCount, errorCode: byteCount < 0 ? errno : nil)
                }, textBundleObserve: { event in
                    recorder.record(event)
                    if case .descriptorClosed = event { descriptorClosed.signal() }
                })
        }
        let readDidEnter = await entered.wait()
        XCTAssertTrue(readDidEnter)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        release.signal()
        let descriptorDidClose = await descriptorClosed.wait()
        XCTAssertTrue(descriptorDidClose)
        XCTAssertFalse(release.didTimeOut)
        let closedDescriptors = recorder.events.compactMap { event -> Int32? in
            guard case .descriptorClosed(_, let descriptor) = event else { return nil }
            return descriptor
        }
        XCTAssertTrue(closedDescriptors.contains(recorder.descriptors[0]))
        XCTAssertEqual(fcntl(recorder.descriptors[0], F_GETFD), -1)
    }

    func testNFRP02RealAsyncTextBundle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_NFRP02_TEXTBUNDLE_REQUIRED"] == "1"
        let configuredPath = environment["INSPECTORCORE_NFRP02_TEXTBUNDLE_PATH"]
        guard required || configuredPath != nil else {
            throw XCTSkip("Set INSPECTORCORE_NFRP02_TEXTBUNDLE_REQUIRED=1 and INSPECTORCORE_NFRP02_TEXTBUNDLE_PATH to run the genuine async TextBundle check")
        }
        guard let configuredPath, !configuredPath.isEmpty else {
            XCTFail("Required TextBundle input path is missing")
            return
        }
        let packageURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        let manifestURL = packageURL.appendingPathComponent("info.json")
        let markdownURL = packageURL.appendingPathComponent("text.md")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let markdownBefore = try Data(contentsOf: markdownURL)
        XCTAssertEqual(gitBlobSHA1(manifestBefore), "f4a55653fcdec7ba57b95ad3bf54ec207567332e")
        XCTAssertEqual(gitBlobSHA1(markdownBefore), "63b2651ad5fa7aa6372cba6146c6be003c5f884a")

        let publicResult = try await PreviewInspectionResult.read(at: packageURL, timeLimit: .seconds(5))
        assertRealTextBundleResult(publicResult, source: markdownBefore)
        let recorder = TextBundleAsyncRecorder()
        let systemLookup: @Sendable (URL) throws -> String? = { fileURL in
            try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        }
        let instrumentedResult = try await PreviewInspectionResult.read(at: packageURL, timeLimit: .seconds(5),
            sleep: { try await Task.sleep(for: $0) }, contentTypeIdentifier: systemLookup,
            textBundleReadOperation: { descriptor, buffer, count in
                recorder.recordDescriptor(descriptor)
                let byteCount = Darwin.read(descriptor, buffer, count)
                return .init(byteCount: byteCount, errorCode: byteCount < 0 ? errno : nil)
            }, textBundleObserve: { recorder.record($0) },
            textBundleSnapshotObserver: { recorder.record($0) })
        assertRealTextBundleResult(instrumentedResult, source: markdownBefore)
        XCTAssertEqual(instrumentedResult.systemUTI, publicResult.systemUTI)
        let events = recorder.events
        guard let markerIndex = events.firstIndex(where: {
            if case .selectionCommitted = $0 { return true }
            return false
        }) else { return XCTFail("Expected one async package selection marker") }
        guard case .selectionCommitted(let routingByteCount, let distinctOffsets) = events[markerIndex] else {
            return XCTFail("Expected async package selection marker")
        }
        XCTAssertEqual(routingByteCount, 65_536)
        XCTAssertEqual(distinctOffsets, 65_536)
        XCTAssertEqual(events.filter { if case .selectionCommitted = $0 { true } else { false } }.count, 1)
        let continuation = events.dropFirst(markerIndex + 1).compactMap { event -> Int? in
            guard case .read(child: .markdown, let offset, _, _, _) = event else { return nil }
            return offset
        }
        XCTAssertEqual(continuation.first, 65_482)
        XCTAssertEqual(recorder.snapshots.last?.retainedMarkdown, markdownBefore)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: markdownURL), markdownBefore)
    }

    func testNFRP02RealTextBundle() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["INSPECTORCORE_NFRP02_TEXTBUNDLE_REQUIRED"] == "1"
        let configuredPath = environment["INSPECTORCORE_NFRP02_TEXTBUNDLE_PATH"]
        guard required || configuredPath != nil else {
            throw XCTSkip("Set INSPECTORCORE_NFRP02_TEXTBUNDLE_REQUIRED=1 and INSPECTORCORE_NFRP02_TEXTBUNDLE_PATH to run the genuine TextBundle check")
        }
        guard let configuredPath, !configuredPath.isEmpty else {
            XCTFail("Required TextBundle input path is missing")
            return
        }
        let packageURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        let manifestURL = packageURL.appendingPathComponent("info.json")
        let markdownURL = packageURL.appendingPathComponent("text.md")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let markdownBefore = try Data(contentsOf: markdownURL)

        XCTAssertEqual(manifestBefore.count, 54)
        XCTAssertEqual(markdownBefore.count, 86_923)
        XCTAssertEqual(gitBlobSHA1(manifestBefore), "f4a55653fcdec7ba57b95ad3bf54ec207567332e")
        XCTAssertEqual(gitBlobSHA1(markdownBefore), "63b2651ad5fa7aa6372cba6146c6be003c5f884a")

        let systemLookup: @Sendable (URL) throws -> String? = { fileURL in
            try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        }
        let publicResult = try PreviewInspectionResult.read(at: packageURL)
        assertRealTextBundleResult(publicResult, source: markdownBefore)

        var events: [TextBundleReadEvent] = []
        let instrumentedResult = try PreviewInspectionResult.readTextBundle(at: packageURL,
            contentTypeIdentifier: systemLookup, observe: { events.append($0) })
        assertRealTextBundleResult(instrumentedResult, source: markdownBefore)
        XCTAssertEqual(instrumentedResult.systemUTI, publicResult.systemUTI)
        guard let markerIndex = events.firstIndex(where: {
            if case .selectionCommitted = $0 { return true }
            return false
        }) else { return XCTFail("Expected one package routing marker") }
        let marker = events[markerIndex]
        guard case .selectionCommitted(let routingByteCount, let distinctOffsets) = marker else {
            return XCTFail("Expected a package routing marker")
        }
        XCTAssertEqual(routingByteCount, 65_536)
        XCTAssertEqual(distinctOffsets, 65_536)
        let laterReads = events.dropFirst(markerIndex + 1).compactMap { event -> Int? in
            guard case .read(child: .markdown, let offset, _, _, _) = event else { return nil }
            return offset
        }
        XCTAssertEqual(laterReads.first, 65_482)
        XCTAssertEqual(laterReads.count, 1)

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: markdownURL), markdownBefore)
        print("NFR-P02 real TextBundle advisory UTI: \(instrumentedResult.systemUTI ?? "nil")")
    }

    func testTextBundleUsesSharedMarkdownInspectionAndPreservesTextBytes() throws {
        let url = try fixtureURL("Showcase/markdown-family/note.textbundle")
        let textURL = url.appendingPathComponent("text.md")
        let textBytes = try Data(contentsOf: textURL)
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })

        XCTAssertEqual(result.formatDefinition?.id, FormatID(rawValue: "textbundle"))
        XCTAssertEqual(result.markdownDocument?.raw, String(decoding: textBytes, as: UTF8.self))
        XCTAssertEqual(result.originalBytes, textBytes)
        XCTAssertFalse(result.markdownDocument?.headings.isEmpty ?? true)
        XCTAssertFalse(result.inspectionDiagnostics.contains { $0.code == .parseError })
    }

    func testUnsupportedOrMalformedTextBundleHasNoMarkdownPayload() throws {
        let malformedURL = try fixtureURL("Cases/fileformats/textbundle/malformed.textbundle")
        XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: malformedURL, maximumBytes: 1_048_576))

        let unsupportedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-\(UUID().uuidString).textbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: unsupportedURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unsupportedURL) }
        try Data(#"{"version":2,"type":"text/html"}"#.utf8)
            .write(to: unsupportedURL.appendingPathComponent("info.json"))
        try Data("<p>Not Markdown</p>".utf8).write(to: unsupportedURL.appendingPathComponent("text.md"))
        XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: unsupportedURL, maximumBytes: 1_048_576))

        try Data(#"{"version":2,"type":7}"#.utf8)
            .write(to: unsupportedURL.appendingPathComponent("info.json"), options: .atomic)
        XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: unsupportedURL, maximumBytes: 1_048_576))
    }

    func testTextBundleRejectsSymlinkedTextAndHonorsByteLimit() throws {
        let original = try fixtureURL("Showcase/markdown-family/note.textbundle")
        let symlinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-\(UUID().uuidString).textbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: symlinkURL) }
        try FileManager.default.copyItem(at: original.appendingPathComponent("info.json"),
                                         to: symlinkURL.appendingPathComponent("info.json"))
        try FileManager.default.createSymbolicLink(at: symlinkURL.appendingPathComponent("text.md"),
                                                   withDestinationURL: original.appendingPathComponent("text.md"))
        XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: symlinkURL, maximumBytes: 1_048_576))

        let rootSymlinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-\(UUID().uuidString).textbundle", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootSymlinkURL, withDestinationURL: original)
        defer { try? FileManager.default.removeItem(at: rootSymlinkURL) }
        XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: rootSymlinkURL, maximumBytes: 1_048_576))

        let limited = try TextBundleInspector.readMarkdown(at: original, maximumBytes: 8)
        XCTAssertEqual(limited.data.count, 8)
        XCTAssertGreaterThan(limited.fileSize, limited.data.count)
    }

    private func makeTextBundle(manifest: Data? = nil, markdown: Data?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glimt-\(UUID().uuidString).textbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let defaultManifest = Data(#"{"version": 2, "type": "net.daringfireball.markdown"}"#.utf8) + Data([0x0A])
        try (manifest ?? defaultManifest).write(to: url.appendingPathComponent("info.json"))
        if let markdown { try markdown.write(to: url.appendingPathComponent("text.md")) }
        return url
    }

    private func makeImageBundle(_ destinations: [String],
                                 configure: (URL, Data) throws -> Void = { _, _ in }) throws -> URL {
        let markdown = Data(destinations.enumerated().map { index, destination in
            "![image-\(index)](\(destination))"
        }.joined(separator: "\n").appending("\n").utf8)
        let url = try makeTextBundle(markdown: markdown)
        do {
            try configure(url, onePixelPNG())
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func onePixelPNG() throws -> Data {
        try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/Aq8AAAAASUVORK5CYII="))
    }

    private func writePNG(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func assertBothPreviewRoutes(url: URL, markdown: Data,
                                         expectations: [TextBundleImageExpectation],
                                         override: PreviewInspectionResult.FormatOverride? = nil) async throws {
        let synchronous = try PreviewInspectionResult.read(at: url, formatOverride: override,
            contentTypeIdentifier: { _ in nil })
        assertImageExpectations(synchronous, markdown: markdown, expectations: expectations)

        let asynchronous = try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(10),
            formatOverride: override, contentTypeIdentifier: { _ in nil })
        assertImageExpectations(asynchronous, markdown: markdown, expectations: expectations)
    }

    private func assertImageExpectations(_ result: PreviewInspectionResult, markdown: Data,
                                        expectations: [TextBundleImageExpectation],
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.originalBytes, markdown, file: file, line: line)
        guard let document = result.markdownDocument else {
            XCTFail("Expected the shared Markdown document", file: file, line: line)
            return
        }
        XCTAssertEqual(document.raw, String(decoding: markdown, as: UTF8.self), file: file, line: line)
        XCTAssertEqual(document.images.count, expectations.count, file: file, line: line)
        guard let renderedText = document.renderedText else {
            XCTFail("Expected rendered Markdown text", file: file, line: line)
            return
        }
        let rendered = renderedText as NSString
        var searchLocation = 0
        for (index, expectation) in expectations.enumerated() {
            guard index < document.images.count else { continue }
            let image = document.images[index]
            XCTAssertEqual(image.destination, expectation.destination, file: file, line: line)
            let range = rendered.range(of: expectation.alt,
                options: [], range: NSRange(location: searchLocation, length: rendered.length - searchLocation))
            XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
            guard range.location != NSNotFound else { continue }
            XCTAssertEqual(image.range, range, "Alt range must use rendered UTF-16 offsets", file: file, line: line)
            searchLocation = NSMaxRange(range)
            if expectation.attached {
                XCTAssertEqual(image.data, try? onePixelPNG(), file: file, line: line)
                XCTAssertEqual(image.pixelWidth, 1, file: file, line: line)
                XCTAssertEqual(image.pixelHeight, 1, file: file, line: line)
            } else {
                XCTAssertNil(image.data, file: file, line: line)
                XCTAssertNil(image.pixelWidth, file: file, line: line)
                XCTAssertNil(image.pixelHeight, file: file, line: line)
                XCTAssertTrue(rendered.substring(with: image.range).contains(expectation.alt), file: file, line: line)
            }
        }
    }

    private func makeMutationFixture(mutation: TextBundlePackageMutation.Kind) throws -> TextBundleMutationFixture {
        let markdown = Data("![mutation](assets/pixel.png)\n".utf8)
        let packageURL = try makeTextBundle(markdown: markdown)
        let sibling = packageURL.deletingLastPathComponent()
        let asideURL = sibling.appendingPathComponent("Glimt-original-\(UUID().uuidString).textbundle", isDirectory: true)
        let replacementURL = try makeTextBundle(markdown: markdown)
        let pixel = try onePixelPNG()
        try writePNG(pixel, at: packageURL.appendingPathComponent("assets/pixel.png"))
        try writePNG(pixel, at: replacementURL.appendingPathComponent("assets/pixel.png"))
        return TextBundleMutationFixture(packageURL: packageURL, asideURL: asideURL,
            replacementURL: replacementURL, markdown: markdown, mutation: mutation)
    }

    private func readAsyncTextBundle(at url: URL, override: PreviewInspectionResult.FormatOverride? = nil,
                                     registry: FormatInspectorRegistry = .builtIn,
                                     recorder: TextBundleAsyncRecorder = TextBundleAsyncRecorder()) async throws
    -> PreviewInspectionResult {
        try await PreviewInspectionResult.read(at: url, timeLimit: .seconds(5),
            sleep: { try await Task.sleep(for: $0) }, formatOverride: override,
            contentTypeIdentifier: { _ in nil }, inspectionRegistry: registry,
            textBundleObserve: { recorder.record($0) },
            textBundleSnapshotObserver: { recorder.record($0) })
    }

    private func assertRealTextBundleResult(_ result: PreviewInspectionResult, source: Data,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.selectedInspectorID, .markdown, file: file, line: line)
        XCTAssertEqual(result.formatDefinition?.id, FormatID(rawValue: "textbundle"), file: file, line: line)
        XCTAssertEqual(result.sampleByteCount, 65_482, file: file, line: line)
        XCTAssertFalse(result.sampleIsComplete, file: file, line: line)
        XCTAssertEqual(result.originalBytes, source, file: file, line: line)
        XCTAssertTrue(result.analysis.text.contains("Data Model & API Contract"), file: file, line: line)
        XCTAssertTrue(result.markdownDocument?.headings.contains(where: { $0.title == "Data Model & API Contract" }) ?? false,
                      file: file, line: line)
    }

    private func gitBlobSHA1(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }
}

private struct TextBundleImageExpectation {
    let alt: String
    let destination: String
    let attached: Bool
}

private final class TextBundleMutationFixture: @unchecked Sendable {
    let packageURL: URL
    let asideURL: URL
    let replacementURL: URL
    let markdown: Data
    let mutation: TextBundlePackageMutation

    init(packageURL: URL, asideURL: URL, replacementURL: URL, markdown: Data,
         mutation kind: TextBundlePackageMutation.Kind) {
        self.packageURL = packageURL
        self.asideURL = asideURL
        self.replacementURL = replacementURL
        self.markdown = markdown
        self.mutation = TextBundlePackageMutation(kind: kind, packageURL: packageURL,
            asideURL: asideURL, replacementURL: replacementURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: packageURL)
        try? FileManager.default.removeItem(at: asideURL)
        try? FileManager.default.removeItem(at: replacementURL)
    }
}

private final class TextBundlePackageMutation: @unchecked Sendable {
    enum Kind: CaseIterable, CustomStringConvertible {
        case replacementDirectory
        case vacant
        case symlink

        var description: String {
            switch self {
            case .replacementDirectory: return "replacement directory"
            case .vacant: return "vacant original path"
            case .symlink: return "replacement symlink"
            }
        }
    }

    private let kind: Kind
    private let packageURL: URL
    private let asideURL: URL
    private let replacementURL: URL
    private let lock = NSLock()
    private var storedErrors: [String] = []

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedErrors
    }

    init(kind: Kind, packageURL: URL, asideURL: URL, replacementURL: URL) {
        self.kind = kind
        self.packageURL = packageURL
        self.asideURL = asideURL
        self.replacementURL = replacementURL
    }

    func perform() {
        do {
            try FileManager.default.moveItem(at: packageURL, to: asideURL)
            switch kind {
            case .replacementDirectory:
                try FileManager.default.moveItem(at: replacementURL, to: packageURL)
            case .vacant:
                break
            case .symlink:
                try FileManager.default.createSymbolicLink(at: packageURL, withDestinationURL: replacementURL)
            }
        } catch {
            lock.lock()
            storedErrors.append(String(describing: error))
            lock.unlock()
        }
    }
}

private final class TextBundleDispatchRecorder: @unchecked Sendable {
    struct Call {
        let inspectorID: InspectorID
        let fileURL: URL?
        let fileSize: Int
        let byteCount: Int
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return storedCalls }
    func append(_ call: Call) { lock.lock(); storedCalls.append(call); lock.unlock() }
}

private final class TextBundleMetadataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return storedCount }
    func increment() { lock.lock(); storedCount += 1; lock.unlock() }
}

/// One-shot signal that can be awaited by async test control and signaled by synchronous hooks.
private final class TextBundleAsyncGate: Sendable {
    private struct State: Sendable {
        var signaled = false
        var completed = false
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard !state.completed else { return nil }
            state.signaled = true
            state.completed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: true)
    }

    var didTimeOut: Bool { state.withLock { $0.completed && !$0.signaled } }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let completedResult = state.withLock { state -> Bool? in
                guard !state.completed else { return state.signaled }
                state.waiter = continuation
                return nil
            }
            if let completedResult {
                continuation.resume(returning: completedResult)
            } else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [self] in
                    timeout()
                }
            }
        }
    }

    private func timeout() {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard !state.completed else { return nil }
            state.completed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: false)
    }
}

/// Synchronous barrier for callbacks that must hold the watchdog's detached worker in place.
private final class TextBundleBlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let timeoutCount = Mutex(0)

    var didTimeOut: Bool { timeoutCount.withLock { $0 > 0 } }

    @discardableResult
    func wait() -> Bool {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            timeoutCount.withLock { $0 += 1 }
            return false
        }
        return true
    }

    func signal() { semaphore.signal() }
}

private final class TextBundleAsyncRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [TextBundleReadEvent] = []
    private var storedSnapshots: [TextBundlePreviewSnapshot] = []
    private var storedDescriptors: [Int32] = []
    private var readCounts: [Int32: Int] = [:]

    var events: [TextBundleReadEvent] { lock.lock(); defer { lock.unlock() }; return storedEvents }
    var snapshots: [TextBundlePreviewSnapshot] { lock.lock(); defer { lock.unlock() }; return storedSnapshots }
    var descriptors: [Int32] { lock.lock(); defer { lock.unlock() }; return storedDescriptors }

    func record(_ event: TextBundleReadEvent) { lock.lock(); storedEvents.append(event); lock.unlock() }
    func record(_ snapshot: TextBundlePreviewSnapshot) { lock.lock(); storedSnapshots.append(snapshot); lock.unlock() }
    func recordDescriptor(_ descriptor: Int32) {
        lock.lock()
        storedDescriptors.append(descriptor)
        lock.unlock()
    }
    func incrementReadCount(for descriptor: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let count = (readCounts[descriptor] ?? 0) + 1
        readCounts[descriptor] = count
        return count
    }
}

private final class ThumbnailPackageCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ThumbnailTextBundleReadSnapshot] = []
    private var inspectionsAtDispatch: [Int] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return snapshots.count }
    var inspectionSnapshotCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return inspectionsAtDispatch
    }

    func record(_ snapshot: ThumbnailTextBundleReadSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }

    func recordInspection() {
        lock.lock()
        inspectionsAtDispatch.append(snapshots.count)
        lock.unlock()
    }
}

private struct ThumbnailCompletionRecordingMarkdownInspector: FormatInspector {
    let completion: ThumbnailPackageCompletionRecorder
    let dispatches: TextBundleDispatchRecorder
    var id: InspectorID { .markdown }

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        completion.recordInspection()
        dispatches.append(.init(inspectorID: id, fileURL: request.fileURL,
            fileSize: request.fileSize, byteCount: request.bytes.count))
        return .markdown(try MarkdownInspector.inspect(analysis: request.analysis,
            options: request.markdownOptions))
    }
}

private struct TextBundleRecordingInspector: FormatInspector {
    let id: InspectorID
    let recorder: TextBundleDispatchRecorder

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        recorder.append(.init(inspectorID: id, fileURL: request.fileURL, fileSize: request.fileSize,
                              byteCount: request.bytes.count))
        return .text
    }
}

private struct TextBundleAssetPublishingMarkdownInspector: FormatInspector {
    let assetURL: URL
    let data: Data
    let recorder: TextBundleDispatchRecorder

    var id: InspectorID { .markdown }

    func inspect(_ request: InspectionRequest) throws -> InspectionOutcome {
        recorder.append(.init(inspectorID: id, fileURL: request.fileURL, fileSize: request.fileSize,
                              byteCount: request.bytes.count))
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: assetURL)
        return .markdown(try MarkdownInspector.inspect(analysis: request.analysis,
                                                       options: request.markdownOptions))
    }
}
