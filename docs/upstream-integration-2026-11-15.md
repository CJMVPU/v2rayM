# 上游合并与 DDD 适配 — 0.4.8

上游 `2dust/v2rayN/master` 固定为 `c374f26d285df5444e590bb58c92f7e003efbddf`。
本地父提交 `1f3b5f138b8c12b658a085a4f38d3c9c015f6531`，共同基线 `e3457fa4`，新增 28 个提交。
通过双父合并保留真实上游祖先关系，逐路径决定记录在 `upstream-merge-resolutions-2026-11-15.json`。

## 架构适配

- 拆分 `ConfigTextHandler`、`ConfigDbHandler`、`ConfigDbQuery` 和 `ConfigState`，移除旧 ConfigHandler，
  AppManager 不再承担数据库查询/迁移。避免保留重复转发层。
- 领域/应用程序集不引入 ServiceLib 或共享状态；WebAPI 仓储及 RuntimeConfigStore 适配新入口。
- 有配置上下文的操作继续显式传入 Config，不采用上游隐式全局配置写入方式。
  设置事务继续按原锁顺序持有快照，失败恢复保持 journal 和数据库在线备份语义。
- 保留参数化查询、批量读取顺序、未知协议记录、清理 eligible 过滤、订阅失败保留、
  最终配置生成失败语义、真实核心统计端口和修订号持久化。
- pre-SOCKS 构造函数移入 builder，仍只处理原有自定义 Xray 链，不引入另一内核/TUN 桥。
- DNS 常用地址来自现有后端选项 API；SwiftUI 只显示/编辑原始值，保存仍走设置用例。
- Downloader/TUnit 升级仍需独立兼容性验证；本次没有把历史延后项宣称为已支持。

## 逐提交处置

| 提交 | 上游主题 | 处理 |
| --- | --- | --- |
| `e57e1227` | Restore Autofit Column Width Button on Main Window (#10579) | 不恢复列宽自适应按钮，保留固定原生表格。 |
| `750f2fa7` | fix: preserve inner KCP mask when adding a header (#10577) | 本地已有 KCP seed/mask 保留；追加上游相关回归。 |
| `ddf7582b` | Bump TUnit from 1.81.16 to 1.83.0 (#10573) | 依赖版本暂不升级：保留当前验证的下载器/测试运行器；不引入已移除二维码组件。 |
| `1eae1375` | Bump QRCoder from 1.8.0 to 1.8.1 (#10563) | 依赖版本暂不升级：保留当前验证的下载器/测试运行器；不引入已移除二维码组件。 |
| `cbb8721d` | Bump Downloader from 6.0.1 to 7.0.1 (#10562) | 依赖版本暂不升级：保留当前验证的下载器/测试运行器；不引入已移除二维码组件。 |
| `d5338f67` | Add IP-literal DoH presets and expose dns-module in routing inbound tags (#10571) | 移植 IP DoH 预设和 dns-module 标签；SwiftUI 从后端读取常用地址。 |
| `6288b390` | fix(macos): do not unload the LaunchAgent when updating auto-start (#10567) | 原生使用 SMAppService；保留已删除的 LaunchAgent 启动路径。 |
| `0734317f` | fix(singbox): preserve Hysteria2 hop interval ranges (#10576) | 排除 sing-box Hysteria2 更新。 |
| `28f8ca7b` | fix: import SIP008 subscriptions with numeric ports (#10575) | 移植 SIP008 数字/字符串端口及外层订阅解析修复。 |
| `480558d5` | perf: look up ProfileEx items by IndexId instead of scanning the list (#10588) | 保留本地字典与修订号持久化，适配最大排序缓存及下降/重载/清空失效。 |
| `2faf09b8` | Bump TUnit from 1.83.0 to 1.84.0 (#10594) | 依赖版本暂不升级：保留当前验证的下载器/测试运行器；不引入已移除二维码组件。 |
| `a189c659` | i18n(ru): add missing UI translations (#10595) | 不引入已删除旧桌面功能的俄语资源。 |
| `f2f336d9` | fix(tests): initialize shared SQLite schema once (#10596) | 共享测试 schema 使用 Lazy 初始化一次，追加事务内重复初始化回归。 |
| `9c7c1690` | fix: inherit targetStrategy for custom outbounds (#10597) | 移植自定义 outbound 的 targetStrategy 继承，保留显式值。 |
| `18de5da9` | fix: report Linux TUN startup failures (#10556) | 保留原生 Xray 启动就绪/受控进程验证，不引入 Linux/其他引擎 TUN；移植缺失自定义配置文件诊断。 |
| `f64c2997` | Split configuration management by storage type | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `a42642d3` | Refactor UI config access and clean up code | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `49963a16` | Extract database queries from AppManager | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `52925681` | Centralize shared configuration state | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `2c90ed1a` | Move configuration data classes to handlers | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `33fa9865` | Move pre-SOCKS helper to config builder | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `a6624e03` | Move DefaultServer function to ConfigTextHandler | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `254b39bc` | Centralize config access in database handlers | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `41231533` | Fix test | 保留本地测试与显式配置绑定，适配配置拆分。 |
| `4e40d5f5` | Optimize AppManager | 适配 Handler/Data 配置拆分及调用点；保留显式事务配置、DDD 端口、本地查询/恢复/迁移语义。 |
| `9f599c60` | fix(xray): keep direct DNS ahead of catch-all proxy rules (#10599) | 移植直连 DNS 在代理兜底规则之前的优先级修复及回归。 |
| `f5bdbe34` | fix(ui): show ALPN values that are not in the preset list (#10604) | 原生 ALPN 文本输入已支持自定义值；不恢复旧 UI。 |
| `c374f26d` | refactor(masque): allow empty credentials and enable TLS by default (#10601) | MASQUE 功能此前延后，继续保留本地显式支持范围。 |

## 验证

ServiceLib、WebAPI、SwiftUI 和 helper 测试、产品边界、DDD 边界及契约校验均运行。
新增回归包括 DNS 兜底顺序、负载均衡、targetStrategy、SIP008、配置快照隔离、参数绑定、
测试 schema 初始化，以及最大排序值降低/重载/清空。已有失败补偿、用户数据保留和原生 TUN 配置回归保留。
构建采用同一提交快照并执行签名包内回环；另执行临时数据的备份/恢复回环。

证据路径：`artifacts/reviews/2026-11-15-upstream-048/`。
安装、远程推送和清理结果单独记录；本地回环不代表真实 TUN 网络验收或公证。
沿用用户要求，推送后不等待远程 CI 完成。
