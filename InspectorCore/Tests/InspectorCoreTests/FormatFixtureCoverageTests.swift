import Foundation
import CryptoKit
import XCTest
@testable import InspectorCore

/// Every supported format has a shipped valid showcase (checked by `FormatCatalogTests`) and at least one
/// defective case here, so a newly supported format cannot land without a malformed-input test.
final class FormatFixtureCoverageTests: XCTestCase {
    // MARK: Defective fixtures

    private static let defectiveFixtures: [String: String] = [
        // Semantic inspectors
        "json": "Cases/json/invalid/malformed.json",
        "jsonl": "Cases/jsonl/invalid/malformed.jsonl",
        "yaml": "Cases/yaml/invalid/malformed.yaml",
        "xml": "Cases/xml/invalid/malformed.xml",
        "kml": "Cases/geospatial/invalid/malformed.kml",
        "gpx": "Cases/geospatial/invalid/malformed.gpx",
        "geojson": "Cases/geospatial/invalid/malformed.geojson",
        "xcworkspace": "Cases/catalog/invalid/contents.xcworkspacedata",
        "info-plist": "Cases/catalog/invalid/Info.plist",
        "entitlements": "Cases/catalog/invalid/malformed.entitlements",
        "dotenv": "Cases/config/dotenv/invalid/missing-key.env",
        "reference-fstab-config-file": "Cases/config/fstab/invalid/fstab",
        "editorconfig": "Cases/config/editorconfig/invalid/.editorconfig",
        "gitignore": "Cases/config/ignore/invalid/.gitignore",
        "dockerignore": "Cases/config/ignore/invalid/.dockerignore",
        "npmrc": "Cases/config/npmrc/invalid/.npmrc",
        "gitattributes": "Cases/config/gitattributes/invalid/.gitattributes",
        "gitmodules": "Cases/config/gitmodules/invalid/.gitmodules",
        "systemd-unit": "Cases/config/systemd/invalid/broken.service",
        "go-module": "Cases/config/go/invalid/go.mod",
        "ssh-public-key": "Cases/security/invalid/malformed.pub",
        "mobileconfig": "Cases/xml/malformed.mobileconfig",
        "plist": "Cases/plist/invalid/malformed.plist",
        "pbxproj": "Cases/catalog/invalid/project.pbxproj",
        "strings": "Cases/requested-formats/invalid/localizable.strings",
        "stringsdict": "Cases/requested-formats/invalid/localizable.stringsdict",
        "xcstrings": "Cases/catalog/invalid/Localizable.xcstrings",
        "xcscheme": "Cases/requested-formats/invalid/sample.xcscheme",
        "csr": "Cases/security/invalid/malformed.csr",
        "pkcs7": "Cases/security/invalid/malformed.p7b",
        "pkcs12": "Cases/security/invalid/truncated.p12",
        "csv": "Cases/fileformats/csv/unterminated-quote.csv",
        "tsv": "Cases/fileformats/tsv/unterminated-quote.tsv",
        "diff": "Cases/fileformats/diff/bad-hunk-header.diff",
        "zip": "Cases/fileformats/zip/truncated.zip",
        "pem-certificate": "Cases/security/invalid/corrupted.pem",
        "der-certificate": "Cases/security/invalid/truncated.der",
        "mobileprovision": "Cases/security/invalid/malformed.mobileprovision",
        "jwk": "Cases/security/invalid/malformed.jwk",
        "jwks": "Cases/security/invalid/malformed.jwks",
        "jwt": "Cases/security/invalid/malformed.jwt",
        "cyclonedx-sbom": "Cases/security/invalid/malformed.cdx.json",
        "spdx-sbom": "Cases/security/invalid/malformed.spdx.json",
        "spdx-tag-value": "Cases/sbom/invalid/spdx-malformed-record.spdx",
        "spdx-yaml": "Cases/sbom/invalid/malformed.spdx.yaml",
        "privacy-manifest": "Cases/apple/invalid/wrong-shape.xcprivacy",
        "xcode-test-plan": "Cases/apple/invalid/wrong-root.xctestplan",
        "code-resources": "Cases/apple/invalid/CodeResources",
        "sqlite": "Cases/sqlite/invalid/truncated.sqlite",
        "tar-archive": "Cases/tar/invalid/bad-checksum.tar",
        "cyclonedx-sbom-protobuf": "Cases/sbom/invalid/malformed.cdx.pb",
        "pem-public-key": "Cases/security/invalid/malformed-public-key.pub",
        "xslt": "Cases/catalog/invalid/malformed.xslt",
        "xsd": "Cases/catalog/invalid/malformed.xsd",
        "xib": "Cases/catalog/invalid/malformed.xib",
        "storyboard": "Cases/catalog/invalid/malformed.storyboard",
        "mdx": "Cases/markdown-family/invalid/malformed.mdx",
        "apib": "Cases/markdown-family/invalid/malformed.apib",
        "mdc": "Cases/markdown-family/invalid/malformed.mdc",
        "quarto": "Cases/markdown-family/invalid/malformed.qmd",
        "rst": "Cases/source/invalid/unclosed-literal.rst",
        "windows-registry": "Cases/config/registry/invalid/malformed.reg",
        "cyclonedx-sbom-xml": "Cases/sbom/invalid/cyclonedx-external-entity.cdx.xml",
        "markdown": "Cases/fileformats/md/malformed.md",
        "rmarkdown": "Cases/fileformats/rmd/malformed.rmd",
        "log": "Cases/log/invalid/malformed.log",
        // Plain text
        "text": "Cases/fileformats/txt/invalid-utf8.txt",
        "xquery": "Cases/fileformats/xquery/unclosed-flwor.xquery",
        "haml": "Cases/fileformats/haml/unclosed-attribute.haml",
        "dtd": "Cases/fileformats/dtd/unclosed-declaration.dtd",
        "jsp": "Cases/idl-jupyter/jsp/malformed.jsp",
        "gcc-linker": "Cases/fileformats/ld/unclosed-section.ld",
        "conf": "Cases/fileformats/conf/unclosed-block.conf",
        "mermaid": "Cases/mermaid/invalid.mermaid",
        "make": "Cases/fileformats/mk/malformed.mk",
        "kermeta": "Cases/fileformats/kmt/malformed.kmt",
        "lilypond": "Cases/fileformats/ly/malformed.ly",
        "logos": "Cases/fileformats/xm/malformed.xm",
        "mf": "Cases/fileformats/mf/malformed.mf",
        "nix": "Cases/fileformats/nix/malformed.nix",
        "nim": "Cases/fileformats/nim/malformed.nim",
        "openscad": "Cases/fileformats/openscad/malformed.scad",
        "webassembly-text": "Cases/fileformats/wat/malformed.wat",
        "cue": "Cases/fileformats/cue/malformed.cue",
        "kdl": "Cases/fileformats/kdl/malformed.kdl",
        "latex": "Cases/fileformats/latex/malformed.tex",
        "jenkinsfile": "Cases/fileformats/jenkinsfile/Jenkinsfile",
        "meson": "Cases/fileformats/meson/meson.build",
        "plsql": "Cases/fileformats/plsql/malformed.pkb",
        "visual-basic": "Cases/fileformats/vb/malformed.vb",
        "vala": "Cases/fileformats/vala/malformed.vala",
        "vimscript": "Cases/fileformats/vim/malformed.vim",
        "email": "Cases/mail/invalid/malformed.eml",
        "icalendar": "Cases/calendar/invalid/malformed.ics",
        "vcard": "Cases/contacts/invalid/malformed.vcf",
        "tsql": "Cases/fileformats/tsql/malformed.tsql",
        // Source
        "reference-bison": "Cases/source/invalid/malformed-bison.y",
        "graphviz": "Cases/source/invalid/malformed-graphviz.dot",
        "ada": "Cases/source/invalid/unterminated-string.ada",
        "actionscript": "Cases/source/invalid/unclosed-block.as",
        "awk": "Cases/source/invalid/unterminated-regex.awk",
        "swift": "Cases/source/invalid/unterminated-string.swift",
        "d": "Cases/source/invalid/unclosed-block.d",
        "java": "Cases/source/invalid/unclosed-comment.java",
        "c": "Cases/source/invalid/unclosed-comment.c",
        "cpp": "Cases/fileformats/cpp/malformed.cpp",
        "python": "Cases/source/invalid/bad-indentation.py",
        "pyrex": "Cases/fileformats/pyrex/malformed.pyx",
        "javascript": "Cases/source/invalid/unterminated-template.js",
        "typescript": "Cases/source/invalid/missing-brace.ts",
        "tsx": "Cases/fileformats/tsx/malformed.tsx",
        "jsx": "Cases/source/invalid/unclosed-element.jsx",
        "csharp": "Cases/source/invalid/unterminated-verbatim.cs",
        "groovy": "Cases/source/invalid/unclosed-gstring.groovy",
        "gradle": "Cases/source/invalid/unclosed-closure.gradle",
        "ruby": "Cases/source/invalid/unterminated-heredoc.rb",
        "podspec": "Cases/source/invalid/unterminated-string.podspec",
        "php": "Cases/source/invalid/unterminated-string.php",
        "go": "Cases/source/invalid/unterminated-raw-string.go",
        "rust": "Cases/source/invalid/unterminated-raw-string.rs",
        "zig": "Cases/requested-formats/invalid/broken.zig",
        "kotlin": "Cases/fileformats/kt/malformed.kt",
        "lua": "Cases/fileformats/lua/malformed.lua",
        "shell": "Cases/fileformats/ksh/malformed.ksh",
        "fish": "Cases/source/invalid/unclosed-block.fish",
        "csh": "Cases/source/invalid/unclosed-block.csh",
        "powershell": "Cases/fileformats/ps1/malformed.ps1",
        "batch": "Cases/source/invalid/unclosed-parenthesis.bat",
        "haskell": "Cases/source/invalid/unclosed-comment.hs",
        "clojure": "Cases/source/invalid/unbalanced.clj",
        "lisp": "Cases/fileformats/lisp/malformed.lisp",
        "elixir": "Cases/source/invalid/unterminated-sigil.ex",
        "erlang": "Cases/source/invalid/missing-terminator.erl",
        "fsharp": "Cases/source/invalid/unclosed-comment.fs",
        "fortran": "Cases/source/invalid/unterminated-string.f90",
        "assembly": "Cases/source/invalid/invalid-operand.asm",
        "html": "Cases/source/invalid/unclosed-tags.html",
        "css": "Cases/source/invalid/unclosed-rule.css",
        "scss": "Cases/fileformats/scss/malformed.scss",
        "less": "Cases/fileformats/less/malformed.less",
        "vue": "Cases/fileformats/vue/malformed.vue",
        "svelte": "Cases/fileformats/svelte/malformed.svelte",
        "dockerfile": "Cases/source/invalid/unclosed-continuation.dockerfile",
        "cmake": "Cases/source/invalid/unclosed-call.cmake",
        "terraform": "Cases/fileformats/tf/malformed.tf",
        "toml": "Cases/source/invalid/unterminated-string.toml",
        "ini": "Cases/source/invalid/unclosed-section.ini",
        "properties": "Cases/source/invalid/dangling-continuation.properties",
        "xcconfig": "Cases/source/invalid/unterminated-string.xcconfig",
        "sql": "Cases/source/invalid/unterminated-string.sql",
        "bibtex": "Cases/source/invalid/unbalanced-entry.bib",
        "asciidoc": "Cases/fileformats/adoc/malformed.adoc",
        "miniscript": "Cases/fileformats/ms/malformed.ms",
        "dylan": "Cases/source/invalid/unclosed-block.dylan",
        "eiffel": "Cases/source/invalid/unterminated-string.e",
        "gdscript": "Cases/source/invalid/bad-indentation.gd",
        "gleam": "Cases/source/invalid/unterminated-string.gleam",
        "coffeescript": "Cases/source/invalid/unterminated-block-string.coffee",
        "coldfusion": "Cases/source/invalid/unclosed-tag.cfm",
        "crystal": "Cases/source/invalid/unclosed-block.cr",
        "cson": "Cases/source/invalid/unbalanced.cson",
        "objective-c": "Cases/fileformats/objective-c/malformed.m",
        "perl": "Cases/fileformats/perl/malformed.pl",
        "r": "Cases/fileformats/r/malformed.R",
        "scala": "Cases/fileformats/scala/malformed.scala",
        "julia": "Cases/fileformats/julia/malformed.jl",
        "matlab": "Cases/source/matlab/malformed.m",
        "ocaml": "Cases/source/ocaml/malformed.ml",
        "tcl-tk": "Cases/source/tcl/malformed.tcl",
        "auto-hot-key": "Cases/fileformats/ahk/malformed.ahk",
        "inno-setup": "Cases/fileformats/inno/malformed.iss",
        "nsis": "Cases/fileformats/nsis/malformed.nsi",
        "rego": "Cases/fileformats/rego/malformed.rego",
        "ldif": "Cases/fileformats/ldif/malformed.ldif",
        "turtle": "Cases/fileformats/turtle/malformed.ttl",
        "reference-yang": "Cases/source/invalid/malformed.yang",
        "textbundle": "Cases/fileformats/textbundle/malformed.textbundle",
        "applescript": "Cases/source/applescript/malformed.applescript",
        "nginx": "Cases/source/nginx/malformed.conf",
        "apache": "Cases/source/apache/malformed.conf",
        "pascal": "Cases/fileformats/pascal/malformed.pas",
        "verilog": "Cases/fileformats/verilog/malformed.vh",
        "vhdl": "Cases/fileformats/vhdl/malformed.vhd",
        "cobol": "Cases/fileformats/cobol/malformed.cob",
        "device-tree-source": "Cases/fileformats/device-tree/malformed.dts",
        "gettext": "Cases/fileformats/gettext/malformed.po",
        "erb": "Cases/fileformats/erb/malformed.erb",
        "qml": "Cases/fileformats/qml/malformed.qml",
        "solidity": "Cases/fileformats/solidity/malformed.sol",
        "org": "Cases/fileformats/org/malformed.org",
        "asp": "Cases/fileformats/asp/malformed.asp",
        "aspx": "Cases/fileformats/aspx/malformed.aspx",
        "jinja": "Cases/fileformats/jinja/malformed.jinja",
        "reference-elm": "Cases/source/invalid/malformed.elm",
        "twig": "Cases/fileformats/twig/malformed.twig"
    ]

