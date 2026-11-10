-- The Island moving to the music (Settings > Bar > "Island moves to the music"): whether the bar swells and sends a wave along itself on the bass.
-- Kept in bar-beat.json (`on`). Only the Island does it, so the switch means nothing on the other layouts (the page dims it). With it off cava does not run
-- for the bar (`cava_want`), unless the visualiser or the player's equalizer needs it.
return function()
    local on_ = true
    local ok, saved = pcall(sys.ask, "files.read", "bar-beat.json", "json")
    if ok and type(saved) == "table" and type(saved.on) == "boolean" then on_ = saved.on end
    fact.bar_beat = on_
    if cava_want then cava_want() end
    on("bar_beat_toggle", function()
        on_ = not on_
        fact.bar_beat = on_
        pcall(sys.call, "files.write", "bar-beat.json", { on = on_ })
        if cava_want then cava_want() end
    end)
end
