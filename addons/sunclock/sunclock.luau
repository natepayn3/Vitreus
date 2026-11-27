-- The Sun Clock's logic: once a minute it works out where the sun is overhead (the night side on the map follows from that, in night.wgsl), the
-- time, and the day's sunrise, sunset and length where the user is. The place is the shell's (the one the forecast is for, Settings > VPN > Weather);
-- until the shell has given one, the add-on guesses it by IP itself (ipwho.is, at most once a day, kept in its data folder).
--
-- The sun's position is the usual low-precision one (the Astronomical Almanac's, good to about a minute of time, more than the map can show).

local RAD = math.pi / 180

local state = { ip = nil, ip_at = 0 }
local ok, saved = pcall(sys.ask, "files.read", "state.json", "json")
if ok and type(saved) == "table" then
    if type(saved.ip) == "table" and tonumber(saved.ip.lat) and tonumber(saved.ip.lon) then state.ip = saved.ip end
    state.ip_at = tonumber(saved.ip_at) or 0
end
local function save() pcall(sys.call, "files.write", "state.json", state) end

local function wrap180(d)
    d = d % 360
    if d > 180 then d = d - 360 end
    return d
end

-- The sun at time t (seconds since 1970, UTC): its declination and the equation of time, in degrees.
local function sun_at(t)
    local n = t / 86400 - 10957.5                          -- days since J2000.0
    local L = (280.460 + 0.9856474 * n) % 360
    local g = ((357.528 + 0.9856003 * n) % 360) * RAD
    local lam = (L + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) * RAD
    local eps = (23.439 - 0.0000004 * n) * RAD
    local dec = math.asin(math.sin(eps) * math.sin(lam)) / RAD
    local ra = math.atan2(math.cos(eps) * math.sin(lam), math.cos(lam)) / RAD
    return dec, wrap180(L - ra)
end

local function utc_hours(t)
    local u = os.date("!*t", t)
    return u.hour + u.min / 60 + u.sec / 3600
end

local function clock(t)
    if fact.clock_12h == false then return os.date("%H:%M", t) end
    local s = os.date("%I:%M %p", t)
    return (s:gsub("^0", ""))
end

local function span(sec)
    local m = math.floor(sec / 60 + 0.5)
    local h = math.floor(m / 60)
    m = m % 60
    if h == 0 then return m .. " min" end
    if m == 0 then return h .. " h" end
    return h .. " h " .. m .. " min"
end

-- Sunrise and sunset (seconds) of the local day that holds t, at lat, lon; or nil and why (the sun never sets, or never rises).
local function rise_set(t, lat, lon)
    local l = os.date("*t", t)
    local noon_local = os.time({ year = l.year, month = l.month, day = l.day, hour = 12, min = 0, sec = 0 })
    local dec, eot = sun_at(noon_local)
    -- the sun crosses the meridian when the local apparent time is noon: 12 - lon/15 - eot/15 hours UTC, on the day nearest to local noon
    local want = 12 - lon / 15 - eot / 15
    local diff = (want - utc_hours(noon_local)) % 24
    if diff > 12 then diff = diff - 24 end
    local noon = noon_local + diff * 3600
    local c = (math.sin(-0.833 * RAD) - math.sin(lat * RAD) * math.sin(dec * RAD)) / (math.cos(lat * RAD) * math.cos(dec * RAD))
    if c > 1 then return nil, nil, "night" end
    if c < -1 then return nil, nil, "day" end
    local h = math.acos(c) / RAD / 15 * 3600            -- half the day, in seconds
    return noon - h, noon + h, nil
end

local function place()
    if fact.wx_loc_ok == true then return tonumber(fact.wx_lat), tonumber(fact.wx_lon), nil end
    if state.ip then return tonumber(state.ip.lat), tonumber(state.ip.lon), state.ip.city end
    return nil
end

local function update_line()
    local a, b = text.t_place or "", text.t_status or ""
    text.t_line = (a ~= "" and b ~= "") and (a .. "  ·  " .. b) or (a .. b)
end

local function update()
    local t = os.time()
    local dec, eot = sun_at(t)
    fact.sun_lat = dec
    fact.sun_lon = wrap180(15 * (12 - utc_hours(t)) - eot)
    text.t_now = clock(t)

    local lat, lon, city = place()
    if not lat or not lon then
        fact.me_ok = false
        text.t_place = "Finding where you are…"
        text.t_status = ""
        text.t_rise, text.t_set, text.t_len = "–", "–", "–"
        update_line()
        return
    end
    fact.me_lat, fact.me_lon, fact.me_ok = lat, lon, true
    local name = (text.wx_name or ""):gsub("^Automatic · ", "")      -- the shell's name for the place ("Automatic · <city>" when found by IP)
    if fact.wx_loc_ok ~= true or name == "" then name = city or "Here" end
    text.t_place = name

    local rise, set, polar = rise_set(t, lat, lon)
    if polar == "day" then
        text.t_rise, text.t_set, text.t_len = "–", "–", "24 h"
        text.t_status = "The sun does not set today"
        fact.is_day = true
    elseif polar == "night" then
        text.t_rise, text.t_set, text.t_len = "–", "–", "0 h"
        text.t_status = "The sun does not rise today"
        fact.is_day = false
    else
        text.t_rise, text.t_set, text.t_len = clock(rise), clock(set), span(set - rise)
        if t < rise then
            text.t_status = "Sunrise in " .. span(rise - t)
            fact.is_day = false
        elseif t < set then
            text.t_status = "Sunset in " .. span(set - t)
            fact.is_day = true
        else
            local r2 = rise_set(t + 86400, lat, lon)
            text.t_status = r2 and ("Sunrise in " .. span(r2 - t)) or "Night"
            fact.is_day = false
        end
    end
    update_line()
end

-- The place by IP, only when the shell has none to give (the weather never ran, or found nothing). Once a day at most.
local function guess_place()
    if fact.wx_loc_ok == true then return end
    if state.ip and os.time() - state.ip_at < 86400 then return end
    local okf, folder = pcall(sys.ask, "files.folder")
    if not okf or type(folder) ~= "string" then return end
    run("curl", { "-s", "-L", "--max-time", "10", "-o", folder .. "/ip.json", "https://ipwho.is/" }, function(_, code)
        if code ~= 0 then return end
        local okr, r = pcall(sys.ask, "files.read", "ip.json", "json")
        if okr and type(r) == "table" and r.success and tonumber(r.latitude) and tonumber(r.longitude) then
            state.ip = { lat = tonumber(r.latitude), lon = tonumber(r.longitude), city = tostring(r.city or "Here") }
            state.ip_at = os.time()
            save()
            update()
        end
    end)
end

on("fact:clock_12h", function() update() end)
on("fact:wx_loc_ok", function() update() end)
on("fact:wx_lat", function() update() end)
on("fact:wx_lon", function() update() end)
on("text:wx_name", function() update() end)

-- The template's monitor matching (addons/_template_drawer/addon.luau): which copy of the scene is on the panel's monitor.
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
on("fact:slot_open", function(v)
    find_monitor()
    if v == true then update() end
end)

update()
-- on the minute, so the clock turns over with the bar's
after((60 - os.date("*t").sec) * 1000 + 50, function()
    update()
    every(60000, update)
end)
-- the shell tells a new add-on its place within a few seconds of starting it; guess only if it has not
after(15000, guess_place)
every(3600000, guess_place)
