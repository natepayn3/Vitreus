# The Vitreus add-on style

What a panel should look and feel like, so that an add-on sits beside the Control Center and News & Weather. `addon.plm` is a working sample of every rule here, and `addon-pencil.plm` holds the drawing: import it and use it. An add-on may use its own artwork (an `.svg` or `.png` of its own is fine), but the closer it is to this, the less it stands out.

## Being included in Vitreus, and not

**Anyone is free to write an add-on their own way.** Put it in `~/.config/pleamar/vitreus-addons/<id>/`, share it from your own repository, and it works and looks however you made it. Nothing here is required for that.

**An add-on that is included in Vitreus itself** (in `addons/`, in this repository, listed in Settings > Add-ons, off until the user switches it on) follows this style, so the shell feels like one thing. Before proposing one, check it against this list:

- It looks and moves as the sections below say: the boiled pencil that rests unless used, the Control Center's switches and sliders, even margins from the rectangle the shell gives it, and the content arriving the way the Control Center's does. Using `addon-pencil.plm` is the easy way to be right.
- Its zones are gated on `shown`, its text fields go through the shell, and it stays well under the scene's size limit (`pleamar --check` prints it).
- It keeps secrets as described under Secrets, says in its README how, and does not send anything anywhere the user did not set up.
- The `author` in `addon.toml` and the README credit whoever the idea or the code came from, and its licence is compatible with this repository's (MIT).
- It runs without an account or a device the reviewer may not have, or it has a way to try it (a demo mode, for example).
- It has a README with screenshots, and says if an AI assistant helped.

A proposal that follows the style but is not quite there is a conversation, not a rejection: the aim is that it is right, not that it is perfect first time.

## The boiled pencil

Everything is drawn as a hand would: a line is drawn twice, the second a hair off and fainter, and a stroke wobbles a little. Lines are redrawn about eight times a second (`let fr = floor(time * 8)`), which is the "boil".

- **Only what is being used moves.** A piece of drawing rests unless it is on or under the pointer. Every pencil component takes `f`, the frame its lines are drawn on: pass `f: if(on or hover, fr, 0)`. At rest it keeps its crooked lines but stands still. (Idle CPU matters: nothing should boil in a panel nobody is touching, and the scene draws nothing at all while its panel is shut.)
- **Never name `time`.** A scene that names pleamar's `time` anywhere is kept awake for good, panel shut or not (`pleamar --report` says "animating 100%"). Boil on a clock of the scene's own that runs only while the panel shows, as the sample does (`prop ax_clk = 0`, `spin ax_clk by if(shown > 0.5, 1, 0)`, `floor(ax_clk * 8)`), and give the surface `open: shown > 0.5` so a shut panel has no surface on any monitor.
- **Keep the stroke inside its clip.** A wobble moves a line about a pixel. Draw an outline inside its box by half its stroke plus the wobble (`x + 2.6 * u`, `w - 5.2 * u`) or a list's clip will cut it across a pixel.
- **Draw, don't stamp.** Icons are strokes (`PIcon`), not images. A user's own `.svg` / `.png` is allowed in place of one, and is drawn as it is (it does not boil).
- **Colours come from the palette** (`ink`, `faint`, `mint`, `onmint`, `card`, `off`, `alert`); never a literal colour. `mint` is the accent: it marks what is on. A colour worked out
  from the thing itself (a light's own hue, `rgb(…)` from facts) is not a literal, and is fine where it stands for that thing. A literal that has to be there (a hue bar's rainbow) is marked on its
  line, `// lint: colour <why>`, for the reviewer to see.
- **Icons are drawn in pencil**, never with an icon font (Material Symbols, Nerd Fonts): `PIcon` here, a table of strokes of your own drawn the same way, or SVGs of your own.

## Controls

Copy these numbers; they are the Control Center's.

