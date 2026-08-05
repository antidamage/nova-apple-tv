# Nova Apple TV dashboard — custom UX component inventory

The reuse rule itself lives in the repo-root `AGENTS.md` under "UI
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
- `VerticalBrightnessSlider` —
  `NovaAppleTVDashboard/LightingControlsView.swift`. This is the custom
  remote-driven lighting brightness control.
