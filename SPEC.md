# Nova Apple TV Dashboard — Specification

Native tvOS client for the local Nova Home Assistant dashboard. This document
scopes the **entire** app: its role, architecture, data contract, the focus and
interaction model, every zone surface, the status-orb subsystem, the camera and
background renderers, and the invariants that must not regress.

The companion `README.md` holds the operator-facing UX contract and build notes;
this SPEC is the engineering reference and is authoritative where the two
overlap.

---

## 1. Role and boundaries

The Apple TV app is intentionally a **thin client**. It:

- reads the existing Nova dashboard HTTP API and renders it,
- sends zone/entity commands back to that same API,
- holds **no** persistent state and does nothing while the Apple TV sleeps.

It explicitly does **not**:

- host the dashboard or any business logic that belongs on the host,
- talk to Home Assistant directly (every call goes through the Nova host),
- use any cloud/LLM/API-key service — there is no API key anywhere in the app,
- own "truth" for device state — the host's `/api/state` is the source of truth.

**Behaviour parity is a hard constraint.** Command semantics, remembered-
preference payloads, and the set of presets/modes mirror the web dashboard
(`nova-ha-dashboard`). When in doubt, copy the web client's behaviour rather than
invent new behaviour here. Any change to this app must preserve both the
user-facing UX and the HA-facing command shape unless the web client changes
first.

### Target

- Platform: tvOS 18.0+ (`TVOS_DEPLOYMENT_TARGET = 18.0`).
- Bundle id: `nz.co.skull.NovaAppleTVDashboard`, display name "Nova TV".
- Single landscape scene; no multi-scene support.
- Renders as an always-on Apple TV display.

---

## 2. Hosts and configuration

`AppConfig` is the bootstrap resolver for network endpoints.

- Public default: `http://nova.local`
- Optional private override: `NovaDashboardBaseURLs` in an installer-supplied
  Info.plist
- Optional standalone camera host: `NovaCameraBaseURL`; otherwise cameras use
  the dashboard's same-origin proxy

Every request is attempted against the hosts in order; the first reachable one
wins and is cached in `DashboardStore.activeBaseURL` so subsequent absolute URLs
(camera streams, background texture) resolve against the host that actually
answered. `Info.plist` allows arbitrary/local-network HTTP loads
(`NSAllowsArbitraryLoads`, `NSAllowsLocalNetworking`) because the host is plain
HTTP on the LAN. Household addresses and hostnames must remain in ignored local
configuration and must never be committed.

---

## 3. Runtime architecture

Two `@MainActor` observable stores are created once by the app entry point
(`NovaAppleTVDashboardApp`) and injected into the environment:

| Store | Responsibility | Poll cadence |
|---|---|---|
| `DashboardStore` | dashboard state, theme, layout, orb-module catalog, all command sends, active host, full-screen camera id | `/api/state` every **5s**, `/api/theme` after each state fetch, `/api/orb-modules` every **5 min** |
| `NovaActivityStore` | the `/api/nova-load` signal that animates the orb, plus the `/api/power` and `/api/tasks` feeds the status orb readouts need | load every **2s**; the extra feeds every **30s**, and only while a readout that needs them is selected |

Each store runs its polling loops in detached `Task`s started from `.task` on the
root view. Polling is best-effort: a failed cosmetic fetch (theme, orb modules,
activity) keeps the last good value; a failed `/api/state` surfaces an error
message but does not clear the last good state.

### Data flow

```
Nova host ──HTTP──> DashboardStore/NovaActivityStore ──@Published──> SwiftUI views
   ▲                                                                      │
   └──────────── POST /api/zone, /api/entity (commands) ◀────────────────┘
```

Commands optimistically adopt the `DashboardState` returned by the command
endpoint (the host echoes the post-command state), then the 5s poll reconciles.
Every command carries a random per-session `sourceClientId` so the host can
ignore the echo of our own command in its realtime fan-out.

---

## 4. Source map

Swift sources live in `NovaAppleTVDashboard/`. Files are grouped by concern so
each surface can be read in isolation; reusable chrome is centralized.

