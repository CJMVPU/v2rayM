# v2rayM

v2rayM 是基于 [v2rayN](https://github.com/2dust/v2rayN) 的 macOS 客户端项目。
原生界面采用 SwiftUI，节点、订阅、配置生成和代理内核管理优先复用上游功能，保留 GitHub fork 关联和提交历史。

当前处于架构准备阶段：已移除 WPF 和 Avalonia 桌面 GUI，保留 `ServiceLib`、`v2rayN.WebAPI` 和后端测试；SwiftUI 应用尚未实现。

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
系统代理、TUN、Clash 策略组和连接管理、菜单栏、全局快捷键及登录启动需要额外适配。

完整评估、代码依据和实施顺序见 [macOS 原生客户端架构评估](docs/macos-architecture.md)。
上游 API 的接口边界见 [功能映射](v2rayN/v2rayN.WebAPI/FEATURE-MAP.md) 和 [运行说明](v2rayN/v2rayN.WebAPI/README.md)。

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
这不等于完整客户端或 TUN 已可使用。

目前 macOS WebAPI 测试仍有实例锁所有者读取失败，完整测试尚未通过；该问题会使新验证流程报告失败。
详细复查结果见架构评估中的验证记录。

## 上游同步

共享后端尽量沿用上游路径和实现，SwiftUI 应用及 macOS 集成放入独立的 `macos/` 目录。
同步时合并上游提交，在临时分支处理 API 和配置兼容性；保留本 fork 对旧 GUI 及其发布流程的删除决定。
上游修改已删除文件时可能产生 modify/delete 冲突，需要逐项检查。

Linux 和 Windows 的共享业务实现、WebAPI 后端构建与测试继续保留，以减少同步差异。
它们不包含本项目已移除的桌面 GUI。

## 许可证与上游

保留上游的 [GPL-3.0 许可证](LICENSE) 和源文件声明。
原项目：[2dust/v2rayN](https://github.com/2dust/v2rayN)。
