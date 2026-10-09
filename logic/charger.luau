-- Whether the charger is filling the battery, straight from the kernel. pleamar's `battery` service only looks every 20 s, so a plug or
-- unplug took up to 20 s to show. This reads the battery's status when the kernel says a power supply changed (udevadm monitor, one
-- process, no polling), plus a slow look every 15 s in case an event is missed. `chg_now` is what the scene uses instead of `pwr.charging`.
return function()
    local path
    local function look()
        if not path then return end
        run("cat", { path }, function(out, code)
            if code ~= 0 or not out then return end
            local s = out:match("^%s*(%S+)")
            fact.chg_now = (s == "Charging" or s == "Full")
        end)
    end
    run("ls", { "/sys/class/power_supply" }, function(out, code)
        if code ~= 0 or not out then return end
        for name in out:gmatch("%S+") do
            if name:match("^BAT") then path = "/sys/class/power_supply/" .. name .. "/status"; break end
        end
        look()
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
