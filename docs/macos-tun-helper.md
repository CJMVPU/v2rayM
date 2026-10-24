# macOS TUN helper 接入

v2rayM 通过普通用户 WebAPI、原生 XPC 客户端和 macOS 特权 helper 启动 Xray 原生 TUN 内核。
配置仍由 ServiceLib 生成，helper 不实现代理协议，也不接收管理员密码或任意 shell 命令。

当前产品仅运行 Xray。helper 的开发签名、注册、XPC 状态通信与真实网络验收分别记录；
开发签名包未公证，ad-hoc 包不能建立特权连接。历史多内核设计已退役，旧记录保存在 Git。

## 调用链路

```text
SwiftUI 或已认证本机 API 客户端
  → WebAPI /api/macos/tun
  → ServiceLib 生成 TUN 配置
  → CoreManager 的 IPrivilegedCoreLauncher 扩展点
  → V2rayMHelperClient 的受控输入输出
  → NSXPCConnection
  → SMAppService 管理的 V2rayMHelper
  → 已签名内核的私有副本
```

`macos/TunHelper` 是独立 Swift Package，包含 helper、XPC 客户端、协议、配置策略和测试。
`v2rayN.WebAPI/MacOS` 负责 C# 适配与资源快照。
ServiceLib 仅增加可选启动适配入口和进程包装扩展，原有 Linux/Windows 路径继续保留。
普通 WebAPI 不以 root 身份运行。

## 支持范围

当前仅接受 ServiceLib 生成的 Xray 原生 TUN 配置；自定义完整配置和其他代理内核的 TUN 被明确拒绝。
普通节点使用一个特权 Xray 进程接管 TUN；helper 负责授权和生命周期，不参与代理转发。
未知的本地文件引用会拒绝启动，需要资源快照适配后再开放，不能让 root 进程直接读取任意用户指定路径。

TUN 优先使用 helper 校验并保护的官方 Xray 更新版本，没有已提交更新时使用应用内签名版本。
设置页更新 Xray 会通过下述可信更新机制更新特权内核；来源由状态接口报告。
规则文件与证书从普通用户进程读取后作为有限大小的快照传入，helper 写入自己的私有目录。
helper 不写用户指定日志路径；日志通过现有后端日志接口提供。

## 权限和进程归属

XPC 两端均通过代码签名 requirement 检查对端，限定 Apple 签发的同一 Team ID 和固定程序 identifier。
读取 Team ID 时显式请求 Security 的签名信息；helper 从 dyld 读取实际可执行文件路径，
不依赖 launchd 可能提供的 bundle 相对 `argv[0]`。
无有效 Team ID 的 ad-hoc 签名不能通过该边界。开发签名可用于本机开发验证，正式对外分发需要相应 Developer ID 和公证流程。

helper 从固定应用路径复制内核到 root 私有目录，检查副本的签名后执行，关闭校验与执行之间的用户目录替换窗口。
请求只包含内核类型、配置字节和数据文件快照，没有可执行文件路径、任意参数或需要停止的 PID。
每条 XPC 连接只控制自己创建的内核，内核退出由 helper 通过自有子进程句柄和 `waitpid` 确认。

正常停止先发送 SIGTERM，等待最多 8 秒；超时才对自己持有的子进程发送 SIGKILL。
发生强制终止、连接丢失或停止超时时，后端报告清理未确认，不能据此显示路由与 DNS 已恢复。
需检查系统网络状态；当前实现不会猜测并覆盖用户的全局 DNS 或路由。

后端退出导致客户端 stdin EOF，客户端请求停止；客户端退出导致 XPC 连接失效，helper 再次执行连接所属进程的清理。
断连清理失败时持续保留会话与限额，按秒重试；清理成功才释放。
helper 收到退出信号时在 20 秒预算内并行清理所有会话，仍失败则明确记录并非零退出。内核显式加入 helper 的 launchd 进程组，plist 保留进程组清理，并设置 30 秒退出预算。
这些进程控制路径已有普通用户进程测试，实际 launchd 崩溃、系统重启及真实 TUN 网络恢复仍需签名后的实机验证。

## API

以下接口沿用现有 Bearer 会话认证。它们不接收 sudo 密码。

| 接口 | 行为 |
| --- | --- |
| `GET /api/macos/tun` | 返回平台、helper 可用状态及错误码、配置开关、运行状态、受控特权内核 PID 和内核来源 |
| `PUT /api/macos/tun`，正文 `{"enabled":true}` | 检查 helper 后保存开关；运行中沿用设置事务重启，失败回滚 |
| `PUT /api/macos/tun`，正文 `{"enabled":false}` | 关闭配置；运行中停止原 TUN 内核并按普通代理配置重启 |
| 现有 `/api/core/start`、`stop`、`restart` | 使用上述配置，TUN 启动走 helper，普通启动走原路径 |

helper 缺失、未授权、签名或协议不匹配时，启用请求失败，原设置保持不变。
`enabled` 表示保存的配置意图，不证明隧道接口或真实流量已经正常。
macOS capability 增加 `macos.tun.helper`；Linux/Windows 的无头 TUN 拒绝规则保持原样。

## 原生界面

