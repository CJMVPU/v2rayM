#!/usr/bin/env python3
"""Fail on retired runtime engines and packaging entry points, including untracked files."""
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r'sing[-_]?box|SagerNet|\b\w*4Sbox\w*\b|https?://[^\s\"\']*MetaCubeX', re.I)
PACKAGING_PATTERN = re.compile(r'sing[-_]?box|SagerNet|MetaCubeX|\bmihomo\b|\.srs\b', re.I)
SKIP_PARTS = {'obj', 'bin', 'Tests', '.build', '__pycache__', 'publish', '.packages'}
SOURCE_FOLDERS = ('macos/Native/Sources', 'macos/TunHelper/Sources', 'scripts/xray/library', 'contracts')


def check(root=ROOT):
    errors = []
    for directory, children, files in os.walk(root):
        children[:] = [child for child in children if child not in {'.git', '.build', '.swiftpm', '__pycache__'}
                       and not (Path(directory) == root and child == 'artifacts')]
        for name in files:
            if (Path(name).suffix.lower() in {'.cs', '.csproj', '.fsproj', '.sln', '.slnx'}
                    or (name.lower() == 'global.json' and Path(directory) == root)
                    or name.lower() in {'nuget.config', 'directory.build.props', 'directory.packages.props'}):
                errors.append(f'{(Path(directory) / name).relative_to(root)}: retired managed project file')
    candidates = {}
    for folder in SOURCE_FOLDERS:
        for path in (root / folder).rglob('*'):
            relative = path.relative_to(root)
            if not path.is_file() or set(relative.parts) & SKIP_PARTS or path.name == 'pac':
                continue
            if path.suffix in {'.go', '.swift', '.json', '.py', '.sh', '.ps1', '.yml', '.yaml', ''}:
                candidates[path] = folder in ('scripts/xray/library', 'contracts')
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
                if packaging and re.search(r'actions/setup-dotnet@|\bdotnet\s+(?:build|run|test|publish|restore|exec|tool)\b', line, re.I):
                    errors.append(f'{relative}:{number}: retired managed toolchain')
                if pattern.search(line) or ('macos/Native/Sources' in str(relative) and re.search('mihomo|clash', line, re.I)):
                    errors.append(f'{relative}:{number}: retired engine reference')
        except UnicodeError:
            continue
    if (root / 'v2rayN').exists():
        errors.append('Retired v2rayN source directory is present')
    return errors


def main():
    errors = check()
    if errors:
        print('\n'.join(errors))
        return 1
    print('macOS product boundaries passed: Xray-only native sources, core bridge and packaging')
    return 0


if __name__ == '__main__':
    sys.exit(main())
