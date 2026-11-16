# DDD 扩展与上游合并指南

## 选择修改位置

本项目采用模块化单体。进程边界继续是 SwiftUI 客户端、本机认证 WebAPI、Xray 和独立特权 helper，
不会为了分层增加网络服务或数据库。新增功能先确定所属上下文，再沿已有用例扩展。

| 变化 | 修改位置 | 可参考的现有入口 |
| --- | --- | --- |
| 不依赖存储/网络的判断、不变量或状态 | `V2rayM.Domain` 或 Swift `V2rayMDomain` | `SettingsPolicy`、`CoreHealthEvidence`、`NetworkRecovery` |
| 操作顺序、任务所有权、重试、锁和补偿 | 两端 `V2rayM.Application` | `SettingsEditorService`、`CoreUpdateApplyService`、`NativeCommandService` |
| ServiceLib 新字段、方法或枚举 | WebAPI `Adapters`、`V2rayRuntime.*Adapter.cs` | `ServiceLibSettingsEditor`、`ServiceLibProfileEditor` |
| HTTP 输入输出、查询投影、错误文案 | WebAPI Contracts/Api、Swift Kit、AppModel 适配器 | `SettingsContractMapper`、`ModuleUpdates.swift` |
| 文件/SQLite/进程/URLSession/系统代理 | 对应基础设施适配器 | `RuntimeConfigStore`、`RestoreDirectoryTransaction`、`BackendController` |
| 特权启动和网络恢复凭据 | 独立 `macos/TunHelper` 上下文 | `LaunchPolicy`、`TunSession`、`TrustedCoreStore` |

领域层不接收 ServiceLib 实体、HTTP DTO、SwiftUI 对象、进程句柄或 helper 启动权限。
应用层只依赖领域层和它定义的端口。读取模型可以包含列表展示所需字段，业务聚合无需复制全部存储字段。

## 添加设置或节点字段

1. 在领域值/规则中表达本地需要验证的事实，在应用用例输入中加入该值。
2. 在适配器读取完整上游实体，只修改明确暴露的字段；保留 ID、顺序、分组归属及未知字段。
3. 设置使用 `SettingsEditorService`，把读取、修改、保存和持久化补偿放在一个 mutation scope。
   会影响运行的字段进入当前运行指纹；普通模式与 TUN 模式分别比较实际生效内容。
4. UI/HTTP 只映射输入和结果，不另写保存/重启流程。检查单项保存和批量保存使用相同规则。
5. 回归至少覆盖未暴露字段保留、无变化不重启、保存失败恢复，以及运行应用失败的旧意图恢复。

原生 TUN 开关使用 `SettingsEdit.TunEnabled`；MTU/IPv6/排除路由使用 `NativeTunSettings`。
helper 可用性和 CIDR 语法检查在适配器，不把系统 API 引入领域程序集。

路由 HTTP/ServiceLib 映射集中在 `RoutingSettingsService` 适配器；`V2rayRuntime` 保留原有入口作为转发，
运行应用与恢复继续走既有事务。路由用例自身持有 mutation scope，外层 `SettingsTransaction.MutateAsync`
只负责失败补偿，不递归取得同一把锁。`/api/macos/tun` 写操作与其他设置写入一样取得独占 operation lease，
避免整个配置快照的恢复覆盖同时发生的偏好设置写入。

创建接口返回持久化后的 ID，客户端必须先接收 ID，再刷新列表。已确认写入之后的观察失败应单独提示，
不能将创建操作当作未执行重试。导入页面等待写入确认后才关闭，失败保留原文。

节点元数据和频繁变化的观测值分开读取：原列表接口默认行为不变，原生客户端每 30 秒读取元数据，
每 5 秒读取内存中的延迟/累计流量，用户操作后强制刷新。状态统计通过数据库计数，不实例化整张节点表。
合并上游新展示字段时，先判断它属于元数据还是观测值，避免重新把全量读取放进 2 秒状态轮询。

订阅适配使用逐项 `Succeeded/Failed/Skipped` 结果，不能从进度文案或正常返回推断成功。
保留 ServiceLib 原有 `UpdateProcess` 签名，新结果接口是增量扩展；只为成功项目写更新时间。
失败自动更新使用独立的 5 分钟内存退避，手动重试不受限制，不伪造成功时间。

## 添加后台操作或外部 I/O

