-- The Bar page of the settings: which monitors the bar shows on, any of them up to `MAX`, which is what the page's row of tiles
-- shows and what the scene declares (`bar_c0` to `bar_c3`). The scene is one copy per monitor (`screens: each max N`: what each copy
-- holds of its own is named per copy, `name.$screen`, which only a copy per monitor has), and **N follows the monitors that are
-- plugged in**: a desk of three gets three copies, a desk of one pays for one. Growing is at once, because a monitor without a copy
-- shows nothing at all, not even the frame; shrinking waits for the next start, so unplugging does not restart the bar.
-- The copies of the monitors that are not chosen are closed: each copy knows its monitor by name (`screen.K.name`), and this says
-- which of them are chosen (`bar_c0` to `bar_c3`), so choosing takes effect at once. A vitreus.plm from before, whose `screens:` names
-- one monitor, is moved over once: that line is rewritten and the bar started again, from a command left running on its own (`setsid`)
-- that asks this one to quit and then opens the scene afresh. What was chosen is kept in bar.json (a list of names; from before, one
-- name or "all"); a chosen monitor that is not plugged in is left out until it is back, and with none of them plugged in the bar
-- is on every monitor there is, up to `MAX`. With `others: "frame"` in bar.json (Settings > Bar, "Frame on the other monitors")
-- the copies of the other monitors stay open with the frame and its notches (launcher, Settings, desk) and no bar.
return function(with_dirs)
    local MAX = 4                    -- as many as the page shows in its row of tiles and the scene declares (`bar_c0`…`bar_c3`)
    local FPS_FREE = 480             -- `rate:`'s ceiling in the language: the scene is left to the monitor
    local FPS = { FPS_FREE, 120 }    -- what the page offers, in the order of its chips: only one conditional
                                     -- `rate:` clause is honoured, so there is one value to choose besides "Screen"
    local B = { pref = nil, file = nil, mons = {}, busy = false, awake = false, others = false, may_shrink = true }
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
pkill -f "^pleamar --scene .*/vitreus/desktop"  # the desktop widgets restart with the shell (their keepers start them again)
sleep 0.3
[ "$(stat -c %s "$L" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$L" "$L.1"
# under its keeper when there is one (bin/vitreus-keep): a keeper already looking after it starts it again itself
command -v vitreus-keep >/dev/null 2>&1 && exec vitreus-keep "$P" "$L"
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]

    local function connected(name)
        for i, m in ipairs(B.mons) do if m.name == name then return i end end
        return nil
    end
    -- Where the bar should be now: the chosen monitors that are plugged in (MAX at the most), or the first MAX of them when none is.
    local function chosen()
        local out, seen = {}, {}
        for _, n in ipairs(B.pref or {}) do
            if connected(n) and not seen[n] and #out < MAX then out[#out + 1] = n; seen[n] = true end
        end
        if #out == 0 then
            for i = 1, math.min(MAX, #B.mons) do out[#out + 1] = B.mons[i].name end
        end
        return out
    end
    -- How many copies the scene should hold: one for every monitor that is plugged in, so a desk of three or four
    -- is served and a desk of one does not pay for copies it has no monitors for. Growing happens as soon as a
    -- monitor appears, because a monitor without a copy of its own shows nothing at all, not even the frame;
    -- shrinking happens only in the first settle after starting, so unplugging a monitor in the middle of the day
    -- does not restart the bar. (A file from before says one monitor's name, and is moved over.)
    local function want()
        local n = #B.mons
        if n < 1 then n = 1 elseif n > MAX then n = MAX end
        if not B.may_shrink then
            local have = tonumber((B.file or ""):match("^each max (%d+)") or "")
            if have and have > n then n = have end
        end
        return n
    end
    local function file_for()
        return "each max " .. want()
    end
    -- Whether the scene is one copy per monitor at all, rather than a file from before naming a single one.
    local function spread()
        return B.file ~= nil and B.file:match("^each") ~= nil
    end

    -- Open the copies of the chosen monitors and close the others. Each copy says which monitor it is (`screen.K.name`, empty until it knows).
    local function copies()
        if #B.mons == 0 then return end
        local set = {}
        for _, n in ipairs(chosen()) do set[n] = true end
        -- A copy that does not know its monitor yet: the first few are lit, as many as there are monitors, so a copy the
        -- scene does not have (`each max N` with N below MAX) is never lit and the bar is there from the first frame.
        local blind = math.min(#B.mons, MAX)
        for k = 0, MAX - 1 do
            local name = text["screen." .. k .. ".name"]
            local on
            if name == nil or name == "" then on = k < blind else on = set[name] == true end
            if fact["bar_c" .. k] ~= on then fact["bar_c" .. k] = on end
        end
    end

    -- Tell the window gaps where the bar is and what is plugged in.
    local told = nil
    local function publish()
        if not spread() or #B.mons == 0 then return end
        local names = {}
        for _, m in ipairs(B.mons) do names[#names + 1] = m.name end
        local sel = chosen()
        local set = {}
        for _, n in ipairs(sel) do set[n] = true end
        local all = #sel >= #B.mons
        local thin = (not all) and B.others        -- the other monitors have the frame: their windows get its room
        if fact.bar_others ~= B.others then fact.bar_others = B.others end
        bar_mon.set = set
        bar_mon.name = #sel == 1 and sel[1] or "all"
        copies()
        local sig = table.concat(sel, ",") .. "|" .. tostring(thin) .. "|" .. table.concat(names, ",")
        if sig == told then return end
        told = sig
        bar_fx.on, bar_fx.sel, bar_fx.mons, bar_fx.thin = all and "all" or sel[1], set, names, thin
        iris_fx.apply_hypr()
    end

    local function show()
        local sel = chosen()
        local set = {}
        for _, n in ipairs(sel) do set[n] = true end
        for i = 0, 3 do
            local m = B.mons[i + 1]
            fact["bar_m." .. i .. ".on"] = m ~= nil
            fact["bar_sel." .. i] = m ~= nil and set[m.name] == true
            if m then
                text["bar_m." .. i .. ".name"] = m.name
                text["bar_m." .. i .. ".sub"] = m.sub
            end
        end
        fact.bar_rest = #sel < #B.mons
        if B.busy then
            text.bar_msg = "Moving the bar…"
        elseif B.note then
            text.bar_msg = B.note
        else
            local gone = {}
            for _, n in ipairs(B.pref or {}) do if #B.mons > 0 and not connected(n) then gone[#gone + 1] = n end end
            text.bar_msg = #gone > 0 and (table.concat(gone, ", ") .. (#gone > 1 and " aren't" or " isn't") .. " plugged in: the bar waits for " .. (#gone > 1 and "them" or "it") .. ".") or ""
        end
    end

    -- `value` is what the caller has already worked out. Recomputing it here would read `B.may_shrink`
    -- after it has been put down, and a shrink would then write back the very number it is leaving
    -- behind: the file would never change, the comparison in `settle` would never agree, and the bar
    -- would restart for ever.
    local function restart(value)
        if B.busy then return end
        B.busy = true
        show()
        with_dirs(function(d)
            local plm = d.conf .. "/vitreus.plm"
            local value = value or file_for()
            run("sed", { "-i", "-E", "/^    surface \\{/s/screens: [^;]*;/screens: " .. value .. ";/", plm }, function(_, code)
                if code ~= 0 then
                    B.busy = false
                    show()
                    text.bar_msg = "Couldn't change where the bar shows."
                    return
                end
                B.file = file_for()
                run("setsid", { "-f", "sh", "-c", RESTART, "sh", plm, d.data .. "/vitreus.log" }, function() end)
            end)
        end)
    end

    -- Put the bar where it should be, once what the file says and what is plugged in are both known. Not in the
    -- first seconds after starting, so a monitor that is still waking up does not send it back and forth.
    local function settle()
        if B.busy or B.file == nil or #B.mons == 0 then return end
        if not B.awake then return end
        local value = file_for()
        B.may_shrink = false
        if value ~= B.file then restart(value) else publish() end
    end

    local function read_mons()
        hypr_monitors(4, function(out, code)
            if code ~= 0 or not out then return end
            local ok, list = pcall(json.decode, out)
            local mons = {}
            if ok and type(list) == "table" then
                for _, j in ipairs(list) do
                    local t = j.transform or 0
                    local tall = t == 1 or t == 3 or t == 5 or t == 7
                    local sc = (j.scale and j.scale > 0) and j.scale or 1
                    local w, h = math.floor((j.width or 0) / sc + 0.5), math.floor((j.height or 0) / sc + 0.5)
                    if tall then w, h = h, w end
                    mons[#mons + 1] = { name = j.name, x = j.x or 0, y = j.y or 0, tall = tall, w = w, h = h }
                end
            else
                -- pleamar-wm's `hyprctl monitors` is text, even with -j: "Monitor <name> (ID 1):", "2560x1440@164.83 at 1440x733" (its sizes already turned by the rotation).
                for name, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID %d+%):\n(.-)\n\n") do
                    local w, h, x, y = body:match("(%d+)x(%d+)@[%d%.]+ at (%-?%d+)x(%-?%d+)")
                    if w then mons[#mons + 1] = { name = name, x = tonumber(x), y = tonumber(y), tall = tonumber(h) > tonumber(w), w = tonumber(w), h = tonumber(h) } end
                end
            end
            if #mons == 0 then return end
            table.sort(mons, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
            for i, m in ipairs(mons) do
                local where = #mons == 1 and "" or (i == 1 and "left" or (i == #mons and "right" or "middle"))
                if m.tall then where = where == "" and "portrait" or (where .. ", portrait") end
                m.sub = where
            end
            B.mons = mons
            show()
            publish()
            settle()
        end)
    end

    -- What bar.json keeps: the chosen monitors, whether the others keep the frame, and the frame rate.
    local function save(screens)
        local fps = (B.fps and B.fps ~= FPS_FREE) and B.fps or nil
        pcall(sys.call, "files.write", "bar.json", { screens = screens, others = B.others and "frame" or nil, fps = fps, ws_style = (B.ws or 0) ~= 0 and B.ws or nil })
    end

    -- Settings > Bar: how many frames a second the bar paints. A 240 Hz screen has it paint a panel 240 times a
    -- second, which costs while it lasts what a game at that rate costs; the animations last the same either way,
    -- so this is less current, not less movement. The scene reads `bar_fps` in its `rate:`, so it takes at once
    -- and nothing is restarted. FPS_FREE is `rate:`'s ceiling in the language, which is to say "no cap".
    on("bar_pick_fps", function(n)
        n = math.floor(tonumber(n) or 0)
        for _, v in ipairs(FPS) do
            if v == n then
                B.fps = n
                fact.bar_fps = n
                return save(B.pref or chosen())
            end
        end
    end)

    -- Settings > Bar > Workspaces: how the marks look (0 squares, 1 dots, 2 numbers, 3 lines). The scene morphs between them, so it is at once.
    on("bar_pick_ws", function(n)
        n = math.floor(tonumber(n) or 0)
        if n < 0 or n > 3 then return end
        B.ws = n
        fact.ws_style = n
        save(B.pref or chosen())
    end)

    -- A tile of the Bar page: it joins the bar's monitors, or leaves them. One stays, and no more than MAX.
    on("bar_pick_scr", function(i)
        if B.busy then return end
        local m = B.mons[math.floor(i + 0.5) + 1]
        if not m then return end
        local sel, now = chosen(), {}
        local chosen_now = false
        for _, n in ipairs(sel) do
            if n == m.name then chosen_now = true else now[#now + 1] = n end
        end
        B.note = nil
        if chosen_now then
            if #now == 0 then B.note = "The bar needs a monitor." else sel = now end
        elseif #sel >= MAX then
            B.note = "The bar is on " .. MAX .. " monitors at the most: let one go first."
        else
            sel[#sel + 1] = m.name
        end
        B.pref = sel
        save(B.pref)
        show()
        if B.file ~= nil and file_for() ~= B.file then restart() else publish() end
    end)

    -- Settings > Bar's switch: the frame on the other monitors, or nothing there. The scene is on every monitor already, so it is at once.
    on("bar_others_toggle", function()
        B.others = not B.others
        save(B.pref or chosen())
        publish()
    end)

    local ok, saved = pcall(sys.ask, "files.read", "bar.json", "json")
    if ok and type(saved) == "table" then
        -- a list of names; from before, one name (or "all": the first two monitors, as nothing chosen)
        if type(saved.screens) == "table" then B.pref = saved.screens
        elseif type(saved.screens) == "string" and saved.screens ~= "all" then B.pref = { saved.screens } end
    end
    if ok and type(saved) == "table" and saved.others == "frame" then B.others = true end
    B.fps = FPS_FREE
    if ok and type(saved) == "table" and type(saved.fps) == "number" then
        for _, v in ipairs(FPS) do if v == saved.fps then B.fps = saved.fps end end
    end
    fact.bar_fps = B.fps
    B.ws = (ok and type(saved) == "table" and type(saved.ws_style) == "number") and math.floor(saved.ws_style) or 0
    if B.ws < 0 or B.ws > 3 then B.ws = 0 end
    fact.ws_style = B.ws
    -- What this bar was started with: the `screens:` of the scene's surface.
    with_dirs(function(d)
        run("grep", { "-o", "-m1", "-E", "screens: [^;]*;", d.conf .. "/vitreus.plm" }, function(out)
            local v = (out or ""):match("screens:%s*(.-)%s*;")
            if v == nil then return end
            B.file = v
            local named = v:match('^"([^"]+)"')
            if B.pref == nil and named then B.pref = { named } end
            show()
            publish()
            settle()
        end)
    end)
    read_mons()
    every(5000, read_mons)
    every(2000, copies)
    after(8000, function() B.awake = true; settle() end)
end
