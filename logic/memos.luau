-- The Desk's Memos (pages/desk_memos.plm): voice memos, recorded from the default microphone with ffmpeg (Opus, in the data folder's memos/;
-- stopped by telling ffmpeg to quit, `q`, so the file is closed properly), listed newest first with their lengths (ffprobe, once each, kept in
-- desk-memos.json), played on the Desk itself (ffmpeg to the sound server; a second press stops it), and moved to the Trash with their cross (gio trash).
return function(with_dirs)
    local MAX = 30
    local dir = nil
    local list = {}                                        -- { path, t (when), secs }
    local lens = {}                                        -- path -> seconds, as ffprobe said
    do
        local ok, s = pcall(sys.ask, "files.read", "desk-memos.json", "json")
        if ok and type(s) == "table" and type(s.lens) == "table" then for k, v in pairs(s.lens) do lens[k] = tonumber(v) end end
    end
    local function clock(n) n = math.floor((n or 0) + 0.5); return string.format("%d:%02d", n // 60, n % 60) end
    -- the time of day as the system writes it: 12-hour with AM/PM when the locale has them (`date +%p` says something), 24-hour when not
    local h24 = false
    local render
    run("date", { "+%p" }, function(out) h24 = tostring(out or ""):match("%S") == nil; if render then render() end end)
    local function at(t)
        if h24 then return os.date("%H:%M", t) end
        local h = tonumber(os.date("%I", t))
        return h .. os.date(":%M %p", t)
    end
    local playing, play_k, play_t0, play_len = nil, -1, 0, 0
    render = function()
        local rows = {}
        for i, m in ipairs(list) do
            local today = os.date("%Y%m%d", m.t) == os.date("%Y%m%d", os.time())
            rows[i] = {
                name = today and ("Today, " .. at(m.t)) or (os.date("%a %b ", m.t) .. tonumber(os.date("%d", m.t)) .. ", " .. at(m.t)),
                len = m.secs and clock(m.secs) or "",
                playing = play_k == i - 1,
            }
        end
        model.memos = rows
        fact.memo_n = #list
        fact.memo_pk = play_k
    end
    local function probe(m)
        if lens[m.path] then m.secs = lens[m.path]; return end
        run("ffprobe", { "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", m.path }, function(out, c)
            local v = c == 0 and tonumber((out or ""):match("[%d.]+")) or nil
            if v then
                m.secs, lens[m.path] = v, v
                pcall(sys.call, "files.write", "desk-memos.json", { lens = lens })
                render()
            end
        end)
    end
    local function load()
        if not dir then return end
        run("find", { dir, "-maxdepth", "1", "-type", "f", "-name", "*.ogg", "-printf", "%T@ %p\n" }, function(out)
            local got = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local t, p = line:match("^([%d.]+) (.+)$")
                if t then got[#got + 1] = { t = math.floor(tonumber(t)), path = p } end
            end
            table.sort(got, function(a, b) return a.t > b.t end)
            while #got > MAX do table.remove(got) end
            list = got
            for _, m in ipairs(list) do probe(m) end
            render()
        end)
    end
    with_dirs(function(d)
        dir = d.data .. "/memos"
        run("mkdir", { "-p", dir }, function() load() end)
    end)
    on("desk_shown", function() if tonumber(fact.desk_tab) == 9 then load() end end)

    -- ── recording ──
    local rec, rec_t0, rec_file = nil, 0, ""
    on("memo_toggle", function()
        if rec then write(rec, "q"); return end
        if not dir then return end
        rec_file = dir .. "/memo-" .. os.date("%Y%m%d-%H%M%S") .. ".ogg"
        rec_t0 = os.time()
        local mine
        mine = spawn("ffmpeg", { "-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", "default", "-ac", "1", "-c:a", "libopus", "-b:a", "48k", rec_file },
            function() end,
            function()
                if rec ~= mine then return end
                rec = nil
                fact.memo_rec = false
                local secs = os.time() - rec_t0
                run("test", { "-s", rec_file }, function(_, c)
                    if c == 0 and secs >= 1 then lens[rec_file] = secs end
                    load()
                end)
            end,
            { stdin = "open" })
        rec = mine
        fact.memo_rec = true
        text.memo_t = "0:00"
    end)
    every(1000, function() if rec then text.memo_t = clock(os.time() - rec_t0) end end)

    -- ── playing ──
    local function stop_play()
        if playing then kill(playing, "term") end
        playing, play_k = nil, -1
        fact.memo_pp = 0
        render()
    end
    on("memo_play", function(i)
        i = tonumber(i) or -1
        local m = list[i + 1]
        if not m then return end
        local again = play_k == i
        stop_play()
        if again then return end
        local mine
        -- played with ffmpeg to the sound server (it reads what it wrote, even a file not closed cleanly, which pw-play turns down). At the
        -- file's own pace (`-re`), with a short buffer, and half a second of silence after it: ffmpeg's pulse output does not wait for what it
        -- has buffered to be heard before it ends, so without these the last second or two was cut off.
        mine = spawn("ffmpeg", { "-hide_banner", "-loglevel", "error", "-nostdin", "-re", "-i", m.path, "-af", "apad=pad_dur=0.6",
                                 "-f", "pulse", "-buffer_duration", "200", "-name", "Desk memo", "Desk memo" }, function() end, function()
            if playing ~= mine then return end
            playing, play_k = nil, -1
            fact.memo_pp = 0
            render()
        end)
        playing, play_k, play_t0, play_len = mine, i, os.time(), m.secs or 0
        render()
    end)
    every(250, function()
        if playing and play_len > 0 then fact.memo_pp = math.min(1, (os.time() - play_t0) / play_len) end
    end)
    on("memo_del", function(i)
        i = tonumber(i) or -1
        local m = list[i + 1]
        if not m then return end
        if play_k == i then stop_play() end
        run("gio", { "trash", m.path }, function() lens[m.path] = nil; pcall(sys.call, "files.write", "desk-memos.json", { lens = lens }); load() end)
    end)
    -- playing stops when the Desk goes or leaves Memos
    on("desk_gone", stop_play)
    on("desk_shown", function() if tonumber(fact.desk_tab) ~= 9 and playing then stop_play() end end)
end
