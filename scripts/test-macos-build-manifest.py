#!/usr/bin/env python3
"""Offline regressions for stale/mixed native source and modified artifacts."""
import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('manifest', Path(__file__).with_name('macos-build-manifest.py'))
manifest = importlib.util.module_from_spec(spec); spec.loader.exec_module(manifest)

class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raym-provenance-test-')
        self.root = Path(self.temp.name) / 'repo'; self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name, text in [('VERSION', '0.3.3\n'), ('macos/Native/Sources/fixture.swift', 'let build = 1\n')]:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)
        subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], cwd=self.root, check=True)
        self.snapshot = manifest.source_snapshot(self.root)
    def tearDown(self): self.temp.cleanup()
    def test_matching_source_is_accepted(self):
        self.assertEqual(manifest.assert_source(self.snapshot, self.root)['version'], '0.3.3')

    def test_source_change_refuses_old_snapshot(self):
        (self.root / 'macos/Native/Sources/fixture.swift').write_text('let build = 2\n')
        with self.assertRaisesRegex(ValueError, 'Source tree changed'):
            manifest.assert_source(self.snapshot, self.root)

    def test_untracked_source_is_part_of_dirty_identity(self):
        (self.root / 'new.swift').write_text('let feature = true\n')
        snapshot = manifest.source_snapshot(self.root)
        self.assertTrue(snapshot['dirty']); self.assertNotEqual(snapshot['sourceDigest'], self.snapshot['sourceDigest'])
        with self.assertRaises(ValueError): manifest.assert_source(self.snapshot, self.root)
    def test_version_change_invalidates_existing_build(self):
        (self.root / 'VERSION').write_text('0.3.4\n')
        with self.assertRaises(ValueError): manifest.assert_source(self.snapshot, self.root)
    def test_invalid_version_is_rejected(self):
        (self.root / 'VERSION').write_text('0.3.3.1\n')
        with self.assertRaises(ValueError): manifest.source_snapshot(self.root)

class PackagedDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raym-packaged-data-')
        self.app = Path(self.temp.name)
        self.data = self.app / 'Contents/Resources/Backend/bin'
        self.data.mkdir(parents=True)
        self.main = self.app / 'Contents/MacOS/V2rayM'
        self.main.parent.mkdir()
        self.main.write_bytes(b'fixture')
        self.main.chmod(0o755)
        self.plist = self.app / 'Contents/Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.3.6', 'CFBundleVersion': '0.3.6', 'CFBundleExecutable': 'V2rayM'}))
        for name in ('geoip.dat', 'geosite.dat'): (self.data / name).write_bytes(name.encode())
        library = self.app / manifest.LIBRARY_PATH
        library.parent.mkdir()
        library.write_bytes(b'embedded fixture')
        self.inputs = {'coreBundleCommit': '1' * 40,
                       'coreBundleDataSHA256': {name: manifest.sha(self.data / name) for name in ('geoip.dat', 'geosite.dat')}}
        self.receipt = {'source': {'version': '0.3.6'}, 'artifacts': {manifest.LIBRARY_PATH: manifest.sha(library)}, 'resourceDigests': {},
                        'runtimeData': manifest.verified_runtime_data(self.data, self.inputs)}
    def tearDown(self): self.temp.cleanup()
    def test_managed_runtime_cannot_be_added_to_native_package(self):
        for name in ('v2rayN.WebAPI', 'libcoreclr.dylib', 'libhostfxr.dylib', 'ServiceLib.dll', 'v2rayN.WebAPI.runtimeconfig.json'):
            with self.subTest(name=name):
                extra = self.data / name
                extra.write_bytes(b'fixture')
                with self.assertRaisesRegex(ValueError, 'managed runtime'):
                    manifest.verify_app_files(self.app, self.receipt, self.inputs)
                extra.unlink()

    def test_additional_proxy_executable_is_rejected(self):
        other = self.app / 'Contents/MacOS/other-core'
        other.write_bytes(b'fixture')
        with self.assertRaisesRegex(ValueError, 'Unexpected executable'):
            manifest.verify_app_files(self.app, self.receipt, self.inputs)

    def test_main_must_be_the_declared_regular_executable(self):
        for issue in ('missing', 'not-executable', 'symlink', 'plist-mismatch'):
            with self.subTest(issue=issue):
                self.main.unlink(missing_ok=True)
                if issue == 'symlink':
                    self.main.symlink_to(self.app / manifest.LIBRARY_PATH)
                elif issue != 'missing':
                    self.main.write_bytes(b'fixture')
                    self.main.chmod(0o644 if issue == 'not-executable' else 0o755)
                if issue == 'plist-mismatch':
                    info = plistlib.loads(self.plist.read_bytes())
                    info['CFBundleExecutable'] = 'V2rayMHelper'
                    self.plist.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, 'CFBundleExecutable'):
                    manifest.verify_app_files(self.app, self.receipt, self.inputs)

    def test_geo_receipt_must_agree_with_reviewed_source(self):
        origin = self.receipt['runtimeData']['origin'] | {'files': self.inputs['coreBundleDataSHA256']}
        path = self.data / 'core-bundle-source.json'
        for key, value in [('repository', 'other'), ('commit', '2' * 40), ('files', {})]:
            path.write_text(json.dumps(origin | {key: value}))
            with self.assertRaisesRegex(ValueError, 'origin'):
                manifest.verified_runtime_data(self.data, self.inputs)
        path.write_text(json.dumps(origin))
        self.receipt['runtimeData']['origin'] = origin
        manifest.verify_app_files(self.app, self.receipt, self.inputs)

    def test_unchanged_runtime_data_passes(self):
        manifest.verify_app_files(self.app, self.receipt, self.inputs)
    def test_each_changed_dat_is_rejected(self):
        for name in ('geoip.dat', 'geosite.dat'):
            with self.subTest(name=name):
                path = self.data / name; original = path.read_bytes(); path.write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, name): manifest.verify_app_files(self.app, self.receipt, self.inputs)
                path.write_bytes(original)
    def test_missing_or_extra_data_digest_is_rejected(self):
        digests = self.receipt['runtimeData']['SHA256']
        original = dict(digests)
        for invalid in ({}, {'geoip.dat': original['geoip.dat']}, original | {'unexpected.dat': 'bad'}):
            self.receipt['runtimeData']['SHA256'] = invalid
            with self.assertRaisesRegex(ValueError, 'digests'): manifest.verify_app_files(self.app, self.receipt, self.inputs)
    def test_plist_version_changed_after_packaging_is_rejected(self):
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            value = {'CFBundleShortVersionString': '0.3.6', 'CFBundleVersion': '0.3.6', 'CFBundleExecutable': 'V2rayM'}; value[key] = '0.3.5'
            self.plist.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(ValueError, 'versions'): manifest.verify_app_files(self.app, self.receipt, self.inputs)

