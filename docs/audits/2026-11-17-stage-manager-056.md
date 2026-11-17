# v0.5.6 Stage Manager presentation lifecycle

The macOS 27.3 / 120 Hz desktop reproduction showed that a Stage Manager thumbnail
can retain `NSWindow.occlusionState.visible` and `isOnActiveSpace == true` while
its application is inactive. The old occlusion-only gate did not pause this
case. In this specific reproduction the home was not being removed; earlier
suspicions about subtree removal during the transition were not the measured
cause. The old thumbnail continued scheduling chart frames and row flips.

The home now retains its view identity and a value snapshot throughout visibility
changes. A shared coordinator observes application activity as well as window
occlusion, hide/minimize, lock, sleep and session events. Losing the foreground
or becoming occluded freezes incoming presentation data and allows a one-second
quiet interval before stopping display ticks and settling pending flips. This
also applies to inactive windows outside Stage Manager. Hard visibility blockers
pause immediately. Backend collection and network operation are unaffected.

On return, keep the previous surface for 0.65 seconds, then catch up to the latest
snapshot over 0.45 seconds using numeric, ring and connection-content transitions.
Suppress catch-up flips so intermediate background records and start/stop events
are not replayed. Rapid direction changes cancel pending pause/resume tasks.
The intervals are conservative application-side grace periods, not a claim to
receive an OS transition-completion callback. The independent inner occlusion
watcher and whole-home conditional removal were removed. A single presentation
source disconnects subscriptions and its one-second timer while paused. Value
equality prevents unrelated parent observations from rebuilding the frozen home.
Existing physical surfaces, independent row cadence, shadows, dark styling and
preferred/maximum 120 Hz request remain.

## Validation

Evidence is under `artifacts/reviews/2026-11-17-stage-056/` (ignored local artifacts).
Native tests: 198 executed, 194 passed and four existing optional checks skipped;
helper tests: 63 passed. Regression coverage includes visible-but-inactive Stage
Manager state, delayed pause, rapid return cancellation, hard blockers interrupting
resume, background snapshot isolation beyond the timer interval, latest-data
restoration, 120 Hz range selection and solid-surface identity. Live compositor
captures retain the solid card and row flip appearance.

The release-mode paired probe uses synthetic rates and seven replacement rows
per second, with actual baseline 0.5.5 and candidate UI sources. It starts no
proxy, helper or TUN. Two disposable test applications cooperate using AppKit's
public yield/activate interfaces, so the test produces actual Stage Manager
thumbnail/foreground changes rather than simulating an occlusion flag. See
[Apple's activation contract](https://developer.apple.com/documentation/appkit/nsapplication/activate()).
Both test processes report application activity, window occlusion, display-link
callbacks and CPU time; candidate traces additionally record presentation phase,
snapshot publication and content mount/unmount. Desktop inspection confirmed the
complete retained thumbnail. Three normal leave/return cycles and three rapid
0.35-second cycles completed. Candidate content appeared once and never disappeared
through the run. Each sustained suspension had zero snapshot updates and zero
steady display callbacks. Rapid reversals never reached a stale suspended phase.
Return traces show roughly 0.65 seconds of retained content followed by catch-up
and live rendering. `stage-results.json` preserves raw timing and measurements.

Excluding three seconds after each phase change, old inactive thumbnails consumed
24.2–27.5% of one CPU core and issued 65–70 display callbacks/second. Candidate
inactive thumbnails consumed 0.91–1.34% and issued zero. These are paired desktop
probe observations including sampling overhead, not an app-exclusive GPU result
or a compositor dropped-frame measurement. Foreground measurements have the other
version running in the background and must not be treated as an isolated foreground
FPS comparison. Requesting 120 Hz does not guarantee actual 120 FPS.

Product signing, packaged loopback, mounted installer readback, unchanged-installed-
app hashes, Git push and cleanup have separate receipts. No real TUN acceptance,
notarization, installation or remote CI completion is claimed. The user authorized
a version bump, a local installer without replacement, commit/push and cleanup.
