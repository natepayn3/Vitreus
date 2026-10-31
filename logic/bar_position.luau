-- The bar's position (Settings > Bar): along the top (the default, the Island), or a strip on any of the four edges with a frame round
-- the rest of the screen. The surface's anchor follows `bar_anchor`, so it moves without being recreated. The panels hang from the top edge
-- in the first, their edge by the strip in the others; `lp_w` is how wide the one last opened is, so that they line up. Kept in bar-position.json
-- (`pos`: "top", "left", "right", "ftop", "fbottom" or "seg", the top frame in three pieces; an older file only has `left`).
return function()
    -- pos: "top" is the Island; "left", "right", "ftop" and "fbottom" are the strip on that edge with a frame round the rest; "seg" is the top one in three pieces of glass.
    local POS = { [0] = "top", "left", "right", "ftop", "fbottom", "seg" }
    local EDGE = { top = { "top", false }, left = { "left", true }, right = { "right", true }, ftop = { "top", true }, fbottom = { "bottom", true }, seg = { "top", true } }
    local pos = "top"
    local function show()
        local e = EDGE[pos] or EDGE.top
        fact.bar_anchor = e[1]
        fact.bar_frame = e[2]
        fact.bar_seg = pos == "seg"
        bar_fx.left = e[2]
        bar_fx.edge = e[1]
        bar_fx.seg = pos == "seg"
        -- the desktop scenes keep their widgets' grid out of the bar's room (`room_*`): told again whenever the bar moves. (A fact the logic sets itself
        -- does not fire `on("fact:bar_anchor")`, so it has to be said from here.)
        if iris_fx and iris_fx.push_room then iris_fx.push_room() end
    end
    local ok, saved = pcall(sys.ask, "files.read", "bar-position.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.pos) == "string" and EDGE[saved.pos] then pos = saved.pos
        elseif saved.left == true then pos = "left" end
    end
    show()
    run("pgrep", { "-x", "pleamar-wm" }, function(_, code) fact.wm_session = (code == 0) end)
    -- What the gaps round the windows were, to give back up on the top: read once, before anything of ours changes them (if it already
    -- says what a strip needs, it was us, and the usual 20 does).
    run("hyprctl", { "getoption", "general:gaps_out", "-j" }, function(out, code)
        local g = { 20, 20, 20, 20 }
        if code == 0 and out then
            local css = out:match('"css":%s*"([^"]*)"')
            local n = {}
            for v in (css or ""):gmatch("%d+") do n[#n + 1] = tonumber(v) end
            -- Not ours: what the strips write is a wide gap on the strip's edge (60 or more on the left; the top and bottom ones a little less) and the frame's
            -- 24 (`px`, in `iris_fx.gaps_code`) on the others. Taken for the original, they stayed in the Island as a big margin on top and 24 all round.
            local mixed = false
            for _, v in ipairs(n) do if v == 24 then mixed = true end end
            local same = n[1] == n[2] and n[2] == n[3] and n[3] == n[4]
            if #n == 4 and n[4] < 60 and not (mixed and not same) then g = n end
        end
        bar_fx.orig = g
        iris_fx.apply_hypr()
    end)
    on("bar_pick_pos", function(i)
        pos = POS[math.floor(i + 0.5)] or "top"
        pcall(sys.call, "files.write", "bar-position.json", { pos = pos, left = pos == "left" })
        show()
        iris_fx.apply_hypr()
        -- pleamar-wm keeps its windows out of the frame by `fr.*`, which is otherwise only looked at every 5 s: tell it now.
        if wm_frame_sync then wm_frame_sync() end
    end)
end
