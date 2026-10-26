# Temperature dial (TV and phone)

`TemperatureEncoder.swift` on `RotaryEncoder`: the aircon and bedroom heater dials on
the climate system panel and in Quick Access. The web knob is the reference
(nova-ha-dashboard `specs/temperature-encoder.md`); this file says where the TV and
phone follow it.

Adeline, 2026-10-25: "temperatures don't need labels. and reverse the current and
target temps in both apps to match the web layout. also, it's not using the
configured temperature ranges." The dial showed the target twice while unlocked
(large on the face, and "TARGET 20.5°" under the lights), and the line under the
lights read "AUTO · 22.0° ROOM" while locked.

## Face

- **The target, large, above the mode lights.** `22% of the knob's size`, the web's
  share (its clamp to 28–48px does not carry to the TV's point sizes).
- **The room temperature, smaller, below the lights**: `15%` of the size. It is the
  only thing on that line. With no reading it prints `--`.
- **No labels and no degree signs**: no TARGET, no ROOM, no °, and no mode on the
  face (the lights are named underneath, and the mode is written under the dial).
- Both print as the web's `formatTemperature`: `22.5`, a whole number as `22`.
  **The decimal part is half size, its top level with the digits'**
  (`RotaryFaceText`).
- While a ring is being worked on (the remote's selected ring, or a thumb under a
  finger on the phone), the line under the lights names the ring and its value
  instead, as before; the room temperature comes back when it is released.

## Range

- **Hard limits**: the aircon entity's `min_temp`/`max_temp` (the model's own
  defaults when the entity omits them; 16–30 °C with no entity or an inverted
  pair); the
  heater's 5–30 °C (the web's `BEDROOM_HEATER_MIN_TARGET_C` /
  `BEDROOM_HEATER_MAX_TARGET_C`; the TV used 16–30 before).
- **The household's knob range**, `preferences.climateTargetRange: { min, max }`
  (the web's climate config, "Knob range"), applies to both dials: each sweeps the
  intersection of it and its own hard limits, or its hard limits if they do not
  overlap. Unset means the hard limits.
- **A stored target outside the range is shown clamped and never written back.**
  Only a turn sends a target (the web's `clampTargetForDisplay`; no user gesture,
  no write).

## Done means

- Both apps, both dials: the target once, the room temperature once, no labels.
- With a knob range set on the web, the TV and phone dials stop at its ends.
- The TV build and its remote model are otherwise unchanged.
