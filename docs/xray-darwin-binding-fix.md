# Xray 26.10.21 Darwin 出口绑定修复

本补丁针对本机日志中的 Xray 26.10.21，源码提交
`1b1647cd9ddf0abc34b981d4611fc03bcac1ca74`，不是较早的 Xray 版本。

`proxy/tun/tun_darwin.go` 的 `setinterface` 为 IPv6/双栈 socket 设置
`IPV6_BOUND_IF` 后，继续设置 IPv4 的 `IP_BOUND_IF`，Darwin 返回 `EINVAL`。
UDP 的 wildcard ListenPacket 会选择双栈 socket，因此即使目标是 IPv4，也可能失败。
补丁只消除错误的 fallthrough，保留自动出口网卡绑定及失败传播，避免 TUN 回环。

## 可复现构建与隔离检查

运行 `scripts/build-macos-xray.py --go /path/to/go --output /tmp/new-core-dir`。
它要求 Go 1.27.3 Darwin，校验固定源码归档 SHA-256，应用
`patches/xray/darwin-bound-interface.patch`，运行 socket 测试并构建内核。
当前默认构建同时包含进程查询诊断补丁，build 字段为 `1b1647c-v2raym-darwin-bind2`，主页显示 `26.10.21（修复版 M2）`。
源代码、补丁和构建脚本应随修改后的核心分发，保留上游 LICENSE。

`scripts/xray/bind_darwin_test.go` 覆盖 IPv4、IPv6/双栈 TCP/UDP 的 socket
选项、无效网卡必须报错，以及 wildcard UDP 到回环接收端的实际数据收发。
这些测试不创建 utun，不修改系统路由、DNS、代理，不使用真实节点。
修复前的 socket 测试中 IPv6 TCP/UDP 返回 invalid argument；修复后全部通过。
这不代替安装后的真实 TUN、DNS 和停止恢复验收。

## 安全与更新

- 应用仍通过代码签名保护打包内核。helper 验证最终私有副本，补丁不开放任意路径执行。
- 已认证的 root 缓存若仍是受影响的 26.10.21，先校验缓存完整性，再回到签名应用内核。
  缓存被篡改仍报错，不借“回退”忽略安全失败。
- 检查单个内核、直接更新和更新全部模块共用修复版策略。同版本在现有进度状态显示
  “已安装同版本修复版，无需更新”；较早版本也不下载、不覆盖。检查失败不能假报无需更新。
- 用户确认的规则：原生 macOS 客户端遇到新的上游版本时提示“等待验证后再替换内核”，不下载替换。
  检查正式版和预发布版列表，按版本号选择最新可用条目；最新版本转正后不回退到较早的预发布条目。
  单独更新和批量更新都保留候选版本并发布 `awaiting-validation` 状态，Geo 数据更新可独立完成。
  用户再次要求检查后，对该精确版本审查源码、运行绑定与回环回归，再安排真实 TUN 验收。
  确认可替代补丁后才修改兼容策略并放行升级；版本变大本身不是修复证明。
- 上游版本与本地补丁标识分开比较；保留原始 release tag，避免特权缓存同步逻辑把
  同版本官方包当成必须重装的版本，也不伪造更大的版本号来“压过”上游。
- 若上游已修复，移除该本地补丁并恢复官方内核，继续执行官方摘要、私有副本校验、
  启动检查及失败回滚；若仍未修复，则保留当前版本或在用户要求下移植最小补丁。
- 更新安装层和打包入口仍拒绝未修复的 26.10.21，作为绕过版本检查时的第二道保护。
- 本地补丁通过应用包交付，不伪装成官方发布资产，不绕过 helper 的官方更新摘要校验。
  合并未来 Xray 源码时，应先移植或确认上游修复，并重新运行 socket 回归。

## 日志处理边界

保留真实连接探测，以便及时发现内核监听失效。macOS 的只读监听表在关闭 socket 后
可能短暂保留记录，不能单独作为健康判据。仅在日志入口丢弃完全匹配的
Info 级 `Connection closed immediately, likely health check connection`；同样文字的
Warning/Error、出口失败、进程查询失败及连接重置均保留。

进程查询 `not found` 可能发生在连接或进程已经结束时；原日志也包含查询失败后继续
成功直连的记录，不能据此认定所有这些请求失败。UDP 443 的 block 是既有路由策略；
连接重置可能来自对端。这些信息不通过删除安全规则或广泛屏蔽日志来“修复”。

## 进程查询后续调查

M2 候选的回环复现、诊断分类补丁与未安装边界见
[xray-process-lookup-fix.md](xray-process-lookup-fix.md)。0.2.2 的完整签名包使用 M2。
