# v0.6.0: reduce application work at Stage Manager departure

Keep the foreground 120 Hz preference, the solid flip's nine side planes, front,
back, lighting, shadows and timing. Keep the 500 ms custom minimize preparation
and the existing return-stability/data/history catch-up behavior.

## Changes

- Cache the lock state for departure/geometry/occlusion events. Initial attachment,
  activation return, screen wake and session return reconcile it with the system;
  distributed lock/unlock notifications still update it. This removes a synchronous
  session-state query from the path before display-link invalidation.
- Publish a presentation phase only when it changes. Geometry during return still
  restarts the quiet timer, and new departures still cancel pending return tasks.
  Stable cards no longer publish identical presented-active/content values while
  freezing. Disc/row resets skip writes when already settled.
- Explicitly clear transaction animation as well as disabling new animations when
  the dashboard is suspended. More significantly, give each solid surface a
  non-animated rendering gate: both its animatable vector and its rendered angle
  become zero while flips are disabled. Cancelling the task alone did not stop
  all already-created SwiftUI angle interpolation in the instrumented runs.
  The gate prevents remaining interpolation from constructing side/back planes
  during system switching, without replacing the sole front content tree.

The low-level freeze notification remains repeatable. A trial deduplication could
miss a display clock attached after an initial freeze; the existing regression
caught this and notification delivery was retained. Only redundant published view
state is suppressed. No native layer-time manipulation, screenshot overlay,
private system API or global animation preference is used.

Apple documents [transaction animation](https://developer.apple.com/documentation/swiftui/transaction)
and [disablesAnimations](https://developer.apple.com/documentation/swiftui/transaction/disablesanimations)
separately. The geometry gate also guards already-created interpolation; it does
not rely on the transaction flag alone to retire it.

## Verification

Evidence: `artifacts/reviews/2026-11-17-transition-060/`.
The matched release-mode fixtures use the current production sources versus
v0.5.9 (`91739dec`), with the same synthetic traffic and seven-row-per-second
connection load. Public AppKit activation switches the two owned test apps;
Stage Manager is enabled. Normal round trips and rapid reversals are exercised.
The installed app, proxy configuration and real network routes are not exercised.

`first-pass-results.json` retains the initial publication/query optimization;
`second-pass-results.json` retains the subsequent transaction-only experiment.
Those runs still showed rotating surface computation after departure. The final
`transition-results.json` measures the renderer gate too. Counter instrumentation
and synchronous trace writes affect absolute timings; these are application CPU
and rendering-work observations, not GPU utilization or compositor frame pacing.

In the final run's first four normal departures, system lock-state queries fell
from three per departure to zero, phase publications from two to one, and card
publications from six to zero. Baseline rotating surface evaluations were
0/104/49/50; candidate evaluations were 0/0/0/0. Total surface evaluations had
medians of 58.5 and 18 respectively. Both versions issued zero additional display
callbacks after freezing and zero callbacks during stable inactive sampling.
Candidate foreground rendering still recorded 8,612 active solid-surface
evaluations across the run. Rapid reversals did not restart rendering before the
return stability interval.

Observation windows end at the first 250 ms sample at least 500 ms after the will
notification (actual intervals: 501–767 ms in this matched set). App CPU time
medians were 178.56 ms baseline and 133.35 ms candidate; time-normalized CPU medians
were 34.74% and 21.82% of one core. These four-sample results include SwiftUI work,
synthetic data generation and trace overhead, have different animation phases,
and are not a controlled estimate of production CPU savings. Stable-inactive
fixture CPU was 2.70%/2.11%, also including the fixture's periodic trace writes.
A sample delta can straddle the will notification; `framesAfterFreeze` uses event
counters and is the authoritative post-freeze callback measurement.

Regression checks cover no redundant phase/card publication, cached-lock departure
and return reconciliation, existing clock/cancellation/return behavior, 120 Hz
bounds and front-tree identity. A new rendering regression starts a long flip,
freezes it before the back faces forward, leaves the target angle unchanged, and
checks that the old interpolation cannot mount the back. After resumption a new
flip must still show its back and retain the original front tree.

The final native suite executed 213 tests: 209 passed and four optional checks
were skipped. All 63 helper tests passed. Resting and live solid-flip captures
were inspected.

Build, native/helper tests, render captures, signing, packaged loopback, DMG
readback, installed-file preservation, commit/push and cleanup are recorded in
the delivery receipts. No notarization, real-TUN acceptance, or guarantee of
perfect system-transition frame pacing is claimed.