标题栏提供互斥的系统代理与 TUN 开关；“运行中”还要求实际持有对应内核进程。
开启 TUN 时先检查选中节点、helper 和其他隧道，再启用并连接；关闭当前模式即停止代理。切换模式通过后端事务完成。
启动失败时回滚本次新开启的模式，已保存的原有模式意图不会被失败重连清除；回滚失败会明确报告。
普通连接、节点选择和系统代理自动连接也会在 TUN 模式下检查冲突，不能绕过开关入口的保护。
设置页提供主动注册和系统授权入口，不会在启动时自动注册服务。正常退出在 TUN 模式下先确认内核停止。

## 数据目录

macOS WebAPI 默认使用 `~/Library/Application Support/v2rayM/`。
可用 `V2RAYM_DATA_HOME` 指定测试或独立实例目录，兼容已有 `V2RAYN_DATA_HOME` 输入。
数据库、配置、日志、临时文件、用户内核和实例锁都经 ServiceLib 的统一路径入口定位。
不会自动导入或修改旧 `v2rayN` 目录。

## 构建与授权

Swift helper 组件最低 macOS 13；当前集成开发包以 macOS 15 为最低系统。
需要 Xcode 工具链、.NET 10 SDK 和 Python 3。

```sh
swift test --package-path macos/TunHelper
SIGN_IDENTITY='Apple Development: Your Name (...)' bash scripts/check-macos-helper-signing.sh
dotnet build v2rayN/v2rayN.slnx --configuration Release
dotnet test --project v2rayN/v2rayN.WebAPI/Tests --configuration Release
```

完整应用按 [README](../README.md) 使用 `build-macos-product.py` 一致构建。
脚本为内核、helper、客户端、后端和应用分别签名；.NET JIT 权限只授予普通用户后端。
`scripts/check-macos-helper-signing.sh` 使用临时程序验证 Team ID 读取、ad-hoc 拒绝及实际路径解析，
需要本机可用签名身份，不注册服务或修改系统网络。

具备有效签名且完成包校验后，在该应用包内执行以下命令注册服务：

```sh
/path/to/V2rayM.app/Contents/MacOS/V2rayMHelperClient register
/path/to/V2rayM.app/Contents/MacOS/V2rayMHelperClient approval
/path/to/V2rayM.app/Contents/MacOS/V2rayMHelperClient status
```

`register` 可能返回 `requiresApproval` 和退出码 2，需要用户在系统设置允许后台服务，再检查 `status`。
卸载使用同一客户端的 `unregister`。代码不会自动注册 helper，也不会代用户确认系统授权。
## 界面内更新 TUN 内核

原生客户端通过已签名桥接进程请求更新。helper 只接受 XTLS/Xray-core 的固定官方发布路径、当前机器架构及有限大小的归档；独立读取 GitHub 发布资产元数据并核对 SHA-256 后，才检查并执行新内核。没有摘要、内容不匹配、路径越界、链接或签名结构损坏均拒绝安装。

更新文件位于 root 专用目录 `/Library/Application Support/io.github.CJMVPU.v2rayM.VerifiedCores`。下载校验期间继续使用原内核，切换时保留上一版本；新版本恢复运行成功后提交并删除旧版。失败、helper 重启或未在两分钟内确认成功时恢复上一版本（或包内版本）。每次 TUN 启动仍检查保护目录中的文件及其摘要，不接受调用者指定的可执行路径。

设置页展示下载字节进度及安装、重启、回滚阶段。更新进行期间限制重复操作，更新结果仅出现在对应卡片中。成功提交后清理已替换的旧版本，失败则恢复上一版本。

## 验证边界

### 断开聊天时的本机自检

先在普通用户终端运行：

```sh
./scripts/test-native-tun.command
```

脚本默认使用 `/Applications/v2rayM.app`，将当前 v2rayM 选中节点、设置与数据库复制到独立临时数据目录；不写入原始数据。
准备阶段检查签名、后端及 helper，不会自动启动内核；随后等待用户在本机终端按回车。
用户应先手动暂停 v2rayN 的 TUN、断开内核并关闭系统代理，再按回车开始。
仍有其他 TUN、系统代理或 v2rayN 内核运行时，检查会拒绝开始。

联网检查在本机运行，不依赖聊天连接，验证无显式代理的 HTTPS 请求、内核重启及停止后的路由、DNS 和接口恢复。
TUN 阶段设有两分钟超时保护；失败或取消后尝试停止本次内核，并终止本次启动的后端以关闭 XPC 租约。
恢复状态以报告为准，不自动改写全局路由/DNS，也不会替用户重新启用 v2rayN。
保持终端打开，等脚本显示结果保存完毕后，用户再手动恢复 v2rayN。

结果和受保护的本机日志位于忽略提交的 `artifacts/macos-tun-tests/`；`latest.txt` 指向最近一次联网测试的 `result.json`。
测试用的节点和数据库副本在结束后删除。只检查准备阶段可加 `--check-only`，不会启用 TUN，结果指针为 `latest-check-only.txt`。

### 验收记录与限制

当前自动回归覆盖配置/签名策略、调用者归属、清理重试、取消、更新中断与回滚、日志双限额及普通 Xray 回环；详见[最终收敛记录](audits/2026-10-24-final-stabilization.md)。

2026-10-21 操作者完成的真实原生 TUN 自检记录仍保存在
`artifacts/macos-tun-tests/20261021-205544-ikm5ydw0/result.json`：无显式代理 HTTPS、重启、停止后的路由/DNS/接口恢复通过。
它仅证明当时版本和环境的行为，不作为当前版本的实网验收。后续休眠、切网、系统崩溃和长时间运行仍需独立验证。
