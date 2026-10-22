# macOS TUN helper 接入

v2rayM 通过普通用户 WebAPI、原生 XPC 客户端和 macOS 特权 helper 启动 Xray 原生 TUN 内核。
配置仍由 ServiceLib 生成，helper 不实现代理协议，也不接收管理员密码或任意 shell 命令。

当前已实现接口、启动适配、helper、签名打包入口和隔离测试。
2026-10-21 已在本机使用 Apple Development 身份完成应用、helper、桥接客户端和内核签名，
验证了 SMAppService 注册与系统授权、root helper 启动、真实 XPC 状态通信及后端 helper 探测。
同日用户执行本机自检，Xray TUN 的无显式代理 HTTPS 请求、重启、正常停止及路由/DNS/接口恢复均通过。
原生界面现已接通同一后端接口；新界面的真实联网操作仍需用户在暂停其他 TUN 后实际验收。
ad-hoc 开发包会明确拒绝建立特权连接，不能当作已经可用的 TUN 客户端。

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
helper 收到退出信号时清理所有会话。内核显式加入 helper 的 launchd 进程组，plist 保留进程组清理，并设置 30 秒退出预算。
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

先按仓库 README 发布 `osx-arm64` 或 `osx-x64` 后端，再创建新的开发集成包：

```sh
bash scripts/package-macos-helper.sh /tmp/v2raym-backend/osx-arm64 /tmp/V2rayM-Development.app
```

默认使用 ad-hoc 签名，仅检查构建和签名结构，不注册服务。
`SIGN_IDENTITY` 可指定实际签名身份；签名包还要求 `CORE_BIN_DIR` 指向匹配架构的内核目录，包含 `xray/xray`。
脚本分别为内核、helper、客户端、后端和应用签名；.NET JIT 权限只授予普通用户后端。
该脚本生成独立的 helper 集成包。完整 SwiftUI 应用使用 `scripts/package-macos-app.sh`，详见仓库 README。
`scripts/check-macos-helper-signing.sh` 使用临时程序验证真实 Apple 签名的 Team ID 读取、ad-hoc 拒绝及相对启动参数下的实际路径解析，
需要本机可用签名身份，但不会注册服务或修改系统网络。

具备有效签名且完成包校验后，在该应用包内执行以下命令注册服务：

```sh
/path/to/V2rayM.app/Contents/MacOS/V2rayMHelperClient register
/path/to/V2rayM.app/Contents/MacOS/V2rayMHelperClient approval
/path/to/V2rayM.app/Contents/MacOS/V2rayMHelperClient status
```

