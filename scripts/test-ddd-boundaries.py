#!/usr/bin/env python3
"""Verify that the architectural gate rejects dependencies, not just today's tree."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ddd_boundaries', ROOT / 'scripts/check-ddd-boundaries.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        package = 'macos/Native/Package.swift'
        self.write(package, (ROOT / package).read_text())

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_valid_direction(self):
        self.assertEqual(guard.check(self.root), [])

    def test_native_application_cannot_import_kit(self):
        self.write('macos/Native/Sources/V2rayMApplication/Bad.swift', 'import V2rayMKit\n')
        self.assertTrue(guard.check(self.root))

    def test_foundation_is_not_an_io_escape(self):
        self.write('macos/Native/Sources/V2rayMDomain/Bad.swift', 'import Foundation\nlet process = Process()\n')
        self.assertTrue(guard.check(self.root))

    def test_attributed_or_scoped_import_cannot_bypass_native_boundary(self):
        for declaration in ['@preconcurrency import V2rayMKit', 'internal import V2rayMKit', 'import struct V2rayMKit.APIClient']:
            with self.subTest(declaration=declaration):
                self.write('macos/Native/Sources/V2rayMApplication/Bad.swift', declaration + '\n')
                self.assertTrue(guard.check(self.root))

    def test_package_formatting_is_not_an_architecture_change(self):
        path = self.root / 'macos/Native/Package.swift'
        path.write_text(path.read_text().replace('.target(name: "V2rayMDomain"),',
            '.target(\n    name: "V2rayMDomain"\n),').replace('dependencies: ["V2rayMDomain"]', 'dependencies: [\n "V2rayMDomain",\n]'))
        self.assertEqual(guard.check(self.root), [])

    def test_native_domain_target_cannot_gain_dependencies(self):
        path = self.root / 'macos/Native/Package.swift'
        path.write_text(path.read_text().replace('.target(name: "V2rayMDomain"),', '.target(name: "V2rayMDomain", dependencies: ["V2rayMKit"]),'))
        self.assertTrue(guard.check(self.root))

if __name__ == '__main__':
    unittest.main()
