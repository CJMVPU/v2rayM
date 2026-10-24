#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
identity="${SIGN_IDENTITY:?Set SIGN_IDENTITY to an Apple code-signing identity}"
[[ "$(uname -s)" == Darwin && "$identity" != - ]] || {
  echo 'This check requires macOS and an Apple-issued signing identity.' >&2; exit 1;
}
test_root="$(mktemp -d "${TMPDIR:-/tmp}/v2raym-signing-check.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
fixture="$test_root/Fixture.app/Contents/MacOS/V2rayMHelper"
mkdir -p "$(dirname "$fixture")"
cat > "$test_root/Check.swift" <<'SWIFT'
import Foundation
@main struct Check {
    static func main() {
        do {
            if CommandLine.arguments.last == "location" {
                print(try ExecutableLocation.current().path)
            } else {
                print(try SigningPolicy().team)
            }
        } catch {
            fputs(String(describing: error) + "\n", stderr)
            exit(1)
        }
    }
}
SWIFT
swiftc -parse-as-library "$repo_root/macos/TunHelper/Sources/TunShared/SigningPolicy.swift" \
  "$repo_root/macos/TunHelper/Sources/TunShared/ExecutableLocation.swift" \
  "$repo_root/macos/TunHelper/Sources/TunShared/HelperContract.generated.swift" \
  "$repo_root/macos/TunHelper/Sources/TunShared/Wire.swift" "$test_root/Check.swift" -o "$fixture"
codesign --force --sign - "$fixture"
python3 - "$fixture" <<'PY'
import subprocess
import sys
from pathlib import Path
fixture = str(Path(sys.argv[1]).resolve())
result = subprocess.run(['Contents/MacOS/V2rayMHelper', 'location'], executable=fixture,
                        cwd='/', capture_output=True, text=True, timeout=15)
assert result.returncode == 0 and Path(result.stdout.strip()).resolve() == Path(fixture), (result.returncode, result.stdout, result.stderr)
print('PASS: bundle-relative argv[0] resolves to the actual loaded executable')
result = subprocess.run([fixture], capture_output=True, text=True, timeout=15)
assert result.returncode != 0 and 'apple_team_signature_required' in result.stderr, result
print('PASS: ad-hoc signing cannot supply an Apple Team ID')
PY
codesign --force --sign "$identity" "$fixture"
python3 - "$fixture" <<'PY'
import re
import subprocess
import sys
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, timeout=15)
assert result.returncode == 0 and re.fullmatch(r'[A-Z0-9]{10}', result.stdout.strip()), result
print('PASS: Apple-signed code returns its Team ID through the signing-information API')
PY
