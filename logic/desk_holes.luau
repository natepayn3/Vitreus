-- The window manager's click zone over the bare desktop (the right press that opens the desktop menu) must not cover the desktop widgets: a zone of the
-- window manager's own scene over a bottom-layer widget takes every click meant for it. So the zone is not one rectangle but a set of them round the
-- widgets: each widget scene says where it is (`text hole_cal` ... "monitor|x,y,w,h", empty when it is off the desktop), the desktop of each monitor is
-- cut into rectangles that leave those places out, and the window manager's scene is given them (`dz.K.x` ... in wm/session.plm, made by
-- pleamar-wm/build-session.py). Said again every 20 s: its facts start from nothing when its scene is read in again.
return function()
    local IDS = { "cal", "rem", "sys", "clk" }
    local BIG = 4096
    local SLOTS = 32
    local PAD = 4                      -- a little room round each widget (its shadow)
    local holes = {}                   -- id -> { mon = name, x, y, w, h }
    local last = ""

    local function tiles_for(list)
        -- the rectangles of [0, BIG) x [0, BIG) that are not under any hole: by horizontal bands between the holes' tops and bottoms
        local ys = { [0] = true, [BIG] = true }
        for _, h in ipairs(list) do ys[math.max(0, h.y - PAD)] = true; ys[math.min(BIG, h.y + h.h + PAD)] = true end
        local sorted = {}
        for y in pairs(ys) do sorted[#sorted + 1] = y end
        table.sort(sorted)
        local out = {}
        for i = 1, #sorted - 1 do
            local y0, y1 = sorted[i], sorted[i + 1]
            if y1 > y0 then
                local row = {}
                for _, h in ipairs(list) do
                    if h.y - PAD < y1 and h.y + h.h + PAD > y0 then row[#row + 1] = { x0 = math.max(0, h.x - PAD), x1 = math.min(BIG, h.x + h.w + PAD) } end
                end
                table.sort(row, function(a, b) return a.x0 < b.x0 end)
                local cur = 0
                for _, r in ipairs(row) do
                    if r.x0 > cur then out[#out + 1] = { x = cur, y = y0, w = r.x0 - cur, h = y1 - y0 } end
                    cur = math.max(cur, r.x1)
                end
                if cur < BIG then out[#out + 1] = { x = cur, y = y0, w = BIG - cur, h = y1 - y0 } end
            end
        end
        return out
    end

    local function push(force)
        hypr_monitors(30, function(mons)
            if not mons then return end
            local per = {}
            local ids = {}
            for name, id in mons:gmatch("Monitor (%S+) %(ID (%d+)%)") do
                per[name] = { id = tonumber(id), list = {} }
                ids[#ids + 1] = name
            end
            if #ids == 0 then return end
            for _, h in pairs(holes) do
                if per[h.mon] then table.insert(per[h.mon].list, h) end
            end
            table.sort(ids, function(a, b) return per[a].id < per[b].id end)
            local slot = {}
            for _, name in ipairs(ids) do
                for _, t in ipairs(tiles_for(per[name].list)) do
                    if #slot < SLOTS then slot[#slot + 1] = { m = per[name].id, x = t.x, y = t.y, w = t.w, h = t.h } end
                end
            end
            local cmds = {}
            for k = 0, SLOTS - 1 do
                local s = slot[k + 1] or { m = -9, x = 0, y = 0, w = 0, h = 0 }
                cmds[#cmds + 1] = string.format("fact dz.%d.m %d", k, s.m)
                cmds[#cmds + 1] = string.format("fact dz.%d.x %d", k, s.x)
                cmds[#cmds + 1] = string.format("fact dz.%d.y %d", k, s.y)
                cmds[#cmds + 1] = string.format("fact dz.%d.w %d", k, s.w)
                cmds[#cmds + 1] = string.format("fact dz.%d.h %d", k, s.h)
            end
            local sig = table.concat(cmds, "\n")
            if sig == last and not force then return end
            last = sig
            run("pleamar", { "--say", "wm", table.unpack(cmds) }, function() end)
        end)
    end

    for _, id in ipairs(IDS) do
        on("text:hole_" .. id, function(t)
            local mon, x, y, w, h = (t or ""):match("^(.-)|(%-?%d+),(%-?%d+),(%d+),(%d+)$")
            if mon then holes[id] = { mon = mon, x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) } else holes[id] = nil end
            push(false)
        end)
    end
    after(3000, function() push(true) end)
    every(20000, function() push(true) end)
end
