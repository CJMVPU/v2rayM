# v0.5.9: 500 ms pre-minimize interval

The application's custom minimize button now freezes rendering, asynchronously
waits 500 ms, then calls AppKit's `miniaturize`. The previous configured interval
was 180 ms; the 196 ms in the v0.5.8 report was a measured interval including
scheduling and trace overhead. The new setting is a 500 ms minimum task delay,
not a promise of an exactly 500 ms wall-clock gap or a GPU-idle fence.

The existing synchronous preparation latch, duplicate-click coalescing,
cancellation, visibility recheck and handoff to the AppKit minimizing latch are
unchanged. Return stability, smooth data/history catch-up, 120 Hz preference and
solid flips are also unchanged.

## Stage Manager limitation

The requested 500 ms delay before a user-initiated Stage Manager transition is
not implemented. The app does not initiate that system-owned transition. AppKit's
`willResignActiveNotification` reports impending loss of activation;
`applicationWillResignActive` has no deferral result or completion handler.
The documented Stage Manager collection behaviors express window roles, not a
permission to defer a user's switch. We found no supported public API that lets
this app delay that transition by 500 ms.

Stage Manager therefore retains immediate synchronous freezing on the earliest
available will-resign event, without sleeping the main thread, delaying the freeze
itself, stealing activation back, or changing system-wide animation preferences.
It is not represented as a 500 ms system-transition delay.

Sources checked for this request:
- [AppKit willResignActiveNotification](https://developer.apple.com/documentation/appkit/nsapplication/willresignactivenotification)
- [AppKit applicationWillResignActive](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationwillresignactive(_:))
- [Stage Manager collection behaviors](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)

## Verification and delivery

Evidence directory: `artifacts/reviews/2026-11-17-minimize-059/`.

The existing minimize lifecycle test now uses the production default delay. It
checks synchronous display-clock freezing, a still-responsive main actor with no
minimize at 300 ms, a single callback no earlier than 500 ms, and handoff to the
AppKit minimizing latch. Related tests cover cancellation and window visibility,
Stage Manager inactivity, return stability, rendering isolation and 120 Hz bounds.
Helper checks, product boundaries, signing, packaged loopback, DMG readback and
preservation of the installed app are recorded separately in the release receipts.

No new compositor-FPS, GPU-occupancy or actual Dock/Stage Manager animation-timing
measurement is claimed. Delivery follows the existing request for a version bump,
local installer without replacing the installed app, commit/push and old-build
cleanup, without waiting for remote CI. The package is not notarized.
