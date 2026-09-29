-- Key binds for the Vitreus shell. Loaded from hyprland.lua after hypr_style.lua (`require("hypr_vitreus")`), so
-- where a key is also bound there (Synoptik's), it is unbound first and bound again here.
-- Vitreus is driven with `pleamar --say <scene> "<line>"`: `emit <event>` or `fact <name> <value>`.

-- SUPER + Space opens or closes the launcher (apps, files, commands, emoji, clipboard, wallpapers).
hl.unbind("SUPER + Space")
hl.bind("SUPER + Space", hl.dsp.exec_cmd("pleamar --say vitreus \"emit launch_toggle\" || qs -c Synoptik ipc call launcherosd toggle"))

-- SUPER + SHIFT + Space opens or closes Settings.
hl.bind("SUPER + SHIFT + Space", hl.dsp.exec_cmd("pleamar --say vitreus \"emit settings_toggle\" || qs -c Synoptik ipc call settings toggle"))

-- SUPER + L locks with the pleamar lock screen, falling back to Synoptik's if that scene is not running.
hl.unbind("SUPER + L")
hl.bind("SUPER + L", hl.dsp.exec_cmd("pleamar --say lockscreen \"fact locked true\" || qs -c Synoptik ipc call lockscreen lock"))
