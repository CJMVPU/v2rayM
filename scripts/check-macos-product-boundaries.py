#!/usr/bin/env python3
"""Fail on reintroduced retired engines in active source/assets, including new files."""
from pathlib import Path
import re
import sys
ROOT = Path(__file__).resolve().parents[1]
PATTERN = re.compile(r'sing[-_]?box|SagerNet|\b\w*4Sbox\w*\b', re.I)
ERRORS = []
for folder in ('v2rayN/ServiceLib', 'v2rayN/ServiceLib.Tests', 'v2rayN/v2rayN.WebAPI', 'macos/Native/Sources', 'macos/TunHelper/Sources'):
    for path in (ROOT / folder).rglob('*'):
        if not path.is_file() or set(path.parts) & {'obj', 'bin', 'Tests', '.build'}:
            continue
        if path.name == 'pac':  # PAC domain data is not an engine implementation.
            continue
        if path.suffix not in {'.cs', '.csproj', '.swift', '.resx', '.json', ''}:
            continue
        rel = path.relative_to(ROOT)
        if PATTERN.search(str(rel)):
            ERRORS.append(f'{rel}: retired engine file')
        try:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if PATTERN.search(line) or ('macos/Native/Sources' in str(rel) and re.search('mihomo|clash', line, re.I)):
                    ERRORS.append(f'{rel}:{number}: retired engine reference')
        except UnicodeError:
            pass
for name in ('scripts/fetch-macos-cores.sh', 'scripts/package-macos-app.sh'):
    text = (ROOT / name).read_text()
    if re.search(r'https?://[^\s\"\']*(?:SagerNet|MetaCubeX)|fetch_core.*(?:mihomo|sing)', text, re.I):
        ERRORS.append(f'{name}: unsupported engine download')
registry = (ROOT / 'v2rayN/ServiceLib/Manager/CoreInfoManager.cs').read_text()
if set(re.findall(r'CoreType = ECoreType\.(\w+)', registry)) - {'Xray', 'v2rayN'}:
    ERRORS.append('CoreInfoManager: unsupported executable registration')
if ERRORS:
    print('\n'.join(ERRORS))
    sys.exit(1)
print('macOS product boundaries passed: Xray-only active sources and registry')
