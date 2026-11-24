import Foundation
import XCTest
@testable import InspectorCore

final class SourceDetectionTests: XCTestCase {
    private func detect(_ name: String, uti: String? = nil, source: String = "let value = 42\n", complete: Bool = true) -> SourceDetection {
        let bytes = Data(source.utf8)
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count + (complete ? 0 : 1), maximumBytes: 1_048_576)
        return SourceDetector.detect(fileName: name, systemUTI: uti, analysis: analysis)
    }

    func testKnownExtensionsAndLanguageNames() {
        let groups: [(SourceLanguage, [String])] = [
            (.html, ["html", "htm"]), (.sql, ["sql"]), (.tsql, ["tsql", "mssql"]), (.rust, ["rs"]), (.php, ["php"]),
            (.swift, ["swift"]), (.java, ["java"]), (.c, ["c", "h"]),
            (.cpp, ["cc", "cp", "cpp", "c++", "cu", "cxx", "hh", "hpp", "hxx", "ipp"]),
            (.python, ["py", "pyi", "pyw", "py3", "cpy", "gyp", "gypi", "pxd", "pxi", "rpy", "pyx"]),
            (.javascript, ["js", "mjs", "cjs", "psjs"]), (.jsx, ["jsx", "astro"]), (.typescript, ["ts"]),
            (.tsx, ["tsx"]), (.terraform, ["tf", "tfvars"]), (.scss, ["scss"]),
            (.objectiveC, ["mm"]), (.ocaml, ["ml", "mli"]), (.apache, ["htaccess"]),
            (.tcl, ["tcl", "tk", "itcl", "wish"]), (.appleScript, ["applescript"]),
            (.makefile, ["mk", "mak"]), (.dtd, ["dtd"]), (.xquery, ["xquery", "xq", "xu"]),
            (.jsp, ["jsp"]), (.haml, ["haml"]), (.latex, ["tex", "ltx", "sty", "cls"]),
            (.plsql, ["pkb", "pks", "pck", "fnc", "prc", "trg", "tps", "tpb"]),
            (.visualBasic, ["vb", "vbs", "bas", "basic", "bi"]), (.vala, ["vala", "vapi"]),
            (.vimscript, ["vim"]),
            (.nim, ["nim"]), (.openSCAD, ["scad"]), (.webAssemblyText, ["wat"]),
            (.pascal, ["pas", "dpr", "dpk", "lpr"]), (.verilog, ["vh"]), (.vhdl, ["vhd", "vhdl"]),
            (.cobol, ["cob", "cbl"]), (.deviceTree, ["dts", "dtsi"]), (.gettext, ["po", "pot"]),
            (.erb, ["erb"]), (.qml, ["qml"]), (.solidity, ["sol"]),
            (.perl, ["pl", "pm", "cgi", "plex", "plx"]),
            (.r, ["r"]), (.scala, ["scala"]), (.julia, ["jl"]),
            (.nix, ["nix"]), (.cue, ["cue"]), (.kdl, ["kdl"]),
            (.xcconfig, ["xcconfig"]),
            (.vue, ["vue"]), (.svelte, ["svelte"]), (.asciidoc, ["adoc", "asciidoc"]),
            (.reStructuredText, ["rst"]), (.org, ["org"]),
            (.asp, ["asp"]), (.aspx, ["aspx", "ascx", "ashx"]),
            (.jinja, ["jinja", "jinja2", "j2"]), (.twig, ["twig"]),
            (.shell, ["sh", "bash", "zsh", "command", "ksh", "ebuild", "eclass"]), (.ada, ["ada", "adb", "ads", "gnad"]),
            (.actionscript, ["as"]), (.assembly, ["asm", "s79"]), (.awk, ["awk"]),
            (.toml, ["toml"]), (.ini, ["ini", "desktop", "doxyfile", "kdev3"]), (.properties, ["properties"]),
            (.fsharp, ["fs", "fsx"]), (.fish, ["fish"]),
            (.fortran, ["f", "for", "ftn", "f90", "f95"]), (.gdscript, ["gd"]),
            (.gleam, ["gleam"]), (.go, ["go"]), (.groovy, ["groovy", "gradle"]),
            (.haskell, ["hs", "lhs"]), (.zig, ["zig"]),
            (.d, ["d"]), (.batch, ["bat", "cmd"]), (.dylan, ["dylan"]),
            (.eiffel, ["e", "se"]), (.elixir, ["ex", "exs"]), (.erlang, ["erl", "hri", "hrl"]),
            (.clojure, ["bb", "cli", "clj", "cljc", "cljs", "edn"]),
            (.csh, ["csh"]), (.csharp, ["cs"]), (.cmake, ["cmake"]),
            (.ruby, ["podspec", "rb", "rbx", "ruby", "rake", "gemspec"]), (.coffeescript, ["coffee"]),
            (.coldfusion, ["cfc", "cfm", "cfml"]), (.crystal, ["cr"]),
            (.cson, ["cson"]), (.css, ["css"]), (.bibtex, ["bib"]),
            (.kotlin, ["kt", "kts"]), (.less, ["less"]), (.lisp, ["lisp", "lsp", "asd", "el"]),
            (.lua, ["lua"]), (.powershell, ["ps1", "psm1", "psd1"]), (.miniscript, ["ms"]),
            (.autoHotkey, ["ahk"]), (.innoSetup, ["iss"]), (.nsis, ["nsi", "nsh"]),
            (.rego, ["rego"]), (.ldif, ["ldif"]), (.turtle, ["ttl", "n3", "nt"]),
            (.yang, ["yang"]), (.elm, ["elm"]), (.bison, ["y", "yy"]), (.graphviz, ["dot", "gv"])
        ]
        let languagesOutsideExtensionGroups: Set<SourceLanguage> = [
            .markdown, .dotenv, .dockerfile, .meson, .matlab, .nginx,
            .gitignore, .dockerignore, .gitAttributes, .goModule
        ]
        let groupedLanguages = Set(groups.map { $0.0 })
        XCTAssertEqual(groupedLanguages.count, groups.count)
        XCTAssertEqual(groupedLanguages, Set(SourceLanguage.allCases).subtracting(languagesOutsideExtensionGroups))
        for (name, language) in [("Makefile", SourceLanguage.makefile), ("meson.build", .meson), ("meson_options.txt", .meson),
                                 ("SConstruct", .python), ("Snakefile", .python), ("wscript", .python)] {
            XCTAssertEqual(detect(name).language, language, name)
            XCTAssertEqual(detect(name).reason, .exactFilename, name)
        }
        for (language, extensions) in groups {
            XCTAssertFalse(language.displayName.isEmpty)
            for ext in extensions {
                let sample = "let value = 42\n"
                let result = detect("example.\(ext)", source: sample)
                XCTAssertEqual(result.language, language, ext)
                XCTAssertEqual(result.reason, .fileExtension)
                XCTAssertEqual(detect("example.\(ext.uppercased())", source: sample).language, language)
            }
        }
        XCTAssertNil(detect(".env").language)
        XCTAssertEqual(SourceLanguage.graphviz.displayName, "Graphviz DOT")
    }

    func testMatlabAndObjectiveCSharedMSuffixUsesContentEvidence() {
        let matlab = detect("analysis.m", source: "function y = f(x)\ny = x + 1;\nend\n")
        XCTAssertEqual(matlab.language, .matlab)
        XCTAssertEqual(matlab.reason, .contentEvidence)

        let objectiveC = detect("Greeter.m", source: "#import <Foundation/Foundation.h>\n@implementation Greeter\n@end\n")
        XCTAssertEqual(objectiveC.language, .objectiveC)
        XCTAssertEqual(objectiveC.reason, .contentEvidence)

        XCTAssertNil(detect("ambiguous.m", source: "value = 1;\n").language)
        XCTAssertEqual(detect("ambiguous.m", source: "value = 1;\n").reason, .plainText)
    }

    func testNginxUsesExactFilenameOrStrongConfContentEvidence() {
        let named = detect("nginx.conf", source: "worker_processes 2;\nevents { worker_connections 512; }\n")
        XCTAssertEqual(named.language?.rawValue, "nginx")
        XCTAssertEqual(named.reason, .exactFilename)

        let content = detect("site.conf", source: "server {\n    listen 443 ssl;\n    server_name example.test;\n    location / { proxy_pass http://app; }\n}\n")
        XCTAssertEqual(content.language?.rawValue, "nginx")
        XCTAssertEqual(content.reason, .contentEvidence)

        let generic = detect("service.conf", source: "server = app\nport = 8080\n")
        XCTAssertNil(generic.language)
        XCTAssertEqual(generic.reason, .plainText)
    }

    func testApacheUsesSpecificNamesExtensionsOrStrongConfContentEvidence() {
        let named = detect("httpd.conf", source: "ServerName example.test\nDocumentRoot /srv/www\n")
        XCTAssertEqual(named.language?.rawValue, "apache")
        XCTAssertEqual(named.reason, .exactFilename)

        let content = detect("site.conf", source: "<VirtualHost *:443>\n    ServerName example.test\n    DocumentRoot /srv/www\n</VirtualHost>\n")
        XCTAssertEqual(content.language?.rawValue, "apache")
        XCTAssertEqual(content.reason, .contentEvidence)

        let htaccess = detect(".htaccess", source: "RewriteEngine On\nRewriteRule ^old$ /new [R=301,L]\n")
        XCTAssertEqual(htaccess.language?.rawValue, "apache")
        XCTAssertEqual(htaccess.reason, .exactFilename)

        XCTAssertNil(detect("service.conf", source: "server = app\nport = 8080\n").language)
        XCTAssertEqual(detect("site.conf", source: "server {\n  listen 443;\n  location / { proxy_pass http://app; }\n}\n").language?.rawValue, "nginx")
    }

    func testTSQLUsesItsExtensionsOrMultipleDialectMarkersWithoutCapturingGenericSQL() {
        let content = detect("query.sql", source: "DECLARE @limit int = 10;\nSELECT TOP (@limit) ISNULL(name, N'unknown') FROM dbo.Users;\nGO\n")
        XCTAssertEqual(content.language, .tsql)
        XCTAssertEqual(content.reason, .contentEvidence)

        XCTAssertEqual(detect("query.tsql", source: "SELECT 1;\n").language, .tsql)
        XCTAssertEqual(detect("query.MSSQL", source: "SELECT 1;\n").language, .tsql)
        XCTAssertEqual(detect("query.sql", source: "SELECT current_timestamp;\n").language, .sql)
        XCTAssertEqual(detect("query.sql", source: "-- GO\n-- DECLARE @x\nSELECT 'TOP (10)';\n").language, .sql)
        XCTAssertEqual(detect("query.sql", source: "/* GO /* DECLARE @x */ TOP (10) */\nSELECT 'GETDATE()';\n").language, .sql)
        XCTAssertEqual(detect("query.sql", source: String(repeating: " ", count: 65_536) + "DECLARE @x nvarchar(10); GO\n").language, .sql)
        XCTAssertEqual(detect("oracle.sql", source: "DECLARE v_text VARCHAR2(20); BEGIN v_text := SYSDATE; END;\n/").language, .sql)
    }

    func testSharedVExtensionRequiresVerilogContentEvidence() {
        let verilog = detect("counter.v", source: "module counter(input logic clk);\n  always_ff @(posedge clk) begin\n  end\nendmodule\n")
        XCTAssertEqual(verilog.language, .verilog)
        XCTAssertEqual(verilog.reason, .contentEvidence)

        let commented = detect("notes.v", source: "// module counter\n/* always_ff @(posedge clk) */\n")
        XCTAssertNil(commented.language)
        XCTAssertNil(detect("string.v", source: #""module counter(input logic clk); always_ff @(posedge clk) endmodule""#).language)

        let vLanguage = detect("main.v", source: "module main\npub fn main() { println('hello') }\n")
        XCTAssertNil(vLanguage.language)

        XCTAssertEqual(detect("counter.vh").language, .verilog)
    }

    func testSharedPPRequiresPascalStructureOutsideCommentsAndStrings() {
        let pascal = detect("unit.pp", source: "unit Demo; interface implementation begin end.")
        XCTAssertEqual(pascal.language, .pascal)
        XCTAssertEqual(pascal.reason, .contentEvidence)

        XCTAssertNil(detect("manifest.pp", source: "class profile {\n  package { 'module': ensure => installed }\n}\n").language)
        XCTAssertNil(detect("notes.pp", source: "{ program Fake; begin }\n(* unit Fake; interface implementation *)\n'program Fake; begin'\n").language)
        XCTAssertNil(detect("incomplete.pp", source: "unit Demo; interface\n").language)
    }

    func testCOBOLDTSAndGettextExtensionsRouteThroughCatalog() {
        XCTAssertEqual(detect("program.cob").language, .cobol)
        XCTAssertEqual(detect("fragment.cbl").language, .cobol)
        XCTAssertEqual(detect("board.dts").language, .deviceTree)
        XCTAssertEqual(detect("overlay.dtsi").language, .deviceTree)
        XCTAssertEqual(detect("sv.po").language, .gettext)
        XCTAssertEqual(detect("template.pot").language, .gettext)
    }

    func testERBQMLAndSolidityExtensionsRouteThroughCatalog() {
        XCTAssertEqual(detect("page.html.erb").language, .erb)
        XCTAssertEqual(detect("Component.qml").language, .qml)
        XCTAssertEqual(detect("Counter.sol").language, .solidity)
    }

    func testOrgModeRoutesThroughCatalog() {
        XCTAssertEqual(detect("notes.org").language, .org)
    }

    func testClassicASPJinjaTwigAndASPNETRouteSeparately() {
        XCTAssertEqual(detect("page.asp").language, .asp)
        XCTAssertEqual(detect("page.aspx").language, .aspx)
        XCTAssertEqual(detect("control.ascx").language, .aspx)
        XCTAssertEqual(detect("handler.ashx").language, .aspx)
        XCTAssertEqual(detect("page.jinja").language, .jinja)
        XCTAssertEqual(detect("page.jinja2").language, .jinja)
        XCTAssertEqual(detect("page.j2").language, .jinja)
        XCTAssertEqual(detect("page.twig").language, .twig)
    }

    func testRequestedShowcasesAreDetectedWithTheirExactLanguages() throws {
        let cases: [(String, SourceLanguage)] = [
            ("Showcase/source/html.html", .html), ("Showcase/source/sql.sql", .sql),
            ("Showcase/source/rust.rs", .rust), ("Showcase/source/php.php", .php),
            ("Showcase/source/ruby.rb", .ruby),
            ("Showcase/source/terraform.tf", .terraform), ("Showcase/source/styles.scss", .scss),
            ("Showcase/source/Greeting.tsx", .tsx), ("Showcase/source/App.vue", .vue),
            ("Showcase/source/Counter.svelte", .svelte), ("Showcase/fileformats/guide.adoc", .asciidoc),
            ("Showcase/fileformats/guide.rst", .reStructuredText),
            ("Showcase/source/fsharp.fs", .fsharp), ("Showcase/source/fish.fish", .fish),
            ("Showcase/source/fortran.f90", .fortran), ("Showcase/source/gdscript.gd", .gdscript),
            ("Showcase/source/gleam.gleam", .gleam), ("Showcase/source/go.go", .go),
            ("Showcase/source/gradle.gradle", .groovy), ("Showcase/source/groovy.groovy", .groovy),
            ("Showcase/source/haskell.hs", .haskell), ("Showcase/source/analysis.m", .matlab),
            ("Showcase/source/hello.ml", .ocaml), ("Showcase/source/hello.tcl", .tcl),
            ("Showcase/source/hello.applescript", .appleScript), ("Showcase/source/Greeter.m", .objectiveC),
            ("Showcase/source/nginx.conf", .nginx), ("Showcase/source/httpd.conf", .apache),
            ("Showcase/source/nim.nim", .nim), ("Showcase/source/model.scad", .openSCAD),
            ("Showcase/source/add.wat", .webAssemblyText),
            ("Showcase/source/pascal.pas", .pascal), ("Showcase/source/counter.vh", .verilog),
            ("Showcase/source/counter.vhd", .vhdl),
            ("Showcase/source/hello.cob", .cobol), ("Showcase/source/board.dts", .deviceTree),
            ("Showcase/source/sv.po", .gettext), ("Showcase/source/page.html.erb", .erb),
            ("Showcase/source/Component.qml", .qml), ("Showcase/source/Counter.sol", .solidity),
            ("Showcase/fileformats/notes.org", .org)
        ]

        for (path, expected) in cases {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 65_536)
            XCTAssertFalse(analysis.isBinary, path)
            XCTAssertEqual(SourceDetector.detect(fileName: URL(fileURLWithPath: path).lastPathComponent, analysis: analysis).language, expected, path)
        }
    }

    func testExactNamesUseCatalogSourceLanguagesAndShellRouting() {
        let makefile = detect("Makefile", uti: "public.python-script", source: "#!/bin/bash\n")
        XCTAssertEqual(makefile.language, .makefile)
        XCTAssertEqual(makefile.reason, .exactFilename)
        let jenkinsfile = detect("Jenkinsfile", uti: "public.python-script", source: "#!/bin/bash\n")
        XCTAssertEqual(jenkinsfile.language, .groovy)
        XCTAssertEqual(jenkinsfile.reason, .exactFilename)
        XCTAssertEqual(detect(".vimrc").language, .vimscript)
        XCTAssertEqual(detect(".vimrc").reason, .exactFilename)
        XCTAssertEqual(detect("gvimrc").language, .vimscript)
        XCTAssertEqual(detect("Dockerfile", uti: "public.python-script").language, .dockerfile)
        XCTAssertEqual(detect("Dockerfile", uti: "public.python-script").reason, .exactFilename)
        XCTAssertEqual(detect(".bashrc", uti: "public.python-script").language, .shell)
        XCTAssertEqual(detect(".zshrc").reason, .exactFilename)
        XCTAssertEqual(detect("notMakefile").reason, .plainText)
        XCTAssertEqual(detect("Dockerfile.swift").language, .swift)
        XCTAssertEqual(detect("CMakeLists.txt").language, .cmake)
        XCTAssertNil(detect("sample.bezel").language)
        XCTAssertNil(detect("profile.mobileconfig").language)
        XCTAssertNil(detect("settings.conf").language)
    }

    func testUsableUTIsAndGenericFallback() {
        for (uti, expected): (String, SourceLanguage) in [
            ("public.swift-source", .swift), ("com.sun.java-source", .java),
            ("public.c-source", .c), ("public.c-header", .c),
            ("public.c-plus-plus-source", .cpp), ("public.c-plus-plus-header", .cpp),
            ("public.python-script", .python), ("com.netscape.javascript-source", .javascript),
            ("com.microsoft.typescript", .typescript), ("public.shell-script", .shell),
            ("public.toml", .toml), ("com.microsoft.ini", .ini),
            ("com.glimt.app.java-properties", .properties)
        ] {
            XCTAssertEqual(detect("unknown", uti: uti).language, expected, uti)
            XCTAssertEqual(detect("unknown", uti: uti).reason, .systemUTI)
        }
        for uti in ["public.source-code", "public.text", "dyn.unknown", "public.mpeg-2-transport-stream"] {
            XCTAssertEqual(detect("unknown", uti: uti).reason, .plainText)
        }
        for format in FormatCatalog.supported where format.sourceLanguage != nil {
            for identifier in format.contentTypeIdentifiers {
                XCTAssertEqual(detect("unknown", uti: identifier).language, format.sourceLanguage, identifier)
            }
        }
    }

    func testShebangsNormalizeEnvWithoutExecutingOrParsingShell() {
        for line in ["#!/bin/sh", "#!/bin/bash", "#!/usr/bin/env bash", "#!/bin/zsh", "#!/usr/bin/env zsh", "#!/usr/bin/env -S bash -e"] {
            for ending in ["\n", "\r", "\r\n", ""] {
                let result = detect("script", source: line + ending)
                XCTAssertEqual(result.language, .shell, line)
                XCTAssertEqual(result.reason, .shebang)
            }
        }
        for line in ["#!/usr/bin/python3", "#!/usr/bin/env python3", "#!/usr/bin/python3.12 -u"] {
            XCTAssertEqual(detect("script", source: line + "\n").language, .python)
        }
        for source in ["\n#!/bin/bash\n", " #!/bin/bash\n", "#!/usr/bin/env\n", "#!/usr/bin/env -S\n", "#!/usr/bin/env 'bash'\n", "#!/usr/bin/env $(bash)\n", "#!/usr/bin/env python-malware\n"] {
            XCTAssertNil(detect("script", source: source).language, source)
        }
    }

    func testPriorityAndTypeScriptTransportConflict() {
        XCTAssertEqual(detect("file.py", uti: "public.shell-script", source: "#!/bin/bash\n").language, .python)
        XCTAssertEqual(detect("script", uti: "public.python-script", source: "#!/bin/bash\n").language, .python)
        let result = detect("example.ts", uti: "public.mpeg-2-transport-stream", source: "interface Item { count: number }\n")
        XCTAssertEqual(result.language, .typescript)
        XCTAssertEqual(result.reason, .fileExtension)
        XCTAssertNil(detect("example.json").language)
        XCTAssertNil(detect("example.yaml").language)
    }

    func testFSharpExtensionOutranksTheSystemGLSLFragmentType() {
        let result = detect("Main.fs", uti: "org.khronos.glsl.fragment-shader", source: "let answer = 42\n")
        XCTAssertEqual(result.language, .fsharp)
        XCTAssertEqual(result.reason, .fileExtension)
    }

    func testElixirAndEiffelSharedSuffixUsesConservativeSyntaxEvidence() {
        XCTAssertEqual(detect("module.ex", source: "defmodule Demo do\n  def run, do: 42\nend\n").language, .elixir)
        XCTAssertEqual(detect("module.exs", source: "class DEMO feature run do print (42) end end\n").language, .eiffel)
        XCTAssertEqual(detect("module.ex", source: "class DEMO feature run do print (42) end end\n").language, .eiffel)
        XCTAssertEqual(detect("module.exs", source: "defmodule Demo do\n  def run, do: 42\nend\n").language, .elixir)
        XCTAssertEqual(detect("module.exs", source: "# not Eiffel syntax\n").language, .elixir)
    }

    func testUnknownAndBinaryAlwaysFallBack() {
        XCTAssertEqual(detect("notes", source: "Readable words\n").reason, .plainText)
        XCTAssertNil(detect("notes", source: "Readable words\n").language)
        let analysis = TextAnalysis.analyze(bytes: Data([0x47, 0, 1, 2]), fileSize: 4, maximumBytes: 4)
        for name in ["video.ts", "file.swift", "Makefile"] {
            let result = SourceDetector.detect(fileName: name, systemUTI: "public.swift-source", analysis: analysis)
            XCTAssertNil(result.language)
            XCTAssertEqual(result.reason, .binary)
        }
    }

    func testShebangReadsOnlyBoundedCompleteFirstLine() {
        XCTAssertNil(detect("script", source: "#!/bin/bash", complete: false).language)
        XCTAssertEqual(detect("script", source: "#!/bin/bash\n", complete: false).language, .shell)
        XCTAssertNil(detect("script", source: "#!" + String(repeating: " ", count: 65_536) + "/bin/bash\n").language)
        XCTAssertNil(detect("script", source: String(repeating: "a", count: 65_536) + "\n#!/bin/bash\n").language)
        let source = "#!/usr/bin/env python3\r\nprint(42)\r\n"
        let bytes = Data([0xFF, 0xFE]) + (source.data(using: .utf16LittleEndian) ?? Data())
        let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 65_536)
        XCTAssertEqual(SourceDetector.detect(fileName: "script", analysis: analysis).language, .python)
    }

    func testRepresentativeCorpus() throws {
        let cases: [(String, SourceLanguage)] = [("Cases/source/Example.swift", .swift), ("Showcase/source/java.java", .java), ("Showcase/source/c.c", .c), ("Showcase/source/cpp.cpp", .cpp), ("Showcase/source/python.py", .python), ("Showcase/source/javascript.js", .javascript), ("Showcase/source/typescript.ts", .typescript), ("Showcase/source/shell.sh", .shell), ("Showcase/source/d.d", .d), ("Showcase/source/install.bat", .batch), ("Showcase/source/example.dylan", .dylan), ("Showcase/source/example.e", .eiffel), ("Showcase/source/elixir.ex", .elixir), ("Showcase/source/erlang.erl", .erlang)]
        for (name, language) in cases {
            let bytes = try Data(contentsOf: fixtureURL(name))
            let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 65_536)
            XCTAssertFalse(analysis.isBinary)
            XCTAssertTrue(analysis.text.contains("42"))
            XCTAssertEqual(SourceDetector.detect(fileName: URL(fileURLWithPath: name).lastPathComponent, analysis: analysis).language, language)
        }
        for name in ["Cases/ambiguous/Makefile", "Cases/ambiguous/Dockerfile", "Cases/ambiguous/Jenkinsfile", "Cases/text/unknown.txt", "Cases/binary/binary.ts", "Cases/ambiguous/extensionless-python", "Cases/ambiguous/shell-script"] {
            let bytes = try Data(contentsOf: fixtureURL(name))
            let analysis = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 65_536)
            let result = SourceDetector.detect(fileName: URL(fileURLWithPath: name).lastPathComponent, analysis: analysis)
            if name == "Cases/binary/binary.ts" { XCTAssertEqual(result.reason, .binary) }
            else if name == "Cases/ambiguous/Makefile" { XCTAssertEqual(result.language, .makefile) }
            else if name == "Cases/ambiguous/Jenkinsfile" { XCTAssertEqual(result.language, .groovy) }
            else if name == "Cases/ambiguous/Dockerfile" { XCTAssertEqual(result.language, .dockerfile) }
            else if name == "Cases/ambiguous/extensionless-python" { XCTAssertEqual(result.language, .python) }
            else if name == "Cases/ambiguous/shell-script" { XCTAssertEqual(result.language, .shell) }
            else if name == "Cases/ambiguous/Makefile" { XCTAssertEqual(result.language, .makefile) }
            else if name == "Cases/ambiguous/Jenkinsfile" { XCTAssertEqual(result.language, .groovy) }
            else { XCTAssertNil(result.language) }
        }
    }
}
