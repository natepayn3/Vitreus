-- Which monitor a desktop widget is on: shared by the desktop widgets (desktopclock/, desktopsysmon/: a link to this file in each folder).
--
-- The scene has one surface a monitor (`sl0` to `sl3`, on the monitors the texts `s0` to `s3` name, `sx*`, `sy*` where each is in the desktop, `sm*` whether
-- there is one), and keeps the widget's place in the desktop's coordinates: each surface draws what falls on it. Out of Edit mode only the widget's own
-- monitor (`hk`) has its surface, and none while the widget is hidden: a widget used to be a full-screen copy of its scene on every monitor (~27 MB on the
-- card each), drawing on one. In Edit mode every monitor has one, put there as the editor opens and taken off as it shuts, so that none is made, moved or
-- taken off while the widget is dragged from one monitor to another: a layer fades in and out as it comes and goes (that was the flicker), and moving
-- the surface that took the press ended the drag. Dragged, it goes from cell to cell on the grid of the monitor the pointer is over, and stays where it
-- is let go (the scene sets `hk`, `gx`, `gy`); nothing runs here meanwhile.
--
-- Its monitor is kept by name (`monitor` in its settings). While that monitor is not plugged in the widget is not shown (it does not move in with another
-- monitor's widgets); in Edit mode it is shown on the first monitor, marked "<name> · not connected" (`orphan`, `orph`), so that one whose monitor is
-- gone for good can be found: put somewhere there, that monitor is its own. Settings > Widgets picks the monitor by name (`text mon_name`).
--
-- The monitors come from `hyprctl monitors` (Hyprland's JSON, or pleamar-wm's text), or, where it does not answer, the names the scene's 1 x 1 copies
-- report (`screen.K.name`): then it is placed, but without where the monitors lie it is not dragged across.
--
-- `w`: { scene = its socket's name, cfg = its settings table (`monitor` is read and written), save = function, placed = function(name) (it is on another
-- monitor now) }.
return function(w)
    local cfg, save = w.cfg, w.save
    local mons = {}                 -- { name, x, y, w, h } (all but the name nil when only the name is known), in the compositor's order: slot k is mons[k + 1]

    local function find(name)
        for i, m in ipairs(mons) do if m.name == name then return m, i end end
        return nil
    end
    local function editing() return fact.edit == true or fact.edit == 1 end
    local function shown() return fact.shown == true or fact.shown == 1 end

    -- The surfaces: in Edit mode one on every monitor, out of it the widget's own only (none while it is hidden, or while its monitor is not plugged in).
    -- Its own is `hk`; without its monitor, in Edit mode, the first one, marked.
    local hidden = false
    local last_home = nil
    local function place()
        if not mons[1] then return end
        if cfg.monitor == "" then cfg.monitor = mons[1].name; save() end
        local _, i = find(cfg.monitor)
        local orphan = i == nil
        fact.orphan = orphan
        text.orph = orphan and (cfg.monitor .. " · not connected") or ""
        if text.mon_name ~= cfg.monitor then text.mon_name = cfg.monitor end       -- (its own monitor, plugged in or not: Settings lights that one)
        local home = (i or 1) - 1
        if fact.hk ~= home then fact.hk = home end
        local all = editing()
        for k = 0, 3 do
            local m = mons[k + 1]
            if m and m.x then
                if fact["sx" .. k] ~= m.x then fact["sx" .. k] = m.x end
                if fact["sy" .. k] ~= m.y then fact["sy" .. k] = m.y end
            end
            local here = m ~= nil and ((all and not hidden) or (k == home and not orphan and not hidden))
            if all and m ~= nil and k == home then here = true end
            -- (dragging across needs where the monitors lie: without it, only its own)
            if here and not (m.x or k == home) then here = false end
            local want = here and m.name or ""
            if fact["sm" .. k] ~= here then fact["sm" .. k] = here end
            if text["s" .. k] ~= want then text["s" .. k] = want end
        end
        local name = mons[home + 1] and mons[home + 1].name
        if name ~= last_home then
            last_home = name
            if w.placed then w.placed(name) end
        end
    end

    -- The names the scene's own 1 x 1 copies report: the monitors there are, without where they lie.
    local function from_copies()
        local list, seen = {}, {}
        for k = 0, 3 do
            local nm = text["screen." .. k .. ".name"]
            if nm and nm ~= "" and not seen[nm] then seen[nm] = true; list[#list + 1] = { name = nm } end
        end
        return list
    end

    local function refresh()
        run("hyprctl", { "monitors", "-j" }, function(out, code)
            local list = {}
            if code == 0 and out then
                local ok, got = pcall(json.decode, out)
                if ok and type(got) == "table" then
                    table.sort(got, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
                    for _, d in ipairs(got) do
                        if type(d) == "table" and type(d.name) == "string" then
                            local sc = tonumber(d.scale) or 1
                            local mw, mh = (tonumber(d.width) or 0) / sc, (tonumber(d.height) or 0) / sc
                            if (tonumber(d.transform) or 0) % 2 == 1 then mw, mh = mh, mw end
                            list[#list + 1] = { name = d.name, x = tonumber(d.x) or 0, y = tonumber(d.y) or 0, w = math.floor(mw + 0.5), h = math.floor(mh + 0.5) }
                        end
                    end
                else
                    -- pleamar-wm's `hyprctl monitors` is text ("Monitor <name> (ID 1):", "2560x1440@164.83 at 1440x730").
                    local found = {}
                    for name, id, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID (%d+)%):\n(.-)\n\n") do
                        local mw, mh, x, y = body:match("(%d+)x(%d+)@[%d%.]+ at (%-?%d+)x(%-?%d+)")
                        if x then
                            local sc = tonumber(body:match("scale:%s*([%d.]+)")) or 1
                            found[#found + 1] = { id = tonumber(id), name = name, x = tonumber(x), y = tonumber(y), w = math.floor(tonumber(mw) / sc + 0.5), h = math.floor(tonumber(mh) / sc + 0.5) }
                        end
                    end
                    table.sort(found, function(a, b) return a.id < b.id end)
                    for _, d in ipairs(found) do list[#list + 1] = d end
                end
            end
            if #list == 0 then list = from_copies() end
            while #list > 4 do table.remove(list) end
            if #list == 0 then return end
            mons = list
            place()
        end)
    end

    -- Monitors come and go rarely. On Hyprland its event socket says when (added, removed, a config reload that may move one), with a look every
    -- minute for a missed event; elsewhere every five seconds. Never while it is dragged. A copy reporting a new name (a monitor plugged in) is looked at too.
    local events = false
    local function watch()
        run("printenv", { "XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code)
            local rt, sig = (out or ""):match("^([^\n]+)\n([^\n]+)")
            if code ~= 0 or not rt or not sig then return end
            local ok = pcall(spawn, "socat", { "-u", "UNIX-CONNECT:" .. rt .. "/hypr/" .. sig .. "/.socket2.sock", "-" }, function(line)
                if line:match("^monitoradded") or line:match("^monitorremoved") or line:match("^configreloaded") then after(400, refresh) end
            end, function()
                events = false
                after(5000, watch)
            end)
            events = ok
        end)
    end
    local ticks = 0
    every(5000, function()
        ticks = ticks + 1
        if (not events or ticks % 12 == 0) and not fact.dragging then refresh() end
    end)
    local pending = false
    for k = 0, 3 do
        on("text:screen." .. k .. ".name", function()
            if pending then return end
            pending = true
            after(300, function() pending = false; refresh() end)
        end)
    end
    refresh()
    watch()

    -- Hidden (`shown` false, out of Edit mode): its surface goes once the face has faded out (`sh`, a calm spring: about a second); shown, or Edit mode,
    -- back at once. Edit mode puts a surface on every monitor (empty but for the widget's own), and shutting it takes them off.
    local vis_n = 0
    local function visibility()
        vis_n = vis_n + 1
        local mine = vis_n
        if shown() or editing() then
            hidden = false
            place()
            return
        end
        after(1500, function()
            if mine ~= vis_n then return end
            hidden = true
            place()
        end)
    end
    on("fact:shown", visibility)
    on("fact:edit", visibility)
    after(2000, visibility)         -- (`shown` is set by the logic when it starts, which fires nothing)

    -- Let go on another monitor (the scene sets `hk`): that one is its own now. A widget without its monitor, shown on the first in Edit mode and put
    -- somewhere there, takes that one too.
    on("fact:hk", function(v)
        local m = mons[math.floor((tonumber(v) or 0) + 0.5) + 1]
        if not m then return end
        if m.name ~= cfg.monitor then
            cfg.monitor = m.name
            save()
        end
        place()
    end)
    -- The compositor lets go of a drag as the pointer goes on to another monitor (the scene gets a release there and is not told when the button comes
    -- up on the other side). So a drag that ends by an edge (`edge`) asks bin/vitreus-btnwait whether the button is still down: if it is, the widget is
    -- carried on (`carry`: every monitor's surface hears the pointer, the scene follows it from cell to cell), from where Hyprland says the pointer is,
    -- and when the button comes up it stays where it is (`drop`). Nothing runs meanwhile: the helper waits, blocked on the input devices, and the
    -- pointer comes in as events. Without the helper (no access to the input devices) it stays where the drag ended.
    local on_hypr = false
    run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code) on_hypr = code == 0 and (out or ""):match("%S") ~= nil end)
    -- Where the pointer is while carried, from Hyprland (the desktop's coordinates), every 40 ms: only between the edge and the button coming up.
    local function follow()
        if not fact.carry then return end
        run("hyprctl", { "cursorpos" }, function(out, code)
            if not fact.carry then return end
            local x, y = (out or ""):match("(%-?[%d.]+),%s*(%-?[%d.]+)")
            x, y = tonumber(x), tonumber(y)
            if code == 0 and x and y then
                if fact.pnx ~= x then fact.pnx = x end
                if fact.pny ~= y then fact.pny = y end
            end
            after(40, follow)
        end)
    end
    local function carry_on()
        local up = false            -- (the button came up before the carry began: it is dropped as soon as it does)
        local ok = pcall(spawn, "vitreus-btnwait", { "30" }, function(line)
            if not line:match("down") then return end
            fact.carry = true
            follow()
        end, function()
            up = true
            if fact.carry then after(60, function() fact.drop = true end) end      -- (a moment for the last place of the pointer to come in)
        end)
        return ok
    end
    on("fact:dragging", function(v)
        if v == true or v == 1 then return end
        if fact.edge == true and on_hypr then carry_on() end
        if fact.orphan and mons[1] then         -- (shown on the first monitor without its own, and put somewhere there: that is its own now)
            cfg.monitor = mons[math.floor((tonumber(fact.hk) or 0) + 0.5) + 1].name
            save()
            place()
        end
    end)
    -- Let go (the scene also sets `jump`, to draw it in its new cell at once): `jump` back off a moment later.
    on("fact:jump", function(v)
        if v == true or v == 1 then after(350, function() fact.jump = false end) end
    end)

    -- Settings > Widgets, or a theme's pinned widgets: "show it on this monitor", by name. One that is not plugged in is not taken: it stays where it
    -- is, and says so (the text goes back).
    on("text:mon_name", function(t)
        if find(t) then
            cfg.monitor = t
            save()
            place()
        else
            text.mon_name = cfg.monitor
        end
    end)

    return { refresh = refresh, place = place }
end
