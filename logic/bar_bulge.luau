-- The bulge under the pointer (Settings > Bar > "Bulge under the pointer"): whether the bar's glass and the docks' swell a little where the pointer is over them.
-- Kept in bar-bulge.json (`on`); on unless it was switched off.
return function()
    local on_ = true
    local ok, saved = pcall(sys.ask, "files.read", "bar-bulge.json", "json")
    if ok and type(saved) == "table" and type(saved.on) == "boolean" then on_ = saved.on end
    fact.bar_bulge = on_
    on("bar_bulge_toggle", function()
        on_ = not on_
        fact.bar_bulge = on_
        pcall(sys.call, "files.write", "bar-bulge.json", { on = on_ })
    end)
end
