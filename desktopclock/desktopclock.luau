-- The desktop clock's logic. It reports the digits (the scene draws them) and keeps the settings, which Vitreus's Settings > Clock page changes
-- from outside (`pleamar --say desktopclock "fact lay 1"`).
--
-- `desktopclock.json`, in this scene's own folder (~/.local/share/pleamar/desktopclock): what is missing from it is the default below, and a
-- file that is not there is written so that there is one to edit. It is read when the scene starts.
--   shown        whether the clock is on the desktop
--   use_12_hour  12 or 24 hour clock
--   size         the digits' height in pixels (100 to 340)
--   layout       0 pipe (12 | 34), 1 rule (a line between the hour and the minutes), 2 tower (a column), 3 digital (12:34), 4 slash, 5 hero
--   gx, gy       the cell of its top left corner on the 16 x 9 grid of the desktop (-1: not chosen yet, `position` says)
--   position     "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom" or "bottom_right"
--   monitor      the name of the monitor that shows the clock ("": not chosen yet)
--   weight       the strokes: 0 thin, 1 regular, 2 bold
--   clarity      the glass: 0 clear, 1 soft, 2 full
--   glyphs       a style for the hours ("h"), the minutes ("m") and the divider ("s"): { w = weight multiplier, z = size multiplier, c = tint }, tint 0 the shell's glass,
--                1 mint, 2 light, 3 rose, 4 grey. What is not there is the normal style (1, 1, 0)
local POSITIONS = { top_left = true, top = true, top_right = true, left = true, center = true, right = true, bottom_left = true, bottom = true, bottom_right = true }
local cfg = { shown = true, use_12_hour = true, size = 220, layout = 0, position = "center", gx = -1, gy = -1, monitor = "", weight = 1, clarity = 1, grid = 2 }
local GL = { "h", "m", "s" }
local glyphs = {}
for _, g in ipairs(GL) do glyphs[g] = { w = 1, z = 1, c = 0 } end
local function clampi(v, lo, hi) return math.max(lo, math.min(hi, math.floor(v + 0.5))) end
do
    local ok, saved = pcall(sys.ask, "files.read", "desktopclock.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
        -- The grid used to be 16 x 9 and is 28 x 16: a position saved on the old one is carried over to the same place on the new one (once, `grid` says which it was saved on).
        if saved.grid ~= 2 then
            if cfg.gx >= 0 then cfg.gx = math.floor(cfg.gx * 28 / 16 + 0.5) end
            if cfg.gy >= 0 then cfg.gy = math.floor(cfg.gy * 16 / 9 + 0.5) end
            cfg.migrated = true
        end
        cfg.size = math.max(100, math.min(340, cfg.size))
        cfg.layout = clampi(cfg.layout, 0, 5)
        cfg.weight = clampi(cfg.weight, 0, 2)
        cfg.clarity = clampi(cfg.clarity, 0, 2)
        if not POSITIONS[cfg.position] then cfg.position = "center" end
        if type(saved.glyphs) == "table" then
            for _, g in ipairs(GL) do
                local v = saved.glyphs[g]
                if type(v) == "table" then
                    if type(v.w) == "number" then glyphs[g].w = math.max(0.4, math.min(2, v.w)) end
                    if type(v.z) == "number" then glyphs[g].z = math.max(0.5, math.min(1.5, v.z)) end
                    if type(v.c) == "number" then glyphs[g].c = clampi(v.c, 0, 4) end
                end
            end
        end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopclock.json", cfg)
    end
end
local function save()
    cfg.glyphs = glyphs
    pcall(sys.call, "files.write", "desktopclock.json", cfg)
end
if cfg.migrated then cfg.migrated = nil; cfg.grid = 2; save() end

fact.px = cfg.size
fact.h12 = cfg.use_12_hour
fact.lay = cfg.layout
fact.where = cfg.position
fact.gx = cfg.gx
fact.gy = cfg.gy
fact.wti = cfg.weight
fact.cli = cfg.clarity
fact.shown = cfg.shown

-- Where the monitors lie, in the order of the scene's copies (`screen.index`), which is not the order `hyprctl monitors` lists them in: the copies' sizes
-- are read from `pleamar --say desktopclock describe` and matched to hyprctl's monitors by size. The card is kept by the monitor's name; when none was
-- chosen yet it goes to the first monitor `hyprctl` lists.
local names = {}
local function refresh_monitors()
    run("hyprctl", { "monitors", "-j" }, function(out, code)
        if code ~= 0 or not out then return end
        local ok, list = pcall(json.decode, out)
        if not ok or type(list) ~= "table" then
            -- pleamar-wm's `hyprctl monitors` is text ("Monitor <name> (ID 1):", "2560x1440@164.83 at 1440x730", "scale: 1.00", "focused: yes"), its sizes already turned by the rotation.
            ok, list = true, {}
            for name, id, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID (%d+)%):\n(.-)\n\n") do
                local w, h, x, y = body:match("(%d+)x(%d+)@[%d%.]+ at (%-?%d+)x(%-?%d+)")
                if w then
                    list[#list + 1] = { id = tonumber(id), name = name, width = tonumber(w), height = tonumber(h), x = tonumber(x), y = tonumber(y),
                        scale = tonumber(body:match("scale:%s*([%d.]+)")) or 1, transform = 0, focused = body:find("focused: yes", 1, true) ~= nil }
                end
            end
        end
        if not ok or type(list) ~= "table" or #list == 0 then return end
        table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
        local mons = {}
        for i, d in ipairs(list) do
            if i > 4 then break end
            local sc = tonumber(d.scale) or 1
            local w, h = (tonumber(d.width) or 0) / sc, (tonumber(d.height) or 0) / sc
            if (tonumber(d.transform) or 0) % 2 == 1 then w, h = h, w end
            mons[i] = { name = d.name, x = tonumber(d.x) or 0, y = tonumber(d.y) or 0, w = math.floor(w + 0.5), h = math.floor(h + 0.5) }
        end
        run("pleamar", { "--say", "desktopclock", "describe" }, function(desc, code2)
            local order = {}
            if code2 == 0 and desc then
                -- each line says which copy it is (`screen N`, the copy's `screen.index`): the copies are not always in the same order from one start to the next
                local used = {}
                for n, w, h in desc:gmatch("%(screen (%d+)%) [^\n]-panel (%d+)\xC3\x97(%d+)") do
                    n, w, h = tonumber(n), tonumber(w), tonumber(h)
                    for i, m in ipairs(mons) do
                        if not used[i] and m.w == w and m.h == h and n < 4 and not order[n + 1] then used[i] = true; order[n + 1] = m; break end
                    end
                end
                for k = 1, #mons do if not order[k] then order = {}; break end end
            end
            if #order ~= #mons then order = mons end   -- (what describe says does not fit: hyprctl's own order)
            names = {}
            local primary, mine = 0, nil
            for k = 1, 4 do
                local d = order[k]
                fact["m" .. (k - 1) .. "x"] = d and d.x or 0
                fact["m" .. (k - 1) .. "y"] = d and d.y or 0
                fact["m" .. (k - 1) .. "w"] = d and d.w or 0
                fact["m" .. (k - 1) .. "h"] = d and d.h or 0
                names[k] = d and d.name or nil
                if d and d.name == cfg.monitor then mine = k - 1 end
            end
            -- the monitor it was on, or (when that one is gone, or none was chosen yet) the main one
            fact.mon = mine or primary
            text.mon_name = names[(mine or primary) + 1] or ""
            if cfg.monitor == "" then cfg.monitor = names[primary + 1] or ""; save() end
        end)
    end)
end
-- Monitors come and go rarely. On Hyprland its event socket says when (a monitor added or removed, a config reload that may move one), and a
-- look every minute covers a missed event; without that socket (niri, pleamar-wm) it is every five seconds, as it always was.
local mon_events = false
local function watch_monitors(refresh)
    run("printenv", { "XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code)
        local rt, sig = (out or ""):match("^([^\n]+)\n([^\n]+)")
        if code ~= 0 or not rt or not sig then return end
        local ok = pcall(spawn, "socat", { "-u", "UNIX-CONNECT:" .. rt .. "/hypr/" .. sig .. "/.socket2.sock", "-" }, function(line)
            if line:match("^monitoradded") or line:match("^monitorremoved") or line:match("^configreloaded") then after(400, refresh) end
        end, function()
            mon_events = false
            after(5000, function() watch_monitors(refresh) end)
        end)
        mon_events = ok
    end)
end
local mon_ticks = 0
local function mon_due()
    mon_ticks = mon_ticks + 1
    return not mon_events or mon_ticks % 12 == 0
end
refresh_monitors()
watch_monitors(refresh_monitors)
every(5000, function() if mon_due() and not fact.dragging then refresh_monitors() end end)

-- The glyph styles: a fact each (`ghw` is the hours' weight, `ghz` their size, `ghc` their tint; `gm…` the minutes', `gs…` the divider's), and all of them in `gpack`,
-- "w,z,c;" for each glyph in order, so that the Settings page reads them at once.
local function pack()
    local parts = {}
    for _, g in ipairs(GL) do parts[#parts + 1] = string.format("%.2f,%.2f,%d", glyphs[g].w, glyphs[g].z, glyphs[g].c) end
    text.gpack = table.concat(parts, ";")
end
for _, g in ipairs(GL) do
    fact["g" .. g .. "w"] = glyphs[g].w
    fact["g" .. g .. "z"] = glyphs[g].z
    fact["g" .. g .. "c"] = glyphs[g].c
end
pack()

local last = nil
local function show_time(c)
    last = c
    local h = c.hour
    if cfg.use_12_hour then
        h = h % 12
        if h == 0 then h = 12 end
    end
    fact.d0 = (h >= 10) and (h // 10) or (cfg.use_12_hour and -1 or 0)
    fact.d1 = h % 10
    fact.d2 = c.minute // 10
    fact.d3 = c.minute % 10
end
sys.watch("clock", show_time)

-- What the Settings page tells it (it does not fire for what is set from here).
on("fact:shown", function(v) cfg.shown = v and true or false; save() end)
on("fact:px", function(v) if type(v) == "number" then cfg.size = math.max(100, math.min(340, v)); save() end end)
on("fact:lay", function(v) if type(v) == "number" then cfg.layout = clampi(v, 0, 5); save() end end)
on("fact:where", function(v) if POSITIONS[v] then cfg.position = v; save() end end)
on("fact:gx", function(v) if type(v) == "number" then cfg.gx = v; save() end end)
on("fact:gy", function(v) if type(v) == "number" then cfg.gy = v; save() end end)
on("fact:wti", function(v) if type(v) == "number" then cfg.weight = clampi(v, 0, 2); save() end end)
on("fact:mon", function(v) local n = type(v) == "number" and names[clampi(v, 0, 3) + 1]; if n and n ~= cfg.monitor then cfg.monitor = n; text.mon_name = n; save() end end)
-- Settings > Widgets: "show it on this monitor", by name.
on("text:mon_name", function(t)
    for k = 1, 4 do
        if names[k] and names[k] == t then fact.mon = k - 1; cfg.monitor = t; save() return end
    end
    text.mon_name = cfg.monitor      -- a monitor that is not plugged in (a theme's pinned one, Settings > Theme > Pin widgets): it stays where it is, and says so
end)
on("fact:cli", function(v) if type(v) == "number" then cfg.clarity = clampi(v, 0, 2); save() end end)
for _, g in ipairs(GL) do
    on("fact:g" .. g .. "w", function(v) if type(v) == "number" then glyphs[g].w = math.max(0.4, math.min(2, v)); pack(); save() end end)
    on("fact:g" .. g .. "z", function(v) if type(v) == "number" then glyphs[g].z = math.max(0.5, math.min(1.5, v)); pack(); save() end end)
    on("fact:g" .. g .. "c", function(v) if type(v) == "number" then glyphs[g].c = clampi(v, 0, 4); pack(); save() end end)
end
on("fact:greset", function(v)
    if v ~= 1 then return end
    for _, g in ipairs(GL) do
        glyphs[g] = { w = 1, z = 1, c = 0 }
        fact["g" .. g .. "w"] = 1
        fact["g" .. g .. "z"] = 1
        fact["g" .. g .. "c"] = 0
    end
    pack(); save()
    fact.greset = 0
end)
on("fact:h12", function(v)
    cfg.use_12_hour = v and true or false
    save()
    if last then show_time(last) end
end)

-- Whether Vitreus has its glass off (then this is flat obsidian): asked of it when this starts (it says so itself when it changes), and again a
-- few seconds in, for when Vitreus starts after this does.
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
ask_obs()
after(4000, ask_obs)
-- And which theme it has (0 Glass, 1 Retro, 2 UwU, 3 Cyber): Retro, UwU and Cyber draw this as plastic, like the bar. Vitreus tells it when the theme changes.
local function ask_look()
    run("pleamar", { "--say", "vitreus", "get cas" }, function(cas, code)
        if code ~= 0 or not cas then return end
        run("pleamar", { "--say", "vitreus", "get uwu" }, function(uwu, code2)
            if code2 ~= 0 or not uwu then return end
            run("pleamar", { "--say", "vitreus", "get cyber_on" }, function(cy, code3)
                if code3 ~= 0 or not cy then return end
                fact.look = cas:match("true") and 1 or (uwu:match("true") and 2 or (cy:match("true") and 3 or 0))
            end)
        end)
    end)
end
-- Its colours come from Vitreus too (as facts): ask for them at start, when this scene has just opened with the stock ones.
run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end)
ask_look()
after(250, ask_look)             -- a reload (the palette changed with the theme) starts from Glass: ask again at once, not only on the 4 s timer
after(900, ask_look)
after(2000, ask_look)
after(4000, ask_look)

-- Where the face is, told to the shell (`text hole_clk`: "monitor|x,y,w,h", empty while it is off the desktop) so that the window manager's desktop-click zone leaves a hole
-- there: a zone over a bottom-layer widget takes its clicks (logic/desk_holes.luau). Told once it has stopped moving.
do
    local sent, waiting = nil, false
    local function tell()
        local line = ""
        local w, h = tonumber(fact.hl_w) or 0, tonumber(fact.hl_h) or 0
        local name = text.mon_name
        if fact.shown and name and name ~= "" and w > 1 and h > 1 then
            line = string.format("%s|%d,%d,%d,%d", name, math.floor(fact.hl_x + 0.5), math.floor(fact.hl_y + 0.5), math.floor(w + 0.5), math.floor(h + 0.5))
        end
        if sent == line then return end
        sent = line
        run("pleamar", { "--say", "vitreus", "text hole_clk " .. line }, function() end)
    end
    local function soon()
        if waiting then return end
        waiting = true
        after(300, function() waiting = false; tell() end)
    end
    for _, v in ipairs({ "hl_x", "hl_y", "hl_w", "hl_h", "shown" }) do on("fact:" .. v, soon) end
    on("text:mon_name", soon)
    after(2500, tell)
end

-- Until the monitors are known the card is on none of them (`mon` starts at -1): it used to show on the first copy of the scene for a few seconds and then jump to its own
-- monitor. If they are never learnt (no `hyprctl`), it takes the first one after ten seconds.
after(10000, function()
    for _, k in ipairs({ "mon" }) do if (tonumber(fact[k]) or 0) < 0 then fact[k] = 0 end end
end)
