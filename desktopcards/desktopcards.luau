-- The calendar and reminders' logic. The scene draws; this works out the month, keeps the list and the places, and learns where the monitors lie.
--
-- `desktopcards.json`, in this scene's own folder (~/.local/share/pleamar/desktopcards): what is missing from it is the default below, and a file that is not there is written.
--   cal, rem      { shown, gx, gy, monitor }   whether the card is on the desktop, the cell of its top left corner on the 16 x 9 grid (-1: its default one), and the monitor's name
-- `desktopcards-todos.json`: the reminders, [{ t = text, done = 0 or 1 }].
local CARDS = { "cal", "rem" }
local cfg = {
    cal = { shown = false, gx = -1, gy = -1, monitor = "" },
    rem = { shown = false, gx = -1, gy = -1, monitor = "" },
}
cfg.grid = 2
local todos = {}

do
    local ok, saved = pcall(sys.ask, "files.read", "desktopcards.json", "json")
    if ok and type(saved) == "table" then
        for _, c in ipairs(CARDS) do
            local s = saved[c]
            if type(s) == "table" then
                for k, v in pairs(cfg[c]) do
                    if type(s[k]) == type(v) then cfg[c][k] = s[k] end
                end
                -- The grid is 28 x 16 now (it was 16 x 9): a position saved on the old one is carried over to the same place (`grid` says which it was saved on).
                if saved.grid ~= 2 then
                    if cfg[c].gx >= 0 then cfg[c].gx = math.floor(cfg[c].gx * 28 / 16 + 0.5) end
                    if cfg[c].gy >= 0 then cfg[c].gy = math.floor(cfg[c].gy * 16 / 9 + 0.5) end
                end
            end
        end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopcards.json", cfg)
    end
    local ok2, list = pcall(sys.ask, "files.read", "desktopcards-todos.json", "json")
    if ok2 and type(list) == "table" then
        for _, r in ipairs(list) do
            if type(r) == "table" and type(r.t) == "string" then todos[#todos + 1] = { t = r.t, done = (r.done == 1 or r.done == true) and 1 or 0 } end
        end
    end
end
local function save() pcall(sys.call, "files.write", "desktopcards.json", cfg) end
save()   -- (also writes the migration)
local function save_todos() pcall(sys.call, "files.write", "desktopcards-todos.json", todos) end

for _, c in ipairs(CARDS) do
    fact[c .. "_shown"] = cfg[c].shown
    fact[c .. "_gx"] = cfg[c].gx
    fact[c .. "_gy"] = cfg[c].gy
end

-- ---- where the monitors lie (the same as desktopclock.luau: the scene's copies are not in `hyprctl`'s order, so the copies' sizes are read from `describe` and matched) ----
local names = {}
local function refresh_monitors()
    run("hyprctl", { "monitors", "-j" }, function(out, code)
        if code ~= 0 or not out then return end
        local ok, list = pcall(json.decode, out)
        if not ok or type(list) ~= "table" then
            ok, list = true, {}
            for name, id, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID (%d+)%):\n(.-)\n\n") do
                local w, h, x, y = body:match("(%d+)x(%d+)@[%d%.]+ at (%-?%d+)x(%-?%d+)")
                if w then
                    list[#list + 1] = { id = tonumber(id), name = name, width = tonumber(w), height = tonumber(h), x = tonumber(x), y = tonumber(y),
                        scale = tonumber(body:match("scale:%s*([%d.]+)")) or 1, transform = 0 }
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
        run("pleamar", { "--say", "desktopcards", "describe" }, function(desc, code2)
            local order = {}
            if code2 == 0 and desc then
                local used = {}
                for n, w, h in desc:gmatch("%(screen (%d+)%) [^\n]-panel (%d+)\xC3\x97(%d+)") do
                    n, w, h = tonumber(n), tonumber(w), tonumber(h)
                    for i, m in ipairs(mons) do
                        if not used[i] and m.w == w and m.h == h and n < 4 and not order[n + 1] then used[i] = true; order[n + 1] = m; break end
                    end
                end
                for k = 1, #mons do if not order[k] then order = {}; break end end
            end
            if #order ~= #mons then order = mons end
            names = {}
            for k = 1, 4 do
                local d = order[k]
                fact["m" .. (k - 1) .. "x"] = d and d.x or 0
                fact["m" .. (k - 1) .. "y"] = d and d.y or 0
                fact["m" .. (k - 1) .. "w"] = d and d.w or 0
                fact["m" .. (k - 1) .. "h"] = d and d.h or 0
                names[k] = d and d.name or nil
            end
            -- each card is on the monitor it was on, or (when that one is gone, or none was chosen yet) the first
            for _, c in ipairs(CARDS) do
                local mine = 0
                for k = 1, 4 do if names[k] and names[k] == cfg[c].monitor then mine = k - 1 end end
                fact[c .. "_mon"] = mine
                if cfg[c].monitor == "" then cfg[c].monitor = names[1] or ""; save() end
                text[c .. "_mon_name"] = names[mine + 1] or ""
            end
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
every(5000, function()
    if mon_due() and not (fact.cal_dragging or fact.rem_dragging) then refresh_monitors() end
end)

for _, c in ipairs(CARDS) do
    on("fact:" .. c .. "_shown", function(v) cfg[c].shown = v and true or false; save() end)
    on("fact:" .. c .. "_gx", function(v) if type(v) == "number" then cfg[c].gx = v; save() end end)
    on("fact:" .. c .. "_gy", function(v) if type(v) == "number" then cfg[c].gy = v; save() end end)
    -- by the monitor's name (Settings > Theme > Pin widgets): only a monitor that is plugged in; another name leaves the card where it is
    on("text:" .. c .. "_mon_name", function(t)
        for k = 1, 4 do
            if names[k] and names[k] == t then
                fact[c .. "_mon"] = k - 1
                if cfg[c].monitor ~= t then cfg[c].monitor = t; save() end
                return
            end
        end
        text[c .. "_mon_name"] = cfg[c].monitor      -- (not plugged in: it stays where it is, and says so)
    end)
    on("fact:" .. c .. "_mon", function(v)
        local n = type(v) == "number" and names[math.max(0, math.min(3, math.floor(v + 0.5))) + 1]
        if n and n ~= cfg[c].monitor then cfg[c].monitor = n; save() end
        if n then text[c .. "_mon_name"] = n end
    end)
end

-- ---- the calendar ----
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
local today = { y = 0, m = 0, d = 0 }
local moff = 0                                   -- months away from this one
local function is_leap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end
local function dim(y, m)
    if m == 2 then return is_leap(y) and 29 or 28 end
    return (m == 4 or m == 6 or m == 9 or m == 11) and 30 or 31
end
-- the weekday of a date, 0 Monday .. 6 Sunday (Sakamoto)
local function dow(y, m, d)
    local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
    if m < 3 then y = y - 1 end
    local w = (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7   -- 0 Sunday
    return (w + 6) % 7
end
local function yday(y, m, d)
    local n = d
    for i = 1, m - 1 do n = n + dim(y, i) end
    return n
end
local function build()
    if today.y == 0 then return end
    local idx = (today.y * 12 + (today.m - 1)) + moff
    local y, m = idx // 12, idx % 12 + 1
    local lead = dow(y, m, 1)                    -- days of the month before that fill the first row
    local pm, py = m - 1, y
    if pm < 1 then pm, py = 12, y - 1 end
    local days = {}
    for i = 0, 41 do
        local n = i - lead + 1
        local d, k
        if n < 1 then d, k = dim(py, pm) + n, 0
        elseif n > dim(y, m) then d, k = n - dim(y, m), 0
        else
            d = n
            k = (y == today.y and m == today.m and n == today.d) and 2 or ((i % 7) >= 5 and 3 or 1)
        end
        days[#days + 1] = { d = d, k = k }
    end
    model.cal_days = days
    text.cal_title = MONTHS[m] .. " " .. y
    if moff == 0 then
        -- the week number of today (ISO)
        local wd = dow(today.y, today.m, today.d)
        local wk = (yday(today.y, today.m, today.d) - (wd + 1) + 10) // 7
        text.cal_week = "Week " .. math.max(1, math.min(53, wk))
    else
        text.cal_week = moff > 0 and (moff .. (moff == 1 and " month ahead" or " months ahead")) or (-moff .. (moff == -1 and " month ago" or " months ago"))
    end
end
sys.watch("clock", function(c)
    local changed = c.year ~= today.y or c.month ~= today.m or c.day ~= today.d
    today = { y = c.year, m = c.month, d = c.day }
    if changed then build() end
end)
on("cal_nav", function(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    if n == 0 then moff = 0 else moff = moff + n end
    build()
end)

-- ---- the reminders ----
local function show_todos()
    local rows, left = {}, 0
    for _, r in ipairs(todos) do
        rows[#rows + 1] = { t = r.t, done = r.done }
        if r.done == 0 then left = left + 1 end
    end
    model.todos = rows
    text.rem_sub = (#todos == 0) and "nothing to do" or (left .. " left")
end
show_todos()
on("rem_toggle", function(i)
    local r = todos[math.floor((tonumber(i) or 0) + 0.5) + 1]
    if not r then return end
    r.done = 1 - r.done
    save_todos(); show_todos()
end)
on("rem_add", function()
    local t = (text.rem_new or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then return end
    if #todos >= 12 then return end
    todos[#todos + 1] = { t = t, done = 0 }
    text.rem_new = ""
    save_todos(); show_todos()
end)
on("rem_clear", function()
    local keep = {}
    for _, r in ipairs(todos) do if r.done == 0 then keep[#keep + 1] = r end end
    todos = keep
    save_todos(); show_todos()
end)

-- ---- how Vitreus looks (glass or flat obsidian), asked of it ----
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
ask_obs()
after(4000, ask_obs)
-- And which theme it has (0 Glass, 1 Retro, 2 UwU, 3 Cyber): the last three are not glass, so the cards are plastic plates there. Vitreus tells it when the theme changes.
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
ask_look()
after(900, ask_look)
after(4000, ask_look)
run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end)
after(1500, function() run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end) end)

-- Where each card is, told to the shell (`text hole_cal` / `hole_rem`: "monitor|x,y,w,h", empty while the card is off the desktop) so that the window manager's
-- desktop-click zone leaves a hole there: a zone over a bottom-layer widget takes its clicks. Told once it has stopped moving.
do
    local sent = {}
    local waiting = {}
    local function tell(c)
        local line = ""
        local name = text[c .. "_mon_name"]
        local w, h = tonumber(fact[c .. "_hw"]) or 0, tonumber(fact[c .. "_hh"]) or 0
        if fact[c .. "_shown"] and name and name ~= "" and w > 1 and h > 1 then
            line = string.format("%s|%d,%d,%d,%d", name, math.floor(fact[c .. "_hx"] + 0.5), math.floor(fact[c .. "_hy"] + 0.5), math.floor(w + 0.5), math.floor(h + 0.5))
        end
        if sent[c] == line then return end
        sent[c] = line
        run("pleamar", { "--say", "vitreus", "text hole_" .. c .. " " .. line }, function() end)
    end
    local function soon(c)
        if waiting[c] then return end
        waiting[c] = true
        after(300, function() waiting[c] = false; tell(c) end)
    end
    for _, c in ipairs(CARDS) do
        for _, v in ipairs({ "hx", "hy", "hw", "hh", "shown" }) do on("fact:" .. c .. "_" .. v, function() soon(c) end) end
        on("text:" .. c .. "_mon_name", function() soon(c) end)
        after(2500, function() tell(c) end)
    end
end

-- Until the monitors are known the card is on none of them (`mon` starts at -1): it used to show on the first copy of the scene for a few seconds and then jump to its own
-- monitor. If they are never learnt (no `hyprctl`), it takes the first one after ten seconds.
after(10000, function()
    for _, k in ipairs({ "cal_mon", "rem_mon" }) do if (tonumber(fact[k]) or 0) < 0 then fact[k] = 0 end end
end)
