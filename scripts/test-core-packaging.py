#!/usr/bin/env python3
"""Exercise curated extraction and package fail-closed behavior without downloads."""
import importlib.util
import os
from pathlib import Path
import stat
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
