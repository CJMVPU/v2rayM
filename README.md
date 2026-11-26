# v2rayM

基于 [v2rayN](https://github.com/2dust/v2rayN) 的原生 macOS 代理客户端，采用 **SwiftUI/AppKit + RealityKit + Xray**，保留上游 fork 和提交历史。当前版本 **0.9.0**，要求 macOS 15 或以上。

## 使用

1. 将应用放入 Applications。点击主页的城市与节点名称可配置当前节点；尚未选择时进入节点列表，可导入并设为当前节点。点击近期连接卡片查看日志，点击中央圆盘打开设置。在各页概览点击标题栏签名或按 Esc 返回主页。
2. 在标题栏或菜单栏开启“系统代理”或“TUN”；两种模式互斥，关闭当前模式即可停止。
3. 首次使用 TUN，在设置页注册并按 macOS 提示授权后台服务。开启前先暂停其他 VPN/TUN。

支持节点编辑、延迟测试、参数/路由/DNS 设置、原生 TUN、流量趋势与累计统计。固定紧凑窗口，关闭窗口后继续在菜单栏运行。仅运行 Xray；不支持的节点明确报错并保留记录。

日志逐条保留，按错误红、警告琥珀、启动/停止绿、信息蓝、调试紫区分。位于末尾时，新记录平滑滚入；阅读历史时保持位置，支持横向滚动并遵循“减少动态效果”。应用内最多保留 10,000 条，并限制字符总量。启用内核文件日志后，可在数据目录的 `guiLogs` 中查看。

数据独立保存在 `~/Library/Application Support/v2rayM/`，不修改 v2rayN 数据。退出前确认本应用的网络恢复；恢复失败保留记录供重试。强制终止后的即时恢复不作保证。

## 内核与更新

当前打包 Xray **26.11.9（修复版 M2）**。Xray 编译为动态库，随应用一起签名和更新。设置页可单独更新 GeoIP/GeoSite DAT。

Swift 直接读取 v2rayM 的 SQLite 数据库、生成配置、管理订阅和运行状态。普通代理和 TUN 流量都由 v2rayM 进程中的 Xray 转发。TUN 模式额外使用已签名的 V2rayMHelper 创建系统隧道并管理路由与 DNS。助手完成恢复工作并空闲后退出。旧版自定义节点设置了前置 SOCKS 端口时，同一进程内运行两套配置，各自保留 DNS、路由和日志。

应用版本从 `VERSION` 读取，显示版本与构建号一致，固定三段单数字，按 `0.3.9 → 0.4.0`、`0.9.9 → 1.0.0` 进位。Xray 保留原始上游版本号。

## 构建与验证

需要 Xcode 工具链、Python 3 和 Go 1.27.3。对照旧 C# 实现时另需 .NET 10 SDK。以下为 Apple Silicon 示例，输出目录须尚不存在：

```sh
bash scripts/fetch-macos-cores.sh osx-arm64 /tmp/v2raym-cores --data-only
SIGN_IDENTITY='Apple Development: YOUR_SIGNING_IDENTITY' \
  python3 scripts/build-macos-product.py \
  --output /tmp/v2raym-product --core-bin /tmp/v2raym-cores
```

统一入口检查产品边界、固定输入、源码/组件摘要，构建并签名整包，执行隔离回环检查。定位资源按固定摘要生成。没有 Apple 团队签名的 ad-hoc 包不能用于特权 TUN。

```sh
python3 scripts/check-macos-product-boundaries.py
python3 scripts/generate-helper-contract.py --check
dotnet test --project v2rayN/ServiceLib.Tests --configuration Release
dotnet test --project v2rayN/v2rayN.WebAPI/Tests --configuration Release
swift test --package-path macos/Native
swift test --package-path macos/TunHelper
```

在有图形桌面的测试机上，可运行 `xcrun swift scripts/test-macos-startup-render.swift /Applications/v2rayM.app --runs 10 --report /tmp/v2raym-startup-check`。工具用 Release 主程序副本与临时空数据库连续冷启动，从目标进程的首张窗口截图检查首页圆环。

签名包还可用 `python3 scripts/test-macos-tun-local.py --check-only --app /Applications/v2rayM.app` 做离线预检，验证原生宿主和隔离数据目录。需要实际验收 TUN 时，退出其他 VPN、关闭代理并运行 `scripts/验证新版v2rayM.command`。脚本复制当前节点，在签名应用中测试启动、转发、重新连接及停止后的路由和 DNS。

隔离回环使用临时数据和真实 Xray，不修改系统代理或 TUN。真实 TUN、休眠、切网与长期运行需单独验收。当前本机包为 **Apple Development 开发签名，未公证**；对外分发需 Developer ID、公证和干净机器验收。尚未公开发布安装包。

## 维护文档

- [架构与恢复边界](docs/macos-architecture.md) · [TUN helper 与本机自检](docs/macos-tun-helper.md)
- [主页与定位数据](docs/connection-dashboard.md)
- [Darwin 出口绑定补丁](docs/xray-darwin-binding-fix.md) · [进程查询补丁](docs/xray-process-lookup-fix.md)
- [上游合并规则](docs/upstream-merge-policy.md) · [最终收敛记录](docs/audits/2026-10-24-final-stabilization.md)

本机发布时，先验证新版安装包的签名、版本及回环测试，再用新版替换 `/Applications/v2rayM.app`。核对已安装应用后，卸载本次挂载的安装镜像，删除旧版安装包、旧应用及构建目录里的应用副本。仅保留当前版本的安装包和一份已安装应用。本地构建回执和测试记录放在忽略提交的 `artifacts/`。清理范围限于桌面应用及其分发产物，用户数据和特权服务的可信内核存储独立维护。

保留上游 [GPL-3.0 许可证](LICENSE) 和源文件声明；随包字体采用 [SIL Open Font License](macos/Native/Sources/V2rayM/Resources/Fonts/OFL.txt)，离线定位数据保留 DB-IP 归属。
