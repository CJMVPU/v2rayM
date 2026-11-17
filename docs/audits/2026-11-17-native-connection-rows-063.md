# v0.6.3: cached native turns and dashboard animation performance

Replace the seven connection slots' text fades with a dedicated AppKit /
Core Animation renderer. The user subsequently authorized native trend and other
animation refresh optimizations, preserving effects and layout. Disc/card solid geometry, lighting, rotation parameters,
the 120 Hz display-clock request, immediate minimization and visibility/return
quiet periods are preserved.

Each row rasterizes its rounded background, address and route label only when
needed. Three local face references and a shared 28-entry card LRU reuse identical
content across stable slots and connections moving between slots. Keys include
visible content, size and backing scale. Native turns reuse cached old/new
faces, with two thin edge planes and an explicit static shadow outline. There is no row display link, per-frame SwiftUI angle publication or
per-frame bitmap generation. Native views preserve the existing font, tooltips
and accessibility label.

A card-owned scheduler permits at most two turns, with independent initial jitter,
a 0.28–0.40 second start separation, approximately one-second turns and 2.0–2.8
seconds of per-row rest. Non-neighbouring slots are preferred, and overdue slots
receive priority to prevent starvation. A single sleeping scheduler task replaces
a timer per row; pending slots hold only their latest value, not a history queue.

The final user timing correction supersedes the earlier content-before-turn
request. The visible front retains its old text. The incoming bitmap is prepared
on the hidden back before animation, and becomes visible only as the turn exposes
that face. Completion switches to the identical cached incoming image; newer
arrivals are coalesced for a subsequent turn, not swapped visibly afterward. The
intermediate 50 ms pre-turn hold is removed. The recent-connections whole card
changes/clears its content while its branded back hides the content area; its
physical motion is unchanged. Other cards retain their existing timing.

Window-scoped early freeze captures native presentation transforms/opacities,
removes animations, invalidates completion tokens and releases scheduler slots.
Late data updates do not rasterize or restart turns. After the existing return
gate thaws, the latest face crossfades over the frozen surface; missed turns are
not replayed. Reduce Motion and dismantling cancel pending work.

## Direct native chart clock

After reviewing the interval/handler measurements, the user explicitly expanded
scope to optimize the chart refresh path. The window CADisplayLink now calls the
native plot directly with immutable animation inputs. It no longer publishes an
ObservableObject timestamp, rebuilds a SwiftUI view closure or crosses an
NSViewRepresentable update on every display tick. SwiftUI still handles actual
telemetry, layout, scale-target and lifecycle changes. Path/grid caches, sample
reveal, scale easing, bounded history catch-up, retirement fade, screen-aware
120 Hz requests and early freeze/thaw are preserved. A stale callback from an
invalidated display link is rejected by link identity and lifecycle state.

## Cached numeric transitions and hosted layers

Sampling the main thread identified SwiftUI numeric-content drawing and backing
store synchronization as a substantial cost. Enabling SwiftUI's GPU content
transition path reduced the tail but still waited for RenderBox surfaces, so the
final implementation uses cached native glyph layers instead. The existing
font, text measurement, alignment, 0.45-second rolling/fading/softening effect,
unchanged digits and accessibility labels are retained. Crisp and softened glyph
images are built once per character/style/backing scale and reused; Core Animation
handles opacity, translation and cached image transitions without application
per-frame text drawing. Style changes invalidate the cache. Freeze captures the
presentation surface, rejects stale updates, and thaw crossfades latest content
over the retained frozen digits. Reduce Motion cancels active transitions even
when the string did not change.

Native chart/ring/row/number views explicitly own their CALayer root (assign
`layer` before `wantsLayer`), avoiding AppKit's automatic view backing-store
redraw path. Disc/card solid geometry, nine side planes during turns, lighting,
shadow parameters and turn timing are unchanged. They still use the existing
SwiftUI solid effect, with no side/back planes while resting. The numeric change
removes an independently expensive refresh inside those surfaces.

The final release does not retain the intermediate SwiftUI GPU transition option.
Apple's API description used during diagnosis:
https://developer.apple.com/documentation/swiftui/environmentvalues/contenttransitionaddsdrawinggroup
Layer ownership reference:
https://developer.apple.com/documentation/appkit/nsview/wantslayer

## Verification

Evidence: `artifacts/reviews/2026-11-17-native-rows-063/`.

