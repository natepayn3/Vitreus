-- The Bar page's layout: the order of the bar's pieces and which are hidden, edited by dragging chips on a small copy
-- of the bar (see the Bar page in vitreus.plm). The bar reads `bo.<piece>` (its place) and `bv.<piece>` (shown); the
-- editor reads `bc.<n>` (where each chip is). Kept in bar-layout.json. The settings gear cannot be hidden: it is the way
-- back to this page.
return function()
    local KEYS = { "ws", "title", "media", "set", "sr", "ctl", "clock", "tray" }   -- chip n is KEYS[n + 1]
    local INDEX = {}
    for n, k in ipairs(KEYS) do INDEX[k] = n - 1 end
    local CHIP_W = { ws = 64, title = 110, media = 52, set = 34, sr = 34, ctl = 34, clock = 62, tray = 34 }
    local BAR_W, PAD, GAP = 410, 4, 4          -- the small bar, the room at its ends, and between chips
    local ROW_BAR, ROW_TRAY = 4, 56            -- the chips' top in the bar and in the tray
    local L = { order = {}, hidden = {} }      -- every piece in order, hidden ones too (they keep their place)
    local drag = nil                           -- { key, to_tray, slot }

    local function defaults()
        L.order = { "ws", "title", "media", "tray", "set", "sr", "ctl", "clock" }
        L.hidden = {}
    end

    local function save()
        local hidden = {}
        for _, k in ipairs(L.order) do if L.hidden[k] then hidden[#hidden + 1] = k end end
        pcall(sys.call, "files.write", "bar-layout.json", { order = L.order, hidden = hidden })
    end

    -- What the bar reads.
    local function apply_bar()
        for n, k in ipairs(L.order) do
            fact["bo." .. k] = n - 1
            if k ~= "set" then fact["bv." .. k] = not L.hidden[k] end
        end
    end

    -- Where the chips go: the shown ones along the small bar (the title takes what is left), the hidden ones along the
    -- tray. While a chip is dragged it is left out, and a gap as wide as it opens where it would land.
    local function place()
        local bar, tray = {}, {}
        for _, k in ipairs(L.order) do
            if not (drag and drag.key == k) then
                if L.hidden[k] then tray[#tray + 1] = k else bar[#bar + 1] = k end
            end
        end
        if drag then
            local gap = { gap = true, w = CHIP_W[drag.key] }
            if drag.to_tray then tray[#tray + 1] = gap else table.insert(bar, math.min(drag.slot + 1, #bar + 1), gap) end
        end
        -- the title stretches over what the others leave
        local fixed, n = 0, #bar
        for _, k in ipairs(bar) do
            if k ~= "title" then fixed = fixed + (type(k) == "table" and k.w or CHIP_W[k]) end
        end
        local title_w = math.max(60, BAR_W - 2 * PAD - fixed - GAP * math.max(0, n - 1))
        local x = PAD
        for _, k in ipairs(bar) do
            local w = (type(k) == "table") and k.w or (k == "title" and title_w or CHIP_W[k])
            if type(k) == "string" then
                local c = "bc." .. INDEX[k]
                fact[c .. ".x"], fact[c .. ".y"], fact[c .. ".w"] = x, ROW_BAR, w
            end
            x = x + w + GAP
        end
        x = PAD
        for _, k in ipairs(tray) do
            local w = (type(k) == "table") and k.w or CHIP_W[k]
            if type(k) == "string" then
                local c = "bc." .. INDEX[k]
                fact[c .. ".x"], fact[c .. ".y"], fact[c .. ".w"] = x, ROW_TRAY, w
            end
            x = x + w + GAP
        end
        local hidden_n = 0
        for _, k in ipairs(L.order) do if L.hidden[k] then hidden_n = hidden_n + 1 end end
        fact.btray_n = hidden_n
        fact.bdrop_tray = drag ~= nil and drag.to_tray or false
    end

    -- Where the dragged chip would land, from the pointer: the tray if it is over it (never the gear), else the
    -- place in the bar among the chips whose middles it has passed.
    local function aim()
        if not drag then return end
        local px, py = fact.bdx or 0, fact.bdy or 0
        drag.to_tray = py > (ROW_BAR + 28 + ROW_TRAY) / 2 and drag.key ~= "set"
        if drag.to_tray then return end
        local cx = px - (fact.bgx or 0) + CHIP_W[drag.key] / 2     -- the dragged chip's middle
        local slot = 0
        for _, k in ipairs(L.order) do
            if k ~= drag.key and not L.hidden[k] then
                local c = "bc." .. INDEX[k]
                local mid = (fact[c .. ".x"] or 0) + (fact[c .. ".w"] or 0) / 2
                if cx > mid then slot = slot + 1 end
            end
        end
        drag.slot = slot
    end

    on("bar_lay_grab", function()
        local key = KEYS[math.floor((fact.bdrag or -1) + 0.5) + 1]
        if not key then return end
        drag = { key = key, to_tray = L.hidden[key] or false, slot = 0 }
        -- where it was, so that letting go without moving puts it back
        local slot = 0
        for _, k in ipairs(L.order) do
            if k == key then break end
            if not L.hidden[k] then slot = slot + 1 end
        end
        drag.slot = slot
        place()
    end)
    on("bar_lay_drag", function()
        if not drag then return end
        local before_tray, before_slot = drag.to_tray, drag.slot
        aim()
        if drag.to_tray ~= before_tray or drag.slot ~= before_slot then place() end
        -- the chip itself: its spring follows the pointer, so that letting go it glides from there to its place
        local c = "bc." .. INDEX[drag.key]
        fact[c .. ".x"] = (fact.bdx or 0) - (fact.bgx or 0)
        fact[c .. ".y"] = (fact.bdy or 0) - (fact.bgy or 0)
    end)
    on("bar_lay_drop", function()
        if not drag then return end
        aim()
        local key = drag.key
        if drag.to_tray then
            L.hidden[key] = true
        else
            L.hidden[key] = nil
            -- take it out, and put it back before the slot-th shown piece
            for n, k in ipairs(L.order) do if k == key then table.remove(L.order, n); break end end
            local seen, at = 0, #L.order + 1
            for n, k in ipairs(L.order) do
                if not L.hidden[k] then
                    if seen == drag.slot then at = n; break end
                    seen = seen + 1
                end
            end
            table.insert(L.order, at, key)
        end
        drag = nil
        fact.bdrag = -1
        place()
        apply_bar()
        save()
    end)
    on("bar_lay_reset", function()
        defaults()
        drag = nil
        fact.bdrag = -1
        place()
        apply_bar()
        save()
    end)

    -- What was saved, if it is whole: every piece once, and nothing unknown.
    defaults()
    local ok, saved = pcall(sys.ask, "files.read", "bar-layout.json", "json")
    if ok and type(saved) == "table" and type(saved.order) == "table" then
        local seen, order = {}, {}
        for _, k in ipairs(saved.order) do
            if INDEX[k] ~= nil and not seen[k] then seen[k] = true; order[#order + 1] = k end
        end
        -- a layout saved before the tray piece existed: it goes just before the gear, where it is by default
        if not seen.tray then
            local at = #order + 1
            for n, k in ipairs(order) do if k == "set" then at = n; break end end
            table.insert(order, at, "tray")
            seen.tray = true
        end
        if #order == #KEYS then
            L.order = order
            if type(saved.hidden) == "table" then
                for _, k in ipairs(saved.hidden) do if INDEX[k] ~= nil and k ~= "set" then L.hidden[k] = true end end
            end
        end
    end
    place()
    apply_bar()
end
