-- Settings > Network, the two cards over the VPN's (pages/vpn.plm; the page is still `pg_vpn`): the connection in use, what is going through it, and
-- its address. The connection is the cable's when one is carrying something, Wi-Fi's otherwise; a VPN is the cards below, not this.
--
-- Everything is asked of NetworkManager through nmcli, and only while the page shows: when it opens, when the network service says something changed,
-- and after Apply. The traffic is bin/vitreus-nettraf (a line four times a second from the adapter's own counters), started with the page and stopped
-- when it is left, so nothing runs while nobody looks. nmcli's error text goes to stderr, which `run` does not give back: a failure is explained from
-- its exit code. A change NetworkManager wants a password for is asked by the shell's own password dialog.
return function()
    local COLS = 40
    local S = {
        dev = nil,          -- the adapter in use, its connection (by UUID: two can share a name) and that one's name
        uuid = nil,
        name = "",
        filled = nil,       -- the connection the fields were last filled from (they are left alone while it is the same: someone may be writing)
        was = nil,          -- what that connection had then: { manual, addr, gw, dns }
        proc = nil,         -- the traffic's program, and the adapter it reads
        pdev = nil,
        samples = {},
        reading = false,
        again = false,
    }

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
    local function each_line(out, f) for l in (out or ""):gmatch("[^\n]+") do f(l) end end
    -- `KEY:value` lines (nmcli -t on one thing): the key, and the value with its escapes taken out
    local function pairs_of(out)
        local t = {}
        each_line(out, function(l)
            local k, v = l:match("^([^:]+):(.*)$")
            if k then t[#t + 1] = { k, (v:gsub("\\(.)", "%1")) } end
        end)
        return t
    end
    local function nm(args, done) run("nmcli", args, function(out, code) done(out or "", code) end) end
    local function shown() return fact.panel == "settings" and fact.set_page == "pg_vpn" end

    -- ── what is going through it ──
    local function rate(b)
        if b >= 1048576 then return string.format("%.1f MB/s", b / 1048576) end
        if b >= 1024 then return string.format("%.0f KB/s", b / 1024) end
        return string.format("%.0f B/s", b)
    end
    local function on_traf(line)
        local d, u = (line or ""):match("^(%d+)%s+(%d+)")
        d, u = tonumber(d), tonumber(u)
        if not d then return end
        local sm = S.samples
        sm[#sm + 1] = { d = d, u = u }
        while #sm > COLS do table.remove(sm, 1) end
        -- against the busiest column shown, or 64 KB/s: an idle line's trickle does not fill the chart
        local peak = 65536
        for _, v in ipairs(sm) do peak = math.max(peak, v.d, v.u) end
        local m = {}
        for i = 1, COLS do
            local v = sm[i - (COLS - #sm)]          -- the newest at the right end
            m[i] = v and { d = v.d / peak, u = v.u / peak } or { d = 0, u = 0 }
        end
        model.nw_bars = m
        local n, ad, au = 0, 0, 0
        for i = math.max(1, #sm - 3), #sm do n = n + 1; ad = ad + sm[i].d; au = au + sm[i].u end
        text.nw_rate = "Down " .. rate(ad / n) .. "  ·  Up " .. rate(au / n)
        fact.nw_traf = true
    end
    -- the program runs while the page shows and there is an adapter in use, and reads that one
    local function watch_traf()
        local dev = shown() and S.dev or nil
        if dev == S.pdev then return end
        if S.proc then kill(S.proc, "term"); S.proc = nil end
        S.pdev = dev
        S.samples = {}
        model.nw_bars = {}
        text.nw_rate = ""
        fact.nw_traf = false
        if not dev or not dev:match("^[%w._-]+$") then return end
        local mine
        mine = spawn("vitreus-nettraf", { dev }, function(line) if S.proc == mine then on_traf(line) end end,
            function() if S.proc == mine then S.proc = nil; S.pdev = nil end end)
        S.proc = mine
    end

    -- ── reading ──
    local function nothing()
        S.dev, S.uuid, S.name, S.filled, S.was = nil, nil, "", nil, nil
        fact.nw_on = false
        text.nw_title = "Not connected"
        text.nw_sub = "No cable or Wi-Fi is carrying anything"
        text.nw_a, text.nw_g, text.nw_d = "–", "–", "–"
        watch_traf()
    end

    local function fill(set, live)
        -- the fields start as what is written in the connection; one whose address is handed out starts as what it was handed, so «by hand» keeps it
        local a, g, d = set["ipv4.addresses"] or "", set["ipv4.gateway"] or "", set["ipv4.dns"] or ""
        fact.nw_auto = set["connection.autoconnect"] == "yes"
        fact.nw_manual = set["ipv4.method"] == "manual"
        text.nwf_addr = a ~= "" and (a:match("^[^,%s]+") or a) or (live.cidr or "")
        text.nwf_gw = g ~= "" and g or (live.gw or "")
        text.nwf_dns = (d:gsub(",", ", "))
        S.was = { manual = set["ipv4.method"] == "manual", addr = a:match("^[^,%s]+") or "", gw = g, dns = d, auto = set["connection.autoconnect"] == "yes" }
        S.filled = S.uuid
    end

    local refresh
    local function done_reading()
        S.reading = false
        if S.again then S.again = false; refresh() end
    end
    refresh = function(refill)
        if S.reading then S.again = true return end
        S.reading = true
        if refill then S.filled = nil end
        nm({ "-t", "-f", "DEVICE,TYPE,STATE", "device" }, function(out, code)
            if code ~= 0 then nothing(); text.nw_sub = "NetworkManager is not answering"; return done_reading() end
            local cable, radio
            each_line(out, function(l)
                local f = terse(l)
                if f[3] == "connected" then
                    if f[2] == "ethernet" then cable = cable or f[1] elseif f[2] == "wifi" then radio = radio or f[1] end
                end
            end)
            local dev = cable or radio
            if not dev then nothing(); return done_reading() end
            nm({ "-t", "-f", "GENERAL.CONNECTION,GENERAL.CON-UUID,CAPABILITIES.SPEED,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS", "device", "show", dev }, function(o2, c2)
                if c2 ~= 0 then nothing(); return done_reading() end
                local live, dns = {}, {}
                for _, kv in ipairs(pairs_of(o2)) do
                    local k, v = kv[1], kv[2]
                    if k == "GENERAL.CONNECTION" then live.name = v
                    elseif k == "GENERAL.CON-UUID" then live.uuid = v
                    elseif k == "CAPABILITIES.SPEED" and v ~= "unknown" then live.speed = v
                    elseif k:find("^IP4%.ADDRESS") and not live.cidr then live.cidr = v
                    elseif k == "IP4.GATEWAY" and v ~= "--" then live.gw = v
                    elseif k:find("^IP4%.DNS") and #dns < 2 then dns[#dns + 1] = v end
                end
                if not live.uuid or live.uuid == "" then nothing(); return done_reading() end
                S.dev, S.uuid, S.name = dev, live.uuid, live.name or dev
                fact.nw_on = true
                text.nw_title = S.name
                text.nw_sub = dev .. "  ·  " .. (dev == cable and (live.speed or "Cable") or "Wi-Fi")
                text.nw_a = live.cidr and (live.cidr:gsub("/%d+$", "")) or "–"
                text.nw_g = live.gw or "–"
                text.nw_d = #dns > 0 and table.concat(dns, ", ") or "–"
                watch_traf()
                if S.filled == S.uuid then return done_reading() end
                nm({ "-t", "-f", "connection.autoconnect,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns", "connection", "show", "uuid", S.uuid }, function(o3, c3)
                    if c3 == 0 then
                        local set = {}
                        for _, kv in ipairs(pairs_of(o3)) do set[kv[1]] = kv[2] end
                        fill(set, live)
                    end
                    done_reading()
                end)
            end)
        end)
    end

    -- ── Apply ──
    local function is_ip(s)
        local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        if not a then return false end
        for _, n in ipairs({ a, b, c, d }) do if tonumber(n) > 255 then return false end end
        return true
    end
    local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    local WHY = {
        [4] = "It was saved, but the connection did not come back up",
        [8] = "NetworkManager is not running",
        [10] = "That connection is no longer there",
    }

    on("nw_apply", function()
        if fact.nw_busy or not S.uuid then return end
        local uuid, dev, name, was = S.uuid, S.dev, S.name, S.was or {}
        local dns = {}
        for d in text.nwf_dns:gmatch("[^,%s]+") do
            if not is_ip(d) then text.nw_msg = "«" .. d .. "» is not a name server's address (four numbers, as 1.1.1.1)" return end
            dns[#dns + 1] = d
        end
        local dns_s = table.concat(dns, ",")
        local args = { "connection", "modify", "uuid", uuid, "connection.autoconnect", fact.nw_auto and "yes" or "no" }
        local changed
        if fact.nw_manual then
            local addr, gw = trim(text.nwf_addr), trim(text.nwf_gw)
            local ip, bits = addr:match("^([%d.]+)/(%d+)$")
            if not ip then ip, bits = addr, "24" end
            if not is_ip(ip) or tonumber(bits) < 1 or tonumber(bits) > 32 then text.nw_msg = "The address is four numbers and the network's bits, as 192.168.1.50/24" return end
            if gw ~= "" and not is_ip(gw) then text.nw_msg = "The router's address is four numbers, as 192.168.1.1" return end
            addr = ip .. "/" .. bits
            for _, a in ipairs({ "ipv4.method", "manual", "ipv4.addresses", addr, "ipv4.gateway", gw, "ipv4.dns", dns_s, "ipv4.ignore-auto-dns", "no" }) do args[#args + 1] = a end
            changed = not was.manual or was.addr ~= addr or was.gw ~= gw or was.dns ~= dns_s
        else
            -- handed out by the network; name servers written here are used instead of the ones it hands out
            for _, a in ipairs({ "ipv4.method", "auto", "ipv4.addresses", "", "ipv4.gateway", "", "ipv4.dns", dns_s, "ipv4.ignore-auto-dns", dns_s ~= "" and "yes" or "no" }) do args[#args + 1] = a end
            changed = was.manual == true or was.dns ~= dns_s
        end
        fact.nw_busy = true
        text.nw_msg = "Applying…"
        local function finish(words)
            fact.nw_busy = false
            text.nw_msg = words
            refresh(true)
        end
        nm(args, function(_, code)
            if code ~= 0 then return finish(WHY[code] or "NetworkManager did not accept that (it may have wanted your password)") end
            if not (dev and changed) then return finish("Saved for " .. name) end
            -- in use: the new address is put on the adapter without letting go of the connection, or, when that is refused, by connecting again
            nm({ "device", "reapply", dev }, function(_, c2)
                if c2 == 0 then return finish("Applied to " .. name) end
                nm({ "--wait", "30", "connection", "up", "uuid", uuid }, function(_, c3)
                    finish(c3 == 0 and ("Applied to " .. name) or (WHY[c3] or WHY[4]))
                end)
            end)
        end)
    end)

    -- ── when it is looked at ──
    local function wake()
        if shown() then
            text.nw_msg = ""
            refresh(true)
        else
            watch_traf()        -- (stops it)
        end
    end
    on("fact:set_page", wake)
    on("fact:panel", wake)
    sys.watch("network", function() if shown() and not fact.nw_busy then refresh() end end)
    nothing()
    wake()
end
