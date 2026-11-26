#!/usr/bin/env python3
"""Bind independently compiled macOS components to one reviewed source snapshot."""
import argparse
import hashlib
import json
from pathlib import Path
import os
import plistlib
import re
import subprocess
from xray_build_inputs import verified_patch_names

ROOT = Path(__file__).resolve().parents[1]
def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''): digest.update(block)
    return digest.hexdigest()

def command(args, root=ROOT):
    return subprocess.check_output(args, cwd=root, text=True).strip()

def source_snapshot(root=ROOT):
    version = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(r'[0-9]\.[0-9]\.[0-9]', version): raise ValueError('VERSION must contain three single-digit components')
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
    files = {}
    for name in sorted(set(filter(None, names))):
        path = root / name
        if path.is_file(): files[name] = sha(path)
    def digest(selected):
        return hashlib.sha256(json.dumps(selected, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    prefixes = {'xray': ('scripts/xray/library/', 'patches/xray/', 'contracts/macos-build-inputs.json'),
                'native': ('macos/Native/',), 'helper': ('macos/TunHelper/', 'macos/Resources/', 'contracts/'),
                'build': ('scripts/', '.github/', 'VERSION')}
    components = {key: digest({name: value for name, value in files.items() if name.startswith(prefix)}) for key, prefix in prefixes.items()}
    status = command(['git', 'status', '--porcelain', '--untracked-files=all'], root)
    diff = subprocess.check_output(['git', 'diff', '--binary', 'HEAD', '--'], cwd=root)
    untracked = command(['git', 'ls-files', '--others', '--exclude-standard'], root).splitlines()
    dirty_digest = hashlib.sha256(diff + json.dumps({name: files.get(name) for name in untracked}, sort_keys=True).encode()).hexdigest()
    return {'version': version, 'commit': command(['git', 'rev-parse', 'HEAD'], root), 'dirty': bool(status),
            'dirtyDigest': dirty_digest, 'sourceDigest': digest(files), 'componentSourceDigests': components}

def assert_source(expected, root=ROOT):
    current = source_snapshot(root)
    if expected['sourceDigest'] != current['sourceDigest'] or expected['version'] != current['version']:
        raise ValueError('Source tree changed since the build snapshot. Rebuild the complete product; mixed-source packaging is refused.')
    return current

def verify_core_input(core_bin, root=ROOT, version_output=None):
    inputs = json.loads((root / 'contracts/macos-build-inputs.json').read_text())
    pin = inputs['xray']; core = core_bin / 'xray/xray'
    output = version_output if version_output is not None else command([str(core.resolve()), 'version'])
    if not output.startswith('Xray ' + pin['version'] + ' ') or not re.search(r'(?<!\S)' + re.escape(pin['buildMarker']) + r'(?!\S)', output):
        raise ValueError('Core input is not the reviewed Xray Darwin M2 repair')
    if '(go' + inputs['goVersion'] + ' darwin/' not in output:
        raise ValueError('Core input was built with an unreviewed toolchain')
    metadata = dict(line.split(': ', 1) for line in (core.with_name('SOURCE.txt')).read_text().splitlines() if ': ' in line)
    expected = {'Xray source': pin['revision'], 'Archive SHA256': pin['sourceSHA256'],
                'Patches': ', '.join(pin['patches']), 'Build': pin['buildMarker']}
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError('Core SOURCE provenance differs from reviewed source and patches')
    verified_patch_names(root, inputs, library=False)
    return {'versionOutput': output, 'SHA256': sha(core), 'source': metadata, 'toolchain': inputs['goVersion']}

LIBRARY_PATH = 'Contents/Frameworks/libV2rayMXray.dylib'

def verify_library_input(library, root=ROOT):
    pin = json.loads((root / 'contracts/macos-build-inputs.json').read_text())
    receipt = json.loads(library.with_name('library-build.json').read_text())
    verified_patch_names(root, pin, library=True)
    if receipt != {'inputs': pin['xray'], 'libraryPatches': pin['xrayLibraryPatches'], 'goVersion': pin['goVersion'],
                   'bridgeSources': {p.name: sha(p) for p in (root / 'scripts/xray/library').glob('*.go')}, 'binarySHA256': sha(library)}:
        raise ValueError('Embedded Xray library differs from pinned build inputs or build digest')
    return receipt

def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')

def verified_runtime_data(directory, inputs):
    digests = {}
    for name in ('geoip.dat', 'geosite.dat'):
        digests[name] = sha(directory / name)
        if digests[name] != inputs['coreBundleDataSHA256'][name]:
            raise ValueError('Runtime Geo DAT differs from pinned data: ' + name)
    origin = {'repository': '2dust/v2rayN-core-bin', 'commit': inputs['coreBundleCommit']}
    receipt_path = directory / 'core-bundle-source.json'
    if receipt_path.exists():
        supplied = json.loads(receipt_path.read_text())
        if (any(supplied.get(key) != value for key, value in origin.items())
                or any(supplied.get('files', {}).get(key) != value for key, value in digests.items())):
            raise ValueError('Runtime Geo DAT origin differs from the reviewed core bundle')
        origin = supplied
    return {'SHA256': digests, 'origin': origin}

def verify_app_files(app, receipt, inputs=None):
    permitted = {'MacOS': {'V2rayM', 'V2rayMHelper'}, 'Frameworks': {'libV2rayMXray.dylib'}}
    for directory, names in permitted.items():
        folder = app / 'Contents' / directory
        if folder.exists() and any(path.name not in names for path in folder.iterdir()):
            raise ValueError('Unexpected executable or framework in ' + directory)
    for path in app.rglob('*'):
        name = path.name.lower()
        if path.is_file() and name in {'xray', 'v2raymhelperclient'}:
            raise ValueError('Unexpected standalone process in native package: ' + str(path.relative_to(app)))
        if name == 'dotnet' or name.startswith(('servicelib.', 'v2rayn.webapi', 'libcoreclr', 'libhostfxr', 'libhostpolicy')) or name.endswith(('.dll', '.runtimeconfig.json', '.deps.json')):
            raise ValueError('Unexpected managed runtime in native package: ' + str(path.relative_to(app)))
    plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(plist.get(key) != receipt['source']['version'] for key in ('CFBundleShortVersionString', 'CFBundleVersion')):
        raise ValueError('Application display/build versions differ from VERSION')
    executable = app / 'Contents/MacOS/V2rayM'
    if (plist.get('CFBundleExecutable') != executable.name or executable.is_symlink()
            or not executable.is_file() or not os.access(executable, os.X_OK)):
        raise ValueError('Missing or invalid CFBundleExecutable: V2rayM')
    if inputs is None:
        inputs = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())
    data_root = app / 'Contents/Resources/Backend/bin'
    if receipt.get('runtimeData') != verified_runtime_data(data_root, inputs):
        raise ValueError('Packaged Geo digests or origin differ from the reviewed data')
    if LIBRARY_PATH not in receipt['artifacts']:
        raise ValueError('Embedded Xray library digest missing from application')
    expected_files = receipt['artifacts'] | receipt['resourceDigests']
    for name, expected in expected_files.items():
        if sha(app / name) != expected: raise ValueError('Packaged artifact changed: ' + name)

def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest='action', required=True)
    snapshot = sub.add_parser('snapshot'); snapshot.add_argument('--output', type=Path, required=True)
    core = sub.add_parser('verify-core'); core.add_argument('--core-bin', type=Path, required=True)
    library = sub.add_parser('verify-library'); library.add_argument('--library', type=Path, required=True)
    app = sub.add_parser('write-app'); app.add_argument('--snapshot', type=Path, required=True); app.add_argument('--app', type=Path, required=True)
    check = sub.add_parser('verify-app'); check.add_argument('--app', type=Path, required=True)
    seal = sub.add_parser('seal-app'); seal.add_argument('--app', type=Path, required=True); seal.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'snapshot':
        write_json(args.output, {'schema': 1, 'source': source_snapshot(), 'toolchains': {
            'swift': command(['swift', '--version']),
            'clang': command(['xcrun', 'clang', '--version']), 'macOS': command(['sw_vers', '-productVersion'])}})
    elif args.action == 'verify-core': verify_core_input(args.core_bin)
    elif args.action == 'verify-library': verify_library_input(args.library)
    elif args.action == 'write-app':
        receipt = json.loads(args.snapshot.read_text())
        assert_source(receipt['source'])
        # The app's main executable signature includes CodeResources, which includes
        # this manifest. Its final hash belongs in the external seal, never itself.
        binaries = [LIBRARY_PATH, 'Contents/MacOS/V2rayMHelper']
        plist = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        if plist['CFBundleShortVersionString'] != receipt['source']['version'] or plist['CFBundleVersion'] != receipt['source']['version']:
            raise ValueError('Application display/build versions differ from VERSION')
        library_info = args.app / 'Contents/Resources/Xray/library-build.json'
        receipt['core'] = json.loads(library_info.read_text())
        data_root = args.app / 'Contents/Resources/Backend/bin'
        receipt['inputs'] = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())
        receipt['runtimeData'] = verified_runtime_data(data_root, receipt['inputs'])
        receipt['mainExecutableDigest'] = 'Recorded after bundle signing in external product-manifest.json'
        receipt['artifacts'] = {name: sha(args.app / name) for name in binaries}
        resources = args.app / 'Contents/Resources/V2rayMNative_V2rayM.bundle'
        geo = next(resources.rglob('geodata-manifest.json'))
        receipt['geolocation'] = json.loads(geo.read_text())
        kit = resources.with_name('V2rayMNative_V2rayMKit.bundle')
        if not any(kit.rglob('RuntimeDefaults/settings.json')):
            raise ValueError('Native runtime defaults missing from app')
        receipt['resourceDigests'] = {str(path.relative_to(args.app)): sha(path)
                                      for bundle in (resources, kit) for path in bundle.rglob('*') if path.is_file()}
        receipt['verification'] = {'signature': 'verify externally after bundle signing', 'realTUN': False, 'notarized': False}
        write_json(args.app / 'Contents/Resources/build-manifest.json', receipt)
    elif args.action in {'verify-app', 'seal-app'}:
        receipt = json.loads((args.app / 'Contents/Resources/build-manifest.json').read_text()); assert_source(receipt['source'])
        verify_app_files(args.app, receipt)
        if args.action == 'seal-app':
            receipt['signedArtifacts'] = {str(path.relative_to(args.app)): sha(path) for path in args.app.rglob('*') if path.is_file()}
            write_json(args.output, receipt)
    print('macOS build provenance verified: ' + args.action)
if __name__ == '__main__': main()
