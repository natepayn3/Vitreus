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

-- SUPER + SHIFT + D opens or closes the dashboard, the glass that rises out of the middle of the screen.
hl.unbind("SUPER + SHIFT + D")
hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit dash_toggle\""))

-- SUPER + TAB opens or closes the workspace overview.
hl.unbind("SUPER + TAB")
hl.bind("SUPER + TAB", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit ov_toggle\""))

-- Screenshots and recording are Vitreus's Capture: a region, or the whole screen (copied, and saved in ~/Pictures/Screenshots).
-- SUPER + C opens or closes the Control Center.
hl.unbind("SUPER + C")
hl.bind("SUPER + C", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit controls_toggle\""))
hl.unbind("SUPER + SHIFT + C")
-- SUPER + A takes a screenshot of a region (Snap), SUPER + CTRL + A of the whole screen, SUPER + SHIFT + A records the screen.
hl.unbind("SUPER + A")
hl.bind("SUPER + A", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit shot 0\""))
hl.unbind("SUPER + CTRL + A")
hl.bind("SUPER + CTRL + A", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit shot 1\""))
hl.unbind("SUPER + SHIFT + A")
hl.bind("SUPER + SHIFT + A", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit rec_toggle\""))

-- The brightness keys, again: the same brightnessctl step as hyprland.lua's, and then the new level told to the shell at once (as a share of the
-- backlight's maximum), so its pop-up follows each press; the brightness service only looks every 700 ms.
hl.unbind("XF86MonBrightnessUp")
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd([[PATH="$HOME/.local/bin:$PATH"; f=$(brightnessctl -e4 -n2 -m set 5%+ | awk -F, '{printf "%.4f", $3/$5}'); pleamar --say vitreus "emit bright_key $f"]]), { locked = true, repeating = true })
hl.unbind("XF86MonBrightnessDown")
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd([[PATH="$HOME/.local/bin:$PATH"; f=$(brightnessctl -e4 -n2 -m set 5%- | awk -F, '{printf "%.4f", $3/$5}'); pleamar --say vitreus "emit bright_key $f"]]), { locked = true, repeating = true })

-- SUPER + E opens the home folder in the user's file manager (vitreus-files).
hl.unbind("SUPER + E")
hl.bind("SUPER + E", hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" vitreus-files"))

-- Files is a window of its own (app_id vitreus.files), and it floats rather than tiling.
hl.window_rule({
    name  = "float-vitreus-files",
    match = { class = "^vitreus\\.files$" },
    float = true,
})

-- Caps Lock and Num Lock: Hyprland has no event for them, so these tell the shell when either is pressed (a row of the volume drawer shows the
-- new state). `non_consuming`: the key still reaches the window. Both keys are modifiers themselves (Caps Lock is CAPS, Num Lock MOD2) and a bind
-- only fires with exactly its own modifiers held (`ignore_mods` is not taken by this Hyprland), so each is bound with and without them: with only
-- the plain bind, Caps fired on the way on and not on the way off, and nothing fired at all while Num Lock was on.
for _, key in ipairs({ "Caps_Lock", "Num_Lock" }) do
    for _, mods in ipairs({ "", "CAPS + ", "MOD2 + ", "CAPS + MOD2 + " }) do
        hl.bind(mods .. key, hl.dsp.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --say vitreus \"emit lockkeys\""), { non_consuming = true })
    end
end

-- hyprglass (an optional Hyprland plugin, ~/.local/lib/hyprglass/hyprglass.so), on trial with Files only: the compositor draws glass behind the
-- Files window (tagged below), and Files stops bending its own copy of the wallpaper while the plugin is loaded (vitreus.luau, `game_fx.hg_check`),
-- so that the compositor's shows through. Nothing else: no other window, and not the shell's layer (it is one full-screen surface, and the
-- plugin glassed all of it). This does nothing until the plugin is loaded: `hyprctl plugin load ~/.local/lib/hyprglass/hyprglass.so`, then `hyprctl reload`.
if hl.plugin and hl.plugin.hyprglass then
    local hg = hl.plugin.hyprglass
    -- (its own default blur, 2.0 = 24 px in three passes, hid everything behind: this is about as frosted as pleamar's glass at 100 %)
    hg.config({ enabled = false, layers = { enabled = false }, blur_strength = 0.5, blur_iterations = 2 })
    hl.window_rule({ name = "vitreus-files-hyprglass", match = { class = "^vitreus\\.files$" }, tag = "+hyprglass_enabled" })
end

-- What starts with the session: pleamar runs ~/.config/pleamar/autostart (the Vitreus scene, lock screen and desktop widgets, and the
-- daemons the shell relies on: wallpaper, idle lock, clipboard history). Hyprland's PATH has no ~/.local/bin, hence the export.
-- The daemons are not started from here as well: the installer's lines in autostart start each one only if it is not already running,
-- and a second `hypridle` beside one from the person's own hyprland.lua ran every idle step (lock, screen off) twice.
hl.on("hyprland.start", function ()
    hl.exec_cmd("PATH=\"$HOME/.local/bin:$PATH\" pleamar --autostart")
end)
