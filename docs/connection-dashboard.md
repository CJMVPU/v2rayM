# Native connection dashboard (0.3.0)

The fixed 860 × 600 homepage uses a native circular connection display and a
92-point traffic trend below it. The right-hand status, traffic and recent
connection cards retain their existing data sources. No new connect button is
introduced; system proxy and TUN controls remain mutually exclusive in the title
bar. The background uses the same `NSColor.controlBackgroundColor` as Settings.

## Ring and geometry

- The cyan outer arc represents proxy upload activity; the purple inner arc
  represents proxy download activity. Both use the existing one-minute average,
  not packet events, capacity, health, progress percentages or loss estimates.
- Each ring fills clockwise from the bottom, relative to that direction’s
  highest sample in the last 60 seconds. Zero, missing or inactive rates leave
  only the track. Changes ease over 1.2 seconds. Reduce Motion, window occlusion, minimization
  and closure pause animation. The central status preserves offline, recovery,
  updating, stale, faulted and local-core distinctions.
- The circle is centered horizontally and shifted upward by 10 points; the
  redundant current-connection heading is omitted.
  Diameter is bounded by both width and the space remaining above the trend.
  Protocol and mode labels surround the circle; latency is explicitly the last
  node test, not a live path measurement.
- Close/minimize controls are 16-point gray circles (the small title-bar switch
  thumb height). Hover reveals red/close or yellow/minimize. The hit region is
  24 points; drawing and hover never change layout. Normal close-to-menu-bar and
  minimize actions are retained.

## Trend data

`TrafficTrend` records distinct backend `sampledAt` timestamps from coherent
status refreshes, retaining at most 61 samples and five minutes of history.
The backend publishes approximately every five seconds; plotted rates are the
one-minute rolling averages already used by the speed card, in KiB/s.

Duplicate/out-of-order timestamps are ignored. Missing, stale, invalid,
disabled and stopped samples do not become synthetic zeroes. Interruptions and
gaps of 12 seconds or more break the line. A different running profile or core
start timestamp resets history; switching UI pages does not. Expired points are
filtered even when refreshes stop. Both lines share one hidden axis; scale is determined from the five-minute
observed samples with headroom. The header displays the actual combined
upload/download peak over the last minute, without axis headroom. The chart
uses its full width, seven horizontal grid lines and no endpoint captions.
A visible 60 fps timeline scrolls the chart continuously; new endpoints and
scale changes ease over 1.2 seconds. Bounded cubic segments smooth the curve
without overshoot or bridging missing data. A single sample is a dot,
not an invented line across the chart.

## Location and historical map

The node city and recent-connection location details still use system DNS and
the offline IP database. Unknown locations remain unknown. The previous map
renderer/resources and the saved origin preference are retained, but the
homepage and Settings no longer advertise a map or origin picker.
See `globe-dashboard.md` for the historical map design.

## Verification

Run the product-boundary guard before builds. Swift tests cover duplicate and
out-of-order sampling, stale/disabled/stopped input, interruption boundaries,
profile/restart transitions, capacity and expiry. Inspect full-window and
active-state offline renders for typography, equal circle margins and empty
trend behavior. Run the packaged loopback smoke check before installation.
Signing, installation and any real-network acceptance are recorded separately.
