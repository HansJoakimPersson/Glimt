import AppKit
import CryptoKit
import CoreText
import Darwin
import Foundation
import InspectorCore
import QuickLookThumbnailing
import XCTest
import UniformTypeIdentifiers

final class ThumbnailRendererTests: XCTestCase {
    func testThumbnailSelectionPrecedesContinuation() throws {
        let url = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("cutoff.txt")
        let bytes = Data(repeating: 0x61, count: 65_537)
        try bytes.write(to: url)
        let events = ThumbnailReadEventRecorder()
        let preparation = try ThumbnailPreparation.read(at: url, contentTypeIdentifier: { _ in nil },
            observe: { events.append($0) })
        let values = events.values
        guard let selectionIndex = values.firstIndex(where: {
            if case .selectionCommitted = $0 { return true }
            return false
        }) else { return XCTFail("Selection event missing") }
        XCTAssertTrue(values[..<selectionIndex].contains(where: {
            if case .read = $0 { return true }
            return false
        }))
        XCTAssertTrue(values[(selectionIndex + 1)...].contains(where: {
            if case .continuationAppended = $0 { return true }
            return false
        }))
        XCTAssertEqual(preparation.sampleByteCount, 65_536)
        XCTAssertEqual(preparation.readByteCount, 65_537)
        XCTAssertEqual(preparation.selectedInspectorID, .text)
    }

