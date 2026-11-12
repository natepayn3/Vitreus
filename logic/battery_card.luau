-- The battery panel the bar's battery icon opens (pages/battery_card.plm, in the control center's drawer): the battery's health and its charging options.
-- Everything comes from bin/vitreus-battery: `info` when the card opens, `mode NAME` and `limits START END` to change them
-- (those ask for the password through polkit unless udev/70-vitreus-battery.rules is installed).
-- The limits are stepped by 5 % in the card and written once the clicks stop for a moment, so a run of presses is one password prompt.
return function()
    local HELP = {
        Standard = "Charges at the usual pace, all the way to 100 %.",
        Adaptive = "Learns how you use the laptop and keeps the charge lower while it is mostly plugged in.",
        Fast = "Charges as fast as it can. Wears the battery a little sooner.",
        Trickle = "Charges slowly. The gentlest, for a laptop that is nearly always plugged in.",
        Custom = "Charges only between the two levels below. Stopping short of 100 % is kindest to the battery.",
        PrimAC = "For a laptop that is nearly always plugged in.",
    }
    local modes = {}           -- the names the battery offers, in its order
    local cur = nil            -- the chosen one
    local has_thr, has_start = false, false
    local s_lim, e_lim = 50, 90
    local apply_seq = 0
    local s_min = 50           -- how low the start goes (Dell 50, the others 0)
    local stops = nil          -- the only stops the firmware takes (LG, Toshiba: { 80, 100 }), or nil for any 55..100
    local bios = false         -- a BIOS admin password: changes go through the BIOS's settings, with it
    local pending = nil        -- the change waiting for that password: { "mode", name } or { "limits", s, e }

    local function show_thr()
        fact["bc.thr"] = has_thr and (#modes == 0 or cur == "Custom")
    end

    local function refresh()
        run("vitreus-battery", { "info" }, function(out, code)
            if code ~= 0 or not out or out == "" then fact["bc.ok"] = false; return end
            local v = {}
            for k, val in out:gmatch("([%w_]+)=([^\n]*)") do v[k] = val end
            fact["bc.ok"] = true
            -- Health: what it holds now against what it held new.
            local full, design = tonumber(v.full), tonumber(v.design)
            if full and design and design > 0 then
                local h = math.floor(full / design * 100 + 0.5)
                fact["bc.health"] = h
                text.bc_word = h >= 80 and "Good" or (h >= 60 and "Fair" or "Worn")
                if v.unit == "wh" then
                    text.bc_cap = string.format("Holds %.1f of %.1f Wh it had new", full / 1000, design / 1000)
                else
                    text.bc_cap = string.format("Holds %.2f of %.2f Ah it had new", full / 1e6, design / 1e6)
                end
            else
                fact["bc.health"] = -1
                text.bc_word = ""
                text.bc_cap = "The battery does not report its capacity"
            end
            local bits = {}
            if v.maker and v.maker ~= "" then bits[#bits + 1] = v.maker end
            if v.tech and v.tech ~= "" then bits[#bits + 1] = v.tech end
            local cyc = tonumber(v.cycles)
            if cyc and cyc > 0 then bits[#bits + 1] = cyc .. (cyc == 1 and " cycle" or " cycles") end
            text.bc_detail = table.concat(bits, " · ")
            -- The charge modes: "Trickle [Fast] Standard Adaptive Custom".
            modes, cur = {}, nil
            for w in (v.modes or ""):gmatch("%S+") do
                local name = w:match("^%[(.-)%]$")
                if name then cur = name else name = w end
                modes[#modes + 1] = name
            end
            local rows = {}
            for _, n in ipairs(modes) do rows[#rows + 1] = { name = n, on = (n == cur) } end
            model.bc_modes = rows
            fact["bc.nmodes"] = #modes
            text.bc_desc = cur and (HELP[cur] or "") or ""
            has_start = tonumber(v.start) ~= nil
            has_thr = tonumber(v["end"]) ~= nil
            if has_thr then
                e_lim = tonumber(v["end"])
                s_lim = tonumber(v.start) or 0
                fact["bc.start"] = s_lim
                fact["bc.end"] = e_lim
            end
            fact["bc.hasstart"] = has_start
            s_min = tonumber(v.smin) or 50
            stops = nil
            for n in (v.stops or ""):gmatch("%d+") do stops = stops or {}; stops[#stops + 1] = tonumber(n) end
            show_thr()
            fact["bc.ask"] = v.writable ~= "1"
            bios = v.bios == "1"
            fact["bc.bios"] = bios
        end)
    end

    -- A change that did not go through says why, in the panel: 126/127 is pkexec's own (the password was cancelled), the rest is what the helper or the kernel said.
    local function fail(out, code)
        if code == 0 then text.bc_err = ""; fact["bc.err"] = false; return end
        fact["bc.err"] = true
        if code == 126 or code == 127 then text.bc_err = "Not changed: the password was cancelled"; return end
        if code == 4 then text.bc_err = "Saved in the BIOS: it takes effect after a restart"; return end
        local last = ""
        for line in (out or ""):gmatch("[^\n]+") do last = line end
        last = last:gsub("^.-: ", "", 1)
        text.bc_err = "Not changed: " .. (last ~= "" and last or ("error " .. tostring(code)))
    end

    -- One change, straight (the kernel's files) or, with a BIOS password, held until it is typed into the panel.
    local function apply(args)
        text.bc_err = ""; fact["bc.err"] = false
        if bios then
            pending = args
            fact["bc.pwask"] = true
            return
        end
        fact["bc.busy"] = true
        run("vitreus-battery", args, function(out, code)
            fact["bc.busy"] = false
            fail(out, code)
            refresh()
        end, { errors = true })
    end
    -- The BIOS password was typed (Enter or Apply): read out of the field, the field emptied, and handed to the helper on its input only.
    on("fact:bc_bgo", function(v)
        if not (v == true or tostring(v) == "true") then return end
        fact.bc_bgo = false
        local pw = text.bc_bpw or ""
        text.bc_bpw = ""
        if not pending or pw == "" then return end
        local args = { "bios" }
        for _, a in ipairs(pending) do args[#args + 1] = a end
        pending = nil
        fact["bc.pwask"] = false
        fact["bc.busy"] = true
        run("vitreus-battery", args, function(out, code)
            fact["bc.busy"] = false
            fail(out, code)
            refresh()
        end, { errors = true, input = pw .. "\n" })
        pw = nil
    end)
    on("bc_bcancel", function()
        pending = nil
        text.bc_bpw = ""
        fact["bc.pwask"] = false
        refresh()
    end)

    on("fact:panel", function(v)
        if tostring(v) == "battery" then text.bc_err = ""; fact["bc.err"] = false; fact["bc.busy"] = false
        else pending = nil; text.bc_bpw = ""; fact["bc.pwask"] = false end
    end)
    on("fact:panel", function(v) if tostring(v) == "battery" then refresh() end end)

    on("bc_mode", function(i)
        local name = modes[(tonumber(i) or -1) + 1]
        if not name or name == cur then return end
        -- Shown at once; put back by the refresh if the change did not go through (a cancelled password).
        cur = name
        local rows = {}
        for _, n in ipairs(modes) do rows[#rows + 1] = { name = n, on = (n == cur) } end
        model.bc_modes = rows
        text.bc_desc = HELP[cur] or ""
        show_thr()
        apply({ "mode", name })
    end)

    -- 0 start down, 1 start up, 2 stop down, 3 stop up. The stop is 55..100 (or one of `stops`), the start `s_min`..stop - 5.
    on("bc_step", function(k)
        k = tonumber(k) or -1
        if k < 0 or k > 3 then return end
        if stops and k >= 2 then
            -- the next of the levels the firmware takes, up or down from where it is
            local pick = e_lim
            if k == 3 then
                for _, n in ipairs(stops) do if n > e_lim then pick = n; break end end
            else
                for i = #stops, 1, -1 do if stops[i] < e_lim then pick = stops[i]; break end end
            end
            e_lim = pick
        else
            if k == 0 then s_lim = s_lim - 5 elseif k == 1 then s_lim = s_lim + 5
            elseif k == 2 then e_lim = e_lim - 5 else e_lim = e_lim + 5 end
            e_lim = math.max(55, math.min(100, e_lim))
            if k <= 1 then
                s_lim = math.max(s_min, math.min(95, s_lim))
                if s_lim > e_lim - 5 then e_lim = math.min(100, s_lim + 5) end
            end
        end
        s_lim = math.max(s_min, math.min(e_lim - 5, s_lim))
        fact["bc.start"] = s_lim
        fact["bc.end"] = e_lim
        apply_seq = apply_seq + 1
        local mine = apply_seq
        after(1200, function()
            if mine ~= apply_seq then return end
            apply({ "limits", tostring(s_lim), tostring(e_lim) })
        end)
    end)

    -- (A change started by a logic that has since been reloaded never answers this one: nothing is being written now.)
    fact["bc.busy"] = false
    fact["bc.pwask"] = false
    refresh()
end
