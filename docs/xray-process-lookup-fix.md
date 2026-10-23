# Darwin 进程查询诊断修复（M2）

## 已确认的原因与边界

2026-10-22，在当前安装的 Xray 26.10.21 M1 上，使用独立子进程和回环 UDP
确定性复现：发送数据后关闭发送端 socket，核心随后处理已经排队的数据。
Darwin 已无法从现存 socket 表取得所属进程，`FindProcess` 返回 `process not found`。
原路由器逐条记录 Error，但继续匹配后续路由；20 个测试包全部成功到达回环接收端。

这证明该错误文本可以由连接生命周期竞态产生，不证明历史上每一条都来自同一原因。
macOS 无权访问的进程/socket 也可能导致归属不明；不可将所有查询不到都宣称为已关闭。
本修复没有恢复已消失的进程信息，也没有保证基于进程名称的规则一定匹配短生命周期连接。

## 补丁行为

- Darwin 的“没有匹配到 owner”返回可判别的 `ErrProcessNotFound`，不靠文本包含判断。
- 路由器对这一情况保留每次 Debug 明细，首次输出 Warning；持续出现时，每隔至少
  60 秒在下一次 miss 到来时报告自上次提示以来的合计，不逐条输出 Error。
  如果之后没有新 miss，不会额外启动定时器补发尾部计数；完整细节需使用 Debug 日志。
- 查询器返回的进程列表获取失败、已匹配 PID 的路径获取失败、归属歧义等其他错误
  继续输出 Error。没有新增前端日志过滤器。底层对单个受保护 PID/已消失 FD 的
  原有扫描跳过行为未改，不能据此声称枚举每个 PID 的失败都能独立报告。
- 原有 self/xray 防回环规则、进程匹配、白名单与 UDP 443 配置全部保留。
  进程未知仍是“不匹配此规则”，继续后续规则；不会假设它属于 Xray 或强行直连。
- M1 的 Darwin UDP 出口绑定补丁一起保留。

## 隔离验收结果

证据在 `artifacts/xray-process-lookup-20261022/`。

| 项目 | 安装版 M1 的独立测试进程 | M2 候选独立进程 |
| --- | --- | --- |
| 存活 UDP 回环收发 | 成功 | 成功 |
| 发送端已关闭的 UDP 转发 | 20/20 | 20/20 |
| 进程查询 Error | 20 | 0 |
| 归属不可用合并 Warning | 0 | 1 |
| 逐条归属不可用 Debug | 0 | 20 |
| 创建 TUN / 修改网络配置 | 否 / 0 | 否 / 0 |
| 测试子进程清理 | 完成 | 完成 |

另有正常的 `Xray started` Warning，两组均存在。
构建时 16 个顶层测试通过（另含子用例）：上游 Darwin TCP/UDP/IPv4-mapped
查询、非本机源地址、socket 匹配、wildcard UDP 查询、关闭 socket、日志分类与
聚合、路由继续匹配，以及 M1 IPv4/IPv6 TCP/UDP 绑定和回环数据回归。
诊断测试注入系统/权限错误、路径错误和歧义，确认它们仍输出 Error。

## 重建与后续交付

```sh
python3 scripts/build-macos-xray.py --go /path/to/go \
  --source-archive /path/to/verified-source.tar.gz \
  --output /tmp/new-m2-core --process-lookup-fix
python3 scripts/xray/test-process-lookup-loopback.py \
  --core /tmp/new-m2-core/xray --output /tmp/new-m2-loopback
```

沿用固定上游提交及归档校验，新增补丁 `patches/xray/darwin-process-lookup.patch`。
候选标识为 `1b1647c-v2raym-darwin-bind2`；没有改成上游新版本。
默认构建已切换到 M2，`--process-lookup-fix` 参数保留兼容。

0.2.2 将 M2 纳入完整签名应用包，主页显示 `26.10.21（修复版 M2）`。
helper 和后端显式识别 M1/M2 标识，拒绝相似但未知的标识；更新继续执行同版本跳过、
新上游版本等待验证。真实 TUN 验收独立于隔离测试和安装，不能仅凭安装完成宣称通过。
