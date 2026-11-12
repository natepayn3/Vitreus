-- The desktop editor's logic: it does what the tiles say, by telling Vitreus (which knows how to start a desktop card that is not running) and the widgets' own scenes.
-- A tile is a position: 0 clock, 1 system monitor, 2 audio visualiser (the bottom edge rising into the music), 3 (the webcam, now the Desk's Camera: no tile), 4 a new sticky note.
-- (the calendar and the reminders, 4 and 5, are cards of desktopcards.plm: they are switched by its own facts, `cal_shown` and `rem_shown`)
local EVENTS = { "dclock_toggle", "dsys_toggle", "fw_toggle", "cam_toggle", false, false, "sticky_new" }
local CARD_FACT = { [4] = "cal_shown", [5] = "rem_shown" }
local SCENES = { "desktopclock", "desktopsysmon", "vitreus", "vitreus" }
local SHOWN = { "shown", "shown", "fw_on", "cam_on" }      -- the fact that says whether each is on (the audio visualiser is Vitreus's own: the bottom edge; 3 has no tile)
-- The scenes whose cards can be dragged in place (`fact edit`): they show the cells they take while the editor is open.
local MOVABLE = { "desktopclock", "desktopsysmon", "desktopcards", "desktopnotes" }

local function refresh()
    for i, name in ipairs(SCENES) do
        run("pleamar", { "--say", name, "get " .. SHOWN[i] }, function(out, code)
            fact["on" .. (i - 1)] = code == 0 and (out or ""):match("true") ~= nil
        end)
    end
end

local CARDS_PLM = '$HOME/.config/pleamar/shells/vitreus/desktopcards/desktopcards.plm'
local function start_cards()
    run("sh", { "-c", 'PATH="$HOME/.local/bin:$PATH" vitreus-keep "' .. CARDS_PLM .. '" >/dev/null 2>&1 &' }, function() end)
end
local function refresh_cards()
    for tile, key in pairs(CARD_FACT) do
        run("pleamar", { "--say", "desktopcards", "get " .. key }, function(out, code)
            fact["on" .. tile] = code == 0 and (out or ""):match("true") ~= nil
        end)
    end
end
-- Add-ons with a desktop widget (`[widget]` in their addon.toml): the ones that are running, as Vitreus lists them (`aw_list`: a line each, the socket, "menu" or
-- nothing, the name and the icon, between tabs), a tile each. A tile flips the add-on's `widget_shown`, or opens the add-on's own menu (`menu = true`); while the
-- editor is open each one is told `widget_edit`. A scene that does not answer is left as it was.
local aw = {}
local function aw_show()
    local rows = {}
    for i, a in ipairs(aw) do rows[i] = { name = a.name:upper(), icon = a.icon, on = a.on == true } end
    model.aw = rows
end
local function aw_refresh()
    for _, a in ipairs(aw) do
        run("pleamar", { "--say", a.sock, "get widget_shown" }, function(out, code)
            if code == 0 and out and not out:find("?", 1, true) then a.on = out:match("true") ~= nil; aw_show() end
        end)
    end
end
local function aw_load(done, tries)
    run("pleamar", { "--say", "vitreus", "get aw_list" }, function(out, code)
        if code == 0 and out and out:find("?", 1, true) == 1 and (tries or 0) < 8 then after(700, function() aw_load(done, (tries or 0) + 1) end) return end     -- (busy: again in a moment)
        if code ~= 0 or not out or out:find("?", 1, true) == 1 then if done then done() end return end
        local list = {}
        for line in (out .. "\n"):gmatch("([^\n]*)\n") do
            local sock, menu, name, icon = line:match("^([%w_%-]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if sock and #list < 4 then
                local was = nil
                for _, a in ipairs(aw) do if a.sock == sock then was = a end end
                list[#list + 1] = { sock = sock, menu = menu == "menu", name = name, icon = icon, on = was and was.on }
            end
        end
        aw = list
        aw_show()
        aw_refresh()
        if done then done() end
    end)
end
local function edit_widgets(on)
    for _, name in ipairs(MOVABLE) do
        run("pleamar", { "--say", name, "fact edit " .. tostring(on) }, function() end)
    end
end
local function edit_addons(on)
    for _, a in ipairs(aw) do run("pleamar", { "--say", a.sock, "fact widget_edit " .. tostring(on) }, function() end) end
end

-- Closed, the editor draws nothing, and waiting costs its ~70 MB all the same: a while after it was closed (and after it started, if it is never opened)
-- it leaves, its keeper first or the keeper would start it again. A right press on the wallpaper starts it again (wptrans.luau, or vitreus.luau
-- under pleamar-wm). The `[t]` keeps the pattern from matching the `sh` that runs it.
local IDLE_MS = 30000
local idle_n = 0
local function idle_check()
    idle_n = idle_n + 1
    local mine = idle_n
    after(IDLE_MS, function()
        if mine ~= idle_n or fact.open == true then return end
        run("sh", { "-c", "pkill -f 'vitreus-keep .*/desktopedi[t]/desktopedit[.]plm'; pleamar --say desktopedit quit" }, function() end)
    end)
end
idle_check()

-- It fires for what the scene sets (Done, Escape) and for what is said from outside (the menu, the key): the widgets are told either way.
on("fact:open", function(v)
    local opened = v and true or false
    idle_check()
    edit_widgets(opened)
    if opened then aw_load(function() edit_addons(true) end) else edit_addons(false) end        -- (the add-ons' list first, so the ones that came since are told too)
    if opened then refresh(); refresh_cards() end
    if not opened then run("pleamar", { "--say", "vitreus", "emit widgets_changed" }, function() end) end      -- (a theme that keeps its widgets takes them as they were left: Settings > Theme > Pin widgets)
end)

on("tile_do", function(i)
    local n = math.floor((tonumber(i) or 0) + 0.5)
    local key = CARD_FACT[n]
    if key then
        -- a card of the calendar / reminders scene: ask how it is, switch it (starting the scene first when it is not running)
        run("pleamar", { "--say", "desktopcards", "get " .. key }, function(out, code)
            if code ~= 0 then
                start_cards()
                after(3000, function()
                    run("pleamar", { "--say", "desktopcards", "fact " .. key .. " true", "fact edit true" }, function() end)
                    after(400, refresh_cards)
                end)
                return
            end
            local on = (out or ""):match("true") ~= nil
            run("pleamar", { "--say", "desktopcards", "fact " .. key .. " " .. (on and "false" or "true") }, function() end)
            after(300, refresh_cards)
        end)
        return
    end
    local ev = EVENTS[n + 1]
    if not ev then return end
    run("pleamar", { "--say", "vitreus", "emit " .. ev }, function() end)
    -- a card that was not running has to be started first: look again a moment later, and once more when it has settled
    after(450, refresh)
    after(1500, refresh)
end)

-- The tile's press says which tile it is (and, in `awx` and `awy`, the middle of the tile and the top of the shelf, in pixels of this copy): an add-on with a menu
-- (`menu = true` in its `[widget]`) is asked to open it there, over the shelf, on this monitor; any other has its widget shown or hidden.
on("aw_do", function(v)
    local a = aw[math.floor((tonumber(v) or 0) + 0.5) + 1]
    if not a then return end
    if a.menu then
        local mon = text["screen." .. math.max(0, math.floor(tonumber(fact.emon) or 0)) .. ".name"] or ""
        local cmds = { "--say", a.sock, "fact widget_mx " .. math.floor(tonumber(fact.awx) or 0), "fact widget_my " .. math.floor(tonumber(fact.awy) or 0), "fact widget_edit true", "emit widget_menu" }
        if mon ~= "" then table.insert(cmds, 3, "text widget_mon_name " .. mon) end        -- (before the menu: it opens on that monitor)
        run("pleamar", cmds, function() end)
        return
    end
    run("pleamar", { "--say", a.sock, "get widget_shown" }, function(out, code)
        if code ~= 0 or not out or out:find("?", 1, true) then return end
        local on = out:match("true") ~= nil
        run("pleamar", { "--say", a.sock, "fact widget_shown " .. tostring(not on), "fact widget_edit true" }, function() end)
        a.on = not on
        aw_show()
        after(400, aw_refresh)
    end)
end)

-- An add-on whose widgets come and go on its own (from its menu) says so (`aw_say`), so its tile is ticked or not without the editor asking it.
on("aw_say", function()
    local sock = text.aw_said or ""
    for _, a in ipairs(aw) do
        if a.sock == sock then a.on = fact.aw_said_on == true; aw_show() end
    end
end)

-- Whether Vitreus has its glass off (then the shelf is flat obsidian): asked of it when this starts, and again a few seconds in.
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
ask_obs()
after(4000, ask_obs)
-- The theme, as the widgets ask for it (`look_w`): the editor is started when it is wanted now, after Vitreus last told the desktop scenes.
local function ask_look()
    run("pleamar", { "--say", "vitreus", "get look_w" }, function(out, code)
        local v = code == 0 and tonumber((out or ""):match("%-?%d+")) or nil
        if v and v >= 0 then fact.look = v end
    end)
end
ask_look()
after(1500, ask_look)
-- Its colours come from Vitreus too (as facts, see `push_pal` in vitreus.luau).
run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end)
after(1500, function() run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end) end)
