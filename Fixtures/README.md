# Shared fixtures

Fixtures are canonical synthetic input, not expected output. Tests keep their own assertions.

- `Showcase/`: small, valid, offline product examples. FormatCatalog names each example;
  Settings, normal previews and tests read the same file. Only this directory ships in the app.
- `Cases/`: valid edges, malformed, ambiguous, encoding, boundary and security cases. Test-only.
  `Cases/reference/` holds one synthetic example per SourceCodeSyntaxHighlight reference format;
  `Cases/markdown-family/`, `Cases/catalog/`, `Cases/security/` and `Cases/log/` cover planned
  catalog formats and log variants. Security fixtures contain only public or test material
  (no private keys). The [masterlist](../docs/formats/README.md) links formats to their fixtures;
  unimplemented formats need fixtures only when there is a consumer.

Keep files small and project-owned. Preserve unusual bytes and line endings exactly. Add inputs
for supported behavior or concrete regressions; do not normalize encoding-sensitive cases.
A format is fully supported only with detection, inspection/rendering, tests, a valid showcase
and a defective case in `Cases/` (listed in `FormatFixtureCoverageTests`). Fixtures do not
describe themselves as examples; comments read like the file's own content.
Recognized text fallback is not full support.
