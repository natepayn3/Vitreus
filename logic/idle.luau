-- Idle and sleep (Settings > Idle): after how long without input the screen locks, goes dark and the machine sleeps; each can be Never (0). hypridle does the
-- waiting, because it already honours every reason to stay awake (Caffeine's inhibitor, a browser's video, a Wayland idle inhibitor). This writes what it waits for to
-- `idle.conf` in the data folder, which pleamar-wm/hypridle.conf reads (`source =`), and starts hypridle again. Kept in idle.json. On pleamar-wm the screen-off time is also
-- written into `idle off-after` in session.conf, which that window manager reads at login. The numbers are minutes; the Hyprland screen-off line is hypridle's DPMS.
return function(with_dirs)
    local STEPS = { 0, 1, 2, 3, 5, 7, 10, 15, 20, 30, 45, 60, 90, 120 }
    local I = { lock = 5, off = 7, sleep = 0, force = 0 }   -- force: 1 locks even while a video holds idle off
    local KEYS = { "lock", "off", "sleep" }
    local ROOT = nil
    local pending = 0

    local function words(m)
        if m == 0 then return "Never" end
        if m < 60 then return m .. (m == 1 and " minute" or " minutes") end
        if m % 60 == 0 then return (m // 60) .. (m == 60 and " hour" or " hours") end
        return (m // 60) .. " h " .. (m % 60) .. " min"
    end
    local function show()
        text.idle_lock_t, text.idle_off_t, text.idle_sleep_t = words(I.lock), words(I.off), words(I.sleep)
        fact.idle_lock, fact.idle_off, fact.idle_sleep = I.lock, I.off, I.sleep
        fact.idle_force = I.force
        for _, k in ipairs(KEYS) do
            for i, m in ipairs(STEPS) do if m == I[k] then fact["idle_" .. k .. "_i"] = i - 1 end end
        end
    end

    local function conf()
        local say = 'PATH="$HOME/.local/bin:$PATH" pleamar --say lockscreen "fact locked true"'
        local out = { "# Written by Vitreus (Settings > Idle): do not edit, it is written again with every change.\n" }
        if I.lock > 0 then out[#out + 1] = string.format("listener {\n    timeout = %d\n    on-timeout = %s\n%s}\n", I.lock * 60, say, I.force == 1 and "    ignore_inhibit = true\n" or "") end
        if I.off > 0 then
            out[#out + 1] = string.format("listener {\n    timeout = %d\n    on-timeout = hyprctl dispatch 'hl.dsp.dpms({ action = \"disable\" })'\n    on-resume = hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'\n}\n", I.off * 60)
        end
        if I.sleep > 0 then out[#out + 1] = string.format("listener {\n    timeout = %d\n    on-timeout = systemctl suspend\n}\n", I.sleep * 60) end
        return table.concat(out)
    end

    local function apply()
        pcall(sys.call, "files.write", "idle.json", I)
        pcall(sys.call, "files.write", "idle.conf", conf())
        if ROOT then
            local line = I.off > 0 and ("idle off-after " .. I.off * 60) or "#idle off-after 600"
            run("sed", { "-i", "-E", "s/^#?idle off-after .*/" .. line .. "/", ROOT .. "/.config/pleamar/session.conf" }, function() end)
        end
        pending = pending + 1
        local mine = pending
        after(1500, function()          -- (a few presses in a row restart it once)
            if mine ~= pending then return end
            run("pkill", { "-x", "hypridle" }, function()
                run("setsid", { "-f", "hypridle" }, function() end)
            end)
        end)
    end

    on("idle_set", function(code)
        code = math.floor((tonumber(code) or 0) + 0.5)
        local k, at = KEYS[code // 100 + 1], code % 100 + 1
        if not k or not STEPS[at] or I[k] == STEPS[at] then return end
        I[k] = STEPS[at]
        show()
        apply()
    end)

    on("idle_toggle", function()
        I.force = 1 - I.force
        show()
        apply()
    end)

    with_dirs(function(d)
        ROOT = d.home
        local ok, saved = pcall(sys.ask, "files.read", "idle.json", "json")
        if ok and type(saved) == "table" then
            for _, k in ipairs(KEYS) do
                if type(saved[k]) == "number" and saved[k] >= 0 and saved[k] <= 240 then I[k] = saved[k] end
            end
            if saved.force == 1 then I.force = 1 end
        else
            -- First start: write the file hypridle needs now that hypridle.conf reads it, with the times the shipped config always had.
            apply()
        end
        show()
    end)
end
