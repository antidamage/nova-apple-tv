# Nova on iPhone (touch build)

Adeline, 2026-10-23: "copy the apple TV app and adapt it to ios maintaining the
same feature set. it will be touch-only, but otherwise just like the apple TV
app. I'm going to use it to demo the ATV app in a pinch, but I also want to try
the app as-is. we should use the personal license for now."

Plan `research-everything-and-make-quiet-bumblebee`. Interview answers: shared
sources, a phone-sized band, the phone is a music player too.

## Target

- Target and scheme `NovaTouch` in `NovaAppleTVDashboard.xcodeproj`, beside the
  TV target. Bundle `nz.co.skull.NovaTouch`, display name "Nova", iOS 18.0,
  iPhone only (`TARGETED_DEVICE_FAMILY = 1`), landscape only.
- Signed with the free personal team, passed at build time and never written to
  the project. Profiles last seven days, so the app is reinstalled weekly.
- CI builds the TV scheme only; nothing here changes what it builds.

## Shared sources

- One copy of every source file; both targets compile all of them. Platform
  code splits with `#if os(tvOS)` / `#if os(iOS)` where an API or a behaviour
  is one platform's: the remote host (`RemoteInputHost`), Menu/Back
  (`onExitCommand`), the move commands (`onMoveCommand`), the off-screen theme
  column.
- The remote stack still compiles on the phone (it is plain UIKit and
  Foundation) but is never installed there: the phone's root has no
  `RemoteInputHost`.
- The phone's own pieces are in `TouchInput.swift` (`TouchEditPad`, the orb's touch
  pad, and `PhoneCanvas`) and `RotaryEncoderTouch.swift` (the dials' touch rules).

## Touch model

The existing custom controls are kept (`docs/control-inventory.md`), and so is
their edit model: a control is unlocked, stepped, then committed, with the same
five-second idle commit as the TV. Only what drives it changes.

| Control | TV | Phone |
| --- | --- | --- |
| Any tap target | Select | Tap (the control takes focus, then acts) |
| Dials (rotary, temperature, colour, timer) | Select unlocks; up/down steps; left/right changes channel; Select saves; Back discards | The web dial's touch rules (below, "Dials on the phone") |
| The orb | Select unlocks; up/down steps; Select or Back locks | Tap unlocks; then the whole screen is its touch pad: drag up/down steps the stack (one step per 14 canvas points), a tap anywhere locks |
| The band | Swipes step between controls and panels | Native horizontal scroll |
| Theme / HOST | In the column left of the orb | At the foot of the orb's sidebar; tap |
| Phonoscope | Left/right skip, up House Party bar, down theme bar, Menu leaves | The same as swipes; a close button (top left) leaves |
| Full-screen camera | Menu closes | A close button (top left) closes |

While the orb is unlocked nothing else on the phone takes a touch, as on the TV
the unlocked control owns the remote.

### Dials on the phone

Adeline, 2026-10-25: "the rotary controls on the ios version need to work like the
web version. I don't mind the focus ring and appearance, but the interactions
should be the same." The rules are the web's (`nova-ha-dashboard`,
`specs/color-encoder.md` "Interaction", "Tuck-away", "Ring interaction";
`specs/temperature-encoder.md` "LEDs are the modes"); the look, the focus ring and
the TV's remote model are unchanged. The code is `RotaryEncoderTouch.swift`.

- **Locked, one tap unlocks.** The unlocking tap does nothing else. A locked dial
  takes no drags, so the band still scrolls across it.
- **Unlocked, a drag on the knob turns it like a real knob**: relative, by angle
  about the knob's centre. Each sample applies the angle swept since the last one,
  the short way round; samples inside `0.15 ×` the knob's radius are ignored. The
  rate is the index's own: `range / 270°` per degree, or `range / 360°` for a
  channel that wraps (hue). It stops at the channel's ends and reverses at once.
  The value previews while turning and **commits on release**.
