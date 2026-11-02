-- The monitor's real height, for the scene to centre on (`mon_h`): its surface is a fixed 1440 tall, which is only the screen on a
-- 1440 monitor. Hyprland's logical size of the focused monitor (its height over its scale, swapped when it is turned on its side);
-- where there is no hyprctl it stays 0 and the scene uses its surface.
--
-- It also restarts the shell when a monitor changes (a new mode, scale or rotation): the surface keeps the size it had, so the bar and the
-- panels were left laid out for the old screen. Not for a monitor plugged in or unplugged (or switched on or off): pleamar gives it a copy of
-- its own, or takes it away, and the other monitors keep theirs as they are. (Restarting then made the bar, already on its new monitor, and the
-- desktop widgets vanish and come back a few seconds later.) The restart is the keeper's (bin/vitreus-keep starts the scene again when
-- it stops), and the new run takes the monitors as they are as its starting point, so it does not go round again.
-- A change that is on trial (Settings > Display: "Keep these display settings?") does not restart anything: the shell stays as it is while the
-- question is open, so that the page and its Keep button do not vanish under the pointer. Keep restarts it (a moment later); Revert puts the monitors
-- back to what the shell is laid out for, and there is nothing to restart.
return function()
    local base = nil      -- the monitors the shell is laid out for: name -> "width,height,scale,transform"
    local latest = nil    -- the monitors as they are now
    -- Whether a monitor that is in both has changed (one that came or went is taken as it is)
    local function changed()
        if not base or not latest then return false end
        for name, v in pairs(latest) do
            if base[name] ~= nil and base[name] ~= v then return true end
        end
        return false
    end
    local function trial_on()
        if (tonumber(fact.disp_trial) or 0) > 0 then return true end
        -- the trial is written down before the mode is sent (and cleared by Keep, Revert or a refusal), so this also covers the moment
        -- between the mode changing and the page's countdown starting
        local ok, t = pcall(sys.ask, "files.read", "display-trial.json", "json")
        return ok and type(t) == "table" and type(t.before) == "table" and next(t.before) ~= nil
    end
    local calm = 0        -- how many looks in a row found the monitors changed and no trial open (Revert clears the trial a moment before the monitors go back)
    local function maybe_restart()
        if not changed() then
            calm = 0
            base = latest or base
            return
        end
        if trial_on() then
            calm = 0
            return
        end
        calm = calm + 1
        if calm < 2 then return end
        calm = 0
        base = latest
        -- a moment first, for the mode switch to finish (Hyprland can report two steps in a row)
        exec_on_desktop("sleep 1.5; pkill -f '^pleamar --scene .*/vitreus/(vitreus.plm|desktop)'")
    end
    local function check_change(list)
        local now = {}
        for _, m in ipairs(list) do
            now[tostring(m.name)] = table.concat({ tostring(m.width), tostring(m.height), tostring(m.scale), tostring(m.transform) }, ",")
        end
        latest = now
        base = base or latest
        maybe_restart()
    end
    local function sync()
        hypr_monitors(4, function(out, code)
            if code ~= 0 or not out then return end
            local ok, list = pcall(json.decode, out)
            if not ok or type(list) ~= "table" then
                -- pleamar-wm's `hyprctl monitors` is text: "1920x1080@60 at 0x0" and "scale: 1.00" under each monitor (the first one).
                local h = tonumber(out:match("%d+x(%d+)@"))
                local scale = tonumber(out:match("scale:%s*([%d.]+)")) or 1
                if h and scale > 0 then
                    local v = math.floor(h / scale + 0.5)
                    if v ~= fact.mon_h then fact.mon_h = v end
                end
                return
            end
            check_change(list)
            local pick = nil
            for _, m in ipairs(list) do
                if m.focused then pick = m end
            end
            pick = pick or list[1]
            if not pick then return end
            local h = ((tonumber(pick.transform) or 0) % 2 == 1) and pick.width or pick.height
            local scale = tonumber(pick.scale) or 1
            if h and scale > 0 then
                local v = math.floor(h / scale + 0.5)
                if v ~= fact.mon_h then fact.mon_h = v end
            end
        end)
    end
    sync()
    every(4000, sync)
    -- while a change waits for its answer, look often, so that Keep restarts the shell at once
    every(1000, function() if changed() then sync() end end)
end