| File | Contents |
|---|---|
| `NovaAppleTVDashboardApp.swift` | App entry; creates the stores, starts polling. |
| `AppConfig.swift` | Host URLs and URL building. |
| `Models.swift` | All `Decodable` API models + `JSONValue` + zone/entity computed helpers. |
| `DashboardStore.swift` | `DashboardStore`, `NovaActivityStore`, the theme model (`DashboardTheme`, `ThemeRGB`, shared-theme decoding/resolution), `ZoneAction`, `EntityCommand`, `DashboardError`. |
| `Spectrum.swift` | Colour math: HSL↔RGB, spectrum-position colour, candlelight/white presets, `clamped`. |
| `Formatting.swift` | Display formatters (temperature, percent, wind, local clock/date/day, …). |
| `DashboardFocus.swift` | The focus identity (`DashboardFocus`), remote-input gating (`RemoteMoveGate`, edit events), and the focus **graph** that drives navigation. |
| `DashboardComponents.swift` | Reusable UI kit: fonts, `CutCornerShape`, control chrome, the focus/tap modifiers, `PanelFrame`, `ReadoutTile`, `EmptyStatePanel`, `ControlButton`, `IconControlButton`, `RibbonTitleButton`, `VerticalToggleSwitch`. |
| `TVDashboardView.swift` | Root view: the band layout, remote command handling, the primary zone ribbon, clock header, footer, loading state. |
| `LightingControlsView.swift` | Home→room ribbon, per-zone preset+brightness panel, vertical brightness slider. |
| `ClimateControlsView.swift` | Air conditioner + panel heater surfaces and all climate command logic. |
| `OutsideView.swift` | Outside zone (light toggle, camera tile, weather) + the passive weather/network status panels. |
| `NovaAvatarOrb.swift` | The orb view (surface, load shaping, readout overlay, speaking migration) — delegates drawing to Metal. |
| `OrbInfo.swift` | Status orb **info module** contract + `formatOrbValue` — a port of the dashboard's `lib/orb-info/`. |
| `OrbInfoModules.swift` | The tvOS module catalogue (gym, host load, clock, sky, household) and display resolution. |
| `OrbInfoConformanceCases.swift` | GENERATED. The shared formatter case table; regenerate via `scripts/generate-orb-info-cases.mjs`. |
| `OrbModules.swift` | Status-orb module **model** (decoding, settings, layers, geometry), validation, palette, and animation state. |
| `OrbBuiltins.swift` | The embedded built-in module JSON + `OrbModuleCatalog` (offline catalog + fallback rule). |
| `MetalOrbView.swift` | Native Metal status-orb renderer and module-command encoder. |
| `OrbShader.metal` | GPU interpreter for orb primitives, turbulent rings, liquid glass and speech glow. |
| `VoiceSpeechStore.swift` | `/api/events` SSE consumer and dashboard-compatible speech timing/envelope state. |
| `ParitySelfTests.swift` | Debug startup assertions for shared theme, orb, speech and clock contracts. |
| `CameraFeedView.swift` | HLS playback: inline `AVPlayerLayer` host and the full-screen `AVPlayerViewController`. |
| `FluidBackgroundView.swift` | Metal-backed animated background (`UIViewRepresentable` + renderer). |
| `FluidBackgroundShader.metal` | The background fragment/vertex shaders. |

### Access-control convention

The app is a single module. Types/functions referenced across files are
`internal` (the default, no keyword); helpers used within a single file stay
`private`. View structs that are only ever instantiated by their owning file
(e.g. `ZoneRibbon`, `DashboardHeader`) remain `private`.

---

## 5. API contract (endpoints consumed)

All paths are relative to a host base URL.

