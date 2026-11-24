import Foundation
import XCTest
@testable import InspectorCore

final class FormatCatalogTests: XCTestCase {
    func testMermaidCatalogIdentityAndShowcaseFixture() throws {
        let mermaid = try XCTUnwrap(FormatCatalog.definition(for: .mermaid))
        XCTAssertEqual(mermaid.status, .supported)
        XCTAssertEqual(mermaid.extensions, ["mmd", "mermaid"])
        XCTAssertEqual(mermaid.exactFilenames, [])
        XCTAssertEqual(mermaid.contentTypeIdentifiers, ["com.glimt.mermaid-source"])
        XCTAssertEqual(mermaid.inspectionKind, .text)
        XCTAssertEqual(mermaid.inspectorID, .text)
        XCTAssertNil(mermaid.sourceLanguage)
        XCTAssertEqual(mermaid.effectiveThumbnailStrategy, .textLines)
        XCTAssertEqual(mermaid.effectiveSettingsProfile, .text)
        XCTAssertEqual(mermaid.availableRepresentations, [.rendered, .raw])
        XCTAssertEqual(mermaid.presentationOrder, [.rendered, .raw])
        XCTAssertEqual(mermaid.effectiveDefaultRepresentation, .rendered)
        XCTAssertEqual(mermaid.resolvedDetectionRules.map(\.typeID), ["mermaid"])
        XCTAssertEqual(mermaid.resolvedDetectionRules[0].singleExtensions, [".mmd", ".mermaid"])
        XCTAssertEqual(mermaid.resolvedDetectionRules[0].systemUTIIdentifiers, ["com.glimt.mermaid-source"])
        XCTAssertTrue(try XCTUnwrap(mermaid.detectionRules?.first).usesCatalogExtensions)
        XCTAssertTrue(try XCTUnwrap(mermaid.detectionRules?.first).usesCatalogUTIs)
        XCTAssertEqual(FormatCatalog.match(fileName: "diagram.MMD")?.id, .mermaid)
        XCTAssertEqual(FormatCatalog.match(fileName: "diagram.Mermaid")?.id, .mermaid)

        let showcased = try fixtureURL(try XCTUnwrap(mermaid.showcaseFixture))
        let original = try fixtureURL("Cases/mermaid/flowchart.mmd")
        XCTAssertEqual(try Data(contentsOf: showcased), try Data(contentsOf: original))
    }

    func testRequestedStructuredAndSourceExtensionsResolveToTheirCatalogDefinitions() throws {
        let supportedMappings: [(String, FormatID)] = [
            ("font.ttx", .xml), ("places.kml", .kml), ("track.gpx", .gpx),
            ("countries.geojson", .geojson),
            ("scene.gltf", .json)
        ]

        for (filename, expectedID) in supportedMappings {
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, expectedID, filename)
        }

