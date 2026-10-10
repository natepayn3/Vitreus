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
hl.bind("SUPER + B", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit wp_picker_toggle\""))

-- SUPER + D opens or closes the Desk.
hl.unbind("SUPER + D")
hl.bind("SUPER + D", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit desk_toggle\""))

-- SUPER + TAB opens or closes the workspace overview.
hl.unbind("SUPER + TAB")
hl.bind("SUPER + TAB", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit ov_toggle\""))

-- The brightness keys, again: the same brightnessctl step as hyprland.lua's, and then the new level told to the shell at once (as a share of the
-- backlight's maximum), so its pop-up follows each press; the brightness service only looks every 700 ms.
hl.unbind("XF86MonBrightnessUp")
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd([[PATH="$HOME/.local/bin:$PATH"; f=$(brightnessctl -e4 -n2 -m set 5%+ | awk -F, '{printf "%.4f", $3/$5}'); pleamar --say vitreus "emit bright_key $f"]]), { locked = true, repeating = true })
hl.unbind("XF86MonBrightnessDown")
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd([[PATH="$HOME/.local/bin:$PATH"; f=$(brightnessctl -e4 -n2 -m set 5%- | awk -F, '{printf "%.4f", $3/$5}'); pleamar --say vitreus "emit bright_key $f"]]), { locked = true, repeating = true })

-- What starts with the session: pleamar runs ~/.config/pleamar/autostart (the Vitreus scene, lock screen and desktop widgets), and the
-- daemons the shell relies on (wallpaper, idle lock, clipboard history). Hyprland's PATH has no ~/.local/bin, hence the export.
hl.on("hyprland.start", function ()
    hl.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --autostart")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("awww-daemon")
    hl.exec_cmd("wl-paste --watch cliphist store")
end)
