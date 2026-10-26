# Remote swipe

Plans: `we-re-working-on-the-imperative-wozniak` (2026-10-15), then the adaptive
range (2026-10-15).

How the Siri Remote's touch surface moves focus on the landscape band. The goal is
the Apple TV feel: slightly sticky, not too sensitive, one item per ordinary
swipe, a deliberate long swipe going further, a short coast after a fast flick,
and quick swipes in a row that flow. It is learned from how the person swipes;
there are no settings.

## Why it exists

The old band let the tvOS focus engine and the app both move focus on every swipe,
then put back whatever the engine did. That produced flicker, dropped moves and a
feel the app did not control. The band now reads the raw touch surface itself and
the focus engine is not allowed to move focus on its own.

Fixed distances were then wrong in both directions: sized for the full pad, they
left the status orb impossible to leave on the first-generation glass-pad remote,
whose touch area is small. The distances now come from the person's own swipes.

## Input

- **Touch**: UIKit indirect touches, the path every remote (first- and
  second-generation Siri Remote, the iOS Remote app) uses for swipes everywhere in
  tvOS. `RemoteTouchRecognizer` follows one touch from start to finish and never
  recognises a gesture of its own, so it takes no touches from anything else. A
  touch's travel is converted to pad units with 1,600 points as the width of the
  surface (the pad is 2.0 units, 100%, wide, and y grows upward); the learned range
  adapts the distances, so this only sets where they start.
- **Fallback**: until the first UIKit touch arrives, `GCController.microGamepad` in
  its documented relative mode (`reportsAbsoluteDpadValues = false`: the first
  touch point is the origin) drives the engine instead, in case a remote's touches
  never reach the band as UIKit touches. Exactly (0,0), or 120 ms with no sample,
  means the thumb lifted. The first build of this engine read absolute values,
  which read swipes inconsistently and in the wrong direction on the first-
  generation remote.
- **Clickpad edge presses / arrows**: `UIPress` `.upArrow/.downArrow/.leftArrow/.rightArrow`.
  Clicking, and on the first-generation remote tapping, the edge of the surface
  makes one. A press with no thumb on the surface is one step with no threshold,
  and held it repeats after 450 ms, then every 180 ms. UI-test remote presses
  arrive this way.
- **Presses and the thumb** are settled by `PressArbiter`, which the self-tests walk
  through every ordering. The second-generation clickpad reports a resting thumb
  as a touch, and the first-generation pad reports an edge tap as an arrow press,
  so a press can belong to a click or to a swipe:
  - A press is the swipe's own **edge contact**, read twice, only if the touch
    moved focus within 150 ms before the press began, or while it was held. It is
    dropped. This holds with no thumb left on the surface too.
  - Any other press is a click: it counts once as it is released. Several clicks
    under one resting thumb each count, and a swipe earlier in the same touch does
    not stop later clicks counting.
  - If the thumb moved (more than 16 points) between the press and its release, a
    swipe may be starting, and the touch's end decides: one step if the touch did
    not swipe. A click still waiting is settled before the next press.
  - Held for 450 ms under a still thumb, a press steps and repeats every 180 ms
    until released; a swipe that moves focus stops the repeat. With no thumb, a
    press steps at once and repeats after 450 ms.
- **Trace**: the last 3,000 touch, press and focus events are kept in the app's
  caches, `Library/Caches/input-trace.txt`, so a swipe that went wrong can be read
  back from the device.
- Select, Menu and Play/Pause are untouched.
- Input is ignored while the full-screen camera is up, including the rest of a
  touch that was already under way when it opened.

## Focus-engine veto

A container view controller around the band overrides `shouldUpdateFocus(in:)` and
refuses any update whose `focusHeading` is non-empty (the engine moving on its
own). Programmatic updates (`@FocusState` writes) carry no heading and pass.
`onMoveCommand` is not used on the band. Phonoscope keeps its own.

## The learned range

- Every touch that locks an axis (outside an unlocked dial) reports its **reach**:
  how far it travelled along that axis, in % of the pad (`max - min` of the
  coordinate over the touch). Reaches under 4% are noise and are not kept.
- The last 200 reaches are stored in `UserDefaults` under `nova.tv.swipeReaches.v2`
  (the first key, `nova.tv.swipeReaches`, held reaches read from the
  GameController values and is left as it was),
  on the device only. The app writes only what it measured, never a default, so an
  update or a reinstall over the top keeps it; nothing is sent to the dashboard.
- The range is the 5th to the 95th percentile of the reaches, which clips a stray
  brush at one end and a wild flick at the other. With `low` and `high` as those
  two: one item from `low`, two items from `low + (high - low) * 2/3`. So the lower
  two thirds of the range is one movement and the top third is two. A touch never
  moves more than two items (coasting is separate).
- `low` is held to 8...30% and the second step to at least 8% above it, so a
  resting thumb cannot move focus and one habit cannot make the remote unusable.
- Until 10 swipes have been seen the starting profile is used (12% and 40%); from
  10 to 40 swipes the learned profile is blended in linearly; from 40 on it is
  used as is.
- Everything else in distance follows from the first step `F`: the first step of a
  swipe that follows a step in the same direction within 350 ms is `0.7 F`; an
  unlocked dial steps every `0.7 F` vertically; a reversal is a back-off of
  `0.8 F` (at least 5%); a flick needs `0.5 F` of travel.

## Engine

Pure and time-injected (`RemoteSwipeEngine`). Distances are % of pad width.

| Constant | Value | Meaning |
|---|---|---|
| axis lock | 3% | Travel before the axis locks; the dominant axis must be at least 1.4x the other, and stays locked for the touch. |
| flick speed | 1.5 pad widths/s | At lift, a touch with no step yet and at least `0.5 F` of travel steps once. |
| coast | up to 2 | Extra items = floor((v - 1.5) / 1.5), gaps 110 ms then 170 ms. A new touch or press cancels it; it follows a row or a list and stops at its end, so a coast never changes column or panel (the flick's own step can, like a short swipe), and it does not follow a panel switch. |
| lean | 12 px | Lean of the focused control toward the swipe, `12 * easeOut(progress to the next step)`, released on every lift. |

Rules:

- Velocity is the signed axis speed over the last 80 ms of samples, in pad widths/s.
- A step moves the anchor forward by the travel it consumed. Each step is applied
  (focus moves) before the next one in the same swipe is judged, so the second step
  starts from where the first landed.
- A touch has at most two steps. Sideways, the second is a **panel switch** (see
  `specs/band-navigation.md`) from the panel the touch began in; up or down it is a
  second ordinary step. An unlocked dial has no panel switch.
- Reversal: once travel backs off from its peak by the reversal distance, the
  engine re-anchors at the turning point, needs the first-step travel again, and
  the flow bonus is dropped.
- Bounce: the engine asks the band whether the next step (or panel switch) would go
  anywhere. If not, it never steps; the control leans nearly the full 12 px and
  holds until lift or reversal.
- No flick or coast while a dial is unlocked, and nothing there can bounce.

## Done means

- Self-tests (DEBUG) with synthetic tracks: the one/two split at the learned
  thresholds and the two-step cap, the reach reported at lift, outlier clipping,
  the blend, persistence across a relaunch, plus the flick, coast, flow, reversal,
  panel-switch, bounce and dial cases.
- The UI tests in `UITests/LandscapeNavigationTests.swift` pass.
- On the set: after a few dozen swipes, one swipe moves one item most of the time
  and a long one moves two, without flicker.
