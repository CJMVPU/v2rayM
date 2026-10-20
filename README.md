# v2rayM

v2rayM 是基于 [v2rayN](https://github.com/2dust/v2rayN) 的 macOS 客户端项目。
原生界面采用 SwiftUI，节点、订阅、配置生成和代理内核管理优先复用上游功能，保留 GitHub fork 关联和提交历史。

已移除 WPF 和 Avalonia 桌面 GUI，保留 `ServiceLib`、`v2rayN.WebAPI` 和后端测试。SwiftUI 首版已接通节点导入与切换、订阅管理、内核连接开关、系统代理、路由选择与日志。TUN helper 已实现代码接线，特权服务与真实 TUN 仍待签名和系统授权验证。

## 架构与功能边界

推荐路径是 SwiftUI 通过仅监听本机的 HTTP API 和 SSE 事件流调用独立的 .NET 后端：

```text
SwiftUI 应用
    │ 本机 HTTP 与 SSE
    ▼
v2rayN.WebAPI
    │ C# 项目引用
    ▼
ServiceLib → Xray / sing-box 等代理内核
```

现有 API 可以复用节点、订阅、路由、DNS、测速、日志、流量统计和非 TUN 内核运行管理。
系统代理由原生 SystemConfiguration 适配负责保存和恢复。Clash 策略组和连接管理、菜单栏、全局快捷键及登录启动仍待实现。
TUN 已通过可选的 macOS XPC helper 接入，详见 [TUN helper 接入](docs/macos-tun-helper.md)，当前不能视为已完成实际联网验证。

完整评估、代码依据和实施顺序见 [macOS 原生客户端架构评估](docs/macos-architecture.md)。
上游 API 的接口边界见 [功能映射](v2rayN/v2rayN.WebAPI/FEATURE-MAP.md) 和 [运行说明](v2rayN/v2rayN.WebAPI/README.md)。

## SwiftUI 原生客户端

最低 macOS 15，需要 Xcode 命令行工具、.NET 10 SDK 和 Python 3。SwiftUI 与平台集成位于 `macos/Native/`，共享后端路径不变。

首版支持：

- 节点列表、搜索、订阅分组、分享链接/配置导入、选择并连接、删除、延迟测试入口。
- 订阅新增、编辑、删除、单个与全部更新；编辑基本字段时保留已有高级选项。
- 代理内核连接/断开，原生系统代理开关，选择上游路由配置，查看日志与后台任务状态。
- 应用自己启动并管理后端，仅绑定 `127.0.0.1:19888`；健康检查匹配子进程 PID 后才交换会话令牌。

本地构建 Apple Silicon 开发包（Intel 将 `osx-arm64` 改为 `osx-x64`）：

```sh
dotnet publish v2rayN/v2rayN.WebAPI/v2rayN.WebAPI.csproj \
  --configuration Release --runtime osx-arm64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  --output /tmp/v2raym-native-backend
bash scripts/fetch-macos-cores.sh osx-arm64 /tmp/v2raym-native-cores
CORE_BIN_DIR=/tmp/v2raym-native-cores \
  bash scripts/package-macos-app.sh /tmp/v2raym-native-backend /tmp/V2rayM.app
open /tmp/V2rayM.app
```

目标 `.app` 与内核下载目录必须尚不存在。内核下载来自上游官方 `2dust/v2rayN-core-bin`，可用 `CORE_BUNDLE_REF` 固定其 Git 提交。
默认使用 ad-hoc 本地签名，普通代理无需付费证书；该产物未公证。TUN 不会自动注册，也不提供未签名绕过。
未嵌入内核的包可在设置里安装 Xray；完整开发包同时包含 Xray、sing-box 和 Geo 数据。

导入节点后选择“使用此节点”或双击节点，再按需要开启“系统代理”。路由规则在设置里选择，沿用上游当前配置，不自动覆盖已有规则。
系统代理只影响遵循 macOS 代理设置的应用，不等同于 TUN。启用代理时 macOS 可能请求管理员授权，应用不读取或保存管理员密码。

关闭系统代理、断开连接和正常退出会先恢复原来的代理配置；恢复失败时保留恢复文件并阻止退出。
如果其他应用更改了代理，则按 HTTP、HTTPS、SOCKS 等配置组恢复仍属于本应用的设置，并保留外部修改。
异常强制退出后的恢复信息位于数据目录的 `native-proxy-recovery.plist`，下次启动显示“恢复系统代理”；目前尚无独立的崩溃守护进程，不能承诺强制退出后立即自动恢复。

界面每两秒通过已有 REST API 刷新状态，不修改上游 SSE 协议。密钥每次后端启动随机生成，仅保留在内存和子进程环境，令牌使用现有登录接口获取；本地请求绕过系统代理且拒绝重定向。
默认数据目录为 `~/Library/Application Support/v2rayM/`。开发隔离启动可直接运行应用内可执行文件，传入 `--data-directory /tmp/v2raym-ui-data --api-port 19889`。

```sh
swift test --package-path macos/Native
native_bin="$(swift build --package-path macos/Native --show-bin-path)"
python3 scripts/smoke-macos-app.py /tmp/V2rayM.app "$native_bin/V2rayMCheck"
```

集成检查使用临时数据库、本机 HTTP/SOCKS 测试服务和真实 Xray，验证订阅增改删更新、节点导入/切换、真实代理转发、端口冲突拒绝、认证与正常退出。
系统代理的恢复/失败重试/外部修改保护使用内存配置测试，不在自动测试中更改本机系统代理。首次管理员授权与真实系统代理切换仍需人工验收。

## 后端开发与验证

需要 .NET 10 SDK 和 Python 3。后端构建无需 Avalonia、WPF、Node.js 或 GUI 热键子模块。

```sh
dotnet build v2rayN/v2rayN.slnx --configuration Release
dotnet test --project v2rayN/ServiceLib.Tests --configuration Release
dotnet test --project v2rayN/v2rayN.WebAPI/Tests --configuration Release
```

在 macOS 上发布独立运行的后端，例如 Apple Silicon：

```sh
dotnet publish v2rayN/v2rayN.WebAPI/v2rayN.WebAPI.csproj \
  --configuration Release --runtime osx-arm64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  --output /tmp/v2raym-backend/osx-arm64
python3 scripts/smoke-macos-backend.py /tmp/v2raym-backend/osx-arm64
```

Intel 构建使用 `osx-x64`。冒烟验证必须在与可执行文件架构匹配的 Mac 上运行。
该检查使用隔离副本和临时凭据，验证启动、认证、只读 API、SSE 和退出；不会配置系统代理或启动代理内核。
GitHub Actions 的 `macos-backend.yml` 构建两种架构，并在运行机器的原生架构上执行冒烟验证。
原生客户端另外通过上述集成检查；TUN 仍需单独进行系统验证。

原 macOS 实例锁读取失败已修复。验证流程还包括 Swift helper 测试和 ad-hoc 开发集成包校验；不会在 CI 注册特权服务。
macOS 后端默认数据目录为 `~/Library/Application Support/v2rayM/`，测试可用 `V2RAYM_DATA_HOME` 隔离。

## 上游同步

共享后端尽量沿用上游路径和实现，SwiftUI 应用及 macOS 集成放入独立的 `macos/` 目录。
同步时合并上游提交，在临时分支处理 API 和配置兼容性；保留本 fork 对旧 GUI 及其发布流程的删除决定。
上游修改已删除文件时可能产生 modify/delete 冲突，需要逐项检查。

Linux 和 Windows 的共享业务实现、WebAPI 后端构建与测试继续保留，以减少同步差异。
它们不包含本项目已移除的桌面 GUI。

## 许可证与上游

保留上游的 [GPL-3.0 许可证](LICENSE) 和源文件声明。
原项目：[2dust/v2rayN](https://github.com/2dust/v2rayN)。
