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

-- Where the monitors lie, in the order of the scene's copies (`screen.index`), which is not the order `hyprctl monitors` lists them in: the copies' sizes
-- are read from `pleamar --say desktopsysmon describe` and matched to hyprctl's monitors by size. The card is kept by the monitor's name; when none was
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
        run("pleamar", { "--say", "desktopsysmon", "describe" }, function(desc, code2)
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

-- The AUR, asked once an hour while the card is shown (`yay -Qua` reads only: one request to the AUR's RPC, a second or so). Its exit code is 1 both for
-- "nothing to update" and for an error, so the words it prints say which: lines with "->" are updates, "error" is a failure and the last answer stays.
local aur_checked = false
local function check_aur()
    run("sh", { "-c", "yay -Qua 2>&1" }, function(out)
        out = out or ""
        local n = 0
        for line in out:gmatch("[^\n]+") do
            if line:find("->", 1, true) then n = n + 1 end
        end
        if n > 0 then
            text.aur_txt = string.format("AUR · %d update%s", n, n == 1 and "" or "s")
            fact.aur_on = true
            aur_checked = true
        elseif not out:lower():find("error", 1, true) and not out:lower():find("failed", 1, true) then
            text.aur_txt = "AUR · up to date"
            fact.aur_on = true
            aur_checked = true
        end
    end)
end
every(3600000, function() if fact.shown then check_aur() end end)
after(10000, function() if fact.shown and not aur_checked then check_aur() end end)

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
on("fact:shown", function(v) cfg.shown = v and true or false; save(); refresh(); if cfg.shown and not aur_checked then check_aur() end end)
on("fact:where", function(v) if POSITIONS[v] then cfg.position = v; save() end end)
on("fact:gx", function(v) if type(v) == "number" then cfg.gx = v; save() end end)
on("fact:gy", function(v) if type(v) == "number" then cfg.gy = v; save() end end)
on("fact:mon", function(v) local n = type(v) == "number" and names[clampi(v, 0, 3) + 1]; if n and n ~= cfg.monitor then cfg.monitor = n; text.mon_name = n; save() end end)
-- Settings > Widgets: "show it on this monitor", by name.
on("text:mon_name", function(t)
    for k = 1, 4 do
        if names[k] and names[k] == t then fact.mon = k - 1; cfg.monitor = t; save() return end
    end
    text.mon_name = cfg.monitor      -- a monitor that is not plugged in (a theme's pinned one, Settings > Theme > Pin widgets): it stays where it is, and says so
end)
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
    run("pleamar", { "--say", "vitreus", "get cas" }, function(cas, code)
        if code ~= 0 or not cas then return end
        run("pleamar", { "--say", "vitreus", "get uwu" }, function(uwu, code2)
            if code2 ~= 0 or not uwu then return end
            fact.look = cas:match("true") and 1 or (uwu:match("true") and 2 or 0)
        end)
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
    for _, v in ipairs({ "hx", "hy", "hw", "hh", "shown" }) do on("fact:" .. v, soon) end
    on("text:mon_name", soon)
    after(2500, tell)
end

-- Until the monitors are known the card is on none of them (`mon` starts at -1): it used to show on the first copy of the scene for a few seconds and then jump to its own
-- monitor. If they are never learnt (no `hyprctl`), it takes the first one after ten seconds.
after(10000, function()
    for _, k in ipairs({ "mon" }) do if (tonumber(fact[k]) or 0) < 0 then fact[k] = 0 end end
end)
