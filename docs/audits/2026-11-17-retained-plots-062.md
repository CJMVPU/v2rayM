# v0.6.2: immediate minimization and retained dashboard graphics

Remove the 500 ms minimize preparation task. The custom title-bar button now
posts the synchronous freeze notification and immediately calls AppKit in the
same event turn. The preparation latch remains until AppKit returns, so its
will-miniaturize notification can take over. Reentrant clicks are ignored;
synchronous cancellation or hiding still prevents the action. This removes an
application delay, not macOS's own transition duration. The existing return
quiet period, smooth data catch-up and foreground 120 Hz preference remain.

The four rings now retain full-circle CAShapeLayer paths. Bounds changes rebuild
the circle; rates only retarget strokeEnd with a 1.2-second animation starting at
the presentation value. Window freeze captures that value and removes the native
animation immediately. Stale updates remain blocked until the window's thaw
notification; the next update eases from the frozen value to current data.

The chart uses retained native layers instead of a per-frame Canvas paint pass:

- Static grid paths change only with bounds.
- Data-space history paths change only when the sample set changes. Equal data
  publications preserve geometry; steady frames translate the layer container.
- The newest connected segment is separate, so endpoint reveal changes only four
  small curves. Vertical scale changes project cached paths with Core Graphics;
  they do not rebuild curves by walking samples in Swift. Stroke width and dot
  diameter remain constant rather than stretching with the vertical scale.
- Recovery reuses the bounded merged history and moves it through the viewport.
  Session boundaries and gaps of at least 12 seconds still break curves. Long
  absences use coarse, bounded time buckets with connected edge neighbours to
  avoid enormous offscreen path bounds; an empty gap stays empty.
- Retiring history is a separate temporary layer group. Its geometry is reused
  during the existing fade and cleared afterward.

The native views have no timers, polling or extra display links. Window-scoped
freeze notifications block late frame updates. Disc/card solid flips, connection
text fades, data collection, node totals and the backend are unchanged.

## Verification and interpretation

Evidence: `artifacts/reviews/2026-11-17-chart-cache-062/`.

The native suite executes 219 tests: 214 pass, five optional checks are skipped.
The geometry benchmark is separately enabled in Release mode (all seven layer tests pass). All 63 helper tests
pass. Dashboard and live-window screenshots preserve the four rings, chart,
card layout and connection rows; the left-edge render regression passes.
New tests cover immediate freeze/call ordering, reentrancy/cancellation,
steady-path reuse, endpoint reveal, equal publications, session/gap boundaries,
constant line/dot size, endpoint projection, and native-ring freeze/thaw.

In a 600-frame steady-scroll check at simulated 120 Hz, the grid, historical
geometry, projection and endpoint path each build once. Revealing the endpoint
does not rebuild/project history. Changing the vertical scale does not rebuild
data-space geometry. A frozen chart rejects subsequent position updates.

A CPU microbenchmark alternates old/new implementations over seven rounds,
1,200 frames per round, 61 samples and four series. Median times:

| Computation | Previous | Retained layers |
| --- | ---: | ---: |
| Latest-segment reveal | 13.427 ms | 1.207 ms |
| Vertical rescaling | 13.577 ms | 5.060 ms |

These are total geometry/property-update times for 1,200 simulated frames,
not per-frame milliseconds. The absolute savings per frame are microseconds.
The benchmark excludes actual GPU execution, WindowServer composition, SwiftUI
layout and screen presentation. Old steady mode already cached geometry; its
empty geometry loop is not an end-to-end comparison to the new property updates.
No GPU utilization percentage, real 120 FPS, or complete Stage Manager stutter
resolution is inferred. Reusing application paths also does not mean macOS never
rasterizes or composites those layers again.

Build/signing, packaged Xray loopback, read-only DMG readback, installed-file
preservation and cleanup are separate delivery records. The requested installer
is not installed. Remote CI is not awaited; no real TUN test or notarization
claim is made.
