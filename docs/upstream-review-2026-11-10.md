# Upstream review - 2026-11-10 / v2rayM 0.4.2

Upstream: 2dust/v2rayN, tip `e3457fa4b4776d380d3bac271e63eeb42847ebaa`.
Reviewed 73 commits after common ancestor `66dd7da6e69b3bcad51115d1c7d5e017b7ef0dd0`.
Local starting HEAD: `480123018923770e2fc9277d9444737d846714c7`. Branch: `codex/upstream-2026-11-10`.

Selective source integration, not a blanket merge. No commit or push; no artificial merge ancestry for excluded changes. Origin/upstream remain configured. The existing uncommitted 0.4.1 upgrade was backed up and preserved.

## Adopted behavior

ECH no longer emits obsolete echForceQuery. REALITY tlshello fragmentation uses packets 1-3 while normal TLS retains tlshello. SIP002 passwords decode once; legacy base64 SOCKS import works. Starting a speed test clears stale speed; UDP attempt timeouts retry while caller cancellation propagates. UDP hopping uses finalmask.udphop, preserving salamander/realm ordering and local KCP seed composition. Unix environment names remain case-sensitive; restart polling does not pass expired negative deadlines to Task.Delay. Public root resources, NLog 6.2.2 and SQLite 3.54.1 are updated. Existing macOS lock handling, transactional subscription preservation and profile concurrency behavior are retained with applicable upstream tests.

## Per-commit disposition

