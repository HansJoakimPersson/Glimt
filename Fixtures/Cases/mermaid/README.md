# Mermaid diagram fixtures

Each `.mmd` file is a small, self-contained source example for one Mermaid syntax family.
`MermaidKitRendererTests` wraps each source in Markdown and verifies supported diagrams render at
narrow and regular widths. The following fixtures are retained as unsupported examples and must
remain readable as source until native parser support is added:

| Fixture | Diagram type | Current behavior |
| --- | --- | --- |
| `agentflow.mmd` | Agent flow | MermaidKit does not parse this dialect; source fallback is tested. |
| `use-case.mmd` | Use case | MermaidKit does not parse this diagram family; source fallback is tested. |

All other family fixtures are expected to render as native images. The fixture set is authored for
Glimt and is not a complete syntax conformance suite.

Fixtures are authored for Glimt and are not copied from upstream demo pages. Keep them compact,
offline, and free of external links or active content. `Fixtures/Cases/` is test-only; no fixture
is included in the app bundle.

`wrapped-01.md` and `wrapped-02.md` preserve the alphabetically first and last 16 `.mmd` files as
Markdown annotations. Each entry is `## <basename>`, a blank line, a column-zero `mermaid` fence,
the original payload bytes, and a closing fence. A single LF is added before the closer only when
the payload ends in neither LF nor CR. Keep the 32 standalone sources unchanged; tests compare the
wrapper payload bytes to those originals before asking the Markdown parser to inspect them.
`invalid.mermaid` is the exact malformed standalone control `flowchart TD\nA[` with no final newline.
