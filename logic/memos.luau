-- The Desk's Memos (pages/desk_memos.plm): voice memos, recorded from the default microphone with ffmpeg (Opus, in the data folder's memos/;
-- stopped by telling ffmpeg to quit, `q`, so the file is closed properly), listed newest first with their lengths (ffprobe, once each, kept in
-- desk-memos.json), played on the Desk itself (ffmpeg to the sound server; a second press stops it), and moved to the Trash with their cross (gio trash).
return function(with_dirs)
    local MAX = 30
    local dir = nil
    local list = {}                                        -- { path, t (when), secs }
    local lens = {}                                        -- path -> seconds, as ffprobe said
    local peaks = {}                                       -- path -> the memo's shape, 44 numbers 0..1 (its level by the second, folded)
    do
        local ok, s = pcall(sys.ask, "files.read", "desk-memos.json", "json")
        if ok and type(s) == "table" then
            if type(s.lens) == "table" then for k, v in pairs(s.lens) do lens[k] = tonumber(v) end end
            if type(s.peaks2) == "table" then
                for k, v in pairs(s.peaks2) do
                    if type(v) == "table" and #v == 44 then peaks[k] = v end
                end
            end
        end
    end
    local function save_cache() pcall(sys.call, "files.write", "desk-memos.json", { lens = lens, peaks2 = peaks }) end
    -- ── the wave across the top of Memos (44 bars: facts wv.0 .. wv.43) ──
    local NB = 44
    local function bars(list)
        for i = 0, NB - 1 do fact["wv." .. i] = list and (list[i + 1] or 0) or 0 end
    end
    local LEVEL_FILTER = "aresample=8000,asetnsamples=n=800:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-:direct=1"
    local function level(line)                              -- a line of ametadata's: the level in dB (-90 for silence), or nil
        if line:find("RMS_level=%-inf") then return -90 end
        local v = tonumber(line:match("RMS_level=(%-?[%d%.]+)"))
        if not v then return nil end
        return math.max(-90, v)
    end
    -- A mic's silence is anywhere (-70 dB on a quiet one, -33 on one with the gain up), so a bar is how far a level is above the room's own
    -- quiet: `floor` (the lowest level lately, rising only slowly) to the loudest lately, at least 20 dB higher. Under 3 dB above the
    -- floor is the room, drawn as a dot.
    local function scale(db, floor, top)
        local up = db - floor
        if up < 3 then return 0.04 end
        return math.max(0.06, math.min(1, up / math.max(20, top - floor)))
    end
    -- the shape of a file, at ten levels a second, folded into 44 bars and scaled so the loudest fills the height; `done(list)` when ffmpeg has finished
    local function shape(path, done)
        if peaks[path] then done(peaks[path]); return end
        run("ffmpeg", { "-hide_banner", "-loglevel", "error", "-nostdin", "-i", path, "-af", LEVEL_FILTER, "-f", "null", "-" }, function(out)
            local vals = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local v = level(line)
                if v then vals[#vals + 1] = v end
            end
            if #vals == 0 then done(nil); return end
            local sorted = {}
            for k, v in ipairs(vals) do sorted[k] = v end
            table.sort(sorted)
            local floor, hi = sorted[math.max(1, math.floor(#sorted * 0.1))], sorted[#sorted]
            local list = {}
            for j = 0, NB - 1 do
                local a = math.floor(j * #vals / NB) + 1
                local b = math.max(a, math.floor((j + 1) * #vals / NB))
                local m = -90
                for k = a, math.min(b, #vals) do if vals[k] > m then m = vals[k] end end
                list[j + 1] = math.floor(scale(m, floor, hi) * 100 + 0.5) / 100
            end
            peaks[path] = list
            save_cache()
            done(list)
        end)
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
    local playing, play_k, play_el, play_len = nil, -1, 0, 0
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
                save_cache()
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
        -- the level goes out of the same ffmpeg as the recording (a second, unrecorded branch of it, one line every tenth of a second); two
        -- of them make a bar, so the wave rolls five bars a second
        local ring, pend = {}, nil
        for i = 1, NB do ring[i] = 0.04 end
        local floor, top = nil, nil
        mine = spawn("ffmpeg", { "-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", "default",
                                 "-filter_complex", "[0:a]asplit[r][m];[m]" .. LEVEL_FILTER .. "[lv]",
                                 "-map", "[r]", "-ac", "1", "-c:a", "libopus", "-b:a", "48k", rec_file, "-map", "[lv]", "-f", "null", "-" },
            function(line)
                local v = level(line or "")
                if not v or rec ~= mine then return end
                floor = floor and math.min(v, floor + 0.04) or v          -- (down at once, up 0.4 dB a second)
                top = top and math.max(v, top - 0.1) or v                 -- (up at once, down 1 dB a second)
                if pend then
                    table.remove(ring, 1)
                    ring[NB] = scale(math.max(pend, v), floor, top)
                    pend = nil
                    bars(ring)
                else
                    pend = v
                end
            end,
            function()
                if rec ~= mine then return end
                rec = nil
                fact.memo_rec = false
                fact.wv_mode = 0
                bars(nil)
                local secs = os.time() - rec_t0
                run("test", { "-s", rec_file }, function(_, c)
                    if c == 0 and secs >= 1 then lens[rec_file] = secs end
                    load()
                end)
            end,
            { stdin = "open" })
        rec = mine
        fact.memo_rec = true
        fact.wv_mode = 1
        bars(nil)
        text.memo_t = "0:00"
    end)
    every(1000, function() if rec then text.memo_t = clock(os.time() - rec_t0) end end)

    -- ── playing ──
    -- How far the memo being played has got, four times a second, by a timer that only exists while one plays (it ends itself when none does).
    local play_t
    local function play_watch()
        if play_t then return end
        play_t = every(250, function()
            if not playing then cancel(play_t); play_t = nil; return end
            if play_len > 0 then
                play_el = play_el + 0.25
                fact.memo_pp = math.min(1, play_el / play_len)
            end
        end)
    end
    local function stop_play()
        if playing then kill(playing, "term") end
        playing, play_k = nil, -1
        fact.memo_pp = 0
        if not rec then fact.wv_mode = 0; bars(nil) end
        render()
    end
    local function start_play(i, from)
        local m = list[i + 1]
        if not m then return end
        local mine
        local args = { "-hide_banner", "-loglevel", "error", "-nostdin" }
        if from and from > 0.05 then args[#args + 1] = "-ss"; args[#args + 1] = string.format("%.2f", from) end
        for _, a in ipairs({ "-re", "-i", m.path, "-af", "apad=pad_dur=0.6", "-f", "pulse", "-buffer_duration", "200", "-name", "Desk memo", "Desk memo" }) do args[#args + 1] = a end
        mine = spawn("ffmpeg", args, function() end, function()
            if playing ~= mine then return end
            playing, play_k = nil, -1
            fact.memo_pp = 0
            if not rec then fact.wv_mode = 0; bars(nil) end
            render()
        end)
        playing, play_k, play_el, play_len = mine, i, from or 0, m.secs or 0
        play_watch()
        fact.memo_pp = play_len > 0 and math.min(1, play_el / play_len) or 0
        render()
    end
    on("memo_play", function(i)
        i = tonumber(i) or -1
        local m = list[i + 1]
        if not m or rec then return end
        local again = play_k == i
        stop_play()
        if again then return end
        -- played with ffmpeg to the sound server (see start_play): it reads what it wrote, even a file not closed cleanly, which pw-play turns down.
        start_play(i, 0)
        fact.wv_mode = 2
        bars(nil)
        shape(m.path, function(l) if play_k == i and l then bars(l) end end)
    end)
    -- a press on the wave while a memo plays: on from that place
    on("memo_seek", function(v)
        local m = list[play_k + 1]
        if not (playing and m and play_len > 0) then return end
        local f = math.max(0, math.min(0.98, (tonumber(v) or 0) / 1000))
        local old, i = playing, play_k
        playing = nil                                        -- (its ending is not ours to hear)
        kill(old, "term")
        start_play(i, f * play_len)
    end)
    on("memo_del", function(i)
        i = tonumber(i) or -1
        local m = list[i + 1]
        if not m then return end
        if play_k == i then stop_play() end
        run("gio", { "trash", m.path }, function() lens[m.path] = nil; peaks[m.path] = nil; save_cache(); load() end)
    end)
    -- playing stops when the Desk goes or leaves Memos
    on("desk_gone", stop_play)
    on("desk_shown", function() if tonumber(fact.desk_tab) ~= 9 and playing then stop_play() end end)
end
