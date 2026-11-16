# 0.4.9 审查问题修复与优化

本次在 0.4.8 已合并的上游基线上完成六项修复、两项优化，不引入新的引擎或界面框架。

| 项目 | 修复行为 | 验证入口 |
| --- | --- | --- |
| 损坏配置被默认值覆盖 | 已存在但无法解析的配置返回加载失败，保留原文件；只有文件不存在才生成默认配置 | `ConfigLoadFailureTests` |
| 删除活动路由中途失败 | 回退方案激活或最后选择保存失败时，在原有事务租约内恢复快照；恢复失败保留双重错误 | `RoutingMutationCompensationTests` |
| TUN 与偏好设置并发写入 | TUN 写入使用与其他设置相同的独占操作准入，观察读取仍可进行 | `RuntimeRequestOperationPolicyTests` |
| 失败订阅也更新时间 | 返回逐项更新结果，只给成功项目盖时间戳；失败使用独立自动重试退避 | `SubscriptionOutcomeTests`、`SubscriptionWorkflowTests` |
| 导入失败丢失输入 | 等待服务端确认后关闭；失败留在主窗口，保留输入并可重试；防止重复提交 | `SettingsPresentationTests` |
| 新路由重复创建 | 从 POST 响应立即保存 ID；后续观察/列表刷新失败不会把已确认保存变成重复 POST | `SettingsPresentationTests`、`AppModelOrchestrationTests`、打包回环 |
| 频繁读取完整节点表 | 状态查询直接计数；元数据 30 秒、内存观测 5 秒；命令后强制刷新 | `ProfileQueryApplicationTests`、`ProfileObservationTests`、原生编排及回环 |
| 运行宿主职责过多 | 路由映射/编排移至专用适配器，保留宿主入口和应用用例；导入视图从主布局提取 | DDD 边界检查、路由补偿及回环 |

## 上游兼容边界

- 保留 Git 合并祖先、ServiceLib 的原订阅方法及列表接口默认响应；新行为优先放在 Application/Adapters。
- ServiceLib 的必要修改限于拒绝损坏配置，以及提供原处理结果，不复制整个上游处理器到新架构。
- 复用 operation/lifecycle/mutation 租约和现有快照恢复，不引入第二套锁、工作流框架或事件存储。
- 保留签名 helper、可信内核更新、回滚和网络恢复策略；不运行真实 TUN 验证，不修改其他代理配置。

## 交付验证

构建前检查产品与 DDD 边界，执行 ServiceLib、WebAPI、Swift 原生、helper 测试，并对新打包应用运行隔离回环。
具体测试日志、渲染图、源快照、产品清单和 DMG 哈希保存于 `artifacts/reviews/2026-11-16-audit-049/`。
这次只生成安装包，不安装、不替换当前应用；本机开发签名不等于 Apple 公证。