    func testNFRP02RealInputs() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["TEST_RUNNER_NFR_P02_REQUIRE_REAL_INPUT"] == "1"
        let repositoryRoot = try fixtureURL("README.md").deletingLastPathComponent().deletingLastPathComponent()
        let inputDirectory = environment["TEST_RUNNER_NFR_P02_REAL_INPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repositoryRoot.appendingPathComponent("docs/plans/.runs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: inputDirectory.path) else {
            if required || environment["TEST_RUNNER_NFR_P02_REAL_INPUT_DIR"] != nil {
                XCTFail("Required NFR-P02 real-input directory is missing")
            } else {
                throw XCTSkip("NFR-P02 real inputs are opt-in")
            }
            return
        }
        let fingerprints = [
            ("glib-mkenums", "6b144d7044beeddcde563f4588cd7e3aed74f4dbc9198af1223b2993de9a9ea5"),
            ("fr005-magic.plist", "3c1bc045cd817974ee631bd4a9da86d4113b8d0d90016248f9b2005f033f30ea"),
            ("words", "be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9")
        ]
        let urls = try fingerprints.map { name, expectedHash -> URL in
            let url = inputDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("Required NFR-P02 input is missing: \(name)")
                return url
            }
            XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), expectedHash, name)
            return url
        }
        func assertRouting(_ recorder: ThumbnailReadEventRecorder, sample: Int, complete: Bool) {
            let selection = recorder.values.compactMap { event -> (Int, Int)? in
                guard case .selectionCommitted(let count, let distinct) = event else { return nil }
                return (count, distinct)
            }
            XCTAssertEqual(selection.count, 1)
            XCTAssertEqual(selection.first?.0, sample)
            XCTAssertEqual(selection.first?.1, sample)
            XCTAssertLessThanOrEqual(sample, 65_536)
            XCTAssertEqual(complete, sample < 65_536)
        }

        let observedPython = ThumbnailInspectionRecorder()
        let pythonEvents = ThumbnailReadEventRecorder()
        let python = try ThumbnailPreparation.read(at: urls[0], contentTypeIdentifier: { _ in nil },
            observe: { pythonEvents.append($0) }, inspectionObserver: { observedPython.store($0) })
        assertRouting(pythonEvents, sample: 32_278, complete: true)
        let pythonResult = try XCTUnwrap(observedPython.value)
        XCTAssertEqual(python.selectedInspectorID, .source)
        XCTAssertEqual(python.sourceLanguage, .python)
        XCTAssertEqual(python.sampleByteCount, 32_278)
        XCTAssertTrue(python.sampleIsComplete)
        XCTAssertEqual(python.readByteCount, 32_278)
        XCTAssertEqual(pythonResult.originalBytes, try Data(contentsOf: urls[0]))

        let plistURL = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("fr005-magic")
        try Data(contentsOf: urls[1]).write(to: plistURL)
        let observedPlist = ThumbnailInspectionRecorder()
        let plistEvents = ThumbnailReadEventRecorder()
        let plist = try ThumbnailPreparation.read(at: plistURL, contentTypeIdentifier: { _ in nil },
            observe: { plistEvents.append($0) }, inspectionObserver: { observedPlist.store($0) })
        assertRouting(plistEvents, sample: 3_333, complete: true)
        let plistResult = try XCTUnwrap(observedPlist.value)
        XCTAssertEqual(plist.selectedInspectorID, .plist)
        XCTAssertEqual(plist.formatID, .plist)
        XCTAssertEqual(plist.sampleByteCount, 3_333)
        XCTAssertTrue(plist.sampleIsComplete)
        XCTAssertNotNil(plistResult.plistInspection?.content)
        XCTAssertEqual(plistResult.originalBytes, try Data(contentsOf: urls[1]))
        XCTAssertTrue(plist.thumbnailText?.isEmpty == false)

        let dictionaryBytes = try Data(contentsOf: urls[2])
        let observedWords = ThumbnailInspectionRecorder()
        let wordsEvents = ThumbnailReadEventRecorder()
        let words = try ThumbnailPreparation.read(at: urls[2], contentTypeIdentifier: { _ in nil },
            observe: { wordsEvents.append($0) }, inspectionObserver: { observedWords.store($0) })
        assertRouting(wordsEvents, sample: 65_536, complete: false)
        XCTAssertEqual(words.selectedInspectorID, .text)
        XCTAssertEqual(words.sampleByteCount, 65_536)
        XCTAssertFalse(words.sampleIsComplete)
        XCTAssertEqual(words.readByteCount, 262_144)
        XCTAssertTrue(words.analysis.truncated)
        XCTAssertGreaterThan(words.analysis.lineCount,
            TextAnalysis.analyze(bytes: Data(dictionaryBytes.prefix(65_536)), fileSize: dictionaryBytes.count,
                                 maximumBytes: 65_536).lineCount)
        XCTAssertEqual(try XCTUnwrap(observedWords.value).originalBytes, Data(dictionaryBytes.prefix(262_144)))

        let changed = Data(dictionaryBytes.prefix(65_536)) + Data([0]) + Data(dictionaryBytes.dropFirst(65_537))
        let derivativeURL = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("words")
        try changed.write(to: derivativeURL)
        let observedBinary = ThumbnailInspectionRecorder()
        let binaryEvents = ThumbnailReadEventRecorder()
        let binary = try ThumbnailPreparation.read(at: derivativeURL, contentTypeIdentifier: { _ in nil },
            observe: { binaryEvents.append($0) }, inspectionObserver: { observedBinary.store($0) })
        assertRouting(binaryEvents, sample: 65_536, complete: false)
        XCTAssertEqual(binary.selectedInspectorID, .text)
        XCTAssertTrue(binary.analysis.isBinary)
        XCTAssertNil(binary.sourceDocument)
        XCTAssertNil(binary.thumbnailText)
        XCTAssertEqual(try XCTUnwrap(observedBinary.value).originalBytes, Data(changed.prefix(262_144)))
    }

    func testNFRP02RealThumbnailTextBundle() throws {
        let environment = ProcessInfo.processInfo.environment
        let required = environment["GLIMT_NFRP02_THUMBNAIL_TEXTBUNDLE_REQUIRED"]
        let configuredPath = environment["GLIMT_NFRP02_THUMBNAIL_TEXTBUNDLE_PATH"]
        guard required != nil || configuredPath != nil else {
            throw XCTSkip("Genuine Thumbnail TextBundle input is opt-in")
        }
        guard required == nil || required == "1" else {
            XCTFail("GLIMT_NFRP02_THUMBNAIL_TEXTBUNDLE_REQUIRED must be 1 when configured")
            return
        }
        guard let configuredPath else {
            XCTFail("Required genuine Thumbnail TextBundle path is missing")
            return
        }
        let packageURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            XCTFail("Configured genuine Thumbnail TextBundle is missing")
            return
        }
        let manifestURL = packageURL.appendingPathComponent("info.json")
        let markdownURL = packageURL.appendingPathComponent("text.md")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let markdownBefore = try Data(contentsOf: markdownURL)
        XCTAssertEqual(manifestBefore.count, 54)
        XCTAssertEqual(markdownBefore.count, 86_923)
        XCTAssertEqual(Self.gitBlobSHA1(manifestBefore), "f4a55653fcdec7ba57b95ad3bf54ec207567332e")
        XCTAssertEqual(Self.gitBlobSHA1(markdownBefore), "63b2651ad5fa7aa6372cba6146c6be003c5f884a")
        let metadataUTI = try packageURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier

        func assertStagedResult(_ preparation: ThumbnailPreparation, _ inspection: PreviewInspectionResult?,
                                _ recorder: ThumbnailTextBundleEventRecorder, _ label: String) throws {
            XCTAssertEqual(preparation.selectedInspectorID, .markdown, label)
            XCTAssertEqual(preparation.formatID, .textbundle, label)
            XCTAssertEqual(preparation.systemUTI, inspection?.systemUTI, label)
            XCTAssertEqual(preparation.systemUTI, metadataUTI, label)
            XCTAssertEqual(preparation.sampleByteCount, 65_482, label)
            XCTAssertFalse(preparation.sampleIsComplete, label)
            XCTAssertEqual(preparation.readByteCount, 86_923, label)
            XCTAssertEqual(inspection?.originalBytes, markdownBefore, label)
            XCTAssertEqual(inspection?.formatDefinition?.id, FormatID(rawValue: "textbundle"), label)

            let events = recorder.values
            guard let selectionIndex = events.firstIndex(where: {
                if case .selectionCommitted = $0 { true } else { false }
            }) else { return XCTFail("\(label): staged selection event missing") }
            guard case .selectionCommitted(let routingCount, let distinctOffsets) = events[selectionIndex] else {
                return XCTFail("\(label): malformed selection event")
            }
            XCTAssertEqual(routingCount, 65_536, label)
            XCTAssertEqual(distinctOffsets, 65_536, label)
            let markdownReads = events.enumerated().compactMap { index, event -> (Int, Int, Int32)? in
                guard case .read(child: .markdown, let offset, _, let returned, _) = event, returned > 0,
                      let descriptorEvent = events[..<index].last(where: {
                          if case .readDescriptor(child: .markdown, offset: offset, _) = $0 { true } else { false }
                      }),
                      case .readDescriptor(_, _, let descriptor) = descriptorEvent else { return nil }
                return (offset, index, descriptor)
            }
            let continuation = try XCTUnwrap(markdownReads.first(where: { $0.0 == 65_482 }), label)
            XCTAssertEqual(continuation.2, try XCTUnwrap(markdownReads.first(where: { $0.0 == 0 })?.2, label), label)
            XCTAssertTrue(events.enumerated().contains { index, event in
                guard index > continuation.1,
                      case .descriptorClosed(child: .markdown, let descriptor) = event else { return false }
                return descriptor == continuation.2
            }, "\(label): Markdown descriptor must close after its final read")
        }

        let synchronousEvents = ThumbnailTextBundleEventRecorder()
        let synchronousInspection = ThumbnailInspectionRecorder()
        let synchronous = try ThumbnailPreparation.read(at: packageURL,
            contentTypeIdentifier: { fileURL in
                try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
            }, textBundleObserve: { synchronousEvents.append($0) },
            inspectionObserver: { synchronousInspection.store($0) })
        try assertStagedResult(synchronous, synchronousInspection.value, synchronousEvents, "synchronous")
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: markdownURL), markdownBefore)

        let watchdogEvents = ThumbnailTextBundleEventRecorder()
        let watchdogInspection = ThumbnailInspectionRecorder()
        let watchdog = try ThumbnailPreparation.read(at: packageURL, timeLimit: .seconds(5),
            contentTypeIdentifier: { fileURL in
                try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
            }, textBundleObserve: { watchdogEvents.append($0) },
            inspectionObserver: { watchdogInspection.store($0) })
        try assertStagedResult(watchdog, watchdogInspection.value, watchdogEvents, "watchdog")
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: markdownURL), markdownBefore)

        let evidence = "route=.textbundle/.markdown uti=\(metadataUTI ?? "nil") offsets=65536 sample=65482 eof=false continuation=65482 retained=86923 manifestBlob=f4a55653fcdec7ba57b95ad3bf54ec207567332e markdownBlob=63b2651ad5fa7aa6372cba6146c6be003c5f884a"
        print("NFR-P02 genuine Thumbnail TextBundle: \(evidence)")
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "NFR-P02 genuine Thumbnail TextBundle E2 evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTextBundleThumbnailUsesBoundedSharedMarkdownContent() throws {
        let url = try fixtureURL("Showcase/markdown-family/note.textbundle")
        let events = ThumbnailTextBundleEventRecorder()
        let inspection = ThumbnailInspectionRecorder()
        let preparation = try ThumbnailPreparation.read(at: url, contentTypeIdentifier: { _ in nil },
            textBundleObserve: { events.append($0) }, inspectionObserver: { inspection.store($0) })

        XCTAssertEqual(preparation.formatID, .textbundle)
        XCTAssertEqual(preparation.selectedInspectorID, .markdown)
        XCTAssertEqual(preparation.sampleByteCount, 34)
        XCTAssertTrue(preparation.sampleIsComplete)
        XCTAssertEqual(preparation.readByteCount, try Data(contentsOf: url.appendingPathComponent("text.md")).count)
        XCTAssertEqual(inspection.value?.originalBytes.count, preparation.readByteCount)
        XCTAssertEqual(events.values.filter { if case .selectionCommitted = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(events.values.contains { if case .dispatchAttempt(.markdown) = $0 { true } else { false } })
        XCTAssertFalse(events.values.contains { if case .assetResolutionStarted = $0 { true } else { false } })
        XCTAssertTrue(preparation.thumbnailText?.contains("Glimt") == true)
        XCTAssertTrue(preparation.thumbnailText?.contains("Anteckning") == true)
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: preparation.analysis,
            sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
            appearance: .light, maximumSize: CGSize(width: 256, height: 256), scale: 1))

        let timedEvents = ThumbnailTextBundleEventRecorder()
        let timedInspection = ThumbnailInspectionRecorder()
        let timed = try ThumbnailPreparation.read(at: url, timeLimit: .seconds(5),
            contentTypeIdentifier: { _ in nil }, textBundleObserve: { timedEvents.append($0) },
            inspectionObserver: { timedInspection.store($0) })
        XCTAssertEqual(timed.selectedInspectorID, preparation.selectedInspectorID)
        XCTAssertEqual(timed.resolution, preparation.resolution)
        XCTAssertEqual(timed.readByteCount, preparation.readByteCount)
        XCTAssertEqual(timedInspection.value?.originalBytes, inspection.value?.originalBytes)
        XCTAssertEqual(timedEvents.values.filter { if case .selectionCommitted = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(timedEvents.values.contains { if case .dispatchAttempt(.markdown) = $0 { true } else { false } })
        XCTAssertFalse(timedEvents.values.contains { if case .assetResolutionStarted = $0 { true } else { false } })
    }

    func testThumbnailTextBundleWatchdogClosesOnlyCompletedReadPublication() throws {
        let manifest = Data(#"{"version": 2, "type": "net.daringfireball.markdown" }"#.utf8)
        let blockedURL = try makeThumbnailTextBundle(manifest: manifest,
            markdown: Data(repeating: 0x61, count: 90_000), name: "before.textbundle")
        defer { try? FileManager.default.removeItem(at: blockedURL) }
        let beforeGate = ThumbnailSnapshotGate()
        let beforeEvents = ThumbnailTextBundleEventRecorder()
        let beforeObserver = ThumbnailInspectionRecorder()
        let beforeOutcome = ThumbnailPreparationReadOutcome()
        let beforeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { beforeDone.signal() }
            do {
                let result = try ThumbnailPreparation.read(at: blockedURL, timeLimit: .seconds(1),
                    contentTypeIdentifier: { _ in nil }, textBundleObserve: { event in
                        beforeEvents.append(event)
                        if case .selectionCommitted = event { beforeGate.block() }
                    }, inspectionObserver: { beforeObserver.store($0) },
                    packageRunner: { _, onTimeout, work in
                        let worker = Task.detached { try work() }
                        guard beforeGate.waitUntilEntered() else { return nil }
                        onTimeout()
                        worker.cancel()
                        beforeGate.release()
                        let joined = DispatchSemaphore(value: 0)
                        Task.detached { _ = try? await worker.value; joined.signal() }
                        _ = joined.wait(timeout: .now() + 5)
                        return nil
                    })
                beforeOutcome.store(.success(result))
            } catch {
                beforeOutcome.store(.failure(error))
            }
        }
        XCTAssertEqual(beforeDone.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(beforeGate.waitUntilReleased())
        XCTAssertThrowsError(try XCTUnwrap(beforeOutcome.result).get()) {
            XCTAssertTrue($0 is InspectionWatchdog.TimeoutError)
        }
        XCTAssertNil(beforeObserver.value)
        XCTAssertFalse(beforeEvents.values.contains { if case .dispatchAttempt = $0 { true } else { false } })

        let completeURL = try makeThumbnailTextBundle(manifest: manifest,
            markdown: Data("---\ntitle: hidden\n---\n# Visible\n".utf8), name: "after.textbundle")
        defer { try? FileManager.default.removeItem(at: completeURL) }
        let normal = try ThumbnailPreparation.read(at: completeURL, contentTypeIdentifier: { _ in nil })
        XCTAssertTrue(normal.thumbnailText?.contains("Visible") == true)
        XCTAssertFalse(normal.thumbnailText?.contains("hidden") == true)
        let afterGate = ThumbnailSnapshotGate()
        let afterEvents = ThumbnailTextBundleEventRecorder()
        let afterObserver = ThumbnailInspectionRecorder()
        let afterOutcome = ThumbnailPreparationReadOutcome()
        let afterDone = DispatchSemaphore(value: 0)
        let afterWorkerFinished = DispatchSemaphore(value: 0)
        let afterReadCountAtTimeout = ThumbnailIntegerRecorder()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { afterDone.signal() }
            do {
                let result = try ThumbnailPreparation.read(at: completeURL, timeLimit: .seconds(1),
                    contentTypeIdentifier: { _ in nil }, textBundleObserve: { event in
                        afterEvents.append(event)
                        if case .dispatchAttempt = event { afterGate.block() }
                    }, inspectionObserver: { afterObserver.store($0) },
                    packageRunner: { _, onTimeout, work in
                        let worker = Task.detached {
                            defer { afterWorkerFinished.signal() }
                            return try work()
                        }
                        guard afterGate.waitUntilEntered() else { return nil }
                        afterReadCountAtTimeout.store(afterEvents.requestedReadCount)
                        onTimeout()
                        worker.cancel()
                        return nil
                    })
                afterOutcome.store(.success(result))
            } catch {
                afterOutcome.store(.failure(error))
            }
        }
        XCTAssertEqual(afterDone.wait(timeout: .now() + 5), .success)
        let fallback = try XCTUnwrap(afterOutcome.result).get()
        XCTAssertEqual(afterObserver.value?.inspectionDiagnostics.map(\.code), [.limitExceeded])
        XCTAssertEqual(fallback.readByteCount, try Data(contentsOf: completeURL.appendingPathComponent("text.md")).count)
        XCTAssertEqual(fallback.selectedInspectorID, .markdown)
        XCTAssertEqual(afterEvents.values.filter { if case .selectionCommitted = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(afterEvents.values.filter { if case .dispatchAttempt = $0 { true } else { false } }.count, 1)
        let readsAtTimeout = try XCTUnwrap(afterReadCountAtTimeout.value)
        XCTAssertEqual(afterEvents.requestedReadCount, readsAtTimeout,
            "The fallback must not trigger package reads while the cancelled worker remains gated")
        afterGate.release()
        XCTAssertTrue(afterGate.waitUntilReleased())
        XCTAssertEqual(afterWorkerFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(afterEvents.requestedReadCount, readsAtTimeout,
            "The cancelled worker must stop without reading after it leaves the gate")

        let emptyURL = try makeThumbnailTextBundle(manifest: manifest, markdown: Data(), name: "empty.textbundle")
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let emptyGate = ThumbnailSnapshotGate()
        let emptyOutcome = ThumbnailPreparationReadOutcome()
        let emptyObserver = ThumbnailInspectionRecorder()
        let emptyDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { emptyDone.signal() }
            do {
                let result = try ThumbnailPreparation.read(at: emptyURL, timeLimit: .seconds(1),
                    contentTypeIdentifier: { _ in nil }, textBundleObserve: { event in
                        if case .dispatchAttempt = event { emptyGate.block() }
                    }, inspectionObserver: { emptyObserver.store($0) },
                    packageRunner: { _, onTimeout, work in
                        let worker = Task.detached { try work() }
                        guard emptyGate.waitUntilEntered() else { return nil }
                        onTimeout()
                        worker.cancel()
                        emptyGate.release()
                        let joined = DispatchSemaphore(value: 0)
                        Task.detached { _ = try? await worker.value; joined.signal() }
                        _ = joined.wait(timeout: .now() + 5)
                        return nil
                    })
                emptyOutcome.store(.success(result))
            } catch {
                emptyOutcome.store(.failure(error))
            }
        }
        XCTAssertEqual(emptyDone.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(emptyGate.waitUntilReleased())
        let emptyFallback = try XCTUnwrap(emptyOutcome.result).get()
        XCTAssertEqual(emptyFallback.readByteCount, 0)
        XCTAssertEqual(emptyObserver.value?.inspectionDiagnostics.map(\.code), [.limitExceeded])
    }

    func testThumbnailTextBundleAdapterRejectsMalformedAndLinkedChildren() throws {
        let validManifest = Data(#"{"version": 2, "type": "net.daringfireball.markdown" }"#.utf8)
        let outside = try writeTemporaryFile(Data("outside".utf8), named: "outside.md")
        for useWatchdog in [false, true] {
            let malformed = try makeThumbnailTextBundle(manifest: Data("not json".utf8),
                markdown: Data("text".utf8), name: "malformed-\(useWatchdog).textbundle")
            defer { try? FileManager.default.removeItem(at: malformed) }
            let linked = try makeThumbnailTextBundle(manifest: validManifest,
                markdown: Data(), name: "linked-\(useWatchdog).textbundle")
            try FileManager.default.removeItem(at: linked.appendingPathComponent("text.md"))
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("text.md"),
                withDestinationURL: outside)
            defer { try? FileManager.default.removeItem(at: linked) }

            for url in [malformed, linked] {
                XCTAssertThrowsError(try readThumbnailAdapter(url, useWatchdog: useWatchdog))
            }
        }

        var lateBinary = Data("# Textual route\n".utf8)
        lateBinary.append(Data(repeating: 0x61, count: 65_482 - lateBinary.count))
        lateBinary.append(0)
        let binaryURL = try makeThumbnailTextBundle(manifest: validManifest, markdown: lateBinary,
            name: "late-binary.textbundle")
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        for useWatchdog in [false, true] {
            let inspection = ThumbnailInspectionRecorder()
            let preparation: ThumbnailPreparation
            if useWatchdog {
                preparation = try ThumbnailPreparation.read(at: binaryURL, timeLimit: .seconds(5),
                    contentTypeIdentifier: { _ in nil }, inspectionObserver: { inspection.store($0) })
            } else {
                preparation = try ThumbnailPreparation.read(at: binaryURL,
                    contentTypeIdentifier: { _ in nil }, inspectionObserver: { inspection.store($0) })
            }
            XCTAssertTrue(preparation.analysis.isBinary)
            XCTAssertNil(preparation.thumbnailText)
            XCTAssertNil(ThumbnailRenderer.render(analysis: preparation.analysis,
                sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
                appearance: .light, maximumSize: thumbnailSize, scale: 1))
            XCTAssertEqual(inspection.value?.selectedInspectorID, .markdown)
            XCTAssertEqual(inspection.value?.inspectionDiagnostics.map(\.code), [.unsupported])
        }
    }

    func testThumbnailTextBundleAdapterRetainsBoundedPayloadInBothPaths() throws {
        let manifest = Data(#"{"version": 2, "type": "net.daringfireball.markdown" }"#.utf8)
        let markdown = Data("---\ntitle: hidden\n---\n# Visible\n".utf8)
            + Data(repeating: 0x61, count: ThumbnailPreparation.maximumPrefixBytes + 20_000)
        let url = try makeThumbnailTextBundle(manifest: manifest, markdown: markdown, name: "bounded.textbundle")
        defer { try? FileManager.default.removeItem(at: url) }

        for useWatchdog in [false, true] {
            let events = ThumbnailTextBundleEventRecorder()
            let inspected = ThumbnailInspectionRecorder()
            let preparation: ThumbnailPreparation
            if useWatchdog {
                preparation = try ThumbnailPreparation.read(at: url, timeLimit: .seconds(5),
                    contentTypeIdentifier: { _ in nil }, textBundleObserve: { events.append($0) },
                    inspectionObserver: { inspected.store($0) })
            } else {
                preparation = try ThumbnailPreparation.read(at: url, contentTypeIdentifier: { _ in nil },
                    textBundleObserve: { events.append($0) }, inspectionObserver: { inspected.store($0) })
            }
            XCTAssertEqual(preparation.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
            XCTAssertTrue(preparation.analysis.truncated)
            XCTAssertEqual(preparation.sampleByteCount, 65_482)
            XCTAssertFalse(preparation.sampleIsComplete)
            XCTAssertEqual(inspected.value?.originalBytes, Data(markdown.prefix(ThumbnailPreparation.maximumPrefixBytes)))
            XCTAssertNil(preparation.thumbnailText, "Incomplete Markdown must stay on the raw fallback")
            XCTAssertEqual(inspected.value?.inspectionDiagnostics.map(\.code), [.truncated])
            XCTAssertFalse(preparation.thumbnailText?.contains("hidden") == true)

            let values = events.values
            guard let selection = values.firstIndex(where: {
                if case .selectionCommitted = $0 { true } else { false }
            }) else { return XCTFail("The package selection event is missing") }
            guard case .selectionCommitted(let routingBytes, let distinctOffsets) = values[selection] else {
                return XCTFail("The package selection event is malformed")
            }
            XCTAssertEqual(routingBytes, 65_536)
            XCTAssertEqual(distinctOffsets, 65_536)
            guard let continuation = values.firstIndex(where: {
                if case .continuationAppended = $0 { true } else { false }
            }),
                let dispatch = values.firstIndex(where: {
                    if case .dispatchAttempt = $0 { true } else { false }
                }) else { return XCTFail("Continuation and dispatch events are required") }
            XCTAssertLessThan(selection, continuation)
            XCTAssertLessThan(continuation, dispatch)
            let markdownDescriptors = values.compactMap { event -> Int32? in
                guard case .readDescriptor(child: .markdown, _, let descriptor) = event else { return nil }
                return descriptor
            }
            XCTAssertEqual(Set(markdownDescriptors).count, 1)
            let descriptor = try XCTUnwrap(markdownDescriptors.first)
            let finalMarkdownRead = try XCTUnwrap(values.lastIndex(where: {
                if case .read(child: .markdown, _, _, _, _) = $0 { true } else { false }
            }))
            let descriptorClose = try XCTUnwrap(values.firstIndex(where: {
                if case .descriptorClosed(child: .markdown, descriptor) = $0 { true } else { false }
            }))
            XCTAssertGreaterThan(descriptorClose, finalMarkdownRead)
        }
    }

    func testThumbnailTextBundleSnapshotRejectsPublicationAfterTimeoutClosure() throws {
        let box = ThumbnailTextBundleSnapshotBox()
        let url = try fixtureURL("Showcase/markdown-family/note.textbundle")
        let captured = ThumbnailTextBundleSnapshotRecorder()
        _ = try PreviewInspectionResult.readThumbnailTextBundle(at: url, maximumBytes: 262_144,
            markdownOptions: .init(frontMatter: .hide), contentTypeIdentifier: { _ in nil },
            onCompletedRead: { captured.store($0) })
        let snapshot = try XCTUnwrap(captured.value)
        XCTAssertTrue(box.publish(snapshot))
        box.close()
        XCTAssertFalse(box.publish(snapshot))
        XCTAssertNotNil(box.load())
    }

    func testZIPThumbnailUsesBoundedArchiveListing() throws {
        let url = try fixtureURL("Showcase/data/inventory.zip")
        let bytes = try Data(contentsOf: url)
        let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: url.lastPathComponent, systemUTI: nil)

        XCTAssertEqual(preparation.formatID, .zip)
        XCTAssertTrue(preparation.thumbnailText?.contains("ZIP · 2 entries") == true)
        XCTAssertTrue(preparation.thumbnailText?.contains("inventory.txt") == true)
        XCTAssertTrue(preparation.thumbnailText?.contains("notes.txt") == true)
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: preparation.analysis,
            sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
            appearance: .light, maximumSize: CGSize(width: 256, height: 256), scale: 1))

        let oversized = Data(repeating: 0x41, count: ThumbnailPreparation.maximumPrefixBytes + 1)
        let clipped = ThumbnailPreparation.prepare(bytes: oversized, fileSize: oversized.count,
            fileName: "oversized.zip", systemUTI: nil)
        XCTAssertEqual(clipped.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
        XCTAssertTrue(clipped.analysis.truncated)
        XCTAssertNil(clipped.thumbnailText)
    }

    func testZIPThumbnailListsAnArchiveLargerThanTheThumbnailPrefix() throws {
        let entry = [UInt8]("large.bin".utf8)
        let payloadSize = ThumbnailPreparation.maximumPrefixBytes * 2
        func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func le32(_ value: Int) -> [UInt8] { le16(value & 0xFFFF) + le16(value >> 16) }
        let fields = le16(10) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(payloadSize) + le32(payloadSize)
        var archive = [0x50, 0x4B, 0x03, 0x04] + fields + le16(entry.count) + le16(0) + entry
        archive += [UInt8](repeating: 0x41, count: payloadSize)
        let centralOffset = archive.count
        archive += [0x50, 0x4B, 0x01, 0x02] + le16(10) + fields + le16(entry.count) + le16(0) + le16(0)
            + le16(0) + le16(0) + le32(0) + le32(0) + entry
        let centralSize = archive.count - centralOffset
        archive += [0x50, 0x4B, 0x05, 0x06] + le16(0) + le16(0) + le16(1) + le16(1)
            + le32(centralSize) + le32(centralOffset) + le16(0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtLargeZIP-\(UUID().uuidString).zip")
        try Data(archive).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let preparation = try ThumbnailPreparation.read(at: url)
        XCTAssertEqual(preparation.formatID, .zip)
        XCTAssertEqual(preparation.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
        XCTAssertTrue(preparation.thumbnailText?.contains("ZIP · 1 entry") == true, preparation.thumbnailText ?? "nil")
        XCTAssertTrue(preparation.thumbnailText?.contains("large.bin") == true)
    }

    func testEmptyZIPThumbnailShowsEmptyState() throws {
        let bytes = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "empty.zip", systemUTI: nil)
        XCTAssertEqual(preparation.formatID, .zip)
        XCTAssertEqual(preparation.thumbnailText, "ZIP · 0 entries")
    }

    func testNewDatabaseArchiveAppleAndSBOMThumbnailsUseBoundedSummaries() throws {
        let cases: [(String, FormatID, String, [String])] = [
            ("Showcase/data/inventory.sqlite", .sqlite, "SQLite · 2 schema objects", ["packages", "CREATE TABLE"]),
            ("Showcase/data/inventory.tar", .tarArchive, "TAR · 1 entry", ["csv.csv"]),
            ("Showcase/apple/CodeResources", .codeResources, "CodeResources", ["Resources/Info.txt"]),
            ("Showcase/security/cyclonedx.cdx.pb", .cyclonedxSBOMProtobuf, "CycloneDX protobuf 1.5", ["SQLite3", "3.46"])
        ]
        for (path, id, expected, excluded) in cases {
            let url = try fixtureURL(path)
            let preparation = try ThumbnailPreparation.read(at: url)
            XCTAssertEqual(preparation.formatID, id, path)
            XCTAssertTrue(preparation.thumbnailText?.contains(expected) == true, path)
            for value in excluded {
                XCTAssertFalse(preparation.thumbnailText?.contains(value) == true, path)
            }
            XCTAssertNotNil(ThumbnailRenderer.render(analysis: preparation.analysis,
                sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
                appearance: .light, maximumSize: CGSize(width: 256, height: 256), scale: 1), path)
        }
    }

    func testX509ThumbnailSummarizesParsedCertificateFacts() throws {
        for (path, id) in [("Showcase/security/certificate.pem", FormatID.pemCertificate),
                           ("Showcase/security/certificate.der", FormatID.derCertificate)] {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: url.lastPathComponent, systemUTI: nil)

            XCTAssertEqual(preparation.formatID, id, path)
            XCTAssertTrue(preparation.thumbnailText?.contains("Glimt Test Fixture") == true, path)
            XCTAssertNotNil(ThumbnailRenderer.render(analysis: preparation.analysis,
                sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
                appearance: .light, maximumSize: CGSize(width: 256, height: 256), scale: 1), path)
        }

        let oversizedPEM = Data(repeating: 0x41, count: ThumbnailPreparation.maximumPrefixBytes + 1)
        let clipped = ThumbnailPreparation.prepare(bytes: oversizedPEM, fileSize: oversizedPEM.count,
            fileName: "oversized.pem", systemUTI: nil)
        XCTAssertEqual(clipped.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
        XCTAssertNil(clipped.thumbnailText)
    }

    func testSecurityFormatThumbnailsUseOnlyNonSensitiveSummaries() throws {
        let cases: [(String, FormatID, String)] = [
            ("Showcase/security/synthetic.mobileprovision", .mobileprovision, "signature not checked"),
            ("Showcase/security/demo.jwt", .jwt, "unverified"),
            ("Showcase/security/public-key.jwk", .jwk, "JWK"),
            ("Showcase/security/public-keys.jwks", .jwks, "key"),
            ("Showcase/security/cyclonedx.cdx.json", .cyclonedxSBOM, "CycloneDX"),
            ("Showcase/security/demo.spdx.json", .spdxSBOM, "SPDX"),
            ("Showcase/security/cyclonedx.cdx.xml", .cyclonedxSBOMXML, "CycloneDX"),
            ("Showcase/security/cyclonedx.cdx.pb", .cyclonedxSBOMProtobuf, "CycloneDX protobuf 1.5"),
            ("Showcase/security/demo.spdx", .spdxTagValue, "SPDX-2.3")
        ]
        for (path, id, expectedSummary) in cases {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: url.lastPathComponent, systemUTI: nil)
            XCTAssertEqual(preparation.formatID, id, path)
            XCTAssertTrue(preparation.thumbnailText?.localizedCaseInsensitiveContains(expectedSummary) == true, path)
            XCTAssertFalse(preparation.thumbnailText?.contains("build@glimt.test") == true, path)
            XCTAssertFalse(preparation.thumbnailText?.contains("glimt-test") == true, path)
            XCTAssertNotNil(ThumbnailRenderer.render(analysis: preparation.analysis,
                semanticText: preparation.thumbnailText, appearance: .light,
                maximumSize: thumbnailSize, scale: 1), path)
        }

        let privateJWK = Data(#"{"kty":"oct","k":"thumbnail-secret"}"#.utf8)
        let privatePreparation = ThumbnailPreparation.prepare(bytes: privateJWK, fileSize: privateJWK.count,
            fileName: "private.jwk", systemUTI: nil)
        XCTAssertFalse(privatePreparation.thumbnailText?.contains("thumbnail-secret") == true)
        let oversizedToken = Data(repeating: 0x41, count: ThumbnailPreparation.maximumPrefixBytes + 1)
        XCTAssertNil(ThumbnailPreparation.prepare(bytes: oversizedToken, fileSize: oversizedToken.count,
            fileName: "oversized.jwt", systemUTI: nil).thumbnailText)
    }

    func testStringCatalogThumbnailContainsCountsWithoutLocalizedValues() throws {
        let url = try fixtureURL("Showcase/apple/Localizable.xcstrings")
        let bytes = try Data(contentsOf: url)
        let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: url.lastPathComponent, systemUTI: nil)

        XCTAssertEqual(preparation.formatID, .xcstrings)
        XCTAssertEqual(preparation.thumbnailText, "String catalog · 3 strings · 3 languages")
        XCTAssertFalse(preparation.thumbnailText?.contains("Inställningar") == true)
        XCTAssertFalse(preparation.thumbnailText?.contains("Open private panel") == true)
        XCTAssertNotNil(ThumbnailRenderer.render(analysis: preparation.analysis,
            semanticText: preparation.thumbnailText, appearance: .light,
            maximumSize: thumbnailSize, scale: 1))
    }

#if DEBUG
    func testDebugBuildMarkerRendersOnUsableThumbnailCanvas() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 128,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        XCTAssertTrue(ThumbnailRenderer.drawDebugBuildMarker("DEBUG · 1.0.0 (1)", in: context, size: CGSize(width: 128, height: 64)))
        let image = try XCTUnwrap(context.makeImage())
        let imageData = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertTrue(imageData.contains(where: { $0 != 0 }), "The build label should leave visible pixels in the thumbnail context")
        XCTAssertFalse(ThumbnailRenderer.drawDebugBuildMarker("DEBUG · 1.0.0 (1)", in: context, size: CGSize(width: 24, height: 24)))
        XCTAssertTrue(ThumbnailRenderer.drawDebugBuildMarker("11-18 09:05:07", in: context, size: CGSize(width: 80, height: 64)),
                      "The build-time stamp fits a small Finder icon")
    }
#endif

    private let thumbnailSize = CGSize(width: 256, height: 256)
    private var temporaryDirectoryURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlimtThumbnailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectoryURL = directory
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testRendersLeadingLogicalLinesInOrderWithExpectedDimensions() throws {
        let analysis = Self.analysis(for: "alpha\nbeta\n")

        XCTAssertEqual(
            ThumbnailRenderer.renderedLines(for: analysis, maximumSize: thumbnailSize, scale: 1),
            ["alpha", "beta"]
        )

        let image = try XCTUnwrap(
            ThumbnailRenderer.render(analysis: analysis, maximumSize: thumbnailSize, scale: 1)
        )
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        XCTAssertTrue(hasPixelsDifferentFromBackground(in: image))
    }

    /// Thumbnails use fixed defaults (D62): the line budget is `ThumbnailRenderDefaults.maximumLines`.
    func testThumbnailUsesFixedLineBudget() {
        let analysis = Self.analysis(for: (1...60).map(String.init).joined(separator: "\n"))
        let lines = ThumbnailRenderer.renderedLines(for: analysis, maximumSize: CGSize(width: 1024, height: 1024), scale: 1)
        XCTAssertEqual(lines, (1...ThumbnailRenderDefaults.maximumLines).map(String.init))
        XCTAssertEqual(ThumbnailRenderDefaults.maximumLines, 18)
        XCTAssertFalse(ThumbnailRenderDefaults.source.showLineNumbers)
        XCTAssertFalse(ThumbnailRenderDefaults.source.indentationGuides)
        XCTAssertTrue(ThumbnailRenderDefaults.source.wrapLines)
        XCTAssertEqual(ThumbnailRenderDefaults.appearance, .system)
    }

    /// D62 determinism: a clear Quick Look settings change (font size, guides, line numbers, wrap,
    /// per-format override, chosen representation) changes the Quick Look configuration but leaves the
    /// thumbnail pixels identical.
    @MainActor
    func testThumbnailIsIdenticalBeforeAndAfterQuickLookSettingsChange() throws {
        func thumbnailBytes(_ fileName: String, _ uti: String, _ text: String) throws -> Data {
            let bytes = Data(text.utf8)
            let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: uti)
            let image = try XCTUnwrap(ThumbnailRenderer.render(analysis: preparation.analysis,
                sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
                appearance: .light, maximumSize: CGSize(width: 512, height: 512), scale: 2))
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        let source = (1...48).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let json = "{\"name\":\"Glimt\",\"items\":[1,2,3]}"
        let inputs = [("Example.py", "public.python-script", source), ("config.json", "public.json", json)]
        let before = try inputs.map { try thumbnailBytes($0.0, $0.1, $0.2) }

        let factory = GlimtSettingsV3.factoryDefaults
        var changed = factory
        changed.general.font = FontSetting(family: "Menlo", size: 22)
        changed.general.indentationGuides = !factory.general.indentationGuides
        changed.general.lineNumbers = !factory.general.lineNumbers
        changed.general.wordWrap = factory.general.wordWrap == .off ? .soft : .off
        changed.formatOverrides["json"] = ["raw", "tree", "pretty"]
        let quickLookBefore = RenderConfiguration(settings: factory)
        let quickLookAfter = RenderConfiguration(settings: changed)
        XCTAssertNotEqual(quickLookBefore.source(for: .python), quickLookAfter.source(for: .python))
        XCTAssertNotEqual(quickLookBefore.configuredViews(for: .json), quickLookAfter.configuredViews(for: .json))

        let after = try inputs.map { try thumbnailBytes($0.0, $0.1, $0.2) }
        XCTAssertEqual(before, after, "Thumbnail rendering takes no user settings")
    }

    /// The thumbnail picks the catalog's preferred representation; the user's default representation
    /// never reaches it. Formats without a declared strategy fall back by inspection kind.
    func testThumbnailRepresentationComesFromCatalogStrategy() throws {
        XCTAssertEqual(FormatCatalog.definition(for: .json)?.effectiveThumbnailStrategy, .textLines)
        XCTAssertEqual(FormatCatalog.definition(for: .csv)?.effectiveThumbnailStrategy, .table)
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.effectiveThumbnailStrategy, .sourceCode)
        let bytes = Data("{\"a\":1,\"b\":2}".utf8)
        let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "x.json", systemUTI: "public.json")
        XCTAssertGreaterThan(preparation.thumbnailText?.components(separatedBy: .newlines).count ?? 0, 1,
                             "JSON thumbnails show pretty text even when Quick Look defaults to Raw")
    }

    func testPrivacyAndTestPlanThumbnailsContainCountsButNoDocumentValues() throws {
        let cases = [
            ("Showcase/apple/PrivacyInfo.xcprivacy", "PrivacyInfo.xcprivacy", ["tracker.example", "C617.1"], "Cases/apple/invalid/wrong-shape.xcprivacy", "private-tracker.invalid"),
            ("Showcase/apple/UnitTests.xctestplan", "UnitTests.xctestplan", ["GlimtTests", "A1B2C3D4"], "Cases/apple/invalid/wrong-root.xctestplan", "PRIVATE_TEST_TARGET"),
            ("Showcase/security/demo.spdx.yaml", "demo.spdx.yaml", ["Glimt SBOM", "Glimt"], "Cases/sbom/invalid/malformed.spdx.yaml", "PRIVATE_COMPONENT_NAME")
        ]
        for (path, fileName, privateValues, malformedPath, malformedValue) in cases {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: fileName, systemUTI: nil)
            let summary = try XCTUnwrap(preparation.thumbnailText, fileName)
            XCTAssertFalse(privateValues.contains(where: summary.contains), fileName)
            XCTAssertTrue(summary.contains("1 "), fileName)

            let malformed = try Data(contentsOf: fixtureURL(malformedPath))
            let fallback = ThumbnailPreparation.prepare(bytes: malformed, fileSize: malformed.count,
                fileName: fileName, systemUTI: nil)
            let safeFallback = try XCTUnwrap(fallback.thumbnailText, malformedPath)
            XCTAssertFalse(safeFallback.contains(malformedValue), malformedPath)
        }
    }

    @MainActor
    func testMermaidThumbnailIdentityDispatchesToUnchangedTextLinesOutput() throws {
        let source = "flowchart TD\nA[Thumbnail] --> B[Text lines]\n"
        let bytes = Data(source.utf8)
        let controls: [(String, String?)] = [
            ("diagram.mmd", nil),
            ("diagram.mermaid", "public.swift-source"),
            ("diagram.data", "com.glimt.mermaid-source")
        ]
        let plain = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "diagram.txt", systemUTI: "public.plain-text")
        let plainImage = try XCTUnwrap(ThumbnailRenderer.render(analysis: plain.analysis,
            sourceDocument: plain.sourceDocument, semanticText: plain.thumbnailText,
            appearance: .light, maximumSize: CGSize(width: 256, height: 256), scale: 1))
        let plainPixels = try XCTUnwrap(plainImage.dataProvider?.data as Data?)

        for (fileName, uti) in controls {
            let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: fileName, systemUTI: uti)
            XCTAssertEqual(preparation.formatID, .mermaid, fileName)
            XCTAssertEqual(FormatCatalog.definition(for: preparation.formatID ?? .text)?.effectiveThumbnailStrategy,
                           .textLines, fileName)
            XCTAssertNil(preparation.sourceDocument, fileName)
            XCTAssertNil(preparation.thumbnailText, fileName)
            XCTAssertEqual(ThumbnailRenderer.renderedLines(for: preparation.analysis,
                maximumSize: CGSize(width: 256, height: 256), scale: 1),
                ThumbnailRenderer.renderedLines(for: plain.analysis,
                    maximumSize: CGSize(width: 256, height: 256), scale: 1), fileName)
            let image = try XCTUnwrap(ThumbnailRenderer.render(analysis: preparation.analysis,
                sourceDocument: preparation.sourceDocument, semanticText: preparation.thumbnailText,
                appearance: .light, maximumSize: CGSize(width: 256, height: 256), scale: 1))
            XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data as Data?), plainPixels, fileName)
        }

        let logLike = Data("2026-11-19T10:00:00Z ERROR api: failed\n".utf8)
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: logLike, fileSize: logLike.count,
            fileName: "events.mmd", systemUTI: nil).formatID, .mermaid)
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: logLike, fileSize: logLike.count,
            fileName: "events.log", systemUTI: "com.glimt.mermaid-source").formatID, .log)

        let sourceHint = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "diagram.mmd", systemUTI: "public.swift-source")
        XCTAssertEqual(sourceHint.formatID, .mermaid, "The qualifying Mermaid filename takes precedence over source hints")
    }

    @MainActor
    func testThumbnailGeometryKeepsReplyInPointsAndRasterAtRequestedScale() throws {
        let pointSize = CGSize(width: 96, height: 64)
        XCTAssertEqual(
            ThumbnailRenderer.replyContextSize(maximumSize: pointSize, minimumSize: CGSize(width: 32, height: 32), scale: 2),
            pointSize
        )
        let analysis = Self.analysis(for: "Hello from Glimt\\nA deliberately long line for thumbnail truncation")
        let oneX = try XCTUnwrap(ThumbnailRenderer.render(analysis: analysis, maximumSize: pointSize, scale: 1))
        let twoX = try XCTUnwrap(ThumbnailRenderer.render(analysis: analysis, maximumSize: pointSize, scale: 2))
        XCTAssertEqual(oneX.width, 96)
        XCTAssertEqual(oneX.height, 64)
        XCTAssertEqual(twoX.width, 192)
        XCTAssertEqual(twoX.height, 128)
    }

    @MainActor
    func testThumbnailSizeClassesRenderAtOneAndTwoTimes() throws {
        let analysis = Self.analysis(for: "# Glimt\nlet value = 42\nprint(value)\nA long representative source line for the thumbnail")
        for edge in [64, 96, 128] {
            let pointSize = CGSize(width: edge, height: edge)
            for scale: CGFloat in [1, 2] {
                let image = try XCTUnwrap(ThumbnailRenderer.render(
                    analysis: analysis, maximumSize: pointSize, scale: scale
                ), "\(edge)pt at \(scale)x")
                XCTAssertEqual(image.width, edge * Int(scale))
                XCTAssertEqual(image.height, edge * Int(scale))
                XCTAssertTrue(hasPixelsDifferentFromBackground(in: image), "\(edge)pt at \(scale)x")
            }
        }
    }

    func testThumbnailGeometryRejectsInvalidAndUnboundedRequests() {
        for (size, scale) in [
            (CGSize(width: CGFloat.infinity, height: 64), 1),
            (CGSize(width: CGFloat.nan, height: 64), 1),
            (CGSize(width: 64, height: 64), CGFloat.infinity),
            (CGSize(width: 64, height: 64), 0),
            (CGSize(width: 8_192, height: 64), 1),
            (CGSize(width: 4_096, height: 4_096), 2),
            (CGSize(width: 2_049, height: 2_049), 1)
        ] {
            XCTAssertNil(ThumbnailRenderer.pixelSize(maximumSize: size, scale: scale))
            XCTAssertNil(ThumbnailRenderer.replyContextSize(maximumSize: size, minimumSize: .zero, scale: scale))
        }
        XCTAssertNil(ThumbnailRenderer.replyContextSize(
            maximumSize: CGSize(width: 64, height: 64), minimumSize: CGSize(width: 65, height: 1), scale: 1
        ))
        XCTAssertNil(ThumbnailRenderer.replyContextSize(
            maximumSize: CGSize(width: 1_000_000, height: 64), minimumSize: .zero, scale: 0.001
        ))
    }

    func testPreparationBuildsBoundedSourceDocumentFromCatalogDetection() throws {
        let bytes = Data("// Glimt source\nlet label = \"Glimt\"\n".utf8)
        let preparation = ThumbnailPreparation.prepare(
            bytes: bytes,
            fileSize: bytes.count,
            fileName: "Example.swift",
            systemUTI: "public.swift-source"
        )

        XCTAssertEqual(preparation.sourceLanguage, .swift)
        let source = try XCTUnwrap(preparation.sourceDocument)
        XCTAssertEqual(source.language, .swift)
        XCTAssertEqual(source.source, String(decoding: bytes, as: UTF8.self))
        XCTAssertTrue(source.highlighting.runs.contains { $0.kind == .comment })
        XCTAssertTrue(source.highlighting.runs.contains { $0.kind == .keyword })
        XCTAssertTrue(source.highlighting.runs.contains { $0.kind == .string })
        XCTAssertNil(ThumbnailPreparation.prepare(
            bytes: Data("{\"ok\":true}".utf8),
            fileSize: 11,
            fileName: "config.json",
            systemUTI: "public.json"
        ).sourceDocument)
    }

    func testPreparationUsesRenderedMarkdownWithoutFrontMatterForThumbnailContent() {
        let markdown = """
        ---
        title: Internal metadata title
        purpose: Fixture-only front matter
        ---

        # Finder-friendly heading

        A readable paragraph that identifies the document.
        """
        let bytes = Data(markdown.utf8)
        let preparation = ThumbnailPreparation.prepare(
            bytes: bytes,
            fileSize: bytes.count,
            fileName: "README.md",
            systemUTI: nil
        )

        XCTAssertTrue(preparation.thumbnailText?.contains("Finder-friendly heading") == true)
        XCTAssertTrue(preparation.thumbnailText?.contains("A readable paragraph") == true)
        XCTAssertFalse(preparation.thumbnailText?.contains("Fixture-only front matter") == true)
        XCTAssertFalse(preparation.thumbnailText?.contains("---") == true)
        XCTAssertEqual(preparation.thumbnailText?.split(separator: "\n", omittingEmptySubsequences: true).first, "Finder-friendly heading")
        XCTAssertGreaterThan(preparation.thumbnailText?.components(separatedBy: .newlines).count ?? 0, 1)
    }

    @MainActor
    func testPreparationProvidesPrettyTextForOneLineJSONThumbnail() throws {
        let json = "{\"name\":\"Glimt\",\"enabled\":true,\"version\":1,\"formats\":[\"JSON\",\"YAML\"]}"
        let bytes = Data(json.utf8)
        let preparation = ThumbnailPreparation.prepare(
            bytes: bytes,
            fileSize: bytes.count,
            fileName: "config.json",
            systemUTI: "public.json"
        )

        XCTAssertTrue(preparation.thumbnailText?.contains("name") == true)
        XCTAssertTrue(preparation.thumbnailText?.contains("Glimt") == true)
        XCTAssertGreaterThan(preparation.thumbnailText?.components(separatedBy: .newlines).count ?? 0, 1)
        let image = try XCTUnwrap(ThumbnailRenderer.render(
            analysis: preparation.analysis,
            semanticText: preparation.thumbnailText,
            maximumSize: CGSize(width: 256, height: 256),
            scale: 1
        ))
        XCTAssertTrue(hasPixelsDifferentFromBackground(in: image))
    }

    @MainActor
    func testCSVThumbnailUsesCatalogTableStrategy() throws {
        let bytes = Data("name,kind\nGlimt,document\n".utf8)
        let preparation = ThumbnailPreparation.prepare(
            bytes: bytes, fileSize: bytes.count, fileName: "items.csv", systemUTI: "public.comma-separated-values-text"
        )

        XCTAssertEqual(preparation.csvInspection?.table?.headers, ["name", "kind"])
        XCTAssertTrue(preparation.thumbnailText?.contains("Glimt") == true)
        let image = try XCTUnwrap(ThumbnailRenderer.render(
            analysis: preparation.analysis,
            semanticText: preparation.thumbnailText,
            maximumSize: CGSize(width: 256, height: 256),
            scale: 1
        ))
        XCTAssertTrue(hasPixelsDifferentFromBackground(in: image))
    }

    @MainActor
    func testBinaryPlistThumbnailHasSemanticContent() throws {
        let object: [String: Any] = ["name": "Glimt", "enabled": true, "version": 1]
        let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let preparation = ThumbnailPreparation.prepare(
            bytes: bytes,
            fileSize: bytes.count,
            fileName: "config.plist",
            systemUTI: "com.apple.binary-property-list"
        )

        XCTAssertTrue(preparation.analysis.isBinary)
        XCTAssertTrue(preparation.thumbnailText?.contains("Glimt") == true)
        XCTAssertTrue(preparation.thumbnailText?.contains("enabled") == true)
        let image = try XCTUnwrap(ThumbnailRenderer.render(
            analysis: preparation.analysis,
            semanticText: preparation.thumbnailText,
            maximumSize: thumbnailSize,
            scale: 1
        ))
        XCTAssertTrue(hasPixelsDifferentFromBackground(in: image))
    }

    @MainActor
    func testSourceThumbnailUsesResolvedThemeAndSyntaxColors() throws {
        let source = "// note\nlet label = \"Glimt\"\n"
        let analysis = Self.analysis(for: source)
        let document = try SourceCodeInspector.inspect(analysis: analysis, language: .swift)
        let palette = SourceThemePalette(
            background: .init(red: 0.08, green: 0.10, blue: 0.12),
            foreground: .init(red: 0.95, green: 0.95, blue: 0.95),
            comment: .init(red: 0.10, green: 0.85, blue: 0.80),
            keyword: .init(red: 0.95, green: 0.20, blue: 0.65),
            string: .init(red: 0.95, green: 0.75, blue: 0.15),
            number: .init(red: 0.25, green: 0.65, blue: 0.95),
            type: .init(red: 0.60, green: 0.45, blue: 0.95),
            directive: .init(red: 0.95, green: 0.45, blue: 0.15)
        )
        let configuration = SourceRenderConfiguration(
            lightTheme: .neutral,
            darkTheme: .neutral,
            lightPalette: palette,
            darkPalette: palette
        )

        let image = try XCTUnwrap(ThumbnailRenderer.render(
            analysis: analysis,
            sourceDocument: document,
            sourceConfiguration: configuration,
            appearance: .dark,
            maximumSize: thumbnailSize,
            scale: 1
        ))

        XCTAssertTrue(imageContains(palette.background, in: image))
        XCTAssertTrue(imageContains(palette.comment, in: image))
        XCTAssertTrue(imageContains(palette.keyword, in: image))
        XCTAssertTrue(imageContains(palette.string, in: image))
    }

    @MainActor
    func testLongInputStopsAtInsetContentRectAndClipsAllInkToIt() throws {
        let text = (1...100).map { "line-\($0)" }.joined(separator: "\n")
        let analysis = Self.analysis(for: text)
        let visibleLines = ThumbnailRenderer.renderedLines(
            for: analysis,
            maximumSize: thumbnailSize,
            scale: 1
        )
        XCTAssertGreaterThan(visibleLines.count, 1)
        XCTAssertLessThan(visibleLines.count, 100)
        XCTAssertEqual(visibleLines, (1...visibleLines.count).map { "line-\($0)" })

        let image = try XCTUnwrap(
            ThumbnailRenderer.render(analysis: analysis, maximumSize: thumbnailSize, scale: 1)
        )
        XCTAssertTrue(hasPixelsDifferentFromBackground(in: image))
        XCTAssertTrue(allInkIsInsideInsetContentRect(in: image, inset: 13))
    }

    /// The thumbnail follows Quick Look's word wrap: Off truncates one row, Soft continues on the next rows.
    @MainActor
    func testThumbnailWrapsLikeQuickLook() throws {
        let analysis = Self.analysis(for: String(repeating: "wrap me ", count: 40))
        func lowestInkRow(_ mode: WordWrapMode) throws -> Int {
            let configuration = SourceRenderConfiguration(
                showLineNumbers: false, wrapMode: mode, lineLength: 120, tabsToSpaces: 4,
                fontFamily: "System Monospaced", fontSize: 12, lightTheme: .glimtDefault, darkTheme: .glimtDefault,
                lightPalette: nil, darkPalette: nil, indentationGuides: false)
            let image = try XCTUnwrap(ThumbnailRenderer.render(analysis: analysis, sourceConfiguration: configuration,
                                                               appearance: .light, maximumSize: thumbnailSize, scale: 1))
            return lowestInkRowIndex(in: image)
        }
        let truncated = try lowestInkRow(.off)
        let wrapped = try lowestInkRow(.soft)
        XCTAssertLessThan(truncated, 40)
        XCTAssertGreaterThan(wrapped, truncated + 20)
    }

    @MainActor
    func testNewlineDenseInputOnlyScansThumbnailVisibleLines() throws {
        let text = "x\n" + String(repeating: "a\n", count: 131_071)
        let analysis = Self.analysis(for: text)
        XCTAssertEqual(analysis.text.utf8.count, 262_144)

        let pointSize: CGFloat = 10
        let font = CTFontCreateWithName(NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular).fontName as CFString,
                                        pointSize, nil)
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        let contentRect = CGRect(origin: .zero, size: thumbnailSize).insetBy(dx: 13, dy: 13)
        let selection = ThumbnailRenderer.visibleSourceLines(
            in: analysis.text,
            contentRect: contentRect,
            fontAscent: ascent,
            lineHeight: lineHeight,
            lineSpacing: 3
        )

        XCTAssertEqual(selection.lines.first?.text, "x")
        XCTAssertLessThan(selection.scannedLineCount, 64)
        XCTAssertLessThanOrEqual(selection.scannedLineCount, selection.lines.count)
    }

    @MainActor
    func testEmptyTextProducesOnlyTheBackground() throws {
        let analysis = Self.analysis(for: "")

        XCTAssertEqual(
            ThumbnailRenderer.renderedLines(for: analysis, maximumSize: thumbnailSize, scale: 1),
            []
        )
        let image = try renderedImage(for: analysis)
        XCTAssertFalse(hasPixelsDifferentFromBackground(in: image))
    }

    @MainActor
    func testEmptyFirstLineProducesOnlyTheBackground() throws {
        let analysis = Self.analysis(for: "\nalpha")

        XCTAssertEqual(
            ThumbnailRenderer.renderedLines(for: analysis, maximumSize: thumbnailSize, scale: 1),
            []
        )
        let image = try renderedImage(for: analysis)
        XCTAssertFalse(hasPixelsDifferentFromBackground(in: image))
    }

    @MainActor
    func testBinaryAnalysisWithoutSemanticModelReturnsNoThumbnail() {
        let bytes = Data([0x00, 0x01, 0x02])
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 262_144)

        XCTAssertTrue(analysis.isBinary)
        XCTAssertEqual(
            ThumbnailRenderer.renderedLines(for: analysis, maximumSize: thumbnailSize, scale: 1),
            []
        )
        XCTAssertNil(ThumbnailRenderer.render(analysis: analysis, maximumSize: thumbnailSize, scale: 1))
    }

    @MainActor
    func testTrailingNewlineDoesNotCreateAnExtraVisibleLine() throws {
        let analysis = Self.analysis(for: "alpha\n")

        XCTAssertEqual(
            ThumbnailRenderer.renderedLines(for: analysis, maximumSize: thumbnailSize, scale: 1),
            ["alpha"]
        )
        let image = try renderedImage(for: analysis)
        XCTAssertTrue(hasPixelsDifferentFromBackground(in: image))
    }

    func testPreparationReportsResolverResultsAndCompleteEvidence() {
        let cases: [(String, Data, String?, String, Double)] = [
            ("Makefile", Data("all:\n".utf8), nil, "make", 1.0),
            ("foo.d.ts", Data("declare const x: string;\n".utf8), nil, "typescript-declaration", 0.98),
            ("app.local", Data("KEY=value\n".utf8), nil, "generic-local", 0.95),
            ("config", Data("---\na: 1\nb: 2\n".utf8), nil, "yaml", 0.80),
            ("script", Data("#!/usr/bin/env python3\nprint(1)\n".utf8), nil, "python", 0.90),
            ("unknown", Data("plain words\n".utf8), nil, "unknown", 0),
            ("foo.ts", Data("const x: number = 1;\n".utf8), "public.mpeg-2-transport-stream", "typescript", 0.95)
        ]

        for (name, bytes, uti, expectedType, expectedConfidence) in cases {
            let preparation = ThumbnailPreparation.prepare(
                bytes: bytes,
                fileSize: bytes.count,
                fileName: name,
                systemUTI: uti
            )
            let expected = TypeResolver().resolve(
                fileName: name,
                leadingBytes: Data(bytes.prefix(65_536)),
                systemUTI: uti,
                sampleIsComplete: true
            )
            XCTAssertEqual(preparation.resolution, expected, name)
            XCTAssertEqual(preparation.resolution.typeID, expectedType, name)
            XCTAssertEqual(preparation.resolution.confidence.value, expectedConfidence, accuracy: 0.000_001, name)
            XCTAssertEqual(preparation.resolution.evidence.count, uti == "public.mpeg-2-transport-stream" ? 8 : 7, name)
            XCTAssertEqual(preparation.sampleByteCount, bytes.count, name)
            XCTAssertTrue(preparation.sampleIsComplete, name)
        }
    }

