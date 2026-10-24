# v2rayM macOS 架构（0.3.3）

产品只包含 SwiftUI 原生 macOS 客户端和 Xray，保留上游 fork、ServiceLib 与 WebAPI。
控制链路为 SwiftUI → 本机认证 WebAPI → ServiceLib → Xray；TUN 特权操作通过独立签名 helper。
后端不以 root 运行。节点数据库、配置和恢复记录使用 v2rayM 独立数据目录。

## 原生端

`AppModel` 负责展示与用户操作编排，依赖 `NativeAPI`、`NativeBackend`、`NativeProxy`、`NativeClock` 和网络事件接口。
测试可以注入故障和迟到响应，无需启动真实代理或修改系统网络。
`ConnectionCoordinator` 保存 off/system/tun 连接意图及操作代数，意图与实际运行状态分离。
标题栏和菜单栏使用同一个模型；恢复中的连接仍能取消，旧查询不能覆盖后续操作结果。

关键运行快照独立刷新，`ObservationScheduler` 分别调度日志、节点、路由、helper 状态和更新进度。
观察失败保留最近数据并记录该主题错误，不作为停止健康代理的依据。
后端进程退出、明确停止/故障状态与一次 HTTP 查询失败分别处理。
休眠和网络变化通过恢复状态机退避重试，操作代数阻止取消之后重新连接。
系统代理设置按配置组保存原值并核对归属；端口变化重新绑定，恢复失败保留日志供重试。

`APIClient` 仅允许本机 HTTP API，绕过系统代理、拒绝重定向并验证响应 envelope。
后端启动时校验健康响应 PID；Management Key 交换 Bearer 会话，不写入日志。
共享后端仍保留 SSE 接口，原生客户端采用轮询，不依赖事件流完整历史。

## 后端职责与一致性

`V2rayRuntime` 仍是 API 门面和共享业务组合入口。以下服务承担独立职责：

- `CoreLifecycleService`：运行快照、受管进程、健康监测及停止确认。
- `CoreSettingsTransaction`：停止、应用、重启与失败恢复的设置事务编排。
- `IRuntimeConfigStore`：当前配置、保存、快照与恢复；ServiceLib 适配器封装原有单例。
- `ModuleUpdateCoordinator`：更新任务准入、任务生命周期、进度和更新决策。
- `RuntimeExecutionContext`：统一操作租约、核心锁、写入门及区域预设锁的归属。

配置恢复涉及 SQLite 和 JSON，不能假装是一个数据库事务。
路由、DNS、完整配置模板在同一 SQLite 事务内恢复；跨文件恢复先持久化私有权限的 journal，
成功才删除。保存失败保留 journal，下次初始化或重试先重放，不能覆盖未完成的恢复意图。
旧节点 ID、配置字段和共享 API 保留；不支持的节点明确失败，不删除用户数据。

更新决策区分 current、available、awaiting-validation、failed，单项与批量更新使用同一规则。
发布入口使用严格版本解析，历史数据仍可使用原有宽容解析。
Xray 从正式及预发布版本中选择最新版本；发现高于已安装版本的候选时等待兼容验证，不直接替换。

## helper 权限与契约

helper 通过调用者签名认证、受限路径和启动策略控制特权 Xray；保留可信更新、回滚及路由/DNS 恢复。
跨 Swift/C# 的协议常量由 `contracts/` 生成，golden fixture 校验两端编码；生成文件漂移会令检查失败。
无 Xray 用途的 SRS 白名单已移除。

状态探测合并并发请求，成功缓存 30 秒、失败缓存 2 秒，状态变化使缓存失效。
启动及更新等关键预检查使用实时探测，不能以展示缓存绕过授权或可用性检查。

## 精简与定位资源

Profile DTO 使用普通属性，不再引入 ReactiveUI。旧窗口适配器、二维码、扫码、旧自动启动、
无订阅者的界面事件总线及其无调用系统代理/PAC 路径移除。
原生系统代理仍由 `SystemProxyController` 管理。
旧地图渲染器和纹理移除，节点城市与近期连接定位保留。

离线定位保留 IPv4/IPv6 区间，城市表改为带版本的 `places.bin`，使用内存映射和按需字符串解码。
边界、偏移、UTF-8 与坐标异常返回未知位置；保留 DB-IP 许可归属。
输入及生成文件摘要通过 `geodata-manifest.json` 与构建输入锁校验，干净检出可以重新生成。

## 构建和验收

`scripts/build-macos-product.py` 是一致构建入口：检查边界和契约、验证定位资源、记录源码快照、
编译后端及原生/helper、嵌套签名、核对 manifest、执行隔离回环验证。
来源记录包含版本、commit、源码摘要、工具链及组件摘要；低层打包入口也验证后端来源，避免新 UI 混装旧后端。
Xray 保留固定源码及 Darwin 修复标识。macOS 产品 CI 与独立 WebAPI 手动发布分开。

测试、构建、签名、安装、真实网络验收和公证是不同结果。
隔离测试不改系统代理、不注册 helper，也不证明真实 TUN、休眠或 Wi-Fi 恢复已通过实机验收。
版本规则、操作命令见 [README](../README.md)；本轮验收见 [架构改造记录](audits/2026-10-24-architecture-refactor.md)。
上游导入必须先阅读 [合并规则](upstream-merge-policy.md)，不能恢复其他内核或桌面 GUI。
