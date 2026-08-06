# Nova Apple TV Dashboard

The tvOS client for Nova. A native app that presents the dashboard's zones —
lighting, climate, outside, network — on the TV, driven by the Siri remote, with
a live exterior camera feed and the shared status orb.

> **Full engineering reference: [`SPEC.md`](SPEC.md)** — architecture, source map,
> API contract, theming, the focus/navigation model, every zone surface, the
> status-orb subsystem, the camera and background renderers, and the invariants
> that must not regress. This README is the operator-facing UX contract and build
> notes.

## Where it fits

| Component | Interface |
|---|---|
| [Nova HA Dashboard](https://github.com/antidamage/nova-ha-dashboard) | Reads `/api/*` at `http://nova.local`, sends actions to `/api/zone`, consumes `/api/events` and `/api/orb-modules` |
| Camera host | `GET /api/camera/outside/index.m3u8` and `/status`, or a standalone service via `NovaCameraBaseURL` |
| [Nova Visualiser](https://github.com/antidamage/nova-visualiser) | Displays its stream; falls back to this app's own Metal engine when unavailable |

## What it does

**Zone control.** Lighting presets (ON, CANDLE/DAY, WHITE, OFF), climate
controls, outside power and network status, laid out as a ribbon of major zones
that expand in place.

**Camera.** The Outside zone carries an always-live inline preview of the
exterior feed. Selecting it opens the standard tvOS full-screen player with
play/pause, DVR scrub across the rolling window, skip and a LIVE indicator.

**Focus and input handling.** Movement is rate-limited per context and
opposite-direction flicks inside 100 ms are discarded. Every focusable control
carries a scroll id and re-centres on focus change, so the focused control is
always fully on screen.

**Thin-client model.** It does not host the dashboard, talk to Home Assistant
directly, or keep state while the Apple TV sleeps. It reads the dashboard API at
`http://nova.local` and sends zone actions back to `/api/zone`.

**Shared rendering.** The status orb is rendered in native Metal from the same
declarative module documents the web dashboard uses, and the Phonoscope Metal
engine is the offline fallback for the streamed visualiser.

## Install

On a Mac with Xcode:

```sh
xcodebuild -project NovaAppleTVDashboard.xcodeproj \
  -scheme NovaAppleTVDashboard \
  -configuration Debug -sdk appletvos build
```

The public build defaults to `http://nova.local`. For another hostname or a
fallback list, supply `NovaDashboardBaseURLs` in a private `Info.plist` selected
by an ignored local xcconfig. A standalone camera service can be supplied as
`NovaCameraBaseURL`; without it the app uses the dashboard's same-origin
`/api/camera` proxy.

To deploy to a device:

```powershell
scripts/deploy-via-build-host.ps1   # takes build Mac, SSH key, device id, team
```

Household endpoint overrides belong in the build Mac's private
`$HOME/.config/nova-apple-tv/deploy.env`, never in source control.

When the web dashboard's status-orb built-ins change, re-sync them:

```sh
node --experimental-strip-types scripts/sync-orb-builtins.mjs
```

## UX contract

A focus-first tvOS model. Directional swipes move focus predictably, select
expands or confirms, and edit controls capture remote input until confirmed or
cancelled. The layout should read like a PS4/PS5 dashboard: a tight horizontal
band of cards that expands vertically only when the active item needs to show
more.

### Zone structure

```text
Lighting | Climate | Outside | Network
```

Lighting expands into `Home | <room zones supplied by the dashboard>`. `Home`
controls every light; child zones follow the dashboard's configured room order
and control their own. Outside owns outside on/off, weather and the camera.
Climate owns climate devices. Network is a major zone, not a Home child.

### Focus and expansion

- Cards start as titles only.
- Select on a collapsed major or sub-zone expands it; select on an expanded one
  collapses it.
- Down from an expanded title enters the first child/control; up from controls
  returns to the owning title.
- Left/right within a row moves one item at a time.
- Left/right from an expanded title collapses before moving to a sibling.
- Auto-collapse may only happen after focus has actually left the hierarchy.
- Edge exits require two gestures: first collapse, then move away.
- Focus must never collapse a parent merely because focus moved to a child or
  control inside it.

### Remote movement tuning

| Context | Accepts a move every |
|---|---|
| Normal navigation | 260 ms |
| Repeated same-direction navigation | 220 ms |
| Edit controls | 110 ms |

Opposite-direction flicks inside 100 ms are ignored.

### Lighting controls

Lighting zones currently expose only the preset action row: ON, CANDLE/DAY,
WHITE, OFF. The hue grid and brightness slider are intentionally removed pending
a rework — they never worked reliably. `RemoteHueGrid` and `RemoteLinearSlider`
remain defined but unused, and `lightingFocusRows` no longer emits
`.hue`/`.brightness` rows. Restore them here when the feature is reworked.

### Outside camera

- The inline preview plays through a bare `AVPlayerLayer` (`CameraFeedView.swift`),
  muted, self-healing on stalls and failures. Source is the dashboard host's
  rolling-window HLS playlist at `GET /api/camera/outside/index.m3u8`;
  `GET /api/camera/outside/status` drives the LIVE/OFFLINE chrome and the source
  label (LIVE FEED vs PLACEHOLDER when the host serves the synthetic clock).
- The camera is a **focusable tile** in the Outside focus graph — its own row,
  `.action(zone.id, "camera-outside")`, below the outside-power button — so you
  swipe down past the passive weather panel to reach it. The preview is height-capped
  at 250 pt so scroll-to-focus reveals the whole tile.
- The inline preview is deliberately a bare layer rather than AVKit's
  `VideoPlayer`, so its transport controls never fight the custom focus model.
  Full transport lives in the full-screen player instead.
- The full-screen player is hosted by the **root** view and its presented camera
  id lives on `DashboardStore.fullScreenCameraID`, not on the tile. Presenting
  the cover sends the dashboard's `@FocusState` to `nil`, and the
  focus-left-the-zone logic would otherwise collapse the Outside zone, unmount
  the tile and dismiss the cover the instant it opened. Two guards keep this
  safe: `collapseIfFocusLeftExpandedArea` ignores a `nil` focus, and `handleExit`
  dismisses only the player when it is up, so Menu/Back never falls through to
  collapse the underlying zone.

### Modal editing

- Temperature controls follow the web dashboard: visible minus/plus controls,
  current and target readouts, immediate stepper actions. Do not replace these
  with a generic slider unless the web dashboard changes first.
- Fan speed uses a dot-line style control matching the web dashboard concept;
  while editing, swipes adjust the selected step and select commits.

### Visual rules

- The shared dashboard theme is the only colour source. Do not add ad hoc colours.
- The UI is mostly black and dark grey, monotone aside from theme accent and
  highlight colours.
- No default white tvOS focus boxes or rings anywhere.
- Focused controls use the shared highlight fill/outline; expanded or active
  controls use the shared accent fill/outline; idle controls use the shared
  border colour.
- The Nova activity/avatar widget stays top-centre. Its arcs circle the avatar,
  smoothly change direction, and size from load.
- The status orb's draw stack is module-driven and rendered by native Metal
  (`MetalOrbView.swift` + `OrbShader.metal`). It interprets the declarative
  status-orb documents shared with the web dashboard — module settings, turbulent
  rings, all four blend modes, liquid-glass theme controls and the voice-glow
  colour slot. `NovaAvatarOrb` fetches `GET /api/orb-modules` (5-minute poll),
  ships `classic`, `reactor`, `halo` and `cross` as offline fallbacks, and
  resolves the theme's `avatar.orbModule` with classic as the universal fallback.
- `VoiceSpeechStore` consumes `/api/events`. Speech start/end events centre and
  enlarge the orb and drive its alert layers with the same consonant envelope the
  browser dashboards use.
- The resting clock uses the shared clock colour slots and dashboard layout:
  local time with seconds and meridiem, a location chip from the Apple TV time
  zone, an ordinal long date, and a Monday-to-Sunday strip highlighting today.

### Climate parity

Match the web dashboard controls in
`nova-ha-dashboard/app/components/dashboard/ClimateControls.tsx`:

- Air conditioner power states: Auto, Manual, Off
- Modes: Heating, Cooling, Fan
- Fresh air switch: Recirculate/Fresh
- Temperature stepper: target readout, current readout, minus, plus
- Fan speed: Quiet through Turbo, dot-line selection
- Panel heater: power plus temperature stepper

Prefer copying the web dashboard's command semantics and remembered-preference
behaviour before inventing new climate behaviour.

### Debugging

Interaction logs belong behind `#if DEBUG` and must never appear in the UI. When
tuning remote behaviour, log accepted and ignored moves, focus nodes, edit entry,
confirm and cancel.
