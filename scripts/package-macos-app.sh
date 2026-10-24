#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export APP_VERSION="${APP_VERSION:-$(cat "$repo_root/VERSION")}"
export APP_BUILD="${APP_BUILD:-$APP_VERSION}"
if [[ ! "$APP_VERSION" =~ ^[0-9]\.[0-9]\.[0-9]$ || "$APP_BUILD" != "$APP_VERSION" ]]; then
  echo 'Use three single-digit version components; APP_BUILD must equal APP_VERSION.' >&2
  exit 1
fi
python3 "$repo_root/scripts/check-macos-product-boundaries.py"
python3 "$repo_root/scripts/prepare-macos-geo.py" --verify-only
for resource in ipv4.bin ipv6.bin places.bin ATTRIBUTION.txt; do
  if [[ ! -s "$repo_root/macos/Native/Sources/V2rayM/Resources/Globe/$resource" ]]; then
    echo "Missing globe resource: $resource. See docs/globe-dashboard.md before packaging." >&2
    exit 1
  fi
done
backend="${1:?Usage: package-macos-app.sh <backend-publish-directory> <new-output.app>}"
python3 "$repo_root/scripts/macos-build-manifest.py" verify-backend --backend "$backend"
app="${2:?Specify a new output .app directory}"
architecture="$(lipo -archs "$backend/v2rayN.WebAPI")"
signing_identity="${SIGN_IDENTITY:--}"
build_dir="${NATIVE_SCRATCH_PATH:-${TMPDIR:-/tmp}/v2raym-native-build-$architecture}"
swift build --disable-sandbox --package-path "$repo_root/macos/Native" --scratch-path "$build_dir" --configuration release --arch "$architecture" --product V2rayM
native_bin="$(swift build --disable-sandbox --package-path "$repo_root/macos/Native" --scratch-path "$build_dir" --configuration release --arch "$architecture" --show-bin-path)"
bash "$repo_root/scripts/package-macos-helper.sh" "$backend" "$app"
cp "$native_bin/V2rayM" "$app/Contents/MacOS/"
ditto "$native_bin/V2rayMNative_V2rayM.bundle" "$app/Contents/Resources/V2rayMNative_V2rayM.bundle"
cp "$repo_root/macos/Native/Assets/AppIcon.icns" "$app/Contents/Resources/"
python3 - "$app/Contents/Info.plist" "${CORE_BIN_DIR:-}" "$app/Contents/Resources/Backend/bin" <<'PY'
from pathlib import Path
import os
import plistlib
import shutil
import sys
path = Path(sys.argv[1])
with path.open('rb') as source:
    info = plistlib.load(source)
info.update(CFBundleName='v2rayM', CFBundleDisplayName='v2rayM', CFBundleExecutable='V2rayM', CFBundleIconFile='AppIcon.icns',
            LSUIElement=False, NSHighResolutionCapable=True, NSPrincipalClass='NSApplication',
            CFBundleShortVersionString=os.environ.get('APP_VERSION', info['CFBundleShortVersionString']),
            CFBundleVersion=os.environ.get('APP_BUILD', os.environ.get('APP_VERSION', info['CFBundleVersion'])),
            NSHumanReadableCopyright='Based on v2rayN. Licensed under GPL-3.0.')
with path.open('wb') as output:
    plistlib.dump(info, output)
# Generated upstream configurations refer to bundled GeoIP/rule data in addition to the core executables.
if sys.argv[2]:
    source, destination = Path(sys.argv[2]), Path(sys.argv[3])
    for item in source.iterdir():
        if item.is_file() and item.name in {'geoip.dat', 'geosite.dat', 'core-bundle-source.json'}:
            shutil.copyfile(item, destination / item.name)
PY
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.bridge "$app/Contents/MacOS/V2rayMHelperClient"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM "$app/Contents/MacOS/V2rayM"
python3 "$repo_root/scripts/macos-build-manifest.py" write-app --backend "$backend" --app "$app"
codesign --force --sign "$signing_identity" --options runtime "$app"
codesign --verify --strict --deep "$app"
python3 "$repo_root/scripts/macos-build-manifest.py" verify-app --app "$app"
echo "Prepared native SwiftUI application: $app"
