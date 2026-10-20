# v2rayM macOS 原生客户端架构评估

v2rayM 使用 SwiftUI 构建原生 macOS 界面，继续从 v2rayN 同步共享业务代码。
推荐先将现有 `v2rayN.WebAPI` 作为普通用户权限的本地后端，SwiftUI 通过 HTTP 与 SSE 访问它。
SwiftUI 不直接调用 C# ViewModel，也不直接读写上游 SQLite 数据库。

本评估对应初始上游基线 `66dd7da6`，共享构建版本为 `7.25.6`、目标框架为 .NET 10。
真实联网代理、系统代理、TUN、签名和公证均需要单独验证。
当前 helper 接入的实现与验证边界见 [macOS TUN helper 接入](macos-tun-helper.md)。

## ServiceLib 的复用边界

[`ServiceLib.csproj`](../v2rayN/ServiceLib/ServiceLib.csproj) 是 C# 类库，不引用 WPF、Avalonia 或 GUI 热键项目。
它包含节点与订阅管理、协议解析、SQLite 持久化、配置生成、路由、DNS、测速、统计及代理内核管理。
保留这些实现，能让协议和配置的上游修复继续进入本项目。

它还依赖 ReactiveUI，并包含 `ViewModels`、界面资源以及平台代码，并非完全与表现层分离。
例如 [`MainWindowViewModel`](../v2rayN/ServiceLib/ViewModels/MainWindowViewModel.cs) 包含剪贴板、扫码、窗口显示隐藏和设置对话框交互；
[`AppManager`](../v2rayN/ServiceLib/Manager/AppManager.cs) 使用单例、共享配置和 `IWindowDialog`。
删除所有 ViewModel 或名字含 `Gui` 的配置会扩大上游差异，并可能破坏共享功能。
这些兼容结构保留在后端，新的 SwiftUI 界面自行组织状态和交互。

## WebAPI 已有能力

[`v2rayN.WebAPI.csproj`](../v2rayN/v2rayN.WebAPI/v2rayN.WebAPI.csproj) 直接引用 ServiceLib，没有 GUI 框架依赖。
[`V2rayRuntime`](../v2rayN/v2rayN.WebAPI/Services/V2rayRuntime.cs) 自行初始化 AppManager、内核和统计，并使用
[`HeadlessWindowDialog`](../v2rayN/v2rayN.WebAPI/Adapters/HeadlessWindowDialog.cs) 满足对话框接口。
它使用自己的任务调度、写操作串行化和退出清理，不需要启动桌面 ViewModel。

| 功能 | 现有 API | SwiftUI 侧工作 |
| --- | --- | --- |
| 节点和分组 | `/api/profiles`、`/api/profile-groups`，包含编辑、导入导出、选择和排序 | 列表、编辑表单、导入入口 |
| 订阅 | `/api/subscriptions`，含更新及后台调度 | 订阅管理、更新进度 |
| 内核运行 | `/api/core/start`、`stop`、`restart`，`/api/status` | 连接状态、错误与运行配置显示 |
| 路由和 DNS | `/api/settings/routing-profiles`、`/api/settings/dns/*` | 原生设置页面 |
| 测速和统计 | `/api/speedtests`、节点计数及 SSE | 进度、结果、流量展示 |
| 日志和后台任务 | `/api/logs/page`、`/api/operations`、`/api/events` | 日志查看、任务状态与重连 |
| 内核和规则文件更新 | `/api/core-updates/*`、`/api/core/geo/update` | 根据返回的支持状态展示操作 |
| 备份和恢复 | `/api/backup/*`、WebDAV | 原生文件选择器；macOS 恢复重启流程仍需补齐 |
| 编辑器选项 | `/api/editor-options` 及 DNS 选项接口 | 动态读取，避免复制上游枚举 |

接口和 DTO 的依据是 [`WebApiEndpoints.cs`](../v2rayN/v2rayN.WebAPI/Api/WebApiEndpoints.cs)、
[`ApiModels.cs`](../v2rayN/v2rayN.WebAPI/Contracts/ApiModels.cs) 及上游的
[`FEATURE-MAP.md`](../v2rayN/v2rayN.WebAPI/FEATURE-MAP.md)。
功能表表示已有代码接口，真实内核能力取决于目标架构的内核文件及 macOS 实测。

## 必须补齐的 macOS 能力

### 系统代理

WebAPI 没有系统代理设置接口。
ServiceLib 的 [`ProxySettingOSX`](../v2rayN/ServiceLib/Handler/SysProxy/ProxySettingOSX.cs) 和
[`proxy_set_osx_sh`](../v2rayN/ServiceLib/Sample/proxy_set_osx_sh) 可作为行为参考，脚本通过 `networksetup` 修改网络服务。
现有清理行为是关闭代理，不能直接视为恢复用户原有代理设置。

建议由 macOS 系统集成层处理权限、网络服务变化和原设置快照，开启前记录配置，关闭或异常恢复时只恢复本应用拥有的修改。
启动和停止代理内核不等于系统代理已经设置成功，GUI 应分别显示两者状态。

