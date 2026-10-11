-- The desktop stickers' logic: up to sixteen sticky notes, each in a slot (0 to 15) of the scene (`o<k>` there is one, `h<k>` it has writing, `gx<k>`, `gy<k>` its top left in the
-- desktop, `c<k>` its paper, `t<k>` its words). What is kept, in this scene's own folder (~/.local/share/pleamar/desktopnotes):
--   desktopnotes.json            shown     whether the stickers are on the desktop
--                                clarity   (unused now: they are paper; kept so that an old file reads)
--   desktopnotes-stickers.json   the stickers: { slot, t, x, y, c } each; x and y are the desktop's own coordinates (all the monitors together)
-- A file that is not there is written so that there is one to edit. They are read when the scene starts.
local MAX = 16
local W, H = 200, 168
local cfg = { shown = false, clarity = 1 }
do
    local ok, saved = pcall(sys.ask, "files.read", "desktopnotes.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopnotes.json", cfg)
    end
end
local function save_cfg() pcall(sys.call, "files.write", "desktopnotes.json", cfg) end
cfg.shown = true      -- the stickers are on the desktop for as long as there are any (each is closed on its own); there is no switch for all of them
fact.shown = true
fact.cli = cfg.clarity

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ── where the monitors lie ──
-- `hyprctl monitors -j`: each one's top left and size in the layout (logical pixels: the size over its scale, turned about when it is rotated a quarter), in the order Hyprland
-- numbers them, which is the order the scene's copies are in (`screen.index`).
local mons = { { x = 0, y = 0, w = 1920, h = 1080 } }
local function refresh_monitors(done)
    run("hyprctl", { "monitors", "-j" }, function(out, code)
        if code == 0 and out then
            local ok, list = pcall(json.decode, out)
            if ok and type(list) == "table" and #list > 0 then
                table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
                local m = {}
                for i, d in ipairs(list) do
                    if i > 4 then break end
                    local sc = tonumber(d.scale) or 1
                    local w, h = (tonumber(d.width) or 1920) / sc, (tonumber(d.height) or 1080) / sc
                    if (tonumber(d.transform) or 0) % 2 == 1 then w, h = h, w end
                    m[i] = { x = tonumber(d.x) or 0, y = tonumber(d.y) or 0, w = math.floor(w + 0.5), h = math.floor(h + 0.5) }
                end
                mons = m
            end
        end
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, 4 do
            local d = mons[i]
            fact["m" .. (i - 1) .. "x"] = d and d.x or 0
            fact["m" .. (i - 1) .. "y"] = d and d.y or 0
            if d then x0, y0, x1, y1 = math.min(x0, d.x), math.min(y0, d.y), math.max(x1, d.x + d.w), math.max(y1, d.y + d.h) end
        end
        fact.mcount = #mons
        fact.vx0, fact.vy0, fact.vx1, fact.vy1 = x0, y0, x1, y1
        if done then done() end
    end)
end
refresh_monitors()
every(5000, function() refresh_monitors() end)

