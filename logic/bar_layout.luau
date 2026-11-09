-- The bar's pieces are in a fixed order: the workspaces, the clock beside the window title, the tray, search, the gear and the controls.
-- (There used to be an editor for it on the Bar page, and a bar-layout.json that kept what it made: both are gone, and the file is ignored.)
-- The bar reads `bo.<piece>` (its place) and `bv.<piece>` (shown). The add-ons piece (`ax`) stays hidden: the add-on icons stay in their pill.
return function()
    local order = { "ws", "clock", "title", "tray", "sr", "set", "ctl", "ax" }
    for n, k in ipairs(order) do
        fact["bo." .. k] = n - 1
        if k ~= "set" then fact["bv." .. k] = (k ~= "ax") end
    end
    -- the player's buttons are not a piece: they sit inside the window title's chip, wherever that is
    fact["bv.media"] = true
    fact["bo.media"] = (fact["bo.title"] or 0) + 0.5
end
