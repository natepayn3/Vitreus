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

-- Which monitor it is on, and moving it to another (pushed over an edge in Edit mode, or Settings > Widgets): widget_place.luau.
local hooks = {}                    -- (a table, not a global: Luau keeps a global as it was when the handler was made)
require("widget_place")({
    scene = "desktopclock", cfg = cfg, save = save,
    moved = function(gx, gy) cfg.gx = gx; cfg.gy = gy end,
    placed = function() if hooks.hole then hooks.hole() end end,
})

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
    -- the exact number Vitreus pushes (`look_w`): its theme flags alone left Milk, Proxy, Paper and Doodle as Glass, and the later asks overwrote the push
    run("pleamar", { "--say", "vitreus", "get look_w" }, function(out, code)
        if code ~= 0 or not out then return end
        local v = tonumber(out:match("%-?%d+"))
        if v and v >= 0 then fact.look = v end
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
    hooks.hole = soon               -- (and when it goes to another monitor: widget_place.luau's `placed`)
    for _, v in ipairs({ "hl_x", "hl_y", "hl_w", "hl_h", "shown" }) do on("fact:" .. v, soon) end
    on("text:mon_name", soon)
    after(2500, tell)
end
