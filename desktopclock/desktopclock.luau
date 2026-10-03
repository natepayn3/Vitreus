-- The desktop clock's logic. It reports the digits (the scene draws them) and keeps the settings, which Vitreus's Settings > Clock page changes
-- from outside (`pleamar --say desktopclock "fact lay 1"`).
--
-- `desktopclock.json`, in this scene's own folder (~/.local/share/pleamar/desktopclock): what is missing from it is the default below, and a
-- file that is not there is written so that there is one to edit. It is read when the scene starts.
--   shown        whether the clock is on the desktop
--   use_12_hour  12 or 24 hour clock
--   size         the digits' height in pixels (100 to 340)
--   layout       0 pipe (12 | 34), 1 rule (a line between the hour and the minutes), 2 tower (a column), 3 capsule (12:34 in an outline), 4 slash, 5 hero
--   position     "top_left", "top", "top_right", "left", "center", "right", "bottom_left", "bottom" or "bottom_right"
--   weight       the strokes: 0 thin, 1 regular, 2 bold
--   clarity      the glass: 0 clear, 1 soft, 2 full
local POSITIONS = { top_left = true, top = true, top_right = true, left = true, center = true, right = true, bottom_left = true, bottom = true, bottom_right = true }
local cfg = { shown = true, use_12_hour = true, size = 220, layout = 0, position = "center", weight = 1, clarity = 1 }
local function clampi(v, lo, hi) return math.max(lo, math.min(hi, math.floor(v + 0.5))) end
do
    local ok, saved = pcall(sys.ask, "files.read", "desktopclock.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
        cfg.size = math.max(100, math.min(340, cfg.size))
        cfg.layout = clampi(cfg.layout, 0, 5)
        cfg.weight = clampi(cfg.weight, 0, 2)
        cfg.clarity = clampi(cfg.clarity, 0, 2)
        if not POSITIONS[cfg.position] then cfg.position = "center" end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "desktopclock.json", cfg)
    end
end
local function save() pcall(sys.call, "files.write", "desktopclock.json", cfg) end

fact.px = cfg.size
fact.h12 = cfg.use_12_hour
fact.lay = cfg.layout
fact.where = cfg.position
fact.wti = cfg.weight
fact.cli = cfg.clarity
fact.shown = cfg.shown

local last = nil
local function show_time(c)
    last = c
    local h = c.hour
    if cfg.use_12_hour then
        h = h % 12
        if h == 0 then h = 12 end
    end
    fact.d0 = (h >= 10) and (h // 10) or (cfg.use_12_hour and -1 or 0)
    fact.d1 = h % 10
    fact.d2 = c.minute // 10
    fact.d3 = c.minute % 10
end
sys.watch("clock", show_time)

-- What the Settings page tells it (it does not fire for what is set from here).
on("fact:shown", function(v) cfg.shown = v and true or false; save() end)
on("fact:px", function(v) if type(v) == "number" then cfg.size = math.max(100, math.min(340, v)); save() end end)
on("fact:lay", function(v) if type(v) == "number" then cfg.layout = clampi(v, 0, 5); save() end end)
on("fact:where", function(v) if POSITIONS[v] then cfg.position = v; save() end end)
on("fact:wti", function(v) if type(v) == "number" then cfg.weight = clampi(v, 0, 2); save() end end)
on("fact:cli", function(v) if type(v) == "number" then cfg.clarity = clampi(v, 0, 2); save() end end)
on("fact:h12", function(v)
    cfg.use_12_hour = v and true or false
    save()
    if last then show_time(last) end
end)
