-- The monitor's real height, for the scene to centre on (`mon_h`): its surface is a fixed 1440 tall, which is only the screen on a
-- 1440 monitor. Hyprland's logical size of the focused monitor (its height over its scale, swapped when it is turned on its side);
-- where there is no hyprctl it stays 0 and the scene uses its surface.
return function()
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
end
