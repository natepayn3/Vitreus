# The Settings' style

Every Settings page is built from the same few parts. A new setting picks its part from the table; it does not invent one.

## Which control

| The setting is… | Use | Component |
|---|---|---|
| on or off | the switch | `SettingsSwitch` |
| an amount (a percentage, pixels, a speed) | the slider | `PSlider` |
| one of many steps along a scale (more than six) | the slider with stops, its value named at the right (Idle's times) | `PSlider` over a row of dots |
| one of two to six named choices | the picker: one slot, the words in it, a shaded thumb that travels to the chosen one | `SetPick` |
| one of several things that are easier seen than named | picture tiles (Bar position, clock Layout, Theme) | drawn on the page |
| a time of day | the stepper (− value +) | drawn on the page |
| something that happens once (Reset, Apply, Test, Browse) | a pill | `PPillOutline` |

**A pill is always a verb.** A row of pills to choose from is a picker instead: the slot shows the choices belong together, and the thumb shows which one is on.

## The picker

`SetPick(x0, y, pitch, n, h, sel, hot, pu)` draws the slot and the thumb; the page draws each word and keeps each choice's zone and rule. `sel` is the chosen index
itself (a fact, not a spring): the thumb's leading edge goes there in 90 ms and its trailing edge in 280 ms, so it stretches, flattens and gathers, as a slider's knob does.
A grid adds `nr, rp, row`. `on` 0 hides the thumb when nothing is chosen. Under each word, a box at `7% * zone.hover` is the only per-choice drawing.

Choices made in a `repeat` cannot have their zones read from outside it: put a plain zone under the slot (`name_sl`), before the repeat, and pass its `.hover` as `hot`.

## The page

- Cards are 438 wide, corner 14, with a hairline edge (`stroke: 1 * pu`, ink at `hair`, after the veil box), on `spx + 219`; content starts at `spx + 14` and controls end at `spx + 424`.
- **14 inside every card, on all four sides.** The first row's top (a picker's slot, a pill, a label's cap height) is 14 below the card's top, and the last row's bottom
  (a pill's edge, the descenders of a hint) is 14 above the card's bottom, as the content is 14 in from either side. Nothing touches or crowds an edge.
  A single row with a hint (label at `ty - 6`, hint at `ty + 8`) makes a card 58 tall, `ty` at its top + 29. A plain row (a slider, a picker) has its middle at the top + 26.
- **8 units between cards**, always: the bottom of one card to the top of the next. A loose caption or hint between two cards keeps 8 above and 8 below its line box. A page's length (`xx.h` in vitreus.plm) follows its last card.
- A page opens with what it is: a title card (19 / 700), a one-line hint, and the page's master switch when it has one.
- **A section's name sits above its card, never inside it**: small caps (16 / 700, faint) at `spx + 14`, its middle 13 above the card's top, with 17 from the
  card above's bottom to that middle (so 30 between the two cards). Every section on a page is named the same way, or none is.

## The words

| | Size | Weight | Colour |
|---|---|---|---|
| Card title | 19 | 700 | ink |
| Row label | 17 | 600 | ink |
| Hint under a label | 13.5 | – | faint |
| Section caps | 16 | 700 | faint |
| A slider's value | 19.5 | 700 | mint, right-aligned at `spx + 424` |
| A word in a picker | 14 to 15.5 | 600–700 | ink, mint when chosen |

A label says what the setting is, in two or three words. The hint says what changes, in one line; leave it out when the label is enough.

## Sliders

A slider with a hint is stacked: label and value on one line, hint under, the slider below at the full 410. A slider with no hint sits on its label's line, between
the label and the value.
