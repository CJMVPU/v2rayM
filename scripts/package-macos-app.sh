#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export APP_VERSION="${APP_VERSION:-$(cat "$repo_root/VERSION")}"
export APP_BUILD="${APP_BUILD:-$APP_VERSION}"
if [[ ! "$APP_VERSION" =~ ^[0-9]\.[0-9]\.[0-9]$ || "$APP_BUILD" != "$APP_VERSION" ]]; then
  echo 'Use three single-digit version components; APP_BUILD must equal APP_VERSION.' >&2
  exit 1
fi
"$repo_root/scripts/project-tool" check-macos-product-boundaries
"$repo_root/scripts/project-tool" prepare-macos-geo --verify-only
for resource in ipv4.bin ipv6.bin places.bin ATTRIBUTION.txt; do
  if [[ ! -s "$repo_root/macos/Native/Sources/V2rayM/Resources/Globe/$resource" ]]; then
    echo "Missing geolocation resource: $resource. See docs/connection-dashboard.md before packaging." >&2
    exit 1
  fi
done
core_bin="${1:?Usage: package-macos-app.sh <verified-core-bin> <new-output.app> <source-snapshot.json>}"
app="${2:?Specify a new output .app directory}"
snapshot="${3:?Specify the pre-build source snapshot}"
[[ ! -e "$app" ]] || { echo "Use a new output application path" >&2; exit 1; }
library="${4:?Specify the reviewed Xray library}"
"$repo_root/scripts/project-tool" macos-build-manifest verify-library --library "$library"
architecture="$(lipo -archs "$library")"
case "$architecture" in arm64|x86_64) ;; *) echo "Expected a single macOS library architecture" >&2; exit 1 ;; esac
signing_identity="${SIGN_IDENTITY:--}"
build_dir="${NATIVE_SCRATCH_PATH:-${TMPDIR:-/tmp}/v2raym-native-build-$architecture}"
swift build --disable-sandbox --package-path "$repo_root/macos/Native" --scratch-path "$build_dir" --configuration release --arch "$architecture" --product V2rayM
native_bin="$(swift build --disable-sandbox --package-path "$repo_root/macos/Native" --scratch-path "$build_dir" --configuration release --arch "$architecture" --show-bin-path)"
helper_build="${SWIFT_SCRATCH_PATH:-${TMPDIR:-/tmp}/v2raym-helper-build-$architecture}"
swift build --disable-sandbox --package-path "$repo_root/macos/TunHelper" --scratch-path "$helper_build" --configuration release --arch "$architecture" --product V2rayMHelper
helper_bin="$(swift build --disable-sandbox --package-path "$repo_root/macos/TunHelper" --scratch-path "$helper_build" --configuration release --arch "$architecture" --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchDaemons" "$app/Contents/Resources/Backend/bin" "$app/Contents/Resources/Xray"
cp "$helper_bin/V2rayMHelper" "$app/Contents/MacOS/"
cp "$repo_root/macos/Resources/io.github.CJMVPU.v2rayM.tun-helper.plist" "$app/Contents/Library/LaunchDaemons/"
cp "$core_bin/geoip.dat" "$core_bin/geosite.dat" "$app/Contents/Resources/Backend/bin/"
if [[ -f "$core_bin/core-bundle-source.json" ]]; then cp "$core_bin/core-bundle-source.json" "$app/Contents/Resources/Backend/bin/"; fi
cp "$(dirname "$library")/LICENSE" "$(dirname "$library")/SOURCE.txt" "$(dirname "$library")/library-build.json" "$app/Contents/Resources/Xray/"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.tun-helper "$app/Contents/MacOS/V2rayMHelper"
mkdir -p "$app/Contents/Frameworks"
cp "$library" "$app/Contents/Frameworks/libV2rayMXray.dylib"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.xray-library "$app/Contents/Frameworks/libV2rayMXray.dylib"
cp "$native_bin/V2rayM" "$app/Contents/MacOS/"
ditto "$native_bin/V2rayMNative_V2rayM.bundle" "$app/Contents/Resources/V2rayMNative_V2rayM.bundle"
ditto "$native_bin/V2rayMNative_V2rayMKit.bundle" "$app/Contents/Resources/V2rayMNative_V2rayMKit.bundle"
cp "$repo_root/macos/Native/Assets/AppIcon.icns" "$app/Contents/Resources/"
info="$app/Contents/Info.plist"
plutil -create xml1 "$info"
while read -r key value; do
  plutil -insert "$key" -string "$value" "$info"
done <<PLIST
CFBundleIdentifier io.github.CJMVPU.v2rayM
CFBundlePackageType APPL
LSMinimumSystemVersion 15.0
CFBundleName v2rayM
CFBundleDisplayName v2rayM
CFBundleExecutable V2rayM
CFBundleIconFile AppIcon.icns
NSPrincipalClass NSApplication
CFBundleShortVersionString $APP_VERSION
CFBundleVersion $APP_BUILD
NSHumanReadableCopyright Based on v2rayN. Licensed under GPL-3.0.
PLIST
plutil -insert V2rayMTunAcceptanceProtocol -integer 1 "$info"
plutil -insert LSUIElement -bool NO "$info"
plutil -insert NSHighResolutionCapable -bool YES "$info"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM "$app/Contents/MacOS/V2rayM"
"$repo_root/scripts/project-tool" macos-build-manifest write-app --snapshot "$snapshot" --app "$app"
codesign --force --sign "$signing_identity" --options runtime "$app"
codesign --verify --strict --deep "$app"
"$repo_root/scripts/project-tool" macos-build-manifest verify-app --app "$app"
echo "Prepared native SwiftUI application: $app"
