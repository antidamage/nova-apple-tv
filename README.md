# Nova Apple TV Dashboard

The tvOS client for Nova. A native app that presents the dashboard's zones —
lighting, climate, timers, outside, network — on the TV, driven by the Siri remote, with
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

**Focus and input handling.** Movement is rate-limited per context, with immediate first input and bounded repeats. Every focusable control
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

The app is built, staged and deployed by the CI: a Forgejo Action on the build
Mac builds every push to the branch the set is built from, and a deployer
installs the newest staged build as soon as the Apple TV is awake. Agents should
let that happen rather than deploying by hand — see `docs/CI-APPLETV-CI.md`.

A manual deploy is still available, for putting one specific build on the set:

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

The landscape composition follows Nova Classic on the web: a pinned status orb,
clock column, Quick Access, then independently expanded Home and Systems groups.
Each group joins its vertical title (a label, always open) with its zone menu and
selected controls in one panel. The zone choices persist locally. Advanced panels are omitted; `AdvancedFold` remains a
supported opt-in component.

### Remote and rotary controls

The remote's feel is learned, not configured. The app keeps the reach of each
swipe it sees (the last 200, on the device, in its own storage) and works out the
person's range from them with the outliers clipped: the lower two thirds of the
range moves one item and the top third moves two. The behaviour is in
`specs/remote-swipe.md`.

The band reads the remote's touch surface itself and owns focus: it is hosted in a
container that refuses any focus update the TV's focus engine makes on its own, so
a swipe moves focus once, where the band's map says. The highlight the household
sees and the control Select activates are the same control.

Select unlocks a dial and holds the swipe target on it. While it is unlocked
every directional press is that dial's own step — left/right walks the dial's
steps (the ring sliders first, outermost inward, then the mode lights left to
right) and up/down adjusts the step you are on — and focus cannot leave the dial,
by the band's navigation or by the engine's geometry. Both ends hold, so neither
the outermost ring nor the last mode wraps or steps out of the dial. The unlock
is a lease: a second Select applies the draft, and so does five seconds with no
input, and Back discards it. Unmounting and app suspension discard a draft. Only
changed channels are sent, so polling and returning to the app never write stale
values.

- Colour: hue, brightness and saturation. Hue wraps; the other channels clamp.
  Colour is disabled when all lights are off; brightness can bring them back.
- Temperature: target, Auto/Manual/Off (heater Auto/Off), supported HVAC modes,
  fan, fresh air and sleep timer. Rings that do not apply fold away. The bedroom
  dial uses the server thermostat, not the old panel-heater entity.
- Timer: configured icon types, shared countdown, duration ring, silent Off
  cancellation and server-side completion. Duration steps follow the current
  web control: five seconds below a minute, ten seconds below five minutes,
  thirty seconds below ten minutes, then progressively coarser minutes.

The status orb is always reachable by navigating left. Select dismisses the
displayed timer/wash/reminder alert globally, or unlocks stack browsing, which
holds the swipe target the same way a dial does. Directional inputs step the
stack; Select, Back, or five seconds with no input returns it to priority order.
The orb never starts push-to-talk.

### Verification

Debug startup runs shared orb ordering/format conformance and
`LandscapeSelfTests` (swipe engine, focus neighbours, timer steps, clamp/wrap,
task query shaping and reminder acknowledgement).
`LandscapeUITests` exercises actual tvOS focus and Select/Back handling, captures
screenshots, and cancels previews without issuing household control commands.

Run on a tvOS simulator with `xcodebuild test -scheme LandscapeUITests
-destination 'platform=tvOS Simulator,name=<simulator>' CODE_SIGNING_ALLOWED=NO`. Grant
the simulator's media-library access first (`xcrun simctl privacy <simulator>
grant media-library nz.co.skull.NovaAppleTVDashboard`): opening the visualiser
otherwise raises the Apple Music permission prompt, which takes focus from every
later launch until it is answered.
The vendored SRT archive has no usable Intel simulator API: on that simulator
only, the transport reports unavailable and the existing local visualiser
fallback remains available. Device and Apple Silicon transport is unchanged.

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
- The theme's per-element treatments are part of that contract and are read from
  the **selected variant**:
  - `knobSkin` — the dial faces. Pinned to `dark`/`light` it is honoured exactly
    (the dashboard's dark theme asks for the pale knob, and vice versa); `auto`
    follows the theme's own background. The face's readouts and the mode-light
    wells follow the same skin, since pale ink on a pale face is invisible.
  - `ledColor` — the dials' mode lights and the orb's lit channel.
  - `unlockRingColor` — the ring drawn round a dial while it is unlocked.
- The status orb's draw stack is module-driven and rendered by native Metal
  (`MetalOrbView.swift` + `OrbShader.metal`). It interprets the declarative
  status-orb documents shared with the web dashboard — module settings, turbulent
  rings, all four blend modes, liquid-glass theme controls and the voice-glow
  colour slot — **including each layer's `enabledWhen` gate**, which is how a
  module ships the light and dark treatments of one surface and draws exactly
  one of them. `NovaAvatarOrb` fetches `GET /api/orb-modules` (5-minute poll),
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

## License

Licensed under the GNU General Public License, version 3 only (GPL-3.0-only).
See [LICENSE](LICENSE).
