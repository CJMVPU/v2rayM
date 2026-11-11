# Upstream integration and v0.4.3 - 2026-11-11

Fetched upstream/master again: latest remains e3457fa4b4776d380d3bac271e63eeb42847ebaa. New dependency PR branches are not merged master changes.

The 73 commits through that tip were reviewed in upstream-review-2026-11-10.md. Commit cb73805e preserves the tested selective integrations and Xray 26.11.9 M2 upgrade. This release completes a two-parent merge with that upstream tip. Remaining paths from the automatic merge were resolved individually to the reviewed product tree; upstream-merge-resolutions-2026-11-11.json records each path and its contributing upstream commits. Retired components remain deleted. Deferred AOT/download/transport features remain deferred; future integration must revisit the ledger explicitly, as these commits are now ancestors.

There are no new upstream master fixes beyond the previous review. The adopted fixes (SIP002, SOCKS, ECH, REALITY, UDP hopping, speed testing, environment names, restart deadlines, roots and runtime dependencies) are retained, including native cancellation, signing, trust-store and network recovery protections.

User-requested native changes:

- Close/minimize controls refresh pointer tracking when attached or tracking areas change, handle mouse movement and show a fixed-size tinted halo plus action glyph. Disabled controls remain neutral.
- Traffic history no longer evicts samples while stopped/disabled. A frozen clock is used for visible points, peaks and the time axis; animation is disabled. Enabling traffic resumes pruning and the live timeline. Existing session boundaries and bounded capacity remain enforced.
- Operator validation launcher now expects app version/build 0.4.3.

Validation and installation evidence lives in artifacts/releases/verification-0.4.3/. Real TUN acceptance remains operator-run after disconnecting v2rayN; no actual TUN is started during this build/install task. No push or public release is requested.
