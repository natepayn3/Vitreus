# Themes

Every theme is a small `.toml` file: eleven colours, a typeface and how round the window corners are. Vitreus's own are here
(`retro.toml`, `uwu.toml`, `cyber.toml`, `milk.toml`, `doodle.toml`, `paper.toml`, `proxy.toml`, and `glass.toml`, which only carries
Glass's font and corners because the wallpaper is its palette: Iris recolours it from your wallpaper, with a legibility floor on the text).

## Making your own

1. Copy `_template.toml` to `~/.config/pleamar/vitreus-themes/` under any name (`sunset.toml`) and change it. Every setting is
   explained in the template.
2. Open **Settings > Theme** (or open the page again): your theme is a card at the end of the strip. Pick it.

A file that cannot be read is named in the line under the cards and left out; the others are not affected. `base` chooses the shape
the colours are worn on (`glass`, `retro`, `uwu`, `cyber`, `milk`, `doodle`, `paper` or `proxy`); a theme cannot add shapes of its own.
A theme's typeface can be changed on the Theme page, and the choice is remembered per theme in `fonts.json` in the data folder.

`bin/vitreus-themes` reads the files and leaves the list in `themes.json` in the data folder
(`~/.local/share/pleamar/vitreus`), which the shell, its font setup and the window-corner code all read. Your files stay where they
are when Vitreus updates.
