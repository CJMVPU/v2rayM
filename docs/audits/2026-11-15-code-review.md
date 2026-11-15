# 2026-11-15 全仓库代码审查

审查基线：`90f59a96`。工作开始时工作区干净。由主智能体与三个子智能体分别检查原生客户端、ServiceLib/WebAPI、helper/构建脚本；这是一轮静态审查加自动化回归，并非逐行安全证明或长期性能测量。

## 本次修复

- **流量趋势保留**：`TrafficTrend` 不再按节点/内核启动时间清空历史；改变会话时切换曲线段，拒绝早于新内核启动时间的采样，保留最近五分钟与最多 61 点限制。停止期间显示时钟冻结，恢复后按真实时间淘汰过期点；不提供应用退出后的磁盘持久化。后端实时均值和计数器基线重置继续保留，防止跨核心错误累计。
- **测速区域设置**：内部测速小数字符串统一 invariant 格式与解析，避免逗号小数系统中的 `1,5` 被 API 读为 `15`。补充文化环境回归。
- **DMG 说明**：移除固定声称 Apple Development 签名的文字；构建允许 ad-hoc，因此说明应准确描述签名取决于构建身份，且 ad-hoc 无法授权 TUN helper。本次没有发布 DMG。

## 后续精简、重构与优化候选

| 优先级 | 位置 | 证据、影响与建议 |
| --- | --- | --- |
| P2 性能 | `macos/Native/Sources/V2rayM/GlobeMonitor.swift:23` | 单 actor 内同步 `getaddrinfo` 会使慢域名阻塞其他位置解析。八任务上限并不意味着八路 DNS 并发。考虑有界专用解析执行器与超时，保留失败缓存和取消后不发布旧结果的约束；只涉及位置展示。 |
| P2 内存 | `macos/TunHelper/Sources/TunShared/TrustedCoreStore.swift:127,335,352`；`LaunchPolicy.swift:76` | SHA256 前全量读取最多 256 MB 的核心。可抽取流式文件摘要函数；必须保留源文件及私有执行副本两次校验，不能省略防替换竞态的验证。 |
| P3 精简 | `macos/TunHelper/Sources/V2rayMHelper/main.swift:23`；`TunShared/TunSession.swift:144` | 分发与会话处理重复 JSON/Base64 解码。可增加内部已解码请求入口，边界仍执行 wire 大小检查，保留非法 JSON/未知 action 错误语义。 |
| P3 性能 | `v2rayN/v2rayN.WebAPI/Services/LogBuffer.cs:81` | 无新日志时 Tail 仍扫描最多一万条队列。可在锁内对相同 sequence 快速返回空集合，仍返回最新 generation；收益需测量。 |
| P3 契约 | `v2rayN/ServiceLib/Services/DownloadService.cs:33` | 进度回调丢弃返回 Task。当前产品消费方最终同步完成，未确认用户可见故障。后续统一为同步契约或端到端等待异步回调，覆盖顺序、取消、异常；不能改为 async void。 |
| P3 刷新 | `macos/Native/Sources/V2rayM/AppModel.swift:284`；`ContentView.swift:10` | 周期发布状态和趋势使顶层观察者失效。可按监控、日志、更新进度拆 observable，并减少未变化值发布。先用 Instruments 确认收益，不能据此宣称已有明显卡顿。 |
| P3 重构 | `macos/Native/Sources/V2rayM/AdvancedSettingsPanel.swift:24` | 参数、DNS、路由的 draft/绑定/校验/保存集中；可拆子模型与视图，保留完整原始文档，避免遗漏未展示字段。 |
| P3 重构 | `V2rayRuntime.Settings.cs`、`V2rayRuntime.CoreUpdate.cs`、`V2rayRuntime.cs`、`ConfigHandler.cs` | 大文件按 DNS/路由编辑、预设、更新决策和安装事务逐步抽服务。继续使用已有事务/协调器，保留 geo 与 runtime mutation 的独立锁域及回滚。 |

这些候选没有混入本次生命周期修复；尤其 helper 权限、认证、可信更新、路由/DNS 恢复不适合为了减少行数而重写。

## 验证与交付边界

原生、helper、ServiceLib、WebAPI 测试；产品边界、helper 契约、构建来源和签名规则检查；完整签名包与隔离回环验证。实际执行结果以本次 `artifacts/reviews/2026-11-15-code-review/` 下日志及 `product/verification.json` 为准，不以历史版本报告代替。

两个 .NET 测试项目共享 ServiceLib 构建产物，首次并发执行发生资源文件争用；后续按顺序执行。当前 SDK 位于 `artifacts/releases/verification-0.4.1/dotnet/dotnet`；跨进程 WebAPI 测试还需将该目录加入 PATH，否则子进程找不到 dotnet，修正环境后重跑。

本次不安装到 Applications、不切换系统代理或真实 TUN、不修改 v2rayN 数据。版本保持 VERSION 的 0.4.4；修复通过 Git 提交交付，构建为本机验证产物，不是新版本公开发布或公证发行。
