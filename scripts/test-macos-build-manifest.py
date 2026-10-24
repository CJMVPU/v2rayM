#!/usr/bin/env python3
"""Offline regressions for stale/mixed backend source and modified artifacts."""
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
        self.backend = Path(self.temp.name) / 'backend'; self.backend.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name, text in [('VERSION', '0.3.3\n'), ('macos/Native/Sources/fixture.swift', 'let build = 1\n'), ('v2rayN/ServiceLib/fixture.cs', 'class Fixture {}\n')]:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)
        subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], cwd=self.root, check=True)
        (self.backend / 'v2rayN.WebAPI').write_bytes(b'backend fixture')
        self.receipt = {'schema': 1, 'source': manifest.source_snapshot(self.root), 'backendSHA256': manifest.sha(self.backend / 'v2rayN.WebAPI')}
        manifest.write_json(self.backend / 'v2raym-backend-build.json', self.receipt)
    def tearDown(self): self.temp.cleanup()
    def test_matching_source_and_backend_are_accepted(self):
        self.assertEqual(manifest.verify_backend(self.backend, self.root)['source']['version'], '0.3.3')
    def test_native_only_change_also_refuses_old_backend_receipt(self):
        (self.root / 'macos/Native/Sources/fixture.swift').write_text('let build = 2\n')
        with self.assertRaisesRegex(ValueError, 'Source tree changed'): manifest.verify_backend(self.backend, self.root)
    def test_backend_binary_tampering_is_rejected(self):
        (self.backend / 'v2rayN.WebAPI').write_bytes(b'different backend')
        with self.assertRaisesRegex(ValueError, 'executable differs'): manifest.verify_backend(self.backend, self.root)
    def test_untracked_source_is_part_of_dirty_identity(self):
        (self.root / 'new.swift').write_text('let feature = true\n')
        snapshot = manifest.source_snapshot(self.root)
        self.assertTrue(snapshot['dirty']); self.assertNotEqual(snapshot['sourceDigest'], self.receipt['source']['sourceDigest'])
        with self.assertRaises(ValueError): manifest.verify_backend(self.backend, self.root)
    def test_version_change_invalidates_existing_build(self):
        (self.root / 'VERSION').write_text('0.3.4\n')
        with self.assertRaises(ValueError): manifest.verify_backend(self.backend, self.root)
    def test_invalid_version_is_rejected(self):
        (self.root / 'VERSION').write_text('0.3.3.1\n')
        with self.assertRaises(ValueError): manifest.source_snapshot(self.root)

class PackagedDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raym-packaged-data-')
        self.app = Path(self.temp.name)
        self.data = self.app / 'Contents/Resources/Backend/bin'
        self.data.mkdir(parents=True)
        self.plist = self.app / 'Contents/Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.3.6', 'CFBundleVersion': '0.3.6'}))
        for name in ('geoip.dat', 'geosite.dat'): (self.data / name).write_bytes(name.encode())
        self.receipt = {'source': {'version': '0.3.6'}, 'artifacts': {}, 'resourceDigests': {},
                        'runtimeData': {'SHA256': {name: manifest.sha(self.data / name) for name in ('geoip.dat', 'geosite.dat')}}}
    def tearDown(self): self.temp.cleanup()
    def test_unchanged_runtime_data_passes(self):
        manifest.verify_app_files(self.app, self.receipt)
    def test_each_changed_dat_is_rejected(self):
        for name in ('geoip.dat', 'geosite.dat'):
            with self.subTest(name=name):
                path = self.data / name; original = path.read_bytes(); path.write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, name): manifest.verify_app_files(self.app, self.receipt)
                path.write_bytes(original)
    def test_missing_or_extra_data_digest_is_rejected(self):
        digests = self.receipt['runtimeData']['SHA256']
        original = dict(digests)
        for invalid in ({}, {'geoip.dat': original['geoip.dat']}, original | {'unexpected.dat': 'bad'}):
            self.receipt['runtimeData']['SHA256'] = invalid
            with self.assertRaisesRegex(ValueError, 'digests'): manifest.verify_app_files(self.app, self.receipt)
    def test_plist_version_changed_after_packaging_is_rejected(self):
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            value = {'CFBundleShortVersionString': '0.3.6', 'CFBundleVersion': '0.3.6'}; value[key] = '0.3.5'
            self.plist.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(ValueError, 'versions'): manifest.verify_app_files(self.app, self.receipt)

class ReviewedInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raym-input-test-')
        self.core_bin = Path(self.temp.name)
        self.core = self.core_bin / 'xray/xray'; self.core.parent.mkdir(); self.core.write_bytes(b'fixture')
        pin = json.loads((manifest.ROOT / 'contracts/macos-build-inputs.json').read_text())['xray']
        self.source = self.core.with_name('SOURCE.txt')
        self.source.write_text('Xray source: ' + pin['revision'] + '\nArchive SHA256: ' + pin['sourceSHA256'] +
                               '\nPatches: ' + ', '.join(pin['patches']) + '\nBuild: ' + pin['buildMarker'] + '\n')
        self.version = 'Xray 26.10.21 (Xray, Penetrates Everything.) 1b1647c-v2raym-darwin-bind2 (go1.27.3 darwin/arm64)'
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
    def test_retired_transitive_dependency_is_rejected(self):
        assets = self.core_bin / 'v2rayN/v2rayN.WebAPI/obj/project.assets.json'; assets.parent.mkdir(parents=True)
        assets.write_text(json.dumps({'libraries': {'ReactiveUI/1.0': {}, 'Newtonsoft.Json/1.0': {}}}))
        with self.assertRaisesRegex(ValueError, 'Retired desktop'): manifest.verify_dependencies(self.core_bin)

if __name__ == '__main__': unittest.main()