-- ── the stickers ──
local slots = {}      -- slot (0..15) -> { t = words, x = left, y = top, c = paper }
local function slot_list()
    local list = {}
    for k = 0, MAX - 1 do
        local s = slots[k]
        if s then list[#list + 1] = { slot = k, t = s.t, x = s.x, y = s.y, c = s.c } end
    end
    return list
end
local function save_stickers() pcall(sys.call, "files.write", "desktopnotes-stickers.json", { items = slot_list() }) end
local function publish(k)
    local s = slots[k]
    fact["o" .. k] = s ~= nil
    fact["h" .. k] = s ~= nil and s.t ~= ""
    fact["gx" .. k] = s and s.x or 0
    fact["gy" .. k] = s and s.y or 0
    fact["c" .. k] = s and s.c or 0
    text["t" .. k] = s and s.t or ""
end
do
    local ok, saved = pcall(sys.ask, "files.read", "desktopnotes-stickers.json", "json")
    if ok and type(saved) == "table" and type(saved.items) == "table" then
        for _, it in ipairs(saved.items) do
            local k = math.floor(tonumber(it.slot) or -1)
            if k >= 0 and k < MAX and type(it.t) == "string" then
                slots[k] = { t = it.t, x = tonumber(it.x) or 80, y = tonumber(it.y) or 80, c = math.floor(tonumber(it.c) or 0) % 6 }
            end
        end
    else
        -- the earlier notes (a list of lines) become one sticker each, in a row from the corner
        local ok2, old = pcall(sys.ask, "files.read", "desktopnotes-items.json", "json")
        if ok2 and type(old) == "table" and type(old.items) == "table" then
            local k = 0
            for _, it in ipairs(old.items) do
                if type(it) == "table" and type(it.t) == "string" and k < MAX then
                    slots[k] = { t = it.t, x = 60 + k * 36, y = 120 + k * 28, c = k % 6 }
                    k = k + 1
                end
            end
        end
        save_stickers()
    end
end
for k = 0, MAX - 1 do publish(k) end

local made = 0
on("note_new", function()
    local free
    for k = 0, MAX - 1 do if not slots[k] then free = k break end end
    if not free then return end
    refresh_monitors(function()
        local mi = math.max(1, math.min(#mons, math.floor((tonumber(fact.nmon) or 0) + 0.5) + 1))
        local m = mons[mi]
        local px, py = tonumber(fact.nx) or -1, tonumber(fact.ny) or -1
        local x, y
        if px >= 0 and py >= 0 then x, y = m.x + px - W / 2, m.y + py - 26
        else x, y = m.x + (m.w - W) / 2 + (made % 6) * 26, m.y + (m.h - H) / 2 + (made % 6) * 26 end
        x = math.max(m.x, math.min(m.x + m.w - W, x))
        y = math.max(m.y, math.min(m.y + m.h - H, y))
        made = made + 1
        slots[free] = { t = "", x = math.floor(x + 0.5), y = math.floor(y + 0.5), c = (made - 1) % 6 }
        publish(free)
        save_stickers()
        if not cfg.shown then cfg.shown = true; fact.shown = true; save_cfg() end
        fact.nx, fact.ny = -1, -1
        text.ei = ""
        -- (it is written on once it is clicked: the scene must not grab the keyboard on its own)
    end)
end)
on("note_del", function(i)
    local k = math.floor((tonumber(i) or -1) + 0.5)
    if not slots[k] then return end
    slots[k] = nil
    publish(k)
    save_stickers()
    if math.floor((tonumber(fact.eix) or -1) + 0.5) == k then fact.eix = -1 end
end)
on("note_commit", function()
    local k = math.floor((tonumber(fact.eix) or -1) + 0.5)
    if slots[k] then
        slots[k].t = trim(text.ei)
        publish(k)
        save_stickers()
    end
    fact.eix = -1
    text.ei = ""
end)
-- A click on a sticker (the scene sets `eix`): the field starts with what it says.
on("fact:eix", function(v)
    local k = math.floor((tonumber(v) or -1) + 0.5)
    if k >= 0 and slots[k] then text.ei = slots[k].t end
end)

-- Dragging a sticker sets its `gx`, `gy` over and over: the place is kept once it has stopped for a moment.
local drag_token = 0
local function moved(k)
    drag_token = drag_token + 1
    local t = drag_token
    after(500, function()
        if t ~= drag_token then return end
        local s = slots[k]
        local x, y = tonumber(fact["gx" .. k]), tonumber(fact["gy" .. k])
        if s and x and y then s.x, s.y = math.floor(x + 0.5), math.floor(y + 0.5); save_stickers() end
    end)
end
for k = 0, MAX - 1 do
    on("fact:gx" .. k, function() moved(k) end)
    on("fact:gy" .. k, function() moved(k) end)
end

-- What the launcher or `pleamar --say` tells it (it does not fire for what is set from here).
on("fact:shown", function(v) cfg.shown = v and true or false; save_cfg() end)
on("fact:cli", function(v) if type(v) == "number" then cfg.clarity = math.max(0, math.min(2, math.floor(v + 0.5))); save_cfg() end end)

-- Whether Vitreus has its glass off: asked of it when this starts (it says so itself when it changes), and again a few seconds in.
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
ask_obs()
after(4000, ask_obs)