| Method | Path | Used for |
|---|---|---|
| GET | `/api/state` | Full dashboard state (zones, entities, totals, router, sun, weather, preferences, warnings). |
| GET | `/api/theme` | Shared theme payload (variants + top-level `layout`). |
| GET | `/api/orb-modules` | Status-orb module catalog (merged host built-ins + dropped modules). |
| GET | `/api/nova-load` | Activity signal (cpu/net/gpu/load + listening flag). |
| GET | `/api/power` | Live household watts + cost rate, for the power status orb readouts. |
| GET | `/api/tasks?command=list` | Reminder list, for the next-reminder / overdue readouts. |
| GET | `/api/camera/<id>/index.m3u8` | Rolling-window HLS playlist for a camera. |
| GET | `/api/camera/<id>/status` | Camera source/recording/connection state. |
| POST | `/api/zone` | Group/zone lighting action (on/off/brightness/color/candlelight/white). |
| POST | `/api/entity` | Single-entity service call (climate, switch, light). |

### Request shaping

- GET: `cachePolicy = .reloadIgnoringLocalCacheData`; timeouts 3–4s.
- POST: JSON body, timeout 6s.
- `/api/zone` body: `{ zoneId, action, sourceClientId, brightnessPct?, cursor?, rgb? }`.
- `/api/entity` body: `{ entityId, domain, service, data?, remember?, sourceClientId }`.
- A 2xx with a JSON body is decoded as the new `DashboardState`; a non-2xx with
  `{ "error": ... }` becomes a surfaced `DashboardError.server`.

---

## 6. Data model (`Models.swift`)

- `DashboardState` — the root payload. Derives the **primary zones** (Home,
  Climate, Outside, Network) and the **Home child zones** (rooms, retaining the
  dashboard-provided order), plus helpers
  to resolve a zone by id and to map any zone id to its top-level zone.
- `DashboardZone` — id, name, entities, domain counts, on/brightness, and a set
  of computed classifiers (`isHomeZone`/`isClimateZone`/`isOutsideZone`/
  `isNetworkZone`) and entity slices (`lightEntities`, `climateEntities`, …).
  Zone kind is matched by id **or** normalized name so the host can rename.
- `DashboardEntity` — id, domain, state, name, area, free-form `attributes`
  (`[String: JSONValue]`), and an `isIllumination` flag. Computes `isOn`,
  `isProblemState`, target/current temperatures, hvac/fan modes.
- `DomainCounts` — per-domain counts + a `summaryParts` list for subtitles.
- `RouterStatus`, `WeatherStatus`, `SunStatus`, `DashboardPreferences`
  (`AirconPreferences`, `WatchfacePreferences`), `NovaLoad`.
- `JSONValue` — a permissive JSON value used for entity attributes, with
  `doubleValue`/`stringValue`/`stringArray`/`doubleArray` accessors.
- `SpectrumCursor`, `RGBColor`, `SpectrumValue` — colour selection types.

Decoding is **lenient**: unknown/missing fields fall back, never throw the whole
payload away (e.g. `isIllumination` defaults to `false`).

---

## 7. Theming

The shared theme is the **only** colour source. The UI is otherwise monotone
black/dark-grey; the only chromatic colours are the theme **accent** and
**highlight**. Do not introduce ad-hoc colours.

### Resolution pipeline

1. `/api/theme` returns a `SharedThemeResponse` with an optional `theme` payload
   and a top-level `layout` block.
2. `SharedThemePayload.resolved(sun:)` selects the variant:
   - `selection == "light"` → light; `"dark"`/absent → dark;
   - `"auto"` → resolved from `SunStatus` (below-horizon ⇒ dark; else compares
     next sunrise/sunset; falls back to local hour 6–18 ⇒ light).
   - A legacy flat theme is honoured when no variants are present.
3. `DashboardTheme(sharedTheme:)` maps the shared colours (each an rgb + 0–100
   intensity) into concrete `ThemeRGB`s, with documented clamps and defaults.
4. `layout.tvHeightFraction` (clamped 0.3–0.95, default 0.6) sets the band height
   fraction; it is a tvOS-specific knob delivered on the shared theme envelope.

### Derived colours

`DashboardTheme` exposes `panel`/`panelSoft` (background mixed toward black/
white), `text`/`muted` (title colour chosen by luminance + `titleTone`),
`titleOnAccent`/`titleOnHighlight` (legible text over the accent/highlight), and
`borderColor`. These are the vocabulary every component uses.

