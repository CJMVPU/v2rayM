#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backend="${1:?Usage: package-macos-app.sh <backend-publish-directory> <new-output.app>}"
app="${2:?Specify a new output .app directory}"
architecture="$(lipo -archs "$backend/v2rayN.WebAPI")"
signing_identity="${SIGN_IDENTITY:--}"
build_dir="${NATIVE_SCRATCH_PATH:-${TMPDIR:-/tmp}/v2raym-native-build-$architecture}"
swift build --package-path "$repo_root/macos/Native" --scratch-path "$build_dir" --configuration release --arch "$architecture" --product V2rayM
native_bin="$(swift build --package-path "$repo_root/macos/Native" --scratch-path "$build_dir" --configuration release --arch "$architecture" --show-bin-path)"
bash "$repo_root/scripts/package-macos-helper.sh" "$backend" "$app"
cp "$native_bin/V2rayM" "$app/Contents/MacOS/"
python3 - "$app/Contents/Info.plist" "${CORE_BIN_DIR:-}" "$app/Contents/Resources/Backend/bin" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys
path = Path(sys.argv[1])
with path.open('rb') as source:
    info = plistlib.load(source)
info.update(CFBundleName='v2rayM', CFBundleDisplayName='v2rayM', CFBundleExecutable='V2rayM',
            LSUIElement=False, NSHighResolutionCapable=True, NSPrincipalClass='NSApplication',
            NSHumanReadableCopyright='Based on v2rayN. Licensed under GPL-3.0.')
with path.open('wb') as output:
    plistlib.dump(info, output)
# Generated upstream configurations refer to bundled GeoIP/rule data in addition to the core executables.
if sys.argv[2]:
    source, destination = Path(sys.argv[2]), Path(sys.argv[3])
    for item in source.iterdir():
        if item.is_file() and item.suffix in {'.dat', '.mmdb', '.metadb'}:
            shutil.copyfile(item, destination / item.name)
    if (source / 'srss').is_dir():
        shutil.copytree(source / 'srss', destination / 'srss', dirs_exist_ok=True)
PY
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM.bridge "$app/Contents/MacOS/V2rayMHelperClient"
codesign --force --sign "$signing_identity" --options runtime --identifier io.github.CJMVPU.v2rayM "$app/Contents/MacOS/V2rayM"
codesign --force --sign "$signing_identity" --options runtime "$app"
codesign --verify --strict --deep "$app"
echo "Prepared native SwiftUI application: $app"
