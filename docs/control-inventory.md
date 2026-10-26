# Nova Apple TV dashboard — custom UX component inventory

The reuse rule itself lives in the agent workspace's `AGENTS.md`, under "UI
implementation conventions": when a surface already has a custom component for
a control, find and reuse it rather than dropping to a native SwiftUI
`Slider`/`Toggle` or other platform default. This file is the inventory for that
rule on this surface.

Keep it current when adding, renaming, or retiring reusable controls. Search
the named component before introducing a one-off equivalent, and preserve each
component's preview/commit, accessibility, focus, and persistence conventions.

- `ControlButton`, `IconControlButton`, `RibbonTitleButton`, and
  `VerticalToggleSwitch` — `NovaAppleTVDashboard/DashboardComponents.swift`.
  These are the standard focus-aware tvOS actions and toggles used throughout
  dashboard zone and climate controls.
- `ControlChrome`, `PanelFrame`, `ReadoutTile`, and `EmptyStatePanel` —
  `NovaAppleTVDashboard/DashboardComponents.swift`. These define the shared
  focus/active chrome and panel surfaces.
- `RotaryEncoder` and `RotaryChannel` — `NovaAppleTVDashboard/RotaryEncoder.swift`.
  Shared relative stepping, slider/selector/toggle rings, wrap/clamp, preview,
  Select commit, Back cancel, five-second idle commit, and focus-loss commit.
  Scene suspension discards drafts. Ring positions remain stable when hidden.
  `RotaryKnobFace`, `RotaryTitleArc`, and `RotaryLEDs` supply the shared
  recessed bezel, machined face, title and lights; `RotaryIndicator` also
  supplies the status orb's dial indicator.
- `ColorEncoder`, `TemperatureEncoder`, and `TimerEncoder` — same-named Swift
  files. Wired variants, reused at full size and in `QuickAccessColumn`.
  Commands go through DashboardStore and the web server's existing endpoints.
- `ThemeHostControls` — `ThemeHostControls.swift`. The theme cycle button and the
  HOST button (with its text-entry modal), built from `IconControlButton`; left of
  the orb on the TV, at the foot of the orb's sidebar on the phone.
- `TouchEditPad` and `PhoneCanvas` — `TouchInput.swift`, phone only. The touch
  pad the unlocked orb is driven by (drag steps, tap locks) and the scaled
  canvas the band is drawn on (`specs/ios-touch-app.md`).
- `RotaryEncoderTouch.swift` — phone only: the web dial's touch rules on
  `RotaryEncoder` (knob turns by angle, tap cycles LEDs, ring thumbs drag, tap
  outside locks). Every dial built on `RotaryEncoder` gets them.
- `LandscapeGroup` and `AdvancedFold` — `LandscapeGroup.swift`.
  Joined horizontal group chrome and an opt-in advanced section. The TV
  dashboard does not mount advanced panels or the fold trigger.
- `BandMap` / `BandCursor` (where a swipe goes) — `BandMap.swift`; `RemoteSwipeEngine` (how a touch becomes steps) — `RemoteSwipeEngine.swift`.
  The current layout owns its focus targets in `LandscapeFocusLayout.swift`.
  First movement is immediate; repeats settle for 300 ms with no acceleration.
- `VerticalBrightnessSlider` (legacy, no longer mounted) —
  `NovaAppleTVDashboard/LightingControlsView.swift`. This is the custom
  remote-driven lighting brightness control.
