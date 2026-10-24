#!/usr/bin/env python3
"""Build one source-consistent signed native product. Never installs or alters networking."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New product directory; existing outputs are never replaced')
    parser.add_argument('--core-bin', type=Path, required=True, help='Verified Xray and Geo DAT input directory')
    parser.add_argument('--dotnet', default='dotnet')
    parser.add_argument('--skip-smoke', action='store_true', help='Build only; verification receipt records smoke as not run')
    args = parser.parse_args()
    if platform.system() != 'Darwin': parser.error('Build on macOS')
    if args.output.exists(): parser.error('Output must not exist')
    core_bin = args.core_bin.resolve()
    for name in ['xray/xray', 'geoip.dat', 'geosite.dat']:
        if not (core_bin / name).is_file(): parser.error('Missing core input: ' + name)
    output = args.output.resolve(); output.mkdir(parents=True)
    env = os.environ.copy(); env['CORE_BIN_DIR'] = str(core_bin)
    env['APP_VERSION'] = env['APP_BUILD'] = (ROOT / 'VERSION').read_text().strip()
    env['NATIVE_SCRATCH_PATH'] = str(output / 'native-build'); env['SWIFT_SCRATCH_PATH'] = str(output / 'helper-build')
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'module-cache')
    def run(command): subprocess.run([str(x) for x in command], cwd=ROOT, env=env, check=True)
    manifest = ROOT / 'scripts/macos-build-manifest.py'
    run([sys.executable, manifest, 'verify-core', '--core-bin', core_bin])
    run([sys.executable, ROOT / 'scripts/check-macos-product-boundaries.py'])
    run([sys.executable, ROOT / 'scripts/generate-helper-contract.py', '--check'])
    geo = ROOT / 'scripts/prepare-macos-geo.py'
    if subprocess.run([sys.executable, str(geo), '--verify-only'], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        run([sys.executable, geo])
    snapshot = output / 'source-snapshot.json'
    run([sys.executable, manifest, 'snapshot', '--output', snapshot, '--dotnet', args.dotnet])
    source = json.loads(snapshot.read_text())['source']
    rid = 'osx-arm64' if platform.machine() == 'arm64' else 'osx-x64'
    backend = output / 'backend'
    run([args.dotnet, 'publish', ROOT / 'v2rayN/v2rayN.WebAPI/v2rayN.WebAPI.csproj', '--configuration', 'Release',
         '--runtime', rid, '--self-contained', 'true', '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true',
         '-p:WebVersion=' + source['version'], '-p:WebCommit=' + source['commit'], '-p:WebRepository=' + os.environ.get('GITHUB_REPOSITORY', 'CJMVPU/v2rayM'), '--output', backend])
    run([sys.executable, manifest, 'record-backend', '--snapshot', snapshot, '--backend', backend])
    app = output / 'v2rayM.app'
    run(['bash', ROOT / 'scripts/package-macos-app.sh', backend, app])
    run([sys.executable, manifest, 'verify-app', '--app', app])
    if not args.skip_smoke:
        run(['swift', 'build', '--disable-sandbox', '--package-path', ROOT / 'macos/Native', '--scratch-path', env['NATIVE_SCRATCH_PATH'], '--configuration', 'release', '--product', 'V2rayMCheck'])
        binary = subprocess.check_output(['swift', 'build', '--package-path', str(ROOT / 'macos/Native'), '--scratch-path', env['NATIVE_SCRATCH_PATH'], '--configuration', 'release', '--show-bin-path'], text=True, env=env).strip()
        run([sys.executable, ROOT / 'scripts/smoke-macos-app.py', app, Path(binary) / 'V2rayMCheck'])
    run([sys.executable, manifest, 'verify-app', '--app', app])
    run([sys.executable, manifest, 'seal-app', '--app', app, '--output', output / 'product-manifest.json'])
    (output / 'verification.json').write_text(json.dumps({'productVersion': source['version'], 'sourceDigest': source['sourceDigest'],
        'build': 'passed', 'signature': 'passed', 'packagedLoopbackSmoke': 'not run' if args.skip_smoke else 'passed',
        'installed': False, 'realTUN': False, 'notarized': False}, indent=2) + '\n')
    print('Verified local product: ' + str(app))
if __name__ == '__main__': main()
