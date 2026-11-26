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
                     '.github/workflows/smoke-download.yaml', 'scripts/xray/library/new.go',
                     'contracts/new.json', 'macos/TunHelper/Sources/New.swift',
                     'scripts/new-download.sh'):
            with self.subTest(path=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text('download mihomo and sing-box and rules.srs')
                self.assertTrue(any(name in error for error in boundaries.check(root)))

    def test_managed_projects_and_build_steps_are_rejected_outside_retired_tree(self):
        for path, body in [('macos/Other/ServiceLib.csproj', '<Project/>'),
                           ('Legacy/Example.cs', 'class Example {}'),
                           ('.github/workflows/new.yml', 'uses: actions/setup-dotnet@v5'),
                           ('scripts/build.sh', 'dotnet publish Project')]:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                file = root / path
                file.parent.mkdir(parents=True)
                file.write_text(body)
                self.assertTrue(any(path in error for error in boundaries.check(root)))

    def test_retired_backend_tree_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'v2rayN').mkdir()
            self.assertTrue(boundaries.check(root))


if __name__ == '__main__':
    unittest.main()