The full native suite executes 231 tests: 225 pass, six optional checks skip
(optional layout/geometry/geodata fixtures). The three numeric-renderer checks
also pass after the final Reduce Motion and restore adjustment.
All 63 helper tests pass. New checks cover identical-content cache reuse across
600 updates, shared reuse across slots, the two-turn cap and independent order,
latest-only coalescing, early freeze and stale-update rejection, smooth catch-up,
Reduce Motion/dismantling, hidden-face content replacement for native/whole-card turns, native chart
interpolation and stale-configuration rejection until thaw. Live captures check the row's thin 3D edge, the unchanged whole-card back,
and final pixels against a fresh rendering after rapid replacement.

## Performance method

Release offline fixtures compare committed 0.6.2 text fades against this renderer
using the same current dashboard, synthetic telemetry and every-second replacement
of all seven connections plus speed data. They never start a proxy or TUN.
Final fixtures launch as ordinary temporary app bundles through LaunchServices.
A retained valid 0.6.2 baseline interval lasts eight seconds; the final candidate
has two 20-second pressure intervals, each with a two-second warmup. Lifecycle
phases last eight seconds. Runs are sequential, not a randomized benchmark. Foreground phases reject failed activation, and records
include active/occluded/minimized/locked states. Unbundled pilots and the direct
bundle launch with failed activation are retained separately and excluded from
the final comparison. No build/test workload runs concurrently with measurement.

The row renderer has no independent per-frame application callback. Reported
callback intervals belong to the homepage's existing display clock. Baseline callback processing covers only timestamp publication, excluding
deferred SwiftUI layout. The final candidate callback includes the direct native
plot update. Neither includes WindowServer/GPU work; handler scopes are recorded
separately rather than presented as identical geometry benchmarks. A separate run-loop diagnostic samples wall
time from afterWaiting to beforeWaiting (last observer order) for loops with a
display tick; this is not a GPU duration or a CPU profiler sample.

The comparison includes the requested staggering, rest periods and coalescing:
it uses equal input load, not identical intermediate visual update cadence.
No single-application GPU percentage or WindowServer presentation-FPS conclusion
is inferred. Build/signing, packaged loopback, read-only DMG verification,
installed-file preservation and cleanup are separate delivery receipts. The
installer is not installed, remote CI is not awaited, and real TUN/notarization
are not claimed.

## Results and acceptance

Acceptance is **main-thread processing interval P95 < 5 ms and P99 < 7 ms**.
It is not the 120 Hz display interval (nominally 8.33 ms), handler duration alone,
or GPU execution time. `acceptance.json` records both passing scenarios.

| Release fixture | Envelopes | P95 ms | P99 ms | CPU % of one core |
| --- | ---: | ---: | ---: | ---: |
| 0.6.2 fades, pressure baseline | 953 | 9.170 | 14.339 | 41.77 |
| 0.6.3 native rows/trend/numbers, pressure | 4,831 | 0.309 | 0.371 | 5.49 |
| 0.6.3 repeated disc/card activation and closing | 2,419 | 4.282 | 5.181 | 28.77 |

The last scenario uses an independent 120 Hz diagnostic tick to mark active
run-loop intervals even after closing stops the plot's own clock. Twenty seconds
include repeated four-second on/off periods. Thus closing animation is not
accidentally excluded by counting only active plot callbacks.

The pressure run records 192 numeric transitions and at most two simultaneous
row turns, with 77 row bitmap builds over approximately 40 seconds (mean 0.645 ms,
P99 1.058 ms). The chart callback itself has P95 0.256 ms / P99 0.289 ms; callback
spacing averages 8.355 ms with 119.64 callbacks/second. Hidden refresh records
zero callbacks, row starts and bitmap builds, approximately 0.70% of one CPU core.
The restored phase remains below both main-thread percentile targets.

Percentiles are not a maximum guarantee: the pressure maximum is 11.67 ms and
the repeated-mode maximum is 22.53 ms. The short offline measurements cannot
promise zero hitches under all system load or represent WindowServer's presented
frame rate. The Dock fixture did not report `isMiniaturized`, so its numbers are
not claimed as real minimization/Stage Manager transition verification. Unit
checks cover early freeze and thaw; no live proxy or TUN was exercised. No
application-exclusive GPU utilization percentage was measured. Evidence retains
intermediate results and samples, including a profiled steady phase that is
excluded from the final pressure comparison.
