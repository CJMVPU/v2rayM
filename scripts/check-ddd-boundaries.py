#!/usr/bin/env python3
"""Enforce the dependency direction of extracted product domain modules."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def check_native_source(path, root, allowed_imports, layer, errors):
    source = path.read_text()
    for imported in re.findall(r'^\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|internal|package)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)', source, re.M):
        if imported not in allowed_imports:
            errors.append(f'{path.relative_to(root)}: forbidden {layer} import {imported}')
    # Foundation also exports process, disk and network APIs. Keeping its import
    # for dates/async support must not silently introduce infrastructure work.
    if re.search(r'\b(?:URLSession|URLRequest|FileManager|FileHandle|Process|UserDefaults|NSWorkspace)\s*[.(]', source):
        errors.append(f'{path.relative_to(root)}: infrastructure API in native {layer}')

def check(root=ROOT):
    errors = []
    native = root / 'macos/Native/Sources/V2rayMDomain'
    for path in native.rglob('*.swift'):
        check_native_source(path, root, {'Foundation'}, 'domain', errors)
    package = (root / 'macos/Native/Package.swift').read_text()
    if not re.search(r'\.target\s*\(\s*name\s*:\s*"V2rayMDomain"\s*\)', package):
        errors.append('Native domain target must have no target dependencies')
    native_application = root / 'macos/Native/Sources/V2rayMApplication'
    for path in native_application.rglob('*.swift'):
        check_native_source(path, root, {'Foundation', 'V2rayMDomain'}, 'application', errors)
    if not re.search(r'\.target\s*\(\s*name\s*:\s*"V2rayMApplication"\s*,\s*dependencies\s*:\s*\[\s*"V2rayMDomain"\s*,?\s*\]\s*,?\s*\)', package):
        errors.append('Native application target may depend only on the domain target')
    return errors

if __name__ == '__main__':
    errors = check()
    if errors: raise SystemExit('\n'.join(errors))
    print('DDD dependency boundaries passed')