- The knob turns the dial's face channel (`faceChannel`, the temperature target),
  or else the lit channel (the colour knob's HUE / BRIGHT / SAT, the timer's type).
- **A tap on the knob (under 5 points of travel) cycles the LEDs and wraps.** On a
  dial whose LEDs show a value (`ledChannel`, the climate modes), the value for
  the LED it ends on is sent **1.5 s after the last tap**, and only if it differs
  from where the taps started. Otherwise a tap lights the next usable channel.
- **Rings: the thumb is the only handle.** A press grabs a slider or selector ring
  only on its thumb's hotspot: the ring's band radially (one ring pitch, 15 points,
  centred on its track; the innermost ring also owns everything from the knob's
  edge out), and the thumb plus 22 points of arc past each end angularly. The web
  pads one track; the phone pads a fingertip. Grabbing never moves the thumb: the
  press-to-thumb angle is kept for the drag. The value is absolute to where the
  thumb is dragged along the 270° arc, snapping to the ring's step. Dragging into
  the bottom gap pins at the nearer end until the finger comes back on that end's
  half. Commits on release.
- **A toggle ring** has no thumb: a tap anywhere on its band flips it and commits.
- Hidden and disabled rings take no touch; a press in the gap or off a thumb does
  nothing.
- **The timer commits on lock**, as the web's does (its type and duration only
  make sense together); every other dial commits each gesture on release.
- **It locks again after five seconds without input**, or at once on a tap
  anywhere outside the dial and its rings, which still reaches what it landed on.
  It never locks while a finger is on it. A tap straight onto another dial unlocks
  that one and locks this one. Locking sends anything not yet sent (a pending LED
  change, the timer's edit). Scene suspension discards it, as on the TV.
- A tap is judged in real screen points of total travel, not canvas points, so
  the canvas's scale does not shrink it. A press in the knob's dead centre turns
  nothing until the finger leaves it.
- The colour knob fills a channel it is not sending from what it last sent for
  ten seconds, not from the zone, so two quick turns cannot undo each other.
- The focus ring stays: the theme's unlock ring while unlocked, the highlight
  while only focused.

## Layout

- The same panels in the same order and visual language.
- `PhoneCanvas` lays the TV dashboard out on a canvas of the phone's size
  divided by one factor, then draws it at that factor, so every width, font and
  gap keeps its proportion. The factor is the phone's height ÷ 700, clamped to
  0.4…1 (about 0.63 on a landscape iPhone Pro Max). The band then scrolls
  sideways as it does on the TV.
- The TV's layout and its numbers are unchanged.

## Music: the phone is a player too

- The phone reports its own now-playing to `/api/phonoscope/now-playing` with
  `source: "iphone"`; the TV keeps `"appletv"`.
- The server keeps one report per source and hands the visualiser the source
  that most recently started playing; a paused or stale source (over 8s) yields
  to one that is playing (`nova-ha-dashboard`, `lib/phonoscope-now-playing.ts`).
- Preset commands carry a `target` (default `appletv`), and each app asks only
  for its own (`GET /api/appletv/command?target=iphone`). A TV preset never
  starts music on the phone, and the reverse.
- The web's preset buttons still target the TV. A "play on phone" control on the
  web is follow-up work, not part of this.

## Info.plist (`NovaTouch/Info.plist`)

ATS (`NSAllowsArbitraryLoads`, `NSAllowsLocalNetworking`), local-network and
Apple Music usage text worded for the phone, the four fonts, the camera keys,
landscape orientations, `UIRequiresFullScreen`. App icon from
`apple-tv-icon.png`. The host setting is `specs/host-settings.md`.

## Done means

- A signed build installs and launches on Neptunium.
- Every panel the TV shows is reachable and operable by touch; a dial change
  reaches Home Assistant.
- The camera plays; Phonoscope renders or streams.
- Music played on the phone drives the visualiser.
- The TV build, its behaviour and CI are unchanged.
