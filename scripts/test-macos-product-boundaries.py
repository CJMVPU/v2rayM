#!/usr/bin/env python3
"""Offline regression for product sources and previously missed release entry points."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('boundaries', Path(__file__).with_name('check-macos-product-boundaries.py'))
boundaries = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundaries)


class BoundaryTests(unittest.TestCase):
    def test_each_active_packaging_surface_is_scanned(self):
        for name in ('.github/workflows/new.yml', '.github/workflows/test-release.yml',
                     '.github/workflows/smoke-download.yaml', 'v2rayN/v2rayN.WebAPI/Containerfile',
                     'v2rayN/v2rayN.WebAPI/Scripts/new.py', 'v2rayN/v2rayN.WebAPI/Scripts/new.sh',
                     'scripts/new-download.sh'):
            with self.subTest(path=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                registry = root / 'v2rayN/ServiceLib/Manager/CoreInfoManager.cs'
                registry.parent.mkdir(parents=True)
                registry.write_text('CoreType = ECoreType.Xray')
                source = root / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text('download mihomo and sing-box and rules.srs')
                self.assertTrue(any(name in error for error in boundaries.check(root)))

    def test_unknown_core_registration_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registry = root / 'v2rayN/ServiceLib/Manager/CoreInfoManager.cs'
            registry.parent.mkdir(parents=True)
            registry.write_text('CoreType = ECoreType.OtherEngine')
            self.assertIn('CoreInfoManager: unsupported executable registration', boundaries.check(root))

    def test_xray_source_and_persisted_legacy_enum_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registry = root / 'v2rayN/ServiceLib/Manager/CoreInfoManager.cs'
            registry.parent.mkdir(parents=True)
            registry.write_text('CoreType = ECoreType.Xray')
            enum = root / 'v2rayN/ServiceLib/Enums/ECoreType.cs'
            enum.parent.mkdir()
            enum.write_text('mihomo = 13,')
            self.assertEqual(boundaries.check(root), [])


if __name__ == '__main__':
    unittest.main()
