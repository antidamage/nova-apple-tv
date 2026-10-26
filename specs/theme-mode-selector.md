# Theme mode selector

Adeline, 2026-10-23: "I do want a theme mode selector (dark/light/auto) same as
on the web version. put it to the left of the status orb, offscreen. it'll only
show if the user swipes left from the status orb to get to it, and going back to
the status orb will hide it."

Adeline, 2026-10-23, later: "make the theme buttons into a single cycling icon
like on the web dashboard", with a HOST button beside it
(`specs/host-settings.md`). Plan `research-everything-and-make-quiet-bumblebee`.

## What it sets

The web dashboard's per-device theme override (`nova-ha-dashboard`,
`specs/theme-override.md`), on this TV:

| Row | Means |
| --- | --- |
| SHARED | Follow the shared theme selection from the config page. The default. |
| AUTO | Dark while the sun is down, light while it is up, on this TV only. |
| LIGHT | The light variant, on this TV only. |
| DARK | The dark variant, on this TV only. |

- Kept on the TV (`UserDefaults`, key `nova.tv.themeOverride`; empty is SHARED)
  and never sent to the server, as the web keeps it in that browser.
- AUTO resolves by the sun exactly as the shared `auto` does.
- One icon button, as the web's (`nova-ha-dashboard` `specs/theme-override.md`).
  Select cycles SHARED → AUTO → LIGHT → DARK → SHARED, and each press applies at
  once: the dashboard eases into the new variant over 0.6s from the last theme
  the server sent, without waiting for the next poll
  (`DashboardStore.setThemeOverride`).
- The icon and caption show the mode in force. SF Symbols stand in for the web's
  lucide set: `circle.lefthalf.filled` (SHARED), `sun.horizon` (AUTO),
  `sun.max` (LIGHT), `moon` (DARK).

## Where it is

- A column in the same group frame as Home and Systems, titled THEME, placed
  left of the orb's sidebar and off screen: the theme button over the HOST button
  (`ThemeHostControls`).
- Swiping left from the orb lands on the theme button, and the whole dashboard
  slides right (0.24s) to bring the column on screen. Down reaches HOST, up goes
  back. Right from either, or Back, returns to the orb, and the dashboard slides
  back so the column is off screen again. While it is shown the band is scrolled
  to its start.
- On the phone the same two buttons sit at the foot of the orb's sidebar,
  always on screen (`specs/ios-touch-app.md`).
- The navigation rules are in `specs/band-navigation.md`; the model is
  `BandPanel.theme` and `ThemeMode` in `BandMap.swift`.

## Checked

`BandMapSelfTests`: left of the orb is the theme button whatever mode is in
force; HOST is under it and both ends hold; right from either is the orb; nothing
is left of them; a long swipe left reaches them from the orb only; both are
reachable and the orb is reachable from both.
