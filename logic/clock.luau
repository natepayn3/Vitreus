-- Settings > Clock. The desktop clock is a scene of its own (desktopclock/) and keeps its settings in its own desktopclock.json: this page asks it for
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
        say("get shown", function(out, code)
            if code ~= 0 then fact.ck_ok = false return end
            fact.ck_ok = true
            fact.ck_on = trim(out):match("true") ~= nil
            local function num(name, key, hi)
                say("get " .. name, function(o) local n = tonumber(trim(o)); if n then fact[key] = n end end)
            end
            num("lay", "ck_lay"); num("px", "ck_px"); num("wti", "ck_wt"); num("cli", "ck_cl");
            say("get where", function(o) local n = POS_BACK[trim(o)]; if n then fact.ck_pos = n end end)
            say("get h12", function(o) fact.ck_12h = trim(o):match("true") ~= nil end)
        end)
    end
    on("fact:set_page", function(v) if v == "pg_clock" then refresh() end end)

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
end
