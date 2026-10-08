-- The desktop system monitor's logic. It runs `vitreus-sysmon` while the card is shown and turns each line into the numbers the scene draws (a
-- small cut of what vitreus.luau does for Settings > System monitor), and keeps the settings, which can be changed from outside
-- (`pleamar --say desktopsysmon "fact where top_left"`).
--
-- `desktopsysmon.json`, in this scene's own folder (~/.local/share/pleamar/desktopsysmon): what is missing from it is the default below, and a
-- file that is not there is written so that there is one to edit. It is read when the scene starts.
--   shown      whether the card is on the desktop
--   position   "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom" or "bottom_right"
--   clarity    the glass: 0 clear, 1 soft, 2 full
local POSITIONS = { top_left = true, top = true, top_right = true, left = true, center = true, right = true, bottom_left = true, bottom = true, bottom_right = true }
local cfg = { shown = false, position = "bottom_right", clarity = 1 }
local function clampi(v, lo, hi) return math.max(lo, math.min(hi, math.floor(v + 0.5))) end
do
    local ok, saved = pcall(sys.ask, "files.read", "desktopsysmon.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
        cfg.clarity = clampi(cfg.clarity, 0, 2)
        if not POSITIONS[cfg.position] then cfg.position = "bottom_right" end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopsysmon.json", cfg)
    end
end
local function save() pcall(sys.call, "files.write", "desktopsysmon.json", cfg) end

fact.where = cfg.position
fact.cli = cfg.clarity
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
on("fact:cli", function(v) if type(v) == "number" then cfg.clarity = clampi(v, 0, 2); save() end end)
