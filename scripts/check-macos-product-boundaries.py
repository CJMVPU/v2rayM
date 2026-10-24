#!/usr/bin/env python3
"""Fail on retired runtime engines and packaging entry points, including untracked files."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r'sing[-_]?box|SagerNet|\b\w*4Sbox\w*\b|https?://[^\s\"\']*MetaCubeX', re.I)
PACKAGING_PATTERN = re.compile(r'sing[-_]?box|SagerNet|MetaCubeX|\bmihomo\b|\.srs\b', re.I)
RETIRED_PACKAGES = {'reactiveui', 'reactiveui.sourcegenerators', 'qrcoder', 'zxing.net.bindings.skiasharp', 'taskscheduler'}
SKIP_PARTS = {'obj', 'bin', 'Tests', '.build', '__pycache__', 'publish', '.packages'}
SOURCE_FOLDERS = ('v2rayN/ServiceLib', 'v2rayN/ServiceLib.Tests', 'v2rayN/v2rayN.WebAPI',
                  'macos/Native/Sources', 'macos/TunHelper/Sources')


def check(root=ROOT):
    errors = []
    candidates = {}
    for folder in SOURCE_FOLDERS:
        for path in (root / folder).rglob('*'):
            relative = path.relative_to(root)
            if not path.is_file() or set(relative.parts) & SKIP_PARTS or path.name == 'pac':
                continue
            if path.suffix in {'.cs', '.csproj', '.swift', '.resx', '.json', '.py', '.sh', '.ps1', '.yml', '.yaml', ''}:
                candidates[path] = 'Scripts' in relative.parts or path.name == 'Containerfile'
    # Audit/test fixtures intentionally contain forbidden examples; product scripts do not.
    for folder in ('scripts', '.github/workflows'):
        for path in (root / folder).rglob('*'):
            if (path.is_file() and not set(path.relative_to(root).parts) & SKIP_PARTS
                    and path.suffix in {'.py', '.sh', '.ps1', '.yml', '.yaml'}
                    and (folder == '.github/workflows' or (path.name != 'check-macos-product-boundaries.py'
                         and not path.name.startswith(('test-', 'test_', 'smoke-'))))):
                candidates[path] = True
    for path, packaging in candidates.items():
        relative = path.relative_to(root)
        pattern = PACKAGING_PATTERN if packaging else PATTERN
        if pattern.search(str(relative)):
            errors.append(f'{relative}: retired engine file')
        try:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if pattern.search(line) or ('macos/Native/Sources' in str(relative) and re.search('mihomo|clash', line, re.I)):
                    errors.append(f'{relative}:{number}: retired engine reference')
        except UnicodeError:
            continue
    registry = (root / 'v2rayN/ServiceLib/Manager/CoreInfoManager.cs').read_text()
    if set(re.findall(r'CoreType = ECoreType\.(\w+)', registry)) - {'Xray', 'v2rayN'}:
        errors.append('CoreInfoManager: unsupported executable registration')
    for project in (root / 'v2rayN').rglob('*.csproj'):
        if set(project.relative_to(root).parts) & SKIP_PARTS:
            continue
        for package in re.findall(r'<PackageReference\s+Include="([^"]+)"', project.read_text()):
            if package.lower() in RETIRED_PACKAGES:
                errors.append(f'{project.relative_to(root)}: retired desktop package {package}')
    return errors


def main():
    errors = check()
    if errors:
        print('\n'.join(errors))
        return 1
    print('macOS product boundaries passed: Xray-only sources, registry and packaging')
    return 0


if __name__ == '__main__':
    sys.exit(main())
