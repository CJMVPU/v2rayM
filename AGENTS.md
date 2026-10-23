# v2rayM repository instructions

Read `docs/upstream-merge-policy.md` before importing upstream changes. The latest
explicit user decision is **macOS SwiftUI + Xray only**, including native Xray TUN.
Older documents describing multi-core support are historical, not requirements.

## Product boundaries
- Keep the upstream Git/fork relationship. Reuse and improve ServiceLib/WebAPI
  behind the native SwiftUI app. Do not restore Avalonia/WPF/Windows/Linux GUIs.
- Xray is the only proxy executable. Do not restore sing-box compatibility,
  models, generators, assets, SRS rules, downloads, or a SOCKS-to-TUN bridge.
  Do not add Mihomo or other engines, their update buttons, or executable fallbacks.
- Unsupported imported or stored nodes must fail clearly; never silently route
  them through another engine or delete the user's records.
- Preserve the signed helper, caller authentication, restricted launch policy,
  trusted update store, rollback, route/DNS recovery and cancellation behavior.
- Never change v2rayN's configuration or data. Real TUN tests must not run while
  another VPN/TUN owns the network; use offline/loopback validation first.

## Native experience
- Fixed compact window; LXGWWenKaiMono Medium; no sidebar or subscription page.
- Home defaults to a house icon. Navigation and import/mutually exclusive system
  proxy and TUN controls stay in the title bar. No separate connect button.
- All buttons have disabled-aware hover feedback without layout shifts.
- Node table has fixed names, order and widths, including transport and TLS; do not
  restore manual column resizing/reordering. Footer height never changes on selection.
  “配置节点” is always visible and disabled without a selection, left of
  “设为当前节点”. Editing must preserve unexposed fields and validate before save.
- Logs use bounded oldest-first eviction, retain history across mode changes,
  show each record separately, support both scroll directions, hide scrollbars.
- Notices must not reflow content. Update progress stays within Settings.
- Keep MTU presets/custom entry and the validated 1280–65535 range.

## Merge and verification
- Read the v2rayM release version from `VERSION`: exactly three single-digit
  components. Display version and bundle build must match; carry 0.2.9 to 0.3.0
  and 0.9.9 to 1.0.0. Do not add a fourth component or rename upstream Xray versions.
- No blanket “take upstream” resolution on protected areas. Review each change
  against the policy, port useful Xray/security fixes, omit retired features.
- Run `python3 scripts/check-macos-product-boundaries.py` before builds and merges.
  Do not weaken the guard to pass an upstream merge; changes to scope require
  explicit user authorization.
- Run affected backend/Swift/helper tests and packaged loopback smoke checks.
  Record build, signing, installation and real-network acceptance separately.
- Preserve uncommitted user work and secrets. Do not commit, push, publish, or
  modify other apps unless requested. Do not claim a local package is notarized.
