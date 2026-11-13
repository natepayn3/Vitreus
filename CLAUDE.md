# Working on Vitreus

Vitreus is a pleamar shell: `vitreus.plm` (the scene) and `vitreus.luau` (its logic), with `pages/*.plm` and `logic/*.luau` beside them. Run `pleamar --check vitreus.plm` after every edit
to a scene (`pleamar --docs reference` has the language; never guess a keyword).

## Test in the rig, not on the desktop in use

`dev/rig start` runs a copy of the whole shell (the working tree, uncommitted edits included, and a copy of its data) in a headless pleamar-wm, with its own config, data and cache folders.
`dev/rig say "get fact" "emit event"` talks to it, `dev/rig sync` copies edits into it (it reloads in about 2 s), `dev/rig log`, `dev/rig stop`. `RIG_PNG=file RIG_AT=5 dev/rig start` saves a
picture, `RIG_INPUT="x,y@ms down@ms up@ms"` moves and clicks the mouse. Read the header of `dev/rig` for what it shares with the desktop (do not press power, lock or restart actions in it).
It has no Hyprland: gaps, borders, the Hyprland page and glass blur cannot be seen there.

## Every commit passes dev/verify

Nothing lands on main (a commit of ours, or a pull request merged) until `dev/verify` passes for it: `dev/verify` for this checkout's HEAD (`--dirty` with uncommitted edits),
`dev/verify 71 72` for pull requests, merged onto origin/main in that order. It tests against **origin/main** and **pleamar's own `main`** (built into ~/.cache/vitreus-verify),
never the experimental pleamar that may be installed in ~/.local/bin, and the shell must survive a **full restart** (compositor, shell and every scene stopped and started
again on the data the first run left). It runs in its own process namespace, so the shell's `pkill -f` patterns cannot reach the desktop in use. Read its header for the stages.

## Settings pages

Every Settings page follows `pages/SETTINGS-STYLE.md`: which control a setting gets (switch, slider, the `SetPick` picker, picture tiles, stepper), the card and row measurements and the
type scale. Read it before adding a page or a setting. A pill is only ever a verb (Reset, Apply, Test); a row of choices is a `SetPick`.

## Gotchas

- **A handler reads shared globals as they were when it was made.** A `logic/*.luau` module's `on(...)` handler reading a global table made in `vitreus.luau` (e.g. `dock_fx.enabled`) gets
  the old value, while writes reach the real table. Keep state in a local of the module and only write to the shared table. (This made the dock-room switch stick, and left a stale flag.)
- **A fact the logic sets does not fire `on("fact:...")`.** Only the scene (a rule) or an outside `--say` does: call the function directly.
- **Saving a scene and its logic one after the other can leave the old logic running** (`the previous one stays as it was`) while the scene has reloaded and cleared its models (the add-on
  pill goes empty). After editing both, `touch` a logic file, or save the logic file last, and check the log.
- **A layer surface that reserves room (`reserve:`) shrinks the shell's own full-screen surface** (surfaces with no zone of their own are placed in what is left). Room for the docks is kept
  through Hyprland's `gaps_out` (`dock_fx`, `iris_fx.gaps_code`) and pleamar-wm's `fr.*`, not by a second surface.
- `vitreus.luau` is at Luau's limit of 200 locals: new top-level state is a global table (`bar_fx`, `dock_fx`, `wph`), not a `local`.
- The gaps Vitreus sends to Hyprland are kept in `vitreus_colors.lua`; the room for the docks is deliberately not written there (it would be read back as the original gaps).
- `hyprctl` is the real one only on Hyprland; under pleamar-wm it is `pleamar-wm/hyprctl` and answers `monitors` and `activewindow` only.
- **An add-on scene is laid out below what the bar reserves** (62 at the top of the Island): the shell sends `slot_y` minus `ax.yoff`. Its rectangle is also inset by `axs.m` on every side.
- **A scene that draws nothing while shut gets a long first frame when it wakes**, and a spring started in it is over at once: start the content's springs 200 ms later and keep a prop moving meanwhile
  (`wk` in `addons/_template_drawer/addon.plm`). The rules for an add-on's look are in `addons/_template_drawer/STYLE.md`.
- **A scene may hold 65 536 properties, and a model's copies are built for its `max`** (not for its rows): an icon set is one table of strokes, not one drawing per icon.
