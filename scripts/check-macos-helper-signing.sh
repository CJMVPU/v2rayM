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
location=$(cd / && /bin/bash -c 'exec -a Contents/MacOS/V2rayMHelper "$1" location' bash "$fixture")
[[ "$location" -ef "$fixture" ]] || { echo "Unexpected helper location" >&2; exit 1; }
if "$fixture" > "$test_root/result" 2>&1; then echo "Expected ad-hoc rejection" >&2; exit 1; fi
grep -q 'apple_team_signature_required' "$test_root/result"
codesign --force --sign "$identity" "$fixture"
team=$("$fixture")
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "Missing signed team" >&2; exit 1; }
echo "Helper executable location and Apple team signature verified."
