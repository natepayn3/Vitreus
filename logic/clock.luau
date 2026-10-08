-- Settings > Widgets: first the desktop clock, then (below) the desktop system monitor. The desktop clock is a scene of its own (desktopclock/) and keeps its settings in its own desktopclock.json: this page asks it for
-- them when it opens (`pleamar --say desktopclock "get ..."`) and tells it each change (`fact`), and it saves them. `ck_ok` is false when it does not
-- answer, which is when it is not running; the switch then starts it.
return function()
    local POS = { "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom", "bottom_right" }
    local POS_BACK = {}
    for i, n in ipairs(POS) do POS_BACK[n] = i - 1 end
    local SIZES = { 140, 220, 280, 340 }
    local function say(cmd, fn) run("pleamar", { "--say", "desktopclock", cmd }, fn or function() end) end
    local function trim(s) return ((s or ""):gsub("%s+$", "")) end

    local function refresh()
        say_many("desktopclock", { "get shown", "get lay", "get px", "get wti", "get cli", "get where", "get h12" }, function(r)
            if not r then fact.ck_ok = false return end
            fact.ck_ok = true
            fact.ck_on = trim(r[1]):match("true") ~= nil
            local function num(i, key) local n = tonumber(trim(r[i])); if n then fact[key] = n end end
            num(2, "ck_lay"); num(3, "ck_px"); num(4, "ck_wt"); num(5, "ck_cl")
            local pos = POS_BACK[trim(r[6])]; if pos then fact.ck_pos = pos end
            fact.ck_12h = trim(r[7]):match("true") ~= nil
        end)
    end
    -- The desktop system monitor (desktopsysmon/) is the same: its own scene, asked when the page opens, told each change.
    local function say_sy(cmd, fn) run("pleamar", { "--say", "desktopsysmon", cmd }, fn or function() end) end
    local function refresh_sy()
        say_many("desktopsysmon", { "get shown", "get cli", "get where" }, function(r)
            if not r then fact.sy_ok = false return end
            fact.sy_ok = true
            fact.sy_on = trim(r[1]):match("true") ~= nil
            local n = tonumber(trim(r[2])); if n then fact.sy_cl = n end
            local pos = POS_BACK[trim(r[3])]; if pos then fact.sy_pos = pos end
        end)
    end
    on("fact:set_page", function(v) if v == "pg_clock" then refresh(); refresh_sy() end end)

    on("ck_toggle", function()
        local b = not fact.ck_on
        fact.ck_on = b
        if fact.ck_ok then
            say("fact shown " .. tostring(b))
        elseif b then
            -- not running: start it, and once it is up read what it holds
            exec_on_desktop('pleamar --scene "$HOME/.config/pleamar/shells/vitreus/desktopclock/desktopclock.plm" --no-hud')
            after(2500, refresh)
        end
    end)
    local function pick(event, key, remote, hi)
        on(event, function(i)
            local v = math.max(0, math.min(hi, math.floor(i + 0.5)))
            fact[key] = v
            say("fact " .. remote .. " " .. v)
        end)
    end
    pick("ck_lay_set", "ck_lay", "lay", 5)
    pick("ck_wt_set", "ck_wt", "wti", 2)
    pick("ck_cl_set", "ck_cl", "cli", 2)
    on("ck_pos_set", function(i)
        local k = math.floor(i + 0.5)
        if POS[k + 1] then fact.ck_pos = k; say("fact where " .. POS[k + 1]) end
    end)
    on("ck_12h_set", function(i)
        local b = i >= 0.5
        fact.ck_12h = b
        say("fact h12 " .. tostring(b))
    end)
    on("ck_size_set", function(i)
        local v = SIZES[math.floor(i + 0.5) + 1]
        if v then fact.ck_px = v; say("fact px " .. v) end
    end)

    -- The clock's hours, minutes and divider: each has a weight and a size (a step of a list) and a tint. The Settings page works on the one picked
    -- (`gl_sel`: 0 hours, 1 minutes, 2 divider); what the clock scene holds is read at once from its `gpack`, "w,z,c;" for each of the three.
    local WS = { 0.6, 0.8, 1, 1.25, 1.5 }
    local ZS = { 0.8, 0.9, 1, 1.1, 1.2 }
    local GP = {}
    for i = 0, 2 do GP[i] = { 1, 1, 0 } end
    local function gname(i) return ({ [0] = "h", "m", "s" })[i] end
    local function step(list, v)
        local best, bd = 3, 1e9
        for i, x in ipairs(list) do
            local d = math.abs(x - v)
            if d < bd then best, bd = i, d end
        end
        return best - 1
    end
    local function show_sel()
        local g = GP[fact.gl_sel] or { 1, 1, 0 }
        fact.gl_w = step(WS, g[1])
        fact.gl_z = step(ZS, g[2])
        fact.gl_c = math.max(0, math.min(4, math.floor(g[3] + 0.5)))
    end
    local function read_glyphs()
        say("get gpack", function(out, code)
            if code ~= 0 then return end
            local i = 0
            for w, z, c in trim(out):gmatch("([%d%.]+),([%d%.]+),(%d+)") do
                if i <= 2 then GP[i] = { tonumber(w) or 1, tonumber(z) or 1, tonumber(c) or 0 } end
                i = i + 1
            end
            show_sel()
        end)
    end
    local refresh_clock = refresh
    refresh = function() refresh_clock(); read_glyphs() end
    on("gl_pick", function(i)
        fact.gl_sel = math.max(0, math.min(2, math.floor(i + 0.5)))
        show_sel()
    end)
    local function set_glyph(slot, key, value)
        local i = fact.gl_sel
        GP[i][slot] = value
        say("fact g" .. gname(i) .. key .. " " .. value)
    end
    on("gl_w_set", function(j) j = math.max(0, math.min(4, math.floor(j + 0.5))); fact.gl_w = j; set_glyph(1, "w", WS[j + 1]) end)
    on("gl_z_set", function(j) j = math.max(0, math.min(4, math.floor(j + 0.5))); fact.gl_z = j; set_glyph(2, "z", ZS[j + 1]) end)
    on("gl_c_set", function(j) j = math.max(0, math.min(4, math.floor(j + 0.5))); fact.gl_c = j; set_glyph(3, "c", j) end)
    on("gl_reset", function()
        local i = fact.gl_sel
        GP[i] = { 1, 1, 0 }
        say("fact g" .. gname(i) .. "w 1"); say("fact g" .. gname(i) .. "z 1"); say("fact g" .. gname(i) .. "c 0")
        show_sel()
    end)
    on("gl_reset_all", function()
        for i = 0, 2 do GP[i] = { 1, 1, 0 } end
        say("fact greset 1")
        show_sel()
    end)

    on("sy_toggle", function()
        local b = not fact.sy_on
        fact.sy_on = b
        if fact.sy_ok then
            say_sy("fact shown " .. tostring(b))
        elseif b then
            -- not running: start it, and show it once it is up
            exec_on_desktop('pleamar --scene "$HOME/.config/pleamar/shells/vitreus/desktopsysmon/desktopsysmon.plm" --no-hud')
            after(2500, function() say_sy("fact shown true"); refresh_sy() end)
        end
    end)
    on("sy_pos_set", function(i)
        local k = math.floor(i + 0.5)
        if POS[k + 1] then fact.sy_pos = k; say_sy("fact where " .. POS[k + 1]) end
    end)
    on("sy_cl_set", function(i)
        local v = math.max(0, math.min(2, math.floor(i + 0.5)))
        fact.sy_cl = v
        say_sy("fact cli " .. v)
    end)
end
