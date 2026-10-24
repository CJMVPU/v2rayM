# 全项目优化、重构与精简审查

日期：2026-10-24（Asia/Shanghai）。版本：`0.3.4`；基准提交：`529b2d00`，包含审查开始时已有的工作区改动。本次由主审和三个子智能体分别检查 Native、ServiceLib/WebAPI、helper/Xray，再交叉复核构建脚本与发布链。

本次只审查、运行离线测试并新增本报告，没有修改产品源码，没有提交、推送、安装、发布或启动真实代理/TUN。原有网络恢复修改及其审计文档保留。以下“确定”指源码触发链成立；只有明确列出的项目做了隔离执行复现，不等于全部问题均在真实网络中复现。

优先级：P1 为恢复能力或产品边界问题，应优先处理；P2 为数据一致性、明确功能或性能问题；P3 为维护性整理。当前没有建议重写整个项目或恢复其他内核。

## 优先修复

### 1. P1：XPC 失效后，清理失败的会话失去恢复持有者

- 位置：`macos/TunHelper/Sources/V2rayMHelper/main.swift:58`；`macos/TunHelper/Sources/TunShared/TunSession.swift:161`、`:191`。
- 触发：XPC invalidation 调用异步 disconnect，同时从 sessions 移除 endpoint；若 DNS restore 抛错，stopLocked/cleanup 返回 faulted，没有释放 limiter 名额，也没有完成网络恢复。
- 后果：失效连接不再可用，而 Listener 也不再持有待恢复会话。名额可能持续占用，后续连接最终得到 helper_busy；恢复状态失去重试入口。不能把名额无条件释放作为修复，否则可能允许新会话覆盖未清理网络。
- 建议：由 helper 生命周期管理器持有待清理会话，disconnect 返回明确清理结果，清理成功后才移除；失败保留状态并可重试，shutdown 同样处理未完成清理。
- 证据：在临时源码副本用失败的 DNS restore 和模拟 core 复现“断开并释放 session 后 limiter 仍占用”；没有修改本机 DNS 或启动 helper 服务。
- 回归：失效、短暂恢复失败、重试成功、重复 disconnect、退出时仍失败；必须验证无残余进程且不抢占其他软件配置。

### 2. P2：可信内核更新的两个中断窗口会卡住后续更新

- 位置：`macos/TunHelper/Sources/TunShared/TrustedCoreStore.swift:94`、`:236`、`:250`。
- 触发 A：current 已移到 previous，但 stage 尚未移到 current 时 helper 中断。重启后的 base 仅在 current 存在时恢复，previous 单独残留不会恢复。
- 触发 B：finish 已把 current 标为 committed，但 previous 尚未删除时中断。base 不清理此残留。
- 后果：后续 activate 要求 previous 不存在，因此可能一直报 update_store_busy。A 还会让 source 无法选择原可信版本。
- 建议：把目录状态恢复做成显式、可重复执行的状态机，覆盖 previous-only、uncommitted-current、committed-current+previous；按 manifest/所有权校验决定恢复，保留官方摘要校验和 rollback。
- 证据：临时测试副本构造上述两个磁盘状态，都复现后续 activate busy。当前新版本更新受“等待验证”保护，此项是更新事务进入后遇到中断的条件性问题，不是每次启动都会触发。

### 3. P2：ProfileEx 首次保存会重复插入同一主键，失败后丢掉待保存记录

- 位置：`v2rayN/ServiceLib/Manager/ProfileExManager.cs:43`、`:95`、`:133`；`Models/Entities/ProfileExItem.cs:6`；`Helper/SqliteHelper.cs:29`。
- 触发：新 ID 第一次 SetTestDelay/SetSort，在 AddProfileEx 和 setter 各入队一次。SaveQueueIndexIds 没去重，按相同数据库初始快照把同一记录两次加入 lstInserts。IndexId 是主键，InsertAll 使用事务。
- 后果：新增事务主键冲突回滚；catch 只写日志，队列已取空，排序/延迟/测速信息可能不落盘。并发的 FirstOrDefault ?? AddProfileEx 还可能制造多个相同 ID 对象，使 API ToDictionary 报错。
- 建议：使用按 ID 唯一的缓存及去重待保存集合；原子创建、快照保存、失败保留待保存 ID。不能只换容器而忽略字段并发写入和保存中的新更新。
- 验证缺口：现有并发测试验证内存/队列，没有覆盖首次保存、重建缓存读回、数据库失败重试。本轮未执行 .NET 实测，结论来自完整源码链。

