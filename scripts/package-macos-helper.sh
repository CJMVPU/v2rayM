#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${1:?Usage: package-macos-helper.sh <backend-publish-directory> <new-output.app>}"
app="${2:?Specify a new output .app directory}"
signing_identity="${SIGN_IDENTITY:--}"
core_bin="${CORE_BIN_DIR:-}"
[[ "$(uname -s)" == Darwin ]] || { echo 'This package requires macOS.' >&2; exit 1; }
[[ -x "$backend/v2rayN.WebAPI" && "$app" == *.app && ! -e "$app" ]] || {
  echo 'Provide a native backend publish directory and a new .app path.' >&2; exit 1;
}
architecture="$(lipo -archs "$backend/v2rayN.WebAPI")"
case "$architecture" in arm64|x86_64) ;; *) echo 'Backend must have one macOS architecture.' >&2; exit 1 ;; esac
if [[ "$signing_identity" != - ]]; then
  [[ -n "$core_bin" && -f "$core_bin/xray/xray" && -f "$core_bin/sing_box/sing-box" ]] || {
    echo 'Signed packages require CORE_BIN_DIR with xray/xray and sing_box/sing-box.' >&2; exit 1;
  }
fi
build_dir="${SWIFT_SCRATCH_PATH:-${TMPDIR:-/tmp}/v2raym-helper-build-$architecture}"
swift build --package-path "$repo_root/macos/TunHelper" --scratch-path "$build_dir" \
  --configuration release --arch "$architecture"
swift_bin="$(swift build --package-path "$repo_root/macos/TunHelper" --scratch-path "$build_dir" \
  --configuration release --arch "$architecture" --show-bin-path)"

python3 - "$backend" "$app" "$core_bin" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

backend, app = map(Path, sys.argv[1:3])
destination = app / 'Contents/Resources/Backend'
shutil.copytree(backend, destination, ignore=shutil.ignore_patterns(
    '.env', 'guiConfigs', 'guiLogs', 'guiTemps', 'guiBackups', 'binConfigs', 'WebAPIData', '*.instance.lock'))
if sys.argv[3]:
    core_bin = Path(sys.argv[3])
    for kind, name in [('xray', 'xray'), ('sing_box', 'sing-box')]:
        target = destination / 'bin' / kind
        target.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(core_bin / kind / name, target / name)
        (target / name).chmod(0o755)
(app / 'Contents/MacOS').mkdir()
(app / 'Contents/Library/LaunchDaemons').mkdir(parents=True)
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(dict(CFBundleIdentifier='io.github.CJMVPU.v2rayM', CFBundleName='v2rayM Helper Setup',
        CFBundleExecutable='V2rayMHelperClient', CFBundlePackageType='APPL', CFBundleVersion='0.1.0',
        CFBundleShortVersionString='0.1.0', LSMinimumSystemVersion='15.0', LSUIElement=True), output)
PY
cp "$swift_bin/V2rayMHelper" "$swift_bin/V2rayMHelperClient" "$app/Contents/MacOS/"
cp "$repo_root/macos/Resources/io.github.CJMVPU.v2rayM.tun-helper.plist" "$app/Contents/Library/LaunchDaemons/"
if [[ -n "$core_bin" ]]; then
  for kind in xray sing_box; do
    name=sing-box; [[ "$kind" != xray ]] || name=xray
    case " $(lipo -archs "$app/Contents/Resources/Backend/bin/$kind/$name") " in
      *" $architecture "*) ;;
      *) echo "Core architecture mismatch: $kind" >&2; exit 1 ;;
    esac
    codesign --force --sign "$signing_identity" --options runtime \
      --identifier "io.github.CJMVPU.v2rayM.core.$kind" "$app/Contents/Resources/Backend/bin/$kind/$name"
  done
fi
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.tun-helper "$app/Contents/MacOS/V2rayMHelper"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.bridge "$app/Contents/MacOS/V2rayMHelperClient"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.backend \
  --entitlements "$repo_root/macos/Resources/Backend.entitlements" "$app/Contents/Resources/Backend/v2rayN.WebAPI"
codesign --force --sign "$signing_identity" --options runtime "$app"
codesign --verify --strict --deep "$app"
echo "Prepared helper integration bundle: $app"
if [[ "$signing_identity" == - ]]; then
  echo 'Development artifact only: ad-hoc signing cannot authorize this helper. No system service was registered.'
fi
