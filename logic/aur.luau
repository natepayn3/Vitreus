-- The shell's one AUR check: how many AUR packages have a newer version, asked of paru (or yay) with `-Qua`, which only asks the AUR (no root,
-- nothing installed). At the start and every half hour, and again when Home's card is pressed with nothing to update. The answer goes to Home's
-- card (pages/desk_home.plm) and to the desktop system monitor widget (`aur_txt`: it no longer asks itself), so the two never disagree. With
-- updates, a press on the card opens Term and types the update there (`aur_update`, logic/term.luau), to be seen and confirmed.
return function()
    local helper = nil
    local last = 0
    local busy = false
    local function check(force)
        if busy or not helper then return end
        if not force and os.time() - last < 1800 then return end       -- (a press on the card while a check is fresh asks again anyway)
        busy = true
        last = os.time()
        fact.aur_state = 1                                 -- checking
        run(helper, { "-Qua" }, function(out, code)
            busy = false
            local rows = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local name, old, new = line:match("^(%S+)%s+(%S+)%s+%->%s+(%S+)")
                if name then rows[#rows + 1] = { name = name, ver = new } end
            end
            -- no output and a failure is not "up to date": the AUR could not be reached
            if #rows == 0 and code ~= 0 and (out or ""):match("%S") == nil and code ~= 1 then
                fact.aur_state = 3
                text.aur_msg = "Could not check"
                return
            end
            local shown = {}
            for i = 1, math.min(#rows, 6) do shown[i] = rows[i] end
            model.aur_list = shown
            fact.aur_n = #rows
            fact.aur_state = 2
            text.aur_msg = #rows == 0 and "Up to date" or (#rows == 1 and "1 update" or (#rows .. " updates"))
            -- the widget's line, kept here too for a widget that starts later (`get aur_line`)
            local line = #rows == 0 and "AUR · up to date" or string.format("AUR · %d update%s", #rows, #rows == 1 and "" or "s")
            text.aur_line = line
            run("pleamar", { "--say", "desktopsysmon", "text aur_txt " .. line }, function()
                run("pleamar", { "--say", "desktopsysmon", "fact aur_on true" }, function() end)
            end)
        end)
    end
    run("which", { "paru" }, function(_, c)
        if c == 0 then helper = "paru"; check(true); return end
        run("which", { "yay" }, function(_, c2)
            if c2 == 0 then helper = "yay"; check(true)
            else fact.aur_state = 4; text.aur_msg = "No AUR helper" end
        end)
    end)
    every(1800000, function() check(true) end)
    on("aur_check", function() check(true) end)
    -- for logic/term.luau: what to type to update (the helper found here)
    function desk_aur_cmd() return (helper or "paru") .. " -Sua" end
end
