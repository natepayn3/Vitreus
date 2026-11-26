-- Lyrics, on the cassette's side B (pages/media_float.plm). Pressing the label flips the tape; side B's label carries the words, the line being
-- sung in the middle, the one before above and the next below, rolling up as the song goes.
--
-- The words come from LRCLIB (bin/vitreus-lyrics, kept in ~/.cache/pleamar/vitreus/lyrics). Nothing is looked up until it has been allowed
-- once on side B itself (lyrics.json, `on`), and then only while side B is showing: flipping back to A sends nothing more.
--
-- The scene's `lyr_mode`: 0 nothing yet · 1 looking · 2 timed · 3 words with no times (they scroll with how far the song has gone) · 4 none found ·
-- 5 instrumental · 6 a stream with no end · 7 not allowed yet · 8 could not ask.
-- `lyr_l0` … `lyr_l4`: the line two before, the one before, the one being sung, the next and the one after; `lyr_step` rolls them up by one.
--
-- It answers `pos(seconds)`, which the player calls with each reading of where the song is (once a second while the player is open); in between it
-- counts on by itself, five times a second, so a line changes when it is sung and not up to a second late.
return function()
    local S = {
        on = false, playing = false,
        key = "", artist = "", title = "", len = 0,
        want = "",                -- the song a lookup was started for
        mode = 0, lines = nil, plain = nil,
        pos = 0, idx = -99, cache = nil,
    }
    do
        local ok, t = pcall(sys.ask, "files.read", "lyrics.json", "json")
        if ok and type(t) == "table" then S.on = t.on == true end
    end

    local function set_mode(m) S.mode = m; fact.lyr_mode = m end
    --  Whether side B is showing: read from the scene each time, never kept here (a copy kept here fell out of step with the tape, and side B said
    --  "flip back to A" with a song playing).
    local function side_b() return fact.wk_b == true end
    local function show(list, i)
        for k = 0, 4 do
            local l = list[i + k - 2]           -- (i is 1-based: the line being sung is list[i], shown as lyr_l2)
            text["lyr_l" .. k] = l or ""
        end
    end
    local function clear()
        S.lines, S.plain, S.idx = nil, nil, -99
        for k = 0, 4 do text["lyr_l" .. k] = "" end
    end

    --  Where in the words the song is: the last timed line already reached (0 before the first), or, with no times, as far down as the song has gone.
    --  How far through the line being sung (0 to 1), for a long one to slide by: told only when it has moved on a little.
    local function frac(f)
        f = math.max(0, math.min(1, f))
        if math.abs(f - (S.frac or -1)) >= 0.02 or (f == 0 and S.frac ~= 0) then S.frac = f; fact.lyr_frac = f end
    end
    local function place()
        local i
        if S.lines then
            i = 0
            local lo, hi = 1, #S.lines
            while lo <= hi do
                local mid = (lo + hi) // 2
                if S.lines[mid][1] <= S.pos + 0.15 then i = mid; lo = mid + 1 else hi = mid - 1 end
            end
            if i >= 1 then
                local t0 = S.lines[i][1]
                local t1 = S.lines[i + 1] and S.lines[i + 1][1] or (t0 + 4)
                frac((S.pos - t0) / math.max(0.5, t1 - t0))
            else
                frac(0)
            end
            if i == S.idx then return end
            local fwd = i == S.idx + 1
            S.idx = i
            local words = {}
            for n, l in ipairs(S.lines) do words[n] = l[2] end
            if i == 0 then
                show({ "", "", "", words[1] or "", words[2] or "" }, 3)
            else
                show(words, i)
            end
            if fwd then emit("lyr_step") end
        elseif S.plain then
            local n = #S.plain
            local x = (S.len > 0) and (S.pos / S.len * n) or 0
            local i2 = math.max(1, math.min(n, math.floor(x) + 1))
            frac(x - (i2 - 1))
            if i2 == S.idx then return end
            local fwd = i2 == S.idx + 1
            S.idx = i2
            show(S.plain, i2)
            if fwd then emit("lyr_step") end
        end
    end

    local function fetch()
        if not (S.on and side_b()) then return end
        if S.len <= 0 then clear(); set_mode(6) return end
        if S.key == "" or S.title == "" then clear(); set_mode(4) return end
        if S.want == S.key and S.mode >= 1 and S.mode <= 5 then return end     -- (this song's words are here, or on their way)
        S.want = S.key
        clear()
        set_mode(1)
        local function go()
            local asked = S.key
            run("vitreus-lyrics", { "--cache", S.cache, S.artist, S.title, string.format("%.0f", S.len) }, function(out, code)
                if asked ~= S.key then return end                -- another song by now
                local ok, d = pcall(json.decode, out or "")
                if code ~= 0 or not ok or type(d) ~= "table" then set_mode(8) return end
                if d.status == "synced" and type(d.lines) == "table" and #d.lines > 0 then
                    S.lines = d.lines; set_mode(2); S.idx = -99; place()
                elseif d.status == "plain" and type(d.plain) == "table" and #d.plain > 0 then
                    S.plain = d.plain; set_mode(3); S.idx = -99; place()
                elseif d.status == "instrumental" then set_mode(5)
                elseif d.status == "error" then set_mode(8)
                else set_mode(4) end
            end)
        end
        if S.cache then go() return end
        run("printenv", { "HOME" }, function(h)
            h = (h or ""):gsub("%s+$", "")
            if h == "" then set_mode(8) return end
            S.cache = h .. "/.cache/pleamar/vitreus/lyrics"
            go()
        end)
    end

    sys.watch("media", function(m)
        S.playing = m.playing == true
        local len = tonumber(m.length) or 0
        if len > 43200 then len = 0 end
        local key = tostring(m.title or "") .. "|" .. tostring(m.artist or "") .. "|" .. tostring(math.floor(len + 0.5))
        if key ~= S.key then
            S.key, S.title, S.artist, S.len = key, tostring(m.title or ""), tostring(m.artist or ""), len
            S.pos = 0
            clear()
            if not S.on then set_mode(7) elseif side_b() then fetch() else set_mode(0) end
        end
    end)

    on("fact:wk_b", function()
        if not S.on then set_mode(7) return end
        if side_b() then fetch() end
    end)
    on("lyr_ok", function()
        S.on = true
        pcall(sys.call, "files.write", "lyrics.json", { on = true })
        S.want = ""
        fetch()
    end)
    -- From the launcher: forget that it was allowed (side B asks again).
    on("lyr_forget", function()
        S.on = false
        pcall(sys.call, "files.write", "lyrics.json", { on = false })
        clear(); set_mode(7)
    end)

    every(200, function()
        if not side_b() then return end
        if S.playing and (S.lines or S.plain) then
            S.pos = S.pos + 0.2
            if S.len > 0 and S.pos > S.len then S.pos = S.len end     -- (counted on past the end while nobody read it: a loop's reading sets it back)
            place()
        elseif S.on and (S.mode == 0 or S.mode == 7) and S.key ~= "" then
            fetch()                                             -- side B with nothing on it and a song playing: put it right
        end
    end)

    set_mode(S.on and 0 or 7)
    if side_b() then after(300, fetch) end                      -- (the logic loaded again with the tape turned over)
    return function(pos)
        if type(pos) ~= "number" then return end
        -- a reading a little behind what has been counted is the player's rounding: only a real jump (a seek) sets it back
        if math.abs(pos - S.pos) > 0.6 then S.idx = -99 end      -- (a seek, or a drift: the lines are put right without the roll)
        S.pos = pos
        if S.lines or S.plain then place() end
    end
end