| Commit | Subject | Decision |
| --- | --- | --- |
| `57f17d59` | fix(profile-ex): make ProfileExItem creation atomic per IndexId (#10420) | Already covered by equivalent or stronger local implementation; retain it and applicable regression tests |
| `e2f42923` | ReactiveUI 26 (#10249) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `78b0b222` | Native Aot (#10295) | Defer: Keep non-AOT publishing and existing serializer contracts |
| `8b93d357` | Add ProDataGrid (#10347) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `4169c12a` | test: strengthen ProfileExManager concurrency regression coverage (#10410) | Already covered by equivalent or stronger local implementation; retain it and applicable regression tests |
| `ad3e24b6` | Fix fragment packet selection for REALITY (#10428) | Adopt applicable source/resources and tests |
| `7e14cf97` | Preserve subscription profiles on failed import (#10429) | Already covered by equivalent or stronger local implementation; retain it and applicable regression tests |
| `fcd31300` | Update GlobalHotKeys (#10493) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `36184045` | Fix (#10431) (#10432) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `e1c96335` | fix: keep the PAC listener running after a client reset (#10447) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `926790b0` | fix(speedtest): clear the last speed when a speed test starts (#10449) | Adopt applicable source/resources and tests |
| `5664270b` | Update cert (#10450) | Adopt applicable source/resources and tests |
| `9593b289` | Fix (#10460) | Already covered by equivalent or stronger local implementation; retain it and applicable regression tests |
| `70ab27e4` | Fix udp test (#10484) | Adopt applicable source/resources and tests |
| `3dce503a` | Fix (#10494) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `e044b90c` | chore(deps): update Downloader to 5.10.2 (#10491) | Defer: Retain currently validated downloader dependency |
| `bf2584c9` | Bump docker/setup-buildx-action from 3 to 4 (#10424) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `b13ae259` | Bump actions/download-artifact from 7 to 8 (#10425) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `aac4520f` | Bump actions/setup-python from 6 to 7 (#10426) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `3d44ba8e` | chore(deps): update NLog to 6.2.2 (#10409) | Adopt applicable source/resources and tests |
| `4c8b865d` | Bump docker/build-push-action from 6 to 7 (#10427) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `2bc79bc5` | Bump Repobot.SQLite.Unofficial from 3.53.4.1 to 3.54.1 (#10416) | Adopt applicable source/resources and tests |
| `a2a8a77f` | chore(deps): update MaterialDesignThemes to 5.4.0 (#10423) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `75691697` | fix(xray): stop emitting obsolete echForceQuery (#10480) | Adopt applicable source/resources and tests |
| `ebabf790` | fix(webapi): allow reading the instance-lock owner on macOS (#10454) | Already covered by equivalent or stronger local implementation; retain it and applicable regression tests |
| `743eb323` | fix(webapi): preserve Unix environment names and isolate test fixtures (#10455) | Adopt applicable source/resources and tests |
| `8c02b5f2` | Update cert workflow (#10497) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `7a52be41` | chore(deps): bump IPNetwork2 from 4.3.0 to 5.0.1 (#10453) | Defer: Major IPNetwork2 upgrade requires dedicated native route validation |
| `c436b998` | fix: persist repeated profile test results (#10466) | Already covered by equivalent or stronger local implementation; retain it and applicable regression tests |
| `0856ffd7` | Try fix dns (#10485) | Defer: DNS address index compared to expectedIPs.Count; do not adopt this finalQuery selection |
| `d4880dbe` | Fix policy group (#10495) | Defer: Group BFS lacks a visited set; defer until cyclic configuration regression is covered |
| `59487dca` | Add MASQUE warp support (#10498) | Defer: New MASQUE WARP feature requires native configuration adaptation |
| `4c4449e7` | fix: match proxy group types without case sensitivity (#10472) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `19850f92` | Profile pre-resolver (#10220) | Defer: New subscription pre-resolver changes stored addresses; separate feature integration |
| `3d0f45f6` | Update loongarch64 build (#10487) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `0f1f82af` | Fix (#10501) | Defer: Fix for deferred pre-resolver feature |
| `522bca49` | fix(fmt): import legacy base64 SOCKS links again (#10505) | Adopt applicable source/resources and tests |
| `a74d10ba` | Bump actions/checkout from 6 to 7 (#10507) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `281f5ee3` | Bump TUnit from 1.73.19 to 1.78.0 (#10509) | Defer test-framework-only upgrade; retain validated test runner |
| `fe54a73d` | Fix ipinfo copy functionality (#10515) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `ff9fd7b9` | fix(fmt): default the AnyTLS and Naive port to 443 when the link omits it (#10504) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `749a7312` | Prevent duplicate UI style injections | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `9d1063f3` | Fix | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `0d9e8455` | fix(fmt): decode the SIP002 plain-text password only once (#10520) | Adopt applicable source/resources and tests |
| `2239982a` | feat(dns): support optional IPv6 FakeIP pools (#10464) | Defer: New optional IPv6 FakeIP requires native settings and TUN acceptance |
| `aa00b2c6` | build(deps): bump Avalonia.Desktop to 12.1.5 (#10503) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `9a029a3f` | fix: resolve JSON and SQLite trimming warnings (#10513) | Defer: Depends on AOT metadata refactor; retain local transaction implementation |
| `66546700` | Fix UI (#10527) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `8027b2cf` | fix(webapi): handle expired restart polling deadlines (#10516) | Adopt applicable source/resources and tests |
| `15ed51f9` | Fix (#10530) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `92aa3ba6` | Adjust Download Configuration (#10531) | Defer: Part of deferred downloader configuration refactor |
| `b8458fdb` | Bump TUnit from 1.78.0 to 1.80.0 (#10528) | Defer test-framework-only upgrade; retain validated test runner |
| `7c49b236` | chore(deps): update Downloader to 6.0.1 (#10517) | Defer: Downloader 6 migration requires separate lifecycle validation |
| `2010477f` | fix(fmt): keep a ':' in a Naive password through export and import (#10526) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `052f6f0f` | Suggest local interfaces in bind setting | Defer: Desktop adapter suggestion UI is not used |
| `c01224c3` | Remove FrozenColumnCount | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `5211b9ce` | feat: add sing-box TUN dns_mode setting (#10336) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `5d2e339e` | fix(desktop): 删除确认对话框打开时聚焦确认按钮 (#10542) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `f1ef8dfb` | Bump ProDataGrid from 12.1.0.6 to 12.1.5 (#10543) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `91d1cbe5` | Bump TUnit from 1.80.0 to 1.81.0 (#10545) | Defer test-framework-only upgrade; retain validated test runner |
| `6e48e507` | Update package-rhel.sh (#10537) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `92a9da8b` | Refactor download (#10534) | Defer: Retain cancellation propagation and trusted update lifecycle instead of replacing download/subscription architecture |
| `54ecc045` | Add HeaderContextMenu (#10547) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `5ca37027` | Fix udphop (#10550) | Port UDP-hop schema/order fix only; reject KCP change that replaces the seed list |
| `73670c70` | fix(singbox): keep the ws path query when removing ed (#10548) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `1e167449` | Update ResUI.zh-Hant.resx (#10511) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `968beb44` | feat(core): support AUTO option and filter non-IP NDIS interfaces for BindInterface (#10519) | Defer: Heuristic AUTO interface selection must not replace native route-aware recovery |
| `0f71c46d` | feat: support Xray XDRIVE object storage relay transport (#10546) | Defer: New XDRIVE transport requires native import/edit/save validation; not included in this fix release |
| `f07e3dc4` | fix(resx): restore HeaderContextMenu localization resources accidentally overwritten during merge (#10553) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `cc28308b` | Update certificate (#10554) | Adopt applicable source/resources and tests |
| `cdcac040` | fix(dns): inherit proxy dial strategy in speedtest config (#10558) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |
| `7188f36e` | Bump TUnit from 1.81.0 to 1.81.16 (#10561) | Defer test-framework-only upgrade; retain validated test runner |
| `e3457fa4` | Bump Avalonia.Desktop from 12.1.5 to 12.1.6 (#10560) | Exclude retired desktop/other-engine/platform packaging or associated UI/CI changes |

## Verification and delivery

Version 0.4.2 keeps Xray 26.11.9 with the local M2 process-diagnostic patch. The operator script now requires 0.4.2.
Boundary, ServiceLib/WebAPI, Swift/helper, provenance, signed packaged-loopback and installation results are recorded under `artifacts/releases/verification-0.4.2/`.
Per explicit user instruction, install first and leave real TUN/network acceptance to the operator after disconnecting v2rayN, using `scripts/验证新版v2rayM.command`. Offline success is not real-network acceptance.
