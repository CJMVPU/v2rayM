#!/usr/bin/env bash
set -euo pipefail
rid="${1:?Usage: fetch-macos-cores.sh <osx-arm64|osx-x64> <new-destination-bin>}"
destination="${2:?Specify a new destination directory}"
case "$rid" in
  osx-arm64) bundle=v2rayN-macos-arm64 ;;
  osx-x64) bundle=v2rayN-macos-64 ;;
  *) echo 'Expected osx-arm64 or osx-x64.' >&2; exit 2 ;;
esac
[[ ! -e "$destination" ]] || { echo 'Destination already exists; refusing to replace it.' >&2; exit 1; }
ref="${CORE_BUNDLE_REF:-master}"
[[ "$ref" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo 'Invalid upstream ref.' >&2; exit 1; }
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 \
  "https://raw.githubusercontent.com/2dust/v2rayN-core-bin/$ref/$bundle.zip" --output "$temporary_directory/cores.zip"
python3 - "$temporary_directory/cores.zip" "$bundle" "$destination" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import shutil
import sys
import zipfile
archive, bundle, destination = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
prefix = bundle + '/bin/'
with zipfile.ZipFile(archive) as source:
    files = [item for item in source.infolist() if item.filename.startswith(prefix) and not item.is_dir()]
    if not files or len(files) > 4096 or sum(item.file_size for item in files) > 1024 ** 3:
        raise RuntimeError('Unexpected upstream bundle size.')
    names = {item.filename[len(prefix):] for item in files}
    if not {'xray/xray', 'sing_box/sing-box', 'geoip.dat', 'geosite.dat'}.issubset(names):
        raise RuntimeError('Upstream bundle lacks required cores or Geo data.')
    for item in files:
        relative = PurePosixPath(item.filename[len(prefix):])
        if relative.is_absolute() or '..' in relative.parts or '\\' in str(relative) or (item.external_attr >> 16) & 0o170000 == 0o120000:
            raise RuntimeError('Unsafe upstream archive entry.')
    destination.mkdir(parents=True)
    for item in files:
        target = destination / item.filename[len(prefix):]
        target.parent.mkdir(parents=True, exist_ok=True)
        with source.open(item) as incoming, target.open('xb') as output:
            shutil.copyfileobj(incoming, output)
    for name in ('xray/xray', 'sing_box/sing-box', 'mihomo/mihomo'):
        if (destination / name).is_file():
            (destination / name).chmod(0o755)
print('Official upstream core bundle SHA-256:', hashlib.sha256(archive.read_bytes()).hexdigest())
print('Prepared:', destination)
PY
