-- Game mode: one switch (the Controls drawer's tile, or `emit game_toggle`) that trades looks and power for latency while you play.
-- On: Hyprland's blur, shadows, rounding, opacity and animations go off, tearing is allowed (a window may ask for it), variable refresh
-- is fullscreen-only, the audio visualiser stops listening (cava is stopped, which also frees its CPU), notifications are silenced (Do Not Disturb, put back after), a fullscreen window keeps drawing while it is on another workspace (else the game stalls waiting for frames it
-- never gets), and power-profiles-daemon goes to Performance. Off: `hyprctl reload` rereads the config, which drops every override
-- (nothing here is saved to a file, so a restart of Hyprland ends it too), and the profile it found is put back.
-- On niri the compositor part is its animations (off); on pleamar-wm it is its windows (square, no shadow, opaque). Tearing and variable refresh are
-- Hyprland only. The rest (profile, visualiser, notifications) is the same everywhere.
-- AC only, on purpose: every one of these trades battery and heat for latency, so on battery it says no and changes nothing.
-- The privileged half of Ryoku's version (deep idle states, WiFi power save) is left out: it needs root, and a polkit rule.
return function()
    local G = { on = false, prior = nil, dnd = false, comp = "wm" }
    -- Which compositor this is, asked once: Hyprland has its signature in the environment, niri its socket, and under pleamar-wm there is neither.
    run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(o, c) if c == 0 and (o or "") ~= "" then G.comp = "hypr" end end)
    run("printenv", { "NIRI_SOCKET" }, function(o, c) if c == 0 and (o or "") ~= "" then G.comp = "niri" end end)

    local ON = [[hl.config({ general = { allow_tearing = true }, decoration = { rounding = 0, active_opacity = 1.0, inactive_opacity = 1.0, blur = { enabled = false }, shadow = { enabled = false } }, animations = { enabled = false }, misc = { vrr = 2 } }) ]]
        .. [[hl.window_rule({ name = "game-mode-immediate", match = { class = ".*" }, immediate = true }) ]]
        .. [[hl.window_rule({ name = "game-mode-render-unfocused", match = { fullscreen = true }, render_unfocused = true })]]

    local function show()
        fact.game_on = G.on
        text.game_status = G.on and "On" or "Off"
    end
    local function say(title, body)
        pcall(run, "notify-send", { "-a", "Vitreus", title, body }, function() end)
    end

    local function start()
        -- A system battery (type Battery, scope not Device) that reports Discharging means the machine is not on the mains.
        -- Peripheral batteries (a wireless mouse: hidpp_battery_*, scope Device) and USB-C ports (type USB) also say Discharging,
        -- and must not count, or a desktop with a Logitech mouse is "on battery" forever.
        -- (Not `sh`: the scene may not run it. `find` + `grep -H` print "dir/field:value" for each, parsed here.)
        run("find", { "-L", "/sys/class/power_supply", "-maxdepth", "2", "(", "-name", "type", "-o", "-name", "scope", "-o", "-name", "status", ")",
                      "-exec", "grep", "-H", "", "{}", "+" }, function(out)
            local ps = {}
            for dir, field, val in (type(out) == "string" and out or ""):gmatch("([^\n]*)/(%a+):([^\n]*)") do
                ps[dir] = ps[dir] or {}
                ps[dir][field] = val
            end
            local discharging = false
            for _, p in pairs(ps) do
                if p.type == "Battery" and p.scope ~= "Device" and p.status == "Discharging" then discharging = true end
            end
            if discharging then
                fact.game_k = 0.45
                text.game_status = "Needs AC power"
                say("Game Mode", "Needs AC power: every lever trades battery and heat for latency")
                after(2500, function() fact.game_k = 1; show() end)
                return
            end
            G.on = true
            game_fx.on = true
            game_fx.glass(true)               -- no glass: flat obsidian, nothing bent or captured over the game
            G.dnd = game_fx.dnd_start()       -- notifications off, unless something was silencing them already
            cava_want()                       -- the visualiser stops listening (cava is stopped)
            show()
            if G.comp == "hypr" then run("hyprctl", { "eval", ON }, function() end)
            elseif G.comp == "niri" then game_fx.niri(true)
            else game_fx.wm(true) end
            run("powerprofilesctl", { "get" }, function(out, c)
                local p = (out or ""):match("%S+")
                if c == 0 and p and p ~= "performance" then
                    G.prior = p
                    run("powerprofilesctl", { "set", "performance" }, function() end)
                end
            end)
        end)
    end

    local function stop()
        G.on = false
        game_fx.on = false
        game_fx.glass(false)
        if G.dnd then game_fx.dnd_stop(); G.dnd = false end
        cava_want()
        show()
        if G.comp == "hypr" then run("hyprctl", { "reload" }, function() end)
        elseif G.comp == "niri" then game_fx.niri(false)
        else game_fx.wm(false) end
        if G.prior then
            run("powerprofilesctl", { "set", G.prior }, function() end)
            G.prior = nil
        end
    end

    on("game_toggle", function()
        if G.on then stop() else start() end
    end)
    show()
end
