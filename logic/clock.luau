-- Settings > Widgets: first the desktop clock, then (below) the desktop system monitor. The desktop clock is a scene of its own (desktopclock/) and keeps its settings in its own desktopclock.json: this page asks it for
-- them when it opens (`pleamar --say desktopclock "get ..."`) and tells it each change (`fact`), and it saves them. `ck_ok` is false when it does not
-- answer, which is when it is not running; the switch then starts it.
return function()
    local SIZES = { 70, 100, 140, 190 }
    local function say(cmd, fn) run("pleamar", { "--say", "desktopclock", cmd }, fn or function() end) end
    local function trim(s) return ((s or ""):gsub("%s+$", "")) end
    -- Which monitor shows the clock and the system monitor: their chips (the same names as the visualiser's, `cv_m.N.name`) light the one they are on.
    local cv_names = {}
    local ck_pref, sy_pref = "", ""
    local function show_wd_mons()
        local ck_at, sy_at = 0, 0
        for i, n in ipairs(cv_names) do
            if n == ck_pref then ck_at = i end
            if n == sy_pref then sy_at = i end
        end
        fact.ck_mon, fact.sy_mon = ck_at, sy_at
    end
    local function refresh()
        say_many("desktopclock", { "get shown", "get sty", "get px", "get d0", "get d1", "get d2", "get d3", "get h12", "get mon_name",
                                   "get ck_tm", "get ck_ap", "get ck_wd", "get ck_wdl", "get ck_dt", "get ck_dts", "get ck_dtl" }, function(r)
            if not r then fact.ck_ok = false return end
            ck_pref = trim(r[9]):match("^[%w%._%-]+$") and trim(r[9]) or ""; show_wd_mons()
            fact.ck_ok = true
            fact.ck_on = trim(r[1]):match("true") ~= nil
            local function num(i, key) local n = tonumber(trim(r[i])); if n then fact[key] = n end end
            num(2, "ck_sty"); num(3, "ck_px"); num(4, "ck_d0"); num(5, "ck_d1"); num(6, "ck_d2"); num(7, "ck_d3")
            fact.ck_12h = trim(r[8]):match("true") ~= nil
            -- the time and date as the clock words them (a text answers as itself, maybe quoted)
            for i, key in ipairs({ "ck_tm", "ck_ap", "ck_wd", "ck_wdl", "ck_dt", "ck_dts", "ck_dtl" }) do
                local v = trim(r[9 + i]):gsub('^"(.*)"$', "%1")
                text[key] = v
            end
        end)
    end
    -- The desktop system monitor (desktopsysmon/) is the same: its own scene, asked when the page opens, told each change.
    local function say_sy(cmd, fn) run("pleamar", { "--say", "desktopsysmon", cmd }, fn or function() end) end
    local function refresh_sy()
        say_many("desktopsysmon", { "get shown", "get cli", "get where", "get mon_name" }, function(r)
            if not r then fact.sy_ok = false return end
            sy_pref = trim(r[4]):match("^[%w%._%-]+$") and trim(r[4]) or ""; show_wd_mons()
            fact.sy_ok = true
            fact.sy_on = trim(r[1]):match("true") ~= nil
            local n = tonumber(trim(r[2])); if n then fact.sy_cl = n end
        end)
    end
    -- The chips of the clock and the system monitor are the monitors plugged in now (the order hyprctl lists them in).
    local function show_cv_mons()
        for i = 0, 3 do
            local n = cv_names[i + 1]
            fact["cv_m." .. i .. ".on"] = n ~= nil
            text["cv_m." .. i .. ".name"] = n or ""
        end
    end
    local function read_cv_mons()
        run("hyprctl", { "monitors", "-j" }, function(out, code)
            if code ~= 0 or not out then return end
            local names = {}
            local ok, list = pcall(json.decode, out)
            if ok and type(list) == "table" then
                table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
                for _, m in ipairs(list) do names[#names + 1] = m.name end
            else
                -- pleamar-wm's `hyprctl monitors` is text: "Monitor <name> (ID 1):"
                for name in out:gmatch("Monitor (%S+) %(ID %d+%):") do names[#names + 1] = name end
            end
            cv_names = names
            show_cv_mons()
            show_wd_mons()
        end)
    end
    local function refresh_cv() read_cv_mons() end
    read_cv_mons()
    on("fact:set_page", function(v) if v == "pg_clock" then refresh(); refresh_sy(); refresh_cv() end end)
    -- The settings open again on the page they were left on, and the desktop editor can switch the widgets while it is showing: the page
    -- asks again when the panel opens, and while it is in view it asks (only whether they are on) every couple of seconds.
    on("fact:panel", function(v) if v == "settings" and fact.set_page == "pg_clock" then refresh(); refresh_sy() end end)
    local function refresh_shown()
        run("pleamar", { "--say", "desktopclock", "get shown" }, function(out, code) if code == 0 then fact.ck_on = (out or ""):match("true") ~= nil end end)
        run("pleamar", { "--say", "desktopsysmon", "get shown" }, function(out, code) if code == 0 then fact.sy_on = (out or ""):match("true") ~= nil end end)
    end
    every(2000, function() if fact.panel == "settings" and fact.set_page == "pg_clock" then refresh_shown() end end)

    on("ck_toggle", function()
        local b = not fact.ck_on
        fact.ck_on = b
        -- Just tell it. Only when it does not answer at all (no scene running) is one started: asking `ck_ok` here started a second
        -- clock on top of the first whenever the page had not read the first yet (a reload, a page left open).
        say("fact shown " .. tostring(b), function(_, code)
            if code ~= 0 and b then
                exec_on_desktop('vitreus-keep "${XDG_CONFIG_HOME:-$HOME/.config}/pleamar/shells/vitreus/desktopclock/desktopclock.plm"')
                -- (told to show, as the system monitor is: a clock saved as hidden started hidden, and the switch flipped back off)
                after(2500, function() say("fact shown true"); refresh() end)
            else
                refresh()
            end
        end)
    end)
    local function pick(event, key, remote, hi)
        on(event, function(i)
            local v = math.max(0, math.min(hi, math.floor(i + 0.5)))
            fact[key] = v
            say("fact " .. remote .. " " .. v)
        end)
    end
    pick("ck_sty_set", "ck_sty", "sty", 4)
    on("ck_12h_set", function(i)
        local b = i >= 0.5
        fact.ck_12h = b
        say("fact h12 " .. tostring(b))
    end)
    on("ck_size_set", function(i)
        local v = SIZES[math.floor(i + 0.5) + 1]
        if v then fact.ck_px = v; say("fact px " .. v) end
    end)

    on("sy_toggle", function()
        local b = not fact.sy_on
        fact.sy_on = b
        say_sy("fact shown " .. tostring(b), function(_, code)
            if code ~= 0 and b then
                exec_on_desktop('vitreus-keep "${XDG_CONFIG_HOME:-$HOME/.config}/pleamar/shells/vitreus/desktopsysmon/desktopsysmon.plm"')
                after(2500, function() say_sy("fact shown true"); refresh_sy() end)
            else
                refresh_sy()
            end
        end)
    end)
    on("sy_cl_set", function(i)
        local v = math.max(0, math.min(2, math.floor(i + 0.5)))
        fact.sy_cl = v
        say_sy("fact cli " .. v)
    end)

    on("ck_mon_set", function(i)
        local n = cv_names[math.floor(i + 0.5)]
        if not n then return end
        ck_pref = n; show_wd_mons()
        say("text mon_name " .. n)
    end)
    on("sy_mon_set", function(i)
        local n = cv_names[math.floor(i + 0.5)]
        if not n then return end
        sy_pref = n; show_wd_mons()
        say_sy("text mon_name " .. n)
    end)
end
