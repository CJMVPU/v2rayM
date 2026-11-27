# v2rayM 文档

使用和安装见[项目首页](../README.md)。维护当前版本时可按下表查找入口。

| 要解决的问题 | 文档 |
| --- | --- |
| 如何构建签名安装包，验证 DNS、两跳出站和整包转发 | [构建、测试与打包](build-and-test.md) |
| 节点如何变成运行会话，停止或切网时如何恢复 | [运行架构](macos-architecture.md) |
| 哪些功能属于领域层、应用层、宿主或系统适配器 | [DDD 模块边界](ddd-architecture.md) · [功能扩展指南](ddd-extension-guide.md) |
| TUN 助手何时启动，如何授权和验证恢复 | [TUN 助手](macos-tun-helper.md) |
| 如何维护流量趋势、近期连接、离线定位和动画 | [主页实现](connection-dashboard.md) |
| 哪些上游改动可以移植，Xray 保留了哪些 Darwin 修复 | [上游合并规则](upstream-merge-policy.md) · [出口绑定](xray-darwin-binding-fix.md) · [进程查询](xray-process-lookup-fix.md) |

## 历史记录

最近一次[上游 8.0.1 同步记录](upstream-integration-2026-11-26.md)列出了 DNS、自定义出站的移植范围及延后项目。更早的[上游审查](upstream-review-2026-11-10.md)、[11 月 11 日合并](upstream-integration-2026-11-11.md)、[11 月 15 日合并](upstream-integration-2026-11-15.md)、[Xray 候选验证](xray-26.11.9-validation.md)、[DDD 审查](ddd-audit-2026-11-15.md)和[专项审查记录](audits/)描述各自提交时的实现与验证环境。
