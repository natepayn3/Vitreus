-- The desktop system monitor's logic. It runs `vitreus-sysmon` while the card is shown and turns each line into the numbers the scene draws (a
-- small cut of what vitreus.luau does for Settings > System monitor), and keeps the settings, which can be changed from outside
-- (`pleamar --say desktopsysmon "fact where top_left"`).
--
-- `desktopsysmon.json`, in this scene's own folder (~/.local/share/pleamar/desktopsysmon): what is missing from it is the default below, and a
-- file that is not there is written so that there is one to edit. It is read when the scene starts.
--   shown      whether the card is on the desktop
--   gx, gy     the cell of its top left corner on the 16 x 9 grid of the desktop (-1: not chosen yet, `position` says)
--   position   "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom" or "bottom_right"
--   monitor    the name of the monitor that shows the card ("": not chosen yet)
--   clarity    the glass: 0 clear, 1 soft, 2 full
local POSITIONS = { top_left = true, top = true, top_right = true, left = true, center = true, right = true, bottom_left = true, bottom = true, bottom_right = true }
local cfg = { shown = false, position = "bottom_right", gx = -1, gy = -1, monitor = "", clarity = 1, grid = 2 }
local function clampi(v, lo, hi) return math.max(lo, math.min(hi, math.floor(v + 0.5))) end
do
    local ok, saved = pcall(sys.ask, "files.read", "desktopsysmon.json", "json")
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
        cfg.clarity = clampi(cfg.clarity, 0, 2)
        if not POSITIONS[cfg.position] then cfg.position = "bottom_right" end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopsysmon.json", cfg)
    end
end
local function save() pcall(sys.call, "files.write", "desktopsysmon.json", cfg) end
if cfg.migrated then cfg.migrated = nil; cfg.grid = 2; save() end

fact.where = cfg.position
fact.gx = cfg.gx
fact.gy = cfg.gy
fact.cli = cfg.clarity

