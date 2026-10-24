#!/usr/bin/env python3
"""Extract only Xray and DAT data from a commit-pinned shared backend bundle."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[3]
BUNDLES = {
    'linux-x64': 'v2rayN-linux-64', 'linux-arm64': 'v2rayN-linux-arm64',
    'linux-riscv64': 'v2rayN-linux-riscv64', 'linux-loongarch64': 'v2rayN-linux-loong64',
    'win-x64': 'v2rayN-windows-64', 'win-arm64': 'v2rayN-windows-arm64',
}


def validate_destination(destination):
    if destination.is_symlink():
        raise ValueError('Destination must not be a symlink')
    if destination.exists():
        if not destination.is_dir():
            raise ValueError('Destination must be a directory')
        for path in destination.iterdir():
            if path.name != '.keep' or path.is_symlink() or not path.is_file() or path.stat().st_size != 0:
                raise ValueError('Destination must be empty or contain only the publish .keep marker')


def extract(archive, rid, destination, commit):
    validate_destination(destination)
    core = 'xray/xray.exe' if rid.startswith('win-') else 'xray/xray'
    allowed = {core, 'xray/LICENSE', 'geoip.dat', 'geosite.dat'}
    required = {core, 'geoip.dat', 'geosite.dat'}
    prefix = BUNDLES[rid] + '/bin/'
    with zipfile.ZipFile(archive) as source:
        entries = [item for item in source.infolist() if item.filename.startswith(prefix) and not item.is_dir()]
        if not entries or len(entries) > 4096 or sum(item.file_size for item in entries) > 1024 ** 3:
            raise ValueError('Unexpected upstream bundle size')
        names = set()
        for item in entries:
            name = item.filename[len(prefix):]
            path = PurePosixPath(name)
            if (path.is_absolute() or '..' in path.parts or '\\' in name
                    or stat.S_ISLNK(item.external_attr >> 16) or name in names):
                raise ValueError('Unsafe or duplicate upstream archive entry')
            names.add(name)
        if not required.issubset(names):
            raise ValueError('Upstream bundle lacks Xray or DAT data')
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.xray-assets-', dir=destination.parent) as temporary:
            staged = Path(temporary) / 'bin'
            staged.mkdir()
            for item in entries:
                name = item.filename[len(prefix):]
                if name not in allowed:
                    continue
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(item) as incoming, target.open('xb') as output:
                    shutil.copyfileobj(incoming, output)
            (staged / core).chmod(0o755)
            receipt = {'repository': '2dust/v2rayN-core-bin', 'commit': commit,
                       'archiveSHA256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                       'files': {str(p.relative_to(staged)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in staged.rglob('*') if p.is_file()}}
            (staged / 'core-bundle-source.json').write_text(json.dumps(receipt, indent=2) + '\n')
            # Publish creates bin/.keep. Recheck before the atomic handoff, never
            # merge with user files or an old set of executable assets.
            validate_destination(destination)
            if destination.exists():
                marker = destination / '.keep'
                if marker.exists(): marker.unlink()
                destination.rmdir()
            staged.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rid', choices=BUNDLES)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--archive', type=Path, help='Offline fixture or previously downloaded pinned archive')
    args = parser.parse_args()
    commit = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())['coreBundleCommit']
    validate_destination(args.destination)
    with tempfile.TemporaryDirectory(prefix='v2raym-core-assets-') as work:
        archive = args.archive or Path(work) / 'bundle.zip'
        if args.archive is None:
            url = f'https://raw.githubusercontent.com/2dust/v2rayN-core-bin/{commit}/{BUNDLES[args.rid]}.zip'
            with urllib.request.urlopen(url, timeout=60) as incoming, archive.open('wb') as output:
                shutil.copyfileobj(incoming, output)
        extract(archive, args.rid, args.destination, commit)
    print('Prepared Xray-only shared backend assets: ' + str(args.destination))


if __name__ == '__main__':
    main()
