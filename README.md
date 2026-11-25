# Glimt

<p>
  <a href="https://github.com/HansJoakimPersson/Glimt/actions/workflows/ci.yml"><img src="https://github.com/HansJoakimPersson/Glimt/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt/actions/workflows/release.yml"><img src="https://github.com/HansJoakimPersson/Glimt/actions/workflows/release.yml/badge.svg" alt="Release"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt/releases"><img src="https://img.shields.io/github/v/release/HansJoakimPersson/Glimt?include_prereleases&sort=semver&style=flat&label=version" alt="latest version"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt/releases"><img src="https://img.shields.io/github/downloads/HansJoakimPersson/Glimt/total.svg?style=flat" alt="downloads"/></a>
  <a href="https://hansjoakimpersson.github.io/Glimt/"><img src="https://img.shields.io/badge/website-GitHub%20Pages-222222.svg?style=flat&logo=githubpages&logoColor=white" alt="website"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg?style=flat" alt="license"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt"><img src="https://img.shields.io/badge/platform-macOS%2015%2B-0A84FF.svg?style=flat" alt="platform"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt"><img src="https://img.shields.io/badge/Swift-6-F05138.svg?style=flat&logo=swift&logoColor=white" alt="Swift 6"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt"><img src="https://img.shields.io/badge/Quick%20Look-preview%20%2B%20thumbnails-6E6E73.svg?style=flat" alt="Quick Look preview and thumbnails"/></a>
  <a href="https://github.com/HansJoakimPersson/Glimt"><img src="https://img.shields.io/badge/network-none-34C759.svg?style=flat" alt="no network access"/></a>
  <a href="https://github.com/sponsors/hansjoakimpersson"><img src="https://img.shields.io/badge/GitHub%20Sponsors-Support-EA4AAA.svg?style=flat&logo=githubsponsors&logoColor=ffffff" alt="GitHub Sponsors"/></a>
</p>

Glimt adds Quick Look previews for source code, Markdown and structured data to macOS. Select a
file in Finder and press Space to see it highlighted, rendered or laid out as a tree, with Raw and
Hex always one click away. Glimt is local and read-only: it never runs or changes the files it
shows, and it does not use the network.

<img src="docs/assets/glimt-icon.svg" width="96" alt="Glimt icon">

<img src="docs/assets/glimt-overview.png" width="800" alt="The Glimt app with its settings beside a rendered Markdown preview, and in front of it a Quick Look window showing a Swift file with syntax highlighting and line numbers">

## Features

- Syntax-highlighted source with line numbers for programming, markup, configuration and template
  languages.
- Rendered Markdown with support for most formatting, such as tables, footnotes, math and Mermaid
  diagrams, and a dynamic table of contents.
- Tree, Pretty and Table views for JSON, YAML, XML, property lists, CSV, logs, certificates,
  SQLite schemas and more. Archives are listed, never extracted.
- Finder thumbnails from the same engine.
- Apple developer files such as provisioning profiles, entitlements and privacy manifests, shown as
  readable metadata without installing or trusting anything.
- An app for opening files directly, changing appearance and choosing which views each format
  offers.

## System Requirements

macOS 15 or later, on Apple silicon or Intel. Glimt needs no special permissions.

## Installation

Download the latest release archive:

