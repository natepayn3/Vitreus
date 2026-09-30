-- Key binds for the Vitreus shell. Loaded from hyprland.lua (`require("hypr_vitreus")`) after the rest of the binds, so
-- where a key is also bound earlier, it is unbound first and bound again here.
-- Vitreus is driven with `pleamar --say <scene> "<line>"`: `emit <event>` or `fact <name> <value>`.

-- SUPER + Space opens or closes the launcher (apps, files, commands, emoji, clipboard, wallpapers).
hl.unbind("SUPER + Space")
hl.bind("SUPER + Space", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit launch_toggle\""))

-- SUPER + SHIFT + Space opens or closes Settings.
hl.unbind("SUPER + SHIFT + Space")
hl.bind("SUPER + SHIFT + Space", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit settings_toggle\""))

-- SUPER + L locks with the pleamar lock screen.
hl.unbind("SUPER + L")
hl.bind("SUPER + L", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say lockscreen \"fact locked true\""))

-- SUPER + B opens the wallpaper picker: every wallpaper as a glass hexagon.
hl.unbind("SUPER + B")
hl.bind("SUPER + B", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit gal_toggle\""))

-- SUPER + TAB opens or closes the workspace overview.
hl.unbind("SUPER + TAB")
hl.bind("SUPER + TAB", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit ov_toggle\""))
