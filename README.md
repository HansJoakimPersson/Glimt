# Glimt

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg?style=flat" alt="license"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt"><img src="https://img.shields.io/badge/platform-macOS%2015%2B-0A84FF.svg?style=flat" alt="platform"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt"><img src="https://img.shields.io/badge/Swift-6-F05138.svg?style=flat&logo=swift&logoColor=white" alt="Swift 6"/></a>
  <a href="https://github.com/sponsors/hansjoakimpersson"><img src="https://img.shields.io/badge/GitHub%20Sponsors-Support-EA4AAA.svg?style=flat&logo=githubsponsors&logoColor=ffffff" alt="GitHub Sponsors"/></a>
</p>

Glimt is a native, local, read-only file inspector for macOS 15 or later. It shows source code,
Markdown and structured data through a shared engine in the host app, Quick Look and thumbnails.
Files are never executed or changed, and the installed app does not use the network.

<img src="docs/assets/glimt-icon.svg" width="96" alt="Glimt icon">

**Beta:** download the latest pre-release from [GitHub Releases](https://github.com/HansJoakimPersson/Glimt/releases).
Beta builds are ad-hoc signed and not notarized, so macOS asks you to confirm the first launch (see
Install below). Finder provider selection remains unverified; macOS may choose another
provider even when Glimt renders the file in its app.

## Install

1. Download `Glimt-<version>-macOS.zip` and `Glimt-<version>-SHA256SUMS.txt` from the release and
   verify the archive: `shasum -a 256 -c Glimt-<version>-SHA256SUMS.txt`.
2. Unzip it and move `Glimt.app` to `/Applications`.
3. Open Glimt. When macOS cannot verify the developer, choose **Done**, open
   **System Settings › Privacy & Security** and click **Open Anyway**. Alternatively run
   `xattr -dr com.apple.quarantine /Applications/Glimt.app`.
4. `Glimt › About Glimt` shows the version, for example **0.1.0 Beta 1 (1)**.

## Build and run

Requires Swift 6 and Xcode with a compatible macOS SDK.

1. Clone the repository and open `Glimt.xcodeproj`.
2. Select the `Glimt` scheme, `My Mac` and `Debug`.
3. Use Xcode’s `Sign to Run Locally`, then `Product > Run`.

This launches the host from your checkout; an Xcode launch does not prove system integration.
The same commands run locally and in GitHub Actions:

```sh
make test      # full unsigned gate: lint, Core, tooling and Xcode Debug/Release tests, bundle audit
make package   # Release build, signature and bundle audit, dist/Glimt-<version>-macOS.zip + SHA-256
make version   # version, tag and artifact names from Config/Version.xcconfig
```

Versioning, signing, notarization and publishing a release are described in [RELEASING.md](RELEASING.md).

## Inspect and configure

In Finder, select a file and press Space or use the Preview pane. When macOS selects Glimt, use
the tabs in the **bottom footer** to switch between the file’s available views. Finder thumbnails
use fixed rendering defaults.

In the Glimt app:

- Change global appearance, fonts, wrapping and limits beside the live preview.
- Use `File > Open File…` (⌘O) for your own file.
- Use `View > Formats & Views…` (⌘1) for available views, their order/default, format options and
  custom filename/extension mappings. Mappings do not change Finder provider selection.
- Open `Inquiry` in the title bar for detected type, support, inspector and diagnostics.
  `Copy Report` explicitly copies the report for sharing.

Source previews include bounded lexers for ERB, Classic ASP, ASP.NET, Jinja and Twig templates,
plus QML and Solidity. Template markup and embedded language tokens are colored without evaluating
or executing template code; none of these files are compiled or syntax-validated.

Quick Look reads the same preview settings. A tab change affects only the open preview, while
View Order determines the initial view of a new request. Settings do not alter source files.

## Supported formats

| Family | Examples Glimt handles | Views Glimt presents |
| --- | --- | --- |
| Source code and web markup | Swift, Objective-C, MATLAB/Octave, Ada, Eiffel, Fortran (including fixed form), Pyrex/Cython source, AutoHotkey, Inno Setup, NSIS, OCaml, Nim, OpenSCAD, WebAssembly Text, Pascal/Delphi, Verilog, VHDL, COBOL, Device Tree Source, gettext PO/POT, Tcl/Tk, AppleScript, Visual Basic/VBScript, Vala, Vimscript, Nginx and Apache configuration, Java, Scala, Perl, R, Julia, Python (including SCons, Snakemake and Waf source), JavaScript, TypeScript/TSX, C/C++, Shell (including Gentoo ebuild/eclass), HTML, Classic ASP, ASP.NET, Jinja, Twig, SCSS, Vue, Svelte, PHP, Rust, Ruby and other catalogued languages | Syntax-highlighted Source, Raw; Hex for binary input |
| Policies and data interchange source | Rego, LDAP LDIF, Turtle/N3 and N-Triples | Syntax-highlighted Source, Raw and Hex; no policy evaluation, directory updates or RDF resolution |
| Documentation and infrastructure source | AsciiDoc, Terraform/HCL, INI-style configuration including Desktop Entry, Doxygen and KDevelop project files | Syntax-highlighted Source, Raw; Hex for binary input |
| Markdown | Markdown, TextBundle Markdown packages (`.textbundle`), R Markdown, API Blueprint (`.apib`) and Cursor MDC (`.mdc`) | Shared Rendered or Source. TextBundle Preview reads root `info.json` and `text.md` and resolves eligible local images only within `assets/`. API-specific semantics and Cursor rule execution are not interpreted |
| Org Mode | `.org` | Syntax-highlighted Source, Raw; Org/Babel blocks are never evaluated |
| Standalone diagrams | `.mmd`, `.mermaid` | Native MermaidKit Rendered and Raw; unsupported diagram types remain available as source |
| Structured data | JSON/JSONC/JSON5, YAML, XML, GeoJSON, KML, GPX, property lists including Apple `CodeResources`, JSON Lines, EML, iCalendar, vCard | Tree and Raw; Pretty when available; geospatial formats show bounded feature and coordinate summaries |
| Databases and archives | SQLite schema (`.sqlite`, `.sqlite3`), USTAR (`.tar`, `.tar.gz`, `.tgz`), ZIP (`.zip`) | Table/inventory or schema Tree; archives are never extracted |
| Software bills of materials | CycloneDX and SPDX JSON/XML/YAML/Tag-Value; CycloneDX protobuf (`.cdx.pb`) | Bounded Tree; protobuf decoding covers selected fields only |
| Certificates and containers | X.509 certificates, certificate-only PKCS#7 bundles (`.p7b`, `.p7c`) and DER PKCS#12 v3 files (`.p12`, `.pfx`) | Bounded Tree with certificate facts or PKCS#12 envelope metadata. Inspection never decrypts payloads, imports keys or evaluates trust. |
| Configuration | Go module/workspace files (`go.mod`, `go.sum`, `go.work`, `go.work.sum`), EditorConfig, `.gitignore`, `.dockerignore`, `.npmrc`, `.gitattributes`, `.gitmodules`, systemd unit files, TOML (bounded subset), INI / `.env`, Java Properties, Windows Registry `.reg` | Source, Tree and Raw |
| Logs | JSON and recognized text logs, including Syslog, CEF/LEEF, access logs, Kubernetes CRI and logfmt | Table, Tree and Raw when the content supports them |
| Tables | CSV, TSV | Table, Raw |
| Changes | Diff/Patch | Diff, Raw |
| Plain text | Recognized text | Raw with encoding/line-ending metadata |

Unknown binary input has a bounded Hex fallback. Available views depend on the detected content and
configured View Order. The preview example dropdown is sorted alphabetically by format/sample name.
The [format masterlist](docs/formats/README.md) records supported, partial, Raw-only and planned
formats, plus limits, fixtures and routing conflicts; a readable fallback is not specialist-format support.
Graphviz DOT (`.dot`, `.gv`) has bounded syntax-highlighted Source, Raw and Hex views.
Graph layout and drawing remain deferred pending license review and a native drawing adapter.

For regular files opened by URL, Glimt selects an inspector using at most 64 KiB of file content.
Preview and Thumbnail share the 64 KiB routing budget across a TextBundle package’s manifest and
Markdown sample. The selected inspector can then read more within its own limits.
Inspection has a 2-second deadline for previews and a 1-second deadline for thumbnails.
On timeout, Glimt can use the bytes already read for a Raw or Hex fallback. If no bytes
are available, the request fails.

## Troubleshooting

If Finder shows another preview, check that Glimt is enabled under
`System Settings > General > Login Items & Extensions > Quick Look`. Another provider or an old
Glimt registration may still win. Use Inquiry’s Quick Look diagnostics and the read-only
`bash scripts/glimt-cleanup.sh` inventory before changing registrations.
`.ts` is a known conflict because macOS may classify it as MPEG Transport Stream.

For blank previews, malformed content or large files, inspect the same file with Inquiry and check
the configured Data limit. Thumbnails and API replies alone do not identify the selected provider.

## Settings and logs

Preferences live at `~/Library/Application Support/Glimt/settings.json`. The host writes them;
Preview reads them, and Thumbnail reads only debug flags. Use the confirmed **Reset All Settings…**
action to restore defaults, including custom themes and mappings. It has no undo.

**Advanced > Debug logging** is off by default. When enabled it writes
`~/Library/Logs/Glimt/Glimt.log`, rotating at 1 MiB with one previous file. **Show Log File** reveals
it in Finder. Logs exclude inspected content, filenames and full paths. Unified logs are available with:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.glimt.app"' --level debug
```

## Verify and contribute

The full unsigned gate is `make test`. It resolves the pinned packages into
`build/SourcePackages`, then runs `scripts/ql-safe-smoke.sh`: lint, Core, tooling and Xcode
Debug/Release tests and the bundle audit. CI runs the same gate on every push and pull request.

The gate does not install the app. Xcode may register build products; scoped cleanup attempts to
unregister its own paths before deletion. It does not verify Finder selection. Known current test
gaps are documented rather than suppressed.

Focused issues and pull requests are welcome for detection/rendering, Finder interoperability,
accessibility and formats within the local, inert design. Share a minimal synthetic fixture rather
than a private user file. See [docs/formats/README.md](docs/formats/README.md) for the full format
and view inventory.

## Uninstall

Quit Glimt and move the app to Trash. Settings and logs remain until you explicitly remove the
Glimt directories under `~/Library/Application Support/` and `~/Library/Logs/`.
For stale extension registrations, use the identity-checked modes of `scripts/glimt-cleanup.sh`.

## Support

If you want to support Glimt or whatever I build next:

- [GitHub Sponsors](https://github.com/sponsors/hansjoakimpersson)

## License

Glimt is licensed under the GNU Affero General Public License v3.0 (`AGPL-3.0`). See [`LICENSE`](LICENSE).

The optional Git view reads repositories with Glimt's own read-only reader, so no Git library is linked.
