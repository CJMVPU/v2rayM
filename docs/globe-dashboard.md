# Historical native map dashboard

As of 0.3.0, the homepage uses the [connection dashboard](connection-dashboard.md).
The map below describes the previous design; its resources and renderer are retained.

The previous homepage is native SwiftUI with an AppKit/Core Graphics flat Pacific map. It uses real status,
profile, traffic and Xray access-log data. It contains no demo traffic or fabricated
destinations. Window size remains 860 × 600.

## Interaction and data

- The map is centered on the Pacific so Shanghai and Los Angeles share a
  continuous viewport. The viewport is fixed and never responds to connection arrival/expiry. Natural
  Earth coastlines use a dark outline and subtle land stipple. The background is
  cached at the backing scale, so animation only redraws dots and city labels.
  Offscreen origins/nodes are labeled 视野外 at the edge; other offscreen targets
  use hollow dots on edge-bound paths and retain their identity in the recent-connections card. Bézier
  control points remain inside the plot so complete particle paths stay visible; no lines or trails are drawn.
  Wheel/pinch zoom is disabled. Reduce Motion removes particle animation;
  hidden/minimized windows stop playback.
- There is no bottom status strip. The map uses the full content height; the
  right-hand cards have equal 12-point gaps and outer vertical margins, with
  recent connections filling the remaining height.
- The local origin is explicitly configured in Settings → 地图展示 (Shanghai by
  default), not device geolocation. Select no local position to hide it.
- Server and destination hostnames use system DNS. Public IPv4/IPv6 addresses are
  looked up locally using DB-IP Lite. Private/FakeIP addresses and failed lookups
  remain unknown. DNS/CDN geolocation is approximate; arcs are logical connections,
  not physical routes. DNS requests are capped and locations cached for one hour.
- Recent connections come from Xray `accepted` log records, excluding DNS-port
  traffic. Up to five unique destinations/routes are visible; the renderer keeps
  at most eight recently observed destination particle paths for twenty seconds.
- Cyan and purple particles on the local–server path reflect aggregate proxy
  upload/download activity, not individual encrypted HTTP requests and responses.
- The speed card retains the backend's 5-second samples / 60-second average.
  Cumulative traffic is labeled 节点累计, since it is the node's stored
  lifetime total rather than a newly invented session total.
- Protocols/ALPN come from the selected/running profile. ALPN labels are configured
  preferences, not a claim about live negotiated HTTP. The next row displays the
  installed Xray core version.

## Rebuilding geographic resources

Imagery and attribution live in `macos/Native/Sources/V2rayM/Resources/Globe`.
Large generated range tables are excluded from Git. Before packaging, obtain the
official DB-IP City Lite CSV (CC BY 4.0) and compile the tables:

```sh
curl -fL https://download.db-ip.com/free/dbip-city-lite-2026-10.csv.gz -o /tmp/dbip-city-lite-2026-10.csv.gz
python3 scripts/prepare-globe-geo.py /tmp/dbip-city-lite-2026-10.csv.gz macos/Native/Sources/V2rayM/Resources/Globe
```

The converter validates sorted disjoint IPv4/IPv6 ranges and coordinate bounds.
It retains the original precision. Runtime range tables are mapped read-only;
there are no third-party geolocation API calls.

## Verification

`swift test --package-path macos/Native --disable-sandbox` covers log parsing,
range boundaries, private/FakeIP handling, peak expiry, and existing app logic.
An optional CPU render check reuses the actual map view without starting any
backend or proxy:

```sh
V2RAYM_RENDER_OUTPUT=/tmp/v2raym-globe.png swift test --package-path macos/Native --disable-sandbox --filter GlobeRenderingTests
```

The render check does not require Metal. Projection tests cover Shanghai/Los
Angeles, date-line continuity, polar targets and complete curve containment.
Desktop acceptance should additionally check the full window, card layout,
scroll suppression, offscreen playback and normal close/minimize behavior.
An offscreen map snapshot alone is not full desktop visual acceptance.

## 0.2.7 refinement

- Title bar remains 40 points high; existing text navigation and engraved wordmark
  are unchanged. Close/minimize are pale red/yellow recessed top-edge notches.
- Removed the standalone left status light and map hover tooltip.
- Recent connections have five fixed-height slots, no scroll view, and a 350 ms
  insertion/reorder transition (disabled for Reduce Motion).
- Dots use independent monotonic birth times, 3.6-second flights and smooth
  fade-in/fade-out. Status updates do not reset their phase. Rate zero, route
  eviction, expiry and disconnect stop emission while existing dots finish.
- Hidden windows pause rendering; resuming starts at the origin without catch-up.
  A bounded emitter/particle budget avoids unbounded rendering work.

## 0.2.9 refinement

- Title bar is 32 points high, with vertically centered close/minimize controls.
  Status symbols use equal-height slots to align their captions. Dashboard text
  uses the default LXGWWenKaiMono Medium font, including protocol/version and metrics.
- The cached ocean background adds a soft radial shade, faint 20-degree graticule
  and a quiet 太平洋 / PACIFIC OCEAN label. Land, endpoints and particle behavior
  are unchanged; no connection lines or extra endpoint labels were added.
