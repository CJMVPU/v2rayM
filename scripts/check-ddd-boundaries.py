#!/usr/bin/env python3
"""Enforce the dependency direction of extracted product domain modules."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

def check_native_source(path, root, allowed_imports, layer, errors):
    source = path.read_text()
    for imported in re.findall(r'^import\s+(\w+)', source, re.M):
        if imported not in allowed_imports:
            errors.append(f'{path.relative_to(root)}: forbidden {layer} import {imported}')
    # Foundation also exports process, disk and network APIs. Keeping its import
    # for dates/async support must not silently introduce infrastructure work.
    if re.search(r'\b(?:URLSession|URLRequest|FileManager|FileHandle|Process|UserDefaults|NSWorkspace)\s*[.(]', source):
        errors.append(f'{path.relative_to(root)}: infrastructure API in native {layer}')

def check(root=ROOT):
    errors = []
    domain = root / 'v2rayN/V2rayM.Domain'
    project = ET.parse(domain / 'V2rayM.Domain.csproj').getroot()
    for reference in project.iter():
        if reference.tag in {'ProjectReference', 'PackageReference', 'FrameworkReference', 'Reference'}:
            errors.append('Domain must not reference framework, upstream or infrastructure assemblies')
    for path in domain.rglob('*.cs'):
        if {'obj', 'bin'} & set(path.parts): continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r'\b(ServiceLib|v2rayN|Microsoft\.AspNetCore|System\.IO|System\.Net|System\.Diagnostics)\b', line):
                errors.append(f'{path.relative_to(root)}:{number}: external dependency in domain')
    application = root / 'v2rayN/V2rayM.Application'
    project = ET.parse(application / 'V2rayM.Application.csproj').getroot()
    for reference in project.iter():
        if reference.tag == 'ProjectReference' and reference.get('Include') != '../V2rayM.Domain/V2rayM.Domain.csproj':
            errors.append('Application may reference only the domain project')
        if reference.tag in {'PackageReference', 'FrameworkReference', 'Reference'}:
            errors.append('Application must not reference infrastructure assemblies')
    for path in application.rglob('*.cs'):
        if {'obj', 'bin'} & set(path.parts): continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r'\b(ServiceLib|v2rayN|Microsoft\.AspNetCore|System\.IO|System\.Net|System\.Diagnostics)\b', line):
                errors.append(f'{path.relative_to(root)}:{number}: external dependency in application')
    native = root / 'macos/Native/Sources/V2rayMDomain'
    for path in native.rglob('*.swift'):
        check_native_source(path, root, {'Foundation'}, 'domain', errors)
    package = (root / 'macos/Native/Package.swift').read_text()
    if '.target(name: "V2rayMDomain"),' not in package:
        errors.append('Native domain target must have no target dependencies')
    native_application = root / 'macos/Native/Sources/V2rayMApplication'
    for path in native_application.rglob('*.swift'):
        check_native_source(path, root, {'Foundation', 'V2rayMDomain'}, 'application', errors)
    if '.target(name: "V2rayMApplication", dependencies: ["V2rayMDomain"]),' not in package:
        errors.append('Native application target may depend only on the domain target')
    return errors

if __name__ == '__main__':
    errors = check()
    if errors: raise SystemExit('\n'.join(errors))
    print('DDD dependency boundaries passed')