    /// Kinds whose inspector parses structure and must say so when the structure is broken.
    private static let diagnosingKinds: Set<FormatDefinition.InspectionKind> = [.json, .jsonl, .yaml, .xml, .plist]
    /// Kinds whose inspector failure falls back to the raw view, without a structured listing but with a warning.
    private static let rawFallbackKinds: Set<FormatDefinition.InspectionKind> = [.zip, .certificate]

    // MARK: Tests

    func testGraphvizLexicalRuns() throws {
        let lexer = InternalSyntaxHighlighter()
        func runs(_ source: String) throws -> [HighlightRun] { try lexer.highlight(source, language: .graphviz).runs }
        func range(_ token: String, in source: String) -> NSRange {
            let value = (source as NSString).range(of: token)
            XCTAssertNotEqual(value.location, NSNotFound, token)
            return value
        }

        let words = "StRiCt GRAPH digraph subgraph node edge -> -- { } [ ] = : ; , + graph2 _node édigraph edge😀"
        let wordRuns = try runs(words)
        for token in ["StRiCt", "GRAPH", "digraph", "subgraph", "node", "edge", "->", "--", "{", "}", "[", "]", "=", ":", ";", ",", "+"] {
            XCTAssertTrue(wordRuns.contains(.init(range: range(token, in: words), kind: .keyword)), token)
        }
        for token in ["graph2", "_node", "édigraph", "edge😀"] {
            XCTAssertFalse(wordRuns.contains { NSIntersectionRange($0.range, range(token, in: words)).length > 0 }, token)
        }
        let unicode = "😀;digraph -> node"
        XCTAssertTrue(try runs(unicode).contains(.init(range: range("digraph", in: unicode), kind: .keyword)))
        XCTAssertEqual(range("digraph", in: unicode).location, 3)

        let numbers = "a-1 1-2 1..2 1foo-3 1e+ 1e-3node 1e-3 1E+3 --"
        let numberRuns = try runs(numbers)
        XCTAssertEqual(numberRuns.filter { $0.kind == .number }.map { (numbers as NSString).substring(with: $0.range) },
                       ["-1", "1", "-2", "1.", ".2", "-3"])
        XCTAssertTrue(numberRuns.contains(.init(range: range("+", in: numbers), kind: .keyword)))
        for token in ["1e-3node", "1e-3", "1E+3"] {
            XCTAssertFalse(numberRuns.contains { NSIntersectionRange($0.range, range(token, in: numbers)).length > 0 }, token)
        }
        XCTAssertEqual(numberRuns.filter { (numbers as NSString).substring(with: $0.range) == "--" }.count, 1)
        XCTAssertTrue(try runs("1e").isEmpty)
        XCTAssertTrue(try runs("1fooE").isEmpty)

        for newline in ["\n", "\r", "\r\n"] {
            let source = "/* x\(newline)*/ # node\(newline)  # edge\(newline)mid # graph\"unterminated\(newline)digraph"
            let actual = try runs(source)
            let ns = source as NSString
            XCTAssertTrue(actual.contains(.init(range: ns.range(of: "/* x\(newline)*/"), kind: .comment)), newline.debugDescription)
            XCTAssertFalse(actual.contains(.init(range: ns.range(of: "# node"), kind: .directive)), newline.debugDescription)
            XCTAssertTrue(actual.contains(.init(range: ns.range(of: "# edge"), kind: .directive)), newline.debugDescription)
            XCTAssertFalse(actual.contains { ns.substring(with: $0.range) == "# graph" }, newline.debugDescription)
            XCTAssertTrue(actual.contains(.init(range: ns.range(of: "digraph", options: [], range: NSRange(location: ns.length - 7, length: 7)), kind: .keyword)))
            let quote = ns.range(of: "\"unterminated")
            XCTAssertTrue(actual.contains(.init(range: quote, kind: .string)), newline.debugDescription)
        }
        let continued = "\"one\\\nnode\"\r\"two\\\r\nedge\"\n\"three\\\rgraph\nnode"
        let continuedRuns = try runs(continued)
        let continuedNS = continued as NSString
        for token in ["\"one\\\nnode\"", "\"two\\\r\nedge\""] {
            XCTAssertTrue(continuedRuns.contains(.init(range: continuedNS.range(of: token), kind: .string)), token.debugDescription)
        }
        XCTAssertFalse(continuedRuns.contains { continuedNS.substring(with: $0.range) == "\"three\\\rgraph" })
        XCTAssertTrue(continuedRuns.contains(.init(range: continuedNS.range(of: "node", options: [], range: NSRange(location: continuedNS.length - 4, length: 4)), kind: .keyword)))

        let labels = [
            "<!-- graph -> \"image.png\" --> graph",
            "<<B>digraph -> <IMG SRC='x'> <!-- node -> --> edge</B>> graph",
            "<<B TITLE=\"digraph -> <I>node</I>\">edge</B>> graph",
            "<<B TITLE='digraph -> <I>node</I>'>edge</B>> graph",
            "<<B TITLE= <!-- fake -> \"image.png\" --> \"node -> <I>edge</I>\">tail</B>> graph"
        ]
        for source in labels {
            let actual = try runs(source)
            let visible = (source as NSString).range(of: "graph", options: [], range: NSRange(location: source.utf16.count - 5, length: 5))
            XCTAssertEqual(actual, [.init(range: visible, kind: .keyword)], source)
        }
        for source in ["<!-- fake -> node", "<<B><!-- fake -> node -->", "<<B TITLE=\"unterminated -> node", "<<B TITLE='unterminated -> node"] {
            XCTAssertTrue(try runs(source).isEmpty, source)
        }
        let resumed = "<<B>opaque</B>> node"
        XCTAssertEqual(try runs(resumed), [.init(range: range("node", in: resumed), kind: .keyword)])
    }