        let fortran = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: "fortran")))
        XCTAssertTrue(fortran.extensions.contains("for"))
        let haskell = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: "haskell")))
        XCTAssertTrue(haskell.extensions.contains("lhs"))

        let sourceMappings: [(String, String)] = [
            ("index.html", "html"), ("index.htm", "html"), ("query.sql", "sql"),
            ("main.rs", "rust"), ("index.php", "php"), ("app.rb", "ruby"),
            ("sample.fs", "fsharp"), ("sample.fsx", "fsharp"), ("sample.fish", "fish"),
            ("sample.f", "fortran"), ("sample.for", "fortran"), ("sample.f90", "fortran"),
            ("sample.f95", "fortran"),
            ("sample.gd", "gdscript"), ("sample.gleam", "gleam"),
            ("sample.go", "go"), ("sample.gradle", "gradle"),
            ("sample.groovy", "groovy"), ("sample.hs", "haskell"),
            ("sample.lhs", "haskell"),
            ("hello.mm", "objective-c"), ("sample.ml", "ocaml"), ("sample.mli", "ocaml"),
            ("sample.tcl", "tcl-tk"), ("sample.wish", "tcl-tk"), ("sample.applescript", "applescript"),
            ("hello.pl", "perl"), ("module.pm", "perl"), ("analysis.R", "r"),
            ("Main.scala", "scala"), ("analysis.jl", "julia"), ("sample.haml", "haml")
        ]

        for (filename, expectedID) in sourceMappings {
            let definition = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: expectedID)), filename)
            XCTAssertTrue(definition.extensions.contains((filename as NSString).pathExtension), filename)
            XCTAssertEqual(definition.status, .supported, filename)
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, definition.id, filename)
            XCTAssertEqual(definition.inspectorID, .source, filename)
            let expectedLanguage: SourceLanguage? = expectedID == "gradle" ? .groovy : expectedID == "tcl-tk" ? .tcl : SourceLanguage(rawValue: expectedID)
            XCTAssertEqual(definition.sourceLanguage, expectedLanguage, filename)
        }
        XCTAssertEqual(FormatCatalog.match(fileName: "Gemfile")?.id, FormatID.ruby)
        XCTAssertEqual(FormatCatalog.match(fileName: "Rakefile")?.id, FormatID.ruby)
    }

    func testGeospatialCatalogRoutesUseDedicatedFormatIDs() throws {
        let kml = try XCTUnwrap(FormatCatalog.definition(for: .kml))
        let gpx = try XCTUnwrap(FormatCatalog.definition(for: .gpx))
        XCTAssertEqual(kml.extensions, ["kml"])
        XCTAssertEqual(gpx.extensions, ["gpx"])
        XCTAssertEqual(kml.contentTypeIdentifiers, ["com.glimt.kml-xml"])
        XCTAssertEqual(gpx.contentTypeIdentifiers, ["com.glimt.gpx-xml"])
        XCTAssertEqual(kml.effectiveInspectorID, .xml)
        XCTAssertEqual(gpx.effectiveInspectorID, .xml)
        XCTAssertEqual(kml.availableRepresentations, [.tree, .pretty, .raw])
        XCTAssertEqual(gpx.availableRepresentations, [.tree, .pretty, .raw])
        XCTAssertEqual(FormatCatalog.match(fileName: "map.KML")?.id, .kml)
        XCTAssertEqual(FormatCatalog.match(fileName: "route.GPX")?.id, .gpx)
        let geojson = try XCTUnwrap(FormatCatalog.definition(for: .geojson))
        XCTAssertEqual(geojson.extensions, ["geojson"])
        XCTAssertEqual(geojson.contentTypeIdentifiers, ["com.glimt.geojson-data"])
        XCTAssertEqual(geojson.effectiveInspectorID, .json)
        XCTAssertEqual(geojson.availableRepresentations, [.tree, .pretty, .raw])
        XCTAssertEqual(FormatCatalog.match(fileName: "countries.GeoJSON")?.id, .geojson)
    }

    func testCommonShellFortranAndINIAliasesUseTheirNativeSourceRoutes() throws {
        let cases: [(String, String, SourceLanguage)] = [
            ("Showcase/fileformats/gentoo/portage.ebuild", "shell", .shell),
            ("Showcase/fileformats/gentoo/profile.eclass", "shell", .shell),
            ("Showcase/fileformats/fortran/legacy.ftn", "fortran", .fortran),
            ("Showcase/fileformats/ini/org.glimt.viewer.desktop", "ini", .ini),
            ("Showcase/fileformats/ini/Doxyfile.doxyfile", "ini", .ini),
            ("Showcase/fileformats/ini/project.kdev3", "ini", .ini)
        ]
        for (path, expectedID, expectedLanguage) in cases {
            let url = try fixtureURL(path)
            let result = try PreviewInspectionResult.read(at: url)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertEqual(result.sourceDocument?.language, expectedLanguage, path)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: url), path)
        }
    }

    func testDeveloperConfigDotfilesUseSharedSourcePreview() throws {
        let cases: [(String, FormatID, SourceLanguage)] = [
            (".editorconfig", .editorconfig, .ini),
            (".gitignore", .gitignore, .gitignore),
            (".dockerignore", .dockerignore, .dockerignore),
            ("Dockerfile.dockerignore", .dockerignore, .dockerignore)
        ]
        for (name, id, language) in cases {
            XCTAssertEqual(FormatCatalog.match(fileName: name)?.id, id, name)
            let definition = try XCTUnwrap(FormatCatalog.definition(for: id))
            XCTAssertEqual(definition.inspectorID, .source)
            XCTAssertEqual(definition.availableRepresentations, [.source, .raw])
            let result = try PreviewInspectionResult.read(at: fixtureURL(try XCTUnwrap(definition.showcaseFixture)))
            XCTAssertEqual(result.formatDefinition?.id, id, name)
            XCTAssertEqual(result.sourceDocument?.language, language, name)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, name)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: fixtureURL(try XCTUnwrap(definition.showcaseFixture))))
        }
    }

    func testGitAndNodeConfigurationFilesUseBoundedSourceViews() throws {
        let cases: [(String, String, String)] = [
            (".npmrc", "npmrc", "Showcase/config/.npmrc"),
            (".gitattributes", "gitattributes", "Showcase/config/.gitattributes"),
            (".gitmodules", "gitmodules", "Showcase/config/.gitmodules")
        ]
        for (name, id, path) in cases {
            let definition = try XCTUnwrap(FormatCatalog.match(fileName: name), name)
            XCTAssertEqual(definition.id.rawValue, id)
            XCTAssertEqual(definition.inspectorID, .source)
            XCTAssertEqual(definition.availableRepresentations, [.source, .raw])
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, name)
            XCTAssertEqual(result.sourceDocument?.language.rawValue, definition.sourceLanguage?.rawValue, name)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, name)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: fixtureURL(path)), name)
        }
    }

    func testSystemdServiceSocketAndTimerFilesUseINISourcePreview() throws {
        let formatID = FormatID(rawValue: "systemd-unit")
        let definition = try XCTUnwrap(FormatCatalog.definition(for: formatID))
        XCTAssertEqual(definition.sourceLanguage, .ini)
        XCTAssertEqual(definition.inspectorID, .source)
        XCTAssertEqual(definition.availableRepresentations, [.source, .raw])
        for (filename, expectedPath) in [
            ("worker.service", "Showcase/config/systemd/worker.service"),
            ("worker.socket", "Showcase/config/systemd/worker.socket"),
            ("worker.timer", "Showcase/config/systemd/worker.timer")
        ] {
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, formatID, filename)
            let result = try PreviewInspectionResult.read(at: fixtureURL(expectedPath))
            XCTAssertEqual(result.formatDefinition?.id, formatID, filename)
            XCTAssertEqual(result.sourceDocument?.language, .ini, filename)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, filename)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: fixtureURL(expectedPath)), filename)
        }
    }

    func testGoModuleManifestAndLockFilesUseTheirExactFilenameRoute() throws {
        let definition = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: "go-module")))
        XCTAssertEqual(definition.sourceLanguage?.rawValue, "go-module")
        XCTAssertEqual(definition.inspectorID, .source)
        XCTAssertEqual(definition.availableRepresentations, [.source, .raw])
        let files = [
            ("go.mod", "Showcase/config/go/go.mod"),
            ("go.sum", "Showcase/config/go/go.sum"),
            ("go.work", "Showcase/config/go/go.work"),
            ("go.work.sum", "Showcase/config/go/go.work.sum")
        ]
        for (filename, path) in files {
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, definition.id, filename)
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            XCTAssertEqual(result.formatDefinition?.id, definition.id, filename)
            XCTAssertEqual(result.sourceDocument?.language.rawValue, "go-module", filename)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: fixtureURL(path)), filename)
        }
        XCTAssertNotEqual(FormatCatalog.match(fileName: "model.mod")?.id, definition.id,
                          "Go module routing is based on exact filenames and must not claim generic .mod files")
    }

    func testCommonGitAndNPMConfigurationFilesKeepMalformedAndTruncatedSource() throws {
        let cases: [(String, String, String, String)] = [
            (".npmrc", "npmrc", "ini", "npmrc"),
            (".gitattributes", "gitattributes", "git-attributes", "gitattributes"),
            (".gitmodules", "gitmodules", "ini", "gitmodules")
        ]
        for (filename, id, language, folder) in cases {
            let definition = try XCTUnwrap(FormatCatalog.match(fileName: filename), filename)
            XCTAssertEqual(definition.id.rawValue, id)
            XCTAssertEqual(definition.sourceLanguage?.rawValue, language)
            for variant in ["invalid", "truncated"] {
                let path = "Cases/config/\(folder)/\(variant)/\(filename)"
                let bytes = try Data(contentsOf: fixtureURL(path))
                let result = PreviewInspectionResult.prepare(
                    bytes: bytes, fileSize: bytes.count, fileName: filename, systemUTI: nil
                )
                XCTAssertEqual(result.formatDefinition?.id.rawValue, id, path)
                XCTAssertEqual(result.originalBytes, bytes, path)
                XCTAssertEqual(result.sourceDocument?.source, result.analysis.text, path)
            }
        }
    }

    func testCythonAdaAndEiffelSourceAliasesUseTheirNativeRoutes() throws {
        let aliases: [(String, String, SourceLanguage)] = [
            ("Showcase/fileformats/cython/fast.pyx", "pyrex", .python),
            ("Showcase/fileformats/ada/main.adb", "ada", .ada),
            ("Showcase/fileformats/ada/spec.ads", "ada", .ada),
            ("Showcase/fileformats/ada/project.gnad", "ada", .ada),
            ("Showcase/fileformats/eiffel/example.se", "eiffel", .eiffel)
        ]
        for (path, expectedID, expectedLanguage) in aliases {
            let url = try fixtureURL(path)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertEqual(result.sourceDocument?.language, expectedLanguage, path)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: url), path)
        }
        XCTAssertNil(FormatCatalog.match(fileName: "library.a"), "Ada's ambiguous .a alias must not steal static libraries")
    }

    func testAutoHotkeyInnoSetupAndNSISFilesUseInertSourceRoutes() throws {
        let cases: [(String, String, SourceLanguage)] = [
            ("Showcase/fileformats/autohotkey/hotkeys.ahk", "auto-hot-key", .autoHotkey),
            ("Showcase/fileformats/inno/installer.iss", "inno-setup", .innoSetup),
            ("Showcase/fileformats/nsis/installer.nsi", "nsis", .nsis),
            ("Showcase/fileformats/nsis/macros.nsh", "nsis", .nsis)
        ]
        for (path, expectedID, expectedLanguage) in cases {
            let url = try fixtureURL(path)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertEqual(result.sourceDocument?.language, expectedLanguage, path)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: url), path)
        }
    }

    func testRegoLDIFAndRDFFilesUseInertSourceRoutes() throws {
        let cases: [(String, FormatID, SourceLanguage)] = [
            ("Showcase/policy/allow.rego", .rego, .rego),
            ("Showcase/directory/people.ldif", .ldif, .ldif),
            ("Showcase/data/catalog.ttl", .turtle, .turtle)
        ]
        for (path, formatID, language) in cases {
            let url = try fixtureURL(path)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatDefinition?.id, formatID, path)
            XCTAssertEqual(result.sourceDocument?.language, language, path)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: url), path)
        }
        for (extensionName, formatID) in [("n3", FormatID.turtle), ("nt", .turtle)] {
            XCTAssertEqual(FormatCatalog.match(fileName: "graph.\(extensionName)")?.id, formatID)
        }
    }

    func testFormatsWithoutSpecializedLanguageSupportUseRawTextInspection() throws {
        for filename in ["sample.ld", "sample.map"] {
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.effectiveInspectorID, .text, filename)
        }
        let fixtures = [
            ("Showcase/build/linker.ld", "gcc-linker"), ("Cases/fileformats/gcc-map-valid.map", "gcc-linker"),
            ("Cases/fileformats/gcc-linker-edge.ld", "gcc-linker"),
            ("Cases/fileformats/gcc-map-edge.map", "gcc-linker")
        ]
        for (path, expectedID) in fixtures {
            let url = try fixtureURL(path)
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertNil(result.sourceDocument, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertEqual(result.detectionReason, "fileExtension", path)
        }
    }

    func testRequestedFilenameMappingsAreSupported() throws {
        let expected: [(String, String)] = [
            ("babashka.bb", "clojure"), ("script.bash", "shell"), ("sample.bezel", "text"),
            ("refs.bib", "bibtex"), ("script.csh", "csh"), ("main.c", "c"),
            ("header.h", "c"), ("main.cs", "csharp"), ("main.cpp", "cpp"),
            ("main.cp", "cpp"), ("main.c++", "cpp"), ("main.cc", "cpp"),
            ("main.cxx", "cpp"), ("header.hpp", "cpp"), ("header.hh", "cpp"),
            ("header.hxx", "cpp"), ("impl.ipp", "cpp"), ("app.cli", "clojure"),
            ("app.cljs", "clojure"), ("app.cljc", "clojure"), ("deps.edn", "clojure"),
            ("CMakeLists.cmake", "cmake"), ("Podfile.podspec", "podspec"),
            ("app.coffee", "coffeescript"), ("view.cfc", "coldfusion"),
            ("view.cfm", "coldfusion"), ("view.cfml", "coldfusion"),
            ("service.conf", "conf"), ("profile.mobileconfig", "mobileconfig"),
            ("app.cr", "crystal"), ("data.cson", "cson"), ("site.css", "css"),
            ("kernel.cu", "cpp")
        ]

        for (filename, id) in expected {
            let definition = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: id)), id)
            XCTAssertTrue(definition.extensions.contains((filename as NSString).pathExtension), filename)
            XCTAssertEqual(definition.status, .supported, filename)
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, definition.id, filename)
        }
    }

    func testRequestedFormatsRouteToInspectorOrPreservePlainText() {
        let cases: [(String, String, String)] = [
            ("babashka.bb", "(def answer 42)\n", "clojure"),
            ("script.bash", "#!/bin/bash\necho 42\n", "shell"),
            ("sample.bezel", "plain Bezel text\n", "text"),
            ("refs.bib", "@article{key, title={Hello}}\n", "bibtex"),
            ("script.csh", "#!/bin/csh\nif ( 1 ) then\necho 42\nendif\n", "csh"),
            ("main.c", "int main(void) { return 42; }\n", "c"),
            ("header.h", "#define VALUE 42\n", "c"),
            ("main.cs", "class Sample { }\n", "csharp"),
            ("main.cpp", "int main() { return 42; }\n", "cpp"),
            ("main.cp", "int main() { return 42; }\n", "cpp"),
            ("main.c++", "int main() { return 42; }\n", "cpp"),
            ("main.cc", "int main() { return 42; }\n", "cpp"),
            ("main.cxx", "int main() { return 42; }\n", "cpp"),
            ("header.hpp", "int answer = 42;\n", "cpp"),
            ("header.hh", "int answer = 42;\n", "cpp"),
            ("header.hxx", "int answer = 42;\n", "cpp"),
            ("impl.ipp", "template <typename T> T value;\n", "cpp"),
            ("app.cli", "(println 42)\n", "clojure"),
            ("app.cljs", "(defn answer [] 42)\n", "clojure"),
            ("app.cljc", "(def answer 42)\n", "clojure"),
            ("deps.edn", "(def deps {})\n", "clojure"),
            ("CMakeLists.cmake", "project(sample)\n", "cmake"),
            ("Podfile.podspec", "Pod::Spec.new do |spec|\nspec.version = 42\nend\n", "podspec"),
            ("app.coffee", "square = (x) -> if true then x * 42\n", "coffeescript"),
            ("view.cfc", "component { function run() {} }\n", "coldfusion"),
            ("view.cfm", "<cfoutput>#42#</cfoutput>\n", "coldfusion"),
            ("view.cfml", "<cfoutput>#42#</cfoutput>\n", "coldfusion"),
            ("service.conf", "port=42\n# retained as plain configuration text\n", "conf"),
            ("site.conf", "server {\n  listen 443;\n  server_name example.test;\n  location / { proxy_pass http://app; }\n}\n", "nginx"),
            ("site.conf", "<VirtualHost *:443>\n  ServerName example.test\n  DocumentRoot /srv/www\n</VirtualHost>\n", "apache"),
            ("profile.mobileconfig", "<?xml version=\"1.0\"?><plist><dict/></plist>", "mobileconfig"),
            ("app.cr", "def answer\n  42\nend\n", "crystal"),
            ("data.cson", "enabled: true\nanswer: 42\n", "cson"),
            ("site.css", "body { color: red; }\n", "css"),
            ("kernel.cu", "__global__ void run() {}\n", "cpp")
        ]

        for (filename, source, expectedID) in cases {
            let result = PreviewInspectionResult.prepare(bytes: Data(source.utf8), fileSize: source.utf8.count,
                fileName: filename, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, filename)
            XCTAssertEqual(result.analysis.text, source, filename)
            if expectedID == "text" {
                XCTAssertNil(result.sourceDocument, filename)
            } else if expectedID == "xml" || expectedID == "ini" || expectedID == "conf" || expectedID == "mobileconfig" {
                XCTAssertNil(result.sourceDocument, filename)
                if expectedID == "mobileconfig" { XCTAssertNotNil(result.xmlInspection, filename) }
                if expectedID == "conf" { XCTAssertNil(result.additionalInspection, filename) }
            } else {
                XCTAssertNotNil(result.sourceDocument, filename)
                XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, filename)
            }
        }
    }

    func testCatalogIdentitiesAndSupportedShowcasesAreComplete() throws {
        XCTAssertEqual(Set(FormatCatalog.all.map(\.id)).count, FormatCatalog.all.count)
        XCTAssertGreaterThan(FormatCatalog.all.count, 266)
        for format in FormatCatalog.supported {
            let path = try XCTUnwrap(format.showcaseFixture, format.displayName)
            XCTAssertTrue(path.hasPrefix("Showcase/")); XCTAssertFalse(path.contains(".."))
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            XCTAssertEqual(result.formatDefinition?.id, format.id, format.displayName)
            if [.zip, .derCertificate, .mobileprovision, .sqlite, .tarArchive, .cyclonedxSBOMProtobuf, .pkcs7, .pkcs12].contains(format.id) {
                XCTAssertTrue(result.analysis.isBinary, format.displayName)
                if format.id == .zip {
                    XCTAssertNotNil(result.additionalInspection?.archiveListing, format.displayName)
                } else if format.id == .sqlite {
                    XCTAssertNotNil(result.additionalStructuredContent, format.displayName)
                } else if format.id == .tarArchive {
                    XCTAssertNotNil(result.additionalInspection?.tarArchiveListing, format.displayName)
                } else if format.id == .cyclonedxSBOMProtobuf {
                    XCTAssertNotNil(result.additionalInspection?.securityInspection?.content, format.displayName)
                } else if format.id == .mobileprovision || format.id == .pkcs7 || format.id == .pkcs12 {
                    XCTAssertNotNil(result.additionalInspection?.securityInspection?.content, format.displayName)
                } else {
                    XCTAssertNotNil(result.additionalInspection?.certificateInspection, format.displayName)
                }
            } else {
                XCTAssertFalse(result.analysis.isBinary, format.displayName)
                XCTAssertFalse(result.statusSummary.items.contains { $0.kind == .warning }, format.displayName)
            }
            if let language = format.sourceLanguage { XCTAssertEqual(result.sourceDocument?.language, language) }
            if ![FormatID(rawValue: "objective-c"), FormatID(rawValue: "matlab"), .pemPublicKey].contains(format.id) {
                XCTAssertEqual(FormatCatalog.match(fileName: path)?.id, format.id)
            }
            for variant in format.showcaseVariants ?? [] {
                let variantResult = try PreviewInspectionResult.read(at: fixtureURL(variant.path))
                XCTAssertEqual(variantResult.formatDefinition?.id, format.id, variant.title)
                if variant.title == "Gzip-compressed USTAR" {
                    XCTAssertNotNil(variantResult.additionalInspection?.tarArchiveListing, variant.title)
                } else if variant.title != "Binary plist" {
                    XCTAssertFalse(variantResult.analysis.isBinary, variant.title)
                }
            }
        }
    }

    func testWindowsRegistryCatalogAndPreviewAreReadOnlyStructuredInspection() throws {
        let definition = try XCTUnwrap(FormatCatalog.definition(for: .windowsRegistry))
        XCTAssertEqual(definition.status, .supported)
        XCTAssertEqual(definition.extensions, ["reg"])
        XCTAssertEqual(definition.contentTypeIdentifiers, ["com.glimt.app.windows-registry"])
        XCTAssertEqual(definition.availableRepresentations, [.tree, .raw, .hex])

        let url = try fixtureURL(try XCTUnwrap(definition.showcaseFixture))
        let bytes = try Data(contentsOf: url)
        let preview = try PreviewInspectionResult.read(at: url)
        XCTAssertEqual(preview.formatDefinition?.id, .windowsRegistry)
        XCTAssertEqual(preview.originalBytes, bytes)
        if case .array(let rows) = preview.additionalStructuredContent {
            XCTAssertEqual(rows.count, 4)
        } else {
            XCTFail("Expected structured registry value rows")
        }
        XCTAssertFalse(preview.statusSummary.items.contains { $0.kind == .warning })

        let malformedURL = try fixtureURL("Cases/config/registry/invalid/malformed.reg")
        let malformedBytes = try Data(contentsOf: malformedURL)
        let malformed = try PreviewInspectionResult.read(at: malformedURL)
        XCTAssertEqual(malformed.originalBytes, malformedBytes)
        XCTAssertTrue(malformed.inspectionDiagnostics.contains { $0.code == .parseError || $0.code == .unsupported })

        let truncatedURL = try fixtureURL("Cases/config/registry/truncated.reg")
        let fullBytes = try Data(contentsOf: truncatedURL)
        let prefix = Data(fullBytes.prefix(48))
        let truncated = PreviewInspectionResult.prepare(bytes: prefix, fileSize: fullBytes.count,
            fileName: truncatedURL.lastPathComponent, systemUTI: nil)
        XCTAssertEqual(truncated.formatDefinition?.id, .windowsRegistry)
        XCTAssertEqual(truncated.originalBytes, prefix)
        XCTAssertTrue(truncated.inspectionDiagnostics.contains { $0.code == .truncated })
    }

    func testNewSourceFormatsPreserveMalformedAndTruncatedFixtures() throws {
        let cases: [(String, String, String, SourceLanguage)] = [
            ("Showcase/source/analysis.m", "Cases/source/matlab/malformed.m", "Cases/source/matlab/truncated.m", .matlab),
            ("Showcase/source/hello.ml", "Cases/source/ocaml/malformed.ml", "Cases/source/ocaml/truncated.ml", .ocaml),
            ("Showcase/source/hello.tcl", "Cases/source/tcl/malformed.tcl", "Cases/source/tcl/truncated.tcl", .tcl),
            ("Showcase/source/hello.applescript", "Cases/source/applescript/malformed.applescript", "Cases/source/applescript/truncated.applescript", .appleScript),
            ("Showcase/source/nginx.conf", "Cases/source/nginx/malformed.conf", "Cases/source/nginx/truncated.conf", .nginx),
            ("Showcase/source/httpd.conf", "Cases/source/apache/malformed.conf", "Cases/source/apache/truncated.conf", .apache),
            ("Showcase/source/nim.nim", "Cases/fileformats/nim/malformed.nim", "Cases/fileformats/nim/truncated.nim", .nim),
            ("Showcase/source/model.scad", "Cases/fileformats/openscad/malformed.scad", "Cases/fileformats/openscad/truncated.scad", .openSCAD),
            ("Showcase/source/add.wat", "Cases/fileformats/wat/malformed.wat", "Cases/fileformats/wat/truncated.wat", .webAssemblyText),
            ("Showcase/source/pascal.pas", "Cases/fileformats/pascal/malformed.pas", "Cases/fileformats/pascal/truncated.pas", .pascal),
            ("Showcase/source/counter.vh", "Cases/fileformats/verilog/malformed.vh", "Cases/fileformats/verilog/truncated.vh", .verilog),
            ("Showcase/source/counter.vhd", "Cases/fileformats/vhdl/malformed.vhd", "Cases/fileformats/vhdl/truncated.vhd", .vhdl),
            ("Showcase/source/hello.cob", "Cases/fileformats/cobol/malformed.cob", "Cases/fileformats/cobol/truncated.cob", .cobol),
            ("Showcase/source/board.dts", "Cases/fileformats/device-tree/malformed.dts", "Cases/fileformats/device-tree/truncated.dts", .deviceTree),
            ("Showcase/source/sv.po", "Cases/fileformats/gettext/malformed.po", "Cases/fileformats/gettext/truncated.po", .gettext),
            ("Showcase/source/page.html.erb", "Cases/fileformats/erb/malformed.erb", "Cases/fileformats/erb/truncated.erb", .erb),
            ("Showcase/source/Component.qml", "Cases/fileformats/qml/malformed.qml", "Cases/fileformats/qml/truncated.qml", .qml),
            ("Showcase/source/Counter.sol", "Cases/fileformats/solidity/malformed.sol", "Cases/fileformats/solidity/truncated.sol", .solidity),
            ("Showcase/fileformats/notes.org", "Cases/fileformats/org/malformed.org", "Cases/fileformats/org/truncated.org", .org)
        ]

        for (showcase, malformedPath, truncatedPath, language) in cases {
            let malformedURL = try fixtureURL(malformedPath)
            let malformedBytes = try Data(contentsOf: malformedURL)
            let malformed = try PreviewInspectionResult.read(at: malformedURL)
            XCTAssertEqual(malformed.sourceDocument?.language, language, malformedPath)
            XCTAssertEqual(malformed.sourceDocument?.source, String(decoding: malformedBytes, as: UTF8.self), malformedPath)
            XCTAssertEqual(malformed.originalBytes, malformedBytes, malformedPath)

            let truncatedURL = try fixtureURL(truncatedPath)
            let fullBytes = try Data(contentsOf: truncatedURL)
            let retained = Data(fullBytes.prefix(32))
            let truncated = PreviewInspectionResult.prepare(bytes: retained, fileSize: fullBytes.count,
                fileName: truncatedURL.lastPathComponent, systemUTI: nil)
            XCTAssertEqual(truncated.sourceDocument?.language, language, truncatedPath)
            XCTAssertEqual(truncated.sourceDocument?.source, String(decoding: retained, as: UTF8.self), truncatedPath)
            XCTAssertTrue(truncated.sourceDocument?.truncated == true, truncatedPath)

            let shown = try PreviewInspectionResult.read(at: fixtureURL(showcase))
            XCTAssertEqual(shown.sourceDocument?.language, language, showcase)
            XCTAssertFalse(shown.sourceDocument?.highlighting.runs.isEmpty ?? true, showcase)
        }
    }

    func testAPIBlueprintAndCursorMDCUseMarkdownInspectorAndPreserveRawText() throws {
        for (path, id) in [("Showcase/markdown/api.apib", "apib"), ("Showcase/markdown/rule.mdc", "mdc")] {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, path)
            XCTAssertEqual(result.markdownDocument?.raw, String(decoding: bytes, as: UTF8.self), path)
            XCTAssertNotNil(result.markdownDocument?.renderedText, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
        }
    }

    func testAPIBlueprintAndCursorMDCKeepTruncatedMarkdownAvailable() throws {
        for (path, id) in [
            ("Cases/markdown-family/invalid/truncated.apib", "apib"),
            ("Cases/markdown-family/invalid/truncated.mdc", "mdc")
        ] {
            let url = try fixtureURL(path)
            let fullBytes = try Data(contentsOf: url)
            let retained = Data(fullBytes.prefix(48))
            let result = PreviewInspectionResult.prepare(bytes: retained, fileSize: fullBytes.count,
                fileName: url.lastPathComponent, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, path)
            XCTAssertEqual(result.markdownDocument?.raw, String(decoding: retained, as: UTF8.self), path)
            XCTAssertTrue(result.markdownDocument?.diagnostics.contains { $0.code == .truncated } == true, path)
        }
    }

    func testRawTextAndMobileConfigMalformedCasesRetainInput() throws {
        for (path, expectedID) in [("Showcase/text/bezel.bezel", "text"), ("Cases/config/service.conf", "conf")] {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            XCTAssertEqual(result.formatDefinition?.id.rawValue, expectedID, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
            XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self), path)
            XCTAssertNil(result.sourceDocument, path)
        }

        let profileURL = try fixtureURL("Cases/xml/malformed.mobileconfig")
        let profileBytes = try Data(contentsOf: profileURL)
        let profile = try PreviewInspectionResult.read(at: profileURL)
        XCTAssertEqual(profile.formatDefinition?.id.rawValue, "mobileconfig")
        XCTAssertNotNil(profile.xmlInspection)
        XCTAssertEqual(profile.xmlInspection?.rawBytes, profileBytes)
        XCTAssertFalse(profile.xmlInspection?.diagnostics.isEmpty ?? true)
    }
    func testAliasesAndExactFilenamesUseOneShowcasePerFormat() throws {
        for format in FormatCatalog.supported {
            let path = try XCTUnwrap(format.showcaseFixture)
            let showcaseURL = try fixtureURL(path)
            let bytesURL = format.id == .textbundle ? showcaseURL.appendingPathComponent("text.md") : showcaseURL
            let bytes = try Data(contentsOf: bytesURL)
            let extensions = format.id.rawValue == "gcc-linker"
                ? format.extensions.filter { $0 != "d" }
                : format.extensions
            for filename in extensions.map({ "example." + $0 }) + format.exactFilenames {
                let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: filename, systemUTI: nil)
                XCTAssertEqual(result.formatDefinition?.id, format.id, filename)
                let staticMatch = FormatCatalog.match(fileName: filename)?.id
                XCTAssertEqual(staticMatch, format.id == .pemPublicKey ? .sshPublicKey : format.id, filename)
            }
        }
        XCTAssertEqual(FormatCatalog.match(fileName: "Snakefile")?.id, .python)
        XCTAssertEqual(FormatCatalog.match(fileName: "wscript")?.id, .python)
        XCTAssertEqual(FormatCatalog.match(fileName: "Dockerfile")?.id.rawValue, "dockerfile")
        XCTAssertEqual(FormatCatalog.match(fileName: "example.d")?.id.rawValue, "d")
    }

    func testPythonToolingAliasesUseThePythonSourceInspector() throws {
        let aliases = ["pyi", "pyw", "py3", "cpy", "gyp", "gypi", "pxd", "pxi", "rpy"]
        let names = ["SConstruct", "Snakefile", "wscript"]
        let bytes = try Data(contentsOf: fixtureURL("Showcase/source/python.py"))
        for fileName in aliases.map({ "sample." + $0 }) + names {
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id, .python, fileName)
            XCTAssertEqual(result.sourceDocument?.language, .python, fileName)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, fileName)
            XCTAssertEqual(result.originalBytes, bytes, fileName)
        }
    }

    func testRequestedXMLAliasesAndEnvironmentRouting() throws {
        let xmlFixtures = [
            "Cases/requested-formats/xml/designspace.designspace",
            "Cases/requested-formats/xml/model.ecore",
            "Cases/requested-formats/xml/project.ecf",
            "Cases/requested-formats/xml/navigation.ncx",
            "Cases/requested-formats/xml/package.opf"
        ]
        for path in xmlFixtures {
            let url = try fixtureURL(path)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(FormatCatalog.match(fileName: url.lastPathComponent)?.id, .xml, path)
            XCTAssertNotNil(result.xmlInspection?.root, path)
            XCTAssertEqual(result.formatDefinition?.id, .xml, path)
        }
        let dtdURL = try fixtureURL("Showcase/xml/catalog.dtd")
        let dtd = try PreviewInspectionResult.read(at: dtdURL, contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(FormatCatalog.match(fileName: dtdURL.lastPathComponent)?.id, .dtd)
        XCTAssertEqual(dtd.formatDefinition?.id, .dtd)
        XCTAssertNil(dtd.xmlInspection)
        XCTAssertEqual(dtd.analysis.text, String(decoding: dtd.originalBytes, as: UTF8.self))
        XCTAssertEqual(FormatCatalog.match(fileName: ".env")?.id, .dotenv)
        XCTAssertEqual(FormatCatalog.match(fileName: "service.env")?.id, .dotenv)
        XCTAssertEqual(FormatCatalog.match(fileName: "change.diff")?.id, .diff)
        XCTAssertNil(FormatCatalog.match(fileName: "main.dart"))
    }
    func testBrowserSearchIncludesAliasesAndPlannedFormatsWithoutClaimingSupport() {
        XCTAssertTrue(FormatCatalog.search("pyi").contains { $0.id == .python })
        XCTAssertTrue(FormatCatalog.search("Snakefile").contains { $0.id == .python })
        XCTAssertTrue(FormatCatalog.search("docker").contains { $0.id.rawValue == "dockerfile" && $0.status == .supported })
        XCTAssertEqual(FormatCatalog.search(".swift").map(\.id), [.swift])
    }

    func testRequestedXMLAppleAndRawFormatAliases() throws {
        for filename in ["View.xaml", "page.xhtml", "layout.xul"] {
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, .xml, filename)
        }
        XCTAssertEqual(FormatCatalog.match(fileName: "types.xsd")?.id, .xsd)
        XCTAssertEqual(FormatCatalog.match(fileName: "layout.xsl")?.id, .xslt)
        XCTAssertEqual(FormatCatalog.match(fileName: "page.xslt")?.id, .xslt)
        XCTAssertEqual(FormatCatalog.match(fileName: "Run.xcscheme")?.id, .xcscheme)
        XCTAssertEqual(FormatCatalog.match(fileName: "Localizable.strings")?.id, .strings)
        XCTAssertEqual(FormatCatalog.match(fileName: "Localizable.stringsdict")?.id, .stringsdict)
        XCTAssertEqual(FormatCatalog.match(fileName: "Localizable.xcstrings")?.id, .xcstrings)
        XCTAssertEqual(FormatCatalog.match(fileName: "PrivacyInfo.xcprivacy")?.id, .privacyManifest)
        XCTAssertEqual(FormatCatalog.match(fileName: "UnitTests.xctestplan")?.id, .xcodeTestPlan)
        XCTAssertEqual(FormatCatalog.match(fileName: "demo.spdx.yaml")?.id, .spdxYAML)
        XCTAssertEqual(FormatCatalog.match(fileName: "demo.spdx.yml")?.id, .spdxYAML)
        XCTAssertEqual(FormatCatalog.match(fileName: "App.entitlements")?.id, .entitlements)
        XCTAssertEqual(FormatCatalog.match(fileName: "Info.plist")?.id, .infoPlist)
        XCTAssertEqual(FormatCatalog.match(fileName: "id_ed25519.pub")?.id, .sshPublicKey)
        for filename in ["query.xquery", "query.xq", "query.xu"] {
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id.rawValue, "xquery", filename)
        }
        XCTAssertEqual(FormatCatalog.match(fileName: "settings.yaml")?.id, .yaml)
        XCTAssertEqual(FormatCatalog.match(fileName: "script.zsh")?.id, .shell)
        XCTAssertEqual(FormatCatalog.match(fileName: "build.zon")?.id, .json)
        XCTAssertEqual(FormatCatalog.match(fileName: "source.zig")?.id.rawValue, "zig")
    }

    func testRequestedFixturesUseSemanticInspectorsOrPreserveRaw() throws {
        let routes: [(String, FormatID)] = [
            ("xaml.xaml", .xml), ("sample.xcscheme", .xcscheme), ("page.xhtml", .xml),
            ("schema.xsd", .xsd), ("layout.xul", .xml), ("app.entitlements", .entitlements),
            ("binary.entitlements", .entitlements), ("localizable.strings", .strings),
            ("localizable.stringsdict", .stringsdict), ("config.yaml", .yaml),
            ("script.zsh", .shell), ("query.xquery", .init(rawValue: "xquery")),
            ("query.xq", .init(rawValue: "xquery")), ("query.xu", .init(rawValue: "xquery")),
            ("build.zon", .json)
        ]
        for (filename, expectedID) in routes {
            let url = try fixtureURL("Cases/requested-formats/\(filename)")
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.formatDefinition?.id, expectedID, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
        }

        for filename in ["app.entitlements", "localizable.strings", "localizable.stringsdict", "binary.entitlements"] {
            let result = try PreviewInspectionResult.read(at: fixtureURL("Cases/requested-formats/\(filename)"), contentTypeIdentifier: { _ in nil })
            XCTAssertNotNil(result.plistInspection?.content, filename)
            XCTAssertNotNil(result.plistInspection?.prettyText, filename)
        }
        let zon = try PreviewInspectionResult.read(at: fixtureURL("Cases/requested-formats/build.zon"), contentTypeIdentifier: { _ in nil })
        XCTAssertNotNil(zon.jsonInspection?.content)
        XCTAssertTrue(try XCTUnwrap(zon.jsonInspection?.prettyText).contains("\"fingerprint\": 4660"))
        XCTAssertEqual(zon.jsonInspection?.rawBytes, zon.originalBytes)

        let zig = try PreviewInspectionResult.read(at: fixtureURL("Showcase/source/zig.zig"), contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(zig.sourceDocument?.language, .zig)
        XCTAssertFalse(zig.sourceDocument?.highlighting.runs.isEmpty ?? true)
        let zsh = try PreviewInspectionResult.read(at: fixtureURL("Cases/requested-formats/script.zsh"), contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(zsh.sourceDocument?.language, .shell)
        XCTAssertFalse(zsh.sourceDocument?.highlighting.runs.isEmpty ?? true)
        let query = try PreviewInspectionResult.read(at: fixtureURL("Cases/requested-formats/query.xquery"), contentTypeIdentifier: { _ in nil })
        XCTAssertEqual(query.sourceDocument?.language, .xquery)
        XCTAssertFalse(query.sourceDocument?.highlighting.runs.isEmpty ?? true)
        XCTAssertNil(query.xmlInspection)
        XCTAssertEqual(query.analysis.text, String(decoding: query.originalBytes, as: UTF8.self))
    }

    func testRequestedMalformedFixturesKeepRawAndDiagnostics() throws {
        for filename in ["xaml.xaml", "app.entitlements", "localizable.strings", "localizable.stringsdict",
                         "sample.xcscheme", "page.xhtml", "schema.xsd", "layout.xul", "config.yaml", "build.zon"] {
            let url = try fixtureURL("Cases/requested-formats/invalid/\(filename)")
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self), filename)
            XCTAssertTrue(result.statusSummary.items.contains { $0.kind == .warning }, filename)
        }
        let externalXSD = try PreviewInspectionResult.read(at: fixtureURL("Cases/requested-formats/invalid/schema.xsd"), contentTypeIdentifier: { _ in nil })
        XCTAssertNil(externalXSD.xmlInspection?.root)
        for filename in ["script.zsh", "broken.zig"] {
            let url = try fixtureURL("Cases/requested-formats/invalid/\(filename)")
            let bytes = try Data(contentsOf: url)
            let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })
            XCTAssertEqual(result.sourceDocument?.source, String(decoding: bytes, as: UTF8.self), filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
        }
    }

    func testSupportedCatalogUsesSpecificUTIsAndTypeScriptDoesNotInventPublicAliases() throws {
        XCTAssertEqual(FormatCatalog.definition(for: .dotenv)?.contentTypeIdentifiers, [])
        XCTAssertEqual(FormatCatalog.definition(for: .properties)?.contentTypeIdentifiers, ["com.glimt.app.java-properties"])
        let filenameOnlyFormats: Set<FormatID> = [
            .properties, .editorconfig, .gitignore, .dockerignore, .npmrc, .gitattributes, .gitmodules, .systemdUnit,
            .goModule,
            .init(rawValue: "ada"), .init(rawValue: "actionscript"), .init(rawValue: "assembly"),
            .init(rawValue: "awk"), .jsx, FormatID(rawValue: "matlab"),
            FormatID(rawValue: "fsharp"), FormatID(rawValue: "fish"), FormatID(rawValue: "fortran"),
            FormatID(rawValue: "gdscript"), FormatID(rawValue: "gleam"), FormatID(rawValue: "go"),
            FormatID(rawValue: "groovy"), FormatID(rawValue: "haskell"), FormatID(rawValue: "gradle"),
            FormatID(rawValue: "gcc-linker"), FormatID.haml, FormatID.jsp,
            .init(rawValue: "zig"), .init(rawValue: "xquery"),
            .d, .batch, .dylan, .eiffel, .elixir, .erlang, .dtd, .dockerfile,
            .html, .sql, .rust, .php, .ruby, .zip, .pemCertificate, .derCertificate,
            .mobileprovision, .jwt, .jwk, .jwks, .cyclonedxSBOM, .spdxSBOM,
            .cyclonedxSBOMXML, .cyclonedxSBOMProtobuf, .spdxTagValue, .spdxYAML, .privacyManifest, .xcodeTestPlan,
            .sqlite, .tarArchive, .codeResources,
            .xcconfig, .pbxproj, .xcworkspace, .nix, .cue, .kdl,
            FormatID(rawValue: "visual-basic"), FormatID(rawValue: "vala"), FormatID(rawValue: "vimscript"),
            .dotenv, .infoPlist, .entitlements, .sshPublicKey, .fstab,
            .init(rawValue: "nginx"), .init(rawValue: "apache"), FormatID(rawValue: "reference-bison"), FormatID(rawValue: "graphviz"),
            .strings, .stringsdict, .xcstrings, .xcscheme, .csr,
            .storyboard, .xib, .xsd, .xslt, .rst, .quarto, .mdx, .pemPublicKey,
            .latex, .jenkinsfile, .meson, .plsql, .tsql, .nim, .openscad, .webAssemblyText, .pascal, .verilog, .vhdl,
            .cobol, .deviceTree, .gettext, .erb, .qml, .solidity, .org, .mdc, .apib
        ]
        XCTAssertTrue(FormatCatalog.supported.allSatisfy {
            !$0.contentTypeIdentifiers.isEmpty || filenameOnlyFormats.contains($0.id)
        })
        XCTAssertEqual(FormatCatalog.definition(for: .typescript)?.contentTypeIdentifiers, ["com.microsoft.typescript"])
        for (format, identifier) in [
            (FormatID.objectiveC, "com.glimt.objective-c-source"), (FormatID.perl, "com.glimt.perl-source"),
            (FormatID(rawValue: "ocaml"), "com.glimt.ocaml-source"), (FormatID(rawValue: "tcl-tk"), "com.glimt.tcl-source"),
            (FormatID(rawValue: "applescript"), "com.glimt.applescript-source"),
            (FormatID.r, "com.glimt.r-source"), (FormatID.scala, "com.glimt.scala-source"),
            (FormatID.julia, "com.glimt.julia-source")
        ] {
            XCTAssertEqual(FormatCatalog.definition(for: format)?.contentTypeIdentifiers, [identifier])
        }
        for (format, identifier) in [
            (FormatID.terraform, "com.glimt.terraform-source"), (FormatID.scss, "com.glimt.scss-source"),
            (FormatID.tsx, "com.glimt.tsx-source"), (FormatID.vue, "com.glimt.vue-source"),
            (FormatID.svelte, "com.glimt.svelte-source"), (FormatID.asciidoc, "com.glimt.asciidoc")
        ] {
            XCTAssertEqual(FormatCatalog.definition(for: format)?.contentTypeIdentifiers, [identifier])
            XCTAssertNotNil(FormatCatalog.source(forSystemType: identifier))
        }
        for identifier in ["public.typescript", "public.typescript-source", "public.tsx", "public.java-source", "public.javascript", "public.utf8-plain-text"] {
            XCTAssertFalse(FormatCatalog.supported.contains { $0.contentTypeIdentifiers.contains(identifier) }, identifier)
        }
    }

    func testLogCatalogRoutesCommonLogFileSuffixesToTheSharedInspector() {
        let log = FormatCatalog.definition(for: .log)
        XCTAssertEqual(log?.extensions, ["log", "syslog", "cef", "leef"])
        XCTAssertEqual(log?.effectiveInspectorID, .log)
        XCTAssertTrue(["events.log", "events.syslog", "events.cef", "events.leef"].allSatisfy {
            FormatCatalog.match(fileName: $0)?.id == .log
        })
        XCTAssertTrue(log?.contentTypeIdentifiers.contains("com.glimt.log") == true)
    }
    func testInquirySharesCatalogIdentityAndRecognizesSupportedFormats() throws {
        let swiftURL = try fixtureURL("Showcase/source/swift.swift")
        let swift = try PreviewInspectionResult.read(at: swiftURL)
        let report = InquiryReport.make(url: swiftURL, inspection: swift)
        XCTAssertTrue(report.details.contains("Catalog format: Swift (swift)"))
        XCTAssertTrue(report.details.contains("Showcase: Showcase/source/swift.swift"))
        let url = try fixtureURL("Cases/ambiguous/Dockerfile")
        let fallback = try PreviewInspectionResult.read(at: url)
        XCTAssertEqual(fallback.formatDefinition?.id.rawValue, "dockerfile")
        let inquiry = InquiryReport.make(url: url, inspection: fallback)
        XCTAssertTrue(inquiry.details.contains("Catalog format: Dockerfile (dockerfile)"))
        XCTAssertTrue(inquiry.summary.contains("Supported in Glimt."))
        XCTAssertFalse(inquiry.summary.contains("Plain Text fallback"))
    }

    func testNixCUEAndKDLUseCataloguedSourceInspection() throws {
        let fixtures: [(String, String, String, String, SyntaxTokenKind)] = [
            ("Showcase/build/flake.nix", "flake.nix", "nix", "let", .keyword),
            ("Showcase/config/service.cue", "service.cue", "cue", "package", .keyword),
            ("Showcase/config/service.kdl", "service.kdl", "kdl", "true", .keyword)
        ]

        for (path, filename, id, marker, tokenKind) in fixtures {
            let definition = try XCTUnwrap(FormatCatalog.match(fileName: filename), filename)
            XCTAssertEqual(definition.id.rawValue, id, filename)
            XCTAssertEqual(definition.status, .supported, filename)
            XCTAssertEqual(definition.inspectionKind, .source, filename)
            XCTAssertEqual(definition.availableRepresentations, [.source, .raw, .hex], filename)
            XCTAssertEqual(definition.showcaseFixture, path, filename)

            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            let document = try XCTUnwrap(result.sourceDocument, filename)
            XCTAssertEqual(result.formatDefinition?.id, definition.id, filename)
            XCTAssertEqual(document.source, String(decoding: bytes, as: UTF8.self), filename)
            XCTAssertEqual(document.language.rawValue, id, filename)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .comment }, filename)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .string }, filename)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .number }, filename)
            let tokens = document.highlighting.runs.map {
                ((document.source as NSString).substring(with: $0.range), $0.kind)
            }
            XCTAssertTrue(tokens.contains { $0.0 == marker && $0.1 == tokenKind }, filename)
            XCTAssertEqual(document.diagnostics, [], filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
        }
    }

    func testNixCUEAndKDLMalformedAndTruncatedInputsRetainSource() throws {
        for (path, filename, id) in [
            ("nix/malformed.nix", "broken.nix", "nix"),
            ("cue/malformed.cue", "broken.cue", "cue"),
            ("kdl/malformed.kdl", "broken.kdl", "kdl")
        ] {
            let fixturePath = "Cases/fileformats/\(path)"
            let bytes = try Data(contentsOf: fixtureURL(fixturePath))
            let result = try PreviewInspectionResult.read(at: fixtureURL(fixturePath))
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, filename)
            XCTAssertEqual(result.sourceDocument?.source, String(decoding: bytes, as: UTF8.self), filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertEqual(result.sourceDocument?.diagnostics, [], filename)
        }

        for (path, filename, id) in [
            ("nix/truncated.nix", "partial.nix", "nix"),
            ("cue/truncated.cue", "partial.cue", "cue"),
            ("kdl/truncated.kdl", "partial.kdl", "kdl")
        ] {
            let bytes = try Data(contentsOf: fixtureURL("Cases/fileformats/\(path)"))
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count + 1,
                                                        fileName: filename, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, filename)
            XCTAssertEqual(result.sourceDocument?.source, String(decoding: bytes, as: UTF8.self), filename)
            XCTAssertTrue(result.sourceDocument?.truncated == true, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
        }
    }

    func testFormatDefinitionsDeclareModuleContractAndPreserveOriginalBytes() throws {
        for definition in FormatCatalog.supported {
            XCTAssertNotNil(definition.inspectorID, definition.displayName)
            if [.sshPublicKey, .pemPublicKey].contains(definition.id) {
                XCTAssertNil(definition.detectionRules, "SSH and PEM public keys share .pub and require content probing")
            } else {
                XCTAssertNotNil(definition.detectionRules, definition.displayName)
            }
            XCTAssertNotNil(definition.settingsProfile, definition.displayName)
            XCTAssertNotNil(definition.thumbnailStrategy, definition.displayName)
            if !definition.availableRepresentations.isEmpty {
                XCTAssertNotNil(definition.defaultRepresentation, definition.displayName)
            }
            XCTAssertTrue(FormatInspectorRegistry.builtIn.contains(definition.effectiveInspectorID), definition.displayName)
            if definition.sourceLanguage != nil {
                let expectedViews: [FormatDefinition.RepresentationID] = [.toml, .ini, .dotenv, .properties,
                                                                           .editorconfig, .gitignore, .dockerignore,
                                                                           .npmrc, .gitmodules, .gitattributes, .systemdUnit, .goModule].contains(definition.id)
                    ? [.source, .raw] : [.source, .raw, .hex]
                XCTAssertEqual(definition.availableRepresentations, expectedViews, definition.displayName)
                XCTAssertEqual(definition.presentationOrder, expectedViews, definition.displayName)
                XCTAssertEqual(definition.effectiveDefaultRepresentation, .source, definition.displayName)
            }
        }
        XCTAssertEqual(FormatCatalog.definition(for: .json)?.availableRepresentations, [.tree, .pretty, .raw, .hex])
        XCTAssertEqual(FormatCatalog.definition(for: .json)?.presentationOrder, [.raw, .pretty, .tree, .hex])
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.presentationOrder ?? FormatCatalog.definition(for: .swift)?.availableRepresentations,
                       [.source, .raw, .hex])
        XCTAssertEqual(FormatCatalog.definition(for: .csv)?.presentationOrder ?? FormatCatalog.definition(for: .csv)?.availableRepresentations,
                       [.table, .raw, .hex])
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.sourceLanguage, .swift)
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.availableRepresentations, [.source, .raw, .hex])
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.inspectorID, .source)
        XCTAssertEqual(FormatCatalog.definition(for: .json)?.inspectorID, .json)
        XCTAssertEqual(FormatCatalog.definition(for: .json)?.defaultRepresentation, .tree)
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.defaultRepresentation, .source)
        XCTAssertEqual(FormatCatalog.definition(for: .swift)?.thumbnailStrategy, .sourceCode)
        XCTAssertEqual(FormatCatalog.definition(for: .csv)?.availableRepresentations, [.table, .raw, .hex])
        XCTAssertEqual(FormatCatalog.definition(for: .tsv)?.inspectorID, .csv)
        XCTAssertEqual(FormatCatalog.definition(for: .csv)?.tableDelimiter, .comma)
        XCTAssertEqual(FormatCatalog.definition(for: .tsv)?.tableDelimiter, .tab)
        XCTAssertEqual(FormatCatalog.definition(for: .csv)?.thumbnailStrategy, .table)
        XCTAssertEqual(FormatCatalog.match(fileName: "report.tsv")?.id, .tsv)
        XCTAssertEqual(FormatCatalog.match(fileName: "report.csv")?.id, .csv)
        XCTAssertFalse(FormatCatalog.definition(for: .json)?.resolvedDetectionRules.isEmpty ?? true)
        let docker = try PreviewInspectionResult.read(at: fixtureURL("Cases/ambiguous/Dockerfile"))
        XCTAssertEqual(docker.formatDefinition?.id.rawValue, "dockerfile")
        XCTAssertEqual(docker.resolution.typeID, "dockerfile")
        XCTAssertEqual(docker.formatDefinition?.status, .supported)
        XCTAssertEqual(docker.sourceDocument?.language, .dockerfile)
        XCTAssertTrue(docker.sourceDocument?.highlighting.runs.contains { $0.kind == .keyword } == true)
        XCTAssertTrue(docker.formatDefinition?.availableRepresentations.contains(.hex) == true)
        XCTAssertEqual(docker.originalBytes, try Data(contentsOf: fixtureURL("Cases/ambiguous/Dockerfile")))
    }

    func testXcodeProjectConfigurationAndWorkspaceUseFormatInspectors() throws {
        let configuration = try PreviewInspectionResult.read(at: fixtureURL("Showcase/apple/Debug.xcconfig"))
        XCTAssertEqual(configuration.formatDefinition?.id, .xcconfig)
        XCTAssertEqual(configuration.sourceDocument?.language, .xcconfig)
        XCTAssertTrue(configuration.sourceDocument?.highlighting.runs.contains { $0.kind == .directive } == true)

        let project = try PreviewInspectionResult.read(at: fixtureURL("Showcase/apple/project.pbxproj"))
        XCTAssertEqual(project.formatDefinition?.id, .pbxproj)
        XCTAssertNotNil(project.plistInspection?.content)
        XCTAssertTrue(project.plistInspection?.diagnostics.isEmpty == true)

        let workspace = try PreviewInspectionResult.read(at: fixtureURL("Showcase/apple/contents.xcworkspacedata"))
        XCTAssertEqual(workspace.formatDefinition?.id, .xcworkspace)
        XCTAssertNotNil(workspace.xmlInspection?.root)
        XCTAssertTrue(workspace.xmlInspection?.diagnostics.isEmpty == true)

        let malformedProject = Data("{ objects = { broken = ; } }".utf8)
        let malformed = PreviewInspectionResult.prepare(bytes: malformedProject, fileSize: malformedProject.count,
                                                        fileName: "Broken.pbxproj", systemUTI: nil)
        XCTAssertEqual(malformed.formatDefinition?.id, .pbxproj)
        XCTAssertEqual(malformed.plistInspection?.rawBytes, malformedProject)
        XCTAssertFalse(malformed.plistInspection?.diagnostics.isEmpty ?? true)

        let truncatedProject = Data("{ rootObject = ".utf8)
        let truncated = PreviewInspectionResult.prepare(bytes: truncatedProject, fileSize: truncatedProject.count + 1,
                                                         fileName: "Truncated.pbxproj", systemUTI: nil)
        XCTAssertEqual(truncated.formatDefinition?.id, .pbxproj)
        XCTAssertEqual(truncated.plistInspection?.rawBytes, truncatedProject)
        XCTAssertTrue(truncated.plistInspection?.diagnostics.contains { $0.code == .truncated } == true)

        let malformedWorkspaceBytes = Data("<Workspace><FileRef>".utf8)
        let malformedWorkspace = PreviewInspectionResult.prepare(bytes: malformedWorkspaceBytes,
            fileSize: malformedWorkspaceBytes.count, fileName: "contents.xcworkspacedata", systemUTI: nil)
        XCTAssertEqual(malformedWorkspace.formatDefinition?.id, .xcworkspace)
        XCTAssertEqual(malformedWorkspace.xmlInspection?.rawBytes, malformedWorkspaceBytes)
        XCTAssertFalse(malformedWorkspace.xmlInspection?.diagnostics.isEmpty ?? true)
    }

    func testRequestedFileFormatsRouteToSyntaxOrRawTextWithValidAndEdgeFixtures() throws {
        let groups: [(extensions: [String], id: FormatID, language: SourceLanguage?)] = [
            (["nf", "mll", "mly"], .text, nil),
            (["nim"], FormatID.nim, .nim),
            (["scad"], FormatID.openscad, .openSCAD),
            (["wat"], FormatID.webAssemblyText, .webAssemblyText),
            (["pas", "dpr", "dpk", "lpr"], FormatID.pascal, .pascal),
            (["vh"], FormatID.verilog, .verilog),
            (["vhd", "vhdl"], FormatID.vhdl, .vhdl),
            (["cob", "cbl"], FormatID.cobol, .cobol),
            (["dts", "dtsi"], FormatID.deviceTree, .deviceTree),
            (["po", "pot"], FormatID.gettext, .gettext),
            (["erb"], FormatID(rawValue: "erb"), .erb),
            (["qml"], FormatID(rawValue: "qml"), .qml),
            (["sol"], FormatID(rawValue: "solidity"), .solidity),
            (["pas", "dpr", "dpk", "lpr"], FormatID.pascal, .pascal),
            (["vh"], FormatID.verilog, .verilog),
            (["vhd", "vhdl"], FormatID.vhdl, .vhdl),
            (["ml", "mli"], FormatID(rawValue: "ocaml"), .ocaml),
            (["cjs"], .javascript, .javascript), (["fea"], .text, nil),
            (["otio"], .json, nil), (["opml"], .xml, nil),
            (["fnc", "prc", "trg", "pks", "pkb", "pck", "tps", "tpb"], FormatID(rawValue: "plsql"), .plsql),
            (["typ", "tab", "avt", "con", "sqs", "vw", "mvw"], .text, nil)
        ]

        for group in groups {
            for ext in group.extensions {
                let filename = "valid.\(ext)"
                XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, group.id, filename)
                let validURL = try fixtureURL("Cases/fileformats/\(filename)")
                let valid = try PreviewInspectionResult.read(at: validURL)
                XCTAssertFalse(valid.analysis.isBinary, filename)
                XCTAssertEqual(valid.originalBytes, try Data(contentsOf: validURL), filename)
                if let language = group.language {
                    XCTAssertEqual(valid.sourceDocument?.language, language, filename)
                    XCTAssertFalse(valid.sourceDocument?.highlighting.runs.isEmpty ?? true, filename)
                } else if group.id == .text {
                    XCTAssertNil(valid.sourceDocument, filename)
                    XCTAssertEqual(valid.formatDefinition?.id, .text, filename)
                }
                if ext == "otio" { XCTAssertNotNil(valid.jsonInspection, filename) }
                if ext == "opml" { XCTAssertNotNil(valid.xmlInspection, filename) }

                let edgeName = "edge.\(ext)"
                XCTAssertEqual(FormatCatalog.match(fileName: edgeName)?.id, group.id, edgeName)
                let edge = try PreviewInspectionResult.read(at: fixtureURL("Cases/fileformats/\(edgeName)"))
                XCTAssertFalse(edge.analysis.isBinary, edgeName)
                XCTAssertFalse(edge.analysis.text.isEmpty, edgeName)
                XCTAssertEqual(edge.originalBytes, try Data(contentsOf: fixtureURL("Cases/fileformats/\(edgeName)")), edgeName)
                if group.id == .text { XCTAssertNil(edge.sourceDocument, edgeName) }
            }
        }

        for filename in ["valid.pub", "edge.pub"] {
            let url = try fixtureURL("Cases/fileformats/\(filename)")
            let result = try PreviewInspectionResult.read(at: url)
            XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id, .sshPublicKey, filename)
            XCTAssertEqual(result.formatDefinition?.id, .sshPublicKey, filename)
            XCTAssertNil(result.sourceDocument, filename)
            XCTAssertEqual(result.originalBytes, try Data(contentsOf: url), filename)
        }
    }

    func testPascalAndVerilogSharedSuffixesRequireContentEvidence() {
        let pascalText = "unit Demo; interface implementation begin end.\n"
        let pascalBytes = Data(pascalText.utf8)
        let pascal = PreviewInspectionResult.prepare(bytes: pascalBytes, fileSize: pascalBytes.count,
            fileName: "demo.pp", systemUTI: nil)
        XCTAssertEqual(pascal.formatDefinition?.id, .pascal)
        XCTAssertEqual(pascal.sourceDocument?.language, .pascal)

        let puppetText = "class profile { package { 'module': ensure => installed } }\n"
        let puppetBytes = Data(puppetText.utf8)
        let puppet = PreviewInspectionResult.prepare(bytes: puppetBytes, fileSize: puppetBytes.count,
            fileName: "manifest.pp", systemUTI: nil)
        XCTAssertNil(puppet.sourceDocument)
        XCTAssertNotEqual(puppet.formatDefinition?.id, .pascal)

        let verilogText = "module counter(input logic clk); always_ff @(posedge clk) begin end endmodule\n"
        let verilogBytes = Data(verilogText.utf8)
        let verilog = PreviewInspectionResult.prepare(bytes: verilogBytes, fileSize: verilogBytes.count,
            fileName: "counter.v", systemUTI: nil)
        XCTAssertEqual(verilog.formatDefinition?.id, .verilog)
        XCTAssertEqual(verilog.sourceDocument?.language, .verilog)

        let vText = "module main\npub fn main() { println('hello') }\n"
        let vBytes = Data(vText.utf8)
        let v = PreviewInspectionResult.prepare(bytes: vBytes, fileSize: vBytes.count,
            fileName: "main.v", systemUTI: nil)
        XCTAssertNil(v.sourceDocument)
    }

    func testCSVAndTSVShareCatalogBackedInspectorAndShowcase() throws {
        for (format, path) in [(FormatID.csv, "Showcase/data/csv.csv"), (FormatID.tsv, "Showcase/data/tsv.tsv")] {
            let definition = try XCTUnwrap(FormatCatalog.definition(for: format))
            XCTAssertEqual(definition.inspectorID, .csv)
            XCTAssertEqual(definition.showcaseFixture, path)
            let result = try PreviewInspectionResult.read(at: fixtureURL(path))
            XCTAssertEqual(result.formatDefinition?.id, format)
            XCTAssertNotNil(result.csvInspection?.table)
            XCTAssertEqual(result.csvInspection?.rawBytes, try Data(contentsOf: fixtureURL(path)))
        }
    }

    func testJSONLinesRecognizesBothExtensionsAndPreservesRawForMalformedRecords() throws {
        for (filename, path) in [
            ("events.jsonl", "Showcase/jsonl/events.jsonl"),
            ("records.ndjson", "Cases/jsonl/valid/records.ndjson")
        ] {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: filename, systemUTI: nil)
            XCTAssertEqual(result.formatDefinition?.id, .jsonl, filename)
            let recordCount: Int
            if case .array(let records)? = result.additionalStructuredContent { recordCount = records.count }
            else { XCTFail("Expected JSON Lines records for \(filename)"); continue }
            XCTAssertEqual(recordCount, filename == "events.jsonl" ? 2 : 5, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertFalse(result.inspectionDiagnostics.contains { $0.code == .parseError }, filename)
        }

        let data = try Data(contentsOf: fixtureURL("Cases/jsonl/valid/records.ndjson"))
        let utiRouted = PreviewInspectionResult.prepare(bytes: data, fileSize: data.count, fileName: "events",
                                                        systemUTI: "com.glimt.json-lines")
        XCTAssertEqual(utiRouted.formatDefinition?.id, .jsonl)

        let malformedBytes = try Data(contentsOf: fixtureURL("Cases/jsonl/invalid/malformed.jsonl"))
        let malformed = PreviewInspectionResult.prepare(bytes: malformedBytes, fileSize: malformedBytes.count,
                                                       fileName: "broken.jsonl", systemUTI: nil)
        XCTAssertEqual(malformed.formatDefinition?.id, .jsonl)
        if case .array(let records)? = malformed.additionalStructuredContent { XCTAssertEqual(records.count, 3) }
        else { XCTFail("Expected malformed records to remain visible in Tree") }
        XCTAssertTrue(malformed.inspectionDiagnostics.contains { $0.code == .parseError })
        XCTAssertEqual(malformed.originalBytes, malformedBytes)
        XCTAssertEqual(malformed.analysis.text, String(decoding: malformedBytes, as: UTF8.self))
    }

    func testAdditionalDocumentedFormatAliasesUseTheirSharedInspectors() throws {
        for extensionName in ["lay", "mpd", "csproj"] {
            XCTAssertEqual(FormatCatalog.match(fileName: "sample.\(extensionName)")?.id, .xml)
            let result = PreviewInspectionResult.prepare(
                bytes: Data("<project />".utf8), fileSize: 11,
                fileName: "sample.\(extensionName)", systemUTI: nil
            )
            XCTAssertNotNil(result.xmlInspection, extensionName)
        }

        for extensionName in ["mq4", "mq5"] {
            XCTAssertEqual(FormatCatalog.match(fileName: "sample.\(extensionName)")?.id, .cpp)
            let result = PreviewInspectionResult.prepare(
                bytes: Data("int main() { return 0; }".utf8), fileSize: 24,
                fileName: "sample.\(extensionName)", systemUTI: nil
            )
            XCTAssertEqual(result.sourceDocument?.language, .cpp, extensionName)
        }

        XCTAssertEqual(FormatCatalog.match(fileName: "sample.xm")?.id.rawValue, "logos")

        XCTAssertEqual(FormatCatalog.match(fileName: "guide.rmd")?.id, .rmarkdown)
        XCTAssertEqual(FormatCatalog.match(fileName: ".vimrc")?.id.rawValue, "vimscript")
        XCTAssertEqual(FormatCatalog.match(fileName: "gvimrc")?.id.rawValue, "vimscript")
        XCTAssertEqual(FormatCatalog.definition(for: .markdown)?.availableRepresentations, [.rendered, .source])
        XCTAssertEqual(SourceDetector.detect(
            fileName: "script.ksh",
            analysis: TextAnalysis.analyze(bytes: Data("echo ok\n".utf8), fileSize: 8, maximumBytes: 8)
        ).language, .shell)
    }

    func testRequestedFormatExtensionsResolveToTheirOwnShowcasesAndFallbacks() throws {
        let cases: [(String, String)] = [
            ("kmt", "kermeta"), ("ksh", "shell"), ("kt", "kotlin"), ("kts", "kotlin"),
            ("less", "less"), ("ly", "lilypond"), ("ily", "lilypond"),
            ("tf", "terraform"), ("tfvars", "terraform"), ("scss", "scss"), ("tsx", "tsx"),
            ("vue", "vue"), ("svelte", "svelte"), ("adoc", "asciidoc"), ("asciidoc", "asciidoc"),
            ("lisp", "lisp"), ("lsp", "lisp"), ("asd", "lisp"), ("el", "lisp"),
            ("xm", "logos"), ("lua", "lua"), ("mk", "make"), ("mak", "make"),
            ("lay", "xml"), ("md", "markdown"), ("rmd", "rmarkdown"), ("mpd", "xml"),
            ("mq4", "cpp"), ("mq5", "cpp"), ("mf", "mf"), ("asp", "asp"), ("aspx", "aspx"),
            ("jinja", "jinja"), ("twig", "twig"),
            ("psm1", "powershell"), ("psd1", "powershell"), ("ps1", "powershell"),
            ("vb", "visual-basic"), ("vala", "vala"),
            ("vim", "vimscript"),
            ("csproj", "xml"), ("ms", "miniscript")
        ]
        for (fileExtension, expectedID) in cases {
            let filename = "sample.\(fileExtension)"
            let format = try XCTUnwrap(FormatCatalog.match(fileName: filename), filename)
            XCTAssertEqual(format.id.rawValue, expectedID, filename)
            XCTAssertEqual(format.status, .supported, filename)
            XCTAssertNotNil(format.showcaseFixture, filename)
            let fixture = try XCTUnwrap(format.showcaseFixture)
            let result = try PreviewInspectionResult.read(at: fixtureURL(fixture))
            XCTAssertEqual(result.formatDefinition?.id, format.id, filename)
            XCTAssertFalse(result.analysis.isBinary, filename)
            if format.sourceLanguage != nil {
                XCTAssertNotNil(result.sourceDocument?.highlighting.runs.first, filename)
            } else if format.inspectionKind == .text {
                XCTAssertEqual(format.availableRepresentations, [.raw], filename)
            }

            for variant in format.showcaseVariants ?? [] {
                let variantBytes = try Data(contentsOf: fixtureURL(variant.path))
                let variantResult = PreviewInspectionResult.prepare(
                    bytes: variantBytes, fileSize: variantBytes.count,
                    fileName: URL(fileURLWithPath: variant.path).lastPathComponent, systemUTI: nil
                )
                XCTAssertEqual(variantResult.formatDefinition?.id, format.id, variant.title)
            }

            let malformed = try Data(contentsOf: fixtureURL("Cases/fileformats/\(fileExtension)/malformed.\(fileExtension)"))
            let malformedResult = PreviewInspectionResult.prepare(
                bytes: malformed, fileSize: malformed.count, fileName: filename, systemUTI: nil
            )
            XCTAssertEqual(malformedResult.formatDefinition?.id, format.id, "malformed \(filename)")
            XCTAssertEqual(malformedResult.originalBytes, malformed, "raw preservation for \(filename)")

            let truncated = try Data(contentsOf: fixtureURL("Cases/fileformats/\(fileExtension)/truncated.\(fileExtension)"))
            let truncatedResult = PreviewInspectionResult.prepare(
                bytes: truncated, fileSize: truncated.count + 1, fileName: filename, systemUTI: nil
            )
            XCTAssertTrue(truncatedResult.analysis.truncated, "truncated \(filename)")

            let binaryResult = PreviewInspectionResult.prepare(
                bytes: Data([0, 0xff, 0]), fileSize: 3, fileName: filename, systemUTI: nil
            )
            XCTAssertTrue(binaryResult.analysis.isBinary, "binary \(filename)")
            XCTAssertNil(binaryResult.sourceDocument, "binary input must not be highlighted: \(filename)")
        }
    }

    func testCommonSourceLanguageAliasesRouteToTheirCanonicalFormats() {
        for fileName in ["sample.vbs", "sample.bas", "sample.basic", "sample.bi"] {
            XCTAssertEqual(FormatCatalog.match(fileName: fileName)?.id.rawValue, "visual-basic", fileName)
        }
        XCTAssertEqual(FormatCatalog.match(fileName: "sample.vapi")?.id.rawValue, "vala")
        for fileName in [".vimrc", ".gvimrc", "_vimrc", "_gvimrc", "vimrc", "gvimrc"] {
            XCTAssertEqual(FormatCatalog.match(fileName: fileName)?.id.rawValue, "vimscript", fileName)
        }
    }

    func testDiffPatchFlowsThroughCatalogAndPreservesRawSource() throws {
        let path = "Showcase/diff/changes.patch"
        let url = try fixtureURL(path)
        let bytes = try Data(contentsOf: url)
        let result = try PreviewInspectionResult.read(at: url, contentTypeIdentifier: { _ in nil })

        XCTAssertEqual(FormatCatalog.definition(for: .diff)?.contentTypeIdentifiers, ["public.patch-file"])
        XCTAssertEqual(result.formatDefinition?.id, .diff)
        XCTAssertEqual(result.diffInspection?.files.first?.oldPath, "settings/example.json")
        XCTAssertEqual(result.diffInspection?.files.first?.newPath, "settings/example.json")
        XCTAssertEqual(result.diffInspection?.addedLineCount, 2)
        XCTAssertEqual(result.diffInspection?.removedLineCount, 1)
        XCTAssertEqual(result.diffInspection?.rawText, String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(result.originalBytes, bytes)
        XCTAssertEqual(result.formatDefinition?.availableRepresentations, [.diff, .raw])
    }

    func testFormatIDEncodingRetainsBaselineMappingCompatibility() throws {
        XCTAssertEqual(try JSONDecoder().decode(FormatID.self, from: Data("\"yaml\"".utf8)), .yaml)
        XCTAssertEqual(String(data: try JSONEncoder().encode(FormatID.yaml), encoding: .utf8), "\"yaml\"")
    }

    func testRequestedLegacyAndStructuredExtensionsRouteToTheirSharedInspectors() throws {
        let routes: [(String, FormatID, SourceLanguage?)] = [
            ("ada-example.ada", .init(rawValue: "ada"), .ada),
            ("actionscript-example.as", .init(rawValue: "actionscript"), .actionscript),
            ("autolit-example.au3", .text, nil), ("autolit-compiled.a3x", .text, nil),
            ("atl-template.atl", .text, nil),
            ("assembly-example.asm", .init(rawValue: "assembly"), .assembly),
            ("assembly-legacy.s79", .init(rawValue: "assembly"), .assembly),
            ("gawk-script.awk", .init(rawValue: "awk"), .awk),
            ("applescript-example.applescript", .init(rawValue: "applescript"), .appleScript), ("applescript-legacy.ascr", .text, nil),
            ("applescript-compiled.scpt", .text, nil), ("command-example.command", .shell, .shell),
            ("component.jsx", .jsx, .jsx), ("component.astro", .jsx, .jsx),
            ("upx-script.psjs", .javascript, .javascript), ("adobe-sequence.sequ", .xml, nil),
            ("flex-example.mxml", .xml, nil), ("localization.loctable", .plist, nil),
            ("workflow.wflow", .plist, nil), ("azkaban-flow.flow", .yaml, nil)
        ]

        for (fileName, expectedID, expectedLanguage) in routes {
            let fixture = try (try? fixtureURL("Showcase/legacy-formats/\(fileName)"))
                ?? fixtureURL("Cases/legacy-formats/\(fileName)")
            let bytes = try Data(contentsOf: fixture)
            let result = PreviewInspectionResult.prepare(
                bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil
            )

            XCTAssertEqual(FormatCatalog.match(fileName: fileName)?.id, expectedID, fileName)
            XCTAssertEqual(result.formatDefinition?.id, expectedID, fileName)
            XCTAssertEqual(result.originalBytes, bytes, fileName)
            XCTAssertFalse(result.analysis.isBinary, fileName)
            if let expectedLanguage {
                XCTAssertEqual(result.sourceDocument?.language, expectedLanguage, fileName)
                XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, fileName)
            } else {
                XCTAssertNil(result.sourceDocument, fileName)
                XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self), fileName)
            }
        }

        XCTAssertNotNil(try PreviewInspectionResult.read(at: fixtureURL("Cases/legacy-formats/adobe-sequence.sequ")).xmlInspection)
        XCTAssertNotNil(try PreviewInspectionResult.read(at: fixtureURL("Cases/legacy-formats/flex-example.mxml")).xmlInspection)
        XCTAssertNotNil(try PreviewInspectionResult.read(at: fixtureURL("Cases/legacy-formats/localization.loctable")).plistInspection)
        XCTAssertNotNil(try PreviewInspectionResult.read(at: fixtureURL("Cases/legacy-formats/workflow.wflow")).plistInspection)
        XCTAssertNotNil(try PreviewInspectionResult.read(at: fixtureURL("Cases/legacy-formats/azkaban-flow.flow")).yamlInspection)
    }

    func testRequestedFormatsPreserveMalformedAndTruncatedSource() throws {
        let sourceCases: [(String, SourceLanguage)] = [
            ("sample.ada", .ada), ("sample.as", .actionscript), ("sample.asm", .assembly),
            ("sample.s79", .assembly), ("sample.awk", .awk), ("sample.jsx", .jsx),
            ("sample.astro", .jsx), ("sample.psjs", .javascript), ("sample.command", .shell)
        ]
        for (fileName, language) in sourceCases {
            let bytes = Data("function unfinished( { let message = \"unterminated\n".utf8)
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertEqual(result.sourceDocument?.language, language, fileName)
            XCTAssertEqual(result.sourceDocument?.source, String(decoding: bytes, as: UTF8.self), fileName)
            XCTAssertEqual(result.originalBytes, bytes, fileName)

            let truncated = Data(bytes.prefix(max(1, bytes.count / 2)))
            let clipped = PreviewInspectionResult.prepare(bytes: truncated, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertEqual(clipped.sourceDocument?.source, String(decoding: truncated, as: UTF8.self), fileName)
            XCTAssertTrue(clipped.sourceDocument?.truncated == true, fileName)
        }

        for (fileName, malformed) in [
            ("sample.sequ", "<sequence><frame></sequence>"),
            ("sample.mxml", "<mx:Application><mx:Label></mx:Application>"),
            ("sample.loctable", "<?xml version=\"1.0\"?><plist><dict>"),
            ("sample.wflow", "<?xml version=\"1.0\"?><plist><dict>"),
            ("sample.flow", "tasks: [unterminated\n")
        ] {
            let bytes = Data(malformed.utf8)
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertEqual(result.originalBytes, bytes, fileName)
            XCTAssertFalse(result.analysis.text.isEmpty, fileName)
            if fileName.hasSuffix(".flow") { XCTAssertNotNil(result.yamlInspection, fileName) }
            else if fileName.hasSuffix(".loctable") || fileName.hasSuffix(".wflow") { XCTAssertNotNil(result.plistInspection, fileName) }
            else { XCTAssertNotNil(result.xmlInspection, fileName) }
        }

        for fileName in ["sample.au3", "sample.atl", "sample.ascr"] {
            let bytes = Data("on run; keep this text inert: \"unfinished\n".utf8)
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertNil(result.sourceDocument, fileName)
            XCTAssertEqual(result.analysis.text, String(decoding: bytes, as: UTF8.self), fileName)
            XCTAssertEqual(result.originalBytes, bytes, fileName)
        }

        let appleScript = "on run; keep this text inert: \"unfinished\n"
        let appleBytes = Data(appleScript.utf8)
        let appleResult = PreviewInspectionResult.prepare(bytes: appleBytes, fileSize: appleBytes.count,
            fileName: "sample.applescript", systemUTI: nil)
        XCTAssertEqual(appleResult.sourceDocument?.source, appleScript)
        XCTAssertEqual(appleResult.originalBytes, appleBytes)
    }

    func testCompiledScriptExtensionsRemainBinaryAndAreNeverInterpreted() {
        for fileName in ["sample.scpt", "sample.a3x"] {
            let bytes = Data([0x00, 0x53, 0x43, 0x52, 0x49, 0x50, 0x54, 0xFF])
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: fileName, systemUTI: nil)
            XCTAssertTrue(result.analysis.isBinary, fileName)
            XCTAssertNil(result.sourceDocument, fileName)
            XCTAssertNil(result.formatDefinition, fileName)
            XCTAssertEqual(result.originalBytes, bytes, fileName)
        }
    }
}
