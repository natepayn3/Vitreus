-- Settings > Lock screen. The lock screen is a scene of its own and keeps its settings in its own lockscreen.json: this page asks it for
-- them when it opens (`pleamar --say lockscreen "get ..."`) and tells it each change (`fact` / `text`), and it saves them. `lk_ok` is false
-- when it does not answer, which is when it is not running.
return function(key, with_dirs)
    local BLUR = { 18, 36, 60 }
    local DATES = { "long", "standard", "dayFirst", "iso" }
    local DATE_FACT = { long = "lkd_long", standard = "lkd_std", dayFirst = "lkd_day", iso = "lkd_iso" }
    local DATE_NAME = { "lkd_long", "lkd_std", "lkd_day", "lkd_iso" }
    -- the lock screen's names for the mask style and the palette, and this scene's
    local MASK_LOCK = { "msk_shapes", "msk_dots", "msk_stars", "msk_special" }
    local MASK_HERE = { "lkm_shapes", "lkm_dots", "lkm_stars", "lkm_special" }
    local PAL_LOCK = { "mp_vibrant", "mp_accent", "mp_neon", "mp_pastel", "mp_mono" }
    local PAL_HERE = { "lkc_vibrant", "lkc_accent", "lkc_neon", "lkc_pastel", "lkc_mono" }
    local MASK_BACK, PAL_BACK = {}, {}
    for i, n in ipairs(MASK_LOCK) do MASK_BACK[n] = MASK_HERE[i] end
    for i, n in ipairs(PAL_LOCK) do PAL_BACK[n] = PAL_HERE[i] end
    local function say(cmd, fn) run("pleamar", { "--say", "lockscreen", cmd }, fn or function() end) end
    local function trim(s) return ((s or ""):gsub("%s+$", "")) end

    -- Which monitor has the clock and the password bar: its name is the lock screen's `cfg_monitor` ("all" for every one), and the chips are
    -- the monitors Hyprland has plugged in now. A name that is not plugged in shows as "All", which is what the lock screen does then too.
    local lk_names, lk_pref = {}, "all"
    local function show_mons()
        local at = 0
        for i = 0, 3 do
            local n = lk_names[i + 1]
            fact["lk_m." .. i .. ".on"] = n ~= nil
            text["lk_m." .. i .. ".name"] = n or ""
            if n and n == lk_pref then at = i + 1 end
        end
        fact.lk_mon = at
    end
    local function read_mons()
        hypr_monitors(2, function(out, code)
            if code ~= 0 or not out then return end
            local ok, list = pcall(json.decode, out)
            if not ok or type(list) ~= "table" then return end
            lk_names = {}
            for _, m in ipairs(list) do lk_names[#lk_names + 1] = m.name end
            show_mons()
        end)
    end
    -- Make the lock screen's `screens:` line name `pref` ("all", or a monitor), if it does not already.
    local function lock_screens(pref)
        with_dirs(function(d)
            local plm = d.conf .. "/lockscreen/lockscreen.plm"
            local value = pref == "all" and "all" or ('"' .. pref .. '"')
            run("grep", { "-m1", "-E", "^        screens: ", plm }, function(out)
                if (out or ""):match("screens:%s*(.-)%s*$") == value then return end
                -- never while it is locked: the write reloads the scene
                say("get locked", function(l)
                    if trim(l) == "false" then
                        run("sed", { "-i", "-E", "/^        screens: /s/screens: .*/screens: " .. value .. "/", plm }, function() end)
                    end
                end)
            end)
        end)
    end
    on("lk_mon_set", function(i)
        local k = math.floor(i + 0.5)
        lk_pref = (k >= 1 and lk_names[k]) or "all"
        show_mons()
        say("text cfg_monitor " .. lk_pref, function() lock_screens(lk_pref) end)
    end)
    -- The lock screen's own file says which monitors show it (`screens:`), and an update can put the stock `all` back: so once
    -- the lock screen answers, its file is made to say what it has saved. Only when they differ, since a write reloads the lock scene.
    after(8000, function()
        say("get cfg_monitor", function(o, code)
            local pref = trim(o):match("^[%w%._%-]+$")
            if code == 0 and pref then lock_screens(pref) end
        end)
    end)

    local function refresh()
        read_mons()
        say_many("lockscreen", { "get cfg_monitor", "get cfg_blur", "get cfg_12h", "get cfg_ampm", "get cfg_media", "get cfg_date",
            "get clock_px", "get cfg_secs", "get show_power", "get mask_style", "get mask_pal" }, function(r)
            if not r then fact.lk_ok = false return end
            lk_pref = trim(r[1]):match("^[%w%._%-]+$") and trim(r[1]) or "all"; show_mons()
            fact.lk_ok = true
            local n = tonumber(trim(r[2]))
            if n then fact.lk_blur = n end
            fact.lk_12h = trim(r[3]):match("true") ~= nil
            fact.lk_ampm = trim(r[4]):match("true") ~= nil
            fact.lk_media = trim(r[5]):match("true") ~= nil
            fact.lk_date = DATE_FACT[trim(r[6])] or "lkd_long"
            local px = tonumber(trim(r[7])); if px then fact.lk_px = px end
            fact.lk_secs = trim(r[8]):match("true") ~= nil
            fact.lk_power = trim(r[9]):match("true") ~= nil
            fact.lk_mask = MASK_BACK[trim(r[10])] or "lkm_shapes"
            fact.lk_pal = PAL_BACK[trim(r[11])] or "lkc_accent"
        end)
    end
    on("fact:set_page", function(v) if v == "pg_lock" then refresh() end end)

    on("lk_blur_set", function(i)
        local v = BLUR[math.floor(i + 0.5) + 1]
        if v then fact.lk_blur = v; say("fact cfg_blur " .. v) end
    end)
    on("lk_12h_set", function(i)
        local b = i >= 0.5
        fact.lk_12h = b
        say("fact cfg_12h " .. tostring(b))
    end)
    on("lk_ampm_toggle", function()
        local b = not fact.lk_ampm
        fact.lk_ampm = b
        say("fact cfg_ampm " .. tostring(b))
    end)
    on("lk_media_toggle", function()
        local b = not fact.lk_media
        fact.lk_media = b
        say("fact cfg_media " .. tostring(b))
    end)
    local SIZES = { 100, 150, 200 }
    on("lk_size_set", function(i)
        local v = SIZES[math.floor(i + 0.5) + 1]
        if v then fact.lk_px = v; say("fact clock_px " .. v) end
    end)
    on("lk_secs_toggle", function()
        local b = not fact.lk_secs
        fact.lk_secs = b
        say("fact cfg_secs " .. tostring(b))
    end)
    on("lk_power_toggle", function()
        local b = not fact.lk_power
        fact.lk_power = b
        say("fact show_power " .. tostring(b))
    end)
    -- Test lock: the lock screen in its safe mode (Esc on an empty bar, or a minute without a key, opens it), which it leaves again once
    -- it is open. The window goes first, so it is not what the lock looks at.
    on("lk_test", function()
        fact.panel = "none"
        after(350, function()
            say("fact safe true", function() say("fact locked true") end)
        end)
    end)
    on("lk_mask_set", function(i)
        local k = math.floor(i + 0.5) + 1
        if MASK_LOCK[k] then fact.lk_mask = MASK_HERE[k]; say("fact mask_style " .. MASK_LOCK[k]) end
    end)
    on("lk_pal_set", function(i)
        local k = math.floor(i + 0.5) + 1
        if PAL_LOCK[k] then fact.lk_pal = PAL_HERE[k]; say("fact mask_pal " .. PAL_LOCK[k]) end
    end)
    on("lk_date_set", function(i)
        local k = math.floor(i + 0.5) + 1
        if DATES[k] then fact.lk_date = DATE_NAME[k]; say("text cfg_date " .. DATES[k]) end
    end)

    -- ── The example bar (Settings > Lock screen). What is typed becomes glyphs, as it does on the lock screen: a random shape, a colour
    -- index and a symbol for each character, kept only here and only while the page is up. Enter pretends the password was right (the
    -- glyphs turn green), then it clears.
    local ROT = { 0, 45, 90, 135, 180, 225, 270, 315 }
    local SYMBOLS = { "!", "@", "#", "$", "%", "^", "&", "*", "~", "?", "§", "+", "=", "<", ">", "/" }
    local list = {}
    local function show_list()
        local shown = list
        if #list > 16 then
            shown = {}
            for i = #list - 15, #list do shown[#shown + 1] = list[i] end
        end
        model.lb = shown
    end
    local function clear_bar()
        list = {}
        model.lb = {}
        fact.lb_ok = false
        text.lb_pw = ""
    end
    on("text:lb_pw", function(t)
        if fact.lb_ok then return end
        local n = utf8.len(t) or #t
        if n == #list then return end
        if n == 0 then list = {}
        elseif n > #list then
            for _ = #list + 1, n do
                list[#list + 1] = { idx = math.random(0, 15), rot = ROT[math.random(1, #ROT)], outline = math.random() < 0.22,
                                    ci = math.random(0, 59), sym = SYMBOLS[math.random(1, #SYMBOLS)] }
            end
        else
            while #list > n do list[#list] = nil end
        end
        show_list()
    end)
    on("lb_submit", function()
        if #list == 0 or fact.lb_ok then return end
        fact.lb_ok = true
        after(900, clear_bar)
    end)
    on("fact:set_page", function(v) if v ~= "pg_lock" then clear_bar() end end)
    on("fact:panel", function(v) if v ~= "settings" then clear_bar() end end)
end