### 4. P2：统计重新初始化后，正在累加的对象与保存列表脱离

- 位置：`v2rayN/ServiceLib/Manager/StatisticsManager.cs:90`、`:135`、`:51`；`v2rayN/v2rayN.WebAPI/Services/V2rayRuntime.Settings.cs:266`。
- 触发：同一节点已有采样后修改统计/实时速度设置，InitData 替换 _lstServerStat，却未重绑定 _serverStatItem；节点 ID 不变时继续更新旧对象，SaveTo 写新列表。
- 后果：界面可能继续增长，持久化累计量却停留在旧值。Close 仅取消旧采样，未等待其结束，也使重初始化难以推理。
- 建议：明确 StopAsync → 保存 → 重新加载并绑定 → StartAsync；或保留一致内存数据，避免不必要重载。测试同节点切换设置后采样、保存、重读，不丢量或重复计量。

### 5. P1：遗留 WebAPI 发布链仍主动打包并执行退役内核，当前 guard 漏检

- 位置：`.github/workflows/build-WebAPI.yml:198`、`:219`、`:227`；`v2rayN/v2rayN.WebAPI/Scripts/fetch-core-bundle.sh:26`、`:33`、`:59`；`Scripts/web-release-assets.py:46`；`Containerfile:33`。
- 证据：Windows release 条件分支下载完整上游 bin 并检查、执行 sing-box/mihomo；Linux 下载脚本强制要求相同内核和 SRS 数据，并拷贝整棵 bin；release-assets 也把这些列为必需文件。发布工作流仍能通过 workflow_dispatch/workflow_call 进入。
- 当前 macOS 主打包入口是 Xray 白名单，此发现不证明现用 macOS 包包含其他内核；问题在仍可执行的其他发布/容器入口。
- `scripts/check-macos-product-boundaries.py:15` 排除了 .py/.sh/.yml，另只检查两个根 scripts 文件，没有覆盖上述下载/打包入口。因此本轮 guard 通过不能证明所有发布入口符合产品边界。
- 建议：清理退役内核打包与执行路径，将仍需保留的跨平台共享后端验证与产品发行入口明确区分；扩展 guard 覆盖工作流、Containerfile 和实际打包脚本，增加故障样例。保留 Git/fork 历史，不删除有用途的跨平台共享库代码，也不新增禁用引擎白名单绕过检查。

### 6. P2：日志过滤在共享锁内执行逐条正则，阻塞写入及增量读取

- 位置：`v2rayN/v2rayN.WebAPI/Services/LogBuffer.cs:41`、`:54`；`v2rayN/ServiceLib/Common/Utils.cs:746`。
- 触发：Recent/RecentPage 在 _gate 内过滤最多 10,000 条；IsRegexMatch 每条有 2 秒超时，但超时后继续下一条。复杂合法正则在多条长日志上可叠加大量等待。
- 后果：同锁的 Add、Tail、Clear 都被阻塞。这里确认锁范围与算法风险，没有运行数小时的最坏情况负载。
- 建议：锁内只取快照，锁外匹配；一次解析表达式，设置整次查询的时间预算，首次超时给明确结果。保留匹配超时保护，避免为每条无效匹配重复写日志。
- 回归：慢查询并发 Add/Tail 不被长期阻塞；正常过滤、顺序和分页一致；无效/超时表达式一次处理。

### 7. P2：磁盘日志单次运行无容量上限

- 位置：`macos/Native/Sources/V2rayMKit/BackendController.swift:28`、`:58`；`v2rayN/v2rayN.WebAPI/Services/V2rayRuntime.cs:1031`、`:1050`。
- 证据：native-backend.log 仅在 start 时移到 previous；stdout/stderr 直接连接文件。后端逐条 Console.Out.WriteLine 输出核心日志，另有 ServiceLib ConsoleTarget。
- 后果：长期运行持续增长。UI 的 10,000 条/字符预算只限制内存日志，不限制此磁盘文件。
- 建议：让写入所有者实施大小轮转和保留总预算，或由受控输出读取器统一落盘；避免仅 rename 子进程仍持有的文件描述符。测试持续输出、轮转、异常退出、重启及文件权限。

### 8. P2：IPv6 目标的方括号被误认为路由标签