### Avatar sub-theme

`DashboardAvatarTheme` carries the orb gradient colours, the three line colours +
opacities, the gym number colour/opacity/threshold, the inner-shadow opacity, and
the **`orbModule`** id selecting which status-orb module renders (see §11).

---

## 8. Layout and visual system

The whole UI is one fixed-height **horizontal band**, vertically centred, with
ambient background above and below. Left→right:

```
[ Status Orb ] [ Clock ] [ Zone ribbon → expands right as you drill in … ] →scroll
```

- Band height = `screenHeight × layoutHeightFraction`.
- Everything from the zones rightward lives in a horizontal `ScrollView`;
  `ScrollViewReader.scrollTo(focus, anchor: .center)` runs on every focus change,
  so the focused column is always brought fully on screen — no dead ends.
- Cards use `CutCornerShape` (top-right corner sliced). Fonts: Rajdhani (display)
  and Share Tech Mono (mono), via `Font.novaDisplay`/`Font.novaMono`.

### Reusable kit (`DashboardComponents.swift`)

- `PanelFrame` — the standard bordered card.
- `ControlButton` / `IconControlButton` — icon(+label) controls.
- `RibbonTitleButton` — zone/room title buttons; the whole focused+expanded chain
  lights up in the highlight colour, the focused one with a thicker border.
- `ReadoutTile`, `EmptyStatePanel`.
- `VerticalToggleSwitch` — the shared vertical two-state toggle (aircon fresh-air
  and the Outside light both use it; `indicatorAtTopWhenOn` flips which end means
  "on").
- Chrome + focus modifiers: `controlChrome(isFocused:isActive:)`,
  `dashboardFocus(_:equals:)`, `dashboardFocusTarget(_:equals:)` (passive),
  `dashboardTapTarget(_:equals:perform:)` (interactive). These three modifiers are
  the single source of "focusable, no system focus ring, fires on Select", and
  every control routes through them.

### Visual rules (invariants)

- No default white tvOS focus rings anywhere (`focusEffectDisabled()` everywhere).
- Focused = highlight fill/outline; active/expanded = accent fill/outline; idle =
  border colour.
- Don't add new ad-hoc colours.

---

## 9. Focus and navigation model

The app does **not** use the system focus engine for movement. It owns focus via
`@FocusState<DashboardFocus?>` and an explicit, transposed **focus graph**.

