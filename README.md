# v2rayM

v2rayM 是基于 [v2rayN](https://github.com/2dust/v2rayN) 的原生 macOS 代理客户端，支持 macOS 15 及以上版本。当前版本为 **0.9.6**，内置 **Xray 26.11.9（Darwin 修复版 M2）**。

## 开始使用

1. 打开安装镜像，将 v2rayM 拖入「应用程序」。更新已有安装时，先退出旧版。
2. 点击主页的节点名称进入节点页，导入节点并设为当前节点。支持 SIP008 Shadowsocks JSON 和 WireGuard 配置，每个 WireGuard Peer 会生成一个节点。
3. 从标题栏或菜单栏开启「系统代理」或「TUN」。两种模式互斥，关闭当前开关即可停止代理。首次使用 TUN 时，先关闭其他 VPN/TUN，再到设置中注册后台服务并按 macOS 提示授权。

| 在主页点击 | 可以做什么 |
| --- | --- |
| 中央圆盘 | 打开设置，调整代理参数、路由和 DNS，管理 TUN 助手，更新 GeoIP/GeoSite 分流数据 |
| 城市与节点名称 | 管理节点、导入配置和测试延迟 |
| 近期连接卡片 | 查看日志。滚到末尾时跟随新记录，阅读历史时保持当前位置 |

在子页面概览点击标题栏签名或按 Esc 返回主页。关闭窗口后，代理继续在菜单栏运行。应用使用独立数据目录 `~/Library/Application Support/v2rayM/`。日志跨模式切换保留，最多 10,000 条，另有字符总量限制；开启内核文件日志后可在该目录的 `guiLogs/` 查看。

## 运行方式

SwiftUI 与 AppKit 管理窗口、输入和文本，RealityKit 绘制界面。Swift 读取 SQLite 节点库并生成配置，普通代理与 TUN 的流量都由主进程内的 Xray 动态库转发。TUN 另由按需启动的签名助手创建系统隧道、管理路由和 DNS。Xray 随 App 升级，分流数据可以单独更新。[运行架构](docs/macos-architecture.md) · [TUN 助手](docs/macos-tun-helper.md)

## 构建与验证

[构建与打包指南](docs/build-and-test.md)包含从干净检出生成签名 App 和 DMG 的命令、原生测试和隔离回环入口。开发签名包用于本机验证，公开分发还需 Developer ID 签名、公证与干净机器验收。

维护者可从[文档目录](docs/README.md)查找模块职责、上游同步政策及历次审查记录。项目保留上游 Git 历史和 [GPL-3.0 许可证](LICENSE)。随包字体采用 [SIL Open Font License](macos/Native/Sources/V2rayM/Resources/Fonts/OFL.txt)，离线定位数据保留 [DB-IP 归属](macos/Native/Sources/V2rayM/Resources/Globe/ATTRIBUTION.txt)。
