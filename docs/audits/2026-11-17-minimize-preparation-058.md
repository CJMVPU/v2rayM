# v0.5.8 pre-minimize rendering pause

The custom title-bar minimize action now freezes dashboard publication and its
display links before calling AppKit. A cancellable main-actor task yields for
180 ms, giving SwiftUI's resting surface update and previously submitted work a
separate scheduling interval before `NSWindow.miniaturize`. The main thread is
never slept or blocked. Title-bar hover timers are settled at the same click.

A window-scoped preparation latch prevents occlusion updates or a stale SwiftUI
body from restarting rendering during the gap. AppKit's existing minimizing latch
then owns the pause. If AppKit rejects the request, releasing the preparation
latch allows the existing return coordinator to resume instead of leaving a
permanently frozen window. Restoring still uses the 0.85-second stability interval,
0.45-second data transition and bounded chronological chart-history replay.
The 120 Hz request and solid front/back/edge flip renderer are unchanged.

Repeated clicks coalesce into one request. Close, hide, activation loss, an external
minimization or deminiaturization cancels pending work. The status-bar show action
also cancels it before showing the window. Visibility is rechecked immediately
before calling AppKit, and cancellation uses a generation guard to prevent an old
task from minimizing a subsequently restored window.

This delay applies to the application's custom minimize button. It does not
intercept private WindowServer or Stage Manager operations, nor add a delay to
other applications' switching. The interval is not a GPU-idle query/fence: it
separates application rendering from the system transition but cannot guarantee
that other applications or WindowServer have finished using the GPU.

## Validation

Evidence: `artifacts/reviews/2026-11-17-minimize-058/`.

- Native suite: 209 executed, 205 passed, four optional checks skipped; helper
  suite: 63 passed. Product-boundary guard passed. New tests cover synchronous
  freeze, main-actor responsiveness during the gap, duplicate clicks, cancellation,
  external minimization, restoration, visibility recheck, window scoping and
  handing the preparation latch over to the existing AppKit minimizing latch.
- An instrumented release-mode offline dashboard exercised the default 180 ms
  coordinator with synthetic telemetry. Preparation-to-AppKit-call measured
  196.00 ms, including scheduling and synchronous JSON trace writes. It issued
  zero display callbacks and published zero dashboard snapshots during the gap.
  The phase changed to suspended synchronously, within 0.91 ms of the preparation
  trace. Raw events and `preparation-results.json` retain the evidence.
- That offline window again did not produce actual Dock miniaturization events.
  The scheduling change is verified, but actual Dock animation frame pacing and
  the user's perceived startup stutter are not accepted as fixed by this probe.
  No GPU-occupancy or compositor-FPS improvement is inferred from display callbacks.
- Existing render checks retain the dark theme, seven connection rows and solid
  flip geometry. No proxy was started and no installed configuration was edited.

The existing delivery instruction remains: bump the version, build a signed local
DMG, preserve the installed application, commit/push and clean old build products
without waiting for remote CI. Signing, packaged loopback, read-only DMG hash
verification, installed-file preservation and cleanup are recorded separately in
the release receipts. No notarization or real-network/TUN acceptance is claimed.
