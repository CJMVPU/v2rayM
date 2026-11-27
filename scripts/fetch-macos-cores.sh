#!/usr/bin/env bash
set -euo pipefail
rid="${1:?Usage: fetch-macos-cores.sh <osx-arm64|osx-x64> <new-destination-bin>}"
destination="${2:?Specify a new destination directory}"
mode="${3:-full}"
[[ "$mode" == full || "$mode" == --data-only ]] || { echo "Unsupported extraction mode." >&2; exit 2; }
case "$rid" in
  osx-arm64) bundle=v2rayN-macos-arm64 ;;
  osx-x64) bundle=v2rayN-macos-64 ;;
  *) echo 'Expected osx-arm64 or osx-x64.' >&2; exit 2 ;;
esac
[[ ! -e "$destination" ]] || { echo 'Destination already exists; refusing to replace it.' >&2; exit 1; }
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ref="$(plutil -extract coreBundleCommit raw "$repo_root/contracts/macos-build-inputs.json")"
[[ "${CORE_BUNDLE_REF:-$ref}" == "$ref" ]] || { echo 'Core bundle override differs from reviewed commit.' >&2; exit 1; }
[[ "$ref" =~ ^[a-fA-F0-9]{40}$ ]] || { echo 'Invalid upstream ref.' >&2; exit 1; }
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 \
  "https://raw.githubusercontent.com/2dust/v2rayN-core-bin/$ref/$bundle.zip" --output "$temporary_directory/cores.zip"
"$repo_root/scripts/project-tool" extract-core-bundle "$temporary_directory/cores.zip" "$bundle" "$destination" "$ref" "$mode"
