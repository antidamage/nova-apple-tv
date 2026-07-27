# Nova Apple TV Dashboard

Native tvOS client for the local Nova Home Assistant dashboard.

> **Full engineering reference: [`SPEC.md`](SPEC.md).** It scopes the entire app —
> architecture, source map, API contract, theming, the focus/navigation model,
> every zone surface, the status-orb subsystem, the camera/background renderers,
> and the invariants that must not regress. This README is the operator-facing UX
> contract and build notes.

The Apple TV app is intentionally a thin client. It does not host the dashboard, talk directly to Home Assistant, or keep state while the Apple TV is asleep. It reads the existing Nova dashboard API at the conventional `http://nova.local` mDNS name and sends zone actions back to `/api/zone`. Household-specific fallback addresses stay in private build configuration, never in the repository.

## UX Contract

The Apple TV UI follows a focus-first tvOS model. Directional swipes move focus predictably, select expands or confirms, and edit controls capture remote input until confirmed or cancelled. The layout should feel like a PS4/PS5-style dashboard: a tight horizontal band of cards that expands vertically only when the active item needs to show more information.

### Zone Structure

The major ribbon is:

```text
Lighting | Climate | Outside | Network
```

Lighting expands into:

```text
Home | <room zones supplied by the dashboard>
```

`Home` controls every light. Its child zones follow the dashboard's configured
room order and control their own lights. Outside owns outside on/off, weather,
and a live exterior camera feed. Climate owns climate devices. Network is a
major zone, not a Home child.

### Focus And Expansion

- Cards start as titles only.
- Select on a collapsed major or sub-zone expands it.
- Select on an expanded major or sub-zone collapses it.
- Down from an expanded title enters the first child/control.
- Up from controls returns to the owning title.
- Left/right within a row moves one item at a time.
- Left/right from an expanded title collapses before moving to a sibling.
- Moving out of an expanded hierarchy may auto-collapse only after focus has actually left that hierarchy.
- Edge exits require two gestures: the first collapse, the second move away.
- The control area is a vertical `ScrollView`; every focusable control carries a scroll id (`dashboardFocus(_:equals:)`) and `ScrollViewReader.scrollTo(focus, anchor: .center)` runs on every focus change. This guarantees the focused control is always fully on screen while travelling through a surface — e.g. swiping down from the air conditioner into the panel heater scrolls the heater into view rather than focusing it off-screen.

### Remote Movement Tuning

- Normal navigation accepts one move every `260ms`.
- Repeated same-direction navigation accepts every `220ms`.
- Edit controls accept moves every `110ms`.
- Opposite-direction flicks inside `100ms` are ignored to reduce accidental bounce.
- Focus should never collapse a parent merely because focus moved to a child/control inside that parent.

### Lighting Controls

- Lighting zones currently expose only the preset action row: ON, CANDLE/DAY, WHITE, OFF.
- The colour selector (hue grid) and intensity (brightness) slider are intentionally removed pending a rework — they never worked reliably. `RemoteHueGrid` / `RemoteLinearSlider` remain defined but unused, and `lightingFocusRows` no longer emits `.hue`/`.brightness` rows. Restore them here when the feature is reworked.

### Outside Camera

- The Outside zone shows an always-live inline preview of the exterior S-Video capture (ambient feed for the wall display), played through a bare `AVPlayerLayer` (`CameraFeedView.swift`), muted, self-healing on stalls/failures.
- Source is the dashboard host's rolling-window HLS playlist at `GET /api/camera/outside/index.m3u8`; `GET /api/camera/outside/status` drives the LIVE/OFFLINE chrome and the source label (LIVE FEED vs PLACEHOLDER when the host is serving the synthetic clock).
- The camera is a **focusable tile** in the Outside focus graph (its own row, `.action(zone.id, "camera-outside")`, below the outside-power button), so you swipe down past the passive weather panel to reach it. The inline preview is height-capped (250pt) so the whole tile is fully revealed by scroll-to-focus when focused.
- **Select opens the canonical tvOS full-screen player** (`CameraFullScreenPlayer` → `AVPlayerViewController`) with native play/pause, DVR scrub across the rolling window, skip, and a LIVE indicator — the platform's own transport, driven by the Siri remote. The inline preview is deliberately a bare layer (not AVKit's `VideoPlayer`) so its transport controls never fight the dashboard's custom focus model; full transport lives in the full-screen player instead.
- The full-screen player is hosted by the **root** view and its presented camera id lives on `DashboardStore.fullScreenCameraID` — not on the tile — because presenting the cover sends the dashboard's `@FocusState` to `nil`, and the focus-left-the-zone logic would otherwise collapse the Outside zone, unmount the tile, and dismiss the cover the instant it opened. Two guards make this bulletproof: `collapseIfFocusLeftExpandedArea` ignores a `nil` focus (transient modal focus loss), and `handleExit` dismisses only the player (clearing `fullScreenCameraID`) when it is up, so Menu/Back never falls through to collapse the underlying zone.

