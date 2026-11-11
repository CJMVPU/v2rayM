# Xray 26.11.9 候选验证（2026-11-10）

状态：离线验证通过；用户已明确授权先构建并安装，原生 TUN 验收稍后由用户在本机执行。自动更新等待验证策略保持不变。
用户本轮要求验证后替换；随后明确选择暂时保持 v2rayN 运行。
本轮不启动 TUN；用户明确允许在真实 TUN 验收前先安装。
首次离线验证时安装为 v2rayM 0.4.0 / Xray 26.10.21 修复版 M2。

## 固定输入与补丁审查

- 正式发布：https://github.com/XTLS/Xray-core/releases/tag/v26.11.9
- 源码提交：`676eaf66f8f05d4d558ee7a74b4736623d3feeb9`。
- GitHub API 源码归档 SHA-256：`3932cefef227439f569eb3988ca206b505467be075967a4397452a3ffe9ef033`。
- 官方 macOS arm64 ZIP SHA-256：`233f0c66681cd0726f81a6b2b6ed6a5710869e312047b522e46ed53035bebd26`，与发布资产 digest 一致。
- Go 1.27.3 Darwin arm64 工具链下载摘要与 go.dev 元数据一致。
- 上游 `setinterface` 已按 socket 地址族分别设置 `IPV6_BOUND_IF` / `IP_BOUND_IF`；候选不再应用 `darwin-bound-interface.patch`。
- 上游仍将发送端关闭导致的进程查询未命中逐条记录为 Error。官方二进制回环实验中 20/20 数据包成功转发，同时出现 20 条此类 Error。因此候选保留现有 `darwin-process-lookup.patch`，保留逐条 debug 与聚合警告，不更改路由匹配结果。
- 候选标识：`676eaf6-v2raym-darwin-bind2`。这是带本地补丁的构建，不是官方发布二进制；上游版本仍为 `26.11.9`。

## 已完成验证

1. 产品边界检查通过。
2. 未应用本地绑定补丁的新源码通过 IPv4/IPv6 TCP/UDP 出口绑定、无效网卡失败传播、wildcard UDP 回环测试。
3. 应用进程查询补丁后通过 Darwin 进程匹配、诊断、聚合与 socket 关闭后路由测试；连同绑定测试共 16 个顶层 Go 测试通过。
4. 候选编译成功，Apple Development 本机签名及 `codesign --verify --strict` 通过。
5. 签名后的候选通过 UDP 回显及 20 个已关闭发送端的数据包转发；0 条 Error，20 条逐流 debug，进程未命中产生聚合警告。
6. helper：59 项、0 失败。Swift 客户端：91 项、2 跳过、0 失败。这些是现有应用源码回归，不等于新版完整应用包验收。

本轮测试只使用回环 socket，没有启动 TUN、改路由/DNS/系统代理或操作 v2rayN。

## 本地证据和候选

全部位于 `artifacts/xray-26.11.9-review/`（忽略目录，不纳入 Git）：

- `release.json`、`source.tar.gz`、官方 ZIP 和 `official/xray`。
- `candidate/xray`、`candidate/LICENSE`、`candidate/SOURCE.txt`。
- `candidate-build-inputs.json`：待验收的构建输入；未覆盖正式 contracts。
- `candidate-build.log`：绑定/进程回归及构建输出。
- `official-loopback/result.json`、`candidate-loopback/result.json`：官方/补丁候选对照。
- `helper-tests.log`、`native-tests.log`、`verification.json`。

签名后候选 SHA-256：`30ee27462e747f56342a0d13b17915b5a632e2f3886b53719d0cf7b122d240e7`。

## 本轮交付方式

用户明确选择先安装，再自行断开 v2rayN 运行验证脚本。应用版本更新为 0.4.1，Xray 上游版本保持 26.11.9，本地进程查询补丁标识独立保留。
正式构建输入采用本次候选，构建脚本从固定输入读取补丁列表。旧绑定补丁作为历史记录保留，不再应用。

本机验收入口：`scripts/验证新版v2rayM.command`。脚本不下载依赖，通过应用内后端、签名桥接与 helper 启动测试；使用 v2rayM 节点和配置的临时副本，不修改 v2rayN。开始前拒绝其他代理内核、系统代理和占用目标路由的 TUN，检查应用版本、签名及特权缓存来源。校验真实 HTTPS、临时 DNS、TUN 路由、单一 root Xray、重启及停止后的路由/DNS/代理恢复。两分钟 watchdog 会终止测试后端，让 helper 执行断连清理；失败不标记通过。脚本通过后打开 v2rayM，由用户启用系统代理或 TUN。

构建、安装和本机预检结果单独保存在 `artifacts/releases/verification-0.4.1/`。旧应用和 v2rayM 用户数据在该目录备份。原生 TUN/真实节点联网验收必须以用户随后运行产生的 `artifacts/macos-tun-tests/` 报告为准。未提交、推送、公开发布或公证。
