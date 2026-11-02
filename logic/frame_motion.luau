-- Settings > Bar > "Frame movement": the slow ripple that runs along the frame (`fr_wv`, which wave.wgsl is run for from pages/bar_glass.plm). Kept in frame-motion.json (`on`).
return function()
    local on_ = true
    local ok, saved = pcall(sys.ask, "files.read", "frame-motion.json", "json")
    if ok and type(saved) == "table" and saved.on == false then on_ = false end
    fact.fr_wv = on_ and 1 or 0
    on("fr_wv_toggle", function()
        on_ = not on_
        fact.fr_wv = on_ and 1 or 0
        pcall(sys.call, "files.write", "frame-motion.json", { on = on_ })
    end)
end
