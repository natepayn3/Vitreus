-- Workspaces only: what moves is moved by the renderer.
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do busy[d.id] = d.windows > 0 end
    for i = 1, 5 do fact["ws." .. i .. ".busy"] = busy[i] or false end
    fact["ws.active"] = w.active
end)
on("go", function(i) sys.call("workspaces.focus", i) end)

-- The clock, written the way it is read here: 12 hours with am/pm, and the long date.
local days = { [0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local months = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }

sys.watch("clock", function(c)
    local h = c.hour % 12
    if h == 0 then h = 12 end
    text.clock12 = string.format("%d:%02d %s", h, c.minute, c.hour < 12 and "am" or "pm")
    text.datelong = string.format("%s, %s %d, %d", days[c.weekday], months[c.month], c.day, c.year)
end)

-- The player: whether there is one, and what the three buttons do.
-- cava listens to what is playing and prints one line per frame: six bars, 0..1000.
-- It only runs while something plays, and the bass is the mean of the low two.
local cava = nil
local last = 0
local spec_last = {}

local function listen()
    if cava then return end
    cava = spawn("cava", { "-p", "/home/nick/.config/pleamar/shells/gota/cava.conf" }, function(line)
        local b = {}
        for v in string.gmatch(line, "(%d+);") do b[#b + 1] = tonumber(v) / 1000 end
        if #b < 2 then return end
        local bass = math.min(1, (b[1] + b[2]) / 2)
        -- the equalizer in the media card: only worth sending while that panel is showing
        if fact.panel == "controls" then
            for i = 1, 6 do
                local v = math.min(1, b[i] or 0)
                if math.abs(v - (spec_last[i] or 0)) > 0.02 then
                    spec_last[i] = v
                    fact["spec." .. (i - 1)] = v
                end
            end
        end
        -- only report when it moved enough to be seen: the renderer springs the rest
        if math.abs(bass - last) > 0.03 then
            last = bass
            fact.bass = bass
        end
    end, function() cava = nil end)
end

local function hush()
    if cava then kill(cava); cava = nil end
    last = 0
    fact.bass = 0
    for i = 1, 6 do spec_last[i] = 0; fact["spec." .. (i - 1)] = 0 end
end

-- The cover. Every player publishes it the same way (MPRIS `mpris:artUrl`), and
-- `playerctl` reads it: a local file (browsers write theirs into /tmp, mpv and VLC
-- point at the folder) or a link (Spotify and most streaming apps). A file is used
-- where it is; a link is fetched once into /tmp and cached under a name made from it.
local art_url = ""

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local function unpercent(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function show_art(path)
    text.arturl = path
    fact.art_on = path ~= ""
end

local function use_art(url)
    if url == art_url then return end
    art_url = url
    if url == "" then show_art("") return end
    if url:sub(1, 7) == "file://" then
        show_art(unpercent(url:sub(8)))
    elseif url:match("^https?://") then
        local path = "/tmp/gota-art-" .. hash(url) .. ".img"
        run("curl", { "-fsSL", "--max-time", "8", "-o", path, url }, function(_, code)
            if code == 0 and art_url == url then show_art(path) end
        end)
    else
        show_art("")
    end
end

local function fetch_art(player)
    run("playerctl", { "-p", player, "metadata", "mpris:artUrl" }, function(out, code)
        local url = tostring(out or ""):gsub("%s+$", "")
        if code == 0 and url ~= "" then
            use_art(url)
        else
            -- the name the service gave may not be one playerctl knows: ask without it
            run("playerctl", { "metadata", "mpris:artUrl" }, function(out2, code2)
                use_art(code2 == 0 and (tostring(out2 or ""):gsub("%s+$", "")) or "")
            end)
        end
    end)
end

local song = ""

sys.watch("media", function(m)
    fact.media_on = m.player ~= ""
    if m.playing then listen() else hush() end
    if m.player == "" then
        song = ""
        use_art("")
        return
    end
    local now = m.player .. "|" .. tostring(m.title) .. "|" .. tostring(m.artist)
    if now ~= song then
        local first = song == ""
        song = now
        fetch_art(m.player)
        -- players often publish the cover a moment after the title
        after(900, function() fetch_art(m.player) end)
        if not first then emit("trackchange") end
    end
end)
on("mcmd", function(k)
    sys.call(k == 0 and "media.previous" or (k == 1 and "media.toggle" or "media.next"))
end)

-- The volume slider: the scene turns the pointer into 0..1, the mixer takes it.
on("setvol", function(v)
    sys.call("audio.volume", v)
end)

-- Where the sound can go. PipeWire's names come with the whole card model in
-- them, so they are only tidied (spaces); the scene truncates to fit its row.
-- The ids stay here: the scene only knows positions, and asks for one by number.
local out_ids = {}

sys.watch("audio", function(a)
    local rows, ids, current = {}, {}, ""
    for _, o in ipairs(a.outputs or {}) do
        local name = tostring(o.name):gsub("%s+", " ")
        rows[#rows + 1] = { name = name, current = o.default == true }
        ids[#ids + 1] = o.id
        if o.default == true then current = name end
    end
    out_ids = ids
    model.outlist = rows
    text.outname = current
end)

on("pick_out", function(i)
    local id = out_ids[i + 1]
    if id ~= nil then sys.call("audio.default", id) end
end)

-- The speaker icon: silence it, or bring the sound back.
on("mute", function()
    sys.call("audio.mute")
end)

-- ── the calendar ────────────────────────────────────────────────────
--  Reminders kept in `calendar.json`, a month on screen (six weeks) and the day
--  that is chosen. Writing «3:30pm Call mom» makes a reminder at that time; with
--  no time it is for the whole day. When its time comes, a notification goes out
--  (`notify-send`, to whoever receives them), once: it is marked so that a restart
--  does not say it again. The layout of the month and the way of saving are
--  Marea's calendar's, with weeks that start on Sunday and times in 12 hours.
local SUNDAY_FIRST = true
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local LETTERS = SUNDAY_FIRST and { "S", "M", "T", "W", "T", "F", "S" } or { "M", "T", "W", "T", "F", "S", "S" }

local cal = { events = {}, year = 0, month = 0, sel = nil, rows = {} }

local function days_in(y, m)
    if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then return 29 end
    return ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
end
--  0 for the first day of the week, whichever that is.
local function weekday(y, m, d)
    local w = os.date("*t", os.time({ year = y, month = m, day = d, hour = 12 })).wday   -- 1 is Sunday
    if SUNDAY_FIRST then return w - 1 end
    return (w + 5) % 7
end
local function key(y, m, d) return string.format("%04d-%02d-%02d", y, m, d) end
local function today()
    local t = os.date("*t")
    return t.year, t.month, t.day
end
local function parse_key(k)
    local y, m, d = k:match("^(%d+)-(%d+)-(%d+)$")
    return tonumber(y), tonumber(m), tonumber(d)
end
local function time12(hhmm)
    local h, mi = hhmm:match("^(%d+):(%d+)$")
    h, mi = tonumber(h), tonumber(mi)
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d%s", h12, mi, h < 12 and "am" or "pm")
end
local function on_day(k)
    local list = {}
    for _, e in ipairs(cal.events) do
        if e.date == k then list[#list + 1] = e end
    end
    --  Whole-day ones first, then by time.
    table.sort(list, function(a, b) return (a.time or "") < (b.time or "") end)
    return list
end

local function save_calendar()
    pcall(sys.call, "files.write", "calendar.json", { events = cal.events })
end
do
    local ok, loaded = pcall(sys.ask, "files.read", "calendar.json", "json")
    if ok and type(loaded) == "table" and type(loaded.events) == "table" then cal.events = loaded.events end
end

local function paint_calendar()
    local y, m = cal.year, cal.month
    text["cal.month"] = string.format("%s %d", MONTHS[m], y)
    for w = 1, 7 do text["cal.wd." .. w] = LETTERS[w] end
    --  The grid starts on the first day of the week the 1st falls in.
    local py, pm = y, m - 1
    if pm < 1 then py, pm = y - 1, 12 end
    local lead = weekday(y, m, 1)
    local ty, tm, td = today()
    local d, gy, gm = days_in(py, pm) - lead + 1, py, pm
    if lead == 0 then d, gy, gm = 1, y, m end
    local counts = {}
    for _, e in ipairs(cal.events) do counts[e.date] = (counts[e.date] or 0) + 1 end
    for k = 0, 41 do
        local kk = key(gy, gm, d)
        fact["cal.day." .. k] = d
        fact["cal.in." .. k] = gm == m
        fact["cal.today." .. k] = gy == ty and gm == tm and d == td
        fact["cal.n." .. k] = counts[kk] or 0
        if kk == cal.sel then fact["cal.sel"] = k end
        d = d + 1
        if d > days_in(gy, gm) then
            d, gm = 1, gm + 1
            if gm > 12 then gm, gy = 1, gy + 1 end
        end
    end
    local sy, sm, sd = parse_key(cal.sel)
    local wday = os.date("*t", os.time({ year = sy, month = sm, day = sd, hour = 12 })).wday   -- 1 is Sunday
    text["cal.sel_title"] = string.format("%s, %s %d", DAYS[wday], MONTHS[sm], sd)
    local list = on_day(cal.sel)
    text["cal.sel_sub"] = #list == 0 and "Free day" or (#list == 1 and "1 reminder" or string.format("%d reminders", #list))
    local rows = {}
    cal.rows = {}
    for i, e in ipairs(list) do
        if i <= 4 then
            rows[#rows + 1] = { time = e.time ~= "" and time12(e.time) or "all day", title = e.title, done = e.done == true }
            cal.rows[#cal.rows + 1] = e
        end
    end
    model.cal_events = rows
end

local function show_month(y, m, sel)
    cal.year, cal.month = y, m
    cal.sel = sel or key(y, m, 1)
    paint_calendar()
end

local function open_today()
    local y, m, d = today()
    show_month(y, m, key(y, m, d))
end
on("cal_open", open_today)
on("cal_today", open_today)
on("cal_prev", function()
    local y, m = cal.year, cal.month - 1
    if m < 1 then y, m = y - 1, 12 end
    show_month(y, m)
end)
on("cal_next", function()
    local y, m = cal.year, cal.month + 1
    if m > 12 then y, m = y + 1, 1 end
    show_month(y, m)
end)
--  A day of the grid: chosen; if it belongs to the month before or after, that month comes in.
on("cal_pick", function(k)
    k = math.floor(k or 0)
    local lead = weekday(cal.year, cal.month, 1)
    local n = k - lead + 1
    local y, m = cal.year, cal.month
    if n < 1 then
        m = m - 1
        if m < 1 then y, m = y - 1, 12 end
        n = days_in(y, m) + n
    elseif n > days_in(y, m) then
        n = n - days_in(y, m)
        m = m + 1
        if m > 12 then y, m = y + 1, 1 end
    end
    show_month(y, m, key(y, m, n))
end)

--  «3:30pm Call mom», «3pm call», «15:30 dentist», «18h gym», «18.30 dinner»;
--  anything else is for the whole day. Returns the time as "HH:MM", and the words.
local function parse_line(line)
    local h, mi, ap, rest = line:match("^(%d%d?):(%d%d)%s*([aApP][mM])%s+(.+)$")
    if not h then
        h, ap, rest = line:match("^(%d%d?)%s*([aApP][mM])%s+(.+)$")
        mi = "00"
    end
    if h then
        h, mi = tonumber(h), tonumber(mi)
        if h >= 1 and h <= 12 and mi < 60 then
            local pm = ap:lower() == "pm"
            if h == 12 then h = pm and 12 or 0 else h = pm and h + 12 or h end
            return string.format("%02d:%02d", h, mi), rest
        end
    end
    h, mi, rest = line:match("^(%d%d?)[:%.h](%d%d)%s+(.+)$")
    if not h then
        h, rest = line:match("^(%d%d?)h%s+(.+)$")
        mi = "00"
    end
    if h and tonumber(h) < 24 and tonumber(mi) < 60 then
        return string.format("%02d:%02d", tonumber(h), tonumber(mi)), rest
    end
    return "", line
end

local function add_line(value)
    local line = (value or ""):match("^%s*(.-)%s*$")
    if line == "" then return end
    local time, title = parse_line(line)
    table.insert(cal.events, { date = cal.sel, time = time, title = title })
    save_calendar()
    text.cal_new = ""
    paint_calendar()
end
on("submit:cal_new", add_line)
on("cal_add", function() add_line(text.cal_new) end)

on("cal_check", function(i)
    local e = cal.rows[(i or 0) + 1]
    if e == nil then return end
    e.done = not (e.done == true)
    save_calendar()
    paint_calendar()
end)
on("cal_delete", function(i)
    local e = cal.rows[(i or 0) + 1]
    if e == nil then return end
    for k, x in ipairs(cal.events) do
        if x == e then table.remove(cal.events, k); break end
    end
    save_calendar()
    paint_calendar()
end)

--  Every twenty seconds: tell what is due, and once. A reminder is due for five
--  minutes after its time, so a slept laptop does not read out the whole morning.
--  Also, if the day has turned over, the grid moves its «today» ring.
local painted_day = ""
every(20000, function()
    local y, m, d = today()
    local t = os.date("*t")
    local now = t.hour * 60 + t.min
    local k = key(y, m, d)
    local changed = false
    for _, e in ipairs(cal.events) do
        if e.date == k and e.time ~= "" and not e.told and not e.done then
            local eh, em = e.time:match("^(%d+):(%d+)$")
            local at = tonumber(eh) * 60 + tonumber(em)
            if now >= at and now < at + 5 then
                run("notify-send", { "-a", "Reminder", e.title, time12(e.time) }, function() end)
                e.told = true
                changed = true
            end
        end
    end
    if changed then save_calendar(); paint_calendar() end
    if painted_day ~= k then
        painted_day = k
        if cal.year == 0 or (cal.sel == nil) then open_today() else paint_calendar() end
    end
end)
open_today()
painted_day = key(today())