#if DEBUG
    func testThumbnailProviderMarkerAcceptsEveryCatalogFormat() {
        let scores: [(DetectionEvidence.SignalKind, Double)] = [
            (.filename, 1), (.multiExtension, 0), (.singleExtension, 0), (.shebang, 0),
            (.yamlMapping, 0), (.yamlDocumentMarker, 0), (.systemUTI, 0)
        ]

        for format in FormatID.allCases {
            let marker = ThumbnailProviderMarkerSerializer.serialize(
                token: "01234567-89ab-cdef-0123-456789abcdef",
                provider: "thumbnail",
                phase: "reply-prepared",
                typeID: format.rawValue,
                confidence: 1,
                scores: scores,
                sampleByteCount: 8,
                sampleIsComplete: true,
                elapsedMilliseconds: 1
            )
            XCTAssertNotNil(marker, format.rawValue)
        }
    }

    func testThumbnailProviderMarkerSerializesValidPrimitiveInput() {
        let scores: [(DetectionEvidence.SignalKind, Double)] = [
            (.filename, 1),
            (.multiExtension, 0),
            (.singleExtension, 0),
            (.shebang, 0),
            (.yamlMapping, 0.75),
            (.yamlDocumentMarker, 0.80),
            (.systemUTI, 0)
        ]

        XCTAssertEqual(
            ThumbnailProviderMarkerSerializer.serialize(
                token: "01234567-89ab-cdef-0123-456789abcdef",
                provider: "thumbnail",
                phase: "reply-prepared",
                typeID: "makefile",
                confidence: 1,
                scores: scores,
                sampleByteCount: 917,
                sampleIsComplete: true,
                elapsedMilliseconds: 42
            ),
            "FR005_PROVIDER_V1 token=01234567-89ab-cdef-0123-456789abcdef provider=thumbnail phase=reply-prepared type=makefile confidence=1.00 scores=1.00,0.00,0.00,0.00,0.75,0.80,0.00 sampleBytes=917 complete=1 elapsedMs=42"
        )
    }

    func testThumbnailProviderMarkerRejectsInvalidPrimitiveInputs() {
        let validToken = "01234567-89ab-cdef-0123-456789abcdef"
        let validScores: [(DetectionEvidence.SignalKind, Double)] = [
            (.filename, 1), (.multiExtension, 0), (.singleExtension, 0), (.shebang, 0),
            (.yamlMapping, 0.75), (.yamlDocumentMarker, 0.80), (.systemUTI, 0)
        ]
        var token = validToken
        var type = "makefile"
        var confidence = 1.0
        var scores = validScores
        var sampleBytes = 917
        var elapsedMilliseconds = 42
        var provider = "thumbnail"
        var phase = "reply-prepared"
        func serialize() -> String? {
            ThumbnailProviderMarkerSerializer.serialize(
                token: token,
                provider: provider,
                phase: phase,
                typeID: type,
                confidence: confidence,
                scores: scores,
                sampleByteCount: sampleBytes,
                sampleIsComplete: true,
                elapsedMilliseconds: elapsedMilliseconds
            )
        }

        for malformed in [
            "01234567-89AB-cdef-0123-456789abcdef",
            "01234567-89ab-cdef-0123-456789abcde\n",
            "{01234567-89ab-cdef-0123-456789abcdef}",
            "0123456789abcdef0123456789abcdef"
        ] {
            token = malformed
            XCTAssertNil(serialize())
        }
        token = validToken
        type = "public.python-script"
        XCTAssertNil(serialize())
        type = "makefile"
        provider = "preview"
        XCTAssertNil(serialize())
        provider = "thumbnail"
        phase = "display-prepared"
        XCTAssertNil(serialize())
        phase = "reply-prepared"
        for invalidConfidence in [Double.nan, .infinity, -.infinity, -0.000_001, 1.000_001] {
            confidence = invalidConfidence
            XCTAssertNil(serialize())
        }
        confidence = 1
        for invalidSampleBytes in [-1, 65_537] {
            sampleBytes = invalidSampleBytes
            XCTAssertNil(serialize())
        }
        sampleBytes = 917
        for invalidElapsedMilliseconds in [-1, 60_001] {
            elapsedMilliseconds = invalidElapsedMilliseconds
            XCTAssertNil(serialize())
        }
        elapsedMilliseconds = 42
        scores = Array(validScores.dropLast())
        XCTAssertNil(serialize())
        scores = validScores + [(.filename, 0)]
        XCTAssertNil(serialize())
        scores = validScores.map { ($0.0, $0.0 == .systemUTI ? Double.nan : $0.1) }
        XCTAssertNil(serialize())
        scores = validScores.map { ($0.0, $0.0 == .systemUTI ? 1.01 : $0.1) }
        XCTAssertNil(serialize())
    }

    func testThumbnailProviderMarkerRoundsToHundredthsAndUsesFixedSignalOrder() {
        let scores: [(DetectionEvidence.SignalKind, Double)] = [
            (.systemUTI, 1), (.yamlDocumentMarker, 0.0151), (.yamlMapping, 0.0149),
            (.shebang, 0.005), (.singleExtension, -0.0), (.multiExtension, 0), (.filename, 0)
        ]
        let marker = ThumbnailProviderMarkerSerializer.serialize(
            token: "01234567-89ab-cdef-0123-456789abcdef",
            provider: "thumbnail",
            phase: "reply-prepared",
            typeID: "unknown",
            confidence: 0.125,
            scores: scores + [(.utiConflict, .nan)],
            sampleByteCount: 65_536,
            sampleIsComplete: false,
            elapsedMilliseconds: 17
        )
        XCTAssertEqual(
            marker,
            "FR005_PROVIDER_V1 token=01234567-89ab-cdef-0123-456789abcdef provider=thumbnail phase=reply-prepared type=unknown confidence=0.13 scores=0.00,0.00,0.00,0.01,0.01,0.02,1.00 sampleBytes=65536 complete=0 elapsedMs=17"
        )
    }

    func testThumbnailProviderTokenReaderRequiresAnExactCanonicalAttribute() throws {
        let url = try writeTemporaryFile(Data("content".utf8), named: "token-reader")
        XCTAssertNil(ThumbnailProviderMarkerSerializer.readToken(from: url))

        try setEvidenceAttribute(Data("01234567-89ab-cdef-0123-456789abcdef".utf8), at: url)
        XCTAssertEqual(ThumbnailProviderMarkerSerializer.readToken(from: url), "01234567-89ab-cdef-0123-456789abcdef")
        try setEvidenceAttribute(Data("01234567-89AB-cdef-0123-456789abcdef".utf8), at: url)
        XCTAssertNil(ThumbnailProviderMarkerSerializer.readToken(from: url))
        try setEvidenceAttribute(Data(repeating: 0x61, count: 37), at: url)
        XCTAssertNil(ThumbnailProviderMarkerSerializer.readToken(from: url))
        try setEvidenceAttribute(Data(repeating: 0x61, count: 38), at: url)
        XCTAssertNil(ThumbnailProviderMarkerSerializer.readToken(from: url))
        try setEvidenceAttribute(Data([0xFF]), at: url)
        XCTAssertNil(ThumbnailProviderMarkerSerializer.readToken(from: url))
    }

    func testThumbnailProviderObservesConstructedReplyBeforeHandlerOffMain() async throws {
        let url = try writeTemporaryFile(Data("---\na: 1\nb: 2\n".utf8), named: "Makefile")
        let recorder = ThumbnailProviderObservationRecorder()
        let provenanceRecorder = ThumbnailProvenanceRecorder()
        let tokenReadCounter = ThumbnailTokenReadCounter()
        let completed = expectation(description: "Thumbnail callback completes")
        let size = thumbnailSize
        DispatchQueue.global().async {
            let provider = ThumbnailProvider(debugDependencies: ThumbnailProviderDebugDependencies(
                tokenReader: { _ in
                    tokenReadCounter.increment()
                    return "01234567-89ab-cdef-0123-456789abcdef"
                },
                contentTypeIdentifier: { _ in nil },
                markerObserver: { marker, reply in recorder.observe(marker, reply: reply) },
                provenanceObserver: { provenanceRecorder.append($0) },
                runtimeIdentity: {
                    QuickLookProviderRuntimeIdentity(
                        extensionBundleURL: URL(fileURLWithPath: "/Applications/Glimt.app/Contents/PlugIns/GlimtThumbnail.appex"),
                        extensionBundleIdentifier: "com.glimt.app.thumbnail",
                        appBundleIdentifier: "com.glimt.app",
                        appVersion: "2.4",
                        appBuild: "204"
                    )
                }
            ))
            provider.provideThumbnail(at: url, maximumSize: size, scale: 1) { reply, error in
                recorder.complete(reply: reply, error: error)
                completed.fulfill()
            }
        }

        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(recorder.markers.count, 1)
        XCTAssertNil(recorder.errorDescription)
        XCTAssertEqual(recorder.events, ["marker", "completion"])
        XCTAssertEqual(recorder.observedReplyID, recorder.completedReplyID)
        XCTAssertFalse(recorder.markerOnMainThread)
        XCTAssertEqual(tokenReadCounter.value, 1)
        XCTAssertEqual(provenanceRecorder.values.count, 1)
        XCTAssertTrue(provenanceRecorder.values[0].contains("provider=thumbnail phase=request-received"))
        XCTAssertTrue(provenanceRecorder.values[0].contains("extensionID=com.glimt.app.thumbnail"))
        XCTAssertFalse(provenanceRecorder.values[0].contains(url.path))
    }

    @MainActor
    func testConcurrentThumbnailRequestsCompleteWithIsolatedReplies() async throws {
        let requestCount = 12
        let recorder = ConcurrentThumbnailResultRecorder(requestCount: requestCount)
        let completed = expectation(description: "Concurrent thumbnail callbacks")
        completed.expectedFulfillmentCount = requestCount
        let inputs = try (0..<requestCount).map { index in
            try writeTemporaryFile(
                Data("// File \(index)\nlet value = \(index)\nprint(value)\n".utf8),
                named: "Example-\(index).swift"
            )
        }
        let sizes: [CGSize] = [
            CGSize(width: 64, height: 64), CGSize(width: 96, height: 72),
            CGSize(width: 128, height: 96), CGSize(width: 256, height: 128)
        ]
        // Quick Look calls one provider from many threads; the test reproduces that sharing on purpose.
        nonisolated(unsafe) let provider = ThumbnailProvider(debugDependencies: ThumbnailProviderDebugDependencies(
            contentTypeIdentifier: { _ in nil }
        ))

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: requestCount) { index in
                provider.provideThumbnail(
                    at: inputs[index],
                    maximumSize: sizes[index % sizes.count],
                    scale: index.isMultiple(of: 2) ? 1 : 2
                ) { reply, error in
                    recorder.record(index: index, reply: reply, error: error)
                    completed.fulfill()
                }
            }
        }

        await fulfillment(of: [completed], timeout: 20)
        XCTAssertEqual(recorder.callbackCounts, Array(repeating: 1, count: requestCount))
        XCTAssertEqual(recorder.replyIdentifiers.count, requestCount)
        XCTAssertEqual(Set(recorder.replyIdentifiers).count, requestCount)
        XCTAssertTrue(recorder.errors.allSatisfy { $0 == nil }, "Every supported independent request must produce a reply")
    }

    @MainActor
    func testThumbnailProviderFailuresEmitProvenanceWithoutFR005MarkerAndMainThreadSkipsTokenRead() async throws {
        let tokenCalls = ThumbnailProviderCallCounter()
        let failedRecorder = ThumbnailProviderObservationRecorder()
        let provenanceRecorder = ThumbnailProvenanceRecorder()
        let missingURL = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("missing")
        let missingCompleted = expectation(description: "Missing thumbnail input fails")
        let size = thumbnailSize
        DispatchQueue.global().async {
            let failingProvider = ThumbnailProvider(debugDependencies: ThumbnailProviderDebugDependencies(
                tokenReader: { _ in tokenCalls.increment(); return "01234567-89ab-cdef-0123-456789abcdef" },
                markerObserver: { marker, reply in failedRecorder.observe(marker, reply: reply) },
                provenanceObserver: { provenanceRecorder.append($0) }
            ))
            failingProvider.provideThumbnail(at: missingURL, maximumSize: size, scale: 1) { reply, error in
                failedRecorder.complete(reply: reply, error: error)
                missingCompleted.fulfill()
            }
        }
        await fulfillment(of: [missingCompleted], timeout: 5)
        XCTAssertNotNil(failedRecorder.errorDescription)
        XCTAssertTrue(failedRecorder.markers.isEmpty)
        XCTAssertEqual(tokenCalls.value, 1)
        XCTAssertEqual(provenanceRecorder.values.count, 1)
        XCTAssertTrue(provenanceRecorder.values[0].contains("provider=thumbnail phase=request-received"))

        let bytes = Data("plain words\n".utf8)
        let renderFailureURL = try writeTemporaryFile(bytes, named: "render-failure")
        let renderFailureRecorder = ThumbnailProviderObservationRecorder()
        let renderFailed = expectation(description: "Injected render failure has no marker")
        DispatchQueue.global().async {
            let renderFailureProvider = ThumbnailProvider(debugDependencies: ThumbnailProviderDebugDependencies(
                tokenReader: { _ in tokenCalls.increment(); return "01234567-89ab-cdef-0123-456789abcdef" },
                renderer: { _, _, _, _, _ in nil },
                markerObserver: { marker, reply in renderFailureRecorder.observe(marker, reply: reply) },
                provenanceObserver: { provenanceRecorder.append($0) }
            ))
            renderFailureProvider.provideThumbnail(at: renderFailureURL, maximumSize: size, scale: 1) { reply, error in
                renderFailureRecorder.complete(reply: reply, error: error)
                renderFailed.fulfill()
            }
        }
        await fulfillment(of: [renderFailed], timeout: 5)
        XCTAssertNotNil(renderFailureRecorder.errorDescription)
        XCTAssertTrue(renderFailureRecorder.markers.isEmpty)
        XCTAssertEqual(tokenCalls.value, 2)
        XCTAssertEqual(provenanceRecorder.values.count, 2)

        let mainThreadCalls = ThumbnailProviderCallCounter()
        let mainThreadRecorder = ThumbnailProviderObservationRecorder()
        let mainThreadProvenance = ThumbnailProvenanceRecorder()
        let mainThreadProvider = ThumbnailProvider(debugDependencies: ThumbnailProviderDebugDependencies(
            tokenReader: { _ in mainThreadCalls.increment(); return "01234567-89ab-cdef-0123-456789abcdef" },
            contentTypeIdentifier: { _ in nil },
            markerObserver: { marker, reply in mainThreadRecorder.observe(marker, reply: reply) },
            provenanceObserver: { mainThreadProvenance.append($0) }
        ))
        let mainURL = try writeTemporaryFile(bytes, named: "main-thread")
        mainThreadProvider.provideThumbnail(at: mainURL, maximumSize: thumbnailSize, scale: 1) { reply, error in
            XCTAssertNil(error)
            XCTAssertNotNil(reply)
            mainThreadRecorder.complete(reply: reply, error: error)
        }
        XCTAssertEqual(mainThreadCalls.value, 0)
        XCTAssertTrue(mainThreadRecorder.markers.isEmpty)
        XCTAssertTrue(mainThreadProvenance.values.isEmpty)
    }