class ReviewedInputTests(unittest.TestCase):
    def test_prebuilt_library_requires_current_common_and_embedded_patches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patches = root / 'patches/xray'
            patches.mkdir(parents=True)
            common = patches / 'common.patch'
            embedded = patches / 'embedded.patch'
            for patch in (common, embedded):
                patch.write_text(patch.name)
            inputs = {'xray': {'patches': {common.name: manifest.sha(common)}},
                      'xrayLibraryPatches': {embedded.name: manifest.sha(embedded)}, 'goVersion': 'fixture'}
            (root / 'contracts').mkdir()
            (root / 'contracts/macos-build-inputs.json').write_text(json.dumps(inputs))
            library = root / 'libV2rayMXray.dylib'
            library.write_bytes(b'fixture library')
            receipt = {'inputs': inputs['xray'], 'libraryPatches': inputs['xrayLibraryPatches'],
                       'goVersion': inputs['goVersion'], 'bridgeSources': {}, 'binarySHA256': manifest.sha(library)}
            library.with_name('library-build.json').write_text(json.dumps(receipt))
            self.assertEqual(receipt, manifest.verify_library_input(library, root))
            for patch in (common, embedded):
                with self.subTest(patch=patch.name):
                    patch.write_text('changed')
                    with self.assertRaisesRegex(ValueError, patch.name):
                        manifest.verify_library_input(library, root)
                    patch.write_text(patch.name)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raym-input-test-')
        self.core_bin = Path(self.temp.name)
        self.core = self.core_bin / 'xray/xray'; self.core.parent.mkdir(); self.core.write_bytes(b'fixture')
        pin = json.loads((manifest.ROOT / 'contracts/macos-build-inputs.json').read_text())['xray']
        self.source = self.core.with_name('SOURCE.txt')
        self.source.write_text('Xray source: ' + pin['revision'] + '\nArchive SHA256: ' + pin['sourceSHA256'] +
                               '\nPatches: ' + ', '.join(pin['patches']) + '\nBuild: ' + pin['buildMarker'] + '\n')
        self.version = f"Xray {pin['version']} (Xray, Penetrates Everything.) {pin['buildMarker']} (go1.27.3 darwin/arm64)"
    def tearDown(self): self.temp.cleanup()
    def test_reviewed_m2_metadata_is_accepted(self):
        self.assertEqual(manifest.verify_core_input(self.core_bin, version_output=self.version)['toolchain'], '1.27.3')
    def test_unrepaired_or_m1_core_is_rejected(self):
        for version in [self.version.replace('-v2raym-darwin-bind2', ''), self.version.replace('bind2', 'bind1')]:
            with self.assertRaisesRegex(ValueError, 'M2 repair'): manifest.verify_core_input(self.core_bin, version_output=version)
    def test_wrong_source_provenance_is_rejected(self):
        self.source.write_text(self.source.read_text().replace('darwin-process-lookup.patch', 'unreviewed.patch'))
        with self.assertRaisesRegex(ValueError, 'SOURCE provenance'): manifest.verify_core_input(self.core_bin, version_output=self.version)
    def test_wrong_go_toolchain_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'toolchain'): manifest.verify_core_input(self.core_bin, version_output=self.version.replace('go1.27.3', 'go1.27.2'))
if __name__ == '__main__': unittest.main()
