# Entry points shared by developers and GitHub Actions. The logic lives in scripts/, so a local
# `make test` or `make package` runs exactly what CI runs. See Development in README.md.
SHELL := /bin/bash
SOURCE_PACKAGES := build/SourcePackages

.PHONY: help version resolve lint test package clean

help:
	@printf '%s\n' \
	  'make version   Print the version, tag and artifact names from Config/Version.xcconfig' \
	  'make resolve   Fetch the pinned Swift packages into $(SOURCE_PACKAGES)' \
	  'make lint      swift-format rules, ShellCheck and the InspectorCore warnings-as-errors build' \
	  'make test      Full unsigned gate: lint, Core, tooling and Xcode Debug/Release tests, bundle audit' \
	  'make package   Release build, signature and bundle audit, dist/ zip and SHA-256 checksums' \
	  'make clean     Remove dist/'

version:
	@bash scripts/version.sh

resolve:
	xcodebuild -project Glimt.xcodeproj -scheme Glimt -resolvePackageDependencies \
	  -onlyUsePackageVersionsFromResolvedFile -clonedSourcePackagesDirPath $(SOURCE_PACKAGES)

lint:
	bash scripts/lint.sh

test: resolve
	bash scripts/ql-safe-smoke.sh

package: resolve
	bash scripts/package-release.sh

clean:
	rm -rf dist
