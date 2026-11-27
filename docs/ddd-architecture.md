# 原生 macOS 客户端的 DDD 边界

普通代理和 TUN 共享同一个 Swift 宿主和进程内 Xray。领域层与应用层是 Swift Package 的编译目标。TUN 助手的进程边界由系统权限决定。旧配置和备份的兼容样例随原生测试维护。

## 从界面到转发

`ContentView` 和菜单栏把用户操作交给 `AppModel`。应用服务编排模式切换、恢复和退出，通过端口调用运行时。`NativeRuntimeHost` 是一个 actor，持有当前会话、后台任务和写操作的互斥状态。界面通过 `NativeAPI` 协议直接调用宿主的 Swift 方法。设置和路由编辑传递原生配置值，备份导入和导出传递 ZIP 数据。Xray 动态库负责监听和转发，TUN 模式再通过 XPC 取得系统隧道描述符。

| 所属模块 | 负责的决策或资源 | 代码入口 |
| --- | --- | --- |
| V2rayMDomain | 连接意图、恢复判定、停止证据、订阅身份匹配优先级和维护周期 | `ConnectionCoordinator`、`NetworkRecovery`、`SubscriptionIdentityMatches`、`MaintenanceAction` |
| V2rayMApplication | 模式切换、轮询、关停、运行节点替换的提交和失败补偿 | `ProxyModeService`、`NativePollingService`、`ServingProfileReplacement`、`RuntimeSessionShutdown` |
| V2rayMKit | SQLite 与文件事务、旧配置字段映射、Xray 配置生成与动态库调用、系统代理和 XPC | `NativeConfigurationStore`、`XrayClientConfiguration`、`EmbeddedXray`、`NativeHelperSession` |
| V2rayM | 页面、输入、动画、辅助功能以及将运行状态投影到窗口和菜单栏 | `AppModel`、`PageCubeNavigation`、`RealityWindowScene` |
| TunHelper | 验证调用者、持有特权网络租约、创建 utun、应用并恢复路由与 DNS | `SessionEndpoint`、`NetworkLease`、`SessionRecoveryStore` |

## 写入和恢复

- **订阅刷新。** Kit 从 SQLite 行提取匹配键，原样保留不支持的记录。领域规则先对整个订阅完成高可信匹配，再处理较弱的匹配。完全相同的重复项按原顺序配对，其余匹配要求两边都唯一。
- **修改运行节点。** 宿主基于同一时间和同一网络条件生成前后配置。相同配置允许只提交数据。需要替换时，应用服务先断开，按需启动候选，然后提交。启动或提交失败时，即使调用方已经取消，也会尝试清理候选并恢复原配置。宿主在整个操作期间保有原有写入互斥。
- **停止代理。** 退出流程先排空在途任务并恢复系统代理。会话关停分别尝试停止 Xray、恢复 TUN 网络，两项都失败时保留两份错误。Kit 将错误映射为现有错误码，并用原会话凭据确认助手已经完成恢复。
- **后台维护。** 领域层只计算到期动作。运行宿主检查关闭状态和当前写操作，再委托订阅读取、SQLite 检查点、文件清理或 Geo 更新。

`NativeRuntimeHost` 仍组装运行时适配器，也承载区域预设、Geo 激活和备份恢复等跨资源事务。扩展这些路径时，沿用已有的写操作互斥、恢复日志和会话归属检查。涉及可独立验证的新业务顺序时，在应用层表达顺序，由宿主提供实际读写动作。

## 修改与验证

Swift 领域目标没有其他目标依赖，应用目标仅依赖领域目标。SQLite 行、Xray 配置 JSON、套接字、XPC 响应与 SwiftUI 对象留在外层。编译目标在 [Package.swift](../macos/Native/Package.swift) 中定义。新增功能的落点和回归入口见[扩展指南](ddd-extension-guide.md)。
