#!/bin/bash
# Build a signed, source-consistent local product in a new directory.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tool="$repo/scripts/project-tool"
network="$repo/scripts/network-check"
output=
core_bin=
library=
smoke=1
while (( $# )); do
  case "$1" in
    --output) output="${2:?Missing output directory}"; shift 2 ;;
    --core-bin) core_bin="${2:?Missing Geo data directory}"; shift 2 ;;
    --core-library) library="${2:?Missing core library}"; shift 2 ;;
    --skip-smoke) smoke=0; shift ;;
    *) echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && -n "$output" && ! -e "$output" && -n "$core_bin" && -f "$core_bin/geoip.dat" && -f "$core_bin/geosite.dat" ]] || {
  echo "Use --output <new directory> --core-bin <pinned Geo inputs> on macOS" >&2; exit 1;
}
core_bin=$(cd "$core_bin" && pwd)
if [[ -n "$library" ]]; then library=$(cd "$(dirname "$library")" && pwd)/$(basename "$library"); fi
mkdir -p "$(dirname "$output")"
mkdir "$output"
output=$(cd "$output" && pwd)
cd "$repo"
export CORE_BIN_DIR="$core_bin" APP_VERSION="$(cat VERSION)"
export APP_BUILD="$APP_VERSION" NATIVE_SCRATCH_PATH="$output/native-build" SWIFT_SCRATCH_PATH="$output/helper-build"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/module-cache"
"$tool" check-macos-product-boundaries
"$tool" check-ddd-boundaries
"$tool" generate-helper-contract --check
if ! "$tool" prepare-macos-geo --verify-only; then "$tool" prepare-macos-geo; fi
snapshot="$output/source-snapshot.json"
app="$output/v2rayM.app"
"$tool" macos-build-manifest snapshot --output "$snapshot"
if [[ -z "$library" ]]; then
  scripts/build-macos-xray.sh --library --output "$output/xray-library"
  library="$output/xray-library/libV2rayMXray.dylib"
fi
scripts/package-macos-app.sh "$core_bin" "$app" "$snapshot" "$library"
smoke_status="not run"
if (( smoke )); then
  build=(swift build --disable-sandbox --package-path macos/Native --scratch-path "$NATIVE_SCRATCH_PATH" -c release)
  "${build[@]}" --product V2rayMCheck
  checker=$("${build[@]}" --show-bin-path)/V2rayMCheck
  tool_bin=$(swift build --package-path scripts/ProjectTools -c release --show-bin-path)/ProjectTool
  shipped="$app/Contents/Frameworks/libV2rayMXray.dylib"
  "$network" custom-pair "$tool_bin" "$shipped"
  "$network" embedded "$checker" "$shipped"
  "$network" dns "$app" "$checker"
  V2RAYM_TEST_SIGNED_APP="$app" swift test --disable-sandbox --package-path macos/Native --scratch-path "$NATIVE_SCRATCH_PATH" -c release --filter CustomOutboundChainTests
  "$network" product "$app" "$checker"
  "$network" tun-acceptance --check-only --app "$app" --expect-app-version "$APP_VERSION" --result-dir "$output/native-host-preflight"
  smoke_status=passed
fi
"$tool" macos-build-manifest seal-app --app "$app" --output "$output/product-manifest.json"
digest=$(plutil -extract source.sourceDigest raw "$snapshot")
cat > "$output/verification.json" <<JSON
{
  "productVersion": "$APP_VERSION",
  "sourceDigest": "$digest",
  "build": "passed",
  "signature": "passed",
  "packagedLoopbackSmoke": "$smoke_status",
  "installed": false,
  "realTUN": false,
  "notarized": false
}
JSON
echo "Verified local product: $app"
