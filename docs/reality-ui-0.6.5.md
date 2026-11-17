# RealityKit window presentation — 0.6.5

The application now has one RealityKit scene per window. It owns the window surface, custom title bar, window-control surfaces, navigation models, switches, buttons, panels, node rows, dashboard solids, rings, trend ribbons and recent-connection faces. SwiftUI and AppKit continue to own the NSWindow, layout, text, editable fields, IME, keyboard focus, selection, accessibility and actions. This is a native macOS application with an integrated RealityKit presentation layer; it does not replace macOS window management with a 3D engine.

## Scene and interaction

- A point-aligned orthographic camera maps native layout into the scene. Layout anchors synchronize after native layout and follow scroll clipping. The renderer never intercepts input or performs networking.
- Surfaces retain their entities and reuse unchanged geometry. Cards have actual side faces; nested recent-connection entities follow their parent card's transform.
- The existing readiness, admission, cancellation and bounded two-row scheduling rules remain. Recent connection text uses bounded cached textures, now attached to RealityKit solids.
- Trend data-space curves remain cached; clipped vector ribbons are rendered by RealityKit. Text and rolling numeric glyphs retain native rendering for legibility and accessibility.
- Native field editing, secure fields, validation, unsaved-change confirmation, proxy/TUN command paths and helper authorization are unchanged. Node columns retain their names, order and widths; selection, keyboard movement, double-click activation and context actions remain available.
- Hidden controls explicitly hide their scene entities. Disabled controls remain inert and do not gain hover effects.
- Window suspension cancels navigation animation, stops scene animation, and retains a snapshot while removing the live render view after snapshot completion. A generation check rejects stale snapshot callbacks after resume. Dashboard data admission and the existing early minimize gate remain in place.

## Navigation assets

`Resources/Navigation` contains four authored `.reality` assets: a gabled house with walls and chimney, a spatial graph with spheres and steel rods, a book with a page block and raised log lines, and a beveled gear with a through-hole. The models use multiple materials and an oblique resting pose. They have no colored tab plate or outline.

Mouse entry and newly selected pages request a full turn. Three sub-180-degree RealityKit transform animations preserve a complete rotation instead of collapsing a 360-degree quaternion to the identity. Hover followed by selection coalesces into the active turn. Disabled controls, Reduce Motion, disappearance and window suspension cancel or suppress turns.

To regenerate assets on macOS 15 or later with Xcode:

```sh
xcrun swiftc -parse-as-library -target arm64-apple-macos15.0 \
  macos/Native/Sources/V2rayM/RealityNavigationAssets.swift \
  scripts/generate-navigation-assets.swift -o /tmp/v2raym-generate-navigation
/tmp/v2raym-generate-navigation macos/Native/Sources/V2rayM/Resources/Navigation
```

Asset loading is cached and cloned per scene. Missing assets are a packaging error, not a fallback to flat icons. The export tool reloads each file and checks nonzero volume. These assets are original repository content, not downloaded third-party models.

## Validation and delivery boundaries

- Native suite: 238 tests, 230 passed, 8 opt-in checks skipped, no failures. The full-window GPU rendering test was enabled for home, nodes, logs and settings.
- Backend suite: 194 passed. Helper suite: 63 passed.
- Offline motion capture additionally covers activation, card turn, rapidly replaced rows and stopping. The bounded latest-value and cancellation tests continue to cover row scheduling.
- Interaction tests send mouse events through the RealityKit-backed window to native buttons, switches and fields, including disabled behavior and Chinese text insertion.
- Geometry tests cover clipping, point mapping, mesh reuse, asset volume, full-turn coalescing and animation cancellation. GPU captures include the four asset models at an enlarged scale.
- Product boundaries, DDD dependencies and the generated helper contract were checked. No engine, helper policy or network configuration change is part of this refactor.

Build/signature, packaged loopback smoke, read-only DMG verification, installed-app preservation and cleanup receipts are recorded separately under `artifacts/reviews/2026-11-17-reality-065/`. The deliverable is a local development-signed package; no notarization or real TUN acceptance is claimed. Sustained GPU power consumption and a complete performance comparison against 0.6.4 have not been measured.
