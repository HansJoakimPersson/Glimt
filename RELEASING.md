# Building and releasing Glimt

This document covers how Glimt is built, tested, packaged, versioned and published. The same
commands run locally and in GitHub Actions; the workflows only call them.

## Toolchain

| Tool | Version | Notes |
| --- | --- | --- |
| Xcode | 27.0 (27A266a) | CI pins `/Applications/Xcode_27.0.app` on the `xcode-27` runner |
| macOS SDK / deployment target | macOS 27 SDK / macOS 15.0 | |
| Swift | 6 language mode | |
| Python 3, ShellCheck | any current | used by the tooling tests and `make lint` (`brew install shellcheck`) |

Swift packages are pinned in `Glimt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
and `InspectorCore/Package.resolved`. `make resolve` and `make package` refuse versions that are not
in the resolved file.

## Commands

| Command | What it does |
| --- | --- |
| `make version` | Validates `Config/Version.xcconfig` and prints the SemVer, tag, release title and artifact names |
| `make resolve` | Fetches the pinned packages into `build/SourcePackages` |
| `make lint` | swift-format rules, ShellCheck and the InspectorCore warnings-as-errors build |
| `make test` | The full unsigned gate (`scripts/ql-safe-smoke.sh`): lint with sanitizers, InspectorCore tests, tooling tests, Xcode Debug and Release tests, and the unsigned bundle audit |
| `make package` | `scripts/package-release.sh`: Release build (arm64 + x86_64), ad-hoc or Developer ID signing, `codesign` verification, the bundle audit for that signing mode, then `dist/Glimt-<semver>-macOS.zip` and `dist/Glimt-<semver>-SHA256SUMS.txt` |
| `make clean` | Removes `dist/` |

Builds go to locked scopes under `build/scoped.noindex/`, which unregister their apps from
LaunchServices before deleting them. Nothing is installed. `make package` refuses a dirty working
tree, so every artifact maps to one commit. The commit is recorded in
`Contents/Resources/GlimtBuildProvenance.plist` inside each bundle. For a local experiment only,
`GLIMT_ALLOW_DIRTY=1 make package` lifts the restriction; the provenance then records the tree as unclean.

### Why a Makefile but no root `Package.swift`

The app is an Xcode project because SwiftPM cannot build its app and Quick Look extension bundles,
entitlements, asset catalogs or build phases. A root `Package.swift` would be a second, incomplete
build description. The SwiftPM package that exists, `InspectorCore`, is the engine library the app
links, and `make test` tests it with `swift test`. The Makefile holds no build logic; it gives
developers and CI the same few entry points over `scripts/`.

## Versioning

`Config/Version.xcconfig` is the only place a version is written:

```
MARKETING_VERSION = 0.1.0          // SemVer core → CFBundleShortVersionString of all three bundles
CURRENT_PROJECT_VERSION = 1        // build number → CFBundleVersion
GLIMT_PRERELEASE = beta.1          // alpha.N, beta.N, rc.N, or empty for a stable release
```

It is the base configuration of the Xcode project, so every bundle's Info.plist gets the same
values. The app also gets `GlimtPrerelease`. `scripts/version.sh` validates the file and derives
the rest:

| Derived value | 0.1.0 Beta 1 | Source |
| --- | --- | --- |
| SemVer | `0.1.0-beta.1` | marketing version + `-` + pre-release |
| Git tag | `v0.1.0-beta.1` | `v` + SemVer |
| Release title / About window | `Glimt 0.1.0 Beta 1` / `Version 0.1.0 Beta 1 (1)` | label from the pre-release stage |
| GitHub pre-release | yes | any alpha, beta or rc |
| Artifacts | `Glimt-0.1.0-beta.1-macOS.zip`, `Glimt-0.1.0-beta.1-SHA256SUMS.txt` | SemVer |

The build number is a single increasing integer across all builds. Raise it for every published
build, including each pre-release of the same version, so macOS and update checks can order builds.
Tests fail when a built bundle, the bundle audit or the tag disagree with the file.

### Planned sequence

| Release | `MARKETING_VERSION` | `CURRENT_PROJECT_VERSION` | `GLIMT_PRERELEASE` | Tag |
| --- | --- | --- | --- | --- |
| 0.1.0 Beta 1 | 0.1.0 | 1 | beta.1 | `v0.1.0-beta.1` |
| 0.1.0 Beta 2 | 0.1.0 | 2 | beta.2 | `v0.1.0-beta.2` |
| 0.1.0 RC 1 | 0.1.0 | 3 | rc.1 | `v0.1.0-rc.1` |
| 0.1.0 | 0.1.0 | 4 | *(empty)* | `v0.1.0` |

A later feature release starts again at `alpha.1` or `beta.1` with a higher `MARKETING_VERSION`. The
build number keeps increasing.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main`, on pull requests and on demand. It uses
the `xcode-27` runner with Xcode 27.0 and runs:

