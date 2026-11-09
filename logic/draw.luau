-- Draw: the drawing board in the desk's Pad tab. The scene reports where the pointer is as one number (x * 1000 + y, in half units from
-- the board's corner); this keeps the strokes as short line segments (up to 768, spread over three lists of 256, the most a model holds),
-- gives them back to be drawn, and saves them in desk-draw.json when the pen is lifted. A point is only kept when it is some distance from
-- the last, so a long line is not made of thousands of tiny pieces. Every segment says which stroke it belongs to (`k`), so Undo takes
-- away the last stroke that is still there. With the eraser as the tool, the same points take out whatever segments they pass near.
return function()
    local LIMIT, W, H, STEP = 768, 624, 472, 3
    local REACH = { [0] = 14, 24, 40, 56, 72 }                    -- the eraser's reach in half units, by size
    local segs = {}                                       -- { x0, y0, x1, y1, c, w, k }
    local stroke, last, dirty = 0, nil, false
    local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
    local function point(v)
        v = math.floor((tonumber(v) or 0) + 0.5)
        return clamp(math.floor(v / 1000), 0, W), clamp(v % 1000, 0, H)
    end
    local function save() pcall(sys.call, "files.write", "desk-draw.json", { segs = segs }) end
    local function flush()
        if not dirty then return end
        dirty = false
        for part = 0, 2 do
            local list = {}
            for i = 1, 256 do
                local s = segs[part * 256 + i]
                if not s then break end
                list[i] = { x0 = s.x0, y0 = s.y0, x1 = s.x1, y1 = s.y1, c = s.c, w = s.w }
            end
            model["dr_segs" .. part] = list
        end
    end
    -- Something changed: the lists are given to the scene 40 ms later, once for everything that changes meanwhile (a stroke reports many points
    -- a second). A timer of its own each time, not one that turns for ever: forty wake-ups a second all day, for a board that is rarely open.
    local pending = false
    local function mark()
        dirty = true
        if pending then return end
        pending = true
        after(40, function() pending = false; flush() end)
    end
    local function add(x0, y0, x1, y1)
        if #segs >= LIMIT then return end
        segs[#segs + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, c = tonumber(fact.dr_col) or 0, w = tonumber(fact.dr_thick) or 0, k = stroke }
        mark()
    end
    local function near(s, x, y, r)                       -- is the point within `r` of the segment?
        local dx, dy = s.x1 - s.x0, s.y1 - s.y0
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and clamp(((x - s.x0) * dx + (y - s.y0) * dy) / len2, 0, 1) or 0
        local px, py = s.x0 + t * dx, s.y0 + t * dy
        return (x - px) * (x - px) + (y - py) * (y - py) <= r * r
    end
    local function erase(x, y)
        local r = REACH[tonumber(fact.dr_thick) or 0] or REACH[0]
        local kept = {}
        for _, s in ipairs(segs) do
            if not near(s, x, y, r) then kept[#kept + 1] = s end
        end
        if #kept ~= #segs then segs = kept; mark() end
    end
    local function erase_line(x0, y0, x1, y1)             -- along the way, so a quick sweep does not skip anything
        local r = REACH[tonumber(fact.dr_thick) or 0] or REACH[0]
        local dist = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        local steps = math.max(1, math.ceil(dist / (r / 2)))
        for i = 1, steps do erase(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps) end
    end
    local function erasing() return tonumber(fact.dr_tool) == 1 end
    do
        local ok, saved = pcall(sys.ask, "files.read", "desk-draw.json", "json")
        if ok and type(saved) == "table" and type(saved.segs) == "table" then
            for _, s in ipairs(saved.segs) do
                if type(s) == "table" and #segs < LIMIT then
                    local k = tonumber(s.k) or 0
                    segs[#segs + 1] = { x0 = s.x0 or 0, y0 = s.y0 or 0, x1 = s.x1 or 0, y1 = s.y1 or 0, c = s.c or 0, w = s.w or 0, k = k }
                    if k > stroke then stroke = k end
                end
            end
            mark()
        end
    end
    on("dr_down", function(v)
        local x, y = point(v)
        last = { x, y }
        if erasing() then
            erase(x, y)
        else
            stroke = stroke + 1
            add(x, y, x + 0.2, y)                          -- a tap leaves a dot
        end
    end)
    on("dr_pt", function(v)
        if not last then return end
        local x, y = point(v)
        if erasing() then
            erase_line(last[1], last[2], x, y)
            last = { x, y }
        elseif math.abs(x - last[1]) + math.abs(y - last[2]) >= STEP then
            add(last[1], last[2], x, y)
            last = { x, y }
        end
    end)
    on("dr_up", function()
        last = nil
        save()
    end)
    on("dr_undo", function()
        local top = 0
        for _, s in ipairs(segs) do if s.k > top then top = s.k end end
        if top == 0 and #segs == 0 then return end
        local kept = {}
        for _, s in ipairs(segs) do
            if s.k ~= top then kept[#kept + 1] = s end
        end
        segs = kept
        mark()
        save()
    end)
    on("dr_clear", function()
        segs, last = {}, nil
        mark()
        save()
    end)
    -- ── keeping it ──
    -- The drawing as a picture (magick draws the segments on paper, twice the board's half units), then to the Shelf (0) or into the slideshow's
    -- folder, Pictures/myPad (1), where Home's photo frame and the Camera's photos live.
    local INK = { [0] = "#23272e", "#ff5a5f", "#ff9f43", "#ffd93d", "#4cd97b", "#4da3ff", "#a66bff", "#ff6bcb" }
    local function say(m)
        text.dr_msg = m
        after(2500, function() if text.dr_msg == m then text.dr_msg = "" end end)
    end
    local saving = false
    on("dr_save", function(where)
        if saving then return end
        if #segs == 0 then say("Nothing drawn yet"); return end
        saving = true
        run("xdg-user-dir", { "PICTURES" }, function(out)
            local pics = ((out or ""):gsub("%s+$", ""))
            if pics == "" then saving = false; say("The picture could not be saved"); return end
            local dir = pics .. "/myPad"
            local file = dir .. "/drawing-" .. os.date("%Y%m%d-%H%M%S") .. ".png"
            local args = { "-size", (W * 2) .. "x" .. (H * 2), "xc:#fbf9f3", "-fill", "none", "-stroke", INK[0], "-linecap", "round" }
            local cur_c, cur_w
            for _, s in ipairs(segs) do
                if s.c ~= cur_c then cur_c = s.c; args[#args + 1] = "-stroke"; args[#args + 1] = INK[s.c] or INK[0] end
                if s.w ~= cur_w then cur_w = s.w; args[#args + 1] = "-strokewidth"; args[#args + 1] = tostring((1.8 + 2.6 * s.w) * 4) end
                args[#args + 1] = "-draw"
                args[#args + 1] = string.format("line %d,%d %d,%d", s.x0 * 2, s.y0 * 2, s.x1 * 2, s.y1 * 2)
            end
            args[#args + 1] = file
            run("mkdir", { "-p", dir }, function()
                run("magick", args, function(_, c)
                    saving = false
                    if c ~= 0 then say("The picture could not be saved"); return end
                    if tonumber(where) == 0 then
                        if desk_shelf_add then desk_shelf_add(file) end
                        say("Drawing put on the Shelf")
                    else
                        say("Saved to Pictures/myPad, for the slideshow")
                    end
                end)
            end)
        end)
    end)
    flush()
end
