-- The desktop menu's logic. A row is said to Vitreus (`pleamar --say vitreus "emit <event>"`), which does it (it knows how to start a desktop card that is not running, and
-- where the camera lives). When the menu opens, what its switches show is asked: each scene is asked whether it is shown (a scene that is not running does not answer, which is "off").
local ROWS = { "cam_toggle", "dclock_toggle", "dsys_toggle", "sticky_new" }

on("menu_do", function(i)
    local ev = ROWS[math.floor((tonumber(i) or 0) + 0.5) + 1]
    if not ev then return end
        if ev == "sticky_new" then
        -- where the menu was asked for, on which monitor: Vitreus starts the stickers if they are not running and puts the new one there
        run("pleamar", { "--say", "vitreus", "fact sn_mon " .. math.floor((tonumber(fact.mmon) or 0) + 0.5) }, function()
            run("pleamar", { "--say", "vitreus", "fact sn_x " .. math.floor(tonumber(fact.mx) or -1) }, function()
                run("pleamar", { "--say", "vitreus", "fact sn_y " .. math.floor(tonumber(fact.my) or -1) }, function()
                    run("pleamar", { "--say", "vitreus", "emit sticky_new" }, function() end)
                end)
            end)
        end)
        return
    end
    after(120, function() run("pleamar", { "--say", "vitreus", "emit " .. ev }, function() end) end)
end)

local function shown_of(name, key)
    run("pleamar", { "--say", name, "get shown" }, function(out, code)
        fact[key] = code == 0 and (out or ""):match("true") ~= nil
    end)
end
local function refresh()
    shown_of("webcam", "cam_on")
    shown_of("desktopclock", "clock_on")
    shown_of("desktopsysmon", "sys_on")
end
-- It fires for what the scene sets (the press that opens the menu).
on("fact:open", function(v) if v then refresh() end end)

-- Whether Vitreus has its glass off (then the card is flat obsidian): asked of it when this starts, and again a few seconds in.
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
ask_obs()
after(4000, ask_obs)
-- Vitreus tells the scenes when its glass changes (see `obs` in vitreus.luau).
