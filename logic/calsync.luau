-- Calendars from the web, beside the reminders (Settings > Network, the CALENDARS card under the weather).
--
-- A calendar shared as an iCal link (Google: the calendar's settings, "Secret address in iCal format"; Nextcloud, Outlook, Fastmail, Proton,
-- any .ics or webcal:// link) is pasted in, at most four of them. bin/vitreus-calsync fetches them, spreads the repeating events over the year
-- ahead, and answers JSON; this keeps the answer in `calendar-sync.json` (so the calendar has them at once on the next start, and a calendar
-- that cannot be reached keeps what it last had) and fetches again every 15 minutes, and at once when a link is added or removed.
--
-- They are read-only: they come in the month's dots and the day's list like the reminders, with the calendar's name before the title, and
-- cannot be deleted from here (the cross is not drawn on them). Ticking one off is kept here, per occurrence. Five minutes before a timed
-- one starts a notification says so, once, the way the reminders do (Do Not Disturb holds it back, and it still counts as told).
--
--   repaint()   paint the calendar again (the block in vitreus.luau)
--   quiet()     Do Not Disturb is on
--   time12(s)   "15:30" -> "3:30pm"
return function(repaint, quiet, time12)
    local MAX_FEEDS = 4
    local EVERY = 15 * 60 * 1000
    local S = { feeds = {}, events = {}, state = {}, at = 0, busy = false, again = false, byday = {}, cache = nil }

    local function index()
        S.byday = {}
        for _, e in ipairs(S.events) do
            local l = S.byday[e.date]
            if not l then l = {}; S.byday[e.date] = l end
            l[#l + 1] = e
        end
    end
    local function save()
        pcall(sys.call, "files.write", "calendar-sync.json", { feeds = S.feeds, events = S.events, state = S.state, at = S.at })
    end
    do
        local ok, t = pcall(sys.ask, "files.read", "calendar-sync.json", "json")
        if ok and type(t) == "table" then
            if type(t.feeds) == "table" then
                for _, f in ipairs(t.feeds) do
                    if type(f) == "table" and type(f.url) == "string" then S.feeds[#S.feeds + 1] = f end
                end
            end
            if type(t.events) == "table" then S.events = t.events end
            if type(t.state) == "table" then S.state = t.state end
            S.at = tonumber(t.at) or 0
        end
    end
    index()

    local function feed_name(i)
        local f = S.feeds[(tonumber(i) or 0) + 1]
        return f and f.name and f.name ~= "" and f.name or "Calendar"
    end

    local function paint_feeds()
        local rows = {}
        for _, f in ipairs(S.feeds) do
            local sub
            if f.error and f.error ~= "" then
                sub = f.ok == false and (f.count or 0) > 0 and (f.error .. " · showing the last copy") or f.error
            elseif f.count == nil then
                sub = "Not fetched yet"
            else
                sub = f.count == 1 and "1 event" or string.format("%d events", f.count)
            end
            rows[#rows + 1] = { name = (f.name and f.name ~= "") and f.name or f.url, sub = sub, bad = (f.error or "") ~= "" }
        end
        model.cal_feeds = rows
        if S.busy then
            text.cs_status = "Syncing…"
        elseif #S.feeds == 0 then
            text.cs_status = ""
        elseif S.at > 0 then
            local t = os.date("*t", S.at)
            local now = os.date("*t")
            local when = time12(string.format("%02d:%02d", t.hour, t.min))
            if t.year ~= now.year or t.yday ~= now.yday then when = os.date("%b %d", S.at) .. ", " .. when end
            text.cs_status = "Synced " .. when
        else
            text.cs_status = ""
        end
    end

    local function sync()
        if S.busy then S.again = true return end
        if #S.feeds == 0 then
            S.events = {}
            index(); save(); paint_feeds(); repaint()
            return
        end
        local function go(cache)
            local args = { "--cache", cache }
            for _, f in ipairs(S.feeds) do args[#args + 1] = f.url end
            S.busy = true
            paint_feeds()
            run("vitreus-calsync", args, function(out, code)
                S.busy = false
                local ok, d = pcall(json.decode, out or "")
                if code == 0 and ok and type(d) == "table" and type(d.events) == "table" and type(d.feeds) == "table" then
                    -- (the links may have changed while it ran: the answer only counts for the same list)
                    local same = #d.feeds == #S.feeds
                    for i, f in ipairs(d.feeds) do if not S.feeds[i] or S.feeds[i].url ~= f.url then same = false end end
                    if same then
                        for i, f in ipairs(d.feeds) do
                            S.feeds[i].name = f.name
                            S.feeds[i].count = f.count
                            S.feeds[i].ok = f.ok
                            S.feeds[i].error = f.error
                        end
                        S.events = d.events
                        -- What was ticked off or told is only kept for what is still there.
                        local keep = {}
                        for _, e in ipairs(S.events) do if S.state[e.key] then keep[e.key] = S.state[e.key] end end
                        S.state = keep
                        S.at = os.time()
                        index(); save(); repaint()
                    end
                else
                    for _, f in ipairs(S.feeds) do if (f.error or "") == "" then f.error = "could not sync" end end
                end
                paint_feeds()
                if S.again then S.again = false; sync() end
            end)
        end
        if S.cache then go(S.cache) return end
        run("printenv", { "HOME" }, function(h)
            h = (h or ""):gsub("%s+$", "")
            if h == "" then return end
            S.cache = h .. "/.cache/pleamar/vitreus/calsync"
            go(S.cache)
        end)
    end

    local function add()
        local url = (text.cs_in or ""):match("^%s*(.-)%s*$")
        if url == "" then return end
        local low = url:lower()
        if not (low:match("^https?://") or low:match("^webcal://")) then
            text.cs_status = "That is not a link"
            return
        end
        for _, f in ipairs(S.feeds) do if f.url == url then text.cs_in = ""; return end end
        if #S.feeds >= MAX_FEEDS then text.cs_status = "Four calendars at most" return end
        S.feeds[#S.feeds + 1] = { url = url, name = "" }
        text.cs_in = ""
        save(); paint_feeds()
        sync()
    end
    on("cs_add", add)
    on("submit:cs_in", add)
    on("cs_remove", function(i)
        i = (tonumber(i) or -1) + 1
        if not S.feeds[i] then return end
        table.remove(S.feeds, i)
        -- the events of the ones after it name their calendar by place: they move up with it
        local kept = {}
        for _, e in ipairs(S.events) do
            local f = (tonumber(e.feed) or 0) + 1
            if f ~= i then
                if f > i then e.feed = f - 2 end
                kept[#kept + 1] = e
            end
        end
        S.events = kept
        index(); save(); paint_feeds(); repaint()
        sync()
    end)

    -- A fresh copy a few seconds after the start (the network may still be coming up), then every 15 minutes.
    paint_feeds()
    after(6000, function() if #S.feeds > 0 then sync() end end)
    every(EVERY, function() if #S.feeds > 0 then sync() end end)

    -- Five minutes before a timed event: a notification, once.
    every(20000, function()
        local t = os.date("*t")
        local k = string.format("%04d-%02d-%02d", t.year, t.month, t.day)
        local now = t.hour * 60 + t.min
        local changed = false
        for _, e in ipairs(S.byday[k] or {}) do
            local st = S.state[e.key]
            if e.time ~= "" and not (st and (st.told or st.done)) then
                local h, m = e.time:match("^(%d+):(%d+)$")
                local at = tonumber(h) * 60 + tonumber(m)
                if now >= at - 5 and now < at + 5 then
                    if not quiet() then
                        local body = (now < at and "Starts at " or "Started at ") .. time12(e.time)
                        if (e.where or "") ~= "" then body = body .. " · " .. e.where end
                        run("notify-send", { "-a", feed_name(e.feed), "--", e.title, body }, function() end)
                    end
                    S.state[e.key] = st or {}
                    S.state[e.key].told = true
                    changed = true
                end
            end
        end
        if changed then save() end
    end)

    local api = {}
    --  The events of a day ("YYYY-MM-DD"), as the calendar's list wants them.
    function api.day(k)
        local out = {}
        for _, e in ipairs(S.byday[k] or {}) do
            local st = S.state[e.key]
            out[#out + 1] = { date = e.date, time = e.time, title = feed_name(e.feed) .. " · " .. e.title, done = st and st.done == true or false,
                              synced = true, key = e.key }
        end
        return out
    end
    --  How many each day has, added to the reminders' counts.
    function api.count(counts)
        for d, l in pairs(S.byday) do counts[d] = (counts[d] or 0) + #l end
    end
    function api.toggle(key)
        local st = S.state[key] or {}
        st.done = not (st.done == true)
        S.state[key] = st
        save()
    end
    return api
end