    func testEverySupportedFormatHasADefectiveFixture() throws {
        let supported = Set(FormatCatalog.supported.map(\.id.rawValue))
        XCTAssertEqual(Set(Self.defectiveFixtures.keys).subtracting(supported), [], "defective fixture for an unsupported format")
        XCTAssertEqual(supported.subtracting(Self.defectiveFixtures.keys), [], "supported format without a defective fixture")
        for (id, path) in Self.defectiveFixtures {
            XCTAssertNotEqual(FormatCatalog.definition(for: FormatID(rawValue: id))?.showcaseFixture, path, id)
            _ = try fixtureURL(path)
        }
    }

    func testDefectiveFixturesKeepTheirFormatAndRawBytes() throws {
        for (id, path) in Self.defectiveFixtures.sorted(by: { $0.key < $1.key }) {
            let format = try XCTUnwrap(FormatCatalog.definition(for: FormatID(rawValue: id)), id)
            if format.id == .textbundle {
                XCTAssertThrowsError(try TextBundleInspector.readMarkdown(at: fixtureURL(path), maximumBytes: 1_048_576))
                continue
            }
            let bytes = try Data(contentsOf: fixtureURL(path))
            let result = PreviewInspectionResult.prepare(
                bytes: bytes, fileSize: bytes.count, fileName: URL(fileURLWithPath: path).lastPathComponent, systemUTI: nil
            )
            XCTAssertEqual(result.formatDefinition?.id, format.id, path)
            XCTAssertEqual(result.originalBytes, bytes, "raw preservation for \(path)")

            if Self.diagnosingKinds.contains(format.inspectionKind) {
                let warns = result.statusSummary.items.contains { $0.kind == .warning }
                XCTAssertTrue(warns || !result.inspectionDiagnostics.isEmpty, "no diagnostic for \(path)")
            } else if Self.rawFallbackKinds.contains(format.inspectionKind) {
                XCTAssertNil(result.additionalInspection, "a damaged container must not publish partial facts: \(path)")
                XCTAssertTrue(result.statusSummary.items.contains { $0.kind == .warning }, "silent fallback for \(path)")
            } else if [.sqlite, .tarArchive, .cyclonedxSBOMProtobuf, .pkcs7, .pkcs12].contains(format.id) {
                XCTAssertNil(result.additionalInspection?.securityInspection?.content,
                             "damaged binary input must not publish partial facts: \(path)")
                XCTAssertTrue(result.statusSummary.items.contains { $0.kind == .warning }, "silent fallback for \(path)")
            } else if let language = format.sourceLanguage {
                let document = try XCTUnwrap(result.sourceDocument, path)
                XCTAssertEqual(document.language, language, path)
                XCTAssertEqual(document.source, result.analysis.text, "source must stay verbatim: \(path)")
            } else {
                XCTAssertFalse(result.analysis.isBinary, path)
                XCTAssertFalse(result.analysis.text.isEmpty, path)
            }
        }
    }

