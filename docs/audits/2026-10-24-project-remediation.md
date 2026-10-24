# 0.3.5 全项目修复、优化与日志配色

本轮承接 前轮代码审查的全部主要项及附加维护项（原始审查见 Git 历史），同时保留此前未提交的网络恢复修改。用户确认现有改动一并提交，并在回归后安装替换；不推送、不公开发布。原始工作区补丁保存于本机 `artifacts/reviews/remediation-2026-10-24/baseline/`。

## 已实现

| 审查项 | 处理结果 |
| --- | --- |
| 1 helper 断连清理 | 清理协调器持续持有失败会话，限频重试；成功才移除。shutdown 在 20 秒内并行重试，失败明确记录恢复未确认并非零退出，强杀也不冒充路由恢复成功。 |
| 2 更新中断恢复 | 恢复 previous-only 状态；校验 committed current 后清理残留 previous；阻止未提交激活被覆盖。 |
| 3 ProfileEx | 按 ID 唯一缓存、修订号待保存集合、原子 SQLite 保存，失败保留重试数据；读取副本，保存期间的新更新不会被误清除。 |
| 4 统计一致性 | 移除脱离保存列表的对象缓存；等待采样任务关闭，保存后再初始化；设置、退出、备份恢复等待真实结束。 |
| 5 发行边界 | 所有共享后端资产入口只提取 Xray、许可证与 DAT；固定 bundle commit；完整包拒绝多余内核/数据；扫描工作流、容器和打包脚本。 |
| 6 日志过滤 | 锁内快照、锁外正则；每次仅解析一次，匹配 50 ms、整次过滤 200 ms 预算。保持原有降级语义：无效/昂贵表达式返回未过滤快照。 |
| 7 磁盘日志 | 持续读取 stdout/stderr；当前/前一份各 8 MiB、0600 权限；旧超大文件截尾；非阻塞末尾排空，不因继承 writer 拖住退出。 |
| 8 IPv6 路由 | 分离地址 token 后解析路由标签；覆盖 direct/proxy/block，避免将 IPv6 方括号当作路由。 |
| 9 近期连接性能 | 从最新日志反向去重，最多保留 24 条，避免平方级中间数组；ISO8601 日期解析使用 FormatStyle。 |
| 10 定位缓存 | 单一缓存管理 TTL；成功 1 小时、失败 30 秒、容量 512；合并在途查询，同地址也能过期刷新。 |
| 11 节点查询 | 删除列表重复 JOIN；SQLite 包装支持参数，订阅查询/删除绑定原始 ID。 |
| 12 死代码 | 删除无调用 Clash 控制闭包、专用 HTTP 写方法、StatePort2、无调用其他 Geo 下载及退役内核更新兼容；保留持久化枚举编号和未知节点记录。 |
| 13 Native 包装/流程 | 统一 API value/send/perform；旧 TunMode.apply 场景迁移到实际 ProxyModeSwitch 后移除旧流程，保留冲突和回滚校验。 |
| 14 无变化发布 | 空日志/重复增量和相同元数据不重复广播；移除无读者的 updateGeneration。 |

附加项：helper staging 网络和工具操作移出全局锁，使用连接取消和总计 100 秒 deadline，bridge 保留 110 秒等待余量；helper 日志使用 head index/周期压缩，保留 10,000 条与 1 MB 双限额；Xray 构建删除恒真的补丁开关，两项已批准补丁及测试无条件执行。源文件和复制后二次摘要校验均保留。

日志配色基于来源类型和明确等级标记：error/fatal 红色，warning/warn 琥珀色，core.start/core.started/core.stopped 等生命周期绿色，info 蓝色，debug/trace 紫色，普通日志使用系统文字色。实际后端 `source=core, message=core.started` 同样识别；错误优先于生命周期。记录全文及多行续行保持同色；不更改逐条记录、双向滚动、隐藏滚动条、字体或布局。

## 回归证据

以下均为本轮当前源码执行结果，不借用旧版本通过记录：

- ServiceLib：118 成功，0 失败、0 跳过。
- WebAPI：449 成功，0 失败、0 跳过。
- Native：98 成功，0 失败、0 跳过。启用 dashboard、hover、浅深日志截图及真实 Geo 对比；559,715 条地点记录逐条一致。
- Helper：49 成功，0 失败。含真实 `/bin/sleep` 子进程取消/回收，无 TUN 和外网访问。
- 构建来源 11 项、签名身份选择 4 项、边界扫描 3 项、资产提取/包边界 6 项通过。
- 六种共享后端 RID 的离线打包、更新包边界、manifest 篡改拒绝 dry-run 通过；相关 workflow YAML 及 shell/Python 语法检查通过。
- 跨语言 helper 契约、产品边界检查、`git diff --check` 通过。

先失败再修复的证据覆盖：节点扩展首次保存和失败重试、同节点统计重初始化后累计、复杂日志过滤阻塞写入、更新目录的两个中断状态。新增测试还覆盖保存期间并发更新、SQL 引号 ID 精确读写、等待采样回调关闭、断连清理重试、shutdown 持续失败/短暂失败/强杀、慢 stage 不阻塞 rollback、取消后 stage 清理、日志双界限、API 具体/协议类型一致行为、缓存失败 TTL、颜色追加/淘汰及继承 pipe writer。

交叉审查补修了真实 publish 的 `bin/.keep` 与 Windows 复制嵌套问题，并验证 `test-`/`smoke-` 命名工作流仍受边界扫描。

.NET 测试使用本机 `/private/tmp/v2raym-dotnet-sdk/dotnet`（10.0.402），独立临时 cwd，并设置 `DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE=false`、`DOTNET_USE_POLLING_FILE_WATCHER=1`，避免 Documents 目录 FSEvents 初始化挂起。首次挂起的运行已终止，完整通过来自后续重跑。

## 整包与安装记录

版本为 0.3.5，显示版本和 bundle build 一致。构建通过统一 `build-macos-product.py` 入口，使用已核对版本/补丁/工具链标记的 Xray M2 与已校验 Geo 数据。构建、签名和整包回环结果以本机 `artifacts/reviews/remediation-2026-10-24/product/verification.json` 为准；源码身份以同目录 source-snapshot/product-manifest 为准。安装替换、旧包备份、最终 Git 提交和重新启动检查单独记录在 `artifacts/reviews/remediation-2026-10-24/installation.json`，不把安装状态写成构建通过。

本轮环境另有 v2rayN 持有 TUN/系统代理，因此不执行真实 TUN 接管，不修改其配置/进程。隔离回环不是休眠、切网或真实 TUN 联网验收。开发签名包未公证；未运行远程 Windows/Linux CI 或容器构建。系统强制终止仍可能使路由恢复无法确认，错误状态不会被报告为正常完成。