- 位置：`macos/Native/Sources/V2rayMKit/GlobeTelemetry.swift:89`；`macos/Native/Sources/V2rayM/HomeDashboard.swift:162`。
- 例：`accepted udp:[2606:4700::1111]:443 [tun -> direct]`。parser 在整个 tail 取第一个方括号，route 变为 IPv6 地址。
- 后果：近期连接显示错误路由文本/颜色，且不进入 proxy/direct 定位分支。
- 证据：隔离 Swift 执行现有解析逻辑得到 `2606:4700::1111`。现有 IPv6 测试仅检查 host/port。
- 建议：先分离目标 token，再解析其后的路由标签；补 IPv6 direct/proxy/block 和 IPv4/域名对照测试。

## 性能与结构优化

### 9. P2：近期连接批处理在主线程上做平方级扫描

- 位置：`macos/Native/Sources/V2rayM/GlobeMonitor.swift:72`；`AppModel.swift:268`。
- 一次可输入 10,000 条日志，每条 removeAll+头部 insert，最后才 prefix(24)；中途数组可增长到接近 10,000，主线程做 O(n²) 扫描/搬移。
- 建议逆序扫描最新日志并 Set 去重，保留最多 24 条，补入历史；或循环中始终限制容量。保持完整日志缓冲不变，只优化 dashboard 投影。日期解析也应避免每条新建 formatter。
- 验证必须保持时间过滤、会话切换、同 host/route 去重与最新优先；微基准只作算法证据，不当作真实 UI 帧率。
- 补充微基准：`swiftc -O`，10,000 个不同 ID，原结构三轮为 172.02/178.82/176.55 ms；每轮保留 24 条为 1.20/1.10/1.12 ms，最终 24 条逐项相同。只测数组处理，不含日期解析、DNS 或 UI。临时源文件：`/private/tmp/v2raym-recent-benchmark.swift`。

### 10. P2/P3：定位缓存有两层所有者，失败与成功均无法按 TTL 更新

- 位置：`macos/Native/Sources/V2rayM/GlobeMonitor.swift:11`、`:61`、`:82`、`:95`。
- resolver 有 1 小时 TTL，但外层 attempted 在尝试前就记录 host，失败不删除；未超过 512 时后续调用永远被挡住。节点位置又只在地址变化时查询。
- 建议合并缓存责任：in-flight 只去重正在进行的任务，成功长 TTL、失败短 TTL，网络恢复允许重试；用注入 clock/resolver 验证首次失败后成功及同地址刷新。

### 11. P2：节点列表重复查询，并有未参数化的订阅 ID

- 位置：`v2rayN/v2rayN.WebAPI/Services/V2rayRuntime.cs:484`；`v2rayN/ServiceLib/Manager/AppManager.cs:177`；`Helper/SqliteHelper.cs:64`。
- 列表同时查询 ProfileItems、ProfileModels、SubItems，而 ProfileModels 在此只提供 SubRemarks，已有 subscriptions map 可以替代。
- ProfileModels 将 subid 直接插入 SQL，带引号值可能导致错误；其他按订阅 ID 的 SQL 也应迁移参数。尚未证明任意写库攻击，不作该结论。
- 建议先去掉列表的重复 JOIN 和字典，再给 SQLite 包装加入参数支持，迁移活跃调用。保留原始 ID，不静默修复用户数据。验证空/孤立/带引号 ID 和精准删除。

### 12. P3：成组删除无调用的 Clash 控制代码

- 位置：`v2rayN/ServiceLib/Manager/ClashApiManager.cs:3`、`Manager/AppManager.cs:23`、`Helper/HttpClientHelper.cs:56`。
- 全源码搜索未发现 ClashApiManager 外部调用；ClashItem、ClashConnections、ClashConnectionModel、仅供它调用的 HTTP Put/Patch/Delete 与 StatePort2 分配可成组清理。
- 保留持久化枚举编号与不支持的旧节点记录。WindowsUtils/WindowsJobService 仍有调用，WebDavManager 仍服务备份，不应仅按名称删除。
- 完成后用编译、引用搜索和导入/配置回归验证闭包；不声称已测得具体包体缩小量。

### 13. P3：统一 Native API 包装及实际模式切换路径