- **Switch** (`PSwitch`): a track 22 high, **34 wide off and 38 wide on**, its right end fixed, so it grows leftwards. Off it is a dark hollow (`off`, with a shadow along the top); on it is raised and lit from inside in `mint` with a glow. The knob is 17 across, **a circle when off and a rounded square when on** (corner 8.5 off, 6.5 on), and it stretches (wider and shorter) while it travels. The tile fills with the accent from the switch (`PFill`).
- **Slider**: `PSliderCC(x0, y, w, lv, hot, k, h, mute)` is the shell's own, as the Control Center's volume draws it (a smooth outline, thick pencil columns, a clean ring for the knob, still until the pointer is on it); use it for a full-size slider. The older ones (`PSlider`, `PSliderMini` at the foot of a card; `PSliderTint`, `PSliderMiniTint` pencil the level in a colour of your choosing, for something with a colour of its own): a pill track in a crooked double outline, the level coloured in with the pencil in tight columns (`mint`), and a ring for a knob (drawn twice, bigger than the track is thick, with a faint fill). Dragging it, or pressing anywhere on its track, sets the level. Send changes at most every 150 ms.
- **A card**: 12 corner, a pencil outline, an icon at about 1.35 times the 24 px grid on the left, the name and a status line centred on the card's middle, the switch top right. A click on the card toggles it. Anything further (a right click, a slider) is a zone declared after the card's, so it is on top.
- **Buttons and pills**: a disc or pill of `ink` at 8 to 18 percent with the label in `ink`, `mint` on hover; the same shape as the shell's.

## Themes

The shell can wear a different shape (Settings > Theme), and the add-on tells which through its `look` fact (`0` Glass, `1` Retro, `2` UwU, `3` Cyber, `4` Milkbox, `5` Proxy). The colours already follow the theme through the palette. The shape of a control does not, unless the control takes it from the theme's own pieces, so:

- **Draw "pick one of several" controls (tabs, presets, a mode) with `PThumb`** from `addon-theme.plm` for the lit piece that slides under the chosen label, and keep the track, dividers and labels yours. On Proxy it is the HUD's slanted slab, a little taller than its track; on the other themes it is the pill with a glow. Do not draw your own lit pill: it would stay a pill on every theme.
- **A new theme means a new case in the theme's pieces, not in every add-on.** An add-on that uses only `PThumb`, the pencil and the palette needs no change when a theme is added.
- **Under Proxy the pencil should not wobble.** The HUD is crisp lines: where a piece of drawing boils (see "The boiled pencil"), hold it still when `look == 5` (`f: if(look == 5, 0, ...)`).
- Copy `addon-theme.plm` into the add-on's folder next to `addon-palette.plm`, as you do the palette.

## Layout

- **Use `u`, not pixels.** Declare `let u = 1.1` and write every length as `N * u`.
- **The shell gives you the rectangle** (`slot_x`, `slot_y`, `slot_w`, `slot_h`): below the title bar, inside the glass by an even margin on every side, and clear of the add-on pill. Draw inside it, and work everything out from its size: the user can resize the panel.
- **Centre text on its card** (name and status line as a pair), not on a guess.
- **Grids** are columns that fit (`floor((width + gap) / (cell + gap))`, up to what you want) with the same gap down and across.

## Moving in

What is inside arrives as the Control Center's does: after the glass has started, one piece after another, each rising about 12 units as it fades in, each on its own spring (200, 380 and 520 ms: `en1`..`en3` in `addon.plm`). They start 200 ms after the panel is out: a scene that was shut draws nothing, so its first frame is a long one, and a spring started in it is over at once. The sample holds the whole recipe, including the `wk` spring that keeps frames coming while the content waits.

## Input

- **Gate every zone on `shown`** (`active: shown > 0.5`): the scene has a copy on each monitor and only one shows.
- **Declare zones in the order you want them stacked**: a later zone is on top.
- **Text fields** are typed through the shell (see `addon.luau`): one field at a time, one line, and Ctrl+V works. Do not add a Paste button.
- **A held drag must not be lost**: while a drag is held, make its zone cover the whole screen (`size: if(held, 4000, 30 * u)`).

## Size

A scene may hold **65 536 properties**, and every copy of a model's rows counts, whether the row is used or not. So draw an icon set from one table of strokes looked up with `pick(k, …)` (see `PIcon`) and cap how many rows a model holds. Check with `pleamar --check addon.plm`: it prints the number. A panel that is too heavy does not just run slowly: its frames stop it answering the pointer.

## Secrets

If the add-on keeps a token or a password, keep it as the shell keeps its own: in the add-on's data folder (private to the user), the files mode 600 (`chmod`), and passed to a program through a file (`curl -K`), never on its command line. Say honestly in the README how it is stored.

## Credit

The `author` in `addon.toml` is shown on the add-on's card in Settings. If the add-on builds on someone else's, credit them there and in the README, and keep their licence's notice.
