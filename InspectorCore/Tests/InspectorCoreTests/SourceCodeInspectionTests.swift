import Foundation
import XCTest
@testable import InspectorCore

final class SourceCodeInspectionTests: XCTestCase {
    private func analysis(_ source: String, extraBytes: Int = 0) -> TextAnalysis {
        let bytes = Data(source.utf8)
        return TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count + extraBytes, maximumBytes: 1_048_576)
    }

    private struct FailingHighlighter: SyntaxHighlighting {
        struct Failure: Error {}
        func highlight(_ source: String, language: SourceLanguage) throws -> HighlightedSource { throw Failure() }
    }

    private struct InjectedHighlighter: SyntaxHighlighting {
        let runs: [HighlightRun]
        func highlight(_ source: String, language: SourceLanguage) throws -> HighlightedSource { .init(runs: runs) }
    }

    private struct CancelledHighlighter: SyntaxHighlighting {
        func highlight(_ source: String, language: SourceLanguage) throws -> HighlightedSource { throw CancellationError() }
    }

    func testNineteenLanguagesProduceShieldedTokensFromCorpus() throws {
        let fixtures: [(String, SourceLanguage)] = [
            ("Cases/source/Example.swift", .swift), ("Showcase/source/java.java", .java),
            ("Showcase/source/c.c", .c), ("Showcase/source/cpp.cpp", .cpp),
            ("Showcase/source/python.py", .python), ("Showcase/source/javascript.js", .javascript),
            ("Showcase/source/typescript.ts", .typescript), ("Showcase/source/shell.sh", .shell),
            ("Showcase/legacy-formats/ada-example.ada", .ada),
            ("Showcase/legacy-formats/actionscript-example.as", .actionscript),
            ("Showcase/legacy-formats/assembly-example.asm", .assembly),
            ("Showcase/legacy-formats/gawk-script.awk", .awk),
            ("Showcase/legacy-formats/component.jsx", .jsx),
            ("Cases/legacy-formats/component.astro", .jsx),
            ("Showcase/source/d.d", .d), ("Showcase/source/install.bat", .batch),
            ("Showcase/policy/allow.rego", .rego), ("Showcase/directory/people.ldif", .ldif),
            ("Showcase/data/catalog.ttl", .turtle),
            ("Showcase/source/example.dylan", .dylan), ("Showcase/source/example.e", .eiffel),
            ("Showcase/source/elixir.ex", .elixir), ("Showcase/source/erlang.erl", .erlang)
        ]
        for (name, language) in fixtures {
            let bytes = try Data(contentsOf: fixtureURL(name))
            let input = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, name)
            XCTAssertEqual(document.language, language)
            XCTAssertEqual(document.encoding, .utf8)
            XCTAssertTrue(document.diagnostics.isEmpty, name)
            let kinds = Set(document.highlighting.runs.map(\.kind))
            XCTAssertTrue(kinds.contains(.comment), name)
            XCTAssertTrue(kinds.contains(.string), name)
            XCTAssertTrue(kinds.contains(.keyword), name)
            XCTAssertTrue(kinds.contains(.number), name)
        }
    }

    func testNewLanguageLexersRecognizeCommentsKeywordsStringsAndNumbers() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.ada, "-- note\nprocedure Main is\n  Message : String := \"hi\";\n  Count : Integer := 42;\nbegin null; end Main;\n", "procedure"),
            (.actionscript, "// note\npublic class Example { var label:String = \"hi\"; return 42; }\n", "public"),
            (.assembly, "; note\n.section .text\nmov $42, %rax\n.ascii \"hi\"\n", "mov"),
            (.awk, "# note\nBEGIN { print \"hi\", 42 }\n", "BEGIN"),
            (.jsx, "// note\nexport function View() { const value = 42; return <div title=\"hi\">{value}</div>; }\n", "export"),
            (.dockerfile, "# syntax=docker/dockerfile:1\nFROM alpine:3.20 AS base\nRUN echo \"hi\" 42\n", "FROM"),
            (.rego, "# policy source only\npackage demo\ndefault allow := false\nallow if { input.age >= 42; input.name == \"Ada\" }\n", "package"),
            (.ldif, "# directory data only\ndn: cn=Ada,dc=example\nchangetype: add\nuidNumber: 42\ncn: \"Ada\"\n", "changetype"),
            (.turtle, "# RDF source only\n@prefix ex: <https://example.invalid/#people> .\nex:alice a ex:Person ; ex:age 42 ; ex:name \"Ada\" .\n", "prefix")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
        }
    }

    func testIgnorePatternLexerMarksCommentsNegationsAndPatternsWithoutChangingText() throws {
        let source = "# comment\n/build/\n!dist/release.json\n\\#literal\n"
        let document = try SourceCodeInspector.inspect(analysis: analysis(source), language: .gitignore)
        XCTAssertEqual(document.source, source)
        let tokens = document.highlighting.runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(tokens.contains { $0.0 == "# comment" && $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.0 == "!" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "dist/release.json" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.0 == "\\#literal" && $0.1 == .directive })
    }

    func testGitAttributesLexerHighlightsCommentsPatternsAndAttributes() throws {
        let language = try XCTUnwrap(SourceLanguage(rawValue: "git-attributes"))
        let source = "# comment\n*.pdf diff=pdf -text\n\\#literal -diff\n"
        let document = try SourceCodeInspector.inspect(analysis: analysis(source), language: language)
        XCTAssertEqual(document.source, source)
        let tokens = document.highlighting.runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(tokens.contains { $0.0 == "# comment" && $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.0 == "*.pdf" && $0.1 == .type })
        XCTAssertTrue(tokens.contains { $0.0 == "diff=pdf" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.0 == "-text" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.0 == "\\#literal" && $0.1 == .type })
    }

    func testGoModuleLexerHighlightsDirectivesVersionsAndCommentsWithoutChangingText() throws {
        let language = try XCTUnwrap(SourceLanguage(rawValue: "go-module"))
        let source = "module example.com/acme/app\n\ngo 1.23.0\nrequire (\n  example.com/lib v1.2.3 // indirect\n)\nreplace example.com/old => ../old\n"
        let document = try SourceCodeInspector.inspect(analysis: analysis(source), language: language)
        XCTAssertEqual(document.source, source)
        let tokens = document.highlighting.runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(tokens.contains { $0.0 == "module" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "example.com/acme/app" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.0 == "require" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "v1.2.3" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.0 == "// indirect" && $0.1 == .comment })
        XCTAssertTrue(tokens.contains { $0.0 == "=>" && $0.1 == .directive })
    }

    func testCOBOLDTSAndGettextLexersRecognizeTheirTokens() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.cobol, "      * fixed-form comment\n       IDENTIFICATION DIVISION.\n       PROGRAM-ID. GREETER.\n       DISPLAY 'hello'\n       MOVE 42 TO COUNT.\n*> free-form comment\n", "DIVISION"),
            (.deviceTree, "// device tree comment\n/dts-v1/;\n/ {\n  compatible = \"vendor,board\";\n  memory@0 { reg = <0x0 42>; };\n};\n", "compatible"),
            (.gettext, "# translator comment\nmsgid \"Open file 42\"\nmsgstr[0] \"Öppna fil 42\"\n", "msgid")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0.lowercased() == keyword.lowercased() && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
        }
    }

    func testERBQMLAndSolidityLexersRecognizeTheirSyntax() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.erb, "<h1><%= if ready? then \"Glimt\" else count + 42 end %></h1>\n<p><%= \"%> inside\" %></p>\n<%# note %>\n", "if"),
            (.qml, "// note\nimport QtQuick\nItem { property int count: 42; Text { text: \"hi\" } }\n", "property"),
            (.solidity, "// note\ncontract Counter { string public label = \"count\"; uint256 public count = 42; function increment() public { count++; } }\n", "contract")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
            if language == .erb {
                XCTAssertTrue(tokens.contains { $0.0 == "h1" && $0.1 == .type })
                XCTAssertTrue(tokens.contains { $0.0 == "\"%> inside\"" && $0.1 == .string })
            }
            if language == .qml {
                XCTAssertTrue(tokens.contains { $0.0 == "int" && $0.1 == .type })
            }
            if language == .solidity {
                XCTAssertTrue(tokens.contains { $0.0 == "uint256" && $0.1 == .type })
            }
        }
    }

    func testAutoHotkeyInnoSetupAndNSISLexersRecognizeTheirTokens() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.autoHotkey, "; open the editor\n#Requires AutoHotkey v2.0\nMsgBox(\"Ready\")\ncount := 42\n", "MsgBox"),
            (.innoSetup, "; installer metadata\n[Setup]\nAppName='Glimt'\nAppVersion=42\n", "AppName"),
            (.nsis, "; installer metadata\nName \"Glimt\"\nOutFile \"setup.exe\"\nSection \"Main\"\nSetOutPath \"$INSTDIR\"\nIntCmp $0 42 done\nSectionEnd\n", "Section")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0.caseInsensitiveCompare(keyword) == .orderedSame && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
            if language == .nsis { XCTAssertTrue(tokens.contains { $0.0 == "$0" && $0.1 == .variable }) }
        }
    }

    func testClassicASPJinjaTwigAndASPNETLexersPreserveMarkupAndColorTemplateBlocks() throws {
        let cases: [(SourceLanguage, String, String, String)] = [
            (.asp, "<h1><%= title %></h1>\n<% If ready Then Response.Write \"yes\" End If %>\n<%-- note --%>\n", "If", "h1"),
            (.aspx, "<asp:Label runat=\"server\" Text=\"<%# Model.Name %>\" /><% if (ready) { Response.Write(\"yes\"); } %>\n<%-- note --%>\n", "if", "asp"),
            (.jinja, "<h1>{{ user.name }}</h1>\n{% if \"ready\" %}{{ value + 42 }}{% endif %}\n{# note #}\n", "if", "h1"),
            (.twig, "<h1>{{ user.name }}</h1>\n{% if \"ready\" %}{{ value + 42 }}{% endif %}\n{# note #}\n", "if", "h1")
        ]
        for (language, source, keyword, markup) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.0 == markup && $0.1 == .type }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
        }
    }

    func testOrgModeLexerRecognizesHeadingsTodosDirectivesAndComments() throws {
        let source = "#+TITLE: Work plan\n* TODO Prepare release :release:\n  # comment\n#+BEGIN_SRC swift\nlet value = 42\n#+END_SRC\n"
        let runs = try InternalSyntaxHighlighter().highlight(source, language: .org).runs
        let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(tokens.contains { $0.0 == "#+TITLE" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.0 == "*" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "TODO" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "#+BEGIN_SRC" && $0.1 == .directive })
        XCTAssertTrue(tokens.contains { $0.1 == .comment })
    }

    func testNimOpenSCADAndWebAssemblyTextLexersRecognizeTheirSyntax() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.nim, "# note\n#[ outer #[ nested ]# comment ]#\nproc greet(name: string): string =\n  let answer = 42\n" + "  let details = \"\"\"first line\nsecond line\"\"\"\n  result = \"hi\"\n", "proc"),
            (.openSCAD, "// note\n/* block note */\nmodule part(size = 42) {\n  cube([size, size, size]);\n}\nlabel = \"hi\";\n", "module"),
            (.webAssemblyText, ";; note\n(; outer (; nested ;) comment ;)\n(module\n  (func $answer (result i32)\n    i32.const 42)\n  (export \"answer\" (func $answer))\n)\n", "module")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
            if language == .nim {
                XCTAssertTrue(tokens.contains { $0.0 == "\"\"\"first line\nsecond line\"\"\"" && $0.1 == .string })
            }
            if language == .webAssemblyText {
                XCTAssertTrue(tokens.contains { $0.0 == "$answer" && $0.1 == .variable })
                XCTAssertTrue(tokens.contains { $0.0 == "i32.const" && $0.1 == .keyword })
                XCTAssertTrue(tokens.contains { $0.0 == "i32" && $0.1 == .type })
            }
        }
    }

    func testPascalVerilogAndVHDLLexersRecognizeTheirSyntax() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.pascal, "{ comment }\nprogram Hello;\nvar Count: Integer;\nbegin\n  Count := 42;\n  WriteLn('it''s ready');\nend.\n", "program"),
            (.verilog, "/* comment */\nmodule counter(input logic clk, output logic [3:0] count);\n  localparam string LABEL = \"ready\";\n  always_ff @(posedge clk) begin\n    if (count == 4) count <= 0;\n  end\nendmodule\n", "module"),
            (.vhdl, "-- comment\nlibrary ieee;\nentity counter is\n  port (clk : in std_logic; count : out integer);\nend entity;\narchitecture rtl of counter is\n  constant label_text : string := \"ready\";\nbegin\n  process(clk) begin\n    if rising_edge(clk) then count <= 42; end if;\n  end process;\nend architecture;\n", "entity")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .type }, language.rawValue)
            if language == .pascal {
                XCTAssertTrue(tokens.contains { $0.0 == "'it''s ready'" && $0.1 == .string })
            }
        }
    }

    func testNimOpenSCADAndWebAssemblyTextShowcasesAreBoundedSource() throws {
        let fixtures: [(String, SourceLanguage)] = [
            ("Showcase/source/nim.nim", .nim),
            ("Showcase/source/model.scad", .openSCAD),
            ("Showcase/source/add.wat", .webAssemblyText)
        ]
        for (path, language) in fixtures {
            let url = try fixtureURL(path)
            let result = try PreviewInspectionResult.read(at: url)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(result.formatDefinition?.sourceLanguage, language, path)
            XCTAssertEqual(result.sourceDocument?.source, String(decoding: bytes, as: UTF8.self), path)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, path)
            XCTAssertEqual(result.originalBytes, bytes, path)
        }
    }

    func testMatlabOCamlTclAppleScriptNginxAndApacheLexersRecognizeNativeTokens() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.matlab, "% note\nfunction y = f(x)\ny = x + 42;\nlabel = \"hello\";\nend\n", "function"),
            (.ocaml, "(* note (* nested *) *)\nlet answer = 42\nlet label = \"hi\"\n", "let"),
            (.tcl, "# note\nproc greet {name} {\n  puts \"hi\"\n}\nset answer 42\n", "proc"),
            (.appleScript, "-- note\non greetUser(name)\n  set message to \"hi\"\n  return 42\nend greetUser\n", "on"),
            (.nginx, "# note\nserver {\n  listen 443;\n  server_name \"example.test\";\n  location / { proxy_pass http://app; }\n}\n", "server"),
            (.apache, "# note\n<VirtualHost *:443>\n  ServerName \"example.test\"\n  DocumentRoot /srv/www\n</VirtualHost>\n", "VirtualHost")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
        }
    }

    func testNextPrioritizedLanguageLexersRecognizeTheirSyntax() throws {
        let cases: [(SourceLanguage, String, String, String)] = [
            (.objectiveC, "#import <Foundation/Foundation.h>\n// note\n@interface Greeter : NSObject\n- (void)greet { int count = 42; NSLog(@\"hi\"); }\n@end\n", "interface", "NSObject"),
            (.perl, "#!/usr/bin/perl\n# note\nmy $name = \"Glimt\";\nprint $name, 42;\n", "my", "my"),
            (.r, "# note\nvalues <- c(3, 1, 4)\nsummary <- function(x) mean(x)\nprint(\"ok\")\n", "function", "function"),
            (.scala, "// note\nobject Main { val label = \"Glimt\"; val answer = 42 }\n", "object", "Main"),
            (.julia, "# note\nfunction greet(name)\n  message = \"Glimt\"\n  return 42\nend\n", "function", "end")
        ]

        for (language, source, keyword, marker) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.0 == marker && [.keyword, .type].contains($0.1) }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue)
            if language == .perl { XCTAssertTrue(tokens.contains { $0.0 == "$name" && $0.1 == .variable }) }
        }

        let rSource = "values %in% c(1, 2)\n"
        let rTokens = try InternalSyntaxHighlighter().highlight(rSource, language: .r).runs
        XCTAssertFalse(rTokens.contains { $0.kind == .variable && (rSource as NSString).substring(with: $0.range) == "%in" })
    }

    func testFivePrioritizedLanguageShowcasesRouteAndPreserveMalformedAndTruncatedText() throws {
        let cases: [(String, String, String, SourceLanguage)] = [
            ("Showcase/source/Greeter.m", "Greeter.m", "objective-c", .objectiveC),
            ("Showcase/source/hello.pl", "hello.pl", "perl", .perl),
            ("Showcase/source/analysis.R", "analysis.R", "r", .r),
            ("Showcase/source/Main.scala", "Main.scala", "scala", .scala),
            ("Showcase/source/analysis.jl", "analysis.jl", "julia", .julia)
        ]
        let malformedPaths = [
            "Cases/fileformats/objective-c/malformed.m", "Cases/fileformats/perl/malformed.pl",
            "Cases/fileformats/r/malformed.R", "Cases/fileformats/scala/malformed.scala",
            "Cases/fileformats/julia/malformed.jl"
        ]
        let truncatedPaths = [
            "Cases/fileformats/objective-c/truncated.m", "Cases/fileformats/perl/truncated.pl",
            "Cases/fileformats/r/truncated.R", "Cases/fileformats/scala/truncated.scala",
            "Cases/fileformats/julia/truncated.jl"
        ]

        for ((showcase, filename, id, language), (malformedPath, truncatedPath)) in zip(cases, zip(malformedPaths, truncatedPaths)) {
            let showcaseURL = try fixtureURL(showcase)
            let bytes = try Data(contentsOf: showcaseURL)
            let result = try PreviewInspectionResult.read(at: showcaseURL)
            if filename != "Greeter.m" { XCTAssertEqual(FormatCatalog.match(fileName: filename)?.id.rawValue, id, filename) }
            XCTAssertEqual(result.formatDefinition?.id.rawValue, id, filename)
            XCTAssertEqual(result.sourceDocument?.language, language, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
            XCTAssertFalse(result.sourceDocument?.highlighting.runs.isEmpty ?? true, filename)

            let malformedURL = try fixtureURL(malformedPath)
            let malformedBytes = try Data(contentsOf: malformedURL)
            let malformed = PreviewInspectionResult.prepare(
                bytes: malformedBytes, fileSize: malformedBytes.count,
                fileName: malformedURL.lastPathComponent, systemUTI: nil
            )
            XCTAssertEqual(malformed.sourceDocument?.language, language, filename)
            XCTAssertEqual(malformed.originalBytes, malformedBytes, filename)
            XCTAssertEqual(malformed.sourceDocument?.source, String(decoding: malformedBytes, as: UTF8.self), filename)

            let truncatedURL = try fixtureURL(truncatedPath)
            let truncatedBytes = try Data(contentsOf: truncatedURL)
            let truncated = PreviewInspectionResult.prepare(
                bytes: truncatedBytes, fileSize: truncatedBytes.count + 1,
                fileName: truncatedURL.lastPathComponent, systemUTI: nil
            )
            XCTAssertEqual(truncated.sourceDocument?.language, language, filename)
            XCTAssertTrue(truncated.sourceDocument?.truncated == true, filename)
            XCTAssertEqual(truncated.originalBytes, truncatedBytes, filename)
        }

        XCTAssertEqual(FormatCatalog.match(fileName: "Greeter.mm")?.id.rawValue, "objective-c")
        XCTAssertEqual(FormatCatalog.match(fileName: "analysis.r")?.id.rawValue, "r")
    }

    func testS79AssemblerAliasHighlightsItsInstructionDialect() throws {
        let source = String(decoding: try Data(contentsOf: fixtureURL("Showcase/legacy-formats/assembly-legacy.s79")), as: UTF8.self)
        let runs = try InternalSyntaxHighlighter().highlight(source, language: .assembly).runs
        let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(tokens.contains { $0.0 == "LDA" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.0 == "STA" && $0.1 == .keyword })
        XCTAssertTrue(tokens.contains { $0.1 == .number })
    }

    func testRequestedLanguageShowcasesProduceShieldedTokens() throws {
        let fixtures: [(String, SourceLanguage)] = [
            ("Showcase/source/fsharp.fs", .fsharp), ("Showcase/source/fish.fish", .fish),
            ("Showcase/source/fortran.f90", .fortran), ("Showcase/source/gdscript.gd", .gdscript),
            ("Showcase/source/gleam.gleam", .gleam), ("Showcase/source/go.go", .go),
            ("Showcase/source/gradle.gradle", .groovy), ("Showcase/source/groovy.groovy", .groovy),
            ("Showcase/source/haskell.hs", .haskell)
        ]

        for (path, language) in fixtures {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let input = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, path)
            XCTAssertEqual(document.language, language, path)
            let kinds = Set(document.highlighting.runs.map(\.kind))
            XCTAssertTrue(kinds.contains(.comment), path)
            XCTAssertTrue(kinds.contains(.string), path)
            XCTAssertTrue(kinds.contains(.keyword), path)
            XCTAssertTrue(kinds.contains(.number), path)
        }
    }

    func testPrioritizedLanguagesProduceShieldedTokensFromShowcases() throws {
        let fixtures: [(String, SourceLanguage)] = [
            ("Showcase/source/html.html", .html), ("Showcase/source/sql.sql", .sql),
            ("Showcase/source/rust.rs", .rust), ("Showcase/source/php.php", .php),
            ("Showcase/source/ruby.rb", .ruby)
        ]
        for (path, language) in fixtures {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let input = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, path)
            XCTAssertEqual(document.language, language, path)
            XCTAssertFalse(document.highlighting.runs.isEmpty, path)
            XCTAssertEqual(document.diagnostics, [], path)
        }
    }

    func testPrioritizedLanguageLexersRecognizeRepresentativeTokens() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.html, "<!-- note -->\n<main class=\"hero\" data-count=42>Hello</main>", "main"),
            (.sql, "-- note\nSELECT 'ok' FROM users WHERE count = 42;", "SELECT"),
            (.rust, "// note\nfn main() { let text = \"hi\"; let count: i32 = 42; }", "fn"),
            (.php, "<?php // note\nfunction greet() { $count = 42; return 'hi'; }", "function"),
            (.ruby, "# note\ndef greet\n  count = 42\n  puts \"hi\"\nend", "def")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            let expectedKeywordKind: SyntaxTokenKind = language == .html ? .type : .keyword
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == expectedKeywordKind }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, language.rawValue)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.rawValue)
            if language != .html { XCTAssertTrue(tokens.contains { $0.1 == .number }, language.rawValue) }
            if language == .php { XCTAssertTrue(tokens.contains { $0.0 == "$count" && $0.1 == .variable }) }
        }
        let rustLifetime = "fn borrow<'a>(value: &'a str) -> &'a str { value }"
        let rustRuns = try InternalSyntaxHighlighter().highlight(rustLifetime, language: .rust).runs
        XCTAssertFalse(rustRuns.contains { $0.kind == .string })
    }

    func testNixCUEAndKDLLexersRecognizeCommentsKeywordsStringsAndNumbers() throws {
        let cases: [(String, String, String)] = [
            ("nix", "# line note\n/* block note */ let answer = 42; message = ''hello''; in \"hello\"", "let"),
            ("cue", "// line note\n/* block note */ package preview\nanswer: int & >=42\nlabel: \"hello\"", "package"),
            ("kdl", "// line note\nservice { enabled true replicas 42 name \"hello\" }", "true")
        ]

        for (languageName, source, keyword) in cases {
            guard let language = SourceLanguage(rawValue: languageName) else {
                XCTFail("Missing source language \(languageName)")
                continue
            }
            let tokens = try InternalSyntaxHighlighter().highlight(source, language: language).runs.map {
                ((source as NSString).substring(with: $0.range), $0.kind)
            }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, languageName)
            XCTAssertTrue(tokens.contains { $0.1 == .comment }, languageName)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, languageName)
            XCTAssertTrue(tokens.contains { $0.1 == .number }, languageName)
            if languageName == "nix" {
                XCTAssertTrue(tokens.contains { $0.0 == "''hello''" && $0.1 == .string })
            }
        }
    }

    func testCommonWebConfigurationAndMarkupFormatsUseCataloguedSourceInspection() throws {
        let fixtures: [(String, String, String, String, SyntaxTokenKind)] = [
            ("Showcase/source/terraform.tf", "terraform.tf", "terraform", "resource", .keyword),
            ("Showcase/source/styles.scss", "styles.scss", "scss", "$accent", .variable),
            ("Showcase/source/Greeting.tsx", "Greeting.tsx", "tsx", "function", .keyword),
            ("Showcase/source/App.vue", "App.vue", "vue", "main", .type),
            ("Showcase/source/Counter.svelte", "Counter.svelte", "svelte", "button", .type),
            ("Showcase/fileformats/guide.adoc", "guide.adoc", "asciidoc", "= Glimt Format Preview", .keyword),
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
            XCTAssertFalse(document.highlighting.runs.isEmpty, filename)
            XCTAssertTrue(document.source.contains(marker), filename)
            let tokens = document.highlighting.runs.map {
                ((document.source as NSString).substring(with: $0.range), $0.kind)
            }
            XCTAssertTrue(tokens.contains { $0.0 == marker && $0.1 == tokenKind }, filename)
            XCTAssertEqual(result.originalBytes, bytes, filename)
        }
    }

    func testRequestedMalformedAndAlternateExtensionCasesKeepOriginalText() throws {
        let fixtures: [(String, SourceLanguage)] = [
            ("Cases/fileformats/fsharp-edge.fsx", .fsharp), ("Cases/fileformats/fish-edge.fish", .fish),
            ("Cases/fileformats/fsharp-alias.fsx", .fsharp),
            ("Cases/fileformats/fortran-fixed-edge.f", .fortran), ("Cases/fileformats/fortran-for-edge.for", .fortran),
            ("Cases/fileformats/fortran-free-edge.f95", .fortran), ("Cases/fileformats/gdscript-edge.gd", .gdscript),
            ("Cases/fileformats/fortran-fixed-valid.f", .fortran), ("Cases/fileformats/fortran-valid.for", .fortran),
            ("Cases/fileformats/fortran-valid.f95", .fortran),
            ("Cases/fileformats/gleam-edge.gleam", .gleam), ("Cases/fileformats/go-edge.go", .go),
            ("Cases/fileformats/gradle-edge.gradle", .groovy), ("Cases/fileformats/groovy-edge.groovy", .groovy),
            ("Cases/fileformats/haskell-edge.lhs", .haskell), ("Cases/fileformats/haskell-literate-valid.lhs", .haskell)
        ]

        for (path, language) in fixtures {
            let bytes = try Data(contentsOf: fixtureURL(path))
            let input = TextAnalysis.analyze(bytes: bytes, fileSize: bytes.count, maximumBytes: 1_048_576)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, path)
            XCTAssertEqual(document.language, language, path)
        }
    }

    func testLiterateHaskellHighlightsCodeTracksButLeavesProsePlain() throws {
        let birdTrack = "Prose says module, let, and 42 are ordinary words.\n> module Example where\n> answer = 42\n"
        let birdInput = analysis(birdTrack)
        let bird = try SourceCodeInspector.inspect(analysis: birdInput, language: .haskell, literateHaskell: true)
        XCTAssertEqual(bird.source, birdTrack)
        XCTAssertTrue(bird.highlighting.runs.allSatisfy { $0.range.location >= (birdTrack as NSString).lineRange(for: NSRange(location: 0, length: 0)).length })
        XCTAssertTrue(bird.highlighting.runs.contains { $0.kind == .keyword && (birdTrack as NSString).substring(with: $0.range) == "module" })

        let latex = "Prose where let and 42 are not code.\n\\begin{code}\nmodule Example where\nanswer = 42\n\\end{code}\nMore prose.\n"
        let latexInput = analysis(latex)
        let document = try SourceCodeInspector.inspect(analysis: latexInput, language: .haskell, literateHaskell: true)
        XCTAssertEqual(document.source, latex)
        let tokens = document.highlighting.runs.map { (latex as NSString).substring(with: $0.range) }
        XCTAssertFalse(tokens.contains("let"))
        XCTAssertTrue(tokens.contains("module"))
    }

    func testLiterateHaskellBlankProseLineDoesNotStallTheScanner() throws {
        let source = "Prose.\n\n> answer = 42\n"
        let document = try SourceCodeInspector.inspect(analysis: analysis(source), language: .haskell, literateHaskell: true)
        XCTAssertEqual(document.source, source)
        XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .number })
    }

    func testRequestedLanguageShowcasesAndEdgeCasesAreHighlighted() throws {
        let fixtures: [(String, SourceLanguage)] = [
            ("Showcase/source/clojure.clj", .clojure), ("Showcase/source/csh.csh", .csh),
            ("Showcase/source/csharp.cs", .csharp), ("Showcase/source/cmake.cmake", .cmake),
            ("Showcase/source/podspec.podspec", .ruby), ("Showcase/source/coffeescript.coffee", .coffeescript),
            ("Showcase/source/coldfusion.cfm", .coldfusion), ("Showcase/source/crystal.cr", .crystal),
            ("Showcase/source/cson.cson", .cson), ("Showcase/source/css.css", .css),
            ("Showcase/source/bibtex.bib", .bibtex)
        ]
        for (path, language) in fixtures {
            let data = try Data(contentsOf: fixtureURL(path))
            let input = TextAnalysis.analyze(bytes: data, fileSize: data.count, maximumBytes: 65_536)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, path)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .keyword }, path)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .comment }, path)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .string }, path)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .number }, path)
            XCTAssertTrue(document.diagnostics.isEmpty, path)
        }

        let edges: [(String, SourceLanguage)] = [
            ("Cases/source/edges/clojure.txt", .clojure), ("Cases/source/edges/csh.txt", .csh),
            ("Cases/source/edges/csharp.txt", .csharp), ("Cases/source/edges/cmake.txt", .cmake),
            ("Cases/source/edges/ruby.txt", .ruby), ("Cases/source/edges/coffeescript.txt", .coffeescript),
            ("Cases/source/edges/coldfusion.txt", .coldfusion), ("Cases/source/edges/crystal.txt", .crystal),
            ("Cases/source/edges/cson.txt", .cson), ("Cases/source/edges/css.txt", .css),
            ("Cases/source/edges/bibtex.txt", .bibtex)
        ]
        for (path, language) in edges {
            let data = try Data(contentsOf: fixtureURL(path))
            let input = TextAnalysis.analyze(bytes: data, fileSize: data.count, maximumBytes: 65_536)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, path)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .comment }, path)
            XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .string }, path)
            if language == .c {
                XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .directive }, path)
            } else {
                XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .keyword }, path)
            }
            let nsSource = document.source as NSString
            for phrase in ["if 42", "if 99"] {
                let protectedRange = nsSource.range(of: phrase)
                XCTAssertNotEqual(protectedRange.location, NSNotFound, path)
                XCTAssertTrue(document.highlighting.runs.contains { run in
                    [.comment, .string].contains(run.kind) && NSLocationInRange(protectedRange.location, run.range)
                        && NSMaxRange(run.range) >= NSMaxRange(protectedRange)
                }, "Expected \(phrase) to remain inside a comment or string in \(path)")
                XCTAssertFalse(document.highlighting.runs.contains { run in
                    [.keyword, .number].contains(run.kind) && NSIntersectionRange(run.range, protectedRange).length > 0
                }, "Comment and string contents must not leak tokens in \(path)")
            }
        }

        let clojureData = try Data(contentsOf: fixtureURL("Cases/source/edges/clojure.txt"))
        let clojureText = String(decoding: clojureData, as: UTF8.self)
        let clojureRuns = try InternalSyntaxHighlighter().highlight(clojureText, language: .clojure).runs
        XCTAssertTrue(clojureRuns.contains { $0.kind == .keyword && (clojureText as NSString).substring(with: $0.range) == ":answer" })

        for (path, language) in [("Cases/source/edges/header.h", SourceLanguage.c), ("Cases/source/edges/cuda.cu", .cpp)] {
            let data = try Data(contentsOf: fixtureURL(path))
            let input = TextAnalysis.analyze(bytes: data, fileSize: data.count, maximumBytes: 65_536)
            let detected = SourceDetector.detect(fileName: URL(fileURLWithPath: path).lastPathComponent, analysis: input)
            XCTAssertEqual(detected.language, language, path)
            let document = try SourceCodeInspector.inspect(analysis: input, language: language)
            XCTAssertEqual(document.source, input.text, path)
            if language == .c {
                XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .directive }, path)
            } else {
                XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .keyword }, path)
            }
            if language == .cpp {
                XCTAssertTrue(document.highlighting.runs.contains { $0.kind == .string }, path)
                let token = document.highlighting.runs.first { (document.source as NSString).substring(with: $0.range) == "__global__" }
                XCTAssertEqual(token?.kind, .keyword)
            }
        }
    }

    func testCommentsStringsEscapesAndMultilineShieldKeywords() throws {
        let source = "let text = \"if 42 \\\" else\" // return 10\n/* class 20 /* nested */ end */\nlet block = \"\"\"\nreturn 30\n\"\"\"\nlet raw = #\"if 40 \\\" raw\"#\n"
        let highlighted = try InternalSyntaxHighlighter().highlight(source, language: .swift)
        let tokens = highlighted.runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertEqual(tokens.filter { $0.1 == .keyword }.map(\.0), ["let", "let", "let"])
        XCTAssertEqual(tokens.filter { $0.1 == .comment }.count, 2)
        XCTAssertEqual(tokens.filter { $0.1 == .string }.count, 3)
        XCTAssertFalse(tokens.contains { $0.1 == .number })
        let python = "value = r'''if 42\nreturn'''\n# class 10\nif True:\n    value = f\"hello {42}\"\n"
        let runs = try InternalSyntaxHighlighter().highlight(python, language: .python).runs
        XCTAssertEqual(runs.filter { $0.kind == .string }.count, 2)
        XCTAssertFalse(runs.contains { $0.kind == .number })
    }

    func testAdditionalLanguageLexersAndMarkdownSourceTokens() throws {
        let cases: [(SourceLanguage, String, String)] = [
            (.kotlin, "fun greet() = \"hello\"\n", "fun"),
            (.less, ".card:extend(.base) { content: \"ok\"; color: #fff; }\n", "extend"),
            (.lisp, "; comment\n(defun greet () \"hello\")\n", "defun"),
            (.lua, "-- comment\nlocal function greet() return \"hello\" end\n", "local"),
            (.powershell, "# comment\nforeach ($item in $items) { Write-Output \"ok\" }\n", "foreach"),
            (.miniscript, "func greet(name)\n  return \"hello\"\nend func\n", "func")
        ]
        for (language, source, keyword) in cases {
            let runs = try InternalSyntaxHighlighter().highlight(source, language: language).runs
            let tokens = runs.map { ((source as NSString).substring(with: $0.range), $0.kind) }
            XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword }, language.displayName)
            XCTAssertTrue(tokens.contains { $0.1 == .string }, language.displayName)
        }

        let markdown = "# Heading\n\nUse `inline code`.\n\n```swift\nlet value = 42\n```\n"
        let markdownRuns = try InternalSyntaxHighlighter().highlight(markdown, language: .markdown).runs
        XCTAssertTrue(markdownRuns.contains { $0.kind == .keyword && (markdown as NSString).substring(with: $0.range).hasPrefix("# Heading") })
        XCTAssertTrue(markdownRuns.contains { $0.kind == .string && (markdown as NSString).substring(with: $0.range).contains("inline code") })
        XCTAssertEqual(try SourceCodeInspector.inspect(analysis: analysis(markdown), language: .markdown).source, markdown)
    }

    func testVisualBasicValaAndVimscriptLexersHighlightOnlySupportedLexicalForms() throws {
        let visualBasic = "' comment\nREM second comment\nPublic Class Greeter\n    Public Function Greet(name As String) As String\n        Return \"He said \"\"hi\"\"\" & name\n    End Function\nEnd Class\n"
        let visualBasicRuns = try InternalSyntaxHighlighter().highlight(visualBasic, language: .visualBasic).runs
        let visualBasicTokens = visualBasicRuns.map { ((visualBasic as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(visualBasicTokens.contains { $0.0 == "' comment" && $0.1 == .comment })
        XCTAssertTrue(visualBasicTokens.contains { $0.0 == "REM second comment" && $0.1 == .comment })
        XCTAssertTrue(visualBasicTokens.contains { $0.0 == "Public" && $0.1 == .keyword })
        XCTAssertTrue(visualBasicTokens.contains { $0.0 == "String" && $0.1 == .type })
        XCTAssertTrue(visualBasicTokens.contains { $0.1 == .string })

        let vala = "// comment\npublic class Greeter : Object {\n    public string greet(string name) { return \"Hello \" + name; }\n}\n"
        let valaRuns = try InternalSyntaxHighlighter().highlight(vala, language: .vala).runs
        let valaTokens = valaRuns.map { ((vala as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(valaTokens.contains { $0.0 == "// comment" && $0.1 == .comment })
        XCTAssertTrue(valaTokens.contains { $0.0 == "public" && $0.1 == .keyword })
        XCTAssertTrue(valaTokens.contains { $0.0 == "string" && $0.1 == .type })
        XCTAssertTrue(valaTokens.contains { $0.1 == .string })

        let vimscript = "\" full-line comment\nlet s:message = 'hello'\necho \"display\"\n"
        let vimscriptRuns = try InternalSyntaxHighlighter().highlight(vimscript, language: .vimscript).runs
        let vimscriptTokens = vimscriptRuns.map { ((vimscript as NSString).substring(with: $0.range), $0.kind) }
        XCTAssertTrue(vimscriptTokens.contains { $0.0 == "\" full-line comment" && $0.1 == .comment })
        XCTAssertTrue(vimscriptTokens.contains { $0.0 == "let" && $0.1 == .keyword })
        XCTAssertTrue(vimscriptTokens.contains { $0.0 == "echo" && $0.1 == .keyword })
        XCTAssertEqual(vimscriptTokens.filter { $0.1 == .string }.count, 2)
    }

    func testDirectiveNumberTypesAndLanguageSpecificKeywords() throws {
        let source = "#include <stdio.h>\nconst int count = 0x2A + 1.5e2; // 42\n"
        let runs = try InternalSyntaxHighlighter().highlight(source, language: .c).runs
        XCTAssertTrue(runs.contains { $0.kind == .directive })
        XCTAssertEqual(runs.filter { $0.kind == .number }.map { (source as NSString).substring(with: $0.range) }, ["0x2A", "1.5e2"])
        XCTAssertTrue(runs.contains { $0.kind == .type })
        let script = "#!/usr/bin/env bash\nif true; then\n  count=42\nfi\n"
        XCTAssertEqual(try InternalSyntaxHighlighter().highlight(script, language: .shell).runs.first?.kind, .directive)

        let csharp = "#region Example\nclass Example { string Text = \"if 42\"; }\n#endregion\n"
        let csharpRuns = try InternalSyntaxHighlighter().highlight(csharp, language: .csharp).runs
        XCTAssertEqual(csharpRuns.filter { $0.kind == .directive }.count, 2)
        XCTAssertTrue(csharpRuns.contains { $0.kind == .keyword && (csharp as NSString).substring(with: $0.range) == "class" })

        let cmake = "PROJECT(example) # if 42\n"
        let cmakeRuns = try InternalSyntaxHighlighter().highlight(cmake, language: .cmake).runs
        XCTAssertTrue(cmakeRuns.contains { $0.kind == .keyword && (cmake as NSString).substring(with: $0.range) == "PROJECT" })
        XCTAssertTrue(cmakeRuns.contains { $0.kind == .comment })

        let css = "body { color: red; } // not a CSS comment\n"
        XCTAssertFalse(try InternalSyntaxHighlighter().highlight(css, language: .css).runs.contains { $0.kind == .comment })
    }

    func testLogicalLineTruncationPreservesExactPrefixAndMetadata() throws {
        for source in ["one\ntwo\nthree\n", "one\r\ntwo\r\nthree\r\n", "one\rtwo\rthree\r"] {
            let input = analysis(source)
            let document = try SourceCodeInspector.inspect(analysis: input, language: .swift, maximumLines: 2)
            let separator = input.lineEnding == .crlf ? "\r\n" : input.lineEnding == .cr ? "\r" : "\n"
            XCTAssertEqual(document.source, "one" + separator + "two" + separator)
            XCTAssertEqual(document.lineStarts, [0, 3 + separator.utf16.count])
            XCTAssertEqual(document.lineCount, 2)
            XCTAssertEqual(document.lineEnding, input.lineEnding)
            XCTAssertTrue(document.truncated)
        }
        let empty = try SourceCodeInspector.inspect(analysis: analysis(""), language: .swift)
        XCTAssertEqual(empty.lineStarts, [])
        let newline = try SourceCodeInspector.inspect(analysis: analysis("one\n"), language: .swift, maximumLines: 1)
        XCTAssertEqual(newline.source, "one\n")
        XCTAssertEqual(newline.lineStarts, [0])
        XCTAssertFalse(newline.truncated)
        XCTAssertTrue(try SourceCodeInspector.inspect(analysis: analysis("one\n", extraBytes: 1), language: .swift).truncated)
        let zero = try SourceCodeInspector.inspect(analysis: analysis("one"), language: .swift, maximumLines: -1)
        XCTAssertEqual(zero.source, "")
        XCTAssertTrue(zero.truncated)
    }

    func testHighlighterFailuresAndInvalidRunsKeepPlainText() throws {
        let input = analysis("a😀z\n")
        let failed = try SourceCodeInspector.inspect(analysis: input, language: .swift, highlighter: FailingHighlighter())
        XCTAssertEqual(failed.source, input.text)
        XCTAssertTrue(failed.highlighting.runs.isEmpty)
        XCTAssertFalse(failed.diagnostics.isEmpty)
        let invalid: [[HighlightRun]] = [
            [.init(range: .init(location: -1, length: 2), kind: .string)],
            [.init(range: .init(location: NSNotFound, length: 2), kind: .string)],
            [.init(range: .init(location: 0, length: Int.max), kind: .string)],
            [.init(range: .init(location: 1, length: 1), kind: .string)],
            [.init(range: .init(location: 2, length: 1), kind: .string)],
            [.init(range: .init(location: 1, length: 2), kind: .string), .init(range: .init(location: 0, length: 1), kind: .keyword)],
            [.init(range: .init(location: 0, length: 3), kind: .string), .init(range: .init(location: 1, length: 2), kind: .comment)]
        ]
        for runs in invalid {
            let document = try SourceCodeInspector.inspect(analysis: input, language: .swift, highlighter: InjectedHighlighter(runs: runs))
            XCTAssertEqual(document.source, input.text)
            XCTAssertTrue(document.highlighting.runs.isEmpty)
            XCTAssertFalse(document.diagnostics.isEmpty)
        }
        let valid = try SourceCodeInspector.inspect(analysis: input, language: .swift, highlighter: InjectedHighlighter(runs: [.init(range: .init(location: 1, length: 2), kind: .string)]))
        XCTAssertEqual(valid.highlighting.runs.count, 1)
        XCTAssertThrowsError(try SourceCodeInspector.inspect(analysis: input, language: .swift, highlighter: CancelledHighlighter())) { XCTAssertTrue($0 is CancellationError) }
    }

    func testLargeAndMalformedInputRemainBounded() throws {
        let source = String(repeating: "let n = 42\n", count: 100_000)
        let document = try SourceCodeInspector.inspect(analysis: analysis(source), language: .swift)
        XCTAssertTrue(document.truncated)
        XCTAssertLessThanOrEqual(document.lineCount, 20_000)
        XCTAssertLessThanOrEqual(document.highlighting.runs.count, 50_000)
        XCTAssertTrue(source.hasPrefix(document.source))
        let malformed = "let s = \"unterminated\n/* unterminated"
        XCTAssertEqual(try SourceCodeInspector.inspect(analysis: analysis(malformed), language: .swift).source, malformed)
    }

    func testHighlightResourceCeilingsKeepSourceAvailable() throws {
        XCTAssertThrowsError(try InternalSyntaxHighlighter().highlight(String(repeating: "0", count: 1_048_577), language: .swift))
        let manyRuns = String(repeating: "let n=0;", count: 30_000)
        let document = try SourceCodeInspector.inspect(analysis: analysis(manyRuns), language: .swift)
        XCTAssertEqual(document.source, manyRuns)
        XCTAssertTrue(document.highlighting.runs.isEmpty)
        XCTAssertEqual(document.diagnostics.first?.code, .limitExceeded)
        let nesting = String(repeating: "/*", count: 65) + String(repeating: "*/", count: 65)
        let nested = try SourceCodeInspector.inspect(analysis: analysis(nesting), language: .swift)
        XCTAssertEqual(nested.diagnostics.first?.code, .limitExceeded)
        XCTAssertEqual(nested.source, nesting)
        let run = HighlightRun(range: .init(location: 0, length: 1), kind: .keyword)
        let invalid = try SourceCodeInspector.inspect(analysis: analysis("x"), language: .swift, highlighter: InjectedHighlighter(runs: Array(repeating: run, count: 50_001)))
        XCTAssertTrue(invalid.highlighting.runs.isEmpty)
        XCTAssertFalse(invalid.diagnostics.isEmpty)
    }

    func testHighlighterPropagatesTaskCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try InternalSyntaxHighlighter().highlight("let n=42\n", language: .swift)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
