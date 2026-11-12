-- The Bar page of the settings: which monitors the bar shows on, any of them up to `MAX`, which is what the page's row of tiles
-- shows and what the scene declares (`bar_c0` to `bar_c3`). The scene is one copy per monitor (`screens: each max N`: what each copy
-- holds of its own is named per copy, `name.$screen`, which only a copy per monitor has), and **N follows the monitors that are
-- plugged in**: a desk of three gets three copies, a desk of one pays for one. Growing is at once, because a monitor without a copy
-- shows nothing at all, not even the frame; shrinking waits for the next start, so unplugging does not restart the bar.
-- **Each copy is given its monitor by name** (`--screen A,B`: copy K to the K-th name), from the list this leaves in bar-screens in the
-- data folder, which bin/vitreus-keep passes on every start. Left to pleamar, copy K went to the K-th monitor in the order the compositor
-- announced them, and a monitor switched off and on again is announced last: the bar's copy landed on another monitor and was closed
-- there, and the bar was gone until the next login (issue #67). By name, a chosen monitor that goes away keeps its copy waiting, and
-- the bar is back on it as soon as it is, without a restart.
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
    local FPS = { FPS_FREE, 120, 60 } -- what the page offers, in the order of its chips (`rate:` in the scene has a line for each)
                                     -- `rate:` clause is honoured, so there is one value to choose besides "Screen"
    local B = { pref = nil, file = nil, mons = {}, busy = false, awake = false, others = false, may_shrink = true, fit = nil }
    local LIMIT = 65536              -- the properties a scene can hold (pleamar): every copy has all of the scene's own, so N copies cost N times it
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^([^ ]*/)?pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^([^ ]*/)?pleamar --scene $P"
pkill -f "^([^ ]*/)?pleamar --scene .*/vitreus/desktop"  # the desktop widgets restart with the shell (their keepers start them again)
sleep 0.3
[ "$(stat -c %s "$L" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$L" "$L.1"
# under its keeper when there is one (bin/vitreus-keep): a keeper already looking after it starts it again itself
command -v vitreus-keep >/dev/null 2>&1 && exec vitreus-keep "$P" "$L"
if [ -n "$3" ]; then exec pleamar --scene "$P" --no-hud --screen "$3" >>"$L" 2>&1; fi
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
    -- The monitors that need a copy, in the order the copies are handed out (`--screen`, copy K to the K-th): the chosen ones that are
    -- plugged in, then the chosen ones that are not, whose copies wait for them (switched on again, or after the session started, the
    -- bar is there at once, with no restart), then, with the frame on the others (`others`) or with none of the chosen ones plugged in,
    -- the rest that are plugged in, left to right. Uncut: what fits is `target()`.
    local function layout()
        local out, seen = {}, {}
        local function add(n) if n and not seen[n] and #out < MAX then out[#out + 1] = n; seen[n] = true end end
        local any = false
        for _, n in ipairs(B.pref or {}) do if connected(n) then add(n); any = true end end
        for _, n in ipairs(B.pref or {}) do add(n) end
        if B.others or not any then for _, m in ipairs(B.mons) do add(m.name) end end
        return out
    end
    -- What the scene should be started with: `layout()`, no more of it than fit. Every copy is the whole scene again, and three of it
    -- no longer fit in a scene (issue #60: a desk of three had no bar at all): so never more than fit (`B.fit`, measured once at the start).
    local function target()
        local l = layout()
        local n = math.min(#l, B.fit or MAX)
        local out = {}
        for i = 1, math.max(n, 1) do out[#out + 1] = l[i] end
        return out
    end
    -- Whether the bar has to be started again for `t`: when a monitor of it has no copy. Growing happens as soon as a monitor appears,
    -- because a monitor without a copy of its own shows nothing at all, not even the frame; shrinking only in the first settle after
    -- starting, so unplugging a monitor in the middle of the day does not restart the bar. A file from before says one monitor's name,
    -- and is moved over. A bar started without names (by hand, or before bar-screens) is started again with them, once: if it is
    -- still without them afterwards (bar-screens already says this), whoever started it is left to it rather than restarting for ever.
    local function needs(t)
        B.stuck = false
        local have = tonumber((B.file or ""):match("^each max (%d+)") or "") or 0
        if have == 0 then return true end
        if B.may_shrink and have > #t then return true end
        local named = type(B.started) == "table"
        for _, name in ipairs(t) do
            local ok = false
            for k = 0, have - 1 do
                if (named and B.started[k + 1] == name) or text["screen." .. k .. ".name"] == name then ok = true; break end
            end
            if not ok then
                if not named and B.written == table.concat(t, ",") and have == #t then
                    -- Said, and the copies are opened where they landed (`copies`), so the bar is on the wrong monitor rather than gone with
                    -- nothing saying why (#67: a keeper from before the update, still running its old script, started it without names).
                    B.stuck = true
                    if not B.stuck_said then
                        B.stuck_said = true
                        log("bar · started without --screen even after bar-screens said " .. B.written .. ": is an old vitreus-keep running? The bar stays where its copies landed")
                    end
                    return false
                end
                return true
            end
        end
        return false
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
        -- Started without names and left so (`needs`): when none of its copies landed on a chosen monitor, they are all opened.
        if B.stuck then
            local have = tonumber((B.file or ""):match("^each max (%d+)") or "") or 0
            local hit = false
            for k = 0, have - 1 do if set[text["screen." .. k .. ".name"] or ""] then hit = true end end
            if not hit then for k = 0, have - 1 do local n = text["screen." .. k .. ".name"]; if n and n ~= "" then set[n] = true end end end
        end
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
            -- More copies wanted than fit (target() stops at B.fit): say so, rather than a monitor left bare without a word.
            if text.bar_msg == "" and B.fit and B.fit < MAX then
                local l, need = layout(), 0
                if B.others then need = #l end
                for _, name in ipairs(chosen()) do for i, n in ipairs(l) do if n == name and i > need then need = i end end end
                if need > B.fit then
                    text.bar_msg = "The shell fits on " .. B.fit .. " monitor" .. (B.fit > 1 and "s" or "") .. " at once: " .. (B.others and "turn off the frame on the others, or " or "") .. "choose fewer."
                end
            end
        end
    end

    -- `t` is the list of monitors the copies go to (`target()`), worked out by the caller.
    local function restart(t)
        if B.busy then return end
        B.busy = true
        show()
        with_dirs(function(d)
            local plm = d.conf .. "/vitreus.plm"
            local value = "each max " .. #t
            local list = table.concat(t, ",")
            -- (said in vitreus.log: a restart of the whole shell is worth knowing the reason of)
            local names = {}
            for _, m in ipairs(B.mons) do names[#names + 1] = m.name end
            local was = type(B.started) == "table" and table.concat(B.started, ",") or "unnamed"
            log("bar · restarting for " .. value .. " on " .. list .. " (was " .. tostring(B.file) .. " on " .. was .. "; plugged in: " .. table.concat(names, ", ") .. "; chosen: " .. table.concat(B.pref or {}, ", ") .. ")")
            -- what bin/vitreus-keep hands pleamar as `--screen`, on this start and every one after it
            pcall(sys.call, "files.write", "bar-screens", list .. "\n")
            B.saved = list
            run("sed", { "-i", "-E", "/^    surface \\{/s/screens: [^;]*;/screens: " .. value .. ";/", plm }, function(_, code)
                if code ~= 0 then
                    B.busy = false
                    show()
                    text.bar_msg = "Couldn't change where the bar shows."
                    return
                end
                B.file = value
                run("setsid", { "-f", "sh", "-c", RESTART, "sh", plm, d.data .. "/vitreus.log", list }, function() end)
            end)
        end)
    end

    -- Put the bar where it should be, once what the file says and what is plugged in are both known. Not in the
    -- first seconds after starting, so a monitor that is still waking up does not send it back and forth.
    -- Nothing of the bar is open (a panel, the desk, the dashboard, the overview, the wallpaper picker): a restart now goes unnoticed.
    local function idle()
        return tostring(fact.panel or "none") == "none" and fact.desk_open ~= true and fact.dash_open ~= true and fact.ov_open ~= true and fact.wp_picker_open ~= true
    end
    local function settle()
        if B.busy or B.file == nil or #B.mons == 0 then return end
        if not B.awake or B.fit == nil or B.started == nil then return end
        local t = target()
        -- A chosen monitor switched off had the bar started with a copy waiting for it besides the one on another monitor; with it back, that one
        -- is closed but still built, and every copy is the whole scene again (~330 MB here). Once all the chosen monitors are back, nothing has changed
        -- for 10 s and nothing of the bar is open, it is started again with what it needs, once.
        local have = tonumber((B.file or ""):match("^each max (%d+)") or "") or 0
        if have > #t and not B.may_shrink and B.stable_since and os.time() - B.stable_since >= 10 and idle() then
            local all = true
            for _, n in ipairs(B.pref or {}) do if not connected(n) then all = false end end
            if all then B.may_shrink = true end
        end
        local need = needs(t)
        B.may_shrink = false
        if need then restart(t) return end
        -- the next start (the keeper's, after a crash or a theme change) gives the copies these monitors too
        local list = table.concat(t, ",")
        if B.saved ~= list then
            B.saved = list
            pcall(sys.call, "files.write", "bar-screens", list .. "\n")
        end
        publish()
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
                    mons[#mons + 1] = { name = j.name, id = j.id, x = j.x or 0, y = j.y or 0, tall = tall, w = w, h = h }
                end
            else
                -- pleamar-wm's `hyprctl monitors` is text, even with -j: "Monitor <name> (ID 1):", "2560x1440@164.83 at 1440x733" (its sizes already turned by the rotation).
                for name, id, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID (%d+)%):\n(.-)\n\n") do
                    local w, h, x, y = body:match("(%d+)x(%d+)@[%d%.]+ at (%-?%d+)x(%-?%d+)")
                    if w then mons[#mons + 1] = { name = name, id = tonumber(id), x = tonumber(x), y = tonumber(y), tall = tonumber(h) > tonumber(w), w = tonumber(w), h = tonumber(h) } end
                end
            end
            if #mons == 0 then return end
            table.sort(mons, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
            for i, m in ipairs(mons) do
                local where = #mons == 1 and "" or (i == 1 and "left" or (i == #mons and "right" or "middle"))
                if m.tall then where = where == "" and "portrait" or (where .. ", portrait") end
                m.sub = where
            end
            local sig = {}
            for _, m in ipairs(mons) do sig[#sig + 1] = m.name end
            sig = table.concat(sig, ",")
            if sig ~= B.mons_sig then B.mons_sig = sig; B.stable_since = os.time() end
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

    -- Settings > Display: how many frames a second the shell paints. A 240 Hz screen has it paint a panel 240 times a
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

    -- (Settings > Bar > Workspaces is logic/ws_marks.luau, kept in ws.json; the look bar.json had from before is left as it was, and read there once.)

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
        if B.file ~= nil and B.started ~= nil and needs(target()) then restart(target()) else publish() end
    end)

    -- Settings > Bar's switch: the frame on the other monitors, or nothing there. Turned on, the monitors without a copy need one
    -- (without the frame only the chosen ones have theirs), and the bar is started again for them; otherwise it is at once.
    on("bar_others_toggle", function()
        if B.busy then return end
        B.others = not B.others
        save(B.pref or chosen())
        show()
        if B.file ~= nil and B.fit ~= nil and B.started ~= nil and needs(target()) then restart(target()) else publish() end
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
    local okw, written = pcall(sys.ask, "files.read", "bar-screens")
    -- (what it said when this one started, which the keeper should have passed on: `needs` reads it; `saved` is what it says now)
    B.written = okw and type(written) == "string" and written:match("^%s*(.-)%s*$") or nil
    B.saved = B.written
    -- What this bar was started with: the `screens:` of the scene's surface, and the monitors its copies were given (`--screen`, from
    -- its command line; `false` when it was started without them).
    with_dirs(function(d)
        run("pgrep", { "-af", "^([^ ]*/)?pleamar --scene " .. d.conf .. "/vitreus.plm( |$)" }, function(out)
            local l = (out or ""):match("%-%-screen (%S+)")
            if l and l ~= "all" then
                B.started = {}
                for n in l:gmatch("[^,]+") do B.started[#B.started + 1] = n end
            else
                B.started = false
            end
            settle()
        end)
        run("grep", { "-o", "-m1", "-E", "screens: [^;]*;", d.conf .. "/vitreus.plm" }, function(out)
            local v = (out or ""):match("screens:%s*(.-)%s*;")
            if v == nil then return end
            B.file = v
            -- How many copies fit: what this file holds now, said by `pleamar --check`, over the copies it has (the little the scene
            -- holds once for all of them is counted in each, which only errs low). Without an answer, as many as the page offers.
            local have = tonumber(v:match("^each max (%d+)") or "") or 1
            run("pleamar", { "--check", d.conf .. "/vitreus.plm" }, function(chk)
                local props = tonumber((chk or ""):match("ok · (%d+) properties") or "")
                B.fit = props and props > 0 and math.max(1, math.min(MAX, math.floor(LIMIT * have / props))) or MAX
                if B.fit < MAX then log("bar · " .. B.fit .. " copies fit (" .. tostring(props) .. " properties for " .. have .. ")") end
                show()
                settle()
            end)
            local named = v:match('^"([^"]+)"')
            if B.pref == nil and named then B.pref = { named } end
            show()
            publish()
            settle()
        end)
    end)
    read_mons()
    every(5000, read_mons)
    -- A copy says its monitor's name when it lands on one, also when it moves to another (the monitors are numbered again when one is switched
    -- on). Which copies are open follows at once, not at the next look two seconds later (a copy that moved from the bar's monitor to another
    -- one stayed open there meanwhile), and a monitor switched on is seen then, not at the next look five seconds later.
    local looking = false
    for k = 0, MAX - 1 do
        on("text:screen." .. k .. ".name", function()
            copies()
            if looking then return end
            looking = true
            after(150, function() looking = false; read_mons() end)
        end)
    end
    every(2000, copies)
    after(8000, function() B.awake = true; settle() end)
end
