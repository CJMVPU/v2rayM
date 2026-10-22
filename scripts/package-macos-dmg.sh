#!/usr/bin/env bash
set -euo pipefail
app="${1:?Usage: package-macos-dmg.sh <signed-app> <new-output.dmg>}"
output="${2:?Specify a new output .dmg}"
[[ "$(uname -s)" == Darwin && -d "$app" && "$app" == *.app && "$output" == *.dmg && ! -e "$output" ]] || {
  echo 'Provide a signed .app and a new .dmg output path on macOS.' >&2; exit 1;
}
codesign --verify --deep --strict "$app"
staging="$(mktemp -d "${TMPDIR:-/tmp}/v2raym-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"
cat > "$staging/安装说明.txt" <<'TEXT'
v2rayM 本机开发版

1. 将应用拖入 Applications 文件夹；更新时先退出旧版 v2rayM。
2. 从“应用程序”打开 v2rayM，使用标题栏的“导入节点”添加节点，并选为当前节点。
3. 先暂停 v2rayN 或其他软件的 TUN，再开启 v2rayM 顶部的 TUN 开关。
4. 若提示后台服务未就绪，在“设置 → TUN 后台服务”中点击“安装并授权后台服务”，按系统提示完成授权。
5. 系统代理与 TUN 互斥：开启一个会自动关闭另一个并连接节点，关闭当前开关即停止代理。

本包使用 Apple Development 签名，供签名开发者自己的 Mac 测试使用，未经过 Apple 公证。
应用使用独立的 v2rayM 数据目录，不会自动迁移 v2rayN 的节点和订阅。
TEXT
hdiutil create -volname v2rayM -srcfolder "$staging" -format UDZO -fs HFS+ "$output"
hdiutil verify "$output"
echo "Prepared local installation image: $output"
