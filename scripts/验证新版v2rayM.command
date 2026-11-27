#!/bin/zsh
# Runs locally without a chat connection. No downloads or sudo required.
set -u
repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root" || exit 1
app_version="$(cat "$repo_root/VERSION")"
pin="$repo_root/contracts/macos-build-inputs.json"
xray_version=$(plutil -extract xray.version raw "$pin") || exit 1
marker=$(plutil -extract xray.buildMarker raw "$pin") || exit 1
[[ -n "$xray_version" && -n "$marker" ]] || exit 1
print "v2rayM $app_version / Xray $xray_version 本机验收"
print '请先关闭 v2rayN 的系统代理/TUN 并退出，关闭 v2rayM 的代理/TUN。'
print '保持此终端打开。脚本使用 v2rayM 当前选中节点的临时副本。'
print '测试会短暂接管网络，完成后停止测试连接并核对恢复状态。'
"$repo_root/scripts/network-check" tun-acceptance \
  --app /Applications/v2rayM.app \
  --expect-app-version "$app_version" \
  --expect-xray-marker "$marker"
result=$?
if (( result == 0 )); then
  print '\n验证通过。正在打开新版 v2rayM；请选择系统代理或 TUN 开始使用。'
  /usr/bin/open /Applications/v2rayM.app
else
  print '\n验证未通过，请勿忽略错误。详细原因和网络恢复结果见上方报告。'
  print '若网络已恢复，可重新打开 v2rayN；保留报告供排查。'
fi
print '\n按回车关闭此窗口…'
read -r
exit "$result"