### TUN

[`CoreLaunchPreflight`](../v2rayN/v2rayN.WebAPI/Services/CoreLaunchPreflight.cs) 保留无头默认 TUN 拒绝策略；macOS 主机通过独立策略检查 helper 可用性、生成配置及内核类型后才放行。
已实现 helper 的授权接入入口、进程归属和停止逻辑；真实路由与 DNS 清理仍需签名后的系统验证。

当前选用特权 helper 配合上游 Xray/sing-box 内核，SwiftUI 经普通用户后端控制。Network Extension 是保留的替代路线。
[`SMAppService`](https://developer.apple.com/documentation/servicemanagement) 可用于管理额外的服务程序；
[`NEPacketTunnelProvider`](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider) 需要对应 Network Extension entitlement。
Network Extension 是单独的实现路线，不能直接将现有 CLI 内核放入扩展就当作已经完成。
普通 WebAPI 不应整体以 root 权限运行。

### Clash 和桌面交互

现有 API 不开放 Clash 策略组与连接管理。若首版需要，应在后端提供窄接口，复用上游对应服务；
SwiftUI 不直接保存和操作第二份 Clash 控制器凭据。
菜单栏、原生菜单、通知、剪贴板、文件选择、快捷键和登录启动归 SwiftUI/AppKit 与 macOS 集成层所有。

### 进程生命周期和应用更新

SwiftUI 可在初期启动打包进应用的 WebAPI 子进程，传入 `--foreground --no-open`。
关闭窗口、退出应用和停止连接是三个不同动作，需要明确产品行为。
正常退出必须给后端足够的清理时间；GUI 崩溃、后端崩溃和系统重启后的代理恢复也必须单独设计。

WebAPI 的 `--stop`、后台启动及恢复重启的原生支持主要面向 Linux/Windows。
[`WebRestartCoordinator.cs`](../v2rayN/v2rayN.WebAPI/Launcher/WebRestartCoordinator.cs) 和
[`V2rayRuntime.Backup.cs`](../v2rayN/v2rayN.WebAPI/Services/V2rayRuntime.Backup.cs) 中的重启支持不包含 macOS。
[`WebUpdatePackageStager`](../v2rayN/v2rayN.WebAPI/Services/WebUpdatePackageStager.cs) 也没有 macOS 自更新包格式支持。
备份恢复接口的存在不代表恢复后自动重启已适配完成；客户端需要识别相关能力与错误。

v2rayM 应将 GUI 与随包后端作为一个应用版本更新，代理内核和规则文件保留独立更新策略。
初期不启用 API 自更新，避免后端脱离已签名应用的版本与签名边界。

## SwiftUI 与后端的接口约定

建议采用以下目录，本次评估阶段不创建空应用或占位实现：

```text
macos/
  V2rayM/              SwiftUI 界面及展示状态
  BackendClient/      HTTP、DTO、会话及 SSE
  PlatformServices/   系统代理、登录启动和后端生命周期
v2rayN/
  ServiceLib/         尽量跟随上游
  v2rayN.WebAPI/      复用上游 API，新增接口集中维护
```

HTTP 使用 `URLSession`，所有后端写操作通过 API 完成。
成功和失败响应主要使用 `{ success, code, messageKey, data }`；HTTP 状态码、错误 code 和操作是否异步完成都需要处理。
登录等部分接口的响应字段不同，应按实际 DTO 解码。

Management Key 通过 `/api/auth/login` 交换会话 token，普通请求使用 Bearer 会话。
SSE 按现有协议申请短期单次 ticket；重连时重新申请，不复用已消费 ticket，不把 token 写入日志。
[`EventHub`](../v2rayN/v2rayN.WebAPI/Services/EventHub.cs) 的订阅缓冲最多 256 条且会丢弃最旧事件，没有事件重放协议。
连接重建后必须重新读取状态、任务和列表，不能把 SSE 当成完整历史。

后端只绑定 `127.0.0.1`，使用独立密钥；本机监听不意味着可以免认证。
启动时确认健康响应中的实例 PID 属于应用启动的进程，避免端口碰撞连接到其他实例。
初期使用明确配置的端口并在冲突时失败；自动选端口需要由后端提供可靠的握手信息，不能把“先探测空闲端口”当作无竞争的分配机制。
启动后读取 `/api/status` 的构建身份和 capabilities；能力字符串仍需结合平台支持判断，例如当前通用列表包含自更新，但 macOS 没有相应安装能力。

## 数据目录和发布边界

上游 [`Utils.StartupPath`](../v2rayN/ServiceLib/Common/Utils.cs) 默认使用程序目录，启用 `V2RAYN_LOCAL_APPLICATION_DATA_V2` 后使用
`.NET LocalApplicationData/v2rayN`。
原上游通过 `XDG_DATA_HOME` 间接设置目录，在 macOS 上不能实现预期隔离。
当前 [`Program.PrepareDataScope`](../v2rayN/v2rayN.WebAPI/Program.cs) 和 ServiceLib 路径入口已适配 `V2RAYM_DATA_HOME`，默认使用 `~/Library/Application Support/v2rayM/`，并兼容 `V2RAYN_DATA_HOME`。

正式数据建议放在 `~/Library/Application Support/v2rayM/`，UI 偏好放入本应用 UserDefaults，密钥放入 Keychain。
首次迁移旧 v2rayN 数据应复制并保留回退来源，两个运行实例不能共用同一套 SQLite 文件。
冒烟检查使用可写的临时程序副本并清除继承的数据目录配置，不接触真实配置。

macOS 分发需要分别处理 `osx-arm64` 和 `osx-x64` 后端与代理内核，签名嵌套可执行文件、打包 SwiftUI 应用并验证公证。
现有上游 `publish-native.sh` 只接受 Linux RID，旧 macOS DMG 脚本打包的是 Avalonia 应用。
本 fork 移除旧桌面打包，使用独立的 macOS 后端构建验证；正式 SwiftUI 签名和发布流程待应用实现后建立。

## 本次删除与保留范围

移除 WPF GUI `v2rayN/v2rayN`、共用 Avalonia GUI `v2rayN/v2rayN.Desktop`、仅供后者引用的 GlobalHotKeys 子模块，
以及原桌面 Windows、Linux、macOS 构建和安装包脚本。
解决方案和集中包版本同时清理 GUI 引用。

保留 ServiceLib、UDP 测试库、单元测试、WebAPI 及其后台运行和跨平台测试。
AmazTool 是上游更新辅助程序，虽然新 SwiftUI 应用不会直接用它，暂时保留以免扩大共享更新代码的删除范围。
共享库里的 Windows/Linux 平台分支和 `GuiItem` 等兼容名称继续保留。

## 上游同步方式

保留 GitHub fork 关系及完整历史。共享代码路径保持不变，把新增 SwiftUI 与 macOS 服务集中到自己的目录。
每次同步在临时分支合并上游提交，检查 API 合约、配置迁移、项目与包依赖，以及上游修改已删除 GUI 文件产生的冲突。
不要用整仓 `ours` 合并、全局忽略冲突或手工复制几个后端目录来代替合并。

删除旧 GUI 会形成长期的删除差异。上游 GUI 改动仍可从历史对照；当它同时修改共享逻辑时，需要判断是否也要为 SwiftUI 补功能。
同步后构建两个解决方案入口，运行 ServiceLib/WebAPI 测试，构建两种 macOS 后端，并在对应架构实机验证。

## 实施顺序

1. 完成本次 GUI 清理，构建保留的后端并验证隔离启动、认证、只读 API、SSE 与退出。
2. 补齐 macOS 数据目录、后端启动握手和退出协议，再实现 SwiftUI 最小闭环：节点列表、选择、连接状态和日志。
3. 使用测试节点验证 Xray/sing-box 启停、订阅、测速、路由、DNS 和断线恢复。
4. 实现可回退的系统代理集成、菜单栏与登录启动；按首版需求补 Clash 接口。
5. 单独完成 TUN 授权、路由/DNS 恢复、签名、公证和应用更新，再决定正式分发。

## 验证记录与接入前问题

2026 年 10 月 20 日在 Apple Silicon Mac 上，清理后的 `.slnx` 和 `.sln` 后端解决方案构建成功，均为 0 警告、0 错误。
ServiceLib 的 136 项测试全部通过。WebAPI 首轮 387 项测试通过 385 项；复查通过 386 项，仍有 1 项失败。

`osx-arm64` 和 `osx-x64` 独立后端均发布成功，并检查了各自 Mach-O 架构。
ARM64 通过临时副本中的真实启动、实例 PID、未认证拒绝、登录、只读节点/订阅/编辑选项/任务接口、SSE 心跳、单次 ticket、会话注销和正常退出验证。
Intel 构建尚未在 Intel 实机运行；本次未提供真实节点或内核文件，也未验证实际代理流量。
系统代理、TUN 和用户现有配置均未在这些检查中修改。

稳定失败的是 `WebLauncherTests.InstanceLockOwnerCanBeReadWhileAnotherProcessHoldsTheLock`。
[`WebInstanceLock`](../v2rayN/v2rayN.WebAPI/Launcher/WebInstanceLock.cs) 在 macOS 上使用 `FileShare.None`，持锁时通过另一文件句柄读取 PID 返回空。
当前已将 macOS 纳入 Unix flock 实现，该测试已通过。

首轮额外失败的 `NativeWebUpdateHelperTests.PermanentFileOperationFailuresSurfaceTheOperationAndCauseAfterRetries`
使用 120ms 重试窗口，复查通过；计时敏感性仍需留意，不能据此认定 macOS 自更新已可使用。
清理提交 `23d3624a` 保留了共享 C# 实现；后续 helper 接入集中修改可选启动适配、macOS 路径、实例锁和独立 API，未绕过失败测试。
