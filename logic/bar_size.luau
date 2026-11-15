-- The bar's size (Settings > Bar > Size): a slider from 70 to 125 % of its size on every layout (`bz` in vitreus.plm: the bar's own unit is `u * bz`).
-- Kept in bar-size.json (`size`, 0.7 to 1.25). The room the strip takes round the windows follows it (`bar_fx.size`, see iris_fx.gaps_code and wm_frame_sync):
-- sent when the slider rests, not at every step of it.
return function()
    local MIN, MAX = 0.7, 1.25
    local function clamp(v) return math.max(MIN, math.min(MAX, v)) end
    local function show(size)
        fact.bar_size = size
        text.bar_size_text = string.format("%d%%", math.floor(size * 100 + 0.5))
        bar_fx.size = size
    end
    local size = 1
    local ok, saved = pcall(sys.ask, "files.read", "bar-size.json", "json")
    if ok and type(saved) == "table" and type(saved.size) == "number" then size = clamp(saved.size) end
    show(size)
    local pending = 0
    on("bar_pick_size", function(t)
        size = math.floor(clamp(MIN + (MAX - MIN) * math.max(0, math.min(1, t))) * 100 + 0.5) / 100
        show(size)
        pending = pending + 1
        local mine = pending
        after(400, function()
            if mine ~= pending then return end
            pcall(sys.call, "files.write", "bar-size.json", { size = size })
            iris_fx.apply_hypr()
            if wm_frame_sync then wm_frame_sync() end
        end)
    end)
end
