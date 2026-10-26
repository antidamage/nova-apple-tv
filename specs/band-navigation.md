# Band navigation

Where a swipe goes from each control on the landscape band, worked out the way a
person works it out: by where things are on screen. Plan:
`we-re-working-on-the-imperative-wozniak` (2026-10-15), then the panel map.

The code is `BandMap.swift` (the model and the rules) and `BandCursor` (one
person's place on it). The app and the self-tests drive the same cursor, so what
the tests prove is what the remote does. `BandMapSelfTests.swift` holds the checks.

## The picture

Left to right on the screen:

- the **theme selector**, off screen left of the orb: the theme cycle button over
  the HOST button (`specs/theme-mode-selector.md`, `specs/host-settings.md`). It is
  only drawn while the remote is on it;
- the **status orb**, which is not a panel;
- the clock panel, which has nothing to select and so is not on the map;
- **Quick Access**: the all-lights dial, over its four buttons (ON, DAY, WHITE,
  OFF), over the aircon and heater dials side by side;
- **Home**: a title strip (a label), a list of rooms, and the selected room's
  controls (a dial over its four buttons);
- **Systems**: a title strip, a list (Climate, Outside, Network, Reminders,
  Phonoscope), and the selected system's controls: the two climate dials, or
  power / camera / weather, or the network panel, or the timer dial.

The model: a panel is a row of columns, a column is a stack of blocks, a block is a
row of controls. A lone dial is a block of one. Each control has a position
(x across, y down); the properties below are checked against those positions.

## The rules

1. **One short swipe, one neighbour.** Left and right move along a row, one control
   at a time. Up and down move to the next block in the column, landing on the
   control nearest across (the left one when two are equally near).
2. **Down from a dial is its button group,** and up comes back to the control the
   swipe came from, not whichever is nearest. The memory lasts until the next
   sideways move.
3. **Sideways at the end of a row, or from a lone control, goes on to the next
   thing to the side.** Inside Home and Systems that is the next column (the list
   for the controls); when the panel has no more columns, it is the next panel.
4. **Entering a panel** from the left lands on its list's selected row; from the
   right, on its controls. The group titles are labels: they cannot be focused,
   selected or collapsed, and both groups are always open (Adeline, 2026-10-16).
5. **The longest swipe, left or right, switches panel** from the one the swipe began
   in, landing as in rule 4. Up and down never switch panel.
   Past the last panel it does nothing.
6. **The orb** takes one short swipe right to leave. One short swipe left from the
   first panel is the orb again. One short swipe left from the orb is the theme
   selector, at the mode in force; up and down walk its modes, and right from any
   of them is the orb again (Adeline, 2026-10-23).

7. **A list row is selected by swiping into its controls.** Right from a row makes it
   the selected room or system and lands on the first control; Left comes back to
   the same row. Select does the same without moving. Phonoscope is a row of the
   Systems list that opens its own surface, so Right from it goes to the selected
   system's controls and selects nothing.

## Scrolling

Adeline, 2026-10-23: the focused stack centres itself where there is room, and
goes as far as it can where there is not. The focused control's column is centred
(`scrollTo` clamps at the band's ends). On the orb or the theme selector the band
scrolls all the way back to its start, so no panel is left drawn over the orb.

## Checked

For every control in 16 arrangements of the band (each room selected with each
system selected), every move, and every place reached from the orb.

- a swipe moves toward where it points (right is to the right, up is above);
- up and down stay in their column and panel;
- along a row a swipe moves exactly one control;
- a move within a column comes back the way it went; a move between a panel's
  columns comes back to the column it left;
- every control can be reached from the orb, and the orb from every control.

`BandMapSelfTests` also pins the named cases: the orb, the quick-access buttons and
climate dials, panel edges, rooms, systems, long swipes, and that the group titles
are not stops.

## Seeing the focus

The control the remote is on wears a thick outline in the theme's highlight
colour, standing just outside it with a soft glow (`FocusOutline`): the orb, the
dials (in the unlock colour while a dial is unlocked), the buttons, the list rows
and the camera, weather and network panels.

## Feedback

A swipe with nowhere to go is a bounce: the focused control leans toward the swipe
and holds until lift. A long swipe with no panel beyond does the same at its
second step.
