-- Settings > Bar > Workspaces: how the workspace marks look and behave, kept in ws.json, and what the Apps look shows: the icons of up to three apps
-- on each workspace (`wsic.N.K`, `ws.N.ni` in the scene). The scene morphs between the looks, so each choice is at once.
-- How many windows each workspace has (`ws.N.n`, for the pips and the rings) is set where the workspaces are read, in vitreus.luau.
--
-- `shared`: `icon_for(class)` (the icon of a program from its class, the apps' own table in vitreus.luau), `clients(done)` (Hyprland's and niri's windows,
-- parsed `hyprctl clients`), `where()` ("hypr", "niri" or "wm", once it is known).
return function(shared)
    local O = { style = 0, all = false, count = 5, nums = false, plus = true, motion = 0, pulse = false, size = 1, gap = 9, accent = 0, numerals = 0 }

    local function show()
        fact.ws_style = O.style
        fact.ws_all = O.all
        fact.ws_count = O.count
        fact.ws_nums = O.nums
        fact.ws_plus_on = O.plus
        fact.ws_motion = O.motion
        fact.ws_pulse = O.pulse
        fact.ws_size = O.size
        fact.ws_gap = O.gap
        fact.ws_accent = O.accent
        fact.ws_numerals = O.numerals
        text.ws_size_text = string.format("%d%%", math.floor(O.size * 100 + 0.5))
        text.ws_gap_text = tostring(math.floor(O.gap + 0.5))
    end
    local function save() pcall(sys.call, "files.write", "ws.json", O) end

    -- What was kept; from before ws.json, the look bar.json had (squares, dots, numbers, lines: the nearest new one).
    local ok, saved = pcall(sys.ask, "files.read", "ws.json", "json")
    if ok and type(saved) == "table" then
        local function num(k, lo, hi) if type(saved[k]) == "number" and saved[k] >= lo and saved[k] <= hi then O[k] = saved[k] end end
        local function bool(k) if type(saved[k]) == "boolean" then O[k] = saved[k] end end
        num("style", 0, 4); num("motion", 0, 2); num("accent", 0, 2); num("numerals", 0, 2); num("size", 0.75, 1.5); num("gap", 4, 16)
        if saved.count == 5 or saved.count == 10 then O.count = saved.count end
        bool("all"); bool("nums"); bool("plus"); bool("pulse")
        O.style = math.floor(O.style); O.motion = math.floor(O.motion); O.accent = math.floor(O.accent); O.numerals = math.floor(O.numerals)
    else
        local okb, bar = pcall(sys.ask, "files.read", "bar.json", "json")
        if okb and type(bar) == "table" and type(bar.ws_style) == "number" then
            O.style = ({ [0] = 0, [1] = 1, [2] = 3, [3] = 0 })[math.floor(bar.ws_style)] or 0
        end
    end
    show()

    local function pick(key, n, hi)
        n = math.floor(tonumber(n) or -1)
        if n < 0 or n > hi then return end
        O[key] = n
        show(); save()
    end
    on("ws_pick_style", function(n) pick("style", n, 4); shared.refresh_icons() end)
    on("ws_pick_motion", function(n) pick("motion", n, 2) end)
    on("ws_pick_accent", function(n) pick("accent", n, 2) end)
    on("ws_pick_numerals", function(n) pick("numerals", n, 2) end)
    on("ws_pick_count", function(n)
        n = math.floor(tonumber(n) or -1)
        if n ~= 0 and n ~= 1 then return end
        O.count = n == 1 and 10 or 5
        show(); save()
    end)
    on("ws_pick_urgent", function(n)
        n = math.floor(tonumber(n) or -1)
        if n ~= 0 and n ~= 1 then return end
        O.pulse = n == 1
        show(); save()
    end)
    on("ws_toggle_all", function() O.all = not O.all; show(); save() end)
    on("ws_toggle_nums", function() O.nums = not O.nums; show(); save() end)
    on("ws_toggle_plus", function() O.plus = not O.plus; show(); save() end)
    -- The sliders: the level along them, 0..1. Size in steps of 5 %, spacing in whole steps. Written a little after the last move of a drag, not at every step.
    local pending = 0
    local function save_soon()
        pending = pending + 1
        local mine = pending
        after(400, function() if mine == pending then save() end end)
    end
    on("ws_set_size", function(v)
        v = math.max(0, math.min(1, tonumber(v) or 0))
        local s = math.floor((0.75 + 0.75 * v) * 20 + 0.5) / 20
        if s == O.size then return end
        O.size = s
        show(); save_soon()
    end)
    on("ws_set_gap", function(v)
        v = math.max(0, math.min(1, tonumber(v) or 0))
        local g = math.floor(4 + 12 * v + 0.5)
        if g == O.gap then return end
        O.gap = g
        show(); save_soon()
    end)

    -- The Apps look: for each of workspaces 1 to 10, its programs (one icon each, however many windows it has), in a stable order (by when the program was first
    -- seen there), up to three. Only asked for while the Apps look is chosen: on a change of workspaces, and every few seconds for what that does not say
    -- (a window moved from one workspace to another, a program that changed its class).
    local last = ""
    local shown = {}                       -- what each icon slot was last given
    local function publish(per)
        local sig = {}
        for i = 1, 10 do sig[i] = table.concat(per[i] or {}, ",") end
        local joined = table.concat(sig, "|")
        if joined == last then return end
        last = joined
        for i = 1, 10 do
            local l = per[i] or {}
            fact["ws." .. i .. ".ni"] = math.min(3, #l)
            for k = 0, 2 do
                local v, name = l[k + 1] or "", "wsic." .. i .. "." .. k
                if shown[name] ~= v then shown[name] = v; text[name] = v end
            end
        end
    end
    local function add(per, seen, wsn, class)
        if not wsn or wsn < 1 or wsn > 10 or class == "" then return end
        local icon = shared.icon_for(class)
        per[wsn] = per[wsn] or {}
        seen[wsn] = seen[wsn] or {}
        if not seen[wsn][icon] then seen[wsn][icon] = true; per[wsn][#per[wsn] + 1] = icon end
    end
    local busy = false
    local function refresh()
        if O.style ~= 2 or busy then return end
        local where = shared.where()
        if where == nil then return end
        busy = true
        if where == "wm" then
            local cmds = {}
            for i = 0, 15 do for _, f in ipairs({ "open", "app", "workspace" }) do cmds[#cmds + 1] = "get win." .. i .. "." .. f end end
            say_many("wm", cmds, function(r)
                busy = false
                if not r then return end
                local per, seen = {}, {}
                for i = 0, 15 do
                    local b = i * 3
                    if (r[b + 1] or ""):match("true") then
                        add(per, seen, math.floor(tonumber((r[b + 3] or ""):match("%-?[%d.]+")) or 0), ((r[b + 2] or ""):gsub("%s+$", "")):lower())
                    end
                end
                publish(per)
            end)
        else
            shared.clients(function(list)
                busy = false
                if not list then return end
                -- in the order the windows were opened (their address grows), so the icons keep their places
                table.sort(list, function(a, b) return tostring(a.addr) < tostring(b.addr) end)
                local per, seen = {}, {}
                for _, w in ipairs(list) do
                    if w.mapped ~= "0" then
                        add(per, seen, tonumber((w.workspace or ""):match("^(%-?%d+)")), (w.class or ""):lower())
                    end
                end
                publish(per)
            end)
        end
    end
    shared.refresh_icons = function() last = ""; refresh() end
    local soon = false
    sys.watch("workspaces", function()
        if soon then return end
        soon = true
        after(150, function() soon = false; refresh() end)
    end)
    every(2500, refresh)
    after(2000, refresh)
end
