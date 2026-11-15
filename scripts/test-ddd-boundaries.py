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
        for relative in ['v2rayN/V2rayM.Domain/V2rayM.Domain.csproj',
                         'v2rayN/V2rayM.Application/V2rayM.Application.csproj',
                         'macos/Native/Package.swift']:
            self.write(relative, (ROOT / relative).read_text())

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def test_valid_direction(self):
        self.assertEqual(guard.check(self.root), [])

    def test_domain_cannot_reference_upstream(self):
        self.write('v2rayN/V2rayM.Domain/V2rayM.Domain.csproj',
                   '<Project><ItemGroup><ProjectReference Include="../ServiceLib/ServiceLib.csproj" /></ItemGroup></Project>')
        self.assertTrue(guard.check(self.root))

    def test_application_cannot_reference_web(self):
        self.write('v2rayN/V2rayM.Application/V2rayM.Application.csproj',
                   '<Project><ItemGroup><ProjectReference Include="../v2rayN.WebAPI/v2rayN.WebAPI.csproj" /></ItemGroup></Project>')
        self.assertTrue(guard.check(self.root))

    def test_csharp_source_cannot_use_infrastructure(self):
        self.write('v2rayN/V2rayM.Application/Bad.cs', 'using System.IO;\n')
        self.assertTrue(guard.check(self.root))

    def test_native_application_cannot_import_kit(self):
        self.write('macos/Native/Sources/V2rayMApplication/Bad.swift', 'import V2rayMKit\n')
        self.assertTrue(guard.check(self.root))

    def test_foundation_is_not_an_io_escape(self):
        self.write('macos/Native/Sources/V2rayMDomain/Bad.swift', 'import Foundation\nlet process = Process()\n')
        self.assertTrue(guard.check(self.root))

    def test_native_domain_target_cannot_gain_dependencies(self):
        path = self.root / 'macos/Native/Package.swift'
        path.write_text(path.read_text().replace('.target(name: "V2rayMDomain"),', '.target(name: "V2rayMDomain", dependencies: ["V2rayMKit"]),'))
        self.assertTrue(guard.check(self.root))

if __name__ == '__main__':
    unittest.main()
