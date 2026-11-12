-- The login screen (Settings > Greeter): its picture or video and its clock. Everything goes through bin/vitreus-greeter, which keeps them in a folder of the
-- user's that the greeter reads, so nothing asks for a password. `info` is read when the page opens and after each change.
-- `list(dir)`, `entry(i)` and `home()` are the folder browser's (vitreus.luau's FACE: this module reads none of its globals, which a handler here would see stale).
return function(list, entry, home)
    local ver = 0
    local last_dir = nil              -- where the browser was when something was picked: it opens there again
    local c24 = false
    local active = true               -- SDDM uses this greeter

    local function say(msg, err)
        text.gr_msg = msg or ""
        fact.gr_err = err and true or false
    end

    -- what went wrong, in the helper's own words (its last line)
    local function last_line(out, code)
        local last = ""
        for line in (out or ""):gmatch("[^\n]+") do last = line end
        return last ~= "" and last or ("error " .. tostring(code))
    end

    local function refresh(keep_msg)
        run("vitreus-greeter", { "info" }, function(out, code)
            if code ~= 0 then say("The login screen's helper could not run: " .. last_line(out, code), true); return end
            local v = {}
            for k, val in (out or ""):gmatch("([%w_]+)=([^\n]*)") do v[k] = val end
            local ready, writable = v.ready == "1", v.writable == "1"
            fact.gr_ready = ready
            fact.gr_installed = v.installed == "1"
            active = v.active == "1"
            fact.gr_active = active
            fact.gr_sddm = v.sddm == "1"
            text.gr_other_t = v.sddm ~= "1" and "Needs SDDM, which is not installed here: another program shows the login screen" or "Off: SDDM shows " .. ((v.other or "") ~= "" and ("the " .. v.other .. " login screen") or "its own login screen") .. ", set up outside Vitreus"
            fact.gr_writable = writable
            fact.gr_own = v.kind == "picture" or v.kind == "video"
            c24 = v.clock == "24"
            fact.gr_c24 = c24 and 1 or 0
            if v.kind == "video" then text.gr_kind_t = "Video"
            elseif v.kind == "picture" then text.gr_kind_t = "Picture"
            elseif ready then text.gr_kind_t = "Vitreus's own picture"
            else text.gr_kind_t = v.name == "video" and "The video installed earlier" or "The picture installed earlier" end
            if v.kind == "picture" or v.kind == "video" then text.gr_name_t = v.name or ""
            elseif ready then text.gr_name_t = "Installed with the login screen"
            else text.gr_name_t = "Apply below to keep it as yours" end
            ver = ver + 1
            local pv = (v.poster and v.poster ~= "") and (v.poster .. "?" .. ver) or ""
            text.gr_poster = pv
            fact.gr_has_pv = pv ~= ""
            -- a video with nothing to play it: the greeter shows its first frame, and says nothing (it has nowhere to)
            local video = v.kind == "video" or (v.kind == "theme" and v.name == "video")
            if video and v.mm ~= "1" and v.sddm == "1" then
                say("To play on the login screen, a video needs qt6-multimedia and qt6-multimedia-ffmpeg (pacman -S qt6-multimedia qt6-multimedia-ffmpeg): until then it shows its first frame", true)
            elseif not keep_msg then
                say("", false)
            end
        end)
    end

    -- a change through the helper: busy while it works, then the page read again
    -- (a change that worked says nothing: the page shows it. Only what takes a while and what went wrong are written under the cards.)
    local function change(args, busy_msg)
        fact.gr_busy = true
        say(busy_msg or "", false)
        run("vitreus-greeter", args, function(out, code)
            fact.gr_busy = false
            if code ~= 0 then
                say("Not changed: " .. last_line(out, code), true)
                refresh(true)
                return
            end
            say("", false)
            refresh(true)
        end)
    end

    on("gr_browse", function()
        local h = home()
        list(last_dir or (h ~= "" and (h .. "/Pictures") or nil))
    end)
    on("gr_pick", function(i)
        local e = entry(i)
        if not e or e.dir then return end
        last_dir = e.path:match("^(.*)/[^/]*$")
        local name = e.path:match("[^/]+$") or e.path
        change({ "set", e.path }, e.vid and ("Making the login screen's video from " .. name .. "…") or "")
    end)
    on("gr_default", function()
        change({ "default" }, "")
    end)
    on("gr_clock", function()
        c24 = not c24
        fact.gr_c24 = c24 and 1 or 0
        change({ "clock", c24 and "24" or "12" })
    end)
    -- Apply: the helper builds the greeter and copies it into place through pkexec (126 and 127 are pkexec's own: the password was cancelled).
    on("gr_apply", function()
        fact.gr_busy = true
        say("Updating the login screen…", false)
        run("vitreus-greeter", { "install" }, function(out, code)
            fact.gr_busy = false
            if code == 126 or code == 127 then say("Not updated: the password was cancelled", true)
            elseif code ~= 0 then say("Not updated: " .. last_line(out, code), true)
            else say("", false) end
            refresh(true)
        end)
    end)
    -- The switch: SDDM uses this greeter, or the one it used before. Changing SDDM's files asks for the password (pkexec); cancelled, the switch goes back.
    on("gr_toggle_use", function()
        local on = not active
        active = on
        fact.gr_active = on
        fact.gr_busy = true
        say(on and "Turning the Vitreus login screen on…" or "Turning the Vitreus login screen off…", false)
        run("vitreus-greeter", { "use", on and "on" or "off" }, function(out, code)
            fact.gr_busy = false
            if code == 126 or code == 127 then say("Not changed: the password was cancelled", true)
            elseif code ~= 0 then say("Not changed: " .. last_line(out, code), true)
            else say("", false) end
            refresh(true)
        end)
    end)
    on("gr_preview", function()
        run("vitreus-greeter", { "preview" }, function(out, code)
            if code ~= 0 then say("Could not open it: " .. last_line(out, code), true) end
        end)
    end)

    on("fact:set_page", function(v) if v == "pg_greeter" then refresh() end end)
    after(1500, function() refresh() end)       -- (the launcher's «Settings: Greeter» sets the page from the logic, which no `fact:` handler hears)
end
