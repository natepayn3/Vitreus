-- The logic of the VPN panel: it lists the profiles NetworkManager holds (WireGuard and the ones a VPN plugin makes, the same ones Settings > VPN lists) and connects or
-- disconnects the one whose card is pressed. NetworkManager owns the profiles; this only drives it through nmcli (`permissions { run: "nmcli" }` in vpn.plm).
-- nmcli's `-t` output escapes ":" and "\"; its error text goes to stderr, which `run` does not give back, so a failure is explained from its exit code.
-- Profiles are named by UUID: two can share a name. The state is kept in locals of this file (a shared global table would be read stale by the handlers).
local MAX = 8
local profs, kinds, ips = {}, {}, {}
local busy, errs = {}, {}
local is_open = false

local NM_CODE = {
    [2] = "NetworkManager did not accept it (for OpenVPN, is networkmanager-openvpn installed?)",
    [3] = "it took too long",
    [4] = "could not start: check the keys, the endpoint and the password",
    [5] = "could not disconnect",
    [8] = "NetworkManager is not running",
    [10] = "no such profile",
}
local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function why(code) return NM_CODE[code] or ("nmcli failed with code " .. tostring(code)) end
local function nm(args, done) run("nmcli", args, done) end

local function terse(line)
    local f, cur, i = {}, {}, 1
    while i <= #line do
        local c = line:sub(i, i)
        if c == "\\" then cur[#cur + 1] = line:sub(i + 1, i + 1); i = i + 2
        elseif c == ":" then f[#f + 1] = table.concat(cur); cur = {}; i = i + 1
        else cur[#cur + 1] = c; i = i + 1 end
    end
    f[#f + 1] = table.concat(cur)
    return f
end

local function render()
    local rows, active = {}, {}
    for i, p in ipairs(profs) do
        if i > MAX then break end
        local sub
        if errs[p.uuid] then sub = errs[p.uuid]
        elseif busy[p.uuid] then sub = p.active and "Disconnecting…" or "Connecting…"
        elseif p.active then sub = ips[p.uuid] and ips[p.uuid] ~= "" and ("Connected · " .. ips[p.uuid]) or "Connected"
        else sub = kinds[p.uuid] or (p.type == "wireguard" and "WireGuard" or "VPN") end
        rows[#rows + 1] = { name = p.name, sub = sub, act = p.active and 1 or 0, busy = busy[p.uuid] and 1 or 0 }
        if p.active then active[#active + 1] = p.name end
    end
    model.profs = rows
    if #profs == 0 then
        text.head = "VPN"
        text.headsub = "No profiles yet"
    elseif #active > 0 then
        text.head = "VPN on"
        text.headsub = table.concat(active, ", ")
    else
        text.head = "VPN off"
        text.headsub = "Not connected"
    end
end

local function learn(p)
    if p.type ~= "wireguard" and kinds[p.uuid] == nil then
        kinds[p.uuid] = "VPN"
        nm({ "-g", "vpn.service-type", "connection", "show", "uuid", p.uuid }, function(out, code)
            local s = trim(out)
            if code == 0 and s ~= "" then
                local last = s:match("([^.]+)$") or s
                kinds[p.uuid] = last == "openvpn" and "OpenVPN" or last
                render()
            end
        end)
    elseif p.type == "wireguard" then
        kinds[p.uuid] = "WireGuard"
    end
    if p.active and ips[p.uuid] == nil then
        ips[p.uuid] = ""
        nm({ "-g", "IP4.ADDRESS", "connection", "show", "uuid", p.uuid }, function(out, code)
            local ip = code == 0 and ((trim(out):match("[^\n]+") or ""):gsub("/%d+$", "")) or ""
            -- (none yet, a VPN still coming up: asked again at the next look, instead of kept as "no address" for as long as it stayed up)
            ips[p.uuid] = ip ~= "" and ip or nil
            render()
        end)
    elseif not p.active then
        ips[p.uuid] = nil
    end
end

local function refresh()
    nm({ "-t", "-f", "NAME,UUID,TYPE,ACTIVE", "connection", "show" }, function(out, code)
        if code ~= 0 then
            profs = {}
            render()
            text.headsub = "NetworkManager did not answer"
            return
        end
        local list = {}
        for line in (out or ""):gmatch("[^\n]+") do
            local f = terse(line)
            if #f >= 4 and (f[3] == "wireguard" or f[3] == "vpn") then
                list[#list + 1] = { name = f[1], uuid = f[2], type = f[3], active = f[4] == "yes" }
            end
        end
        -- by name, so a card does not jump to the top when it is switched on (Settings > VPN puts the connected one first)
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
        profs = list
        for _, p in ipairs(profs) do learn(p) end
        render()
    end)
end

on("vt_toggle", function(k)
    local p = profs[math.floor((tonumber(k) or 0) + 0.5) + 1]
    if not p or busy[p.uuid] then return end
    busy[p.uuid] = true
    errs[p.uuid] = nil
    render()
    nm({ "connection", p.active and "down" or "up", "uuid", p.uuid }, function(_, code)
        busy[p.uuid] = nil
        if code ~= 0 then
            errs[p.uuid] = why(code)
            local uuid = p.uuid
            after(5000, function() errs[uuid] = nil; render() end)
        end
        refresh()
    end)
end)

-- Which copy of this scene is on the panel's monitor: the one whose `screen.K.name` is the name the shell sent (`slot_mon`); none matching: the monitor's size decides.
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
on("fact:slot_open", function(v)       -- (the shell says it again every two seconds while the panel is out: only its coming out counts)
    find_monitor()
    local now = v == true
    if now == is_open then return end
    is_open = now
    if now then refresh() end
end)
-- What is switched elsewhere (Settings, the control center, nmcli) shows here while the panel is out.
every(3000, function() if is_open then refresh() end end)
render()
refresh()
