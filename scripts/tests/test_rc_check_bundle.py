from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "rc-check-bundle.sh"
CATALOG = ROOT / "InspectorCore" / "Sources" / "InspectorCore" / "Resources" / "formats.json"
SHOWCASE = ROOT / "Fixtures" / "Showcase"
SOURCE_PACKAGES = Path(os.environ.get("GLIMT_CLONED_SOURCE_PACKAGES_DIR", ROOT / "build" / "SourcePackages"))
SWIFTMATH_FONTS = SOURCE_PACKAGES / "checkouts" / "SwiftMath" / "Sources" / "SwiftMath" / "mathFonts.bundle"
VERSION = dict(
    line.split("=", 1)
    for line in subprocess.run(
        ["bash", str(ROOT / "scripts" / "version.sh")], check=True, capture_output=True, text=True
    ).stdout.splitlines()
)


class RCCheckBundleTests(unittest.TestCase):
    """Runs the unsigned bundle gate against a synthetic, correctly shaped Glimt.app."""

    @classmethod
    def setUpClass(cls):
        cls.work = Path(tempfile.mkdtemp(prefix="glimt-rc-check-"))
        source = cls.work / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        cls.executable = cls.work / "main"
        subprocess.run(["clang", "-o", str(cls.executable), str(source)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.work, ignore_errors=True)

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.work))
        self.app = self.case / "Glimt.app"
        self.make_bundle(self.app, "Glimt", "com.glimt.app", app=True)
        self.make_bundle(self.preview, "GlimtPreview", "com.glimt.app.preview", extension="com.apple.quicklook.preview")
        self.make_bundle(self.thumbnail, "GlimtThumbnail", "com.glimt.app.thumbnail", extension="com.apple.quicklook.thumbnail")
        self.copy_swiftmath_resources(self.app)
        self.copy_swiftmath_resources(self.preview)

    @property
    def preview(self):
        return self.app / "Contents/PlugIns/GlimtPreview.appex"

    @property
    def thumbnail(self):
        return self.app / "Contents/PlugIns/GlimtThumbnail.appex"

    def make_bundle(self, bundle, name, identifier, app=False, extension=None):
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copy2(self.executable, contents / "MacOS" / name)
        info = {
            "CFBundleExecutable": name,
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": VERSION["MARKETING_VERSION"],
            "CFBundleVersion": VERSION["BUILD_NUMBER"],
            "LSMinimumSystemVersion": "15.0",
        }
        if app:
            info.update(CFBundleIconFile="AppIcon", NSHumanReadableCopyright="Copyright",
                        GlimtPrerelease=VERSION["PRERELEASE"])
        if extension:
            info["NSExtension"] = {
                "NSExtensionPointIdentifier": extension,
                "NSExtensionAttributes": {"QLSupportedContentTypes": ["public.json"]},
            }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        resources = contents / "Resources"
        resources.mkdir()
        (resources / "ThirdPartyNotices.txt").write_text(
            "Yams 6.2.2\nlibyaml\nMermaidKit 2.10.2\n"
        )
        (resources / "GlimtBuildProvenance.plist").write_bytes(plistlib.dumps({"SchemaVersion": 1}))
        core = resources / "InspectorCore_InspectorCore.bundle" / "Contents"
        (core / "Resources").mkdir(parents=True)
        (core / "Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL", "CFBundleIdentifier": "inspectorcore.InspectorCore.resources"}))
        shutil.copy2(CATALOG, core / "Resources" / "formats.json")
        if app:
            shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
            (resources / "AppIcon.icns").write_bytes(b"icns\x00\x00\x00\x08")
            (resources / "Assets.car").write_bytes(b"car")
            shutil.copytree(SHOWCASE, resources / "Showcase", ignore=shutil.ignore_patterns(".DS_Store"))
            os.chmod(resources / "Showcase/source/shell.sh", 0o644)
    def copy_swiftmath_resources(self, bundle):
        resource = bundle / "Contents/Resources/SwiftMath_SwiftMath.bundle"
        fonts = resource / "Contents/Resources/mathFonts.bundle"
        shutil.copytree(SWIFTMATH_FONTS, fonts, ignore=shutil.ignore_patterns("math_table_to_plist.py"))
        for path in fonts.rglob("*"):
            if path.is_file():
                path.chmod(0o644)
        info = resource / "Contents/Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL", "CFBundleIdentifier": "swiftmath.SwiftMath.resources"}))

    def run_gate(self, mode="--unsigned"):
        return subprocess.run(["bash", str(SCRIPT), mode, str(self.app)], capture_output=True, text=True)

    def assert_rejected(self, message, mode="--unsigned"):
        result = self.run_gate(mode)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("RC BUNDLE FAIL: " + message, result.stderr + result.stdout)

    # MARK: Accepted

    def test_correct_bundle_passes(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Bundle configuration: READY", result.stdout)
        self.assertIn("UNVERIFIED — unsigned check", result.stdout)
        self.assertIn(f"version={VERSION['SEMVER']} build={VERSION['BUILD_NUMBER']}", result.stdout)

    # MARK: Ad-hoc signature

    def sign_adhoc(self, runtime=True, resource_bundles=True):
        # Xcode signs the nested SwiftPM data bundles before the code that contains them.
        nested = sorted(self.app.rglob("*_*.bundle")) if resource_bundles else []
        for bundle in nested:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)],
                           check=True, capture_output=True)
        entitlements = [
            (self.preview, "Glimt/PreviewExtension/GlimtPreview.entitlements"),
            (self.thumbnail, "Glimt/ThumbnailExtension/GlimtThumbnail.entitlements"),
            (self.app, "Glimt/App/GlimtHost.entitlements"),
        ]
        for bundle, path in entitlements:
            options = ["--options", "runtime"] if runtime else []
            subprocess.run(["codesign", "--force", "--sign", "-", *options, "--entitlements", str(ROOT / path),
                            "--timestamp=none", str(bundle)], check=True, capture_output=True)

    def test_adhoc_signed_bundle_passes_signature_and_entitlement_audit(self):
        self.sign_adhoc()
        result = self.run_gate("--adhoc")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Signature/entitlements: VERIFIED (ad-hoc", result.stdout)

    def test_adhoc_signature_without_hardened_runtime_is_rejected(self):
        self.sign_adhoc(runtime=False)
        self.assert_rejected("Hardened Runtime not present in signature", "--adhoc")

    def test_adhoc_gate_requires_signed_resource_bundles(self):
        self.sign_adhoc(resource_bundles=False)
        self.assert_rejected("Unsigned or invalid resource bundle signature: InspectorCore_InspectorCore.bundle", "--adhoc")

    def test_resource_bundle_signature_in_an_unsigned_bundle_is_rejected(self):
        core = self.app / "Contents/Resources/InspectorCore_InspectorCore.bundle"
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(core)], check=True, capture_output=True)
        self.assert_rejected("Unexpected InspectorCore resource bundle contents: +Contents/_CodeSignature/CodeDirectory")

    def test_debugging_entitlement_is_rejected(self):
        self.sign_adhoc()
        entitlements = plistlib.loads((ROOT / "Glimt/App/GlimtHost.entitlements").read_bytes())
        entitlements["com.apple.security.get-task-allow"] = True
        debuggable = self.case / "debuggable.entitlements"
        debuggable.write_bytes(plistlib.dumps(entitlements))
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", str(debuggable),
                        "--timestamp=none", str(self.app)], check=True, capture_output=True)
        self.assert_rejected("Development debugging entitlement in Release", "--adhoc")

    def test_adhoc_signature_does_not_pass_the_signed_gate(self):
        self.sign_adhoc()
        self.assert_rejected("A real signing identity is required", "--signed")

    def test_unsigned_bundle_fails_the_adhoc_gate(self):
        self.assert_rejected("Unsigned or invalid resource bundle signature", "--adhoc")

    # MARK: Rejected version

    def set_info(self, bundle, **values):
        path = bundle / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(values)
        path.write_bytes(plistlib.dumps(info))

    def test_extension_version_differing_from_configuration_is_rejected(self):
        self.set_info(self.thumbnail, CFBundleShortVersionString="9.9.9")
        self.assert_rejected("Version/build differs from Config/Version.xcconfig")

    def test_build_number_differing_from_configuration_is_rejected(self):
        self.set_info(self.app, CFBundleVersion="999")
        self.assert_rejected("Version/build differs from Config/Version.xcconfig")

    def test_prerelease_label_differing_from_configuration_is_rejected(self):
        self.set_info(self.app, GlimtPrerelease="rc.9")
        self.assert_rejected("Pre-release label differs from Config/Version.xcconfig")

    # MARK: Rejected resources

    def test_license_differing_from_repository_license_is_rejected(self):
        (self.app / "Contents/Resources/LICENSE").write_text("Apache License\n")
        self.assert_rejected("Bundled LICENSE differs from the repository LICENSE")

    def test_extra_inspector_core_resource_is_named_in_the_rejection(self):
        core = self.app / "Contents/Resources/InspectorCore_InspectorCore.bundle/Contents/Resources"
        (core / "stray.txt").write_text("x")
        self.assert_rejected("Unexpected InspectorCore resource bundle contents: +Contents/Resources/stray.txt")

    def test_unknown_top_level_resource_is_rejected(self):
        (self.app / "Contents/Resources/debug.log").write_text("x")
        self.assert_rejected("Unexpected or missing runtime resources")

    def test_showcase_in_an_extension_is_rejected(self):
        shutil.copytree(self.app / "Contents/Resources/Showcase", self.preview / "Contents/Resources/Showcase")
        self.assert_rejected("Unexpected or missing runtime resources")

    def test_missing_core_bundle_in_thumbnail_is_rejected(self):
        shutil.rmtree(self.thumbnail / "Contents/Resources/InspectorCore_InspectorCore.bundle")
        self.assert_rejected("Unexpected or missing runtime resources")

    def test_swiftmath_resource_is_not_allowed_in_thumbnail(self):
        shutil.copytree(self.app / "Contents/Resources/SwiftMath_SwiftMath.bundle",
                        self.thumbnail / "Contents/Resources/SwiftMath_SwiftMath.bundle")
        self.assert_rejected("Unexpected or missing runtime resources")

    def test_modified_swiftmath_font_resource_is_rejected(self):
        font = self.preview / "Contents/Resources/SwiftMath_SwiftMath.bundle/Contents/Resources/mathFonts.bundle/KpMath-Light.otf"
        font.write_bytes(font.read_bytes() + b"modified")
        self.assert_rejected("SwiftMath font resource differs from source")

    def test_swiftmath_build_helper_pruner_removes_only_generator(self):
        bundle = self.case / "SwiftMath_SwiftMath.bundle"
        helper = bundle / "Contents/Resources/mathFonts.bundle/math_table_to_plist.py"
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text("build helper")
        retained = helper.parent / "LICENSE"
        retained.write_text("license")
        subprocess.run(["bash", str(ROOT / "scripts" / "prune-swiftmath-build-helper.sh"), str(bundle)], check=True)
        self.assertFalse(helper.exists())
        self.assertEqual(retained.read_text(), "license")

    def test_pruner_reseals_a_bundle_xcode_already_signed(self):
        bundle = self.app / "Contents/Resources/SwiftMath_SwiftMath.bundle"
        helper = bundle / "Contents/Resources/mathFonts.bundle/math_table_to_plist.py"
        helper.write_text("build helper")
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], check=True, capture_output=True)
        environment = {**os.environ, "CODE_SIGNING_ALLOWED": "YES", "EXPANDED_CODE_SIGN_IDENTITY": "-"}

        subprocess.run(["bash", str(ROOT / "scripts" / "prune-swiftmath-build-helper.sh"), str(bundle)],
                       check=True, env=environment)

        self.assertFalse(helper.exists())
        subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True, capture_output=True)

    def test_app_post_embed_pruner_cleans_nested_preview_resources(self):
        app_bundle = self.app / "Contents/Resources/SwiftMath_SwiftMath.bundle"
        helper = app_bundle / "Contents/Resources/mathFonts.bundle/math_table_to_plist.py"
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text("build helper")
        nested = self.preview / "Contents/Resources/SwiftMath_SwiftMath.bundle"
        nested_helper = nested / "Contents/Resources/mathFonts.bundle/math_table_to_plist.py"
        nested_helper.parent.mkdir(parents=True, exist_ok=True)
        nested_helper.write_text("build helper")
        nested_resource = nested_helper.parent / "font.otf"
        nested_resource.write_text("font")
        nested_resource.chmod(0o755)

        subprocess.run(["bash", str(ROOT / "scripts" / "prune-swiftmath-build-helper.sh"), str(app_bundle)], check=True)

        self.assertFalse(helper.exists())
        self.assertFalse(nested_helper.exists())
        self.assertEqual(nested_resource.stat().st_mode & 0o111, 0)

    def test_extra_file_in_core_bundle_is_rejected(self):
        (self.preview / "Contents/Resources/InspectorCore_InspectorCore.bundle/Contents/Resources/fixture.json").write_text("{}")
        self.assert_rejected("Unexpected InspectorCore resource bundle contents")

    def test_executable_core_bundle_is_rejected(self):
        plist = self.app / "Contents/Resources/InspectorCore_InspectorCore.bundle/Contents/Info.plist"
        plist.write_bytes(plistlib.dumps({"CFBundlePackageType": "BNDL", "CFBundleExecutable": "tool"}))
        self.assert_rejected("InspectorCore resources must be a data-only bundle")

    def test_modified_catalog_is_rejected(self):
        (self.thumbnail / "Contents/Resources/InspectorCore_InspectorCore.bundle/Contents/Resources/formats.json").write_text("[]")
        self.assert_rejected("Format catalog differs from source")

    def test_extra_showcase_file_is_rejected(self):
        (self.app / "Contents/Resources/Showcase/json/private.json").write_text("{}")
        self.assert_rejected("Showcase differs from Fixtures/Showcase")

    def test_modified_showcase_fixture_is_rejected(self):
        (self.app / "Contents/Resources/Showcase/json/json.json").write_text("{\"changed\": true}")
        self.assert_rejected("Showcase fixture differs from source")

    # MARK: Rejected file kinds

    def test_hidden_file_is_rejected(self):
        (self.app / "Contents/Resources/Showcase/.DS_Store").write_bytes(b"\x00")
        self.assert_rejected("Hidden development file in bundle")

    def test_hidden_file_beside_a_dotfile_fixture_is_rejected(self):
        (self.app / "Contents/Resources/Showcase/config/.env").write_text("TOKEN=x\n")
        self.assert_rejected("Hidden development file in bundle")

    def test_missing_dotfile_fixture_is_rejected(self):
        (self.app / "Contents/Resources/Showcase/config/.npmrc").unlink()
        self.assert_rejected("Showcase differs from Fixtures/Showcase")

    def test_symbolic_link_is_rejected(self):
        (self.app / "Contents/Resources/Showcase/json/link.json").symlink_to("/etc/hosts")
        self.assert_rejected("Symbolic link in bundle")

    def test_executable_resource_is_rejected(self):
        os.chmod(self.app / "Contents/Resources/Showcase/source/shell.sh", 0o755)
        self.assert_rejected("Unexpected executable file")

    def test_extra_executable_in_extension_is_rejected(self):
        shutil.copy2(self.executable, self.preview / "Contents/Resources/InspectorCore_InspectorCore.bundle/Contents/helper")
        self.assert_rejected("Unexpected executable file")


