-- The bar's pieces are in a fixed order: the workspaces, the clock beside the window title, the tray, search, the gear and the controls.
-- (There used to be an editor for it on the Bar page, and a bar-layout.json that kept what it made: both are gone, and the file is ignored.)
-- The bar reads `bo.<piece>` (its place) and `bv.<piece>` (shown). The add-ons piece (`ax`), the add-on pill's icons, is shown only when
-- Settings > Bar > "Add-on icons on the bar" is on (`bar_ax`, kept in bar-addons.json); off, the icons stay in their pill.
return function()
    local order = { "ws", "clock", "title", "tray", "sr", "set", "ctl", "ax" }
    local ax_on = false
    local ok, saved = pcall(sys.ask, "files.read", "bar-addons.json", "json")
    if ok and type(saved) == "table" and saved.on == true then ax_on = true end
    -- Settings > Bar > "Show ...": the Desk's button, search, the gear and the control center can each be hidden (kept in bar-icons.json: a name is false when hidden).
    local icons = { dsk = true, bat = true, sr = true, set = true, ctl = true }
    local ok2, sv = pcall(sys.ask, "files.read", "bar-icons.json", "json")
    if ok2 and type(sv) == "table" then for k in pairs(icons) do if sv[k] == false then icons[k] = false end end end
    for n, k in ipairs(order) do
        fact["bo." .. k] = n - 1
        if k ~= "set" and k ~= "ax" then fact["bv." .. k] = (icons[k] ~= false) end
    end
    fact["bv.set"] = icons.set
    fact["bv.dsk"] = icons.dsk
    fact["bv.bat"] = icons.bat
    for _, k in ipairs({ "dsk", "bat", "sr", "set", "ctl" }) do
        on("bar_show_" .. k, function()
            icons[k] = not icons[k]
            fact["bv." .. k] = icons[k]
            pcall(sys.call, "files.write", "bar-icons.json", { dsk = icons.dsk, bat = icons.bat, sr = icons.sr, set = icons.set, ctl = icons.ctl })
        end)
    end
    fact["bo.ax"] = 3.2           -- after the tray and the clock/title group, before the Desk button, search, the gear and the controls
    fact["bv.ax"] = ax_on
    fact.bar_ax = ax_on
    on("bar_ax_toggle", function()
        ax_on = not ax_on
        fact["bv.ax"] = ax_on
        fact.bar_ax = ax_on
        pcall(sys.call, "files.write", "bar-addons.json", { on = ax_on })
    end)
    -- the player's buttons are not a piece: they sit inside the window title's chip, wherever that is
    fact["bv.media"] = true
    fact["bo.media"] = (fact["bo.title"] or 0) + 0.5
end
