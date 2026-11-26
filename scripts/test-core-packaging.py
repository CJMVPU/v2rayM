#!/usr/bin/env python3
"""Exercise curated extraction and package fail-closed behavior without downloads."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'v2rayN/v2rayN.WebAPI/Scripts'


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


fetch = module('fetch', 'fetch-core-bundle.py')
assets = module('assets', 'web-release-assets.py')


class CorePackagingTests(unittest.TestCase):
    def archive(self, directory, rid, extra=None):
        path = Path(directory) / 'upstream.zip'
        prefix = fetch.BUNDLES[rid] + '/bin/'
        core = 'xray/xray.exe' if rid.startswith('win-') else 'xray/xray'
        with zipfile.ZipFile(path, 'w') as archive:
            for name in [core, 'xray/LICENSE', 'geoip.dat', 'geosite.dat', 'unused/other-engine', 'srss/old.srs']:
                archive.writestr(prefix + name, b'fixture')
            if extra:
                info, data = extra(prefix)
                archive.writestr(info, data)
        return path, core

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

    def test_all_rids_extract_only_reviewed_assets(self):
        for rid in fetch.BUNDLES:
            with self.subTest(rid=rid), tempfile.TemporaryDirectory() as directory:
                archive, core = self.archive(directory, rid)
                destination = Path(directory) / 'bin'
                fetch.extract(archive, rid, destination, 'a' * 40)
                actual = {p.relative_to(destination).as_posix() for p in destination.rglob('*') if p.is_file()}
                self.assertEqual(actual, {core, 'xray/LICENSE', 'geoip.dat', 'geosite.dat', 'core-bundle-source.json'})

    def test_traversal_is_rejected_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, _ = self.archive(directory, 'linux-x64', lambda prefix: (prefix + '../../escaped', b'bad'))
            destination = Path(directory) / 'bin'
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                fetch.extract(archive, 'linux-x64', destination, 'a' * 40)
            self.assertFalse(destination.exists())

    def test_symlink_is_rejected(self):
        def link(prefix):
            info = zipfile.ZipInfo(prefix + 'link')
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            return info, b'/tmp/elsewhere'
        with tempfile.TemporaryDirectory() as directory:
            archive, _ = self.archive(directory, 'linux-x64', link)
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                fetch.extract(archive, 'linux-x64', Path(directory) / 'bin', 'a' * 40)

    def test_publish_marker_is_replaced_without_nested_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, core = self.archive(directory, 'linux-x64')
            destination = Path(directory) / 'bin'
            destination.mkdir()
            (destination / '.keep').touch()
            fetch.extract(archive, 'linux-x64', destination, 'a' * 40)
            self.assertTrue((destination / core).is_file())
            self.assertFalse((destination / '.keep').exists())

    def test_existing_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            archive, _ = self.archive(directory, 'linux-x64')
            destination = Path(directory) / 'bin'
            destination.mkdir()
            (destination / 'keep').write_text('original')
            with self.assertRaisesRegex(ValueError, 'must be empty'):
                fetch.extract(archive, 'linux-x64', destination, 'a' * 40)
            self.assertEqual((destination / 'keep').read_text(), 'original')

    def test_full_package_rejects_extra_engine_and_symlink(self):
        for extra in ('other/core', 'xray/xray'):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                publish = root / 'publish'
                for name in ['v2rayN.WebAPI', assets.BUILD_IDENTITY_NAME, 'bin/xray/xray', 'bin/geoip.dat', 'bin/geosite.dat']:
                    path = publish / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'fixture')
                    path.chmod(0o755)
                path = publish / 'bin' / extra
                path.parent.mkdir(parents=True, exist_ok=True)
                if extra == 'xray/xray':
                    path.unlink()
                    path.symlink_to(publish / 'v2rayN.WebAPI')
                else:
                    path.write_bytes(b'unreviewed')
                with self.assertRaises(SystemExit):
                    assets.create_full_zip(publish, root / 'out.zip', 'linux-x64')
                self.assertFalse((root / 'out.zip').exists())


if __name__ == '__main__':
    unittest.main()
