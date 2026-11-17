# v0.6.1: fade recent-connection text instead of flipping rows

The seven recent-connection slots now render their latest values directly. Only
changed address or route text uses a 0.4-second ease-in/out opacity content
transition. The rounded row backgrounds keep their geometry and opacity; they
are outside the animated text subtrees. An unchanged route label does not animate
just because its address changes. Reduce Motion or a suspended dashboard selects
an identity content transition with no animation.

Remove the row flip wrapper, pending/incoming/displayed value copies, delayed
workers, minimum-rest/stagger logic and row-specific solid renderer geometry.
Rapid updates therefore retarget text immediately instead of queuing old records
behind a turn. Stable slot identities and the existing frozen dashboard snapshot
and smooth catch-up remain in use.

The recent-connections card's whole-card opening/closing flip remains, as do the
other cards and the disc. Their original rotation axes, thickness,
perspective, lighting, shadow and timing values are preserved when deleting the
unused vertical row branch. The foreground 120 Hz preference, 500 ms minimize
preparation, visibility gates, rings and traffic-history rendering are unchanged.

## Verification

Evidence: `artifacts/reviews/2026-11-17-text-fade-061/`.

The existing live motion capture now takes a mid-fade row image, replaces the
records again during the fade, and compares the settled visible rows against a
fresh view of the latest records while the proxy fixture is still active. This
moves the pixel comparison before shutdown so it actually checks the latest
connections rather than two empty stopped cards. Closing-card snapshots are still
captured afterward. The obsolete row-flip stagger test is removed with its code.
Existing freeze/resume, render identity, card lifecycle and 120 Hz tests remain.

The native suite executed 212 tests: 208 passed and four optional checks were
skipped. All 63 helper tests passed. The mid-fade capture was visually inspected.

Build, signing, packaged loopback, DMG readback, installed-file preservation and
cleanup are recorded separately. Delivery follows the existing request to build
an installer without replacing the installed app, commit/push and clean old build
outputs without waiting for remote CI. No new GPU-utilization, compositor-FPS or
real-network/TUN acceptance result is claimed.
