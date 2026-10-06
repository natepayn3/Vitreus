-- The Bar page of the settings: which monitors the bar shows on. pleamar reads that (`screens:` on the scene's
-- surface) only when it starts, so choosing rewrites that line of vitreus.plm and starts the bar again, from a
-- command left running on its own (`setsid`) that asks this one to quit and then opens the scene afresh. What was
-- chosen is kept in bar.json; a chosen monitor that is not plugged in puts the bar on all of them until it is back.
return function(with_dirs)
    local B = { pref = nil, file = nil, mons = {}, busy = false, awake = false }
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
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
    -- Where the bar should be now: the choice, or all of them while the chosen one is away.
    local function target()
        local pref = B.pref or "all"
        if pref ~= "all" and not connected(pref) then return "all" end
        return pref
    end

    -- Tell the window gaps where the bar is (it is where the scene was started, not where it is about to go) and what is plugged in.
    local told = nil
    local function publish()
        if B.file == nil or #B.mons == 0 then return end
        local names = {}
        for _, m in ipairs(B.mons) do names[#names + 1] = m.name end
        local on = (B.file ~= "all" and connected(B.file)) and B.file or "all"
        local sig = on .. "|" .. table.concat(names, ",")
        if sig == told then return end
        told = sig
        bar_fx.on, bar_fx.mons = on, names
        iris_fx.apply_hypr()
    end

    local function show()
        local pref = B.pref or "all"
        local at = pref ~= "all" and connected(pref) or nil
        fact.bar_scr = at and (at - 1) or -1
        for i = 0, 3 do
            local m = B.mons[i + 1]
            fact["bar_m." .. i .. ".on"] = m ~= nil
            if m then
                text["bar_m." .. i .. ".name"] = m.name
                text["bar_m." .. i .. ".sub"] = m.sub
            end
        end
        if B.busy then
            text.bar_msg = "Moving the bar…"
        elseif pref ~= "all" and not at and #B.mons > 0 then
            text.bar_msg = pref .. " isn't plugged in, so the bar is on every monitor until it's back."
        else
            text.bar_msg = ""
        end
    end

    local function restart(to)
        if B.busy then return end
        if to ~= "all" and not to:match("^[%w%._%-]+$") then return end
        B.busy = true
        show()
        with_dirs(function(d)
            local plm = d.conf .. "/vitreus.plm"
            local value = to == "all" and "all" or ('"' .. to .. '"')
            run("sed", { "-i", "-E", "/^    surface \\{/s/screens: [^;]*;/screens: " .. value .. ";/", plm }, function(_, code)
                if code ~= 0 then
                    B.busy = false
                    show()
                    text.bar_msg = "Couldn't change where the bar shows."
                    return
                end
                B.file = to
                run("setsid", { "-f", "sh", "-c", RESTART, "sh", plm, d.data .. "/vitreus.log" }, function() end)
            end)
        end)
    end

    -- Put the bar where it should be, once what the file says and what is plugged in are both known. Not in the
    -- first seconds after starting, so a monitor that is still waking up does not send it back and forth.
    local function settle()
        if B.busy or B.file == nil or #B.mons == 0 then return end
        if not B.awake then return end
        local to = target()
        if to ~= B.file then restart(to) end
    end

    local function read_mons()
        hypr_monitors(4, function(out, code)
            if code ~= 0 or not out then return end
            local ok, list = pcall(json.decode, out)
            if not ok or type(list) ~= "table" then return end
            local mons = {}
            for _, j in ipairs(list) do
                local t = j.transform or 0
                mons[#mons + 1] = { name = j.name, x = j.x or 0, y = j.y or 0, tall = t == 1 or t == 3 or t == 5 or t == 7 }
            end
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

    on("bar_pick_scr", function(i)
        if B.busy then return end
        local pref = "all"
        if i >= 0 then
            local m = B.mons[math.floor(i + 0.5) + 1]
            if not m then return end
            pref = m.name
        end
        B.pref = pref
        pcall(sys.call, "files.write", "bar.json", { screens = pref })
        show()
        local to = target()
        if B.file ~= nil and to ~= B.file then restart(to) end
    end)

    local ok, saved = pcall(sys.ask, "files.read", "bar.json", "json")
    if ok and type(saved) == "table" and type(saved.screens) == "string" then B.pref = saved.screens end
    -- What this bar was started with: the `screens:` of the scene's surface.
    with_dirs(function(d)
        run("grep", { "-o", "-m1", "-E", "screens: [^;]*;", d.conf .. "/vitreus.plm" }, function(out)
            local v = (out or ""):match("screens:%s*(.-)%s*;")
            if v == nil then return end
            B.file = v:match('^"([^"]+)"') or "all"
            if B.pref == nil then B.pref = B.file end
            show()
            publish()
            settle()
        end)
    end)
    read_mons()
    every(5000, read_mons)
    after(8000, function() B.awake = true; settle() end)
end