class SourceTypeDeclarationTests(unittest.TestCase):
    """Catalog UTIs are declared by the app and accepted by both Quick Look extensions."""

    def test_jsonl_has_a_resolvable_type_declared_by_both_quick_look_extensions(self):
        identifier = 'com.glimt.json-lines'
        formats = json.loads((ROOT / 'InspectorCore/Sources/InspectorCore/Resources/formats.json').read_text())
        jsonl = next(row for row in formats if row['id'] == 'jsonl')
        self.assertIn(identifier, jsonl['contentTypeIdentifiers'])

        with (ROOT / 'Glimt/App/Info.plist').open('rb') as source:
            declarations = plistlib.load(source)['UTExportedTypeDeclarations']
        declaration = next(row for row in declarations if row['UTTypeIdentifier'] == identifier)
        self.assertIn('jsonl', declaration['UTTypeTagSpecification']['public.filename-extension'])
        self.assertIn('public.text', declaration['UTTypeConformsTo'])

        for extension in ('PreviewExtension', 'ThumbnailExtension'):
            with (ROOT / f'Glimt/{extension}/Info.plist').open('rb') as source:
                info = plistlib.load(source)
            content_types = info['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes']
            self.assertIn(identifier, content_types, extension)

    def test_requested_file_types_are_owned_by_catalog_and_registered_for_quick_look(self):
        expected = {
            'com.glimt.html-source': (['html', 'htm'], 'public.html'),
            'com.glimt.bezel-text': (['bezel'], 'public.plain-text'),
            'com.glimt.clojure-source': (['bb', 'cli', 'clj', 'cljc', 'cljs', 'edn'], 'public.source-code'),
            'com.glimt.cpp-source': (['cp', 'c++', 'ipp'], 'public.c-plus-plus-source'),
            'com.glimt.cuda-source': (['cu'], 'public.c-plus-plus-source'),
            'com.glimt.csh-source': (['csh'], 'public.source-code'),
            'com.glimt.csharp-source': (['cs'], 'public.source-code'),
            'com.glimt.cmake-source': (['cmake'], 'public.source-code'),
            'com.glimt.cocoapods-spec': (['podspec'], 'public.source-code'),
            'com.glimt.coffeescript-source': (['coffee'], 'public.source-code'),
            'com.glimt.coldfusion-source': (['cfc', 'cfm', 'cfml'], 'public.source-code'),
            'com.glimt.crystal-source': (['cr'], 'public.source-code'),
            'com.glimt.cson-source': (['cson'], 'public.source-code'),
            'com.glimt.css-source': (['css'], 'public.source-code'),
            'com.glimt.bibtex-source': (['bib'], 'public.source-code'),
            'com.glimt.configuration-text': (['conf'], 'public.text'),
            'com.glimt.mobileconfig-xml': (['mobileconfig'], 'public.xml'),
            'com.glimt.sql-source': (['sql'], 'public.source-code'),
            'com.glimt.rust-source': (['rs'], 'public.source-code'),
            'com.glimt.php-source': (['php', 'php3', 'php4', 'php5', 'php6', 'php7', 'phps', 'phpt'], 'public.source-code'),
            'com.glimt.ruby-source': (['rb', 'rbx', 'ruby', 'rake', 'gemspec', 'jbuilder', 'prawn', 'rabl', 'rjs', 'thor', 'fcgi'], 'public.source-code'),
            'com.glimt.objective-c-source': (['mm'], 'public.source-code'),
            'com.glimt.ocaml-source': (['ml', 'mli'], 'public.source-code'),
            'com.glimt.tcl-source': (['tcl', 'tk', 'itcl', 'wish'], 'public.source-code'),
            'com.glimt.applescript-source': (['applescript'], 'public.source-code'),
            'com.glimt.perl-source': (['pl', 'pm', 'cgi', 'plex', 'plx'], 'public.source-code'),
            'com.glimt.r-source': (['r', 'R'], 'public.source-code'),
            'com.glimt.scala-source': (['scala'], 'public.source-code'),
            'com.glimt.julia-source': (['jl'], 'public.source-code'),
            'com.glimt.terraform-source': (['tf', 'tfvars'], 'public.source-code'),
            'com.glimt.scss-source': (['scss'], 'public.source-code'),
            'com.glimt.tsx-source': (['tsx'], 'public.source-code'),
            'com.glimt.vue-source': (['vue'], 'public.source-code'),
            'com.glimt.svelte-source': (['svelte'], 'public.source-code'),
            'com.glimt.asciidoc': (['adoc', 'asciidoc'], 'public.text'),
        }
        rows = json.loads((ROOT / 'InspectorCore/Sources/InspectorCore/Resources/formats.json').read_text())
        catalog_types = {identifier for row in rows if row['status'] == 'supported'
                         for identifier in row['contentTypeIdentifiers']}
        with (ROOT / 'Glimt/App/Info.plist').open('rb') as source:
            declarations = plistlib.load(source)['UTExportedTypeDeclarations']
        by_identifier = {row['UTTypeIdentifier']: row for row in declarations}
        self.assertEqual(len(by_identifier), len(declarations))

        for identifier, (extensions, parent) in expected.items():
            self.assertIn(identifier, catalog_types)
            declaration = by_identifier[identifier]
            tags = declaration['UTTypeTagSpecification']['public.filename-extension']
            self.assertEqual(tags, extensions, identifier)
            self.assertIn(parent, declaration['UTTypeConformsTo'], identifier)
            for extension in ('PreviewExtension', 'ThumbnailExtension'):
                with (ROOT / f'Glimt/{extension}/Info.plist').open('rb') as source:
                    info = plistlib.load(source)
                supported = info['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes']
                self.assertIn(identifier, supported, extension)


if __name__ == "__main__":
    unittest.main()
