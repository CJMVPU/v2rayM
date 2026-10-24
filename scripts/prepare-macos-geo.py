#!/usr/bin/env python3
"""Fetch/check the pinned DB-IP input and build the native offline city tables."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'macos/Native/Sources/V2rayM/Resources/Globe'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''): h.update(data)
    return h.hexdigest()

def verify(output=OUTPUT):
    pinned = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())['geolocation']
    manifest = json.loads((output / 'geodata-manifest.json').read_text())
    if manifest['input']['sha256'] != pinned['sha256'] or manifest['input']['sourceURL'] != pinned['sourceURL']:
        raise ValueError('Geo input does not match the reviewed input lock')
    for name in ['ipv4.bin', 'ipv6.bin', 'places.bin']:
        item = manifest['outputs'][name]; path = output / name
        if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise ValueError('Geo output differs from its generation manifest: ' + name)
    if not (output / 'ATTRIBUTION.txt').is_file(): raise ValueError('DB-IP attribution is required')

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--source', type=Path); parser.add_argument('--verify-only', action='store_true'); args = parser.parse_args()
    if args.verify_only:
        verify(); print('Pinned Geo inputs and outputs verified.'); return
    pinned = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())['geolocation']
    with tempfile.TemporaryDirectory(prefix='v2raym-geodata-') as work:
        source = args.source or Path(work) / pinned['file']
        if args.source is None: urllib.request.urlretrieve(pinned['sourceURL'], source)
        if digest(source) != pinned['sha256']: raise ValueError('Pinned DB-IP archive checksum mismatch')
        subprocess.run([sys.executable, str(ROOT / 'scripts/prepare-globe-geo.py'), str(source), str(OUTPUT)], check=True)
    verify(); print('Prepared reproducible native city data.')
if __name__ == '__main__': main()