`register` 可能返回 `requiresApproval` 和退出码 2，需要用户在系统设置允许后台服务，再检查 `status`。
卸载使用同一客户端的 `unregister`。代码不会自动注册 helper，也不会代用户确认系统授权。
签名身份缺失时继续完成源码和隔离验证；获取 Apple Developer 账号本身免费，Developer ID 对外分发属于付费计划。
参见 [Apple 账号](https://developer.apple.com/help/account/basics/about-your-developer-account)、
[Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)、
[Service Management](https://developer.apple.com/documentation/servicemanagement/)。

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

### 已完成与待完成的验证

验证包含共享库与 WebAPI 回归、helper 配置和签名策略、进程归属与清理、模拟桥接协议、独立数据目录、无 helper 时拒绝启用、SSE 及正常退出。
原 macOS 实例锁的 PID 读取问题已通过 Unix flock 路径修复。
已验证实际 Apple Development 签名、SMAppService 注册审批、root helper 启动、XPC 状态通信和后端 helper 探测。
helper 隔离测试 17 项及签名/启动路径回归 3 项通过；签名包的普通代理本机集成检查通过，使用回环测试流量。
2026-10-21 的 Xray 实机自检通过：Google HTTPS 返回 204、Cloudflare HTTPS 返回 200、重启后 Google 返回 204；
测试路由进入新增 utun，停止后特权 PID 列表为空，路由、DNS、系统代理及接口恢复检查均通过。
原生测试新增 13 项 TUN 状态/切换/回滚/冲突检查；签名包集成检查覆盖原生 TUN 状态及关闭接口，不在自动测试中接管网络。
界面实测覆盖缺少节点、其他 TUN 冲突时拒绝接管及保持关闭状态。
sing-box TUN、长时间运行、网络切换、休眠唤醒、异常退出及新界面下的完整联网切换仍需后续验收。

2026-10-21 的 0.1.4 本机开发包完成后端 398 项、原生状态 21 项及 helper 23 项检查。
隔离集成检查实测官方下载 Xray、同步特权缓存、替换正在运行的普通代理内核、自动重连后继续转发 HTTP，并核对普通与特权内核摘要一致、旧版和暂存目录已清理。
设置页“更新全部模块”实测完成 Xray、Mihomo、sing-box、五个 Geo 数据文件及十五个 SRS 文件的更新；最终界面能在维护期间读取进度，完成后解除操作锁定，更新结果留在卡片内。
菜单栏 V 图标、显示窗口和退出由用户手动确认，退出后的应用与后端进程清理由本机检查确认。
更新后的特权内核尚未再次接管真实网络；当前 v2rayN 仍在使用 TUN，需用户安排切换后单独完成这一项联网验收。

0.1.5 默认开启 Xray、Mihomo、sing-box 的预发布检查，实测安装 Xray 26.10.17、Mihomo alpha-94b13ae、sing-box 1.15.0-alpha.12；Xray 和 sing-box 特权缓存与普通版本摘要一致。
更新按钮合并为一行，GeoIP/Site 与 SRS 规则集可独立更新；文件摘要和时间戳检查确认不会改动对方资源，隔离代理实测两类更新均自动重启当前内核并恢复转发。
后端 400 项与原生状态 22 项检查通过；窗口整体固定为 1000 × 680，页面切换左对齐，移除标题栏名称和底部未使用空间，日志单行左对齐。

0.1.6 的原生界面将系统代理与 TUN 改为互斥，切换前检查 TUN 冲突，关闭当前模式停止内核并清除 TUN 启用意图，失败时尝试恢复原模式。后台服务失联时仍保留独立的系统代理恢复入口。
Xray 的现有 TUN 配置由 sing-box 前置接入，因此保留 sing-box 及其安全更新机制。原生订阅界面和管理操作移除，共享后端兼容功能保留。
日志改为有序增量读取和 10,000 行环形保留，并限制字符总量；原生文本视图不显示滚动条，长行可横向滚动，追加记录不重置水平位置。

### 0.1.7 界面与原生 TUN 能力核对

原生界面默认进入主页，导航仅用选中文字着色，设置页隐藏滚动条，路由规则使用单选项。节点表分别展示传输方式和传输安全（TLS / REALITY），关闭与最小化改为贴上边框的自定义控件，隐藏系统最大化按钮。

现有 Xray TUN 链路仍使用上游 legacy-protect 配置生成的 sing-box 前置入口。这个依赖属于当前配置生成和生命周期实现；Xray 官方已有 macOS 原生 TUN 入站，本机 26.10.17 版本也通过 `run -test` 的 `protocol: tun` 配置校验。配置校验不证明系统接管、DNS 恢复或故障恢复已通过实测。项目已有 Xray 原生 TUN 配置生成与 helper 启动支持；`EnableLegacyProtect=true` 默认使用 sing-box 前置入口。后续切换到原生路径时，需要验证上述行为后才能移除前置依赖。

### 0.1.8 界面密度调整

节点页底栏固定为 34 点，无选中项时保留操作区域占位，不再因“设为当前节点”按钮出现而改变布局；节点名称单元格高度压到 22 点并采用小号表格控件。路由单选项横向排在标签同一行，选中导航使用上圆角、底边开放并与内容相接的样式。关闭和最小化维持原有动作，背景改为常驻红色与黄色。代理、TUN 和更新流程未改变。

### 0.1.9 Xray 原生 TUN

macOS 启用 TUN 时关闭 legacy-protect，启动前再次对配置副本归一化。macOS TUN 启动策略只允许主 Xray，拒绝前置上下文及其他内核，避免回退到 sing-box。共享 ServiceLib 的跨平台默认值保持不变。

helper 为 Xray 选择可用 utun 名称，保留出站接口绑定，并从 TUN IPv4 网关派生 DNS。系统 DNS 使用 SystemConfiguration 的临时动态存储条目，不改写网络服务保存的 DNS；正常停止先移除条目，再结束内核。内核退出、XPC 断开和 helper 退出均有清理路径。清理失败会明确报告且保留仍能服务 DNS 的内核以便重试。新后端要求 helper 协议 2，旧 helper 不会被误当作支持新 DNS 生命周期。

窗口增加 1.5 点边框，标题栏分隔线加粗至 2 点。

验证分界：配置生成测试、DNS 生命周期测试及普通 Xray 代理流量可在保留现有 v2rayN 时完成。真实 TUN HTTP/DNS、重启与恢复验收需用户手动暂停 v2rayN 后执行。此次专用 TEST-NET 路由测试被自动审批拒绝，未启动；用户选择保留新版并稍后测试。

稍后可双击 `artifacts/releases/原生TUN本机测试.command`。入口使用 v2rayM 的节点副本，准备好后等待操作者按回车，再检查其他 TUN/系统代理已暂停后测试；本机程序带两分钟超时与结果落盘，聊天断开不影响执行。测试结束后操作者恢复 v2rayN，再读取结果。

### 0.1.10 — native TUN acceptance, log records, and settings

The operator completed `artifacts/macos-tun-tests/20261021-205544-ikm5ydw0/result.json`:
Xray was the only privileged child, Google returned 204, Cloudflare returned 200,
restart traffic returned 204, the temporary gateway DNS was observed, and stopping
restored routes/DNS/system proxy state with no new interfaces or privileged PIDs left.
This accepts the 0.1.9 native TUN traffic path; 0.1.10 additionally passes isolated
settings read/write and ordinary Xray traffic checks without taking over host networking.

Pipe output is framed by newline before decoding UTF-8, retaining partial records
between reads. Large reads are consumed in full; pathological individual records are
bounded. The helper queue is limited by both records and bytes. The backend stores
separate lines in the existing 10,000-entry ring; the native view preserves embedded
newlines instead of replacing them with spaces. Horizontal scrolling remains enabled
and both scrollbars remain hidden.

The native app and signed helper now accept/update only Xray for privileged execution.
The shipped app omits sing-box and SRS data; native update controls omit their targets.
At 0.1.10, shared compatibility code still existed. This historical scope was superseded
by the explicit Xray-only decision in 0.1.11: ServiceLib/WebAPI compatibility generators,
models, templates, downloads and runtime fallbacks were removed. Current Geo updates
use only GeoIP/GeoSite DAT files. Existing unsupported node records are preserved but
rejected explicitly when used; they are never silently mapped to another engine.

Settings provides three editors:
- Parameters: inbound/LAN/sniffing, Xray logging/fingerprint/mux/fragment, app/statistics/
  speed testing, and native TUN MTU/IPv6/excluded CIDRs. Native TUN options participate
  in the same validated settings transaction and rollback as ordinary parameters.
- Routing: create/copy/delete/select profiles, Xray domain strategy, ordered enabled
  rules for domains/IP/ports/network/protocol/inbound tags and proxy/direct/block.
- DNS: shared simple DNS and separately saved Xray normal/TUN custom DNS. The TUN
  gateway and temporary system resolver remain helper-managed. Unsaved editor changes
  are guarded on close; DNS saves preserve pending changes in the other DNS section.

Hidden upstream options are round-tripped, not reset by the Mac forms. Live proxy
ports are not editable until the proxy is off. Settings writes are awaited on app quit.

### 0.1.11 — Xray-only product boundary

The current product supports only Xray, including native TUN. The upstream merge
contract is `docs/upstream-merge-policy.md`; `scripts/check-macos-product-boundaries.py`
runs in CI and packaging. MTU is validated in the 1280–65535 range. Node editing,
fixed table columns and the native UI remain independent of privileged launch policy.

Validation: 412 backend tests, 39 native tests, 31 helper tests, and packaged loopback
traffic/settings/editor smoke checks passed. The previous 0.1.9 real TUN report is
retained as historical acceptance; 0.1.11 has not taken over the host network during
this update.
