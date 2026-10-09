-- The battery, straight from the kernel. pleamar's `battery` service only looks every 20 s, so a plug or unplug took up to 20 s to show.
-- This reads the battery's files when the kernel says a power supply changed (udevadm monitor, one process, no polling), plus a slow look
-- every 15 s in case an event is missed. It gives the scene `chg_now` (the charger is filling it, used instead of `pwr.charging`) and the
-- text `bat_state` for the laptop's card in the Power window: what it is doing and, when the kernel's figures allow, how long is left
-- ("On battery · 3 h 12 min left", "Charging · 45 min to full"). Laptops report charge and current, or energy and power: same sum.
return function()
    local dir, files, has_rate
    local rate_avg, rate_status

    local function span(h)
        local m = math.floor(h * 60 + 0.5)
        if m >= 20 then m = math.floor(m / 5 + 0.5) * 5 end   -- the rate jitters: a minute-exact guess would too
        if m < 1 then m = 1 end
        if m >= 60 then return string.format("%d h %02d min", m // 60, m % 60) end
        return m .. " min"
    end

    local function describe(status, capacity, now, full, rate)
        local eta
        if has_rate and rate and rate > 0 and now and full then
            -- Smoothed over the looks that saw the same status: the draw moves with whatever the machine is doing.
            if rate_status == status and rate_avg then rate_avg = rate_avg * 0.7 + rate * 0.3 else rate_avg = rate end
            rate_status = status
            if status == "Discharging" then eta = now / rate_avg
            elseif status == "Charging" then eta = math.max(0, full - now) / rate_avg end
            if eta and eta > 99 then eta = nil end
        else
            rate_avg, rate_status = nil, nil
        end
        if status == "Full" then return "Fully charged" end
        if status == "Not charging" then return "Plugged in" end
        if status == "Charging" then return eta and ("Charging · " .. span(eta) .. " to full") or "Charging" end
        local base = (capacity and capacity < 20) and "Low" or "On battery"
        return eta and (base .. " · " .. span(eta) .. " left") or base
    end

    local function look()
        if not files then return end
        run("cat", files, function(out, code)
            if code ~= 0 or not out then return end
            local v = {}
            for line in out:gmatch("[^\n]+") do v[#v + 1] = line end
            local status = v[1]:match("^%s*(.-)%s*$")
            fact.chg_now = (status == "Charging" or status == "Full")
            text.bat_state = describe(status, tonumber(v[2]), tonumber(v[3]), tonumber(v[4]), tonumber(v[5]))
        end)
    end

    run("ls", { "/sys/class/power_supply" }, function(out, code)
        if code ~= 0 or not out then return end
        for name in out:gmatch("%S+") do
            if name:match("^BAT") then dir = "/sys/class/power_supply/" .. name; break end
        end
        if not dir then return end
        run("ls", { dir }, function(listing, c)
            local have = {}
            for f in (listing or ""):gmatch("%S+") do have[f] = true end
            files = { dir .. "/status", dir .. "/capacity" }
            -- Order matters: the answer is read back by position (status, capacity, now, full, rate).
            for _, set in ipairs({ { "charge_now", "charge_full", "current_now" }, { "energy_now", "energy_full", "power_now" } }) do
                if have[set[1]] and have[set[2]] and have[set[3]] then
                    for _, f in ipairs(set) do files[#files + 1] = dir .. "/" .. f end
                    has_rate = true
                    break
                end
            end
            look()
        end)
    end)

    spawn("udevadm", { "monitor", "--kernel", "--subsystem-match=power_supply" }, function(line)
        if not line:find("power_supply", 1, true) then return end
        -- The adapter's event comes before the battery's status has changed (unplugging: ~1 s later; plugging in: ~4 s, via "Not charging"),
        -- and the battery says nothing of its own, so look again a few times as it settles.
        look()
        for _, ms in ipairs({ 700, 1500, 3000, 5000 }) do after(ms, look) end
    end)
    every(15000, look)
end
