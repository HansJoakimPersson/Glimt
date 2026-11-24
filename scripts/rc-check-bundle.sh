#!/usr/bin/env bash
# Read-only, Glimt-specific RC artifact checks. This never launches an app or accesses a container.
# --signed (default) requires a real signing identity; --adhoc audits an ad-hoc signature and its
# entitlements; --unsigned skips signature checks.
set -euo pipefail
mode=signed
case "${1:-}" in
    --unsigned) mode=unsigned; shift ;;
    --adhoc) mode=adhoc; shift ;;
    --signed) shift ;;
esac
[[ "$#" == 1 ]] || { printf 'Usage: rc-check-bundle.sh [--signed|--adhoc|--unsigned] /path/to/Glimt.app\n' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(bash "$root/scripts/version.sh")"
python3 - "$mode" "$1" "$root" "$version" <<'PY'
import json, os, pathlib, plistlib, re, stat, subprocess, sys
mode, argument, root, version = sys.argv[1:]
version = dict(line.split('=', 1) for line in version.splitlines())
app = pathlib.Path(argument).resolve()
root = pathlib.Path(root)
def require(condition, message):
    if not condition:
        raise SystemExit('RC BUNDLE FAIL: ' + message)
def info(bundle):
    return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
def command(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)
def files_under(directory):
    return {p.relative_to(directory).as_posix(): p for p in directory.rglob('*') if not p.is_dir()}
def showcase_sources():
    # The reviewed Showcase fixtures, including dotfile formats such as `.npmrc`; Finder metadata is not one.
    return {k: v for k, v in files_under(root/'Fixtures/Showcase').items() if pathlib.PurePosixPath(k).name != '.DS_Store'}
def audit_tree(bundle, executable, skip=None, allowed_hidden=frozenset()):
    # Every entry must be a plain directory or regular file; only the main executable may be executable.
    for path in bundle.rglob('*'):
        if skip is not None and (path == skip or skip in path.parents):
            continue
        mode_bits = os.lstat(path).st_mode
        require(not stat.S_ISLNK(mode_bits), 'Symbolic link in bundle')
        require(stat.S_ISDIR(mode_bits) or stat.S_ISREG(mode_bits), 'Special file in bundle')
        require(not path.name.startswith('.') or path in allowed_hidden, 'Hidden development file in bundle')
        if stat.S_ISREG(mode_bits) and mode_bits & 0o111:
            require(path == executable, 'Unexpected executable file')
def signature_files(bundle):
    # Signed builds seal each nested data bundle with its own signature; unsigned builds carry none.
    if mode == 'unsigned':
        return set()
    verified = subprocess.run(['codesign', '--verify', '--strict', str(bundle)], capture_output=True).returncode == 0
    require(verified, 'Unsigned or invalid resource bundle signature: ' + bundle.name)
    return {f'Contents/_CodeSignature/{name}' for name in ('CodeDirectory', 'CodeRequirements', 'CodeResources', 'CodeSignature')}
def audit_core_resources(resources):
    # SwiftPM resource bundle for InspectorCore: the format catalog only, identical to its source.
    bundle = resources/'InspectorCore_InspectorCore.bundle'
    found = set(files_under(bundle))
    expected = {'Contents/Info.plist', 'Contents/Resources/formats.json'} | signature_files(bundle)
    difference = ' '.join(sorted(['+' + p for p in found - expected] + ['-' + p for p in expected - found]))
    require(found == expected, 'Unexpected InspectorCore resource bundle contents: ' + difference)
    data = info(bundle)
    require(data.get('CFBundlePackageType') == 'BNDL' and 'CFBundleExecutable' not in data, 'InspectorCore resources must be a data-only bundle')
    catalog = (bundle/'Contents/Resources/formats.json').read_bytes()
    json.loads(catalog)
    require(catalog == (root/'InspectorCore/Sources/InspectorCore/Resources/formats.json').read_bytes(), 'Format catalog differs from source')
def audit_swiftmath_resources(resources):
    # SwiftMath's offline math fonts are data resources shared by the host and preview extension.
    bundle = resources/'SwiftMath_SwiftMath.bundle'
    packages = pathlib.Path(os.environ.get('GLIMT_CLONED_SOURCE_PACKAGES_DIR', root/'build/SourcePackages'))
    source = packages/'checkouts/SwiftMath/Sources/SwiftMath/mathFonts.bundle'
    source_files = {p.relative_to(source).as_posix(): p for p in source.rglob('*') if p.is_file() and p.name != 'math_table_to_plist.py'}
    expected = {'Contents/Info.plist'} | {f'Contents/Resources/mathFonts.bundle/{name}' for name in source_files}
    expected |= signature_files(bundle)
    shipped = files_under(bundle)
    require(set(shipped) == expected, 'Unexpected SwiftMath resource bundle contents')
    data = info(bundle)
    require(data.get('CFBundlePackageType') == 'BNDL' and 'CFBundleExecutable' not in data, 'SwiftMath resources must be a data-only bundle')
    for name, source_file in source_files.items():
        bundled = bundle/'Contents/Resources/mathFonts.bundle'/name
        require(bundled.read_bytes() == source_file.read_bytes(), 'SwiftMath font resource differs from source')
def audit_showcase(resources):
    # Showcase previews in the host app: exactly the reviewed fixtures, byte for byte, small and inert.
    shipped = files_under(resources/'Showcase')
    source = showcase_sources()
    require(set(shipped) == set(source), 'Showcase differs from Fixtures/Showcase')
    for name, path in shipped.items():
        require(path.stat().st_size <= 65_536, 'Oversized Showcase fixture')
        require(path.read_bytes() == source[name].read_bytes(), 'Showcase fixture differs from source')
try:
    bundles = [app, app/'Contents/PlugIns/GlimtPreview.appex', app/'Contents/PlugIns/GlimtThumbnail.appex']
    ids = ['com.glimt.app', 'com.glimt.app.preview', 'com.glimt.app.thumbnail']
    expected = {p.name for p in bundles[1:]}
    require({p.name for p in (app/'Contents/PlugIns').iterdir()} == expected, 'Unexpected embedded component')
    for index, (bundle, identifier) in enumerate(zip(bundles, ids)):
        data = info(bundle)
        require({p.name for p in bundle.iterdir()} == {'Contents'}, 'Unexpected bundle-root material')
        allowed_contents = {'Info.plist', 'PkgInfo', 'MacOS', 'Resources', '_CodeSignature', 'embedded.provisionprofile'}
        if index == 0:
            allowed_contents.add('PlugIns')
        require({p.name for p in (bundle/'Contents').iterdir()} <= allowed_contents, 'Unexpected runtime component')
        require({p.name for p in (bundle/'Contents/MacOS').iterdir()} == {data['CFBundleExecutable']}, 'Unexpected executable/helper')
        require(data.get('CFBundleIdentifier') == identifier, 'Unexpected bundle identifier')
        require(data.get('CFBundleShortVersionString') == version['MARKETING_VERSION']
                and data.get('CFBundleVersion') == version['BUILD_NUMBER'], 'Version/build differs from Config/Version.xcconfig')
        require(data.get('LSMinimumSystemVersion') == '15.0', 'Unexpected deployment target')
        require('GlimtAppGroupIdentifier' not in data, 'Obsolete App Group setting configuration')
        resources = bundle/'Contents/Resources'
        allowed = {'ThirdPartyNotices.txt', 'InspectorCore_InspectorCore.bundle', 'GlimtBuildProvenance.plist'}
        if index == 0:
            allowed |= {'LICENSE', 'AppIcon.icns', 'Assets.car', 'Showcase'}
        if index < 2:
            allowed.add('SwiftMath_SwiftMath.bundle')
        require({p.name for p in resources.iterdir()} == allowed, 'Unexpected or missing runtime resources')
        showcase = resources/'Showcase'
        hidden = frozenset(showcase/name for name in showcase_sources()) if index == 0 else frozenset()
        audit_tree(bundle, bundle/'Contents/MacOS'/data['CFBundleExecutable'], skip=bundle/'Contents/PlugIns' if index == 0 else None,
                   allowed_hidden=hidden)
        audit_core_resources(resources)
        if index < 2:
            audit_swiftmath_resources(resources)
        if index == 0:
            audit_showcase(resources)
        notices = (resources/'ThirdPartyNotices.txt').read_text()
        require('MermaidKit 2.10.2' in notices, 'Missing MermaidKit license notice')
        require('Yams 6.2.2' in notices and 'libyaml' in notices, 'Missing dependency notices')
        executable = bundle/'Contents/MacOS'/data['CFBundleExecutable']
        raw = executable.read_bytes()
        for marker in [b'GLIMT_PREVIEW_BEGIN', b'FR005_PROVIDER_V1', b'Choose Fixtures Folder', b'Preview diagnostics']:
            require(marker not in raw, 'Development-only UI/instrumentation in Release')
        links = command('otool', '-L', str(executable)).decode()
        for line in links.splitlines():
            if not line.startswith('\t'):
                continue  # Universal binaries have one header per architecture.
            dependency = line.strip().split(' (', 1)[0]
            require(dependency.startswith(('/System/Library/', '/usr/lib/')), 'Unexpected bundled/external dynamic dependency')
        linked_frameworks = ['WebKit.framework', 'Network.framework', 'JavaScriptCore.framework']
        require(not any(name in links for name in linked_frameworks[1:]), 'Unexpected network/JavaScriptCore framework')
        require('WebKit.framework' not in links or index < 2, 'WebKit is allowed only for the host and Preview renderer')
        symbols = command('nm', '-u', str(executable)).decode()
        require(not re.search(r'\b_(?:system|popen|execve|execv|posix_spawn|fork|vfork)\s*$', symbols, re.M), 'Unexpected process-launch entry point')
        if mode in ('signed', 'adhoc'):
            command('codesign', '--verify', '--strict', str(bundle))
            details = command('codesign', '-dvvv', str(bundle)).decode()
            require(re.search(r'flags=.*\bruntime\b', details), 'Hardened Runtime not present in signature')
            require(mode == 'adhoc' or 'Signature=adhoc' not in details and 'TeamIdentifier=not set' not in details and 'Authority=' in details, 'A real signing identity is required')
            entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], stderr=subprocess.DEVNULL))
            require(entitlements.get('com.apple.security.app-sandbox') is True, 'Sandbox missing')
            read_only = 'com.apple.security.temporary-exception.files.home-relative-path.read-only'
            read_write = 'com.apple.security.temporary-exception.files.home-relative-path.read-write'
            # ADR-038: host and Preview read repository metadata anywhere; Thumbnail never inspects VCS.
            repository_read = 'com.apple.security.temporary-exception.files.absolute-path.read-only'
            # The host needs the settings directory to create it on first save; extensions only read the file.
            if index == 0:
                file_access = {read_write: ['/Library/Application Support/Glimt/', '/Library/Logs/Glimt/'],
                               repository_read: ['/']}
                permitted = {'com.apple.security.app-sandbox', 'com.apple.security.files.user-selected.read-only'}
            else:
                file_access = {read_only: ['/Library/Application Support/Glimt/settings.json'],
                               read_write: ['/Library/Logs/Glimt/']}
                if index == 1:
                    file_access[repository_read] = ['/']
                permitted = {'com.apple.security.app-sandbox'}
            permitted |= set(file_access)
            capabilities = {k for k, v in entitlements.items() if k.startswith('com.apple.security.') and v}
            debuggable = entitlements.get('com.apple.security.get-task-allow') or entitlements.get('get-task-allow')
            require(not debuggable, 'Development debugging entitlement in Release')
            require(capabilities <= permitted, 'Unexpected security capability')
            require('com.apple.security.application-groups' not in entitlements, 'App Group entitlement remains')
            require(all(sorted(entitlements.get(key, [])) == sorted(paths) for key, paths in file_access.items()),
                    'Settings and log access are not limited to the canonical paths')
    preview = info(bundles[1])['NSExtension']
    types = preview['NSExtensionAttributes']['QLSupportedContentTypes']
    require('public.data' not in types and 'public.mpeg-2-transport-stream' not in types, 'Overbroad Quick Look claims')
    require(preview['NSExtensionPointIdentifier'] == 'com.apple.quicklook.preview', 'Invalid Quick Look entry point')
    require(info(app).get('GlimtPrerelease', None) == version['PRERELEASE'], 'Pre-release label differs from Config/Version.xcconfig')
    require(info(app).get('CFBundleIconFile') == 'AppIcon' and info(app).get('NSHumanReadableCopyright'), 'App identity missing')
    require((app/'Contents/Resources/AppIcon.icns').read_bytes().startswith(b'icns'), 'Invalid icon resource')
    license = app/'Contents/Resources/LICENSE'
    require(license.is_file() and license.read_bytes() == (root/'LICENSE').read_bytes(), 'Bundled LICENSE differs from the repository LICENSE')
except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
    raise SystemExit('RC BUNDLE FAIL: artifact/tool check failed (' + type(error).__name__ + ')')
print('Glimt release artifact: PASS; version=' + version['SEMVER'] + ' build=' + version['BUILD_NUMBER'] + '; intended components/resources (catalog, Showcase); no links or stray executables; native dynamic dependencies; dependency notices')
print('Bundle configuration: READY')
print('Signature/entitlements: ' + {'signed': 'VERIFIED', 'adhoc': 'VERIFIED (ad-hoc signature; no Developer ID, not notarized)',
                                   'unsigned': 'UNVERIFIED — unsigned check'}[mode])
print('Settings file access and Finder routing: require the separate signed acceptance pass; never inferred from this check')
PY