1. `make version`, after installing ShellCheck
2. `make test`
3. `make package`, which uploads the `dist/` files as the `glimt-dist` workflow artifact

The same workflow builds releases (below), so a release artifact is always built and tested the
same way as a CI artifact.

## Publishing a release

1. On `main`, with CI green, set the new values in `Config/Version.xcconfig` (see the sequence
   above) and run `make version` to check the names.
2. Write `release-notes/v<semver>.md` with highlights, known limitations and installation steps.
   Start from the previous release's notes. A tooling test fails until the file for the configured
   tag exists.
3. Optionally run `make test` and `make package` locally.
4. Commit, for example `Release 0.1.0 Beta 2`, and push. Wait for CI.
5. Tag the commit and push the tag:

   ```sh
   git tag -a v0.1.0-beta.2 -m "Glimt 0.1.0 Beta 2"
   git push origin v0.1.0-beta.2
   ```

6. The tag starts `.github/workflows/release.yml`. It:
   - rejects a tag that differs from `Config/Version.xcconfig`
   - runs the full CI build and test on the tagged commit
   - verifies the artifact and its checksums
   - creates the GitHub Release with the release title, the zip, the checksum file and the notes,
     followed by the build identity and checksums

   alpha, beta and rc versions are marked as pre-releases. A stable version is marked as latest.
7. Verify the published release: download the zip, check `shasum -a 256 -c`, install, and confirm
   that `Glimt › About Glimt` shows the expected version and build.

If a release job fails before publishing, fix the problem on `main`. Then delete and recreate the
tag on the fixed commit (`git push origin :refs/tags/<tag>`) or move on to the next build number.
Do not replace the assets of a published release. Publish a new build number instead.

## Signing and notarization

Without signing secrets, `make package` signs the app and its extensions **ad hoc**. It keeps
Hardened Runtime and the sandbox entitlements, and the bundle audit (`rc-check-bundle.sh --adhoc`)
verifies them. Such builds are not notarized. Gatekeeper asks the user to confirm the first launch
with **Open Anyway** in System Settings › Privacy & Security. Glimt 0.1.0 Beta 1 ships this way.

For Developer ID signing and notarization, add these repository secrets. CI imports the certificate
into a temporary keychain, then deletes it and the API key file after the job:

| Secret | Value |
| --- | --- |
| `GLIMT_SIGN_IDENTITY` | `Developer ID Application: <Name> (<TEAMID>)` |
| `GLIMT_DEVELOPMENT_TEAM` | the team ID |
| `GLIMT_SIGNING_CERTIFICATE_P12` | base64 of the exported Developer ID certificate and private key (`base64 -i cert.p12`) |
| `GLIMT_SIGNING_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `GLIMT_NOTARY_KEY_P8` | contents of an App Store Connect API key (`AuthKey_<id>.p8`) with Developer access |
| `GLIMT_NOTARY_KEY_ID`, `GLIMT_NOTARY_ISSUER` | that key's ID and issuer ID |

With these secrets, `make package` timestamps the signatures and requires a real identity in the
audit (`rc-check-bundle.sh --signed`). It also submits the app with `notarytool`, staples the
ticket and runs a Gatekeeper `spctl` assessment before archiving. Locally, the same path runs with
the identity in your login keychain:

```sh
GLIMT_SIGN_IDENTITY="Developer ID Application: …" GLIMT_DEVELOPMENT_TEAM=TEAMID \
GLIMT_NOTARY_PROFILE=<notarytool keychain profile> make package
```

Never commit certificates, keys, provisioning profiles or `ExportOptions.plist`; `.gitignore`
excludes them. Test fixtures contain only synthetic certificates.
