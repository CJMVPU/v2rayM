# v2rayM

基于 [v2rayN](https://github.com/2dust/v2rayN) 的原生 macOS 代理客户端，采用 **SwiftUI + Xray**，保留上游 fork 和提交历史。当前版本 **0.3.6**，要求 macOS 15 或以上。

## 使用

1. 将应用放入 Applications，导入节点并选择“设为当前节点”。
2. 在标题栏或菜单栏开启“系统代理”或“TUN”；两种模式互斥，关闭当前模式即可停止。
3. 首次使用 TUN，在设置页注册并按 macOS 提示授权后台服务。开启前先暂停其他 VPN/TUN。

支持节点编辑、延迟测试、参数/路由/DNS 设置、原生 TUN、流量趋势与累计统计。固定紧凑窗口，关闭窗口后继续在菜单栏运行。仅运行 Xray；不支持的节点明确报错并保留记录。

日志逐条保留，按错误红、警告琥珀、启动/停止绿、信息蓝、调试紫区分。位于末尾时，新记录平滑滚入；阅读历史时保持位置，支持横向滚动并遵循“减少动态效果”。最多保留 10,000 条并限制字符容量；后台磁盘日志当前与前一份各最多 8 MiB。

数据独立保存在 `~/Library/Application Support/v2rayM/`，不修改 v2rayN 数据。退出前确认本应用的网络恢复；恢复失败保留记录供重试。强制终止后的即时恢复不作保证。

## 内核与更新

当前打包 Xray **26.10.21（修复版 M2）**，保留 Darwin 出口绑定和进程查询诊断补丁。设置页仅更新 Xray、GeoIP/GeoSite DAT。新 Xray 版本先显示“等待验证”，经源码审查和回归确认后才放行；同版本官方包不会覆盖修复版。

应用版本从 `VERSION` 读取，显示版本与构建号一致，固定三段单数字，按 `0.3.9 → 0.4.0`、`0.9.9 → 1.0.0` 进位。Xray 保留原始上游版本号。

## 构建与验证

需要 Xcode 工具链、.NET 10 SDK、Python 3；重建补丁内核还需 Go 1.27.3。以下为 Apple Silicon 示例，输出目录须尚不存在：

```sh
bash scripts/fetch-macos-cores.sh osx-arm64 /tmp/v2raym-cores
python3 scripts/build-macos-xray.py --output /tmp/v2raym-xray
cp /tmp/v2raym-xray/{xray,LICENSE,SOURCE.txt} /tmp/v2raym-cores/xray/
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

隔离回环使用临时数据和真实 Xray，不修改系统代理或 TUN。真实 TUN、休眠、切网与长期运行需单独验收。当前本机包为 **Apple Development 开发签名，未公证**；对外分发需 Developer ID、公证和干净机器验收。未推送或公开发布。

## 维护文档

- [架构与恢复边界](docs/macos-architecture.md) · [TUN helper 与本机自检](docs/macos-tun-helper.md)
- [主页与定位数据](docs/connection-dashboard.md)
- [Darwin 出口绑定补丁](docs/xray-darwin-binding-fix.md) · [进程查询补丁](docs/xray-process-lookup-fix.md)
- [上游合并规则](docs/upstream-merge-policy.md) · [最终收敛记录](docs/audits/2026-10-24-final-stabilization.md)

本地构建、安装回执和测试证据放在忽略提交的 `artifacts/`。保留当前产物与上一版回退包，过时二进制和重复安装包可清理；历史文档可从 Git 查阅。不要清理用户数据或 root 可信内核存储来释放构建空间。

保留上游 [GPL-3.0 许可证](LICENSE) 和源文件声明；随包字体采用 [SIL Open Font License](macos/Native/Sources/V2rayM/Resources/Fonts/OFL.txt)，离线定位数据保留 DB-IP 归属。