    /// Fixtures read like the file's own content (`Fixtures/README.md`), so they never narrate that they are
    /// test input or describe how Glimt treats them.
    func testFixturesDoNotDescribeThemselves() throws {
        let selfDescriptions = [
            "this fixture", "glimt fixture", "glimt-fixture", "syntax fixture", "source fixture", "malformed fixture",
            "showcase", "glimt never", "glimt only", "glimt does not", "glimt displays", "glimt inspects",
            "never executed", "never executes", "never evaluated", "remain inert", "remains inert", "stays inert",
            "source preview", "for inspection only",
        ]
        let root = try fixtureURL("README.md").deletingLastPathComponent()
        for area in ["Showcase", "Cases"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: root.appendingPathComponent(area), includingPropertiesForKeys: [.isRegularFileKey]
            ))
            for case let url as URL in enumerator where url.lastPathComponent != "README.md" {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let lowered = text.lowercased()
                for phrase in selfDescriptions where lowered.contains(phrase) {
                    XCTFail("\(area)/\(url.lastPathComponent) describes itself: \(phrase)")
                }
            }
        }
    }

    func testPKCS7MalformedFixtureBreaksSignerInfosAndPublishesNoFacts() throws {
        let bytes = try Data(contentsOf: fixtureURL("Cases/security/invalid/malformed.p7b"))
        XCTAssertEqual(Array(bytes.suffix(2)), [0x30, 0x00])
        let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "malformed.p7b", systemUTI: nil)
        XCTAssertEqual(result.formatDefinition?.id, .pkcs7)
        XCTAssertNil(result.additionalInspection?.securityInspection?.content)
        XCTAssertEqual(result.inspectionDiagnostics.first?.code, .parseError)
        XCTAssertEqual(result.originalBytes, bytes)
    }

    func testPKCS12TruncatedFixturePublishesNoFacts() throws {
        let complete = try Data(contentsOf: fixtureURL("Cases/security/certificate-only.p12"))
        let defective = try Data(contentsOf: fixtureURL("Cases/security/invalid/truncated.p12"))
        XCTAssertEqual(complete.count, 1_115)
        XCTAssertEqual(SHA256.hash(data: complete).map { String(format: "%02x", $0) }.joined(),
                       "097bea6a17ae6095ae5bef0bd9c1b44d5a2003320f765536cf95b26ab0c2cd81")
        XCTAssertEqual(defective.count, 1_114)
        XCTAssertEqual(SHA256.hash(data: defective).map { String(format: "%02x", $0) }.joined(),
                       "427e2b814b8d5b8068534c62030a846b13d829ee5d5de61da9f0c31044c14492")
        let result = PreviewInspectionResult.prepare(bytes: defective, fileSize: defective.count,
            fileName: "truncated.p12", systemUTI: nil)
        XCTAssertEqual(result.formatDefinition?.id, .pkcs12)
        XCTAssertNil(result.additionalInspection?.securityInspection?.content)
        XCTAssertEqual(result.inspectionDiagnostics.first?.code, .parseError)
        XCTAssertEqual(result.originalBytes, defective)

        let declaredTruncated = try SecurityFormatInspector.inspect(data: defective, fileSize: complete.count,
                                                                     formatID: .pkcs12)
        XCTAssertNil(declaredTruncated.content)
        XCTAssertEqual(declaredTruncated.diagnostics.first?.code, .truncated)
    }

    func testYANGRoutingAndLexicalRuns() throws {
        XCTAssertEqual(SourceLanguage(rawValue: "yang")?.displayName, "YANG")

        let source = "module glimt {\n  yang-version 1.1;\n  description \"😀 //\";\n}"
        let bytes = Data(source.utf8)
        let suffix = PreviewInspectionResult.prepare(
            bytes: bytes, fileSize: bytes.count, fileName: "sample.YaNg", systemUTI: "public.plain-text"
        )
        XCTAssertEqual(suffix.formatDefinition?.id.rawValue, "reference-yang")
        XCTAssertEqual(suffix.sourceDocument?.language.rawValue, "yang")
        XCTAssertEqual(suffix.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".yang")

        let uti = PreviewInspectionResult.prepare(
            bytes: bytes, fileSize: bytes.count, fileName: "sample", systemUTI: "com.glimt.yang-source"
        )
        XCTAssertEqual(uti.formatDefinition?.id.rawValue, "reference-yang")
        XCTAssertEqual(uti.sourceDocument?.language.rawValue, "yang")
        XCTAssertEqual(uti.resolution.evidence.first { $0.signalKind == .systemUTI }?.value, "com.glimt.yang-source")

        let yin = PreviewInspectionResult.prepare(
            bytes: bytes, fileSize: bytes.count, fileName: "sample.yin", systemUTI: "com.glimt.yang-source"
        )
        XCTAssertEqual(yin.formatDefinition?.id.rawValue, "reference-yang")
        XCTAssertEqual(yin.resolution.evidence.first { $0.signalKind == .systemUTI }?.value, "com.glimt.yang-source")
        let swift = PreviewInspectionResult.prepare(
            bytes: Data("import Foundation\n".utf8), fileSize: 18, fileName: "sample.swift", systemUTI: "com.glimt.yang-source"
        )
        XCTAssertEqual(swift.formatDefinition?.id, .swift)
        XCTAssertEqual(swift.sourceDocument?.language, .swift, "the .swift suffix retains precedence over the YANG UTI")

        for name in ["sample.yin", "sample.yang.txt", "sample"] {
            let genericText = PreviewInspectionResult.prepare(
                bytes: bytes, fileSize: bytes.count, fileName: name, systemUTI: "public.plain-text"
            )
            XCTAssertNotEqual(genericText.formatDefinition?.id.rawValue, "reference-yang", name)
        }

        let binary = PreviewInspectionResult.prepare(
            bytes: Data([0, 255, 0, 255]), fileSize: 4, fileName: "sample.yang", systemUTI: "public.plain-text"
        )
        XCTAssertEqual(binary.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".yang")
        XCTAssertTrue(binary.analysis.isBinary)
        XCTAssertNil(binary.sourceDocument)

        let language = try XCTUnwrap(SourceLanguage(rawValue: "yang"))
        let highlighted = try InternalSyntaxHighlighter().highlight(source, language: language)
        XCTAssertTrue(highlighted.runs.contains(.init(range: NSRange(location: 37, length: 11), kind: .keyword)))
        XCTAssertTrue(highlighted.runs.contains(.init(range: NSRange(location: 49, length: 7), kind: .string)))
        XCTAssertFalse(highlighted.runs.contains { $0.kind == .comment })
        let isolated = try InternalSyntaxHighlighter().highlight("description \"😀 //\"", language: language)
        XCTAssertTrue(isolated.runs.contains(.init(range: NSRange(location: 0, length: 11), kind: .keyword)))
        XCTAssertTrue(isolated.runs.contains(.init(range: NSRange(location: 12, length: 7), kind: .string)))
        XCTAssertFalse(isolated.runs.contains { $0.kind == .comment })

        let keywords = "module submodule yang-version namespace prefix import include belongs-to organization contact description reference revision revision-date typedef grouping uses container list leaf leaf-list key type enumeration enum identity base feature if-feature augment deviation rpc input output notification config mandatory default status units range length pattern must when"
            .split(separator: " ").map(String.init)
        let keywordInput = keywords.joined(separator: " ")
        let keywordRuns = try InternalSyntaxHighlighter().highlight(keywordInput, language: language).runs
        var keywordOffset = 0
        for word in keywords {
            XCTAssertTrue(keywordRuns.contains(.init(range: NSRange(location: keywordOffset, length: word.utf16.count), kind: .keyword)), word)
            keywordOffset += word.utf16.count + 1
        }

        let identifiers = "leaf leaf-name leaf.name ext:leaf leafish Leaf Module module MODULE"
        let identifierRuns = try InternalSyntaxHighlighter().highlight(identifiers, language: language).runs
        XCTAssertEqual(identifierRuns, [
            .init(range: NSRange(location: 0, length: 4), kind: .keyword),
            .init(range: NSRange(location: 54, length: 6), kind: .keyword)
        ])

        let numericInput = "1.1 -1 +1 2018-02-20 0xFF 1_000 2e3"
        let numericRuns = try InternalSyntaxHighlighter().highlight(numericInput, language: language).runs
        XCTAssertEqual(numericRuns.map(\.kind), Array(repeating: .number, count: 9))
        XCTAssertEqual(numericRuns.map { (numericInput as NSString).substring(with: $0.range) },
                       ["1.1", "1", "1", "2018", "02", "20", "0xFF", "1_000", "2e3"])

        let singleQuoted = "'a\\' leaf"
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(singleQuoted, language: language).runs, [
            .init(range: NSRange(location: 0, length: 4), kind: .string),
            .init(range: NSRange(location: 5, length: 4), kind: .keyword)
        ])
        let escapedDouble = "\"a\\\" //\""
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(escapedDouble, language: language).runs, [
            .init(range: NSRange(location: 0, length: escapedDouble.utf16.count), kind: .string)
        ])
        let adjacent = "\"a\"+\"b\""
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(adjacent, language: language).runs, [
            .init(range: NSRange(location: 0, length: 3), kind: .string),
            .init(range: NSRange(location: 4, length: 3), kind: .string)
        ])
        let mixedNewlines = "'a\r\nb' \"c\rd\""
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(mixedNewlines, language: language).runs, [
            .init(range: NSRange(location: 0, length: 6), kind: .string),
            .init(range: NSRange(location: 7, length: 5), kind: .string)
        ])
    }

    func testElmRoutingAndRetainedBytes() throws {
        XCTAssertEqual(FormatCatalog.definition(for: FormatID(rawValue: "reference-elm"))?.status, .supported)
        let showcase = try fixtureURL("Showcase/source/glimt.elm")
        let bytes = try Data(contentsOf: showcase)

        let suffix = PreviewInspectionResult.prepare(
            bytes: bytes, fileSize: bytes.count, fileName: "sample.ELM", systemUTI: "public.plain-text"
        )
        XCTAssertEqual(suffix.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertEqual(suffix.sourceDocument?.language, .elm)
        XCTAssertEqual(suffix.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".elm")
        XCTAssertEqual(suffix.originalBytes, bytes)

        for name in ["sample", "sample.unknown"] {
            let uti = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count, fileName: name,
                                                      systemUTI: "com.glimt.elm-source")
            XCTAssertEqual(uti.formatDefinition?.id.rawValue, "reference-elm", name)
            XCTAssertEqual(uti.sourceDocument?.language, .elm, name)
            XCTAssertEqual(uti.resolution.evidence.first { $0.signalKind == .systemUTI }?.value,
                           "com.glimt.elm-source", name)
        }
        let conflictingType = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "sample.elm", systemUTI: "public.xml")
        XCTAssertEqual(conflictingType.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertEqual(conflictingType.sourceDocument?.language, .elm)

        let swift = PreviewInspectionResult.prepare(bytes: Data("import Foundation\n".utf8), fileSize: 18,
            fileName: "sample.swift", systemUTI: "com.glimt.elm-source")
        XCTAssertEqual(swift.formatDefinition?.id, .swift)
        XCTAssertEqual(swift.sourceDocument?.language, .swift)

        let plain = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "sample.elm.txt", systemUTI: "public.plain-text")
        XCTAssertNotEqual(plain.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertNotEqual(plain.sourceDocument?.language, .elm)
        let exactType = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "sample.elm.txt", systemUTI: "com.glimt.elm-source")
        XCTAssertEqual(exactType.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertEqual(exactType.sourceDocument?.language, .elm)
        let generic = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
            fileName: "sample", systemUTI: "public.plain-text")
        XCTAssertNotEqual(generic.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertNotEqual(generic.sourceDocument?.language, .elm)

        let referenceURL = try fixtureURL("Cases/reference/Main.elm")
        let referenceBytes = try Data(contentsOf: referenceURL)
        let referenceText = String(decoding: referenceBytes, as: UTF8.self)
        let reference = PreviewInspectionResult.prepare(bytes: referenceBytes, fileSize: referenceBytes.count,
            fileName: referenceURL.lastPathComponent, systemUTI: nil)
        XCTAssertEqual(reference.formatDefinition?.id.rawValue, "reference-elm")
        let referenceRuns = try XCTUnwrap(reference.sourceDocument).highlighting.runs
        let referenceNSString = referenceText as NSString
        let importRange = referenceNSString.range(of: "import Html")
        XCTAssertNotEqual(importRange.location, NSNotFound)
        XCTAssertTrue(referenceRuns.contains(.init(range: referenceNSString.range(of: "import", range: importRange), kind: .keyword)))
        XCTAssertTrue(referenceRuns.contains(.init(range: referenceNSString.range(of: "Html", range: importRange), kind: .type)))
        let qualifiedExpression = referenceNSString.range(of: "String.fromInt")
        XCTAssertNotEqual(qualifiedExpression.location, NSNotFound)
        XCTAssertTrue(referenceRuns.contains(.init(
            range: referenceNSString.range(of: "String", range: qualifiedExpression), kind: .type
        )))
        let numberRange = referenceNSString.range(of: "3")
        XCTAssertTrue(referenceRuns.contains(.init(range: numberRange, kind: .number)), "3")
        XCTAssertEqual(reference.originalBytes, referenceBytes)

        let binaryBytes = Data([0, 255, 0, 255])
        let binary = PreviewInspectionResult.prepare(bytes: binaryBytes, fileSize: binaryBytes.count,
            fileName: "binary.elm", systemUTI: nil)
        XCTAssertEqual(binary.resolution.typeID, "reference-elm")
        XCTAssertEqual(binary.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".elm")
        XCTAssertNil(binary.formatDefinition)
        XCTAssertNil(binary.sourceDocument)
        XCTAssertEqual(binary.originalBytes, binaryBytes)
    }

    func testBisonSuffixRoutingAndRetainedBytes() throws {
        let bisonID = FormatID(rawValue: "reference-bison")
        let bisonUTIs = ["public.yacc-source", "com.glimt.bison-source"]
        let bytes = try Data(contentsOf: fixtureURL("Cases/reference/calc.y"))

        XCTAssertEqual(FormatCatalog.definition(for: bisonID)?.status, .supported)
        for suffix in ["y", "yy"] {
            for name in ["sample.\(suffix)", "sample.\(suffix.uppercased())"] {
                for uti in [nil, "public.yacc-source", "com.glimt.bison-source", "public.plain-text", "public.python-script"] as [String?] {
                    let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                        fileName: name, systemUTI: uti)
                    XCTAssertEqual(result.formatDefinition?.id, bisonID, "\(name), \(uti ?? "nil")")
                    XCTAssertEqual(result.sourceDocument?.language, .bison)
                    XCTAssertEqual(result.resolution.evidence.first { $0.signalKind == .singleExtension }?.value,
                                   ".\(suffix)")
                    XCTAssertEqual(result.resolution.confidence.value, 0.95)
                    if uti == "public.python-script" {
                        XCTAssertEqual(result.resolution.evidence.last?.signalKind, .utiConflict)
                        XCTAssertEqual(result.resolution.evidence.last?.value, "public.python-script")
                    }
                }
            }
        }

        let preservedRoutes: [(String, FormatID, SourceLanguage)] = [
            ("Makefile", FormatID(rawValue: "make"), .makefile),
            ("sample.swift", .swift, .swift),
            ("sample.d.ts", .typescript, .typescript)
        ]
        for (name, expectedID, expectedLanguage) in preservedRoutes {
            let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: name, systemUTI: "com.glimt.bison-source")
            XCTAssertEqual(result.formatDefinition?.id, expectedID, name)
            XCTAssertEqual(result.sourceDocument?.language, expectedLanguage, name)
        }

        for name in ["sample", "sample.unknown", "sample.y.txt", "sample.ym", "sample.ymm", "sample.ypp", "sample.yxx"] {
            for uti in bisonUTIs {
                let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                    fileName: name, systemUTI: uti)
                XCTAssertNotEqual(result.formatDefinition?.id, bisonID, "\(name), \(uti)")
                XCTAssertNotEqual(result.sourceDocument?.language, .bison, "\(name), \(uti)")
            }
        }

        for suffix in ["ym", "ymm", "ypp", "yxx"] {
            let name = "sample.\(suffix)"
            XCTAssertNil(FormatCatalog.match(fileName: name), name)
            for uti in [nil, "public.yacc-source", "com.glimt.bison-source"] as [String?] {
                let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                    fileName: name, systemUTI: uti)

                XCTAssertEqual(result.resolution.typeID, "unknown", "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.resolution.confidence.value, 0, "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.resolution.evidence.first { $0.signalKind == .singleExtension }?.value,
                               "no-match", "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.resolution.evidence.first { $0.signalKind == .systemUTI }?.value,
                               "no-match", "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.formatDefinition?.id, .text, "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.formatDefinition?.effectiveInspectorID, .text, "\(name), \(uti ?? "nil")")
                XCTAssertNil(result.sourceDocument, "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.formatName, "Plain text", "\(name), \(uti ?? "nil")")
                XCTAssertEqual(result.detectionReason, "plainText", "\(name), \(uti ?? "nil")")
            }
        }

        for name in ["sample.y", "sample.yy"] {
            let binaryBytes = Data([0, 255, 0, 255])
            let binary = PreviewInspectionResult.prepare(bytes: binaryBytes, fileSize: binaryBytes.count,
                fileName: name, systemUTI: nil)
            XCTAssertEqual(binary.resolution.typeID, bisonID.rawValue)
            XCTAssertNil(binary.formatDefinition)
            XCTAssertNil(binary.sourceDocument)
            XCTAssertEqual(binary.originalBytes, binaryBytes)
        }
    }

    func testGraphvizSuffixRoutingAndRetainedBytes() throws {
        let graphvizID = FormatID(rawValue: "graphviz")
        let customUTI = "com.glimt.graphviz-dot-source"
        let bytes = try Data(contentsOf: fixtureURL("Cases/reference/graph.dot"))
        let definition = try XCTUnwrap(FormatCatalog.definition(for: graphvizID))
        XCTAssertEqual(definition.displayName, "Graphviz DOT")
        XCTAssertEqual(definition.status, .supported)
        XCTAssertEqual(definition.category, .source)
        XCTAssertEqual(definition.extensions, ["dot", "gv"])
        XCTAssertEqual(definition.exactFilenames, [])
        XCTAssertEqual(definition.contentTypeIdentifiers, [])
        XCTAssertEqual(definition.inspectionKind, .source)
        XCTAssertEqual(definition.effectiveInspectorID, .source)
        XCTAssertEqual(definition.effectiveSettingsProfile, .source)
        XCTAssertEqual(definition.sourceLanguage, .graphviz)
        XCTAssertEqual(definition.effectiveThumbnailStrategy, .sourceCode)
        XCTAssertEqual(definition.availableRepresentations, [.source, .raw, .hex])
        XCTAssertEqual(definition.presentationOrder, [.source, .raw, .hex])
        XCTAssertEqual(definition.effectiveDefaultRepresentation, .source)
        XCTAssertEqual(definition.resolvedDetectionRules.map(\.typeID), ["graphviz"])
        XCTAssertEqual(definition.resolvedDetectionRules[0].singleExtensions, [".dot", ".gv"])
        XCTAssertTrue(try XCTUnwrap(definition.detectionRules?.first).usesCatalogExtensions)
        XCTAssertFalse(try XCTUnwrap(definition.detectionRules?.first).usesCatalogUTIs)
        XCTAssertEqual(FormatCatalog.match(fileName: "graph.DOT")?.id, graphvizID)
        XCTAssertEqual(FormatCatalog.match(fileName: "graph.Gv")?.id, graphvizID)
        XCTAssertEqual(try Data(contentsOf: fixtureURL(try XCTUnwrap(definition.showcaseFixture))), bytes)

        for suffix in ["dot", "gv"] {
            for name in ["sample.\(suffix)", "sample.\(suffix.uppercased())"] {
                for uti in [nil, customUTI, "public.plain-text", "public.python-script"] as [String?] {
                    let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                        fileName: name, systemUTI: uti)
                    XCTAssertEqual(result.formatDefinition?.id, graphvizID, "\(name), \(uti ?? "nil")")
                    XCTAssertEqual(result.sourceDocument?.language, .graphviz)
                    XCTAssertEqual(result.resolution.evidence.first { $0.signalKind == .singleExtension }?.value,
                                   ".\(suffix)")
                    XCTAssertEqual(result.resolution.confidence.value, 0.95)
                    if uti == "public.python-script" {
                        XCTAssertEqual(result.resolution.evidence.last?.signalKind, .utiConflict)
                        XCTAssertEqual(result.resolution.evidence.last?.value, "public.python-script")
                    }
                }
            }
        }

        for name in [".dot", ".gv", "sample", "sample.unknown"] {
            for uti in [customUTI, "public.plain-text"] {
                let result = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                    fileName: name, systemUTI: uti)
                XCTAssertEqual(result.resolution.typeID, "unknown", "\(name), \(uti)")
                XCTAssertEqual(result.resolution.confidence.value, 0, "\(name), \(uti)")
                XCTAssertEqual(result.resolution.evidence.first { $0.signalKind == .singleExtension }?.value,
                               "no-match", "\(name), \(uti)")
                XCTAssertEqual(result.resolution.evidence.first { $0.signalKind == .systemUTI }?.value,
                               "no-match", "\(name), \(uti)")
                XCTAssertEqual(result.formatDefinition?.id, .text)
                XCTAssertNil(result.sourceDocument)
            }
        }
        for name in ["sample.dot.txt", "sample.gv.txt"] {
            let text = PreviewInspectionResult.prepare(bytes: bytes, fileSize: bytes.count,
                fileName: name, systemUTI: customUTI)
            XCTAssertEqual(text.formatDefinition?.id, .text, name)
            XCTAssertEqual(text.formatDefinition?.effectiveInspectorID, .text, name)
            XCTAssertNil(text.sourceDocument, name)
        }
        let swift = PreviewInspectionResult.prepare(bytes: Data("import Foundation\n".utf8), fileSize: 18,
            fileName: "sample.swift", systemUTI: customUTI)
        XCTAssertEqual(swift.formatDefinition?.id, .swift)
        XCTAssertEqual(swift.sourceDocument?.language, .swift)

        let binaryBytes = Data([0, 255, 0, 255])
        for suffix in ["dot", "gv"] {
            let binary = PreviewInspectionResult.prepare(bytes: binaryBytes, fileSize: binaryBytes.count,
                fileName: "binary.\(suffix)", systemUTI: nil)
            XCTAssertEqual(binary.resolution.typeID, graphvizID.rawValue)
            XCTAssertEqual(binary.resolution.evidence.first { $0.signalKind == .singleExtension }?.value, ".\(suffix)")
            XCTAssertNil(binary.formatDefinition)
            XCTAssertNil(binary.sourceDocument)
            XCTAssertEqual(binary.originalBytes, binaryBytes)
        }

        for suffix in ["dot", "gv"] {
            for plistFormat in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
                let plistBytes = try PropertyListSerialization.data(fromPropertyList: ["node": "value"],
                    format: plistFormat, options: 0)
                let result = PreviewInspectionResult.prepare(bytes: plistBytes, fileSize: plistBytes.count,
                    fileName: "sample.\(suffix)", systemUTI: nil)
                XCTAssertEqual(result.resolution.typeID, graphvizID.rawValue)
                XCTAssertEqual(result.formatDefinition?.id, .plist)
                XCTAssertEqual(result.detectionReason, plistFormat == .binary ? "magicBytes" : "contentProbe")
                XCTAssertNil(result.sourceDocument)
                XCTAssertEqual(result.originalBytes, plistBytes)
                guard case .dictionary(let members)? = result.plistInspection?.content else {
                    return XCTFail("Expected a decoded plist dictionary for .\(suffix)")
                }
                XCTAssertEqual(members.map(\.key), ["node"])
                XCTAssertEqual(members.first?.value, .string("value"))
            }
        }

        let malformedURL = try fixtureURL("Cases/source/invalid/malformed-graphviz.dot")
        let malformedBytes = try Data(contentsOf: malformedURL)
        let malformed = try PreviewInspectionResult.read(at: malformedURL)
        XCTAssertEqual(malformed.formatDefinition?.id, graphvizID)
        XCTAssertEqual(malformed.sourceDocument?.source, "digraph G {\n  a [label=<<B>edge</B>\n  a -> b;\n")
        XCTAssertEqual(malformed.analysis.text, malformed.sourceDocument?.source)
        XCTAssertEqual(malformed.originalBytes, malformedBytes)
        let malformedSource = try XCTUnwrap(malformed.sourceDocument)
        let malformedNS = malformedSource.source as NSString
        let labelStart = malformedNS.range(of: "<").location
        let opaqueTail = NSRange(location: labelStart, length: malformedNS.length - labelStart)
        XCTAssertEqual(malformedSource.highlighting.runs.filter { NSIntersectionRange($0.range, opaqueTail).length > 0 }, [])

        for (kind, opening, middle, suffix) in [
            (SyntaxTokenKind.comment, "/*\n", String(repeating: "x\n", count: 19_999), "*/\nedge\n"),
            (.string, "\"", String(repeating: "x\\\n", count: 19_999), "\"\nedge\n")
        ] {
            let source = opening + middle + suffix
            let input = Data(source.utf8)
            let result = PreviewInspectionResult.prepare(bytes: input, fileSize: input.count,
                fileName: "large.dot", systemUTI: nil)
            let document = try XCTUnwrap(result.sourceDocument)
            let expectedSource = kind == .string ? opening + middle + "\"\n" : opening + middle
            XCTAssertEqual(document.source, expectedSource)
            XCTAssertEqual(document.lineCount, 20_000)
            XCTAssertTrue(document.truncated)
            let expectedRunLength = document.source.utf16.count - (kind == .string ? 1 : 0)
            XCTAssertEqual(document.highlighting.runs, [.init(range: NSRange(location: 0, length: expectedRunLength), kind: kind)])
            XCTAssertEqual(result.analysis.text, source)
            XCTAssertEqual(result.originalBytes, input)
        }
        let labelSource = "<\n" + String(repeating: "x\n", count: 19_998) + "<!-- fake ->\n" + "closing>\nedge\n"
        let labelInput = Data(labelSource.utf8)
        let labelResult = PreviewInspectionResult.prepare(bytes: labelInput, fileSize: labelInput.count,
            fileName: "large.dot", systemUTI: nil)
        let labelDocument = try XCTUnwrap(labelResult.sourceDocument)
        XCTAssertEqual(labelDocument.source, "<\n" + String(repeating: "x\n", count: 19_998) + "<!-- fake ->\n")
        XCTAssertEqual(labelDocument.lineCount, 20_000)
        XCTAssertTrue(labelDocument.truncated)
        XCTAssertTrue(labelDocument.highlighting.runs.isEmpty)
        XCTAssertEqual(labelResult.analysis.text, labelSource)
        XCTAssertEqual(labelResult.originalBytes, labelInput)

        let byteLimit = 1_048_576
        let cuts: [(String, String, SyntaxTokenKind?)] = [
            ("/*", "*/\n", .comment), ("\"", "\"\n", .string), ("<", ">\n", nil),
            ("//", "\n", .comment), ("#", "\n", .directive)
        ]
        for (opening, closing, expectedKind) in cuts {
            let prefix = opening + String(repeating: "x", count: byteLimit - opening.utf8.count)
            let input = Data((prefix + closing + "edge\n").utf8)
            let result = PreviewInspectionResult.prepare(bytes: input, fileSize: input.count,
                fileName: "capped.dot", systemUTI: nil)
            let document = try XCTUnwrap(result.sourceDocument)
            XCTAssertTrue(document.truncated, opening)
            XCTAssertEqual(document.source, prefix, opening)
            XCTAssertEqual(result.analysis.text, prefix, opening)
            XCTAssertEqual(result.originalBytes, Data(input.prefix(byteLimit)), opening)
            let expectedRuns = expectedKind.map { [HighlightRun(range: NSRange(location: 0, length: byteLimit), kind: $0)] } ?? []
            XCTAssertEqual(document.highlighting.runs, expectedRuns, opening)
        }
        let splitScalarBytes = Data(String(repeating: "x", count: byteLimit - 1).utf8) + Data([0xC3, 0xA9]) + Data("tail".utf8)
        let splitScalar = PreviewInspectionResult.prepare(bytes: splitScalarBytes, fileSize: splitScalarBytes.count,
            fileName: "split.dot", systemUTI: nil)
        let splitDocument = try XCTUnwrap(splitScalar.sourceDocument)
        XCTAssertEqual(splitScalar.originalBytes.count, byteLimit)
        XCTAssertEqual(splitScalar.originalBytes.last, 0xC3)
        XCTAssertEqual(splitDocument.source, String(repeating: "x", count: byteLimit - 1))
        XCTAssertEqual(splitScalar.analysis.text, splitDocument.source)
        XCTAssertTrue(splitDocument.truncated)
        XCTAssertTrue(splitDocument.highlighting.runs.isEmpty)

        let manyDelimiters = String(repeating: ";", count: 50_001)
        let delimiterBytes = Data(manyDelimiters.utf8)
        let limited = PreviewInspectionResult.prepare(bytes: delimiterBytes, fileSize: delimiterBytes.count,
            fileName: "runs.dot", systemUTI: nil)
        let limitedDocument = try XCTUnwrap(limited.sourceDocument)
        XCTAssertEqual(limitedDocument.source, manyDelimiters)
        XCTAssertEqual(limited.analysis.text, manyDelimiters)
        XCTAssertEqual(limited.originalBytes, delimiterBytes)
        XCTAssertTrue(limitedDocument.highlighting.runs.isEmpty)
        XCTAssertTrue(limitedDocument.diagnostics.contains { $0.code == .limitExceeded })
        XCTAssertFalse(limitedDocument.diagnostics.contains { $0.code == .truncated })
    }

    func testBisonLexicalRunsAndSectionBoundaries() throws {
        let showcase = try String(contentsOf: fixtureURL("Showcase/source/bison.y"), encoding: .utf8)
        let showcaseNSString = showcase as NSString
        var cursor = 0
        var expected: [HighlightRun] = []
        func expect(_ token: String, _ kind: SyntaxTokenKind, file: StaticString = #filePath, line: UInt = #line) {
            let range = showcaseNSString.range(of: token,
                range: NSRange(location: cursor, length: showcaseNSString.length - cursor))
            XCTAssertNotEqual(range.location, NSNotFound, "Missing \(token)", file: file, line: line)
            guard range.location != NSNotFound else { return }
            expected.append(.init(range: range, kind: kind))
            cursor = range.upperBound
        }
        expect("%{", .directive)
        expect("/* å %% %} */", .comment)
        expect("%}", .directive)
        expect("%code", .directive)
        expect("\"%% }\"", .string)
        expect("%token", .directive)
        expect("%printer", .directive)
        expect("$$", .variable)
        expect("%%", .directive)
        expect("start", .type)
        expect(":", .keyword)
        expect("'x'", .string)
        expect("$1", .variable)
        expect("@$", .variable)
        expect("/* } %% */", .comment)
        expect("|", .keyword)
        expect("'y'", .string)
        expect(";", .keyword)
        expect("%%", .directive)
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(showcase, language: .bison).runs, expected)

        let grammar = "%%\nfoo: ::: || a:: a.b: 1abc: éabc: ;\n%%"
        let grammarNSString = grammar as NSString
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(grammar, language: .bison).runs, [
            .init(range: grammarNSString.range(of: "%%"), kind: .directive),
            .init(range: grammarNSString.range(of: "foo"), kind: .type),
            .init(range: grammarNSString.range(of: ":", range: NSRange(location: grammarNSString.range(of: "foo").upperBound, length: grammarNSString.length - grammarNSString.range(of: "foo").upperBound)), kind: .keyword),
            .init(range: grammarNSString.range(of: "a.b"), kind: .type),
            .init(range: grammarNSString.range(of: ":", range: NSRange(location: grammarNSString.range(of: "a.b").upperBound, length: grammarNSString.length - grammarNSString.range(of: "a.b").upperBound)), kind: .keyword),
            .init(range: grammarNSString.range(of: ":", range: NSRange(location: grammarNSString.range(of: "1abc").upperBound, length: grammarNSString.length - grammarNSString.range(of: "1abc").upperBound)), kind: .keyword),
            .init(range: grammarNSString.range(of: ":", range: NSRange(location: grammarNSString.range(of: "éabc").upperBound, length: grammarNSString.length - grammarNSString.range(of: "éabc").upperBound)), kind: .keyword),
            .init(range: grammarNSString.range(of: ";"), kind: .keyword),
            .init(range: grammarNSString.range(of: "%%", options: [], range: NSRange(location: grammarNSString.length - 2, length: 2)), kind: .directive)
        ])

        let declarations = "%foo-bar_2 WORD\n%} %%x\nstart: 'x';"
        let declarationsNSString = declarations as NSString
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(declarations, language: .bison).runs, [
            .init(range: declarationsNSString.range(of: "%foo-bar_2"), kind: .directive),
            .init(range: declarationsNSString.range(of: "%x"), kind: .directive),
            .init(range: declarationsNSString.range(of: "'x'"), kind: .string)
        ])

        let rulesOnly = "%%\n%{ %% %}\n%%\nignored: 'y';"
        let rulesOnlyNSString = rulesOnly as NSString
        let rulesClosingTokenEnd = rulesOnlyNSString.range(of: "%}").upperBound
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(rulesOnly, language: .bison).runs, [
            .init(range: rulesOnlyNSString.range(of: "%%"), kind: .directive),
            .init(range: rulesOnlyNSString.range(of: "%%", options: [], range: NSRange(location: rulesClosingTokenEnd, length: rulesOnlyNSString.length - rulesClosingTokenEnd)), kind: .directive)
        ])
    }

    func testBisonEmbeddedShieldingAndSemanticReferences() throws {
        let source = "%%\nstart: x { $1 @$ @name @2 $$ $name &@$ foo$name $$name $12abc $-1 $name[part] $<tag>name @name[part] @<tag>name \"$$\" /* $1 */ // @$\\\ncontinued $2\n $2\n R\"raw\" $$; }\n%%\nend: 'z';"
        let ns = source as NSString
        let runs = try InternalSyntaxHighlighter().highlight(source, language: .bison).runs
        let variables = runs.filter { $0.kind == .variable }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(variables, ["$1", "@$", "@name", "@2", "$$", "$name", "@$", "$2"])
        for rejected in ["foo$name", "$$name", "$12abc", "$-1", "$name[part]", "$<tag>name", "@name[part]", "@<tag>name"] {
            XCTAssertFalse(runs.contains { ns.substring(with: $0.range).contains(rejected) }, rejected)
        }
        XCTAssertTrue(runs.contains { $0.kind == .string && ns.substring(with: $0.range) == "\"$$\"" })
        XCTAssertTrue(runs.contains { $0.kind == .comment && ns.substring(with: $0.range) == "/* $1 */" })
        XCTAssertFalse(runs.contains { $0.range.location > ns.range(of: "R\"raw\"").location })

        let escapedScalar = "%%\nstart: x { \"before\\😀\\\r\nstill\"; // continued\\\r\ncomment $1\n$2; }"
        let escapedNSString = escapedScalar as NSString
        let escapedRuns = try InternalSyntaxHighlighter().highlight(escapedScalar, language: .bison).runs
        XCTAssertTrue(escapedRuns.contains(.init(range: escapedNSString.range(of: "\"before\\😀\\\r\nstill\""), kind: .string)))
        XCTAssertTrue(escapedRuns.contains(.init(range: escapedNSString.range(of: "// continued\\\r\ncomment $1"), kind: .comment)))
        XCTAssertTrue(escapedRuns.contains(.init(range: escapedNSString.range(of: "$2"), kind: .variable)))

        for rawPrefix in ["R\"", "u8R\"", "uR\"", "UR\"", "LR\""] {
            let raw = "%%\nstart: x { \(rawPrefix)tail\" $$; }\n%%\nnext: x;"
            let rawNSString = raw as NSString
            let rawRuns = try InternalSyntaxHighlighter().highlight(raw, language: .bison).runs
            XCTAssertFalse(rawRuns.contains { $0.range.location > rawNSString.range(of: rawPrefix).location }, rawPrefix)
        }

        let lineEndings = ["\n", "\r\n", "\r"]
        for ending in lineEndings {
            let text = " %%\t%% trailing\(ending)start: 'x';\(ending)%%\(ending)ignored: 'y';"
            let textNSString = text as NSString
            let highlighted = try InternalSyntaxHighlighter().highlight(text, language: .bison).runs
            XCTAssertTrue(highlighted.contains(.init(range: textNSString.range(of: "%%"), kind: .directive)), ending.debugDescription)
            XCTAssertFalse(highlighted.contains { textNSString.substring(with: $0.range) == "ignored" }, ending.debugDescription)
        }

        let comments = "// %%\n%%\nnext: 'x';"
        let commentsNSString = comments as NSString
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(comments, language: .bison).runs, [
            .init(range: NSRange(location: 0, length: 5), kind: .comment),
            .init(range: commentsNSString.range(of: "%%", range: NSRange(location: 6, length: commentsNSString.length - 6)), kind: .directive),
            .init(range: commentsNSString.range(of: "next"), kind: .type),
            .init(range: commentsNSString.range(of: ":"), kind: .keyword),
            .init(range: commentsNSString.range(of: "'x'"), kind: .string),
            .init(range: commentsNSString.range(of: ";"), kind: .keyword)
        ])

        let rawPrefix = "%%\nstart: x { "
        let retainedText = rawPrefix + String(repeating: " ", count: 1_048_576 - rawPrefix.utf16.count - 3) + "u8R"
        let retainedBytes = Data((retainedText + "\" ignored %% $$;").utf8)
        let retainedAnalysis = TextAnalysis.analyze(bytes: retainedBytes, fileSize: retainedBytes.count, maximumBytes: 1_048_576)
        let retained = try SourceCodeInspector.inspect(analysis: retainedAnalysis, language: .bison)
        XCTAssertTrue(retained.truncated)
        XCTAssertEqual(retained.source, retainedText)
        let rawStart = (retained.source as NSString).range(of: "u8R", options: [], range: NSRange(location: rawPrefix.utf16.count, length: retained.source.utf16.count - rawPrefix.utf16.count)).location
        XCTAssertFalse(retained.highlighting.runs.contains { $0.kind == .string || $0.range.location >= rawStart })
    }

    func testBisonLineRecoveryAndBraceDepthLimit() throws {
        let recovery = "%%\nstart: 'open\nnext: 'ok';"
        let recoveryNSString = recovery as NSString
        let recovered = try InternalSyntaxHighlighter().highlight(recovery, language: .bison).runs
        let openLocation = recoveryNSString.range(of: "'open").location
        let quoteLineEnd = recoveryNSString.range(of: "\n", range: NSRange(location: openLocation, length: recoveryNSString.length - openLocation)).location
        XCTAssertTrue(recovered.contains(.init(range: NSRange(location: openLocation, length: quoteLineEnd - openLocation), kind: .string)))
        XCTAssertTrue(recovered.contains(.init(range: recoveryNSString.range(of: "next"), kind: .type)))
        XCTAssertTrue(recovered.contains(.init(range: recoveryNSString.range(of: "'ok'"), kind: .string)))

        let unclosedComment = "%%\nstart: x { /* open\n$$"
        let commentRun = try XCTUnwrap(InternalSyntaxHighlighter().highlight(unclosedComment, language: .bison).runs.last)
        XCTAssertEqual(commentRun.kind, .comment)
        XCTAssertEqual(commentRun.range.upperBound, unclosedComment.utf16.count)

        let unclosedPrologue = "%{\n%token WORD\n%%\nstart: x;"
        let prologueRuns = try InternalSyntaxHighlighter().highlight(unclosedPrologue, language: .bison).runs
        XCTAssertEqual(prologueRuns, [.init(range: NSRange(location: 0, length: 2), kind: .directive)])

        for depth in [256, 257] {
            let specimen = "%%\nstart: " + String(repeating: "{", count: depth) + "$1" + String(repeating: "}", count: depth) + ";"
            let bytes = Data(specimen.utf8)
            let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
            let document = try SourceCodeInspector.inspect(analysis: analysis, language: .bison)
            let specimenNSString = specimen as NSString
            XCTAssertEqual(document.source, specimen)
            XCTAssertFalse(document.truncated)
            if depth == 256 {
                XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .variable && specimenNSString.substring(with: $0.range) == "$1" })
                XCTAssertFalse(document.diagnostics.contains { $0.code == .limitExceeded })
            } else {
                XCTAssertTrue(document.highlighting.runs.isEmpty)
                XCTAssertTrue(document.diagnostics.contains {
                    $0.code == .limitExceeded && $0.message == "Syntax highlighting limit reached. Showing plain text."
                })
            }
        }
    }

    func testElmMalformedAndTruncatedSource() throws {
        let malformedURL = try fixtureURL("Cases/source/invalid/malformed.elm")
        let malformedBytes = try Data(contentsOf: malformedURL)
        let malformedText = String(decoding: malformedBytes, as: UTF8.self)
        let malformed = PreviewInspectionResult.prepare(bytes: malformedBytes, fileSize: malformedBytes.count,
            fileName: malformedURL.lastPathComponent, systemUTI: nil)
        XCTAssertEqual(malformed.formatDefinition?.id.rawValue, "reference-elm")
        XCTAssertEqual(malformed.originalBytes, malformedBytes)
        let malformedDocument = try XCTUnwrap(malformed.sourceDocument)
        XCTAssertEqual(malformedDocument.source, malformedText)
        let stringStart = (malformedText as NSString).range(of: "\"").location
        let stringBreak = (malformedText as NSString).range(of: "\n", range: NSRange(location: stringStart, length: (malformedText as NSString).length - stringStart)).location
        XCTAssertTrue(malformedDocument.highlighting.runs.contains(.init(
            range: NSRange(location: stringStart, length: stringBreak - stringStart), kind: .string
        )))
        XCTAssertTrue(malformedDocument.highlighting.runs.contains(.init(
            range: (malformedText as NSString).range(of: "42"), kind: .number
        )), "the declaration after the unclosed string is still colored")
        let commentStart = (malformedText as NSString).range(of: "{-").location
        let comment = try XCTUnwrap(malformedDocument.highlighting.runs.first { $0.kind == .comment })
        XCTAssertEqual(comment.range.location, commentStart)
        XCTAssertEqual(comment.range.upperBound, malformedDocument.source.utf16.count)

        let complete = "module Glimt exposing (..)\n{- 😀\n-}\n"
        let completeBytes = Data(complete.utf8)
        let analysis = TextAnalysis.analyze(bytes: completeBytes, fileSize: completeBytes.count, maximumBytes: 1_048_576)
        let clipped = try SourceCodeInspector.inspect(analysis: analysis, language: .elm, maximumLines: 2)
        XCTAssertEqual(clipped.source, "module Glimt exposing (..)\n{- 😀\n")
        XCTAssertTrue(clipped.truncated)
        let clippedComment = try XCTUnwrap(clipped.highlighting.runs.first { $0.kind == .comment })
        XCTAssertEqual(clippedComment.range.upperBound, clipped.source.utf16.count)
        XCTAssertLessThanOrEqual(clippedComment.range.upperBound, clipped.source.utf16.count)
    }

    func testYANGMalformedAndTruncatedSource() throws {
        let malformedURL = try fixtureURL("Cases/source/invalid/malformed.yang")
        let malformedBytes = try Data(contentsOf: malformedURL)
        let malformed = PreviewInspectionResult.prepare(
            bytes: malformedBytes, fileSize: malformedBytes.count, fileName: malformedURL.lastPathComponent, systemUTI: nil
        )
        XCTAssertEqual(malformed.originalBytes, malformedBytes)
        XCTAssertEqual(malformed.sourceDocument?.source, String(decoding: malformedBytes, as: UTF8.self))
        let malformedDocument = try XCTUnwrap(malformed.sourceDocument)
        XCTAssertTrue(malformedDocument.source.hasPrefix("module glimt {\n  yang-version 1.1;\n"))
        let comment = try XCTUnwrap(malformedDocument.highlighting.runs.first { $0.kind == .comment })
        XCTAssertEqual(comment.range, NSRange(location: (malformedDocument.source as NSString).range(of: "/*").location,
                                              length: malformedDocument.source.utf16.count - (malformedDocument.source as NSString).range(of: "/*").location))
        XCTAssertEqual(comment.range.upperBound, malformedDocument.source.utf16.count)

        let complete = "module glimt {\n  description \"open quote\nclosed quote\";\n}"
        let completeBytes = Data(complete.utf8)
        let analysis = TextAnalysis.analyze(bytes: completeBytes, fileSize: completeBytes.count, maximumBytes: 1_048_576)
        let clipped = try SourceCodeInspector.inspect(analysis: analysis, language: .yang, maximumLines: 2)
        XCTAssertEqual(clipped.source, "module glimt {\n  description \"open quote\n")
        XCTAssertTrue(clipped.truncated)
        XCTAssertTrue(clipped.diagnostics.contains { if case .truncated = $0.code { true } else { false } })
        XCTAssertEqual(clipped.highlighting.runs.last, HighlightRun(range: NSRange(location: 29, length: 12), kind: .string))

        let prepared = PreviewInspectionResult.prepare(
            bytes: completeBytes, fileSize: completeBytes.count, fileName: "complete.yang", systemUTI: nil
        )
        XCTAssertEqual(prepared.originalBytes, completeBytes)
        XCTAssertEqual(prepared.sourceDocument?.source, complete)
    }

    func testElmLexicalRuns() throws {
        XCTAssertEqual(SourceLanguage(rawValue: "elm")?.displayName, "Elm")

        let keywords = "alias as case else exposing if import in infix let module of port then type"
        let keywordSource = keywords + " aliasing modulex Case Constructor"
        let keywordRuns = try InternalSyntaxHighlighter().highlight(keywordSource, language: .elm).runs
        var keywordOffset = 0
        let expectedKeywords = keywords.split(separator: " ").map(String.init).map { word -> HighlightRun in
            let run = HighlightRun(range: NSRange(location: keywordOffset, length: word.utf16.count), kind: .keyword)
            keywordOffset += word.utf16.count + 1
            return run
        }
        XCTAssertEqual(keywordRuns.filter { $0.kind == .keyword }, expectedKeywords)
        for word in ["Case", "Constructor"] {
            let range = (keywordSource as NSString).range(of: word)
            XCTAssertTrue(keywordRuns.contains(.init(range: range, kind: .type)), word)
        }
        XCTAssertFalse(keywordRuns.contains { (keywordSource as NSString).substring(with: $0.range) == "aliasing" })
        XCTAssertFalse(keywordRuns.contains { (keywordSource as NSString).substring(with: $0.range) == "modulex" })

        let punctuatedIdentifiers = "Upper.Lower Tail'bar'"
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(punctuatedIdentifiers, language: .elm).runs, [
            .init(range: NSRange(location: 0, length: 5), kind: .type),
            .init(range: NSRange(location: 6, length: 5), kind: .type),
            .init(range: NSRange(location: 12, length: 4), kind: .type),
            .init(range: NSRange(location: 16, length: 5), kind: .string)
        ])

        let numbers = "12 1.5 2e3 0xFF 1_000"
        let numberRuns = try InternalSyntaxHighlighter().highlight(numbers, language: .elm).runs
        XCTAssertEqual(numberRuns.map { (numbers as NSString).substring(with: $0.range) },
                       ["12", "1.5", "2e3", "0xFF", "1_000"])
        XCTAssertTrue(numberRuns.allSatisfy { $0.kind == .number })

        let characters = "'a' '\\n' '\\u{1F600}' '' 'ab' '😀'"
        let characterRuns = try InternalSyntaxHighlighter().highlight(characters, language: .elm).runs
        XCTAssertEqual(characterRuns.map { (characters as NSString).substring(with: $0.range) },
                       ["'a'", "'\\n'", "'\\u{1F600}'", "''", "'ab'", "'😀'"])
        XCTAssertTrue(characterRuns.allSatisfy { $0.kind == .string })

        let escapedQuote = "\"text \\\" -- {-\""
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(escapedQuote, language: .elm).runs,
                       [.init(range: NSRange(location: 0, length: escapedQuote.utf16.count), kind: .string)])
        for unclosed in ["\"open", "\"\"\"open -- {-𐐷"] {
            XCTAssertEqual(try InternalSyntaxHighlighter().highlight(unclosed, language: .elm).runs,
                           [.init(range: NSRange(location: 0, length: unclosed.utf16.count), kind: .string)])
        }

        let triple = "\"\"\"first\n-- {- /*\n\"\"\" module"
        let tripleRuns = try InternalSyntaxHighlighter().highlight(triple, language: .elm).runs
        let tripleEnd = try XCTUnwrap(triple.range(of: "\"\"\"", options: .backwards)).upperBound
        let tripleSpan = NSRange(triple.startIndex..<tripleEnd, in: triple)
        XCTAssertTrue(tripleRuns.contains(.init(range: tripleSpan, kind: .string)))
        XCTAssertTrue(tripleRuns.contains(.init(range: (triple as NSString).range(of: "module"), kind: .keyword)))

        let comments = "{- outer -- \" {- nested -} tail -} -- line {-\nmodule Elm"
        let commentRuns = try InternalSyntaxHighlighter().highlight(comments, language: .elm).runs
        let blockRange = (comments as NSString).range(of: "{- outer -- \" {- nested -} tail -}")
        let lineRange = (comments as NSString).range(of: "-- line {-")
        XCTAssertTrue(commentRuns.contains(.init(range: blockRange, kind: .comment)))
        XCTAssertTrue(commentRuns.contains(.init(range: lineRange, kind: .comment)))
        XCTAssertTrue(commentRuns.contains(.init(range: (comments as NSString).range(of: "module", options: [], range: NSRange(location: lineRange.upperBound, length: (comments as NSString).length - lineRange.upperBound)), kind: .keyword)))

        let lfPrefix = "'open\\\n"
        let crPrefix = "\"open\\\r"
        let lineRecovery = lfPrefix + "module M\n" + crPrefix + "module N"
        let recoveryRuns = try InternalSyntaxHighlighter().highlight(lineRecovery, language: .elm).runs
        XCTAssertTrue(recoveryRuns.contains(.init(range: NSRange(location: 0, length: lfPrefix.utf16.count - 1), kind: .string)))
        let secondQuote = lfPrefix.utf16.count + "module M\n".utf16.count
        XCTAssertTrue(recoveryRuns.contains(.init(range: NSRange(location: secondQuote, length: crPrefix.utf16.count - 1), kind: .string)))
        for moduleRange in [NSRange(location: lfPrefix.utf16.count, length: 6),
                            NSRange(location: secondQuote + crPrefix.utf16.count, length: 6)] {
            XCTAssertTrue(recoveryRuns.contains(.init(range: moduleRange, kind: .keyword)))
        }

        let unicode = "😀 module Glimt"
        let unicodeRuns = try InternalSyntaxHighlighter().highlight(unicode, language: .elm).runs
        XCTAssertEqual(unicodeRuns, [
            .init(range: NSRange(location: 3, length: 6), kind: .keyword),
            .init(range: NSRange(location: 10, length: 5), kind: .type)
        ])
        XCTAssertTrue(zip(unicodeRuns, unicodeRuns.dropFirst()).allSatisfy { $0.0.range.upperBound <= $0.1.range.location })

        let depth64 = String(repeating: "{-", count: 64) + "😀" + String(repeating: "-}", count: 64)
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(depth64, language: .elm).runs,
                       [.init(range: NSRange(location: 0, length: depth64.utf16.count), kind: .comment)])
        let depth65 = String(repeating: "{-", count: 65) + "x" + String(repeating: "-}", count: 65)
        let depth65Bytes = Data(depth65.utf8)
        let analysis = TextAnalysis.analyze(bytes: depth65Bytes, fileSize: depth65Bytes.count, maximumBytes: 1_048_576)
        let limited = try SourceCodeInspector.inspect(analysis: analysis, language: .elm)
        XCTAssertEqual(limited.source, depth65)
        XCTAssertTrue(limited.highlighting.runs.isEmpty)
        XCTAssertEqual(limited.diagnostics.first?.code, .limitExceeded)
    }
}