-- Which monitor it is on, and moving it to another (pushed over an edge in Edit mode, or Settings > Widgets): widget_place.luau (a link to
-- desktopclock/'s, which it shares).
local hooks = {}                    -- (a table, not a global: Luau keeps a global as it was when the handler was made)
require("widget_place")({
    scene = "desktopsysmon", cfg = cfg, save = save,
    moved = function(gx, gy) cfg.gx = gx; cfg.gy = gy end,
    placed = function() if hooks.hole then hooks.hole() end end,
})
fact.shown = cfg.shown

local function clamp(v) return math.max(0, math.min(1, v or 0)) end
local function size(b)
    b = b or 0
    local units = { "B", "KB", "MB", "GB", "TB", "PB" }
    local i = 1
    while b >= 1024 and i < #units do b = b / 1024; i = i + 1 end
    if i == 1 then return string.format("%d B", b) end
    if b >= 100 then return string.format("%.0f %s", b, units[i]) end
    if b >= 10 then return string.format("%.1f %s", b, units[i]) end
    return string.format("%.2f %s", b, units[i])
end
local function uptime(s)
    s = s or 0
    local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
    if d > 0 then return string.format("up %dd %dh", d, h) end
    if h > 0 then return string.format("up %dh %dm", h, m) end
    return string.format("up %dm", m)
end

local hist = {}     -- the last minute of the network: { rx, tx } in bytes a second
local function on_line(line)
    local ok, d = pcall(json.decode, line)
    if not ok or type(d) ~= "table" or not d.cpu then return end
    if d.info then text.host = d.info.host or "" end
    text.up = uptime(d.up)

    local total = d.cpu.total or 0
    fact.cpu_f = clamp(total / 100)
    text.cpu_txt = string.format("%d%%", math.floor(total + 0.5))
    local sum, n = 0, 0
    for _, f in ipairs(d.cpu.mhz or {}) do if f > 0 then sum = sum + f; n = n + 1 end end
    local meta = n > 0 and string.format("%.1f GHz", sum / n / 1000) or ""
    for _, t in ipairs(d.temps or {}) do
        if t.l == "CPU package" then meta = (meta ~= "" and (meta .. " · ") or "") .. string.format("%d°C", math.floor(t.c + 0.5)); break end
    end
    text.cpu_meta = meta

    local m = d.mem or {}
    local mt = math.max(m.total or 1, 1)
    fact.mem_f = clamp((m.used or 0) / mt)
    text.mem_txt = string.format("%d%%", math.floor(clamp((m.used or 0) / mt) * 100 + 0.5))
    text.mem_meta = string.format("%.1f / %.1f GB", (m.used or 0) / 1048576, (m.total or 0) / 1048576)

    local g = d.gpu
    fact.gpu_on = g ~= nil
    if g then
        fact.gpu_f = clamp((g.util or 0) / 100)
        text.gpu_txt = string.format("%d%%", math.floor((g.util or 0) + 0.5))
        local parts = {}
        if (g.mem_total or 0) > 0 then parts[#parts + 1] = string.format("%.1f / %.1f GB", (g.mem_used or 0) / 1024, g.mem_total / 1024) end
        if g.temp then parts[#parts + 1] = string.format("%d°C", math.floor(g.temp + 0.5)) end
        text.gpu_meta = table.concat(parts, " · ")
    end

    local nt = d.net or {}
    text.rx_txt = "↓ " .. size(nt.rx) .. "/s"
    text.tx_txt = "↑ " .. size(nt.tx) .. "/s"
    hist[#hist + 1] = { rx = nt.rx or 0, tx = nt.tx or 0 }
    if #hist > 60 then table.remove(hist, 1) end
    -- each against the biggest in view (at least 50 KB/s, so that a quiet line stays flat)
    local top = 50 * 1024
    for _, h in ipairs(hist) do top = math.max(top, h.rx, h.tx) end
    -- two columns for each sample, between them a Catmull-Rom curve, so that the bars read as one smooth line
    local function at(i) return hist[math.max(1, math.min(#hist, i))] end
    local function cr(p0, p1, p2, p3, t)
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
    end
    local rows = {}
    for i = 1, #hist do
        for _, t in ipairs({ 0.5, 1 }) do
            local a, b, c, d = at(i - 2), at(i - 1), at(i), at(i + 1)
            -- between sample i-1 and i (the very first one has nothing before it)
            local r = cr(a.rx, b.rx, c.rx, d.rx, t) / top
            local u = cr(a.tx, b.tx, c.tx, d.tx, t) / top
            rows[#rows + 1] = { rx = math.max(0, r), tx = math.max(0, u) }
        end
    end
    model.net_h = rows
    fact.net_step = fact.net_step + 1
end

-- The AUR: Vitreus asks it, once for the shell (logic/aur.luau, every half hour), and tells this card each time (`aur_txt`, `aur_on`), so the
-- widget and the Desk never ask twice or disagree. Started after Vitreus, or shown again, the card asks Vitreus for the last answer.
local function ask_aur()
    run("pleamar", { "--say", "vitreus", "get aur_line" }, function(out, code)
        local t = tostring(out or ""):gsub("%s+$", "")
        if code == 0 and t ~= "" and t:sub(1, 1) ~= "?" then text.aur_txt = t; fact.aur_on = true end
    end)
end
after(6000, function() if fact.shown then ask_aur() end end)

-- It runs while the card is shown, so nothing is read when it is not.
local proc = nil
local function refresh()
    if fact.shown and not proc then
        local mine
        mine = spawn("vitreus-sysmon", {}, function(line) if proc == mine then on_line(line) end end,
            function() if proc == mine then proc = nil end end)
        proc = mine
    elseif not fact.shown and proc then
        kill(proc, "term")
        proc = nil
        hist = {}
    end
end
refresh()

-- What the Settings page tells it (it does not fire for what is set from here).
on("fact:shown", function(v) cfg.shown = v and true or false; save(); refresh(); if cfg.shown then ask_aur() end end)
on("fact:where", function(v) if POSITIONS[v] then cfg.position = v; save() end end)
on("fact:gx", function(v) if type(v) == "number" then cfg.gx = v; save() end end)
on("fact:gy", function(v) if type(v) == "number" then cfg.gy = v; save() end end)
on("fact:cli", function(v) if type(v) == "number" then cfg.clarity = clampi(v, 0, 2); save() end end)

-- Whether Vitreus has its glass off (then this is flat obsidian): asked of it when this starts (it says so itself when it changes), and again a
-- few seconds in, for when Vitreus starts after this does.
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
ask_obs()
after(4000, ask_obs)
-- And which theme it has (0 Glass, 1 Retro, 2 UwU): Retro and UwU draw this as plastic, like the bar. Vitreus tells it when the theme changes.
local function ask_look()
    -- the exact number Vitreus pushes (`look_w`): its theme flags alone left Milk, Proxy, Paper and Doodle as Glass, and the later asks overwrote the push
    run("pleamar", { "--say", "vitreus", "get look_w" }, function(out, code)
        if code ~= 0 or not out then return end
        local v = tonumber(out:match("%-?%d+"))
        if v and v >= 0 then fact.look = v end
    end)
end
ask_look()
after(4000, ask_look)

-- The room the bar's frame takes (`room_*`) is told by Vitreus when it changes; asked for at start (this scene starts after the shell may have said it).
run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end)
after(1500, function() run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end) end)

-- Where the card is, told to the shell (`text hole_sys`: "monitor|x,y,w,h", empty while it is off the desktop) so that the window manager's desktop-click zone leaves a hole
-- there: a zone over a bottom-layer widget takes its clicks (logic/desk_holes.luau). Told once it has stopped moving.
do
    local sent, waiting = nil, false
    local function tell()
        local line = ""
        local w, h = tonumber(fact.hw) or 0, tonumber(fact.hh) or 0
        local name = text.mon_name
        if fact.shown and name and name ~= "" and w > 1 and h > 1 then
            line = string.format("%s|%d,%d,%d,%d", name, math.floor(fact.hx + 0.5), math.floor(fact.hy + 0.5), math.floor(w + 0.5), math.floor(h + 0.5))
        end
        if sent == line then return end
        sent = line
        run("pleamar", { "--say", "vitreus", "text hole_sys " .. line }, function() end)
    end
    local function soon()
        if waiting then return end
        waiting = true
        after(300, function() waiting = false; tell() end)
    end
    hooks.hole = soon               -- (and when it goes to another monitor: widget_place.luau's `placed`)
    for _, v in ipairs({ "hx", "hy", "hw", "hh", "shown" }) do on("fact:" .. v, soon) end
    on("text:mon_name", soon)
    after(2500, tell)
end