#endif

    func testPreparationCompletenessAndConfirmedEOFVectors() {
        let boundaryVectors: [(Data, Int, Int, Bool)] = [
            (Data(), 0, 0, true),
            (Data(repeating: 0x61, count: 65_536), 65_536, 65_536, true),
            (Data(repeating: 0x61, count: 65_537), 65_537, 65_536, false),
            (Data(repeating: 0x61, count: 10), 11, 10, false),
            (Data(repeating: 0x61, count: 11), 10, 11, false)
        ]
        for (bytes, fileSize, sampleCount, complete) in boundaryVectors {
            let result = ThumbnailPreparation.prepare(bytes: bytes, fileSize: fileSize, fileName: "unknown", systemUTI: nil)
            XCTAssertEqual(result.sampleByteCount, sampleCount)
            XCTAssertEqual(result.sampleIsComplete, complete)
            XCTAssertEqual(result.resolution.typeID, "unknown")
        }

        let shebang = Data("#!/usr/bin/env python3".utf8)
        let padded = shebang + Data(repeating: 0x20, count: 65_536 - shebang.count)
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: padded, fileSize: padded.count, fileName: "script", systemUTI: nil).resolution.confidence.value, 0.90)
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: padded, fileSize: padded.count + 1, fileName: "script", systemUTI: nil).resolution.typeID, "unknown")
        let terminatedIncomplete = Data("#!/usr/bin/env python3\n".utf8) + Data(repeating: 0x61, count: 10)
        XCTAssertEqual(ThumbnailPreparation.prepare(
            bytes: terminatedIncomplete,
            fileSize: terminatedIncomplete.count + 1,
            fileName: "script",
            systemUTI: nil
        ).resolution.typeID, "python")

        var lastByteLF = Data("#!/usr/bin/env python3".utf8)
        lastByteLF.append(Data(repeating: 0x20, count: 65_535 - lastByteLF.count))
        lastByteLF.append(0x0A)
        XCTAssertEqual(lastByteLF.count, 65_536)
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: lastByteLF, fileSize: lastByteLF.count, fileName: "script", systemUTI: nil).resolution.typeID, "python")

        let beyondSampleLF = shebang + Data(repeating: 0x20, count: 65_536 - shebang.count) + Data([0x0A])
        XCTAssertEqual(ThumbnailPreparation.prepare(bytes: beyondSampleLF, fileSize: beyondSampleLF.count, fileName: "script", systemUTI: nil).resolution.typeID, "unknown")
    }

    func testReadFallsBackWhenUTIMetadataIsUnavailableAndThrowsForMissingFile() throws {
        let url = try writeTemporaryFile(Data("plain words\n".utf8), named: "unknown")
        let nilUTI = try ThumbnailPreparation.read(at: url) { _ in nil }
        let throwingUTI = try ThumbnailPreparation.read(at: url) { _ in throw CocoaError(.fileReadUnknown) }
        XCTAssertEqual(nilUTI.resolution.typeID, "unknown")
        XCTAssertEqual(throwingUTI.resolution.typeID, "unknown")
        XCTAssertEqual(nilUTI.resolution, TypeResolver().resolve(
            fileName: url.lastPathComponent,
            leadingBytes: Data("plain words\n".utf8),
            systemUTI: nil,
            sampleIsComplete: true
        ))
        XCTAssertThrowsError(try ThumbnailPreparation.read(at: url.appendingPathComponent("missing")))
    }

    func testReadRejectsFIFOWithoutBlocking() throws {
        let fifo = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("stream")
        let result = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(result, 0, "mkfifo errno=\(errno)")
        assertReadThrowsWithinTimeout { _ = try ThumbnailPreparation.read(at: fifo) }
        let symlink = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("stream-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fifo)
        assertReadThrowsWithinTimeout { _ = try ThumbnailPreparation.read(at: symlink) }
    }

    func testTimeLimitedReadWithinTheLimitMatchesTheSynchronousRead() throws {
        let url = try writeTemporaryFile(Data(#"{"name": "glimt"}"#.utf8), named: "config.json")
        let timed = try ThumbnailPreparation.read(at: url, timeLimit: .seconds(30)) { _ in nil }
        let direct = try ThumbnailPreparation.read(at: url) { _ in nil }
        XCTAssertEqual(timed.resolution, direct.resolution)
        XCTAssertEqual(timed.thumbnailText, direct.thumbnailText)
    }

    func testThumbnailTimeoutDuringContinuationUsesLatestPublishedBytes() throws {
        let url = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("continuing.txt")
        try Data(repeating: 0x61, count: 100_000).write(to: url)
        let gate = ThumbnailSnapshotGate()
        let events = ThumbnailReadEventRecorder()
        let inspection = ThumbnailInspectionRecorder()
        let outcome = ThumbnailPreparationReadOutcome()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completed.signal() }
            do {
                let result = try ThumbnailPreparation.read(at: url, timeLimit: .seconds(2),
                    contentTypeIdentifier: { _ in nil }, observe: { events.append($0) },
                    inspectionObserver: { inspection.store($0) }, snapshotObserver: { snapshot in
                        if snapshot.retainedBytes.count > snapshot.routingByteCount {
                            gate.block()
                            gate.recordCancellation(Task.isCancelled)
                        }
                    })
                outcome.store(.success(result))
            } catch {
                outcome.store(.failure(error))
            }
        }
        XCTAssertTrue(gate.waitUntilEntered(), "The continuation snapshot must be published before the deadline")
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        gate.release()
        XCTAssertTrue(gate.waitUntilReleased())
        XCTAssertTrue(gate.waitForCancellation())
        XCTAssertTrue(events.waitForContinuation())
        let result = try XCTUnwrap(outcome.result?.get())
        XCTAssertEqual(result.readByteCount, 100_000)
        XCTAssertEqual(result.selectedInspectorID, .text)
        let diagnostics = try XCTUnwrap(inspection.value).inspectionDiagnostics
        XCTAssertEqual(diagnostics.map(\.code), [.limitExceeded])
        XCTAssertEqual(diagnostics.first?.message, "Inspection took too long; showing raw content")
        XCTAssertEqual(events.values.filter { if case .selectionCommitted = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.values.filter { if case .continuationAppended = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.values.compactMap { event -> Int? in
            guard case .read(let offset, _, let returned, _) = event, returned > 0 else { return nil }
            return offset
        }, [0, 65_536])
        XCTAssertFalse(events.values.contains { if case .dispatchStarted = $0 { return true }; return false })
    }

    func testInspectionPastTheThumbnailLimitFallsBackToTheReadPrefix() throws {
        let text = #"{"name": "glimt"}"#
        let url = try writeTemporaryFile(Data(text.utf8), named: "config.json")
        let started = Date()
        let preparation = try ThumbnailPreparation.read(at: url, timeLimit: .milliseconds(50),
                                                        contentTypeIdentifier: { _ in nil }, prepare: { _, _ in
            while !Task.isCancelled { usleep(1_000) }
            throw CancellationError()
        })
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "The request must not wait for the inspector")
        let direct = try ThumbnailPreparation.read(at: url) { _ in nil }
        XCTAssertEqual(preparation.resolution, direct.resolution, "The fallback keeps the selected route")
        XCTAssertEqual(preparation.analysis.fileSize, text.utf8.count)
        XCTAssertNil(preparation.csvInspection)
    }

    func testThumbnailReadThatCannotFinishBeforeTheLimitThrowsTimeout() throws {
        let url = try writeTemporaryFile(Data("plain".utf8), named: "notes.txt")
        XCTAssertThrowsError(try ThumbnailPreparation.read(at: url, timeLimit: .milliseconds(50), contentTypeIdentifier: { _ in
            while !Task.isCancelled { usleep(1_000) }
            return nil
        })) { XCTAssertTrue($0 is InspectionWatchdog.TimeoutError) }
    }

    func testReadKeepsAnalysisBoundedAtThumbnailCeiling() throws {
        for (count, truncated) in [
            (ThumbnailPreparation.maximumPrefixBytes, false),
            (ThumbnailPreparation.maximumPrefixBytes + 1, true)
        ] {
            let bytes = Data(repeating: 0x61, count: count)
            let url = try writeTemporaryFile(bytes, named: "unknown-\(count)")
            let preparation = try ThumbnailPreparation.read(at: url) { _ in nil }
            XCTAssertEqual(preparation.analysis.text.utf8.count, ThumbnailPreparation.maximumPrefixBytes)
            XCTAssertEqual(preparation.analysis.truncated, truncated)
            XCTAssertEqual(preparation.sampleByteCount, 65_536)
            XCTAssertFalse(preparation.sampleIsComplete)
            XCTAssertEqual(preparation.readByteCount, ThumbnailPreparation.maximumPrefixBytes)
            XCTAssertNil(preparation.systemUTI)
        }
    }

    @MainActor
    func testBinaryJSONWithoutSemanticInspectionReturnsNoThumbnail() {
        let bytes = Data([0x7B, 0x00, 0x01, 0x7D])
        let preparation = ThumbnailPreparation.prepare(bytes: bytes, fileSize: bytes.count, fileName: "sample.json", systemUTI: nil)
        XCTAssertTrue(preparation.analysis.isBinary)
        XCTAssertEqual(preparation.resolution.typeID, "json")
        XCTAssertNil(ThumbnailRenderer.render(analysis: preparation.analysis, maximumSize: thumbnailSize, scale: 1))
    }

    func testFR005RealInputs() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FR005_REQUIRE_REAL_INPUT"] != nil || environment["FR005_REAL_INPUT_DIR"] != nil else {
            throw XCTSkip("Real adapter inputs are not configured")
        }
        guard environment["FR005_REQUIRE_REAL_INPUT"] == "1",
              let directoryPath = environment["FR005_REAL_INPUT_DIR"],
              directoryPath.hasPrefix("/") else {
            XCTFail("Supplied real-input mode requires FR005_REQUIRE_REAL_INPUT=1 and an absolute FR005_REAL_INPUT_DIR")
            return
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let yamlSource = directory.appendingPathComponent("fr005b-tapioca.yml")
        let pythonSource = directory.appendingPathComponent("glib-mkenums")
        let yaml = try Data(contentsOf: yamlSource, options: .mappedIfSafe)
        let python = try Data(contentsOf: pythonSource, options: .mappedIfSafe)
        XCTAssertEqual(yaml.count, 917)
        XCTAssertEqual(Self.sha256(yaml), "0cca808009e7f0b76c4667cd211f0b196aa97b25e489cbb8a09aa472f5b68adb")
        XCTAssertEqual(python.count, 32_278)
        XCTAssertEqual(Self.sha256(python), "6b144d7044beeddcde563f4588cd7e3aed74f4dbc9198af1223b2993de9a9ea5")

        let configURL = try writeTemporaryFile(yaml, named: "config")
        let scriptURL = try writeTemporaryFile(python, named: "script")
        let tsURL = try writeTemporaryFile(yaml, named: "foo.ts")
        let makefileURL = try writeTemporaryFile(yaml, named: "Makefile")
        assertRealResult(try ThumbnailPreparation.read(at: configURL) { _ in nil }, type: "yaml", confidence: 0.80, scores: [0, 0, 0, 0, 0.75, 0.80, 0])
        assertRealResult(try ThumbnailPreparation.read(at: scriptURL) { _ in nil }, type: "python", confidence: 0.90, scores: [0, 0, 0, 0.90, 0, 0, 0])
        assertRealResult(try ThumbnailPreparation.read(at: tsURL) { _ in nil }, type: "typescript", confidence: 0.95, scores: [0, 0, 0.95, 0, 0.75, 0.80, 0])
        assertRealResult(try ThumbnailPreparation.read(at: makefileURL) { _ in "public.make-source" }, type: "makefile", confidence: 1.0, scores: [1, 0, 0, 0, 0.75, 0.80, 0])
        XCTAssertFalse(try ThumbnailPreparation.read(at: makefileURL) { _ in "public.make-source" }.resolution.evidence.contains { $0.signalKind == .utiConflict })

        let defaultPreparation = try ThumbnailPreparation.read(at: configURL)
        let actualUTI = try configURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
        XCTAssertEqual(defaultPreparation.resolution, TypeResolver().resolve(
            fileName: configURL.lastPathComponent,
            leadingBytes: Data(yaml.prefix(65_536)),
            systemUTI: actualUTI,
            sampleIsComplete: true
        ))
#if DEBUG
        let yamlToken = UUID().uuidString.lowercased()
        let pythonToken = UUID().uuidString.lowercased()
        try setEvidenceAttribute(Data(yamlToken.utf8), at: makefileURL)
        let pythonMakefileDirectory = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent("python-input", isDirectory: true)
        try FileManager.default.createDirectory(at: pythonMakefileDirectory, withIntermediateDirectories: true)
        let pythonMakefileURL = pythonMakefileDirectory.appendingPathComponent("Makefile")
        try python.write(to: pythonMakefileURL)
        try setEvidenceAttribute(Data(pythonToken.utf8), at: pythonMakefileURL)
        XCTAssertEqual(ThumbnailProviderMarkerSerializer.readToken(from: makefileURL), yamlToken)
        XCTAssertEqual(ThumbnailProviderMarkerSerializer.readToken(from: pythonMakefileURL), pythonToken)

        let yamlProviderRecorder = await inspectThumbnailProvider(at: makefileURL, systemUTI: "public.yaml")
        XCTAssertEqual(yamlProviderRecorder.markers, [
            "FR005_PROVIDER_V1 token=\(yamlToken) provider=thumbnail phase=reply-prepared type=makefile confidence=1.00 scores=1.00,0.00,0.00,0.00,0.75,0.80,0.60 sampleBytes=917 complete=1"
        ])
        XCTAssertEqual(yamlProviderRecorder.events, ["marker", "completion"])
        XCTAssertEqual(yamlProviderRecorder.observedReplyID, yamlProviderRecorder.completedReplyID)
        let pythonProviderRecorder = await inspectThumbnailProvider(at: pythonMakefileURL, systemUTI: "public.python-script")
        XCTAssertEqual(pythonProviderRecorder.markers, [
            "FR005_PROVIDER_V1 token=\(pythonToken) provider=thumbnail phase=reply-prepared type=makefile confidence=1.00 scores=1.00,0.00,0.00,0.90,0.00,0.00,0.60 sampleBytes=32278 complete=1"
        ])
        XCTAssertEqual(pythonProviderRecorder.events, ["marker", "completion"])
        XCTAssertEqual(pythonProviderRecorder.observedReplyID, pythonProviderRecorder.completedReplyID)
        XCTAssertEqual(Self.sha256(try Data(contentsOf: makefileURL)), "0cca808009e7f0b76c4667cd211f0b196aa97b25e489cbb8a09aa472f5b68adb")
        XCTAssertEqual(Self.sha256(try Data(contentsOf: pythonMakefileURL)), "6b144d7044beeddcde563f4588cd7e3aed74f4dbc9198af1223b2993de9a9ea5")
#endif
        let receipt = XCTAttachment(string: "Thumbnail adapter received required FR-005 real-input vectors and fingerprints.")
        receipt.name = "Thumbnail adapter FR005_REQUIRE_REAL_INPUT=1 receipt"
        add(receipt)
    }

    private static func analysis(for text: String) -> TextAnalysis {
        let bytes = Data(text.utf8)
        return TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 262_144)
    }

    private func writeTemporaryFile(_ data: Data, named name: String) throws -> URL {
        let url = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeThumbnailTextBundle(manifest: Data, markdown: Data, name: String) throws -> URL {
        let root = try XCTUnwrap(temporaryDirectoryURL).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.write(to: root.appendingPathComponent("info.json"))
        try markdown.write(to: root.appendingPathComponent("text.md"))
        return root
    }

    private func readThumbnailAdapter(_ url: URL, useWatchdog: Bool) throws -> ThumbnailPreparation {
        if useWatchdog {
            return try ThumbnailPreparation.read(at: url, timeLimit: .seconds(5), contentTypeIdentifier: { _ in nil })
        }
        return try ThumbnailPreparation.read(at: url, contentTypeIdentifier: { _ in nil })
    }

    private func setEvidenceAttribute(_ value: Data, at url: URL) throws {
        let result: Int32 = url.withUnsafeFileSystemRepresentation { (path: UnsafePointer<Int8>?) -> Int32 in
            guard let path else { return -1 }
            return "com.glimt.fr005-evidence".withCString { (name: UnsafePointer<Int8>) -> Int32 in
                value.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
                    setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

#if DEBUG
    private func inspectThumbnailProvider(at url: URL, systemUTI: String) async -> ThumbnailProviderObservationRecorder {
        let recorder = ThumbnailProviderObservationRecorder()
        let completed = expectation(description: "Genuine thumbnail provider request completes")
        let size = thumbnailSize
        DispatchQueue.global().async {
            let provider = ThumbnailProvider(debugDependencies: ThumbnailProviderDebugDependencies(
                contentTypeIdentifier: { _ in systemUTI },
                markerObserver: { marker, reply in recorder.observe(marker, reply: reply) }
            ))
            provider.provideThumbnail(at: url, maximumSize: size, scale: 1) { reply, error in
                recorder.complete(reply: reply, error: error)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        return recorder
    }
#endif

    private func assertRealResult(
        _ preparation: ThumbnailPreparation,
        type: String,
        confidence: Double,
        scores: [Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(preparation.resolution.typeID, type, file: file, line: line)
        XCTAssertEqual(preparation.resolution.confidence.value, confidence, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(preparation.resolution.evidence.prefix(7).map(\.score.value), scores, file: file, line: line)
        XCTAssertEqual(preparation.sampleByteCount, min(preparation.analysis.fileSize, 65_536), file: file, line: line)
        XCTAssertTrue(preparation.sampleIsComplete, file: file, line: line)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func gitBlobSHA1(_ data: Data) -> String {
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func renderedImage(for analysis: TextAnalysis) throws -> CGImage {
        let image = try XCTUnwrap(
            ThumbnailRenderer.render(analysis: analysis, maximumSize: thumbnailSize, scale: 1)
        )
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        return image
    }

    @MainActor
    private func hasPixelsDifferentFromBackground(in image: CGImage) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) else {
            XCTFail("Could not resolve the semantic background color")
            return false
        }

        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colorDifference(color, background) > 0.02 {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    private func imageContains(_ source: SourceThemeColor, in image: CGImage) -> Bool {
        let expected = NSColor(srgbRed: source.red, green: source.green, blue: source.blue, alpha: source.alpha)
        let bitmap = NSBitmapImageRep(cgImage: image)
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let actual = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colorDifference(actual, expected) < 0.06 { return true }
            }
        }
        return false
    }

    /// Bottom-most bitmap row (from the top) that differs from the top-left background pixel.
    @MainActor
    private func lowestInkRowIndex(in image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return -1 }
        for y in stride(from: image.height - 1, through: 0, by: -1) {
            for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colorDifference(color, background) > 0.02 { return y }
            }
        }
        return -1
    }

    @MainActor
    private func allInkIsInsideInsetContentRect(in image: CGImage, inset: Int) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) else {
            XCTFail("Could not resolve the semantic background color")
            return false
        }

        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colorDifference(color, background) > 0.02 {
                    guard x >= inset, x < image.width - inset, y >= inset, y < image.height - inset else {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func assertReadThrowsWithinTimeout(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @Sendable () throws -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = BoundedThumbnailReadTestOutcome()
        DispatchQueue.global().async {
            do { try operation(); outcome.record(didThrow: false) }
            catch { outcome.record(didThrow: true) }
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(completed, "Special-file read did not return within two seconds", file: file, line: line)
        XCTAssertTrue(outcome.didThrow, "Special-file read should fail", file: file, line: line)
    }

    @MainActor
    private func colorDifference(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent)
            + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent)
    }
}

private final class ThumbnailReadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [RegularFileReadEvent] = []
    private let continuationAppended = DispatchSemaphore(value: 0)
    var values: [RegularFileReadEvent] { lock.lock(); defer { lock.unlock() }; return storedValues }
    func append(_ event: RegularFileReadEvent) {
        lock.lock()
        storedValues.append(event)
        lock.unlock()
        if case .continuationAppended = event { continuationAppended.signal() }
    }
    func waitForContinuation() -> Bool { continuationAppended.wait(timeout: .now() + 5) == .success }
}

private final class ThumbnailInspectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: PreviewInspectionResult?
    var value: PreviewInspectionResult? { lock.lock(); defer { lock.unlock() }; return storedValue }
    func store(_ value: PreviewInspectionResult) { lock.lock(); storedValue = value; lock.unlock() }
}

private final class ThumbnailTextBundleEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [TextBundleReadEvent] = []
    var values: [TextBundleReadEvent] { lock.lock(); defer { lock.unlock() }; return storedValues }
    var requestedReadCount: Int {
        values.reduce(into: 0) { count, event in
            if case .read = event { count += 1 }
        }
    }
    func append(_ event: TextBundleReadEvent) {
        lock.lock()
        storedValues.append(event)
        lock.unlock()
    }
}

private final class ThumbnailIntegerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int?
    var value: Int? { lock.lock(); defer { lock.unlock() }; return storedValue }
    func store(_ value: Int) { lock.lock(); storedValue = value; lock.unlock() }
}

private final class ThumbnailTextBundleSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ThumbnailTextBundleReadSnapshot?
    var value: ThumbnailTextBundleReadSnapshot? { lock.lock(); defer { lock.unlock() }; return storedValue }
    func store(_ value: ThumbnailTextBundleReadSnapshot) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class ThumbnailSnapshotGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)
    func block() {
        entered.signal()
        _ = releaseSignal.wait(timeout: .now() + 10)
        released.signal()
    }
    func recordCancellation(_ value: Bool) {
        if value { cancelled.signal() }
    }
    func release() { releaseSignal.signal() }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func waitUntilReleased() -> Bool { released.wait(timeout: .now() + 10) == .success }
    func waitForCancellation() -> Bool { cancelled.wait(timeout: .now() + 5) == .success }
}