运行上下文是共享所有者，不能在新服务中创建第二套核心锁或配置锁。
锁顺序是 operation lease → core lifecycle → mutation。需要从共享阶段转独占阶段时，先释放共享租约。
任务登记必须覆盖接收、调用、后续观察和清理；请求取消不意味着上游工作已经停止。
退出的 `IsStopping` 接纳状态先于异步取消回调生效。存储准备完成后、发布接纳结果前，必须再次检查
该状态及令牌；不能只依赖 linked token。测速退出回归覆盖了关闭接纳但尚未传播取消的确定时序。

- 只读远端检查先捕获本地快照，释放租约后等待网络，发布前重新验证快照；参考 `ScheduledUpdateCheckService`。
- 下载或暂存产物具有明确所有权，交接前失败由创建方清理，交接后由新所有者处理；参考 `ApplicationUpdateHandoffService`。
- 文件替换、数据库关闭或 helper 确认是不同提交边界。取消和回滚以边界判断，不能只看 UI 的成功标志。
- 多项清理分别尝试；诊断或进度发布失败不能跳过补偿，也不能把已提交结果当成未提交。
  普通诊断通过 `ApplicationDiagnostics.Report` 隔离失败；它不用于吞掉实际配置、进程或存储操作的错误。
- 原生命令用 `NativeCommandService`；长期操作保留 Task 并纳入退出排空。状态观察携带操作代数/恢复代际。

## 合并 ServiceLib 上游

先执行 [上游合并规则](upstream-merge-policy.md)。保持 fork 关系和 Xray-only 产品范围。
ServiceLib 的关键接缝如下；合并时检查其语义，不能仅检查文本冲突是否消失。

| 文件 | 需保留的语义 | 主要回归 |
| --- | --- | --- |
| `Handler/Data/ConfigDbHandler.cs` | 清理/去重支持可选 eligible 过滤，保护不支持、复杂、选中与运行节点 | `ProfileCleanupEligibilityTests`、`ProfileMaintenance` 应用测试 |
| `Helper/SqliteHelper.cs` | 通过 SQLite 在线备份获得包含已提交 WAL 的一致快照 | `BackupSnapshotTests`、`RestoreDatabaseSnapshotTests` |
| `Services/CoreConfig/V2ray/CoreConfigV2rayService.cs` | 最终模板/自定义出站处理完成后才标记生成成功 | `CoreConfigV2rayServiceTests` |
| `Services/DownloadService.cs` | 可选代理端口快照；未提供时保持原调用行为 | 计划更新用例与打包回环 |
| `Services/UpdateService.cs` | 可选已安装版本快照及读取入口，网络阶段不依赖正在变化的安装文件 | `ScheduledUpdateCheckApplicationTests` |

2026-11-15 合并上游配置拆分后：`ConfigDbQuery` 承载数据库查询，`ConfigDbHandler` 承载写入和迁移，
`ConfigTextHandler` 承载文本读写及当前节点选择，`ConfigState` 保存宿主初始化的配置引用。
`ServiceLibRuntimeConfigStore` 是本地事务入口；领域/应用层不能直接读取共享 `ConfigState`。
需要配置的写入方法继续显式接收 `Config`，以保证应用用例持有的事务快照不会被全局值替换。
不要为兼容上游无参调用添加隐式单例重载，也不要恢复旧 `ConfigHandler` 转发层。
数据库查询保留参数绑定、批量查询和请求顺序；节点扩展保留修订号保存及最大排序值下降后的缓存失效。

上游枚举在适配器显式映射，未知值拒绝或返回失败；不重编号持久化枚举，不删除未知用户记录。
Xray 发布版本与本地修复标识、兼容验证等待和可信更新认证继续分别处理。
边界检查同时禁止 ServiceLib 反向引用本地领域/应用项目；Swift 带属性的 import 同样受检查。
纯格式换行不应被误判为架构变化。设置与节点编辑器在主窗口复用展示组件，不新增业务服务层。

## 验证和交付

基础检查：

```sh
python3 scripts/check-macos-product-boundaries.py
python3 scripts/check-ddd-boundaries.py
python3 scripts/test-ddd-boundaries.py
python3 scripts/generate-helper-contract.py --check
```

按影响范围运行 ServiceLib/WebAPI 测试、Native/TunHelper 的 Swift 测试。架构整体变更运行完整矩阵。
使用 `scripts/build-macos-product.py` 从同一源码快照构建、签名并执行隔离回环；构建期间不修改源码。
备份/恢复变更再运行 `scripts/smoke-macos-backend.py --app-bundle <包路径> --check-restore`，只使用临时数据。

构建、签名、回环、安装、真实 TUN、发布、公证分别记录。开发签名包不等于已安装或已公证发行版。
不自动提交、推送、发布、安装或修改其他代理软件；真实 TUN 验收遵守网络所有权限制。
