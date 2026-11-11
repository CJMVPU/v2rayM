#!/bin/zsh
# Runs locally without a chat connection. No downloads or sudo required.
set -u
repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_root" || exit 1
print 'v2rayM 0.4.4 / Xray 26.11.9 本机验收'
print '请先关闭 v2rayN 的系统代理/TUN 并退出，关闭 v2rayM 的代理/TUN。'
print '保持此终端打开。脚本使用 v2rayM 当前选中节点的临时副本。'
print '测试会短暂接管网络，完成后停止测试连接并核对恢复状态。'
/usr/bin/python3 "$repo_root/scripts/test-macos-tun-local.py" \
  --app /Applications/v2rayM.app \
  --expect-app-version 0.4.4 \
  --expect-xray-marker 676eaf6-v2raym-darwin-bind2
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