private final class ThumbnailPreparationReadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<ThumbnailPreparation, Error>?
    var result: Result<ThumbnailPreparation, Error>? { lock.lock(); defer { lock.unlock() }; return storedResult }
    func store(_ result: Result<ThumbnailPreparation, Error>) { lock.lock(); storedResult = result; lock.unlock() }
}

private final class BoundedThumbnailReadTestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDidThrow = false
    var didThrow: Bool { lock.lock(); defer { lock.unlock() }; return storedDidThrow }
    func record(didThrow: Bool) { lock.lock(); storedDidThrow = didThrow; lock.unlock() }
}

private final class ThumbnailTokenReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

private final class ThumbnailProvenanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class ThumbnailProviderObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMarkers: [String] = []
    private var storedEvents: [String] = []
    private var storedObservedReplyID: ObjectIdentifier?
    private var storedCompletedReplyID: ObjectIdentifier?
    private var storedErrorDescription: String?
    private var storedMarkerOnMainThread = false

    var markers: [String] { withLock { storedMarkers } }
    var events: [String] { withLock { storedEvents } }
    var observedReplyID: ObjectIdentifier? { withLock { storedObservedReplyID } }
    var completedReplyID: ObjectIdentifier? { withLock { storedCompletedReplyID } }
    var errorDescription: String? { withLock { storedErrorDescription } }
    var markerOnMainThread: Bool { withLock { storedMarkerOnMainThread } }

    func observe(_ marker: String, reply: QLThumbnailReply) {
        lock.lock()
        storedMarkers.append(marker)
        storedEvents.append("marker")
        storedObservedReplyID = ObjectIdentifier(reply)
        storedMarkerOnMainThread = Thread.isMainThread
        lock.unlock()
    }

    func complete(reply: QLThumbnailReply?, error: Error?) {
        lock.lock()
        storedEvents.append("completion")
        storedCompletedReplyID = reply.map(ObjectIdentifier.init)
        storedErrorDescription = error.map(String.init(describing:))
        lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ThumbnailProviderCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }
}

