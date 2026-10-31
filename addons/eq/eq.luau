-- The logic of the Equalizer: it keeps the ten gains, the switch and the lit preset in the add-on's data folder, runs vitreus-eq (JSON lines in and out) and sends it the bands.
-- The scene only reports what was touched: `eq_toggle`, `preset(n)`, `bset(band * 1000 + (dB + 12) * 10)` and `boost(dB)`.
local ok_f, folder = pcall(sys.ask, "files.folder")
if not ok_f then folder = "" end

local N = 10
local PRESETS = {
    { name = "Flat",   g = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    { name = "Bass",   g = { 6, 5, 3, 1, 0, 0, 0, 0, 0, 0 } },
    { name = "Vocal",  g = { -2, -1, 0, 1, 3, 4, 3, 1, 0, -1 } },
    { name = "Treble", g = { 0, 0, 0, 0, 0, 0, 1, 3, 5, 6 } },
    { name = "Loud",   g = { 5, 4, 1, 0, -1, -1, 0, 2, 4, 5 } },
}

-- cur: the lit preset (0-based), or -1 when the curve is your own. boost: dB past the output's 100 % (0 to 12), into vitreus-eq's limiter.
local st = { on = false, cur = 0, gains = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, boost = 0 }
do
    local ok, saved = pcall(sys.ask, "files.read", "state.json", "json")
    if ok and type(saved) == "table" then
        st.on = saved.on == true
        st.cur = math.floor(tonumber(saved.cur) or 0)
        st.boost = math.max(0, math.min(12, math.floor(tonumber(saved.boost) or 0)))
        if type(saved.gains) == "table" and #saved.gains == N then
            for i = 1, N do st.gains[i] = math.max(-12, math.min(12, tonumber(saved.gains[i]) or 0)) end
        end
    end
end
local function save() pcall(sys.call, "files.write", "state.json", st) end

-- ── the helper ──
local helper = nil
local stopping = false
local target, err = "", ""
local active = true                          -- the EQ is the default output (false: another output was picked, the EQ is bypassed)
local function send(t)
    if helper then write(helper, json.encode(t) .. "\n") end
end

local function output_name(t)
    if t == "" then return "" end
    if t:find("^bluez") then return "Bluetooth" end
    if t:lower():find("hdmi") then return "HDMI" end
    if t:lower():find("usb") then return "USB" end
    return "speakers"
end
local function show()
    for i = 1, N do fact["g." .. (i - 1)] = st.gains[i] end
    fact.cur = st.cur
    fact.boost = st.boost
    fact.eq_on = st.on and 1 or 0
    local name = PRESETS[st.cur + 1] and PRESETS[st.cur + 1].name or "Custom"
    if err ~= "" and st.on then
        text.status = "Not running · " .. err
    elseif st.on and not active then
        text.status = "Bypassed · press to use the EQ again"
    elseif st.on then
        local o = output_name(target)
        text.status = "On · " .. name .. (o ~= "" and (" · " .. o) or "")
    else
        text.status = "Off"
    end
end

local pending = false
local function apply()                       -- (a drag sends a stream of values: at most one message every 40 ms)
    if pending then return end
    pending = true
    after(40, function()
        pending = false
        send({ cmd = "apply", on = st.on, gains = st.gains, boost = st.boost })
    end)
end

-- The spectrum: ten levels and their peaks, 0 to 1, while the panel is out and something is playing.
local function set_spectrum(b, p)
    for i = 0, N - 1 do
        fact["lv." .. i] = b and tonumber(b[i + 1]) or 0
        fact["pk." .. i] = p and tonumber(p[i + 1]) or 0
    end
end
local function on_line(line)
    local ok, ev = pcall(json.decode, line)
    if not ok or type(ev) ~= "table" then return end
    if ev.ev == "spec" then
        if type(ev.b) == "table" and #ev.b == N then set_spectrum(ev.b, type(ev.p) == "table" and #ev.p == N and ev.p or ev.b) end
        return
    end
    if ev.ev ~= "state" then return end
    target = type(ev.target) == "string" and ev.target or ""
    active = ev.active ~= false
    err = type(ev.error) == "string" and ev.error or ""
    -- the Boost needs two plugin packages (vitreus-eq says which are missing): the panel leaves the row out, and Settings > Add-ons says what to install
    local miss = type(ev.missing) == "table" and ev.missing or {}
    fact.boost_ok = #miss == 0 and 1 or 0
    show()
end

-- Reading the sound costs a little and keeps the output awake, so it only runs while the panel is out (the shell says `slot_open` again every two seconds: only a change counts).
local panel = false
local function tell_spectrum() send({ cmd = "spectrum", on = panel }) end
on("fact:slot_open", function(v)
    local now = v == true
    if now == panel then return end
    panel = now
    tell_spectrum()
    if not now then set_spectrum(nil, nil) end
end)

local function start_helper()
    if helper then return end
    helper = spawn("vitreus-eq", { folder }, on_line, function(_, code)
        helper = nil
        target = ""
        log("eq helper ended", code)
        if not stopping then after(3000, start_helper) end
    end, { stdin = "open", errors = true })
    apply()
    tell_spectrum()
end

-- ── what the scene reports ──
on("eq_toggle", function()
    if st.on and not active and err == "" then       -- another output was picked: the press takes the EQ back instead of switching it off
        send({ cmd = "claim" })
        return
    end
    st.on = not st.on
    save()
    show()
    send({ cmd = "apply", on = st.on, gains = st.gains, boost = st.boost })
end)
on("preset", function(n)
    local p = PRESETS[(tonumber(n) or -1) + 1]
    if not p then return end
    st.cur = math.floor(tonumber(n))
    for i = 1, N do st.gains[i] = p.g[i] end
    save()
    show()
    apply()
end)
on("boost", function(v)
    v = math.max(0, math.min(12, math.floor((tonumber(v) or 0) + 0.5)))
    if v == st.boost then return end
    st.boost = v
    fact.boost = v
    save()
    apply()
end)
on("bset", function(v)
    v = math.floor(tonumber(v) or -1)
    local band, raw = v // 1000, v % 1000
    if band < 0 or band >= N then return end
    local g = math.max(-12, math.min(12, (raw - 120) / 10))
    if math.abs(g) < 0.3 then g = 0 end               -- (0 dB has a small catch)
    st.gains[band + 1] = g
    st.cur = -1
    for k, p in ipairs(PRESETS) do                    -- (a curve that lands on a preset lights it)
        local same = true
        for i = 1, N do if st.gains[i] ~= p.g[i] then same = false break end end
        if same then st.cur = k - 1 end
    end
    fact["g." .. band] = g
    fact.cur = st.cur
    show()
    save()
    apply()
end)

show()
start_helper()

-- The shell sends its palette to an add-on when it starts and when the theme changes, not when the add-on alone is restarted (a crash, `vitreus-keep`): until then the scene has its built-in
-- colours. So the add-on asks for it itself once it is up (the shell answers to every add-on, which costs a few facts).
after(1500, function() run("pleamar", { "--say", "vitreus", "emit pal_push" }, function() end) end)

-- Which copy of this scene is on the panel's monitor: the one whose `screen.K.name` is the name the shell sent (`slot_mon`), as in the template. Without it the
-- size decided, and on monitors of the same size every copy drew the panel: a ghost of it on the other monitors.
local function find_monitor()
    local name = text.slot_mon or ""
    local any = false
    for k = 0, 3 do
        local here = name ~= "" and text["screen." .. k .. ".name"] == name
        if fact["mon_c" .. k] ~= here then fact["mon_c" .. k] = here end
        any = any or here
    end
    if fact.mon_known ~= any then fact.mon_known = any end
end
on("fact:slot_open", function() find_monitor() end)      -- (the shell says it again every two seconds while the panel is out, and `slot_mon` before it)
on("text:slot_mon", function() find_monitor() end)
