#!/usr/bin/env python3
"""Bind independently compiled macOS components to one reviewed source snapshot."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RETIRED = {'reactiveui', 'reactiveui.sourcegenerators', 'qrcoder', 'zxing.net.bindings.skiasharp', 'taskscheduler'}

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
    prefixes = {'backend': ('v2rayN/ServiceLib/', 'v2rayN/ServiceLib.UdpTest/', 'v2rayN/v2rayN.WebAPI/', 'v2rayN/Directory.', 'global.json', 'contracts/'),
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
        raise ValueError('Source tree changed since backend build. Rebuild the complete product; mixed-source packaging is refused.')
    return current

def verify_backend(backend, root=ROOT):
    receipt = json.loads((backend / 'v2raym-backend-build.json').read_text())
    if receipt.get('schema') != 1: raise ValueError('Unsupported backend provenance schema')
    assert_source(receipt['source'], root)
    if sha(backend / 'v2rayN.WebAPI') != receipt['backendSHA256']: raise ValueError('Backend executable differs from its build receipt')
    return receipt

def verify_dependencies(root=ROOT):
    assets = json.loads((root / 'v2rayN/v2rayN.WebAPI/obj/project.assets.json').read_text())
    bad = sorted(key.split('/')[0] for key in assets['libraries'] if key.split('/')[0].lower() in RETIRED)
    if bad: raise ValueError('Retired desktop packages in published backend graph: ' + ', '.join(bad))

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
    for name, checksum in pin['patches'].items():
        if sha(root / 'patches/xray' / name) != checksum: raise ValueError('Reviewed core patch changed: ' + name)
    return {'versionOutput': output, 'SHA256': sha(core), 'source': metadata, 'toolchain': inputs['goVersion']}

def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')

def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest='action', required=True)
    snapshot = sub.add_parser('snapshot'); snapshot.add_argument('--output', type=Path, required=True); snapshot.add_argument('--dotnet', default='dotnet')
    core = sub.add_parser('verify-core'); core.add_argument('--core-bin', type=Path, required=True)
    record = sub.add_parser('record-backend'); record.add_argument('--snapshot', type=Path, required=True); record.add_argument('--backend', type=Path, required=True)
    verify = sub.add_parser('verify-backend'); verify.add_argument('--backend', type=Path, required=True)
    app = sub.add_parser('write-app'); app.add_argument('--backend', type=Path, required=True); app.add_argument('--app', type=Path, required=True)
    check = sub.add_parser('verify-app'); check.add_argument('--app', type=Path, required=True)
    seal = sub.add_parser('seal-app'); seal.add_argument('--app', type=Path, required=True); seal.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'snapshot':
        write_json(args.output, {'schema': 1, 'source': source_snapshot(), 'toolchains': {
            'dotnet': command([args.dotnet, '--version']), 'swift': command(['swift', '--version']),
            'clang': command(['xcrun', 'clang', '--version']), 'macOS': command(['sw_vers', '-productVersion'])}})
    elif args.action == 'verify-core': verify_core_input(args.core_bin)
    elif args.action == 'record-backend':
        receipt = json.loads(args.snapshot.read_text()); assert_source(receipt['source']); verify_dependencies()
        receipt['backendSHA256'] = sha(args.backend / 'v2rayN.WebAPI')
        write_json(args.backend / 'v2raym-backend-build.json', receipt)
    elif args.action == 'verify-backend': verify_backend(args.backend)
    elif args.action == 'write-app':
        receipt = verify_backend(args.backend)
        # The app's main executable signature includes CodeResources, which includes
        # this manifest. Its final hash belongs in the external seal, never itself.
        binaries = ['Contents/MacOS/V2rayMHelper', 'Contents/MacOS/V2rayMHelperClient',
                    'Contents/Resources/Backend/v2rayN.WebAPI', 'Contents/Resources/Backend/bin/xray/xray']
        plist = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
        if plist['CFBundleShortVersionString'] != receipt['source']['version'] or plist['CFBundleVersion'] != receipt['source']['version']:
            raise ValueError('Application display/build versions differ from VERSION')
        core = args.app / binaries[-1]
        receipt['core'] = verify_core_input(core.parent.parent)
        data_root = core.parent.parent
        receipt['runtimeData'] = {'SHA256': {name: sha(data_root / name) for name in ('geoip.dat', 'geosite.dat')}}
        data_origin = data_root / 'core-bundle-source.json'
        if data_origin.exists():
            origin = json.loads(data_origin.read_text())
            if any(origin['files'].get(name) != checksum for name, checksum in receipt['runtimeData']['SHA256'].items()):
                raise ValueError('Runtime Geo DAT differs from core bundle receipt')
            receipt['runtimeData']['origin'] = origin
        else:
            receipt['runtimeData']['origin'] = 'Existing explicit local input; hashes recorded without upstream origin claim'
        source = core.with_name('SOURCE.txt')
        if source.exists(): receipt['core']['provenance'] = source.read_text()
        receipt['mainExecutableDigest'] = 'Recorded after bundle signing in external product-manifest.json'
        receipt['inputs'] = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())
        receipt['artifacts'] = {name: sha(args.app / name) for name in binaries}
        resources = args.app / 'Contents/Resources/V2rayMNative_V2rayM.bundle'
        geo = next(resources.rglob('geodata-manifest.json'))
        receipt['geolocation'] = json.loads(geo.read_text())
        receipt['resourceDigests'] = {str(path.relative_to(args.app)): sha(path) for path in resources.rglob('*') if path.is_file()}
        receipt['verification'] = {'signature': 'verify externally after bundle signing', 'realTUN': False, 'notarized': False}
        write_json(args.app / 'Contents/Resources/build-manifest.json', receipt)
    elif args.action in {'verify-app', 'seal-app'}:
        receipt = json.loads((args.app / 'Contents/Resources/build-manifest.json').read_text()); assert_source(receipt['source'])
        for name, expected in (receipt['artifacts'] | receipt['resourceDigests']).items():
            if sha(args.app / name) != expected: raise ValueError('Packaged artifact changed: ' + name)
        if args.action == 'seal-app':
            receipt['signedArtifacts'] = {str(path.relative_to(args.app)): sha(path) for path in args.app.rglob('*') if path.is_file()}
            write_json(args.output, receipt)
    print('macOS build provenance verified: ' + args.action)
if __name__ == '__main__': main()
