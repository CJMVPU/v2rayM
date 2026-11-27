#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tool="$repo/scripts/project-tool"
pin="$repo/contracts/macos-build-inputs.json"
go=go
library=0
source_archive=
destination=
while (( $# )); do
  case "$1" in
    --go) go="${2:?Missing Go executable}"; shift 2 ;;
    --source-archive) source_archive="${2:?Missing source archive}"; shift 2 ;;
    --output) destination="${2:?Missing output directory}"; shift 2 ;;
    --library) library=1; shift ;;
    *) echo "Unknown Xray build argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$destination" && ! -e "$destination" ]] || { echo "Specify a new output directory" >&2; exit 1; }
go=$(command -v "$go")
go_version=$(plutil -extract goVersion raw "$pin")
[[ "$("$go" version)" == *"go$go_version darwin/"* ]] || { echo "Expected Go $go_version for Darwin" >&2; exit 1; }
revision=$(plutil -extract xray.revision raw "$pin")
checksum=$(plutil -extract xray.sourceSHA256 raw "$pin")
marker=$(plutil -extract xray.buildMarker raw "$pin")
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$(dirname "$destination")"
destination=$(cd "$(dirname "$destination")" && pwd)/$(basename "$destination")
if [[ -z "$source_archive" ]]; then
  source_archive="$workspace/source.tar.gz"
  curl -fsSL --retry 3 "https://api.github.com/repos/XTLS/Xray-core/tarball/$revision" -o "$source_archive"
fi
actual=$(shasum -a 256 < "$source_archive")
[[ "${actual%% *}" == "$checksum" ]] || { echo "Pinned source archive checksum mismatch" >&2; exit 1; }
"$tool" unpack-xray-source "$source_archive" "$workspace/source"
trees=("$workspace"/source/XTLS-Xray-core-*)
[[ ${#trees[@]} == 1 && -d "${trees[0]}" ]] || { echo "Unexpected source tree" >&2; exit 1; }
cd "${trees[0]}"
if (( library )); then "$tool" xray-patches --library; else "$tool" xray-patches; fi > "$workspace/patches"
patch_list=
while IFS= read -r patch_name; do
  patch -p1 --batch < "$repo/patches/xray/$patch_name"
  patch_list="${patch_list:+$patch_list, }$patch_name"
done < "$workspace/patches"
export GOTOOLCHAIN=local CGO_ENABLED="$library"
cp "$repo/scripts/xray/bind_darwin_test.go" proxy/tun/v2raym_bind_darwin_test.go
cp "$repo/scripts/xray/process_darwin_test.go" common/net/v2raym_process_darwin_test.go
cp "$repo/scripts/xray/process_router_test.go" app/router/v2raym_process_test.go
"$go" test ./common/net ./app/router -run '^(TestV2rayM|TestFindProcessDarwin|TestDarwinSocketInfo)' -count=1 -v
"$go" test ./proxy/tun -run '^TestDarwin(OutboundSocket|WildcardUDP)Binding$' -count=1 -v
flags=(-trimpath -buildvcs=false -ldflags "-s -w -X github.com/xtls/xray-core/core.build=$marker")
out="$workspace/output"
mkdir "$out"
if (( library )); then
  cp "$repo/scripts/xray/doh_recovery_test.go" app/dns/v2raym_recovery_test.go
  cp "$repo/scripts/xray/xhttp_recovery_test.go" transport/internet/splithttp/v2raym_recovery_test.go
  "$go" test ./app/dns ./transport/internet/splithttp -run '^TestV2rayM' -count=1 -timeout=60s -v
  mkdir v2raymlib
  cp "$repo"/scripts/xray/library/*.go v2raymlib/
  binary="$out/libV2rayMXray.dylib"
  "$go" build "${flags[@]}" -buildmode=c-shared -o "$binary" ./v2raymlib
  install_name_tool -id @rpath/libV2rayMXray.dylib "$binary"
  codesign --force --sign - "$binary"
  "$tool" xray-library-receipt --library "$binary"
else
  "$go" build "${flags[@]}" -o "$out/xray" ./main
  "$out/xray" version
fi
cp LICENSE "$out/"
printf 'Xray source: %s\nArchive SHA256: %s\nPatches: %s\nBuild: %s\n' "$revision" "$checksum" "$patch_list" "$marker" > "$out/SOURCE.txt"
[[ ! -e "$destination" ]]
mv "$out" "$destination"
