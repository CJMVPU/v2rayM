# Dashboard numeric cache — 0.6.4

A previously unseen digit could synchronously spend approximately 11–12 ms creating its soft-focus images through Core Image. Small cached glyph bitmaps now use Accelerate vImage separable Gaussian convolution, avoiding the Metal render/texture-readback path for this work. Crisp text, the three blur levels, animation duration, glyph reuse, layout and visibility handling are unchanged.

This release retains the 0.6.3 disc/card/row animation implementations, the 120 Hz request, and freeze/resume behavior. Experimental container, geometry, row-retention, warmup and update-scheduling changes were not adopted. The requested maximum below 7 ms was not achieved; further optimization was stopped at the user's request.

## Validation

- Product boundary guard passed.
- Native suite: 232 tests, 224 passed, 8 opt-in checks skipped, no failures.
- Helper suite: 63 passed, no failures.
- New Gaussian parity test covers 14/24 pt glyphs at 2× and all three blur radii. Maximum alpha difference against the previous Core Image rendering is 0.01569; maximum mean alpha difference is 0.000616.
- Separate offline full-dashboard mode-switch probe: 120 Hz diagnostic display link, 24 seconds, changing rates and seven recent connections. This measures the main-run-loop wall-clock processing envelope, not just the display-link handler.

| Build / run | P95 | P99 | Maximum |
| --- | ---: | ---: | ---: |
| 0.6.3 baseline | 4.173 ms | 4.958 ms | 20.227 ms |
| Early vector-blur validation | 4.177 ms | 5.148 ms | 8.223 ms |
| Final shipping-source validation | 4.251 ms | 5.378 ms | 17.364 ms |

The final run contains 2,900 samples with the application foreground and the screen unlocked. Its largest interval includes only 5.029 ms of thread CPU time; separate intervals still exceed 7 ms of actual CPU work. Run-to-run changes include system waits and scheduling, so these observations do not establish a global maximum or an overall percentile speedup. They meet the earlier P95 <5 ms / P99 <7 ms criteria in this run. GPU utilization and real Stage Manager/minimize transition frame rates were not measured.

Local evidence: `artifacts/reviews/2026-11-17-frame-max-064/` (performance-summary.json, shipping-validation/measurements.json, native-tests.log, helper-tests.log). Product build, signature, packaged loopback smoke, read-only DMG verification and installation-preservation results are recorded separately in the delivery receipts. The package is not a notarized release and is not installed over the existing application.
