# Dashboard host setting

Adeline, 2026-10-23: "it will need to include configuration inside the generic
iOS settings area for determining what the dashboard's host URL is", and "see if
you can add the same dashboard host configuration setting to the apple tv app
settings inside OS settings". For the TV: "in-app fallback next to the theme
selector. for now make it a single button that shows a pop-up text entry modal."

Plan `research-everything-and-make-quiet-bumblebee`.

## The setting

One value, the dashboard host URL, shared by both apps.

- Kept in `UserDefaults` under `nova.host.dashboardURL`. Empty or missing means
  **build default**: the Info.plist `NovaDashboardBaseURLs` list, then
  `http://nova.local`.
- When set, it is the only base tried; the build-default list is not appended
  after it, so a wrong entry fails visibly instead of being masked by a fallback.
- Normalised before use: whitespace trimmed, a bare host (`nova.local`,
  `nova.local:3000`) gets `http://` in front, one trailing `/` dropped.
- Valid means `http` or `https` with a non-empty host. An invalid value is
  ignored and the build default is used; the in-app editor refuses to save one.
- Read on every request through `AppConfig.dashboardBaseURLs` (no longer a
  `static let`), so a change applies on the next request without a relaunch.
- The camera base follows the dashboard host unless `NovaCameraBaseURL` is set,
  as before.
- Model: `HostSettings` in `HostSettings.swift`. `HostChangeMonitor` notices a
  change (the Settings app, or the modal) and moves the one long-lived
  connection, the voice event stream, to the new host; polls need nothing.

## iOS: the Settings app

`Settings.bundle/Root.plist`, under the app's entry in the iOS Settings app:

| Item | Specifier |
| --- | --- |
| DASHBOARD group title | `PSGroupSpecifier`, footer "Leave empty to use http://nova.local." |
| Dashboard host | `PSTextFieldSpecifier`, key `nova.host.dashboardURL`, URL keyboard, no autocapitalise, no autocorrect, default empty |

The app re-reads on `UserDefaults.didChangeNotification` and on returning to the
foreground, and the stores pick the new base up on their next poll.

## tvOS

The same Settings.bundle ships in the TV app. Whether tvOS's Settings app lists
and saves it is checked on the set and recorded below. Either way the TV has an
in-app editor:

- A **HOST** button sits under the theme button, in the off-screen column left
  of the orb (`specs/theme-mode-selector.md`). The phone has the same button, at
  the foot of the orb's sidebar, as well as the Settings app entry.
- Select opens a modal: a text field (tvOS on-screen keyboard) pre-filled with the
  stored value, a line showing the host in use, and SAVE / CANCEL. Save refuses
  an invalid value and says so; an empty value saves as build default.

## Done means

- iOS: entering a host in Settings and returning to the app switches every
  request to it without a relaunch; clearing it goes back to `http://nova.local`.
- tvOS: the HOST modal does the same.
- `HostSettingsSelfTests` cover normalising, validation and the empty default.

## Checked on the set

- tvOS Settings app shows the bundle: *not yet checked*.
