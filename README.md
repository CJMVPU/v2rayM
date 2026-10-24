# v2rayM

基于 [v2rayN](https://github.com/2dust/v2rayN) 的原生 macOS 代理客户端，使用 **SwiftUI + Xray**，保留上游 fork 关联与提交历史。共享业务继续复用 `ServiceLib` 和 `v2rayN.WebAPI`，已移除 WPF/Avalonia 桌面界面，以及 sing-box、Mihomo 等其他内核的运行、配置生成和更新入口。

当前开发版本为 **0.3.5**。本项目尚未提供经过 Developer ID 签名和 Apple 公证的正式发行包；本地开发 DMG 的使用范围见[签名与分发](#签名与分发)。

0.3.5 修复 helper 断连清理与更新中断恢复、节点扩展和流量统计持久化，优化日志过滤、近期连接与定位缓存，并清理旧内核发布入口。日志按错误、警告、启动/停止、信息和调试类型自适应着色；后端磁盘日志持续按大小轮转。保留网络恢复改动、Darwin M2 修复、5 秒采样与一分钟均速，以及新内核等待验证的更新保护。详见[本轮修复与回归记录](docs/audits/2026-10-24-project-remediation.md)。真实 TUN 联网验收需单独进行。

应用版本统一从 `VERSION` 读取，固定为三段且每段一位数字，显示版本与构建号一致，不添加第四段。依次递增如 `0.2.0` → `0.2.1`，末段到 `9` 后进位为 `0.3.0`，中段到 `9` 后进位为 `1.0.0`。该规则仅用于 v2rayM；Xray 保留真实上游版本号和修复标记。

## 功能

- **原生主页**：环形连接状态、近 5 分钟的代理均速趋势、代理上下行速率、节点累计流量、节点信息、实际安装的 Xray 版本及 TUN 服务状态。青紫填充圆环表示上传／下载活动，不代表完成度；没有有效采样时显示 `—`，断采时曲线留空。详见 [连接仪表盘](docs/connection-dashboard.md)。
- **节点管理**：导入、编辑、选择当前节点、删除与延迟测试。表格固定显示节点、协议、传输、TLS、服务器和延迟；“配置节点”固定显示，未选中时禁用。编辑保留未暴露的字段。
- **互斥代理模式**：标题栏和菜单栏均可快捷开启系统代理或 TUN；开启一个会关闭另一个并连接当前节点，关闭当前模式即停止代理。模式切换失败时尝试恢复原模式。
- **Xray 原生 TUN**：直接由 Xray 接入虚拟网卡，不使用 sing-box 或 SOCKS 转 TUN 前置进程。签名 helper 负责特权启动及路由、DNS 的配置与恢复。
- **参数、路由与 DNS 设置**：适配 Xray 和原生 TUN；MTU 支持预设及自定义值，范围为 1280–65535。已有规则和未展示的参数在编辑时保留。
- **内核与规则更新**：仅更新 Xray 和 GeoIP/GeoSite DAT 数据，支持分别更新及全部更新。Xray 从正式版和预发布版中按版本号选择最新可用发布，避免最新版本转正后退回旧预发布版；发现更高版本时提示“等待验证后再替换内核”，不自动下载替换。进度和结果留在设置页面。
- **连续日志**：最多保留 10,000 行并限制总字符容量，超限淘汰最旧记录；模式切换和空刷新不会清空。支持横向、纵向滚动，隐藏滚动条。错误为红色、警告为琥珀色、启动/停止为绿色、信息为蓝色、调试为紫色，适配浅色和深色模式。后端磁盘日志当前与前一份各最多 8 MiB。
- **菜单栏 V 图标**：未启用时采用系统模板色，系统代理为蓝色，TUN 为绿色，切换或异常为橙色。可显示主窗口、切换模式及安全退出；关闭窗口后继续在后台运行。
- **紧凑固定窗口**：860 × 600，默认进入主页，使用随包附带的 LXGWWenKaiMono Medium 字体。提示悬浮显示，不挤压页面布局；无侧栏、订阅页面或单独连接按钮。

仅支持 Xray 能处理的节点。对不支持的节点明确报错，不自动切换其他内核，也不删除用户已有记录。共享后端保留部分上游订阅数据/API 能力，不代表原生客户端提供订阅管理界面。

## 架构

控制链路：

```text
SwiftUI / macOS 菜单栏
    │ 本机认证 HTTP API
    ▼
v2rayN.WebAPI → ServiceLib → Xray 配置与生命周期管理
    │ TUN 特权请求
    ▼
签名 XPC helper → 受限启动、路由/DNS、可信更新与恢复
```

TUN 数据链路：

```text
Mac 应用 → Xray 原生 TUN → 节点服务器
```

系统代理模式由遵循 macOS 代理设置的应用访问 Xray 本地代理端口。TUN 模式由一个受 helper 管理的特权 Xray 进程接管流量；helper 是控制服务，不是额外的代理转发层。

应用管理自己的后端，默认仅监听 `127.0.0.1:19888`。健康检查核对后端子进程 PID 后才交换会话令牌；启动密钥随机生成，仅保存在内存和子进程环境中。本地 API 请求绕过系统代理且拒绝重定向。界面每两秒刷新状态，共享后端仍保留 SSE 接口。

默认数据目录为 `~/Library/Application Support/v2rayM/`。v2rayM 不读写 v2rayN 的运行配置，不与其共用数据目录。

## 使用

1. 将应用放入 Applications，启动后导入节点，选择“设为当前节点”。
2. 在标题栏或菜单栏 V 菜单中开启“系统代理”或“TUN 模式”。无需再点击连接按钮。
3. 首次使用 TUN，在设置页安装并授权后台服务；按 macOS 提示完成授权。应用不读取或保存管理员密码。
4. 关闭当前模式即可停止代理。正常退出前会确认 TUN 内核停止并恢复属于本应用的网络设置。

TUN 测试前先手动关闭其他软件的 TUN/VPN；检测到测试路由仍由其他隧道接管时，应用拒绝接管。关闭 TUN 不会自动启用系统代理。

系统代理恢复按 HTTP、HTTPS、SOCKS 等配置组核对所有权，尽量保留其他应用的后续修改。恢复失败时保留恢复文件并阻止正常退出；异常强制退出后的信息保存在数据目录的 `native-proxy-recovery.plist`，下次启动可恢复。当前没有独立崩溃守护进程，不能保证强制终止后立即自动恢复。休眠唤醒、网络切换等场景需要单独验收。

## 本地构建

需要 macOS 15 或以上、Xcode 命令行工具、.NET 10 SDK、Python 3。后端无需 Node.js、Avalonia 或 WPF。以下构建 Apple Silicon 版本；Intel 后端目标为 `osx-x64`，原生包应在相应架构的 Mac 上构建和验证。

先取得固定版本的内核数据：

```sh
bash scripts/fetch-macos-cores.sh osx-arm64 /tmp/v2raym-native-cores
```

下载脚本从官方 `2dust/v2rayN-core-bin` 提取 **Xray、许可证和 Geo 数据**，不打包其他内核。默认提交锁定在 `contracts/macos-build-inputs.json`。目标下载目录和 `.app` 路径必须尚不存在。

Xray 26.10.21 的 Darwin 双栈出口绑定存在已复现缺陷。该版本需要先使用 Go 1.27.3
构建本仓库的最小补丁，再将结果用于打包（构建脚本校验固定源码摘要）：

```sh
python3 scripts/build-macos-xray.py --output /tmp/v2raym-patched-xray
cp /tmp/v2raym-patched-xray/{xray,LICENSE,SOURCE.txt} /tmp/v2raym-native-cores/xray/
```

补丁、隔离验证及更新兼容边界见 [Darwin 出口绑定修复](docs/xray-darwin-binding-fix.md)。
修复版仍基于相同的 26.10.21 源码，主页版本显示为 `26.10.21（修复版 M2）`。
M2 同时包含[进程查询诊断修复](docs/xray-process-lookup-fix.md)，保留原有路由行为和真正的查询错误。
点击更新遇到同版本时提示“已安装同版本修复版，无需更新”；遇到更高版本时等待兼容验证，
由用户要求检查后再放行，避免新版本覆盖尚未被上游替代的本地修复。

使用本机有效签名身份构建可供 TUN 开发测试的包；将示例身份替换为自己的代码签名身份：

```sh
SIGN_IDENTITY='Apple Development: YOUR_SIGNING_IDENTITY' \
  python3 scripts/build-macos-product.py \
  --output /tmp/v2raym-product \
  --core-bin /tmp/v2raym-native-cores

bash scripts/package-macos-dmg.sh \
  /tmp/v2raym-product/v2rayM.app /tmp/v2rayM-macos-arm64-local.dmg
```

统一入口自动读取 `VERSION`、核对源码与组件摘要、生成 `product-manifest.json` 并执行隔离回环检查。Geo 数据缺失时根据固定输入及摘要重新生成；源码变化后必须重新构建整包。低层打包脚本拒绝没有来源凭据或源码不匹配的后端。

不设置 `SIGN_IDENTITY` 时使用 ad-hoc 签名，可用于普通代理和隔离回环开发检查；**不能以此代替 TUN helper 所需的 Apple 团队签名**。TUN 授权不提供未签名绕过。DMG 包含应用、Applications 入口和中文安装说明。

获准兼容的内核更新先下载和校验，再替换正在使用的版本并重启，成功后清理旧版本；更高版本当前等待验证。特权 TUN 内核由 helper 独立核对官方 GitHub 发布资产摘要，保存在 root 专用目录；失败或中断时保留恢复路径。具体边界见 [TUN helper 接入](docs/macos-tun-helper.md)。

主页每 5 秒采集一次 Xray 计数器，以最近 60 秒有效样本计算平均速度；运行不足一分钟时按实际采样时长计算。重启、计数器归零及采样中断会重建均速窗口，不清空已保存的累计流量。主页数字使用滚动过渡，并遵循系统“减少动态效果”设置。

## 验证

```sh
dotnet build v2rayN/v2rayN.slnx --configuration Release
dotnet test --project v2rayN/ServiceLib.Tests --configuration Release
dotnet test --project v2rayN/v2rayN.WebAPI/Tests --configuration Release
swift test --package-path macos/Native
swift test --package-path macos/TunHelper
python3 scripts/check-macos-product-boundaries.py

native_bin="$(swift build --package-path macos/Native --show-bin-path)"
python3 scripts/smoke-macos-app.py /tmp/v2rayM.app "$native_bin/V2rayMCheck"
```

隔离集成检查使用临时数据库、本机 HTTP/SOCKS 测试服务和真实 Xray，验证认证、节点、代理转发、日志、流量、版本读取和正常退出。系统代理恢复的故障/重试测试使用内存配置，不改本机系统代理。helper 单元测试不注册系统服务。

GitHub Actions 的 [macOS 验证流程](.github/workflows/macos-backend.yml) 先运行共享后端、原生和 helper 测试，再在 runner 原生架构上构建并执行冒烟检查；CI 产物是开发验证包，不是公证发行包。

本机验证记录分开保存：

- 后端、Swift 测试及签名包回环检查：[设置与主页审查](docs/audits/2026-10-22-settings-and-dashboard.md)、[流量与菜单栏记录](docs/audits/2026-10-22-dashboard-traffic-and-menu.md)。
- 原生 TUN 的联网与恢复验证范围：[TUN 接入文档](docs/macos-tun-helper.md)。
- **2026-10-22 用户反馈“代理测试正常”，此次为手动操作，没有运行测试脚本。** 这属于用户现场验收，不等同于新一轮自动 TUN 测试报告，也不扩展为休眠、切网或所有异常恢复场景均通过。

本地 `artifacts/` 中的安装包、日志与验证报告不纳入源码提交。开发时可用 `V2RAYM_DATA_HOME`，或应用可执行文件的 `--data-directory` / `--api-port` 参数隔离测试数据和端口。

## 签名与分发

当前本机安装包使用 **Apple Development** 开发签名，未完成 Apple 公证；本机 Gatekeeper 评估结果为拒绝，已在当前开发环境中安装使用。

这不等于应用硬性绑定这台 Mac，但不能保证将 DMG 发给别人就能正常安装、启动和授权 helper。当前包应视为本机开发测试包。正常向其他用户分发，需要使用 Apple Developer Program 提供的 **Developer ID Application** 签名、完成 Apple 公证并附加公证票据，再在干净的 Mac 上验证安装及 TUN 授权。收件用户无需购买开发者账号。

参考 Apple 官方的 [Developer ID 说明](https://developer.apple.com/developer-id/) 与 [macOS 软件公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。不要随安装包分发开发证书私钥、P12 或账号凭据。

## 上游同步

合并上游前必须阅读 [合并规则](docs/upstream-merge-policy.md) 和 [AGENTS.md](AGENTS.md)。保留有价值的 Xray、安全及共享业务修复，不能整批恢复其他内核、兼容生成器、旧桌面 GUI 或其发布流程。遇到修改/删除冲突逐项审查，合并后执行产品边界检查及相关回归验证。

共享后端继续保留跨平台构建能力；它不代表本项目提供 Windows/Linux 桌面应用。当前职责边界与恢复策略见 [原生客户端架构](docs/macos-architecture.md)。

## 许可证

保留上游 [GPL-3.0 许可证](LICENSE) 和源文件声明；上游项目为 [2dust/v2rayN](https://github.com/2dust/v2rayN)。随包字体采用 SIL Open Font License，许可文件位于 [字体资源目录](macos/Native/Sources/V2rayM/Resources/Fonts/)。
