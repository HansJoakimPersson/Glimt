import CryptoKit
import Foundation
import XCTest
import InspectorCore
import UniformTypeIdentifiers

final class SettingsStoreTests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GlimtSettingsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: try XCTUnwrap(directory), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Verifies legacy mapping values retain their encoding and are validated against the current catalog.
    func testBaselineCustomMappingMigratesToCatalogIdentityWithoutChangingEncoding() throws {
        let baseline = Data("{\"kind\":\"fileExtension\",\"value\":\"foo\",\"target\":\"yaml\"}".utf8)
        let rule = try JSONDecoder().decode(FileAssociation.self, from: baseline)
        XCTAssertEqual(rule.target, FormatID.yaml)
        XCTAssertEqual(rule.target.inspectionOverride, .yaml)
        XCTAssertEqual(FormatID.mermaid.inspectionOverride, .mermaid)
        XCTAssertEqual(FileAssociation(kind: .fileExtension, value: "mmd", target: .mermaid).validated()?.target, .mermaid)
        XCTAssertEqual(try XCTUnwrap(rule.validated()).displayPattern, "*.foo")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: String]
        XCTAssertEqual(encoded?["target"], "yaml")
        XCTAssertNil(FileAssociation(kind: .fileExtension, value: "foo", target: .init(rawValue: "future-format")).validated())
        XCTAssertEqual(FileAssociation(kind: .fileExtension, value: "foo", target: .dockerfile).validated()?.target, .dockerfile)
        let elm = try XCTUnwrap(FileAssociation(kind: .fileExtension, value: "elm",
            target: FormatID(rawValue: "reference-elm")).validated())
        XCTAssertEqual(elm.target.rawValue, "reference-elm")
    }

    func testZIPMappingRequiresAZIPFilenameAndCertificateFormatsMapToTheirSharedInspector() throws {
        let zipExtension = try XCTUnwrap(FileAssociation(kind: .fileExtension, value: "*.ZIP", target: .zip).validated())
        XCTAssertEqual(zipExtension.value, "zip")
        XCTAssertTrue(zipExtension.matches("archive.ZIP"))
        XCTAssertFalse(zipExtension.matches("archive.docx"))

        let zipFilename = try XCTUnwrap(FileAssociation(kind: .filename, value: "signed.ZiP", target: .zip).validated())
        XCTAssertTrue(zipFilename.matches("signed.ZiP"))
        XCTAssertFalse(zipFilename.matches("signed.pdf"))
        XCTAssertNil(FileAssociation(kind: .filename, value: "archive.pdf", target: .zip).validated())

        XCTAssertEqual(FormatID.pemCertificate.inspectionOverride, .certificate(.pemCertificate))
        XCTAssertEqual(FormatID.derCertificate.inspectionOverride, .certificate(.derCertificate))
        XCTAssertEqual(FormatID.mobileprovision.inspectionOverride, .security(.mobileprovision))
        XCTAssertEqual(FormatID.pkcs7.inspectionOverride, .security(.pkcs7))
        XCTAssertEqual(FormatID.jwt.inspectionOverride, .security(.jwt))
        XCTAssertEqual(FormatID.jwk.inspectionOverride, .security(.jwk))
        XCTAssertEqual(FormatID.jwks.inspectionOverride, .security(.jwks))
        XCTAssertEqual(FormatID.cyclonedxSBOM.inspectionOverride, .security(.cyclonedxSBOM))
        XCTAssertEqual(FormatID.spdxSBOM.inspectionOverride, .security(.spdxSBOM))
        XCTAssertEqual(FileAssociation(kind: .fileExtension, value: "profile", target: .mobileprovision)
            .validated()?.target, .mobileprovision)
    }

    func testBuiltComponentsDoNotRequireAnAppGroupIdentifier() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))
        for bundle in [host, preview, thumbnail] {
            XCTAssertNil(bundle.object(forInfoDictionaryKey: "GlimtAppGroupIdentifier"))
        }
    }

    func testYANGBuiltBundleRegistration() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))

        let declarations = try XCTUnwrap(host.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let yangDeclarations = declarations.filter { ($0["UTTypeIdentifier"] as? String) == "com.glimt.yang-source" }
        XCTAssertEqual(yangDeclarations.count, 1)
        let declaration = try XCTUnwrap(yangDeclarations.first)
        XCTAssertEqual(declaration["UTTypeDescription"] as? String, "YANG source")
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.plain-text"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(tags.keys), ["public.filename-extension"])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["yang"])

        for bundle in [preview, thumbnail] {
            let extensionInfo = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let types = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
            XCTAssertEqual(types.filter { $0 == "com.glimt.yang-source" }.count, 1, bundle.bundleIdentifier ?? "extension")
        }
    }

    func testPKCS7BuiltBundleRegistration() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))
        let identifier = "com.glimt.pkcs7-certificate-bundle"

        let declarations = try XCTUnwrap(host.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let matching = declarations.filter { ($0["UTTypeIdentifier"] as? String) == identifier }
        XCTAssertEqual(matching.count, 1)
        let declaration = try XCTUnwrap(matching.first)
        XCTAssertEqual(declaration["UTTypeDescription"] as? String, "PKCS#7 certificate bundle")
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.data"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(tags.keys), ["public.filename-extension"])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["p7b", "p7c"])

        for bundle in [preview, thumbnail] {
            let extensionInfo = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let claims = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
            XCTAssertEqual(claims.filter { $0 == identifier }.count, 1,
                           bundle.bundleIdentifier ?? "provider")
        }
    }

    func testPKCS12BuiltBundleRegistration() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))
        let identifier = "com.rsa.pkcs-12"

        for fileExtension in ["p12", "pfx"] {
            XCTAssertEqual(UTType(filenameExtension: fileExtension)?.identifier, identifier, fileExtension)
        }
        for key in ["UTExportedTypeDeclarations", "UTImportedTypeDeclarations"] {
            let declarations = host.object(forInfoDictionaryKey: key) as? [[String: Any]] ?? []
            XCTAssertFalse(declarations.contains { ($0["UTTypeIdentifier"] as? String) == identifier }, key)
        }

        for bundle in [host, preview, thumbnail] {
            let resourceRoot = try XCTUnwrap(bundle.resourceURL)
            let catalogURL = resourceRoot.appendingPathComponent(
                "InspectorCore_InspectorCore.bundle/Contents/Resources/formats.json")
            let catalogData = try Data(contentsOf: catalogURL)
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [[String: Any]])
            let row = try XCTUnwrap(catalog.first { ($0["id"] as? String) == "pkcs12" })
            XCTAssertEqual(row["status"] as? String, "supported", bundle.bundleIdentifier ?? "bundle")
            XCTAssertEqual(row["extensions"] as? [String], ["p12", "pfx"], bundle.bundleIdentifier ?? "bundle")
            XCTAssertEqual(row["contentTypeIdentifiers"] as? [String], [identifier], bundle.bundleIdentifier ?? "bundle")
        }

        for bundle in [preview, thumbnail] {
            let extensionInfo = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let claims = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
            XCTAssertEqual(claims.filter { $0 == identifier }.count, 1, bundle.bundleIdentifier ?? "provider")
        }

        let appResources = try XCTUnwrap(host.resourceURL)
        let showcaseURL = appResources.appendingPathComponent("Showcase/security/certificate-only.p12")
        let showcase = try Data(contentsOf: showcaseURL)
        XCTAssertEqual(showcase.count, 1_115)
        XCTAssertEqual(SHA256.hash(data: showcase).map { String(format: "%02x", $0) }.joined(),
                       "097bea6a17ae6095ae5bef0bd9c1b44d5a2003320f765536cf95b26ab0c2cd81")
        XCTAssertEqual(try Data(contentsOf: fixtureURL("Cases/security/certificate-only.p12")), showcase)

        func pkcs12Assets(in root: URL) -> [URL] {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter {
                ["p12", "pfx"].contains($0.pathExtension.lowercased())
            }
        }
        XCTAssertEqual(pkcs12Assets(in: appResources).map { $0.standardizedFileURL },
                       [showcaseURL.standardizedFileURL])
        XCTAssertTrue(pkcs12Assets(in: try XCTUnwrap(preview.resourceURL)).isEmpty)
        XCTAssertTrue(pkcs12Assets(in: try XCTUnwrap(thumbnail.resourceURL)).isEmpty)
    }

    func testElmBuiltBundleRegistration() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))

        let declarations = try XCTUnwrap(host.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let elmDeclarations = declarations.filter { ($0["UTTypeIdentifier"] as? String) == "com.glimt.elm-source" }
        XCTAssertEqual(elmDeclarations.count, 1)
        let declaration = try XCTUnwrap(elmDeclarations.first)
        XCTAssertEqual(declaration["UTTypeDescription"] as? String, "Elm source")
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.plain-text"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(tags.keys), ["public.filename-extension"])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["elm"])

        for bundle in [preview, thumbnail] {
            let extensionInfo = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let types = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
            XCTAssertEqual(types.filter { $0 == "com.glimt.elm-source" }.count, 1, bundle.bundleIdentifier ?? "extension")
        }
    }

    func testBisonBuiltBundleRegistration() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))

        let declarations = try XCTUnwrap(host.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let bisonDeclarations = declarations.filter { ($0["UTTypeIdentifier"] as? String) == "com.glimt.bison-source" }
        XCTAssertEqual(bisonDeclarations.count, 1)
        let declaration = try XCTUnwrap(bisonDeclarations.first)
        XCTAssertEqual(declaration["UTTypeDescription"] as? String, "Bison Grammar Source")
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.yacc-source"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(tags.keys), ["public.filename-extension"])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["y", "yy"])

        for bundle in [preview, thumbnail] {
            let extensionInfo = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let types = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
            XCTAssertEqual(types.filter { $0 == "com.glimt.bison-source" }.count, 1, bundle.bundleIdentifier ?? "extension")
        }

        let packagedFixture = try XCTUnwrap(host.resourceURL).appendingPathComponent("Showcase/source/bison.y")
        XCTAssertEqual(try Data(contentsOf: packagedFixture), try Data(contentsOf: fixtureURL("Showcase/source/bison.y")))
    }

    func testGraphvizBuiltBundleRegistration() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))

        let declarations = try XCTUnwrap(host.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let graphvizDeclarations = declarations.filter { ($0["UTTypeIdentifier"] as? String) == "com.glimt.graphviz-dot-source" }
        XCTAssertEqual(graphvizDeclarations.count, 1)
        let declaration = try XCTUnwrap(graphvizDeclarations.first)
        XCTAssertEqual(declaration["UTTypeDescription"] as? String, "Graphviz DOT Source")
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.plain-text"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(tags.keys), ["public.filename-extension"])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["dot", "gv"])

        for bundle in [preview, thumbnail] {
            let extensionInfo = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
            let types = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
            XCTAssertEqual(types.filter { $0 == "com.glimt.graphviz-dot-source" }.count, 1,
                           bundle.bundleIdentifier ?? "extension")
        }

        let packagedFixture = try XCTUnwrap(host.resourceURL).appendingPathComponent("Showcase/source/graph.dot")
        XCTAssertEqual(try Data(contentsOf: packagedFixture), try Data(contentsOf: fixtureURL("Showcase/source/graph.dot")))
    }

    func testReleaseCandidateMetadataAndPreviewScope() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let host = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let preview = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtPreview.appex")))
        let thumbnail = try XCTUnwrap(Bundle(url: host.bundleURL.appendingPathComponent("Contents/PlugIns/GlimtThumbnail.appex")))
        for (bundle, id) in [(host, "com.glimt.app"), (preview, "com.glimt.app.preview"), (thumbnail, "com.glimt.app.thumbnail")] {
            XCTAssertEqual(bundle.bundleIdentifier, id)
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "15.0")
        }
        XCTAssertNotNil(host.object(forInfoDictionaryKey: "NSHumanReadableCopyright"))
        XCTAssertNotNil(host.url(forResource: "AppIcon", withExtension: "icns"))
        let declarations = try XCTUnwrap(host.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let mermaidDeclarations = declarations.filter { ($0["UTTypeIdentifier"] as? String) == "com.glimt.mermaid-source" }
        XCTAssertEqual(mermaidDeclarations.count, 1)
        let mermaidDeclaration = try XCTUnwrap(mermaidDeclarations.first)
        XCTAssertEqual(mermaidDeclaration["UTTypeDescription"] as? String, "Mermaid source")
        XCTAssertEqual(mermaidDeclaration["UTTypeConformsTo"] as? [String], ["public.plain-text"])
        let mermaidTags = try XCTUnwrap(mermaidDeclaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(mermaidTags.keys), ["public.filename-extension"])
        XCTAssertEqual(mermaidTags["public.filename-extension"] as? [String], ["mmd", "mermaid"])
        let declarationsByID = Dictionary(uniqueKeysWithValues: declarations.compactMap { declaration in
            (declaration["UTTypeIdentifier"] as? String).map { ($0, declaration) }
        })
        XCTAssertTrue(Set(["com.glimt.app.dotenv", "com.glimt.app.java-properties", "com.glimt.app.windows-registry", "com.glimt.app.email-message", "com.glimt.app.icalendar", "com.glimt.app.vcard", "com.glimt.log", "com.glimt.asp-source", "com.glimt.aspx-source", "com.glimt.jinja-source", "com.glimt.twig-source", "com.glimt.gentoo-source", "com.glimt.fortran-source", "com.glimt.ini-source", "com.glimt.python-source-alias", "com.glimt.ada-source", "com.glimt.eiffel-source", "com.glimt.pyrex-source", "com.glimt.autohotkey-source", "com.glimt.inno-setup-source", "com.glimt.nsis-source", "com.glimt.rego-source", "com.glimt.ldif-text", "com.glimt.rdf-turtle-source", "com.glimt.textbundle-package"]).isSubset(of: Set(declarationsByID.keys)))
        for (identifier, fileExtension) in [("com.glimt.app.dotenv", "env"), ("com.glimt.app.java-properties", "properties"), ("com.glimt.app.windows-registry", "reg"), ("com.glimt.app.email-message", "eml"), ("com.glimt.app.icalendar", "ics"), ("com.glimt.app.vcard", "vcf"), ("com.glimt.log", "syslog"), ("com.glimt.asp-source", "asp"), ("com.glimt.aspx-source", "aspx"), ("com.glimt.jinja-source", "jinja"), ("com.glimt.twig-source", "twig"), ("com.glimt.gentoo-source", "ebuild"), ("com.glimt.fortran-source", "ftn"), ("com.glimt.ini-source", "desktop")] {
            let declaration = try XCTUnwrap(declarationsByID[identifier])
            let conformsTo = declaration["UTTypeConformsTo"] as? [String] ?? []
            XCTAssertTrue(conformsTo.contains("public.plain-text") || conformsTo.contains("public.text"))
            let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertTrue((tags["public.filename-extension"] as? [String] ?? []).contains(fileExtension))
        }
        let pythonAliasTags = try XCTUnwrap(declarationsByID["com.glimt.python-source-alias"]?["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(pythonAliasTags["public.filename-extension"] as? [String])),
                       Set(["pyi", "pyw", "py3", "cpy", "gyp", "gypi", "pxd", "pxi", "rpy"]))
        for (identifier, fileExtension) in [("com.glimt.ada-source", "gnad"), ("com.glimt.eiffel-source", "se"),
                                            ("com.glimt.pyrex-source", "pyx")] {
            let tags = try XCTUnwrap(declarationsByID[identifier]?["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertTrue((tags["public.filename-extension"] as? [String] ?? []).contains(fileExtension))
            XCTAssertEqual(UTType(filenameExtension: fileExtension)?.identifier, identifier)
        }
        let textBundleDeclaration = try XCTUnwrap(declarationsByID["com.glimt.textbundle-package"])
        XCTAssertEqual(textBundleDeclaration["UTTypeConformsTo"] as? [String], ["com.apple.package"])
        let textBundleTags = try XCTUnwrap(textBundleDeclaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(textBundleTags["public.filename-extension"] as? [String], ["textbundle"])
        for (identifier, fileExtension) in [("com.glimt.autohotkey-source", "ahk"),
                                            ("com.glimt.inno-setup-source", "iss"),
                                            ("com.glimt.nsis-source", "nsi"), ("com.glimt.rego-source", "rego"),
                                            ("com.glimt.ldif-text", "ldif"), ("com.glimt.rdf-turtle-source", "ttl")] {
            let tags = try XCTUnwrap(declarationsByID[identifier]?["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertTrue((tags["public.filename-extension"] as? [String] ?? []).contains(fileExtension))
            XCTAssertEqual(UTType(filenameExtension: fileExtension)?.identifier, identifier)
        }
        XCTAssertEqual(UTType(filenameExtension: "adb")?.identifier, "public.ada-source")
        XCTAssertEqual(UTType(filenameExtension: "ads")?.identifier, "public.ada-source")
        let logTypeTags = try XCTUnwrap(declarationsByID["com.glimt.log"]?["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(logTypeTags["public.filename-extension"] as? [String])), Set(["syslog", "cef", "leef"]))
        let extensionInfo = try XCTUnwrap(preview.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let types = try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String])
        XCTAssertTrue(types.contains("com.glimt.textbundle-package"), "Preview independently claims TextBundle packages")
        XCTAssertFalse(types.contains("public.data"), "Do not claim unrelated binary formats")
        XCTAssertFalse(types.contains("public.source-code"), "Avoid a broad generic source declaration")
        XCTAssertFalse(types.contains("public.typescript"), "Do not register an unresolved public TypeScript alias")
        XCTAssertFalse(types.contains("public.mpeg-2-transport-stream"))
        XCTAssertTrue(Set(["public.plain-text", "public.json", "public.yaml", "public.xml", "com.apple.property-list", "net.daringfireball.markdown"]).isSubset(of: Set(types)))
        XCTAssertTrue(types.contains("com.glimt.log"))
        XCTAssertEqual(types.filter { $0 == "com.glimt.mermaid-source" }.count, 1)
        let catalogTypes = Set(FormatCatalog.supported.flatMap(\.contentTypeIdentifiers))
        XCTAssertTrue(catalogTypes.isSubset(of: Set(types)), "Every supported format UTI must be registered by Quick Look Preview")
        XCTAssertEqual(UTType(filenameExtension: "csv")?.identifier, "public.comma-separated-values-text")
        XCTAssertEqual(UTType(filenameExtension: "tsv")?.identifier, "public.tab-separated-values-text")
        XCTAssertEqual(UTType(filenameExtension: "pyw")?.identifier, "com.glimt.python-source-alias")
        XCTAssertEqual(UTType(filenameExtension: "pxd")?.identifier, "com.glimt.python-source-alias")

        let thumbnailInfo = try XCTUnwrap(thumbnail.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        let thumbnailAttributes = try XCTUnwrap(thumbnailInfo["NSExtensionAttributes"] as? [String: Any])
        let thumbnailTypes = try XCTUnwrap(thumbnailAttributes["QLSupportedContentTypes"] as? [String])
        XCTAssertTrue(thumbnailTypes.contains("com.glimt.textbundle-package"), "Thumbnail independently claims TextBundle packages")
        XCTAssertTrue(catalogTypes.subtracting(["com.glimt.mermaid-source"]).isSubset(of: Set(thumbnailTypes)),
                      "Every supported UTI except the explicit Preview-only Mermaid identity remains claimed by Thumbnail")
        XCTAssertFalse(thumbnailTypes.contains("com.glimt.mermaid-source"), "Mermaid does not change Thumbnail claims")
        XCTAssertTrue(thumbnailTypes.contains("com.glimt.log"))
        let sourceTypes: Set<String> = [
            "public.swift-source", "com.sun.java-source", "public.c-source", "public.c-header",
            "public.c-plus-plus-source", "public.c-plus-plus-header", "public.python-script",
            "com.netscape.javascript-source", "com.microsoft.typescript", "public.shell-script",
            "public.bash-script", "public.zsh-script", "public.make-source"
        ]
        XCTAssertTrue(sourceTypes.isSubset(of: Set(thumbnailTypes)))
        XCTAssertFalse(thumbnailTypes.contains("public.source-code"), "Avoid a broad generic source declaration")
        XCTAssertFalse(thumbnailTypes.contains("public.data"))
    }

    func testRequestedResolvableSystemTypesAreCataloguedAndRegistered() throws {
        let expected: [(String, String)] = [
            ("f", "public.fortran-source"), ("for", "public.fortran-source"),
            ("f90", "public.fortran-90-source"), ("f95", "public.fortran-95-source"),
            ("gpx", "com.glimt.gpx-xml"), ("kml", "com.glimt.kml-xml"),
            ("geojson", "com.glimt.geojson-data"), ("gltf", "org.khronos.gltf")
        ]
        let preview = try extensionContentTypes(for: "GlimtPreview")
        let thumbnail = try extensionContentTypes(for: "GlimtThumbnail")
        for (fileExtension, identifier) in expected {
            if !["com.glimt.gpx-xml", "com.glimt.kml-xml", "com.glimt.geojson-data"].contains(identifier) {
                XCTAssertEqual(UTType(filenameExtension: fileExtension)?.identifier, identifier, fileExtension)
            }
            XCTAssertTrue(FormatCatalog.supported.contains { $0.contentTypeIdentifiers.contains(identifier) }, identifier)
            XCTAssertTrue(preview.contains(identifier), "Preview: \(identifier)")
            XCTAssertTrue(thumbnail.contains(identifier), "Thumbnail: \(identifier)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let app = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let declarations = try XCTUnwrap(app.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        for (identifier, fileExtension, parentType) in [
            ("com.glimt.gpx-xml", "gpx", "public.xml"),
            ("com.glimt.kml-xml", "kml", "public.xml"),
            ("com.glimt.geojson-data", "geojson", "public.json")
        ] {
            let declaration = try XCTUnwrap(declarations.first { ($0["UTTypeIdentifier"] as? String) == identifier })
            XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], [parentType])
            let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertEqual(tags["public.filename-extension"] as? [String], [fileExtension])
        }
    }

    private func extensionContentTypes(for name: String) throws -> Set<String> {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let app = try XCTUnwrap(Bundle(url: products.appendingPathComponent("Glimt.app")))
        let bundle = try XCTUnwrap(Bundle(url: app.bundleURL.appendingPathComponent("Contents/PlugIns/\(name).appex")))
        let info = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        let attributes = try XCTUnwrap(info["NSExtensionAttributes"] as? [String: Any])
        return Set(try XCTUnwrap(attributes["QLSupportedContentTypes"] as? [String]))
    }

    func testFactoryDefaultsAndMissingFileDoNotWrite() throws {
        let directory = try XCTUnwrap(directory)
        let store = SettingsStore(directory: directory)
        let defaults = GlimtSettings.factoryDefaults
        XCTAssertEqual(defaults, GlimtSettings())
        XCTAssertEqual(defaults.schemaVersion, 2)
        XCTAssertTrue(defaults.source.showLineNumbers)
        XCTAssertTrue(defaults.textCode.wordWrap)
        XCTAssertEqual(defaults.textCode.tabWidth, 4)
        XCTAssertEqual(defaults.markdown.defaultPresentation, .rendered)
        XCTAssertEqual(defaults.structured.defaultPresentation, .tree)
        XCTAssertEqual(try store.load(), defaults)
        XCTAssertEqual(try SettingsStore(directory: directory, readOnly: true).load(), defaults)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testMermaidViewProfileRoundTripsAndCategoryResetRestoresFactoryOrder() throws {
        let directory = try XCTUnwrap(directory)
        let store = SettingsStore(directory: directory)
        let initial = try store.loadV3()
        var settings = initial.settings
        settings.categoryProfiles[ViewCategoryID.renderedDocuments.rawValue] = ["raw", "rendered", "source"]
        settings.formatOverrides[FormatID.mermaid.rawValue] = ["rendered", "raw"]
        let saved = try store.saveV3(settings, replacing: initial)
        let loaded = try store.loadV3()
        XCTAssertEqual(loaded.settings, saved.settings)
        XCTAssertEqual(ViewResolver.resolve(loaded.settings, for: .mermaid).configured, [.rendered, .raw])
        XCTAssertEqual(ViewResolver.resolve(loaded.settings, for: .markdown).configured, [.rendered, .source])

        var resetSettings = loaded.settings
        resetSettings.resetViews(for: .format(.mermaid))
        resetSettings.resetViews(for: .category(.renderedDocuments))
        XCTAssertEqual(ViewResolver.resolve(resetSettings, for: .mermaid).configured, [.rendered, .raw])
        XCTAssertEqual(ViewResolver.resolve(resetSettings, for: .markdown).configured, [.rendered, .source])
        XCTAssertNil(resetSettings.formatOverrides[FormatID.mermaid.rawValue])
        XCTAssertNil(resetSettings.categoryProfiles[ViewCategoryID.renderedDocuments.rawValue])
    }

    func testTwoStoresShareTheSameAtomicFile() throws {
        let directory = try XCTUnwrap(directory)
        let app = SettingsStore(directory: directory)
        let quickLook = SettingsStore(directory: directory, readOnly: true)
        var settings = GlimtSettings()
        settings.source.showLineNumbers = false
        settings.textCode.wordWrap = true
        settings.textCode.tabWidth = 2
        settings.markdown.defaultPresentation = .raw
        settings.structured.defaultPresentation = .pretty
        try app.save(settings)
        XCTAssertEqual(try quickLook.load(), settings)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [SettingsStore.legacyFilename])
        let encoded = try Data(contentsOf: directory.appendingPathComponent(SettingsStore.legacyFilename))
        XCTAssertEqual(try JSONDecoder().decode(GlimtSettings.self, from: encoded), settings)
        try app.save(settings)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(SettingsStore.legacyFilename)), encoded)
    }

    func testCorruptUnknownVersionAndInvalidEnumsFallBackWithoutRewriting() throws {
        let directory = try XCTUnwrap(directory)
        let store = SettingsStore(directory: directory)
        let file = directory.appendingPathComponent(SettingsStore.legacyFilename)
        let valid = try JSONEncoder().encode(GlimtSettings())
        var unknown = GlimtSettings()
        unknown.schemaVersion = 99
        let invalidEnum = try XCTUnwrap(String(data: valid, encoding: .utf8)).replacingOccurrences(of: "rendered", with: "unsupported")
        for bytes in [Data("not JSON".utf8), try JSONEncoder().encode(unknown), Data(invalidEnum.utf8), Data("{\"source\":{\"wordWrap\":\"yes\"}}".utf8)] {
            try bytes.write(to: file)
            XCTAssertEqual(try store.load(), .factoryDefaults)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testPartialAndFutureKeysPreserveKnownPreferences() throws {
        let directory = try XCTUnwrap(directory)
        let store = SettingsStore(directory: directory)
        let file = directory.appendingPathComponent(SettingsStore.legacyFilename)
        for source in [
            "{\"source\":{\"wordWrap\":true},\"future\":{\"theme\":\"unknown\"}}",
            "{\"schemaVersion\":1,\"source\":{\"wordWrap\":true,\"future\":42},\"markdown\":{},\"structured\":{}}"
        ] {
            let bytes = Data(source.utf8)
            try bytes.write(to: file)
            let loaded = try store.load()
            XCTAssertTrue(loaded.textCode.wordWrap)
            XCTAssertTrue(loaded.source.showLineNumbers)
            XCTAssertEqual(loaded.textCode.tabWidth, 4)
            XCTAssertEqual(loaded.markdown.defaultPresentation, .rendered)
            XCTAssertEqual(loaded.structured.defaultPresentation, .tree)
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Loading compatibility defaults must not rewrite settings")
        }
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(try store.load(), .factoryDefaults)
    }

    func testSettingsWaveOneDefaultsAndBaselineCompatibility() throws {
        let legacy = Data("{\"schemaVersion\":1,\"source\":{\"showLineNumbers\":false,\"wordWrap\":true,\"tabWidth\":2},\"markdown\":{\"defaultPresentation\":\"raw\"},\"structured\":{\"defaultPresentation\":\"pretty\"}}".utf8)
        let upgraded = try JSONDecoder().decode(GlimtSettings.self, from: legacy)
        XCTAssertFalse(upgraded.source.showLineNumbers)
        XCTAssertTrue(upgraded.textCode.wordWrap)
        XCTAssertEqual(upgraded.textCode.tabWidth, 2)
        XCTAssertEqual(upgraded.textCode.fontFamily, "System Monospaced")
        XCTAssertEqual(upgraded.textCode.fontSize, 12)
        XCTAssertTrue(upgraded.textCode.wordWrap)
        XCTAssertEqual(upgraded.markdown.defaultPresentation, .raw)
        XCTAssertEqual(upgraded.markdown.profile, .default)
        XCTAssertEqual(upgraded.structured.defaultPresentation, .pretty)
        XCTAssertEqual(upgraded.general.maximumPreviewSize.maximumBytes, 1_048_576)
        var edited = upgraded
        edited.textCode.fontSize = 200
        edited.textCode.fontSize = -1
        edited.markdown.fontSize = 200
        edited.textCode.fontFamily = "not-an-installed-choice"
        edited.structured.expandDepth = 999
        let normalized = edited.normalized()
        XCTAssertEqual(normalized.textCode.fontSize, 9)
        XCTAssertEqual(normalized.markdown.fontSize, 28)
        XCTAssertEqual(normalized.textCode.fontFamily, "System Monospaced")
        XCTAssertEqual(normalized.structured.expandDepth, 3)
        XCTAssertLessThanOrEqual(RenderConfiguration(settings: normalized).maximumPreviewBytes, 1_048_576)
    }

    func testLanguageInheritanceAndLiteralFileMappingResolution() throws {
        var settings = GlimtSettings()
        settings.textCode.fontSize = 18
        settings.textCode.tabWidth = 4
        settings.source.languageOverrides["python"] = .init(tabWidth: 2)
        let extensionRule = try XCTUnwrap(FileAssociation(kind: .fileExtension, value: "*.foo", target: .yaml).validated())
        settings.fileAssociations = [extensionRule, .init(kind: .filename, value: "special.foo", target: .text)]
        let configuration = RenderConfiguration(settings: settings)
        XCTAssertEqual(configuration.source(for: .python).fontSize, 18)
        XCTAssertEqual(configuration.source(for: .python).tabWidth, 2)
        XCTAssertEqual(configuration.source(for: .swift).tabWidth, 4)
        XCTAssertEqual(configuration.association(for: "sample.foo")?.target, .yaml)
        XCTAssertEqual(configuration.association(for: "special.foo")?.target, .text)
        XCTAssertNil(FileAssociation(kind: .filename, value: "../secret", target: .text).validated())
        XCTAssertNil(FileAssociation(kind: .fileExtension, value: "foo.*", target: .text).validated())
        let directory = try XCTUnwrap(directory)
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        XCTAssertEqual(try store.load().source.languageOverrides["python"]?.tabWidth, 2)
        XCTAssertEqual(try store.load().fileAssociations.first?.value, "foo")
    }

    func testLegacyCustomThemeCanBeAssignedToBothAppearancesWithoutMigration() throws {
        let store = SettingsStore(directory: try XCTUnwrap(directory))
        let component = SourceThemeColor(red: 0.2, green: 0.3, blue: 0.4)
        let palette = SourceThemePalette(background: component, foreground: component, comment: component,
            keyword: component, string: component, number: component, type: component, directive: component)
        var legacy = GlimtSettings.factoryDefaults
        legacy.source.customThemes = [.init(id: "legacy-light", name: "Legacy Light", appearance: .light,
                                            basePreset: .neutral, palette: palette)]
        legacy.source.lightCustomThemeID = "legacy-light"
        try store.save(legacy)
        let file = try XCTUnwrap(directory).appendingPathComponent(SettingsStore.legacyFilename)
        let originalBytes = try Data(contentsOf: file)
        var loaded = try store.load()
        XCTAssertEqual(loaded, legacy)
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertEqual(loaded.source.customThemes.first?.appearance, .light, "Keep the old encoded preview hint")
        XCTAssertEqual(try Data(contentsOf: file), originalBytes, "Reading must not rewrite legacy settings")
        loaded.source.darkCustomThemeID = "legacy-light"
        try store.save(loaded)
        let reloaded = try store.load()
        let resolved = reloaded.source.resolved(defaults: reloaded.textCode)
        XCTAssertEqual(resolved.lightPalette, palette)
        XCTAssertEqual(resolved.darkPalette, palette, "Theme assignment is independent of the legacy appearance hint")
        XCTAssertEqual(reloaded.source.lightCustomThemeID, "legacy-light")
        XCTAssertEqual(reloaded.source.darkCustomThemeID, "legacy-light")
    }

    func testEditingUnassignedLibraryThemeDoesNotChangeAssignments() throws {
        let store = SettingsStore(directory: try XCTUnwrap(directory))
        let component = SourceThemeColor(red: 0.1, green: 0.2, blue: 0.3)
        let palette = SourceThemePalette(background: component, foreground: component, comment: component,
            keyword: component, string: component, number: component, type: component, directive: component)
        var settings = GlimtSettings.factoryDefaults
        settings.source.customThemes = [
            .init(id: "active", name: "Active", appearance: .light, basePreset: .glimtDefault, palette: palette),
            .init(id: "library", name: "Library", appearance: .dark, basePreset: .neutral, palette: palette)
        ]
        settings.source.lightCustomThemeID = "active"
        settings.source.darkTheme = .highContrast
        try store.save(settings)
        var edited = try store.load()
        edited.source.customThemes[1].palette.keyword = .init(red: 0.7, green: 0.6, blue: 0.5)
        try store.save(edited)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.source.lightCustomThemeID, "active")
        XCTAssertNil(reloaded.source.darkCustomThemeID)
        XCTAssertEqual(reloaded.source.darkTheme, .highContrast)
        XCTAssertEqual(reloaded.source.resolved(defaults: reloaded.textCode), settings.source.resolved(defaults: settings.textCode), "Editing an unassigned theme has no rendering side effect")
        XCTAssertEqual(reloaded.source.customThemes[1].palette.keyword, edited.source.customThemes[1].palette.keyword)
    }

    func testValuesClampAndResetPersistsFactoryDefaults() throws {
        let directory = try XCTUnwrap(directory)
        let store = SettingsStore(directory: directory)
        let reader = SettingsStore(directory: directory, readOnly: true)
        for (input, expected) in [(Int.min, 1), (Int.max, 8)] {
            var settings = GlimtSettings()
            settings.textCode.tabWidth = input
            try store.save(settings)
            XCTAssertEqual(try reader.load().textCode.tabWidth, expected)
            let bytes = try JSONEncoder().encode(settings)
            try bytes.write(to: directory.appendingPathComponent(SettingsStore.legacyFilename))
            XCTAssertEqual(try store.load().textCode.tabWidth, expected)
        }
        XCTAssertEqual(try store.reset(), .factoryDefaults)
        XCTAssertEqual(try reader.load(), .factoryDefaults)
    }

    func testReadOnlyRejectsSaveAndResetWithoutMutation() throws {
        let directory = try XCTUnwrap(directory)
        let app = SettingsStore(directory: directory)
        let reader = SettingsStore(directory: directory, readOnly: true)
        try app.save(.factoryDefaults)
        let file = directory.appendingPathComponent(SettingsStore.legacyFilename)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try reader.save(.factoryDefaults)) { error in
            guard case SettingsStoreError.readOnly = error else { return XCTFail("Expected read-only error") }
        }
        XCTAssertThrowsError(try reader.reset())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testOversizedLegacyFileFallsBackWithoutReplacingTheSource() throws {
        let directory = try XCTUnwrap(directory)
        let file = directory.appendingPathComponent(SettingsStore.legacyFilename)
        let bytes = Data(repeating: 32, count: 65_537)
        try bytes.write(to: file)
        XCTAssertEqual(try SettingsStore(directory: directory).load(), .factoryDefaults)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testFilesystemErrorsHaveSanitizedUserMessages() throws {
        let directory = try XCTUnwrap(directory)
        let file = directory.appendingPathComponent("not-a-directory")
        try Data("input".utf8).write(to: file)
        let store = SettingsStore(directory: file)
        XCTAssertThrowsError(try store.save(.factoryDefaults)) { error in
            guard case SettingsStoreError.writeFailed = error else { return XCTFail("Expected write failure") }
            XCTAssertFalse(error.localizedDescription.contains(directory.path))
            XCTAssertEqual(error.localizedDescription, "Unable to save shared settings.")
        }
        let invalidFile = directory.appendingPathComponent(SettingsStore.legacyFilename, isDirectory: true)
        try FileManager.default.createDirectory(at: invalidFile, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SettingsStore(directory: directory).load()) { error in
            guard case SettingsStoreError.readFailed = error else { return XCTFail("Expected read failure") }
            XCTAssertFalse(error.localizedDescription.contains(directory.path))
            XCTAssertEqual(error.localizedDescription, "Unable to read shared settings.")
        }
    }

}
