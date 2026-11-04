-- The audio visualiser: the bottom edge of the screen rising into the music (pages/bar_shapes.plm draws it, from the sprung cava bars `spec.s.*`; cava itself is
-- started and stopped by `cava_want` in vitreus.luau). This keeps its switch and its four sliders (Settings > Widgets; the switch also in the desktop editor and in the
-- launcher's "Audio visualiser: toggle") in framewave.json, in Vitreus's data folder, and puts them back when it starts:
--   on    the switch (`fw_on`)
--   cols  how many columns, 6 to 47 (`fw_cols`)
--   sens  how far the music pushes them, 0.3 to 3, a log scale on the slider (`fw_sens`)
--   hgt   how tall at most, 40 to 300 px (`fw_hgt`)
--   bl    how much each melts into the next, 0 to 1 (`fw_bl`)
--   lay   where it stands (`fw_lay`): 0 along the bottom, 1 fanned out of the four corners, 2 along the top, 3 down the left, 4 down the right
--   mon   which monitor shows it, by name ("": all of them); the page's chip is `fw_mon`, and the scene gets that monitor's size (`fw_sw`, `fw_sh`)
-- The slider events (`fw_cols_set` …) carry where on the track it was pressed, 0 to 1. The facts can be set from outside too (`pleamar --say vitreus "fact fw_sens 2"`) and are kept.
return function()
    local cfg = { v = 2, on = true, cols = 24, sens = 1, hgt = 50, bl = 1, lay = 0, mon = "" }
    local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
    local function norm(k, v)
        v = tonumber(v) or cfg[k]
        if k == "cols" then return math.floor(clamp(v, 6, 47) + 0.5)
        elseif k == "sens" then return math.floor(clamp(v, 0.3, 3) * 100 + 0.5) / 100
        elseif k == "hgt" then return math.floor(clamp(v, 40, 300) + 0.5)
        elseif k == "lay" then return math.floor(clamp(v, 0, 4) + 0.5)
        else return math.floor(clamp(v, 0, 1) * 100 + 0.5) / 100 end
    end
    local FACT = { cols = "fw_cols", sens = "fw_sens", hgt = "fw_hgt", bl = "fw_bl", lay = "fw_lay" }
    local function show(k)
        local v = cfg[k]
        if k == "cols" then text.fw_cols_text = string.format("%d", v)
        elseif k == "sens" then text.fw_sens_text = string.format("%.1fx", v)
        elseif k == "hgt" then text.fw_hgt_text = string.format("%d", v)
        elseif k == "bl" then text.fw_bl_text = string.format("%d%%", math.floor(v * 100 + 0.5)) end
    end

    local ok, saved = pcall(sys.ask, "files.read", "framewave.json", "json")
    if ok and type(saved) == "table" and saved.v == 2 then
        if type(saved.on) == "boolean" then cfg.on = saved.on end
        if type(saved.mon) == "string" then cfg.mon = saved.mon end
        for k in pairs(FACT) do
            if type(saved[k]) == "number" then cfg[k] = norm(k, saved[k]) end
        end
    end
    fact.fw_on = cfg.on
    for k, f in pairs(FACT) do fact[f] = cfg[k]; show(k) end
    local function save() pcall(sys.call, "files.write", "framewave.json", cfg) end
    save()

    -- the switch: the scene's own buttons, the editor's tile and the launcher emit `fw_toggle`
    on("fw_toggle", function()
        cfg.on = not cfg.on
        fact.fw_on = cfg.on
        save()
        cava_want()      -- (a fact set from here does not fire `fact:` handlers)
    end)
    on("fact:fw_on", function(v)
        local b = (v == true or v == 1)
        if b ~= cfg.on then cfg.on = b; save() end
    end)

    -- the sliders: a position on the track becomes the value
    local FROM_T = {
        cols = function(t) return 6 + t * 41 end,
        sens = function(t) return 0.3 * 10 ^ t end,
        hgt = function(t) return 40 + t * 260 end,
        bl = function(t) return t end,
        lay = function(t) return t end,      -- (the layout's tiles send the layout, 0 to 4, not a position on a track)
    }
    for k, f in pairs(FACT) do
        on(f .. "_set", function(t)
            cfg[k] = norm(k, FROM_T[k](k == "lay" and (tonumber(t) or 0) or clamp(tonumber(t) or 0, 0, 1)))
            fact[f] = cfg[k]
            show(k)
            save()
        end)
        on("fact:" .. f, function(v)
            if type(v) ~= "number" then return end
            local n = norm(k, v)
            if n ~= cfg[k] then cfg[k] = n; show(k); save() end
        end)
    end

    -- Which monitor shows it ("Show on"): the chips are the monitors in hyprctl's order, as the system monitor's are (`cv_m.*`, logic/clock.luau).
    -- The scene is told the chosen one's size, which each of its copies (one per monitor) compares with its own; one that is not plugged in: all of them.
    local mons = {}
    local function show_mon()
        local at, w, h = 0, 0, 0
        for i, m in ipairs(mons) do if m.name == cfg.mon then at, w, h = i, m.w, m.h end end
        if fact.fw_mon ~= at then fact.fw_mon = at end
        if fact.fw_sw ~= w then fact.fw_sw = w end
        if fact.fw_sh ~= h then fact.fw_sh = h end
    end
    local function read_mons()
        hypr_monitors(4, function(out, code)
            if code ~= 0 or not out then return end
            local okj, list = pcall(json.decode, out)
            local l = {}
            if okj and type(list) == "table" then
                table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
                for _, j in ipairs(list) do
                    local t = j.transform or 0
                    local sc = (j.scale and j.scale > 0) and j.scale or 1
                    local w, h = math.floor((j.width or 0) / sc + 0.5), math.floor((j.height or 0) / sc + 0.5)
                    if t == 1 or t == 3 or t == 5 or t == 7 then w, h = h, w end
                    l[#l + 1] = { name = tostring(j.name), w = w, h = h }
                end
            else
                -- pleamar-wm's `hyprctl monitors` is text, even with -j: "Monitor <name> (ID 1):", "2560x1440@164.83 at 1440x733" (its sizes already turned by the rotation).
                for name, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID %d+%):\n(.-)\n\n") do
                    local w, h = body:match("(%d+)x(%d+)@[%d%.]+ at")
                    if w then l[#l + 1] = { name = name, w = tonumber(w), h = tonumber(h) } end
                end
            end
            if #l == 0 then return end
            mons = l
            show_mon()
        end)
    end
    read_mons()
    every(5000, read_mons)
    on("fw_mon_set", function(i)
        local m = mons[math.floor((tonumber(i) or 0) + 0.5)]
        cfg.mon = m and m.name or ""
        save()
        show_mon()
    end)
    cava_want()
end