> **Why stickiness lives in `onChange(of: focus)`, not `onMoveCommand`.** Every
> control is `.focusable(true)`, so for a swipe between two *adjacent* focusable
> controls the tvOS **focus engine moves focus itself** and consumes the input —
> the root `onMoveCommand` only fires at the edges of the focusable layout (and
> before a level is expanded). That means the sticky boundaries can't be enforced
> by gating `onMoveCommand`; they're enforced by watching the resulting focus
> *change*: a disallowed crossing is **reverted** (`focus = oldFocus`) until the
> boundary's charge is met, and the focused control plays the rubber-band nudge.
> (Making controls focusable only while focused does NOT work — a control can't
> gain focus if it's only focusable once focused, a deadlock that kills all input.)

### Focus identity

`DashboardFocus` enumerates every focusable element: `.section` (primary zone
title), `.child` (Home room title), `.action(zoneID, id)` (a button/tile),
`.brightness`, `.temperature`, `.fanSpeed`, and the parked `.hue`. Each value is
also the scroll id used by scroll-to-focus.

### The graph (`dashboardFocusGraph`)

Built for the current expansion as **rows of siblings**. Critically, the graph is
*transposed* relative to the screen:

- The outer index (row) is a **depth level**, laid out **left→right** on screen.
- Items within a level are **siblings**, stacked **top→bottom**.

So the remote maps to:

- **up/down** → move between siblings in the current level,
- **right** → go deeper (expand the focused title like Select, or step to the
  next control column),
- **left** → go shallower (return to the owning title, or — at the left edge of a
  control group — behave like Back).

Any branch that has controls **must** contribute its control rows to the graph,
or focus on those controls has no position and navigation collapses to the first
zone button.

### Expansion and collapse

- Select on a collapsed title expands it and moves focus to its first control.
- Select on an expanded title collapses it.
- Moving focus out of an expanded hierarchy auto-collapses it — but only once
  focus has **genuinely** left (`collapseIfFocusLeftExpandedArea` ignores a `nil`
  focus, which is a transient modal focus loss).
- Menu/Back (`handleExit`) consumes exactly one level per press: dismiss camera →
  cancel edit → then `collapseOneLevel` (collapse child → collapse zone → step to
  owner). Edge exits therefore always take a deliberate second gesture, and the
  button path is instant. Reversing out by **swipe** is additionally sticky — see
  *Sticky boundaries* below.

### Live swipe tuning (`SwipeSettings`)

The remote feel below is **not hard-coded** — it is driven by `SwipeSettings`
(`DashboardStore.swift`), polled live off the `/api/theme` envelope's
`layout.swipe` block and edited from the dashboard's **Apple TV Expert Settings**
section (server side: `lib/appletv-swipe.ts` owns the defaults/ranges, surfaced
by `app/api/theme` and written via `app/api/layout`). Defaults match the values
quoted here; the gates read the live struct so changes apply without a rebuild.

### Remote tuning (`RemoteMoveGate`)

- Navigation accepts one move every `moveInterval` (default **220ms**; the
  reverse-direction interval is `moveInterval × 1.18`, ~**260ms**).
- Edit moves accept every **50ms** so sliders track a continuous swipe (fixed).
- Opposite-direction "flicks" within **100ms** are dropped (anti-bounce, fixed).
- A short **detachment dwell** (`detachDwell`, default ~80ms) prevents a control
  being abandoned on the first frame of a swipe.

### Sticky boundaries (`StickyBoundaryGate`)

Some transitions resist an accidental swipe: crossing them needs **several
accepted moves in a row** (vs one for an ordinary move), so a stray diagonal
flick can't cascade out of a menu or jump between devices. Charge accumulates
only while the same element pushes the same way against the same boundary, and
resets on any other move, a `resetInterval` rest (default ~500ms), or a
successful crossing.

- **Hierarchy** — reversing one level *out* by **swipe** (left at a control edge,
  or a room title back to the ribbon): `hierarchyCharge` moves to cross (default
  **4**). The physical **Menu/Back button is never gated** (`handleExit` →
  `collapseOneLevel`); it is always an instant, deliberate one-level exit. Only
  the fuzzy trackpad swipe is sticky.
- **Component group** — switching device groups inside the final level (e.g. the
  air conditioner ↔ the panel heater, classified by `controlGroupID`):
  `componentGroupCharge` moves to cross (default **3**). Moving control-to-control
  inside one device is immediate.
- While a boundary holds, the **focused control itself** plays a brief rubber-band
  **nudge** (`SwipeNudge`, delivered through the `\.swipeNudge` environment to the
  control via `dashboardFocus`) — it leans `nudgeDistance` points (default **14**,
  growing with charge progress) toward where it would go, then springs back, so
  the resistance previews the break-free direction rather than reading as a dead
  remote. Setting `nudgeDistance` to 0 disables the hint.

Per-level: `up/down` (siblings) never crosses a boundary; drilling **in** (right
on a title) is never sticky — only reversing out and crossing device groups are.

### Edit handshake

Edit-capable controls (brightness, temperature stepper-as-edit, fan speed, parked
hue/linear) follow one pattern: Select enters edit mode and claims `editingFocus`;
the root view forwards serialized `editMove`/`editCancel` events; the control
keeps a local `draft`, steps it on `editMove`, applies on Select, and discards on
`editCancel` (Menu). Serial + focus tagging let a control ignore stale/foreign
events.

### Debugging

`debugInteractionLog` traces accepted/ignored moves, focus transitions, and edit
enter/confirm/cancel — compiled out of release builds. Interaction logging must
never surface in the UI.

---

## 10. Zones

The primary ribbon is **Lighting | Climate | Outside | Network**.

### Lighting (the Home zone, branded "LIGHTING")

Expands into a room ribbon built from dashboard state: **Home | configured room
zones**. Home controls every light; each room controls its own. Selecting a room
opens its control panel:

- **Preset column**: ON, CANDLE/DAY, WHITE, OFF.
  - CANDLE/DAY and WHITE send a spectrum cursor + preview rgb so the host
    reproduces the web presets exactly; the label and warmth adapt to whether the
    sun is below the horizon (CANDLE 60% warm vs DAY 100% warm-white).
- **Vertical brightness slider** (100% top → 0% bottom): Select to edit, swipe
  up/down (5%/step), Select to apply, Menu to cancel.

> The colour (hue grid) and horizontal brightness controls are **parked** (see
> `ParkedControls.swift`) — removed from the live UI because they never worked
> reliably with the remote. `lightingFocusRows` deliberately does not emit their
> focus rows. Restore them (and the rows) together when reworked.

Any non-Home lighting-capable zone that is itself a primary zone gets the same
preset+brightness panel.

### Climate

Two devices, resolved by fuzzy name/id match (`ClimateDevices`):

- **Air conditioner**:
  - Power: **Auto / Manual / Off** (Auto hidden-disabled unless the unit can both
    heat and cool).
  - Mode: **Heating / Fan / Cooling** (hidden-disabled when unsupported).
  - **Fresh-air** switch: Recirculate/Fresh (`VerticalToggleSwitch`).
  - **Temperature** stepper: target + current readouts, +/- snapped to the
    device step and clamped to min/max. The aircon remembers its target.
  - **Fan speed**: a vertical dot column Quiet→Turbo; Select to edit, up/down to
    step, Select commits — reconciling the quiet/turbo switches and the native fan
    mode in one batch.
- **Panel heater**: ON/OFF + temperature stepper (does not remember a preference).

Command shapes and `remember` payloads mirror
`nova-ha-dashboard/app/components/dashboard/ClimateControls.tsx`. Controls (but
not readouts) dim when the unit is off and not in Auto.

### Outside

- **Light On/Off** toggle (`VerticalToggleSwitch`, indicator at ON/top when lit).
- **Live camera tile** (see §12) — a focusable tile; Select opens the full-screen
  player.
- **Weather** — a passive readout panel (condition + feels-like + a 2×2 temp/
  rain/wind/UV grid). Focusable (so it can be swiped onto and scrolled into view)
  but takes no Select action.

### Network

A passive router/WAN status panel (name, WAN state, download/upload/link). Like
weather it is focusable but has no Select action — a primary zone, not a Home
child.

---

## 11. Status orb modules

The orb's entire draw stack is **module-driven** and shared, byte-for-byte, with
the web dashboard. A module is a declarative JSON document describing ordered
layers. Full contract: `nova-ha-dashboard/SPEC.md` ("Status Orb Modules").

### Contract conventions

- **Unit space**: orb radius = 1.0, centre (0,0), +x right, +y down; every length
  is a fraction of the radius.
- **Angles/sweeps** are in **turns** (0–1 per revolution, clockwise from 3
  o'clock), converted to radians only at draw time.
- **Blend modes** are restricted to four implemented by the native Metal
  compositor (`normal`, `additive`, `screen`, `multiply`).

### Pieces (this client)

- `OrbModules.swift` — the lenient decodable model (values clamped, unknown layer
  types skipped, invalid documents rejected whole), `OrbModule`/layer types,
  `isValidOrbModuleID`, the per-frame `OrbPalette` (resolves theme slots to
  colours), setting-value bindings, and `OrbAnimationModel` (arcField/lineField
  segment state, identical motion model to the web).
- `OrbBuiltins.swift` — the embedded built-in modules (`classic`, plus others)
  exported verbatim from the web's `lib/orb-modules.ts`, and `OrbModuleCatalog`.
- `MetalOrbView.swift` + `OrbShader.metal` — encode and render every module
  primitive at 60fps, including turbulent rings, module settings, the shared
  glass controls, background refraction and the theme's voice-glow slot.
- `NovaAvatarOrb.swift` — owns only the Metal surface, load shaping (listening
  lifts the floor), gym-hours overlay and the compositor movement used while
  Nova speaks.

### Resolution and fallback

`OrbModuleCatalog.resolve(id:fetched:)` is the single cross-platform rule:
requested id → fetched catalog → built-ins → **`classic`**. Fetched modules
overlay the built-ins (a partial server response can never remove an offline
fallback). When the web built-ins change, regenerate the embedded JSON (command
is commented next to the constant in `OrbBuiltins.swift`).

The avatar's gym alert drives a shared raised-cosine pulse: layers may reference
an `alertTheme` to mix toward, or be `alertOnly` (hidden until the alert is
active) — so the alert behaviour needs no module-specific renderer code.
Speech events use the same pulse path. `VoiceSpeechStore` listens to
`/api/events`, reconstructs the server's audible start time and consonant timing,
then supplies the same envelope used by the dashboards. While speaking, the orb
migrates to the screen centre, enlarges with a higher-resolution drawable, hides
the readout, and returns after the end event.

---

## 12. Camera subsystem (`CameraFeedView.swift`)

The host serves a rolling-window HLS playlist per camera; tvOS plays it natively.

- **Inline preview** (`CameraPlayerView` → bare `AVPlayerLayer`): muted, non-
  focusable, non-interactive, and self-healing (rebuilds on stall/failure/`ended`
  with a short backoff). Deliberately **not** AVKit's `VideoPlayer`, whose
  focusable transport would fight the dashboard's custom focus model.
- **Full-screen player** (`CameraFullScreenPlayer` → `AVPlayerViewController`):
  the canonical tvOS video surface — native play/pause, DVR scrub across the
  rolling window, skip, LIVE badge — driven by the Siri remote.

### Modal ownership invariant

The full-screen presentation is owned by the **root** view and its camera id
lives on `DashboardStore.fullScreenCameraID`, **not** on the tile. Presenting the
cover sends the dashboard's `@FocusState` to `nil`; without care the
focus-left-the-zone logic would collapse the Outside zone, unmount the tile, and
dismiss the cover instantly. Two guards make this safe:

1. `collapseIfFocusLeftExpandedArea` ignores a `nil` focus (transient modal
   loss), and
2. `handleExit` dismisses only the player (clearing `fullScreenCameraID`) when it
   is up, so Menu/Back never falls through to collapse the zone.

`CameraFeedStatus` (`/api/camera/<id>/status`) drives the LIVE/OFFLINE chrome and
the source label (LIVE FEED vs PLACEHOLDER when the host serves a synthetic
clock). The inline preview is height-capped (250pt) so the whole tile is revealed
by scroll-to-focus.

---

## 13. Fluid background (`FluidBackgroundView.swift` + `.metal`)

A Metal-rendered animated field that mirrors the web dashboard's background.

- Driven entirely by the theme's `backgroundEffect` (peak intensity, falloff,
  warp, hue spread, apex glow, texture scale/URL) plus the resolved background/
  accent/highlight colours.
- Renders at 30fps via an `MTKView`; falls back to a flat themed `UIView` if Metal
  is unavailable.
- An optional **mosaic texture** (from the theme's `textureUrl`, resolved against
  the active host for relative URLs) refracts the field; tiling is normalized by
  `targetDPR / devicePixelRatio` so it reads at the same apparent scale as the web
  regardless of pixel density. The texture reloads only when its URL changes.

---

## 14. Phonoscope beat synchronisation

- Track resolution returns Nova's complete cached `beatTimes` timeline at song
  start. The Apple TV aligns that timeline to `SystemMusicPlayer.playbackTime`;
  it does not call ReccoBeats or synthesize its own independent clock.
- The local renderer uses the current playback position. House Party separately
  samples the same timeline 250 ms ahead for local HA lights and 1.10 seconds
  ahead for cloud-backed Tuya lights, compensating for their different command
  paths without advancing the on-screen visualiser.
- When a cached timeline is unavailable, the client retains the BPM/offset
  fallback so playback and controls remain usable offline.
- The Apple TV is the distributed playback-clock master. Every House Party
  frame can carry its current track and playback observation; Nova extrapolates
  that state for polling clients. Track changes, play/pause changes, resets, and
  seeks of at least 650 ms bypass normal frame suppression and publish
  immediately instead of waiting for the periodic keepalive.
- Swiping up reveals the House Party action bar. It stays visually subordinate
  to the visualiser with an identical dark-charcoal focused and unfocused
  surface, a 75% grey label, and no tvOS focus effect. The bar dismisses as soon
  as its action loses focus.
- Swiping down reveals a three-button theme transport at the top of the
  visualiser. Prev group and next group step sideways to the adjacent colour
  theme group and land on its first entry, playing the transition the departing
  entry authored; the group's own sequence keeps rotating. Pause freezes the
  current interpolated frame and resume continues from that exact frame — the
  transport's only hold. Stepping groups while paused stays paused. The
  transport uses a charcoal panel
  and charcoal focused control with the dashboard highlight colour as its focus
  outline, and dismisses when none of its buttons retains focus.

---

## 15. Accessibility

- Interactive controls carry `.isButton`; the orb and camera expose descriptive
  labels (the status orb readout, camera live/offline).
- Passive panels are focusable for navigation but are not labelled as buttons.

---

## 16. Build and deploy

The project can be edited on any host; tvOS compilation and signing happen on a
Mac with Xcode.

- Compile check (no signing, simulator destination):
  ```sh
  xcodebuild -project NovaAppleTVDashboard.xcodeproj -scheme NovaAppleTVDashboard \
    -configuration Debug -destination 'generic/platform=tvOS Simulator' \
    -derivedDataPath ./DerivedDataSim CODE_SIGNING_ALLOWED=NO build
  ```
- Full build + install + launch: `scripts/deploy-via-build-host.ps1`. It requires
  the build Mac, Apple TV device id and development team as arguments, packages
  the project, runs the simulator compile check, performs a signed build through
  the Mac's GUI Terminal, propagates that build's exit status, installs, launches
  and verifies the process. Household endpoint overrides can be loaded from the
  Mac's private `$HOME/.config/nova-apple-tv/deploy.env`.
- The Xcode project uses **explicit** file references (not synchronized groups):
  a new source file must be added to `project.pbxproj` in four places
  (`PBXBuildFile`, `PBXFileReference`, the `NovaAppleTVDashboard` `PBXGroup`, and
  the `Sources` `PBXSourcesBuildPhase`) or it will not compile.
- **Sleep blocker**: a sleeping Apple TV refuses foreground launch; install
  succeeds but visual verification needs someone to physically wake the TV.

---

## 17. Invariants — do not regress

1. **Behaviour parity**: never change user-facing UX or the HA command/`remember`
   shapes unless the web client changes first.
2. **No new colours**: only theme accent/highlight + the derived monotone palette.
3. **No system focus rings**: keep `focusEffectDisabled()` on every focusable.
4. **All focusable controls join the graph** and carry their scroll id via
   `dashboardFocus`/the tap-target modifiers — otherwise scroll-to-focus and
   navigation break.
5. **Camera modal ownership** stays on the root/store with the two guards in §12.
6. **Orb modules stay byte-for-byte** with the web built-ins; regenerate, don't
   hand-edit, the embedded JSON.
7. **Thin client**: no direct HA access, no API keys, no persistence.
8. Temperature controls stay as explicit +/- steppers with readouts (not a generic
   slider) unless the web dashboard changes first.

---

## 18. Parked / future work

- **Colour (hue grid) + horizontal brightness** controls live in
  `ParkedControls.swift`, currently unwired. Rework needs a remote-friendly
  interaction; restore the `.hue`/`.brightness` focus rows in `DashboardFocus.swift`
  when re-enabling.
- **Remote wake**: there is no automated wake for the Apple TV (no paired pyatv
  companion credentials); re-pairing would let deploys self-verify visually.
