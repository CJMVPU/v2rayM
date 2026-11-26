#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
core_bin="${1:?Usage: package-macos-helper.sh <verified-core-bin> <new-output.app>}"
app="${2:?Specify a new output .app directory}"
signing_identity="${SIGN_IDENTITY:--}"
export APP_VERSION="$(cat "$repo_root/VERSION")"
[[ "$(uname -s)" == Darwin && "$app" == *.app && ! -e "$app" ]] || {
  echo 'Provide a new .app output path on macOS.' >&2; exit 1;
}
python3 "$repo_root/scripts/macos-build-manifest.py" verify-core --core-bin "$core_bin"
architecture="$(lipo -archs "$core_bin/xray/xray")"
case "$architecture" in arm64|x86_64) ;; *) echo 'Xray must have one macOS architecture.' >&2; exit 1 ;; esac
build_dir="${SWIFT_SCRATCH_PATH:-${TMPDIR:-/tmp}/v2raym-helper-build-$architecture}"
swift build --disable-sandbox --package-path "$repo_root/macos/TunHelper" --scratch-path "$build_dir" \
  --configuration release --arch "$architecture"
swift_bin="$(swift build --disable-sandbox --package-path "$repo_root/macos/TunHelper" --scratch-path "$build_dir" \
  --configuration release --arch "$architecture" --show-bin-path)"

python3 - "$app" "$core_bin" <<'PY'
from pathlib import Path
import plistlib
import os
import shutil
import sys

app, core_bin = map(Path, sys.argv[1:])
# This path is part of the signed helper's launch policy across app upgrades.
destination = app / 'Contents/Resources/Backend/bin'
target = destination / 'xray'
target.mkdir(parents=True)
for name in ('xray', 'SOURCE.txt', 'LICENSE'):
    shutil.copyfile(core_bin / 'xray' / name, target / name)
(target / 'xray').chmod(0o755)
for name in ('geoip.dat', 'geosite.dat', 'core-bundle-source.json'):
    if name != 'core-bundle-source.json' or (core_bin / name).is_file():
        shutil.copyfile(core_bin / name, destination / name)
(app / 'Contents/MacOS').mkdir()
(app / 'Contents/Library/LaunchDaemons').mkdir(parents=True)
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(dict(CFBundleIdentifier='io.github.CJMVPU.v2rayM', CFBundleName='v2rayM Helper Setup',
        CFBundleExecutable='V2rayMHelperClient', CFBundlePackageType='APPL', CFBundleVersion=os.environ['APP_VERSION'],
        CFBundleShortVersionString=os.environ['APP_VERSION'], LSMinimumSystemVersion='15.0', LSUIElement=True), output)
PY
cp "$swift_bin/V2rayMHelper" "$swift_bin/V2rayMHelperClient" "$app/Contents/MacOS/"
cp "$repo_root/macos/Resources/io.github.CJMVPU.v2rayM.tun-helper.plist" "$app/Contents/Library/LaunchDaemons/"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.core.xray "$app/Contents/Resources/Backend/bin/xray/xray"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.tun-helper "$app/Contents/MacOS/V2rayMHelper"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.bridge "$app/Contents/MacOS/V2rayMHelperClient"
codesign --force --sign "$signing_identity" --options runtime "$app"
codesign --verify --strict --deep "$app"
echo "Prepared helper integration bundle: $app"
if [[ "$signing_identity" == - ]]; then
  echo 'Development artifact only: ad-hoc signing cannot authorize this helper. No system service was registered.'
fi