- `macos/Native/Sources/V2rayMKit/APIClient.swift:33` 与 `NativeRuntime.swift:11` 重复 value/send/perform，具体类型与 NativeAPI 存在类型调用走不同包装。保留认证、PID 校验、拒绝重定向及 envelope 成功校验，将请求包装集中一处。
- `TunMode.swift:54` 的旧 apply 启用/回滚路径仅测试使用；产品使用 `ProxyModeSwitch`，smoke 仅用旧 apply(false)。迁移有价值场景到实际编排路径后再删旧流程，保留 checkBeforeConnecting。不能通过删测试掩盖边界。
- 上述是维护建议，不认定为当前切换错误。先补等价调用与失败恢复验证，再做删除。

### 14. P3：避免无变化轮询重复发布状态

- 位置：`macos/Native/Sources/V2rayM/AppModel.swift:270`；`GlobeMonitor.swift:79`。
- 空日志增量仍重赋 logs，空连接更新仍重赋 connections，使观察视图继续处理。日志渲染已有 ID 比较保护，但仍要生成/比较至多 10,000 个 ID。
- 建议先在空增量/快照相等时避免发布，移除没有读者的 updateGeneration；测量后再决定是否拆 Logs/ProfileStore。不要仅因 AppModel 较长就拆散连接事务状态。

### helper 与构建的附加维护项

- `TrustedCoreStore.swift:181` 在全局锁内等待网络元数据并执行多个外部命令，单项允许 35 秒/25 秒，而 bridge stage 总等待为 110 秒。source、rollback、finish、expiry 也用此锁。建议与第 2 项一起拆出可取消、有统一 deadline 的独立 staging 作业，仅短暂锁定目录事务；不能直接去掉锁。尚未注入慢工具实测。
- `TunSession.swift:198` 的有界日志数组使用 removeFirst 淘汰，持续满载时反复搬移。可使用 head-index/ring buffer，保留逐条记录、最旧优先、10,000 条和 1 MB 双上限。正常 bridge 高频 drain 下收益有限，应先量测。
- `scripts/build-macos-xray.py:24` 的 `store_true, default=True` 开关恒真；可删除无效开关及分支，让两个已批准补丁与测试无条件执行，不能增加跳过补丁的入口。
- `TrustedCoreStore.source()` 与 `LaunchPolicy.prepare()` 的源文件/复制后校验不可简单去重，后一次校验保护实际执行对象。

## 实施顺序与边界

1. 先补 helper 断连清理和更新中断的失败测试，再修恢复持有者/目录状态机；同时清理遗漏发布入口并增强 guard。
2. 修 ProfileEx 和统计持久化，使用隔离数据库验证真实读回。
3. 修 IPv6 parser、日志锁范围/磁盘轮转和 dashboard 批处理，再做定位缓存统一。
4. 最后删孤立控制代码，合并 API 包装/旧模式流程，省掉重复查询与无变化发布。

不建议整体重写 ServiceLib/WebAPI，不建议为了短代码合并 helper 权限校验，不更改固定窗口/节点表格/互斥开关产品约束，不删除用户数据或重编号枚举。保护现有网络恢复改动，实施时按独立问题小批验证。

## 本轮验证

- 产品边界检查：通过；其扫描遗漏见第 5 项。
- helper 跨语言契约检查：通过。
- 构建来源测试：11 项通过。
- 签名身份选择单元测试：4 项通过；这不等于本轮重新签名或安装应用。
- helper 现有单元测试：35 项通过，临时 scratch 编译；未注册系统服务。
- helper 临时故障特征测试：3 项复现现有错误行为，包括两种更新目录状态与断连清理失败；断言“错误确实发生”的通过不等于修复完成。
- IPv6 路由解析：隔离 Swift 复现错误。
- Native 测试：85 项，82 通过、3 跳过、0 失败；scratch 为 `/private/tmp/v2raym-native-review-20261024`。跳过项分别未设置 V2RAYM_DASHBOARD_RENDER、V2RAYM_HOVER_RENDER、V2RAYM_GEO_BENCHMARK；没有将截图或 Geo 全量基准记为通过。
- 批处理微基准：见第 9 项，结果相同、数组处理成本明显降低；尚未修改产品实现。
- helper 故障特征测试源文件：`/private/tmp/v2raym-helper-audit-repro/Tests/TunSharedTests/AuditReproTests.swift`，属于临时审查材料，不是仓库正式回归用例。
- .NET 后端测试：本轮未运行；当前 PATH 和检查的常见安装位置未找到 dotnet。后端发现以静态调用链为依据。
- 本轮未做完整产品构建、签名、打包回环、安装或真实网络验收；没有借用旧报告冒充本轮通过。