private final class ConcurrentThumbnailResultRecorder: @unchecked Sendable {
    private let requestCount: Int
    private let lock = NSLock()
    private var storedCallbackCounts: [Int: Int] = [:]
    private var storedReplyIdentifiers: [Int: ObjectIdentifier] = [:]
    private var storedReplies: [Int: QLThumbnailReply] = [:]
    private var storedErrors: [Int: String?] = [:]

    init(requestCount: Int) { self.requestCount = requestCount }

    var callbackCounts: [Int] { withLock { (0..<requestCount).map { storedCallbackCounts[$0, default: 0] } } }
    var replyIdentifiers: [ObjectIdentifier] { withLock { storedReplyIdentifiers.keys.sorted().compactMap { storedReplyIdentifiers[$0] } } }
    var errors: [String?] { withLock { (0..<requestCount).map { storedErrors[$0] ?? nil } } }

    func record(index: Int, reply: QLThumbnailReply?, error: Error?) {
        withLock {
            storedCallbackCounts[index, default: 0] += 1
            if let reply {
                // Keep replies alive until assertions complete so allocator address reuse
                // cannot make distinct request results appear identical.
                storedReplies[index] = reply
                storedReplyIdentifiers[index] = ObjectIdentifier(reply)
            }
            storedErrors[index] = error.map(String.init(describing:))
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
