# Native connection dashboard

The fixed 860 × 600 homepage uses a native circular connection display and a
92-point traffic trend below it. The right-hand status, traffic and recent
connection cards retain their existing data sources. No new connect button is
introduced; system proxy and TUN controls remain mutually exclusive in the title
bar. The app and native window enforce dark Aqua appearance. The dashboard uses fixed
dark background/panel colors; system light appearance does not select a light theme.

## Ring and geometry

- The inner cyan/purple pair represents proxy upload/download; the outer
  green/orange pair represents direct upload/download. All four use the existing one-minute average,
  not packet events, capacity, health, progress percentages or loss estimates.
- Each ring fills clockwise from the bottom, relative to that direction’s
  highest sample in the last 60 seconds. Zero, missing or inactive rates leave
  only the track. Changes ease over 1.2 seconds. Reduce Motion, window occlusion, minimization
  and closure pause animation. The central status preserves offline, recovery,
  updating, stale, faulted and local-core distinctions.
- The disc and all four rings share the horizontal and vertical center of the
  gauge area above the traffic trend. Vertical position uses the actual gauge
  height, with no accumulated offsets. The four badges and trend retain their
  positions; the redundant current-connection heading is omitted. Hover slightly enlarges and tilts the disc inside its fixed hit region. The node and recent-connection cards use the same depth effect. Hover is tested against the inset disc radius,
  excluding ring tracks and square bounding-box corners. Gauge tooltips and the
  Settings home-display explanation section are removed. Source attribution
  remains bundled in Resources/Globe/ATTRIBUTION.txt.
  Diameter is bounded by both width and the space remaining above the trend.
  Protocol and mode labels surround the circle; latency is explicitly the last
  node test, not a live path measurement.
- Close/minimize controls are 16-point gray circles (the small title-bar switch
  thumb height). Hover reveals red/close or yellow/minimize. The hit region is
  24 points; drawing and hover never change layout. Normal close-to-menu-bar and
  minimize actions are retained.

## Trend data

`TrafficTrend` records distinct backend `sampledAt` timestamps from coherent
status refreshes, retaining at most 1024 samples and five minutes of history.
The backend publishes approximately every five seconds; plotted rates are the
one-minute rolling averages already used by the speed card, in KiB/s.

Duplicate/out-of-order timestamps are ignored. Missing, stale, invalid,
disabled and stopped samples do not become synthetic zeroes. Interruptions and
gaps of 12 seconds or more break the line. A different running profile or core
start timestamp starts a new line segment while preserving recent history;
switching UI pages also preserves history. Stopping or disabling statistics
freezes the chart clock. When sampling resumes, the five-minute window expires old points. On return from the background,
the last displayed viewport blends directly to the current one over 0.45 seconds.
Expired samples are excluded from live peaks. Reduce Motion presents the current viewport directly. All four lines share one hidden axis; scale is determined from the five-minute
observed samples with headroom. The title, sampling description, peak and four direction legends share one baseline.
The header displays the largest individual
proxy/direct upload/download sample over the last minute, without axis headroom. The chart
uses its full width, seven horizontal grid lines and no endpoint captions.
A visible 60 fps timeline scrolls the chart continuously; new endpoints and
scale changes ease over 1.2 seconds. Bounded cubic segments smooth the curve
without overshoot or bridging missing data. A single sample is a dot,
not an invented line across the chart.

## Traffic card and import

The speed card uses inline arrow/value pairs: proxy upload/download on the first
row and direct upload/download on the second, using the same four colors as the
rings and chart. Tooltips and accessibility labels name each route and direction.
Direct counts cover Xray's direct outbound only, excluding traffic bypassing Xray.
Node cumulative upload/download remain proxy-only. Every metric uses fixed icon,
right-aligned number and right-aligned unit columns, a shared 14-point font and
one decimal place. Numeric values and duration digits animate smoothly without
changing column widths.
Import is available on the Nodes page; the redundant title-bar import icon is removed.

## Recent connections

The card shows up to seven records without a heading in evenly spaced rows, with a continuous
route-colored background from the host to its route label: cyan for proxy,
green for direct and orange for blocked connections. All card insets are twelve
points, centering the displayed rows. Long hosts truncate in the middle while the route label remains visible;
hover retains the complete destination and estimated location. Empty-state
messages, record ordering and Reduce Motion behavior are unchanged.

## Location and historical map

The selected node can use system DNS to look up its city. Recent connections use the
IP already present in the access record and the offline city database. A domain-only
destination keeps its name with an unknown location. Viewing these records issues
no DNS queries. The location database maps IPv4 and IPv6 change points and an
indexed places.bin table. A gap marker represents uncovered addresses. Both the
source attribution and the original location coordinates are retained.
Regenerate missing geographic resources with `python3 scripts/prepare-macos-geo.py`;
verify fixed input/output digests with `--verify-only`. Retired map designs remain in Git history.

## Verification

Run the product-boundary guard before builds. Swift tests cover duplicate and
out-of-order sampling, stale/disabled/stopped input, interruption boundaries,
profile/restart transitions, capacity and expiry. Inspect full-window and
active-state offline renders for typography, equal circle margins and empty
trend behavior. Run the packaged loopback smoke check before installation.
Signing, installation and any real-network acceptance are recorded separately.

## Motion

A page turn captures the clicked face before locking hover and mounting the destination. The busy cursor stays active during preparation. The two faces rotate together once the destination is ready. Reduce Motion switches pages directly.

On a stopped-to-running core transition, the central disc and recent-connections
card turn out to an edge and back in, without mirrored text. The outer rings stay
in place. The disc clock uses numeric text transitions. A running core awaiting
its first valid sample shows four small colored starting dots at the plot edge;
these are presentation placeholders, never inserted into traffic history.

Recent records use up to seven stable row slots. Changed host/route identities flip
vertically, swapping text at the edge; location-only updates do not trigger a
flip. A newer identity cancels an in-flight swap. Empty and partial groups remain
centered. Reduce Motion suppresses these turns and numeric transitions.

Live motion captures use the window compositor because NSHostingView bitmap
caching does not correctly composite intermediate 3D transforms. The motion
regression also compares settled rows after rapid replacement with a fresh
rendering of the latest records.
