#!/usr/bin/env python3
"""Exercise curated extraction and package fail-closed behavior without downloads."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class CorePackagingTests(unittest.TestCase):
    def test_macos_fetch_pinned_receipts_in_full_and_data_only_modes(self):
        pinned = json.loads((ROOT / 'contracts/macos-build-inputs.json').read_text())['coreBundleCommit']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / 'upstream.zip'
            curl = root / 'curl'
            # Accept only the expected pinned URL. Data never leaves this directory.
            curl.write_text("""#!/usr/bin/env python3
import os, shutil, sys
url, flag, destination = sys.argv[-3:]
assert url == os.environ['FIXTURE_URL'] and flag == '--output'
shutil.copyfile(os.environ['FIXTURE_ARCHIVE'], destination)
""")
            curl.chmod(0o755)
            url = f'https://raw.githubusercontent.com/2dust/v2rayN-core-bin/{pinned}/v2rayN-macos-arm64.zip'
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       FIXTURE_ARCHIVE=str(archive_path), FIXTURE_URL=url)
            env.pop('CORE_BUNDLE_REF', None)
            command = [str(ROOT / 'scripts/fetch-macos-cores.sh'), 'osx-arm64']
            geo = {'geoip.dat', 'geosite.dat'}
            full = geo | {'xray/xray', 'xray/LICENSE'}
            for has_binary in (True, False):
                entries = (full if has_binary else geo) | {'unused/other-engine'}
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    for name in sorted(entries):
                        archive.writestr('v2rayN-macos-arm64/bin/' + name, name.encode())
                for mode, targets in (([], full), (['--data-only'], geo)):
                    with self.subTest(has_binary=has_binary, mode=mode):
                        dest = root / f"output-{has_binary}-{'data' if mode else 'full'}"
                        result = subprocess.run(command + [str(dest)] + mode, env=env, capture_output=True, text=True)
                        if not mode and not has_binary:
                            self.assertNotEqual(result.returncode, 0)
                            self.assertFalse(dest.exists())
                            continue
                        self.assertEqual(result.returncode, 0, result.stderr)
                        receipt = 'core-bundle-source.json'
                        actual = {p.relative_to(dest).as_posix() for p in dest.rglob('*') if p.is_file()}
                        self.assertEqual(actual, targets | {receipt})
                        self.assertEqual(json.loads((dest / receipt).read_text()), {
                            'repository': '2dust/v2rayN-core-bin', 'commit': pinned,
                            'archiveSHA256': hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                            'files': {name: hashlib.sha256(name.encode()).hexdigest() for name in targets}})
                        for name in targets:
                            self.assertEqual((dest / name).read_bytes(), name.encode())
                        if not mode:
                            self.assertTrue(os.access(dest / 'xray/xray', os.X_OK))

            result = subprocess.run(command + [str(root / 'override'), '--data-only'],
                                    env=env | {'CORE_BUNDLE_REF': '0' * 40}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('reviewed commit', result.stderr)
            self.assertFalse((root / 'override').exists())

            # The active macOS extractor must reject unsafe entries even outside its allowlist.
            for name, symlink in [('../escape', False), ('link', True)]:
                with self.subTest(entry=name), zipfile.ZipFile(archive_path, 'w') as archive:
                    for entry in sorted(geo):
                        archive.writestr('v2rayN-macos-arm64/bin/' + entry, b'fixture')
                    info = zipfile.ZipInfo('v2rayN-macos-arm64/bin/' + name)
                    if symlink:
                        info.external_attr = 0o120777 << 16
                    archive.writestr(info, b'outside')
                destination = root / 'rejected'
                result = subprocess.run(command + [str(destination), '--data-only'], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())

if __name__ == '__main__':
    unittest.main()