### Modal Editing

- Temperature controls follow the web dashboard: visible minus/plus controls, current/target readouts, and immediate stepper actions. Do not replace these with a generic slider unless the web dashboard changes first.
- Fan speed uses a dot-line style control matching the web dashboard concept; while editing, swipes adjust the selected step and select commits.

### Visual Rules

- Shared dashboard theme is the only color source.
- The UI is mostly black/dark grey and monotone aside from theme accent and highlight colors.
- Do not add new ad hoc colors.
- Do not allow default white tvOS focus boxes/rings anywhere in the app.
- Focused controls use the shared highlight fill/outline.
- Expanded or active controls use the shared accent fill/outline.
- Idle controls use the shared border color.
- The Nova activity/avatar widget remains top-center. Its arcs circle the avatar, smoothly change direction, and size from load.
- The status orb's draw stack is module-driven and rendered by native Metal (`MetalOrbView.swift` + `OrbShader.metal`). It interprets the declarative status-orb documents shared with the web dashboard, including module settings, turbulent rings, all four blend modes, liquid-glass theme controls and the voice-glow colour slot. `NovaAvatarOrb` fetches `GET /api/orb-modules` from the dashboard host (5-minute poll), ships the same built-ins (`classic`, `reactor`, `halo`, `cross`) as offline fallbacks, and resolves the shared theme's `avatar.orbModule` with classic as the universal fallback. Run `node --experimental-strip-types scripts/sync-orb-builtins.mjs` when the web built-ins change.
- `VoiceSpeechStore` consumes the dashboard's `/api/events` stream. Speech start/end events centre and enlarge the orb and drive its alert layers with the same consonant envelope used by the browser dashboards.
- The resting clock uses the shared clock colour slots and the dashboard layout: local time with seconds and meridiem, a location chip derived from the Apple TV time zone, an ordinal long date, and a Monday-to-Sunday strip highlighting the current day.

### Climate Parity

Match the web dashboard controls in `nova-ha-dashboard/app/components/dashboard/ClimateControls.tsx`:

- Air conditioner power states: Auto, Manual, Off.
- Modes: Heating, Cooling, Fan.
- Fresh air switch: Recirculate/Fresh.
- Temperature stepper: target readout, current readout, minus, plus.
- Fan speed: Quiet through Turbo dot-line selection.
- Panel heater: power plus temperature stepper.

Prefer copying the web dashboard's command semantics and remembered preference behavior before inventing new climate behaviors.

### Debugging

Interaction logs belong behind `#if DEBUG` and must not appear in the UI. Log accepted/ignored moves, focus nodes, edit entry, confirm, and cancel when tuning remote behavior.

## Build

On the Mac with Xcode:

```sh
xcodebuild -project NovaAppleTVDashboard.xcodeproj -scheme NovaAppleTVDashboard -configuration Debug -sdk appletvos build
```

The public build defaults to:

```swift
http://nova.local
```

For another hostname or fallback list, supply `NovaDashboardBaseURLs` in a private
Info.plist selected by an ignored local xcconfig. A standalone camera service can
similarly be supplied as `NovaCameraBaseURL`; without it, the app uses the
dashboard's same-origin `/api/camera` proxy.

`scripts/deploy-via-build-host.ps1` accepts the build Mac, SSH key, Apple TV
device id and Apple development team explicitly. Household endpoint overrides
belong in the build Mac's private `$HOME/.config/nova-apple-tv/deploy.env`, not
source control.
