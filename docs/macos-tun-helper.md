# macOS TUN helper 接入

v2rayM 通过普通用户 WebAPI、原生 XPC 客户端和 macOS 特权 helper 启动现有 Xray 或 sing-box TUN 内核。
配置仍由 ServiceLib 生成，helper 不实现代理协议，也不接收管理员密码或任意 shell 命令。

当前已实现接口、启动适配、helper、签名打包入口和隔离测试。
本机没有 Apple 代码签名身份，因此尚未验证 SMAppService 的系统注册与授权、真实内核 TUN 流量、路由/DNS 恢复。
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

首版接受 ServiceLib 生成的 Xray、sing-box JSON TUN 配置；自定义配置和 mihomo TUN 被明确拒绝。
支持主内核及可选前置内核，helper 同时最多持有两个内核进程。
未知的本地文件引用会拒绝启动，需要资源快照适配后再开放，不能让 root 进程直接读取任意用户指定路径。

TUN 使用应用内签名的内核版本。普通内核更新功能仍可维护用户数据目录中的内核，但不会替换 helper 执行的随包版本。
更新 TUN 内核需要重新构建、签名和更新应用，接口的 `coreSource` 为 `signed-app-bundle`。
规则文件与证书从普通用户进程读取后作为有限大小的快照传入，helper 写入自己的私有目录。
helper 不写用户指定日志路径，sing-box 持久化缓存被禁用；日志通过现有后端日志接口提供。

## 权限和进程归属

XPC 两端均通过代码签名 requirement 检查对端，限定 Apple 签发的同一 Team ID 和固定程序 identifier。
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
dotnet build v2rayN/v2rayN.slnx --configuration Release
dotnet test --project v2rayN/v2rayN.WebAPI/Tests --configuration Release
```

先按仓库 README 发布 `osx-arm64` 或 `osx-x64` 后端，再创建新的开发集成包：

```sh
bash scripts/package-macos-helper.sh /tmp/v2raym-backend/osx-arm64 /tmp/V2rayM-Development.app
```

默认使用 ad-hoc 签名，仅检查构建和签名结构，不注册服务。
`SIGN_IDENTITY` 可指定实际签名身份；签名包还要求 `CORE_BIN_DIR` 指向匹配架构的内核目录，包含 `xray/xray` 和 `sing_box/sing-box`。
脚本分别为内核、helper、客户端、后端和应用签名；.NET JIT 权限只授予普通用户后端。
脚本生成的是 helper 集成包，SwiftUI 主应用尚未实现，包名不是正式产品版本。

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

## 验证边界

验证包含共享库与 WebAPI 回归、helper 配置和签名策略、进程归属与清理、模拟桥接协议、独立数据目录、无 helper 时拒绝启用、SSE 及正常退出。
原 macOS 实例锁的 PID 读取问题已通过 Unix flock 路径修复。
实际 Team ID 签名、SMAppService 注册审批、真实 TUN 连接、网络切换、休眠唤醒和路由/DNS 恢复尚未验证。
只有完成这些系统验证后，才能将 TUN 标为可供实际使用。
