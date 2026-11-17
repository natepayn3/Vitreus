-- The desktop clock's logic. It reports the digits (the scene draws them) and keeps the settings, which Vitreus's Settings > Clock page changes
-- from outside (`pleamar --say desktopclock "fact sty 1"`).
--
-- `desktopclock.json`, in this scene's own folder (~/.local/share/pleamar/desktopclock): what is missing from it is the default below, and a
-- file that is not there is written so that there is one to edit. It is read when the scene starts.
--   shown        whether the clock is on the desktop
--   use_12_hour  12 or 24 hour clock
--   size         the digits' height in pixels (50 to 190)
--   style        0 Glass (12 | 34 in glass digits), 1 Day (the weekday huge, the time in a glass chip, the weather), 2 Stack (the hour over the smaller minutes),
--                3 Capsule (one glass pill: the time and the date), 4 Editorial (the weekday, the time large and light, the date). A file from before the styles
--                has `layout` (six layouts of the glass digits) instead: the rule becomes Stack, the rest Glass.
--   gx, gy       the cell of its top left corner on the 16 x 9 grid of the desktop (-1: not chosen yet, `position` says)
--   position     "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom" or "bottom_right"
--   monitor      the name of the monitor that shows the clock ("": not chosen yet)
local POSITIONS = { top_left = true, top = true, top_right = true, left = true, center = true, right = true, bottom_left = true, bottom = true, bottom_right = true }
local cfg = { shown = true, use_12_hour = true, size = 100, style = 0, position = "center", gx = -1, gy = -1, monitor = "", grid = 2 }
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
        cfg.size = math.max(50, math.min(190, cfg.size))
        if type(saved.style) ~= "number" and type(saved.layout) == "number" then
            cfg.style = (clampi(saved.layout, 0, 5) == 1) and 2 or 0
            cfg.migrated = true
        end
        cfg.style = clampi(cfg.style, 0, 4)
        if not POSITIONS[cfg.position] then cfg.position = "center" end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopclock.json", cfg)
    end
end
local function save()
    pcall(sys.call, "files.write", "desktopclock.json", cfg)
end
if cfg.migrated then cfg.migrated = nil; cfg.grid = 2; cfg.layout = nil; cfg.weight = nil; cfg.clarity = nil; cfg.glyphs = nil; save() end

fact.px = cfg.size
fact.h12 = cfg.use_12_hour
fact.sty = cfg.style
fact.where = cfg.position
fact.gx = cfg.gx
fact.gy = cfg.gy
fact.shown = cfg.shown

-- Which monitor it is on, and moving it to another (pushed over an edge in Edit mode, or Settings > Widgets): widget_place.luau.
local hooks = {}                    -- (a table, not a global: Luau keeps a global as it was when the handler was made)
require("widget_place")({
    scene = "desktopclock", cfg = cfg, save = save,
    moved = function(gx, gy) cfg.gx = gx; cfg.gy = gy end,
    placed = function() if hooks.hole then hooks.hole() end end,
})

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
    -- and as words, for the styles set in type
    local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
    local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
    local hh = cfg.use_12_hour and tostring(h) or string.format("%02d", h)
    text.ck_tm = string.format("%s:%02d", hh, c.minute)
    text.ck_ap = cfg.use_12_hour and ((c.hour < 12) and "AM" or "PM") or ""
    local day = DAYS[(c.weekday or 0) % 7 + 1]
    local mon = MONTHS[math.max(1, math.min(12, c.month or 1))]
    text.ck_wdl = day
    text.ck_wd = string.upper(string.sub(day, 1, 3))
    text.ck_dt = string.format("%s %d %d", string.upper(mon), c.day or 1, c.year or 2026)
    text.ck_dts = string.format("%d %s", c.day or 1, mon)
    text.ck_dtl = string.format("%s %d, %d", mon, c.day or 1, c.year or 2026)
end
sys.watch("clock", show_time)

-- What the Settings page tells it (it does not fire for what is set from here).
on("fact:shown", function(v) cfg.shown = v and true or false; save() end)
on("fact:px", function(v) if type(v) == "number" then cfg.size = math.max(50, math.min(190, v)); save() end end)
on("fact:sty", function(v) if type(v) == "number" then cfg.style = clampi(v, 0, 4); save() end end)
on("fact:where", function(v) if POSITIONS[v] then cfg.position = v; save() end end)
on("fact:gx", function(v) if type(v) == "number" then cfg.gx = v; save() end end)
on("fact:gy", function(v) if type(v) == "number" then cfg.gy = v; save() end end)
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

-- The weather, for Day: the shell's own (it fetches it for its calendar), asked of it at start and every five minutes. Nothing to show until it has some.
local function ask_wx()
    run("pleamar", { "--say", "vitreus", "get wx_ok", "get wx_kind", "get wx_temp", "get wx_desc" }, function(out, code)
        if code ~= 0 or not out then return end
        local l = {}
        for line in (out .. "\n"):gmatch("([^\n]*)\n") do l[#l + 1] = line end
        local ok = (l[1] or ""):match("true") ~= nil
        local temp = (l[3] or ""):gsub("%s+$", "")
        if ok and temp ~= "" then
            fact.wx_kind = tonumber((l[2] or ""):match("%-?%d+")) or 2
            text.wx_temp = temp
            text.wx_desc = (l[4] or ""):gsub("%s+$", "")
        end
        fact.wx_on = ok and temp ~= ""
    end)
end
after(3000, ask_wx)
after(20000, ask_wx)
every(300000, ask_wx)

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
