-- The bar's position (Settings > Bar): along the top (the default), or down the left edge with a frame round the screen. The surface's
-- anchor follows `bar_anchor`, so it moves without being recreated. The panels hang from the top edge in both, their left edge by the
-- strip in the second; `lp_w` is how wide the one last opened is, so that they line up. Kept in bar-position.json.
return function()
    local left = false
    local function show() fact.bar_anchor = left and "left" or "top"; bar_fx.left = left end
    local ok, saved = pcall(sys.ask, "files.read", "bar-position.json", "json")
    if ok and type(saved) == "table" and saved.left == true then left = true end
    show()
    -- What the gaps round the windows were, to give back up on the top: read once, before anything of ours changes them (if it already
    -- says what the left needs, it was us, and the usual 20 does).
    run("hyprctl", { "getoption", "general:gaps_out", "-j" }, function(out, code)
        local g = { 20, 20, 20, 20 }
        if code == 0 and out then
            local css = out:match('"css":%s*"([^"]*)"')
            local n = {}
            for v in (css or ""):gmatch("%d+") do n[#n + 1] = tonumber(v) end
            if #n == 4 and n[4] < 60 then g = n end
        end
        bar_fx.orig = g
        iris_fx.apply_hypr()
    end)
    on("bar_pick_pos", function(i)
        left = math.floor(i + 0.5) == 1
        pcall(sys.call, "files.write", "bar-position.json", { left = left })
        show()
        iris_fx.apply_hypr()
    end)
end
