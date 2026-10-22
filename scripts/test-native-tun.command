#!/bin/bash
set -u
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 "$script_dir/test-macos-tun-local.py"
result=$?
printf '\n本机测试已结束（退出码 %s）。请先查看上方网络恢复结果，再手动恢复 v2rayN。\n' "$result"
read -r -p '按回车关闭此入口：' _
exit "$result"