- [Glimt-latest-macOS.zip](https://github.com/HansJoakimPersson/Glimt/releases/latest/download/Glimt-latest-macOS.zip)
- [Project website](https://hansjoakimpersson.github.io/Glimt/)
- [Releases page](https://github.com/HansJoakimPersson/Glimt/releases/latest)

Then:

1. Unzip the archive.
2. Move `Glimt.app` to `/Applications`.
3. Open Glimt once. Builds are not notarized yet, so macOS blocks the first launch: choose
   **Done**, open **System Settings › Privacy & Security**, click **Open Anyway** next to the
   message about Glimt and confirm.
4. If Finder previews do not appear, enable Glimt under
   **System Settings › General › Login Items & Extensions › Quick Look**.

## How to Use It

Select a file in Finder and press **Space**, or open the Preview pane. The tabs at the bottom switch
between the file's views, such as Source, Rendered, Tree and Raw.

In the app, `File › Open File…` (⌘O) opens any file, and the settings beside the preview control
appearance, fonts and wrapping. `View › Formats & Views…` (⌘1) chooses each format's views and
which one opens first. Quick Look uses the same settings.

<img src="docs/assets/glimt-quicklook.png" width="800" alt="Two Quick Look windows: a Swift file in the Source view with line numbers, and a Markdown file in the Rendered view with a table and a code block">

## Supported Formats

- **Source code and markup:** Swift, Python, JavaScript/TypeScript, C/C++, Java, Rust, Go, Shell,
  HTML, CSS, templates such as Jinja and ERB, and many more.
- **Documents:** Markdown, TextBundle, Mermaid, AsciiDoc, Org.
- **Data:** JSON, YAML, XML, TOML, property lists, CSV/TSV, JSON Lines, logs, iCalendar, vCard, email.
- **Specialist files:** certificates, software bills of materials, SQLite, ZIP and TAR, diffs.
- **Anything else:** plain text in Raw, binary files in Hex.

The [format masterlist](docs/formats/README.md) lists every format with its views and
limits.

## FAQ

**Quick Look does not use Glimt after installation.** Open Glimt once: macOS registers the Quick
Look extensions the first time the app runs.

**Finder still shows another preview.** macOS picks one Quick Look provider per file type, and
another installed app may win. Check that Glimt is enabled under
**System Settings › General › Login Items & Extensions › Quick Look**. The file may also be a
format Glimt does not support yet, or one that macOS keeps for its own preview, such as `.txt` on
macOS 27. `.ts` files are a known conflict, because macOS may treat them as MPEG video.

**Why doesn't Glimt appear in Open With, and why doesn't double-clicking a file open it?** Glimt
is a previewer, not an editor, so it does not register as an app for opening files. Use
`File › Open File…` (⌘O) in Glimt instead.

**Why does macOS ask for access to a folder such as Desktop or Documents?** This can happen when
VCS Support is turned on under Advanced settings. Glimt then reads the Git or Subversion data next
to the file to mark changed lines, and macOS asks before it reads protected folders. VCS Support is
off by default, and Glimt only reads, never writes.

**macOS says it cannot verify Glimt.** Builds are not notarized yet. Approve the first launch with
**Open Anyway**, as described under Installation.

**A preview is blank, partial or only shows Raw or Hex.** The file may be malformed or larger than
Glimt's limits. Open it in the app and choose **Inquiry** in the title bar to see how it was read.

**Does Glimt update itself?** No. Check
[GitHub Releases](https://github.com/HansJoakimPersson/Glimt/releases) for new builds.

**How do I uninstall Glimt?** Quit it and move `Glimt.app` to the Trash. To remove settings and
logs too, delete `~/Library/Application Support/Glimt/` and `~/Library/Logs/Glimt/`.

## Development

Glimt is an Xcode project: the app, its Quick Look Preview and Thumbnail extensions, and the
`InspectorCore` Swift package. You need Xcode 27, Python 3 and ShellCheck. Open `Glimt.xcodeproj`
and run the `Glimt` scheme to build from source. `make test` runs the same checks as CI, and
`make help` lists the other targets.

## Contributing

Issues and focused pull requests are welcome. Run `make test` before opening a pull request, and
attach a small synthetic example file rather than a private one.

## Support

If you want to support Glimt or whatever I build next:

- [GitHub Sponsors](https://github.com/sponsors/hansjoakimpersson)

## License

Glimt is licensed under the GNU Affero General Public License v3.0 (`AGPL-3.0`). See [`LICENSE`](LICENSE).
