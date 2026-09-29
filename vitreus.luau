-- The brightness service reads the backlight straight from sysfs, but setting
-- it shells out to brightnessctl - so a real backlight can still report a
-- level with nothing able to move it, if the binary itself is missing.
run("which", { "brightnessctl" }, function(_, code)
    fact.bright_avail = code == 0
end)

-- Workspaces only: what moves is moved by the renderer.
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do busy[d.id] = d.windows > 0 end
    for i = 1, 5 do fact["ws." .. i .. ".busy"] = busy[i] or false end
    fact["ws.active"] = w.active
end)
on("go", function(i) sys.call("workspaces.focus", i) end)

-- The clock, written the way it is read here: 12 hours with am/pm, and the long date.
local days = { [0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local months = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }

sys.watch("clock", function(c)
    local h = c.hour % 12
    if h == 0 then h = 12 end
    text.clock12 = string.format("%d:%02d %s", h, c.minute, c.hour < 12 and "am" or "pm")
    -- The bar clock's three parts.
    text.clock_h = tostring(h)
    text.clock_mm = string.format(":%02d", c.minute)
    text.bar_ap = c.hour < 12 and "am" or "pm"
    text.bar_date = days[c.weekday]:sub(1, 3):upper()      -- just the day: MON
    text.datelong = string.format("%s, %s %d, %d", days[c.weekday], months[c.month], c.day, c.year)
    -- The clock card's pieces.
    text.clock_hm = string.format("%d:%02d", h, c.minute)
    text.clock_ap = c.hour < 12 and "AM" or "PM"
    text.date_wd = days[c.weekday]:upper()
    text.date_md = months[c.month]:sub(1, 3):upper() .. " " .. c.day
end)

-- The player: whether there is one, and what the three buttons do.
-- cava listens to what is playing and prints one line per frame: six bars, 0..1000.
-- It only runs while something plays, and the bass is the mean of the low two.
local cava = nil
local last = 0
local spec_last = {}
local watching = false      -- the player's panel is open: the only time the equalizer is worth feeding

-- cava wants its config as a file. It is kept here rather than in a file next to the scene, so
-- nothing depends on where Vitreus is installed: it is written into the scene's own data folder (where
-- `dnd.json` and `calendar.json` already live) and cava is pointed at it. That folder is
-- `$XDG_DATA_HOME/pleamar/vitreus`, or `$HOME/.local/share/pleamar/vitreus`, and the sandbox has no
-- `os.getenv`, so the environment is asked of the system once. A player that starts before the
-- answer arrives waits for it.
local CAVA_CONF = table.concat({
    "[general]", "bars = 6", "framerate = 30",
    "[input]", "method = pipewire",
    "[output]", "method = raw", "raw_target = /dev/stdout", "data_format = ascii",
    "ascii_max_range = 1000", "bar_delimiter = 59", "frame_delimiter = 10",
}, "\n") .. "\n"
local cava_conf = nil
local want_listen = false
local listen

local function conf_ready(base)
    base = (base or ""):gsub("%s+$", "")
    if base == "" then return false end
    cava_conf = base .. "/pleamar/vitreus/cava.conf"
    if want_listen then listen() end
    return true
end
pcall(sys.call, "files.write", "cava.conf", CAVA_CONF)
run("printenv", { "XDG_DATA_HOME" }, function(out, code)
    if code == 0 and conf_ready(out) then return end
    run("printenv", { "HOME" }, function(home)
        conf_ready((home or ""):gsub("%s+$", "") .. "/.local/share")
    end)
end)

listen = function()
    want_listen = true
    if cava or not cava_conf then return end
    cava = spawn("cava", { "-p", cava_conf }, function(line)
        local b = {}
        for v in string.gmatch(line, "(%d+);") do b[#b + 1] = tonumber(v) / 1000 end
        if #b < 2 then return end
        local bass = math.min(1, (b[1] + b[2]) / 2)
        -- the equalizer in the media card: only worth sending while that panel is showing
        if watching then
            for i = 1, 6 do
                local v = math.min(1, b[i] or 0)
                if math.abs(v - (spec_last[i] or 0)) > 0.02 then
                    spec_last[i] = v
                    fact["spec." .. (i - 1)] = v
                end
            end
        end
        -- only report when it moved enough to be seen: the renderer springs the rest
        if math.abs(bass - last) > 0.03 then
            last = bass
            fact.bass = bass
        end
    end, function() cava = nil end)
end

local function hush()
    want_listen = false
    if cava then kill(cava); cava = nil end
    last = 0
    fact.bass = 0
    for i = 1, 6 do spec_last[i] = 0; fact["spec." .. (i - 1)] = 0 end
end

-- The cover. Every player publishes it the same way (MPRIS `mpris:artUrl`), and
-- `playerctl` reads it: a local file (browsers write theirs into /tmp, mpv and VLC
-- point at the folder) or a link (Spotify and most streaming apps). A file is used
-- where it is; a link is fetched once into /tmp and cached under a name made from it.
local art_url = ""

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local function unpercent(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function show_art(path)
    text.arturl = path
    fact.art_on = path ~= ""
end

local function use_art(url)
    if url == art_url then return end
    art_url = url
    if url == "" then show_art("") return end
    if url:sub(1, 7) == "file://" then
        show_art(unpercent(url:sub(8)))
    elseif url:match("^https?://") then
        local path = "/tmp/vitreus-art-" .. hash(url) .. ".img"
        run("curl", { "-fsSL", "--max-time", "8", "-o", path, url }, function(_, code)
            if code == 0 and art_url == url then show_art(path) end
        end)
    else
        show_art("")
    end
end

local function fetch_art(player)
    run("playerctl", { "-p", player, "metadata", "mpris:artUrl" }, function(out, code)
        local url = tostring(out or ""):gsub("%s+$", "")
        if code == 0 and url ~= "" then
            use_art(url)
        else
            -- the name the service gave may not be one playerctl knows: ask without it
            run("playerctl", { "metadata", "mpris:artUrl" }, function(out2, code2)
                use_art(code2 == 0 and (tostring(out2 or ""):gsub("%s+$", "")) or "")
            end)
        end
    end)
end

local song = ""

sys.watch("media", function(m)
    -- playerctld stays on the bus as a phantom player even with nothing open:
    -- it reports a player name but no title, so the name alone doesn't count.
    local has_media = m.player ~= "" and m.title ~= ""
    fact.media_on = has_media
    if m.playing then listen() else hush() end
    if not has_media then
        song = ""
        use_art("")
        return
    end
    local now = m.player .. "|" .. tostring(m.title) .. "|" .. tostring(m.artist)
    if now ~= song then
        local first = song == ""
        song = now
        fetch_art(m.player)
        -- players often publish the cover a moment after the title
        after(900, function() fetch_art(m.player) end)
        if not first then emit("trackchange") end
    end
end)
on("mcmd", function(k)
    sys.call(k == 0 and "media.previous" or (k == 1 and "media.toggle" or "media.next"))
end)

-- The volume slider: the scene turns the pointer into 0..1, the mixer takes it.
on("setvol", function(v)
    sys.call("audio.volume", v)
end)

on("setbright", function(v)
    sys.call("brightness.level", v)
end)

-- An event's payload crosses over as a plain number (1/0), not a Luau
-- boolean, even for something written `not net.wifi` in the scene - and
-- these two services insist on a real true/false, not a 1 or a 0.
-- The Wi-Fi tile only names a Wi-Fi connection: `kind` is text, which the scene cannot compare.
sys.watch("network", function(n)
    fact.on_wifi = n.kind == "wifi" and n.online == true
end)

on("togglewifi", function(v)
    sys.call("network.wifi", v == 1)
end)

on("togglebt", function(v)
    sys.call("bluetooth.power", v == 1)
end)

-- Do Not Disturb, with a timer, and the notification history: one module. `dnd` is whether it is in effect,
-- either switched on by hand or by a timer that has not run out. Reading a fact back is not guaranteed to be a
-- boolean, so the logic keeps its own copies. The state is saved in `dnd.json` ({ manual, ends, len }); the
-- history in `notification-history.json`. pleamar's own history only holds what expired unseen, and Vitreus
-- handles every notification itself, so it keeps its own: every arrival goes in, including those Do Not
-- Disturb holds back (which is what a history is for).
local dnd = false
local dnd_manual = false
local dnd_until = 0                       -- the time a running timer ends, in seconds; 0 for none
local dnd_len = 0                         -- how many minutes it was set for: which chip is lit
local nt_hist = {}                        -- newest first: { app, title, body, t }

local function dnd_save()
    pcall(sys.call, "files.write", "dnd.json", { manual = dnd_manual, ends = dnd_until, len = dnd_len })
end
local function nt_save()
    pcall(sys.call, "files.write", "notification-history.json", { items = nt_hist })
end

local function nt_when(t)
    local d, now = os.date("*t", t), os.date("*t")
    if d.year == now.year and d.yday == now.yday then
        local h = d.hour % 12
        if h == 0 then h = 12 end
        return string.format("%d:%02d %s", h, d.min, d.hour < 12 and "am" or "pm")
    end
    return os.date("%b ", t) .. d.day
end

local function nt_render()
    local rows = {}
    for i, h in ipairs(nt_hist) do
        if i > 30 then break end
        rows[i] = { title = h.title, sub = h.body ~= "" and (h.app .. "  ·  " .. h.body) or h.app, when = nt_when(h.t) }
    end
    model.nt_hist = rows
end

-- The time a timer has left, as m:ss (h:mm:ss past an hour).
local function dnd_left_text()
    local r = math.max(0, dnd_until - os.time())
    if r >= 3600 then return string.format("%d:%02d:%02d", r // 3600, (r % 3600) // 60, r % 60) end
    return string.format("%d:%02d", r // 60, r % 60)
end

local function dnd_refresh()
    if dnd_until > 0 and os.time() >= dnd_until then
        dnd_until, dnd_len = 0, 0
        dnd_save()
    end
    dnd = dnd_manual or dnd_until > 0
    fact.dnd_on = dnd
    fact.dnd_len = dnd_until > 0 and dnd_len or 0
    if dnd_until > 0 then
        text.dnd_left = dnd_left_text() .. " left"
        text.nt_tile_sub = "Silenced · " .. dnd_left_text()
    elseif dnd then
        text.dnd_left = "On until turned off"
        text.nt_tile_sub = "Silenced"
    else
        text.dnd_left = "Off"
        text.nt_tile_sub = #nt_hist > 0 and (#nt_hist .. " in history") or "All clear"
    end
end

local function nt_strip(s)
    return ((s or ""):gsub("<[^>]*>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'))
end
local function nt_add(n)
    table.insert(nt_hist, 1, {
        app = (n.app ~= nil and n.app ~= "") and n.app or "System",
        title = nt_strip((n.title ~= nil and n.title ~= "") and n.title or "Notification"),
        body = nt_strip(n.body),
        t = os.time(),
    })
    while #nt_hist > 50 do table.remove(nt_hist) end
    nt_save()
    nt_render()
    dnd_refresh()
end

do
    local ok, saved = pcall(sys.ask, "files.read", "dnd.json", "json")
    if ok and type(saved) == "table" then
        dnd_manual = saved.manual == true
        if type(saved.ends) == "number" and saved.ends > os.time() then
            dnd_until = saved.ends
            dnd_len = type(saved.len) == "number" and saved.len or 0
        end
    end
    local okh, hist = pcall(sys.ask, "files.read", "notification-history.json", "json")
    if okh and type(hist) == "table" and type(hist.items) == "table" then nt_hist = hist.items end
end
nt_render()
dnd_refresh()

-- The tile's pill: off if anything is silencing, else on until turned off.
on("togglednd", function()
    if dnd then
        dnd_manual, dnd_until, dnd_len = false, 0, 0
    else
        dnd_manual = true
    end
    dnd_save()
    dnd_refresh()
end)
-- A timer chip; pressing the one that is lit again cancels it.
on("dnd_for", function(m)
    if dnd_until > 0 and dnd_len == m then
        dnd_until, dnd_len = 0, 0
    else
        dnd_until, dnd_len, dnd_manual = os.time() + m * 60, m, false
    end
    dnd_save()
    dnd_refresh()
end)
every(1000, function() if dnd_until > 0 then dnd_refresh() end end)   -- the countdown
on("nt_clear", function()
    nt_hist = {}
    nt_save()
    nt_render()
    dnd_refresh()
end)
on("nt_hist_del", function(i)
    table.remove(nt_hist, i + 1)
    nt_save()
    nt_render()
    dnd_refresh()
end)

-- Caffeine: what keeps the machine awake is hypridle being stopped, so the
-- truth is asked of the system, not remembered. A timer is the one thing that is remembered: when it ends,
-- hypridle is started again. It is kept in `caffeine.json`, so a shell that restarts while it runs picks it up.
local caf_on, caf_avail = false, true
local caf_until = 0                       -- the time a running timer ends, in seconds; 0 for none
local caf_len = 0                         -- how many minutes it was set for: which chip is lit
local caf_busy = false                    -- a change is under way: the poll must not read hypridle half-changed

local function caf_save()
    pcall(sys.call, "files.write", "caffeine.json", { ends = caf_until, len = caf_len })
end

-- The time a timer has left, as m:ss (h:mm:ss past an hour).
local function caf_left_text()
    local r = math.max(0, caf_until - os.time())
    if r >= 3600 then return string.format("%d:%02d:%02d", r // 3600, (r % 3600) // 60, r % 60) end
    return string.format("%d:%02d", r // 60, r % 60)
end

local function caf_refresh()
    fact.caf_on = caf_on
    fact.caf_len = (caf_on and caf_until > 0) and caf_len or 0
    if caf_on and caf_until > 0 then
        text.caf_left = caf_left_text() .. " left"
        text.caf_tile_sub = "Awake · " .. caf_left_text()
    elseif caf_on then
        text.caf_left = "On until turned off"
        text.caf_tile_sub = "Awake"
    else
        text.caf_left = "Off"
        text.caf_tile_sub = "Off"
    end
end

local function caf_poll(after_poll)
    run("pgrep", { "-x", "hypridle" }, function(_, code)
        caf_on = code ~= 0
        -- hypridle is back on its own (or was never stopped): whatever timer was running has no meaning
        if not caf_on and caf_until > 0 and not caf_busy then
            caf_until, caf_len = 0, 0
            caf_save()
        end
        caf_refresh()
        if after_poll then after_poll() end
    end)
end

-- Keep the machine awake (stop hypridle), or let it sleep again (start it), then read what happened.
local function caf_set(awake)
    caf_busy = true
    local done = function() caf_poll(function() caf_busy = false end) end
    if awake then
        run("pkill", { "-x", "hypridle" }, function()
            run("systemctl", { "--user", "stop", "hypridle.service" }, done)
        end)
    else
        run("systemctl", { "--user", "start", "hypridle.service" }, done)
    end
end

run("which", { "hypridle" }, function(_, code)
    caf_avail = code == 0
    fact.caf_avail = caf_avail
    if code == 0 then
        -- a timer that was running when the shell went away: still running, or over
        local ok, saved = pcall(sys.ask, "files.read", "caffeine.json", "json")
        local ends = (ok and type(saved) == "table" and type(saved.ends) == "number") and saved.ends or 0
        caf_poll(function()
            if ends > 0 and caf_on then
                if ends > os.time() then
                    caf_until = ends
                    caf_len = type(saved.len) == "number" and saved.len or 0
                    caf_refresh()
                else
                    caf_until, caf_len = 0, 0
                    caf_save()
                    caf_set(false)
                end
            end
        end)
        every(5000, function() caf_poll() end)
    end
end)

-- The tile's pill: off if it is on, else on until turned off.
on("togglecaf", function()
    if not caf_avail then return end
    caf_until, caf_len = 0, 0
    caf_save()
    caf_set(not caf_on)
end)
-- A timer chip (minutes); 0 is "until off". Pressing the one that is lit again turns it off.
on("caf_for", function(m)
    if not caf_avail then return end
    if caf_on and ((m == 0 and caf_until == 0) or (m > 0 and caf_until > 0 and caf_len == m)) then
        caf_until, caf_len = 0, 0
        caf_save()
        caf_set(false)
        return
    end
    if m == 0 then
        caf_until, caf_len = 0, 0
    else
        caf_until, caf_len = os.time() + m * 60, m
    end
    caf_save()
    if caf_on then caf_refresh() else caf_set(true) end
end)
every(1000, function()
    if caf_until > 0 then
        if os.time() >= caf_until then
            caf_until, caf_len = 0, 0
            caf_save()
            caf_set(false)
        else
            caf_refresh()
        end
    end
end)

-- Bluetooth only says a device's name inside its `devices` list, not as a
-- top-level field - so the connected one (there is at most one that matters
-- here) is picked out here, the same way the audio watcher below picks the
-- default output out of its list. `bt_list` is the same list again, kept only
-- so a row's tap (a position - see the Wi-Fi list below for why) can find its
-- address.
local bt_list = {}
local bt_last = nil                       -- the last thing the service said
local bt_sig = nil                        -- what the list said last time it was handed over
local bt_scanning = false                 -- a scan is running (see `bt_scan` below)

-- The list is built here, the way Synoptik's was: what is connected first, then what is paired, then the
-- rest, named ones alphabetically and the anonymous ones (BLE beacons, mostly, which are dozens) last, by
-- address. Unpaired devices are only shown while a scan is running: BlueZ goes on reporting what walked past
-- for minutes afterwards, and a stale list of strangers is worse than none.
local function bt_is_mac(n) return n:match("^%x%x[-:]%x%x[-:]%x%x[-:]%x%x[-:]%x%x[-:]%x%x$") ~= nil end

-- What a tap has asked for and BlueZ has not answered yet, by address: connecting or disconnecting takes
-- seconds, and BlueZ can drop the device from its list while it works. Until it answers the row stays where it
-- was (remembered from the last time it was seen), says what it is doing, and only then takes its new place.
local bt_pending = {}                     -- address -> { kind = 1 connecting | 2 disconnecting | 3 failed, row = last row, gen = n }
local bt_gen = 0
local bt_open_addr = nil                  -- the address of the row that is open: its index moves when the list re-sorts

local function bt_render()
    local b = bt_last
    if not b then return end
    local name = ""
    local rows = {}
    local seen = {}
    for _, d in ipairs(b.devices or {}) do
        if d.connected then name = d.name end
        if d.paired or d.connected or bt_scanning or bt_pending[d.address] then
            local nm = (d.name ~= nil and d.name ~= "") and d.name or d.address
            local row = {
                name = nm, address = d.address, paired = d.paired and true or false,
                connected = d.connected and true or false, battery = d.battery or -1,
                anon = bt_is_mac(nm), busy = 0,
            }
            local p = bt_pending[d.address]
            if p then
                -- BlueZ has answered: connecting is over once it is connected, disconnecting once it is not
                if (p.kind == 1 and row.connected) or (p.kind == 2 and not row.connected) then
                    bt_pending[d.address] = nil
                else
                    p.row = row
                    row.busy = p.kind
                end
            end
            seen[d.address] = true
            rows[#rows + 1] = row
        end
    end
    -- a device BlueZ dropped while it was busy stays, as it was last seen
    for addr, p in pairs(bt_pending) do
        if not seen[addr] and p.row then
            local row = {}
            for k, v in pairs(p.row) do row[k] = v end
            row.busy = p.kind
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(x, y)
        if x.connected ~= y.connected then return x.connected end
        if x.paired ~= y.paired then return x.paired end
        if x.anon ~= y.anon then return not x.anon end
        return x.name:lower() < y.name:lower()
    end)
    while #rows > 24 do table.remove(rows) end
    fact.bt_connected = name ~= ""
    text.bt_name = name
    bt_list = rows
    local sig = {}
    for i, r in ipairs(rows) do
        sig[i] = r.address .. "|" .. r.name .. "|" .. tostring(r.paired) .. "|" .. tostring(r.connected) .. "|" .. tostring(r.battery) .. "|" .. r.busy
    end
    local joined = table.concat(sig, "\n")
    if joined ~= bt_sig then
        bt_sig = joined
        model.bt_devices = rows
        -- the open row follows its device to wherever the sort put it, so the open space slides there
        if bt_open_addr then
            local at = -1
            for i, r in ipairs(rows) do
                if r.address == bt_open_addr then at = i - 1 end
            end
            if at ~= fact.bt_open_row then fact.bt_open_row = at end
        end
    end
end

sys.watch("bluetooth", function(b)
    bt_last = b
    bt_render()
end)

on("fact:bt_open_row", function(i)
    local d = i >= 0 and bt_list[i + 1] or nil
    bt_open_addr = d and d.address or nil
end)

-- Asks BlueZ for something slow, and shows that it was asked. `kind` 1 connecting, 2 disconnecting. If BlueZ has
-- not answered in twenty seconds the row says it could not, for three, and goes back to what it was.
local function bt_ask(d, kind, call)
    bt_gen = bt_gen + 1
    local gen = bt_gen
    bt_pending[d.address] = { kind = kind, row = d, gen = gen }
    bt_render()
    sys.call(call, d.address)
    after(20000, function()
        local p = bt_pending[d.address]
        if p and p.gen == gen then
            p.kind = 3
            bt_render()
            after(3000, function()
                local q = bt_pending[d.address]
                if q and q.gen == gen then
                    bt_pending[d.address] = nil
                    bt_render()
                end
            end)
        end
    end)
end

on("bt_pick", function(i)
    local d = bt_list[i + 1]
    if not d or d.busy == 1 or d.busy == 2 then return end
    if d.connected then
        bt_ask(d, 2, "bluetooth.disconnect")
    else
        bt_ask(d, 1, "bluetooth.connect")
    end
end)

on("bt_forget", function(i)
    local d = bt_list[i + 1]
    if not d then return end
    bt_pending[d.address] = nil
    sys.call("bluetooth.forget", d.address)
    fact.bt_open_row = -1
end)

-- A scan gives the scene no sign of its own, so it is told to show one. Discovery is held open by
-- `bluetoothctl --timeout 12 scan on`, as Synoptik's first version did: pleamar's own `bluetooth.scan` answers
-- without an error but BlueZ never starts discovering (`Discovering` stays "no"), while this does, and the
-- service picks up what it finds. It ends by itself after twelve seconds.
on("bt_scan", function()
    if bt_scanning then return end
    bt_scanning = true
    fact.bt_scanning = true
    bt_render()
    run("bluetoothctl", { "--timeout", "12", "scan", "on" }, function()
        bt_scanning = false
        fact.bt_scanning = false
        bt_render()
    end)
end)

-- Wi-Fi asks NetworkManager once and the answer arrives within a few seconds, so its spinner is timed. As with
-- Bluetooth, pleamar's own `network.scan` returns without an error but NetworkManager's `LastScan` never moves;
-- `nmcli device wifi rescan` does move it, so the rescan goes through that. NetworkManager refuses a rescan
-- straight after another one, and says so: the spinner is shown regardless, since the list is fresh anyway.
local wifi_scanning = false
on("wifi_scan", function()
    if wifi_scanning then return end
    wifi_scanning = true
    fact.wifi_scanning = true
    run("nmcli", { "device", "wifi", "rescan" }, function()
        after(3500, function()
            wifi_scanning = false
            fact.wifi_scanning = false
        end)
    end)
end)

-- Where the sound can go. PipeWire's names come with the whole card model in
-- them, so they are only tidied (spaces); the scene truncates to fit its row.
-- The ids stay here: the scene only knows positions, and asks for one by number.
local out_ids = {}

sys.watch("audio", function(a)
    local rows, ids, current = {}, {}, ""
    for _, o in ipairs(a.outputs or {}) do
        local name = tostring(o.name):gsub("%s+", " ")
        rows[#rows + 1] = { name = name, current = o.default == true }
        ids[#ids + 1] = o.id
        if o.default == true then current = name end
    end
    out_ids = ids
    model.outlist = rows
    text.outname = current
end)

on("pick_out", function(i)
    local id = out_ids[i + 1]
    if id ~= nil then sys.call("audio.default", id) end
end)

-- The speaker icon: silence it, or bring the sound back.
on("mute", function()
    sys.call("audio.mute")
end)

-- ── the calendar ────────────────────────────────────────────────────
--  Reminders kept in `calendar.json`, a month on screen (six weeks) and the day
--  that is chosen. Writing «3:30pm Call mom» makes a reminder at that time; with
--  no time it is for the whole day. When its time comes, a notification goes out
--  (`notify-send`, to whoever receives them), once: it is marked so that a restart
--  does not say it again. The layout of the month and the way of saving are
--  Marea's calendar's, with weeks that start on Sunday and times in 12 hours.
local SUNDAY_FIRST = true
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }
local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local LETTERS = SUNDAY_FIRST and { "S", "M", "T", "W", "T", "F", "S" } or { "M", "T", "W", "T", "F", "S", "S" }

local cal = { events = {}, year = 0, month = 0, sel = nil, rows = {} }

local function days_in(y, m)
    if m == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then return 29 end
    return ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
end
--  0 for the first day of the week, whichever that is.
local function weekday(y, m, d)
    local w = os.date("*t", os.time({ year = y, month = m, day = d, hour = 12 })).wday   -- 1 is Sunday
    if SUNDAY_FIRST then return w - 1 end
    return (w + 5) % 7
end
local function key(y, m, d) return string.format("%04d-%02d-%02d", y, m, d) end
local function today()
    local t = os.date("*t")
    return t.year, t.month, t.day
end
local function parse_key(k)
    local y, m, d = k:match("^(%d+)-(%d+)-(%d+)$")
    return tonumber(y), tonumber(m), tonumber(d)
end
local function time12(hhmm)
    local h, mi = hhmm:match("^(%d+):(%d+)$")
    h, mi = tonumber(h), tonumber(mi)
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d%s", h12, mi, h < 12 and "am" or "pm")
end
local function on_day(k)
    local list = {}
    for _, e in ipairs(cal.events) do
        if e.date == k then list[#list + 1] = e end
    end
    --  Whole-day ones first, then by time.
    table.sort(list, function(a, b) return (a.time or "") < (b.time or "") end)
    return list
end

local function save_calendar()
    pcall(sys.call, "files.write", "calendar.json", { events = cal.events })
end
do
    local ok, loaded = pcall(sys.ask, "files.read", "calendar.json", "json")
    if ok and type(loaded) == "table" and type(loaded.events) == "table" then cal.events = loaded.events end
end

local function paint_calendar()
    local y, m = cal.year, cal.month
    text["cal.month"] = string.format("%s %d", MONTHS[m], y)
    for w = 1, 7 do text["cal.wd." .. w] = LETTERS[w] end
    --  The grid starts on the first day of the week the 1st falls in.
    local py, pm = y, m - 1
    if pm < 1 then py, pm = y - 1, 12 end
    local lead = weekday(y, m, 1)
    local ty, tm, td = today()
    local d, gy, gm = days_in(py, pm) - lead + 1, py, pm
    if lead == 0 then d, gy, gm = 1, y, m end
    local counts = {}
    for _, e in ipairs(cal.events) do counts[e.date] = (counts[e.date] or 0) + 1 end
    for k = 0, 41 do
        local kk = key(gy, gm, d)
        fact["cal.day." .. k] = d
        fact["cal.in." .. k] = gm == m
        fact["cal.today." .. k] = gy == ty and gm == tm and d == td
        fact["cal.n." .. k] = counts[kk] or 0
        if kk == cal.sel then fact["cal.sel"] = k end
        d = d + 1
        if d > days_in(gy, gm) then
            d, gm = 1, gm + 1
            if gm > 12 then gm, gy = 1, gy + 1 end
        end
    end
    local sy, sm, sd = parse_key(cal.sel)
    local wday = os.date("*t", os.time({ year = sy, month = sm, day = sd, hour = 12 })).wday   -- 1 is Sunday
    text["cal.sel_title"] = string.format("%s, %s %d", DAYS[wday], MONTHS[sm], sd)
    local list = on_day(cal.sel)
    text["cal.sel_sub"] = #list == 0 and "Free day" or (#list == 1 and "1 reminder" or string.format("%d reminders", #list))
    local rows = {}
    cal.rows = {}
    for i, e in ipairs(list) do
        if i <= 4 then
            rows[#rows + 1] = { time = e.time ~= "" and time12(e.time) or "all day", title = e.title, done = e.done == true }
            cal.rows[#cal.rows + 1] = e
        end
    end
    model.cal_events = rows
end

local function show_month(y, m, sel)
    cal.year, cal.month = y, m
    cal.sel = sel or key(y, m, 1)
    paint_calendar()
end

local function open_today()
    local y, m, d = today()
    show_month(y, m, key(y, m, d))
end
on("cal_open", open_today)
on("cal_today", open_today)
on("cal_prev", function()
    local y, m = cal.year, cal.month - 1
    if m < 1 then y, m = y - 1, 12 end
    show_month(y, m)
end)
on("cal_next", function()
    local y, m = cal.year, cal.month + 1
    if m > 12 then y, m = y + 1, 1 end
    show_month(y, m)
end)
--  A day of the grid: chosen; if it belongs to the month before or after, that month comes in.
on("cal_pick", function(k)
    k = math.floor(k or 0)
    local lead = weekday(cal.year, cal.month, 1)
    local n = k - lead + 1
    local y, m = cal.year, cal.month
    if n < 1 then
        m = m - 1
        if m < 1 then y, m = y - 1, 12 end
        n = days_in(y, m) + n
    elseif n > days_in(y, m) then
        n = n - days_in(y, m)
        m = m + 1
        if m > 12 then y, m = y + 1, 1 end
    end
    show_month(y, m, key(y, m, n))
end)

--  «3:30pm Call mom», «3pm call», «15:30 dentist», «18h gym», «18.30 dinner»;
--  anything else is for the whole day. Returns the time as "HH:MM", and the words.
local function parse_line(line)
    local h, mi, ap, rest = line:match("^(%d%d?):(%d%d)%s*([aApP][mM])%s+(.+)$")
    if not h then
        h, ap, rest = line:match("^(%d%d?)%s*([aApP][mM])%s+(.+)$")
        mi = "00"
    end
    if h then
        h, mi = tonumber(h), tonumber(mi)
        if h >= 1 and h <= 12 and mi < 60 then
            local pm = ap:lower() == "pm"
            if h == 12 then h = pm and 12 or 0 else h = pm and h + 12 or h end
            return string.format("%02d:%02d", h, mi), rest
        end
    end
    h, mi, rest = line:match("^(%d%d?)[:%.h](%d%d)%s+(.+)$")
    if not h then
        h, rest = line:match("^(%d%d?)h%s+(.+)$")
        mi = "00"
    end
    if h and tonumber(h) < 24 and tonumber(mi) < 60 then
        return string.format("%02d:%02d", tonumber(h), tonumber(mi)), rest
    end
    return "", line
end

local function add_line(value)
    local line = (value or ""):match("^%s*(.-)%s*$")
    if line == "" then return end
    local time, title = parse_line(line)
    table.insert(cal.events, { date = cal.sel, time = time, title = title })
    save_calendar()
    text.cal_new = ""
    paint_calendar()
end
on("submit:cal_new", add_line)
on("cal_add", function() add_line(text.cal_new) end)

on("cal_check", function(i)
    local e = cal.rows[(i or 0) + 1]
    if e == nil then return end
    e.done = not (e.done == true)
    save_calendar()
    paint_calendar()
end)
on("cal_delete", function(i)
    local e = cal.rows[(i or 0) + 1]
    if e == nil then return end
    for k, x in ipairs(cal.events) do
        if x == e then table.remove(cal.events, k); break end
    end
    save_calendar()
    paint_calendar()
end)

--  Every twenty seconds: tell what is due, and once. A reminder is due for five
--  minutes after its time, so a slept laptop does not read out the whole morning.
--  Also, if the day has turned over, the grid moves its «today» ring.
local painted_day = ""
every(20000, function()
    local y, m, d = today()
    local t = os.date("*t")
    local now = t.hour * 60 + t.min
    local k = key(y, m, d)
    local changed = false
    for _, e in ipairs(cal.events) do
        if e.date == k and e.time ~= "" and not e.told and not e.done then
            local eh, em = e.time:match("^(%d+):(%d+)$")
            local at = tonumber(eh) * 60 + tonumber(em)
            if now >= at and now < at + 5 then
                -- Do Not Disturb holds it back, but it still counts as told.
                if not dnd then
                    run("notify-send", { "-a", "Reminder", e.title, time12(e.time) }, function() end)
                end
                e.told = true
                changed = true
            end
        end
    end
    if changed then save_calendar(); paint_calendar() end
    if painted_day ~= k then
        painted_day = k
        if cal.year == 0 or (cal.sel == nil) then open_today() else paint_calendar() end
    end
end)
open_today()
painted_day = key(today())

-- The running windows. Hyprland is asked for them (`hyprctl clients`), since the window service
-- gives no list there; the panel under the window title keeps them fresh while it is open. A row's
-- icon is the icon of the app whose `.desktop` file that window's class belongs to (by id,
-- StartupWMClass or name), else the class as an icon name.
local apps_by_class = {}
local task_addrs = {}
local last_task_sig = nil

local function parse_clients(out)
    local list, cur = {}, nil
    for line in out:gmatch("[^\n]+") do
        local addr = line:match("^Window (%x+) %->")
        if addr then
            cur = { addr = addr }
            list[#list + 1] = cur
        elseif cur then
            local k, v = line:match("^%s+([%w]+): ?(.*)$")
            if k then cur[k] = v end
        end
    end
    return list
end

local function refresh_tasks()
    run("hyprctl", { "clients" }, function(out, code)
        if code ~= 0 then return end
        local list = {}
        local pc = parse_clients(out)
        for _, w in ipairs(pc) do
            if w.mapped == "1" then list[#list + 1] = w end
        end
        -- The one with the keyboard first, then by workspace, then by title: Synoptik's order.
        table.sort(list, function(a, b)
            local aa, ab = a.focusHistoryID == "0", b.focusHistoryID == "0"
            if aa ~= ab then return aa end
            local wa = tonumber((a.workspace or ""):match("^(-?%d+)")) or 0
            local wb = tonumber((b.workspace or ""):match("^(-?%d+)")) or 0
            if wa ~= wb then return wa < wb end
            return (a.title or ""):lower() < (b.title or ""):lower()
        end)
        local rows = {}
        task_addrs = {}
        for i, w in ipairs(list) do
            if i > 12 then break end
            local class = (w.class or ""):lower()
            local title = w.title
            if title == nil or title == "" then title = (w.class ~= nil and w.class ~= "") and w.class or "Window" end
            rows[i] = {
                title = title,
                ws = (w.workspace or ""):match("%((.-)%)") or "",
                active = w.focusHistoryID == "0",
                icon = apps_by_class[class] or class,
            }
            task_addrs[i] = w.addr
        end
        -- Only hand the scene a new list when something in it changed: rewriting an identical one
        -- every second restarts the rows' layout for nothing.
        local sig = {}
        for i, r in ipairs(rows) do sig[i] = r.title .. "|" .. r.ws .. "|" .. tostring(r.active) .. "|" .. tostring(r.icon) end
        local joined = table.concat(sig, "\n")
        if joined ~= last_task_sig then
            last_task_sig = joined
            model.tasks = rows
        end
    end)
end

sys.watch("apps", function(list)
    apps_by_class = {}
    for _, a in ipairs(list) do
        for _, k in ipairs({ a.name, a.wmclass, a.id }) do
            if k and k ~= "" then apps_by_class[k:lower()] = a.icon end
        end
    end
end)
on("fact:tasks_watch", function(v)
    watching = v == 1 or v == true
    if watching then refresh_tasks() end
end)
every(1000, function() if watching then refresh_tasks() end end)
-- This Hyprland takes its dispatchers in Lua. `close` has no way to name a window that is not the
-- focused one (a selector it does not understand is ignored, and the focused window closes), so a
-- row's close button first focuses that window, checks it really has the focus, and only then closes.
local function focus_window(addr, then_fn)
    run("hyprctl", { "dispatch", 'hl.dsp.focus({ window = "address:0x' .. addr .. '" })' }, then_fn or function() end)
end
on("task_focus", function(i)
    local addr = task_addrs[i + 1]
    if addr then focus_window(addr) end
end)
on("task_close", function(i)
    local addr = task_addrs[i + 1]
    if not addr then return end
    focus_window(addr, function()
        after(250, function()
            run("hyprctl", { "activewindow" }, function(out)
                if out and out:match("^Window (%x+)") == addr then
                    run("hyprctl", { "dispatch", "hl.dsp.window.close()" }, function() after(250, refresh_tasks) end)
                end
            end)
        end)
    end)
end)

-- The tray apps: background programs that have no window. Pressing one is a click on its icon.
local tray_keys = {}
sys.watch("tray", function(list)
    local rows = {}
    tray_keys = {}
    for i, t in ipairs(list) do
        if i > 8 then break end
        local title = t.title
        if title == nil or title == "" then title = t.id end
        rows[i] = { title = title, icon = t.icon or "" }
        tray_keys[i] = t.key
    end
    model.trays = rows
end)
on("tray_click", function(i)
    local key = tray_keys[i + 1]
    if key ~= nil then sys.call("tray.activate", key) end
end)

-- ── The volume and notification drawer ───────────────────────────────────────────────────
-- Two transient panels share one drawer under the bar. Neither may take a panel the user opened:
-- the volume shows only when nothing is open, and a notification waits its turn (in a queue) until
-- nothing but another of these is. `cur_panel` follows the scene's `panel`.
local cur_panel = "none"
local osd_gen = 0            -- bumped every time the drawer is shown, so an old timer cannot close a new one
local nt_now = nil           -- the notification on screen: { id, keys }
local nt_queue = {}
local nt_seen = {}
local nt_first = true

local function panel_is(name) return tostring(cur_panel) == name end
-- The scene tells the logic when `panel` changes from its side, not when the logic changes it, so
-- every write from here also updates the local copy.
local function set_panel(name)
    cur_panel = name
    fact.panel = name
end
local function osd_free() return panel_is("none") or panel_is("volume") or panel_is("notif") end

local function hide_osd(kind)
    if panel_is(kind == "vol" and "volume" or "notif") then set_panel("none") end
end

-- Volume: whenever the level or the mute changes with nothing else open.
local last_vol, last_mute = nil, nil
sys.watch("audio", function(a)
    local vol = math.floor((a.volume or 0) * 100 + 0.5)
    local mute = a.muted and true or false
    local changed = last_vol ~= nil and (vol ~= last_vol or mute ~= last_mute)
    last_vol, last_mute = vol, mute
    if not changed then return end
    if not (panel_is("none") or panel_is("volume")) then return end
    osd_gen = osd_gen + 1
    local gen = osd_gen
    fact.osd_kind = "vol"
    set_panel("volume")
    after(2000, function()
        if gen == osd_gen then hide_osd("vol") end
    end)
end)

-- Notifications: Vitreus is the notification server now, so this is where they arrive.
local function strip(s)
    return ((s or ""):gsub("<[^>]*>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'))
end

local function finish_notification()
    if nt_now then
        pcall(sys.call, "notifications.dismiss", nt_now.id)
        nt_now = nil
    end
    hide_osd("note")
end

local pump
local function show_notification(n)
    local critical = tostring(n.urgency) == "critical" or tostring(n.urgency) == "2"
    local keys, rows = {}, {}
    for _, a in ipairs(n.actions or {}) do
        if a.key ~= "default" and a.label and a.label ~= "" and #rows < 3 then
            rows[#rows + 1] = { label = a.label }
            keys[#keys + 1] = a.key
        end
    end
    local icon = (n.image ~= nil and n.image ~= "") and n.image or (n.icon or "")
    local body = strip(n.body)
    nt_now = { id = n.id, keys = keys }
    text.nt_app = ((n.app ~= nil and n.app ~= "") and n.app or "System"):upper()
    text.nt_title = strip((n.title ~= nil and n.title ~= "") and n.title or "Notification")
    text.nt_body = body
    text.nt_iconpath = icon
    fact.nt_icon_on = icon ~= ""
    fact.nt_body_on = body ~= ""
    fact.nt_urgent = critical
    model.nt_acts = rows
    osd_gen = osd_gen + 1
    local gen = osd_gen
    fact.osd_kind = "note"
    set_panel("notif")
    emit("ntnew")
    -- A critical one stays until it is dismissed; one with buttons stays longer.
    if not critical then
        after(#rows > 0 and 8000 or 4000, function()
            if gen == osd_gen and nt_now and nt_now.id == n.id then
                finish_notification()
                after(400, pump)
            end
        end)
    end
end

pump = function()
    if nt_now or #nt_queue == 0 or not osd_free() then return end
    show_notification(table.remove(nt_queue, 1))
end

pcall(sys.call, "notifications.keep", true)
sys.watch("notifications", function(list)
    -- The newest come first. What was already there when Vitreus started is not announced.
    for i = #list, 1, -1 do
        local n = list[i]
        if not nt_seen[n.id] then
            nt_seen[n.id] = true
            if not nt_first then
                nt_add(n)
                if dnd then
                    pcall(sys.call, "notifications.dismiss", n.id)   -- Do Not Disturb: it never shows
                else
                    nt_queue[#nt_queue + 1] = n
                end
            end
        end
    end
    nt_first = false
    pump()
end)

on("nt_close", function()
    finish_notification()
    after(400, pump)
end)
on("nt_act", function(i)
    if nt_now and nt_now.keys[i + 1] then
        pcall(sys.call, "notifications.invoke", nt_now.id, nt_now.keys[i + 1])
    end
    finish_notification()
    after(400, pump)
end)

-- Which panel is open, as the scene has it: a panel the user closes lets the next notification in.
on("fact:panel", function(v)
    cur_panel = v
    -- The notification's drawer was closed from elsewhere (a click on the bar, Escape): it counts as
    -- seen, and the next one may come.
    if nt_now and not panel_is("notif") then
        pcall(sys.call, "notifications.dismiss", nt_now.id)
        nt_now = nil
    end
    pump()
end)

-- ── Iris: the palette from the wallpaper ─────────────────────────────────────────────────
-- Synoptik ran `iris --json-only <wallpaper>` and used its bg / surface / fg / dim / accent / red,
-- with a legibility floor on the text and a subtle / medium / bold push on the accent. Here the scene
-- cannot be handed a colour at runtime, so the result is written into `palette.plm`, the library of
-- `let` colours the scene imports, and the scene reloads in them. `iris.json` in Vitreus's data folder
-- holds the two settings: { enabled = true, intensity = "medium" | "subtle" | "bold" }.
local iris_cfg = { enabled = true, intensity = "medium" }
local iris_last_wp = nil
local iris_last_text = nil

local function hex_to_rgb(h)
    return tonumber(h:sub(2, 3), 16) / 255, tonumber(h:sub(4, 5), 16) / 255, tonumber(h:sub(6, 7), 16) / 255
end
local function rgb_to_hex(r, g, b)
    local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return string.format("#%02x%02x%02x", byte(r), byte(g), byte(b))
end
local function rgb_to_hsl(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local l = (mx + mn) / 2
    if mx == mn then return 0, 0, l end
    local d = mx - mn
    local s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
    local h
    if mx == r then h = (g - b) / d + (g < b and 6 or 0)
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    return h / 6, s, l
end
local function hsl_to_rgb(h, s, l)
    if s == 0 then return l, l, l end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    local function chan(t)
        if t < 0 then t = t + 1 elseif t > 1 then t = t - 1 end
        if t < 1 / 6 then return p + (q - p) * 6 * t end
        if t < 1 / 2 then return q end
        if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
        return p
    end
    return chan(h + 1 / 3), chan(h), chan(h - 1 / 3)
end
local function lin(v) return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
local function luminance(hex)
    local r, g, b = hex_to_rgb(hex)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end
local function contrast(a, b)
    local la, lb = luminance(a), luminance(b)
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end
local function shade(hex, dl)                       -- the same colour, lighter (+) or darker (-)
    local h, s, l = rgb_to_hsl(hex_to_rgb(hex))
    return rgb_to_hex(hsl_to_rgb(h, s, math.max(0.03, math.min(0.97, l + dl))))
end
local function blend(a, b, t)                       -- a toward b
    local ar, ag, ab = hex_to_rgb(a)
    local br, bg, bb = hex_to_rgb(b)
    return rgb_to_hex(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end
-- Nudge a colour's lightness, in the direction it already leans, until it clears `min_ratio`
-- against the background: hue and saturation are kept, so Iris's choice survives.
local function ensure_contrast(hex, bg, min_ratio)
    if contrast(hex, bg) >= min_ratio then return hex end
    local h, s, l = rgb_to_hsl(hex_to_rgb(hex))
    local _, _, bl = rgb_to_hsl(hex_to_rgb(bg))
    local dir = l >= bl and 1 or -1
    for _ = 1, 30 do
        l = math.max(0.03, math.min(0.97, l + dir * 0.03))
        local cand = rgb_to_hex(hsl_to_rgb(h, s, l))
        if contrast(cand, bg) >= min_ratio then return cand end
        if l <= 0.03 or l >= 0.97 then break end
    end
    return rgb_to_hex(hsl_to_rgb(h, s, dir > 0 and 0.97 or 0.03))
end
-- Iris has no vibrance knob; "subtle" and "bold" are a saturation (and mild lightness) push on
-- its accent, and "medium" leaves it as Iris gave it.
local function intensity_accent(hex, intensity)
    local h, s, l = rgb_to_hsl(hex_to_rgb(hex))
    if intensity == "subtle" then
        s = s * 0.45
        l = l + (0.55 - l) * 0.3
    elseif intensity == "bold" then
        s = math.min(1, s * 1.5)
        l = l + (l > 0.5 and 0.08 or -0.08)
    end
    l = math.max(0.15, math.min(0.85, l))
    return rgb_to_hex(hsl_to_rgb(h, s, l))
end

-- Where the palette goes, and where Vitreus's data folder is, both resolved from the environment
-- (`$XDG_CONFIG_HOME` / `$XDG_DATA_HOME`, else under `$HOME`) the same way as cava's config.
local dirs = nil
local dirs_waiting = {}
local function with_dirs(fn)
    if dirs then return fn(dirs) end
    dirs_waiting[#dirs_waiting + 1] = fn
    if #dirs_waiting > 1 then return end
    local got = {}
    local function finish()
        if not (got.home and got.xdg_data ~= nil and got.xdg_conf ~= nil and got.xdg_cache ~= nil) then return end
        dirs = {
            home = got.home,
            cache = (got.xdg_cache ~= "" and got.xdg_cache or (got.home .. "/.cache")) .. "/pleamar/vitreus/wp",
            data = (got.xdg_data ~= "" and got.xdg_data or (got.home .. "/.local/share")) .. "/pleamar/vitreus",
            conf = (got.xdg_conf ~= "" and got.xdg_conf or (got.home .. "/.config")) .. "/pleamar/shells/vitreus",
        }
        for _, f in ipairs(dirs_waiting) do f(dirs) end
        dirs_waiting = {}
    end
    local function clean(o) return ((o or ""):gsub("%s+$", "")) end
    run("printenv", { "HOME" }, function(o) got.home = clean(o); finish() end)
    run("printenv", { "XDG_DATA_HOME" }, function(o) got.xdg_data = clean(o); finish() end)
    run("printenv", { "XDG_CONFIG_HOME" }, function(o) got.xdg_conf = clean(o); finish() end)
    run("printenv", { "XDG_CACHE_HOME" }, function(o) got.xdg_cache = clean(o); finish() end)
end

local function json_hex(json, key)
    return json:match('"' .. key .. '"%s*:%s*"(#%x%x%x%x%x%x)"')
end

local function apply_iris(json)
    local surface = json_hex(json, "surface") or "#1e202b"
    local bg = json_hex(json, "bg") or "#12131a"
    local accent = intensity_accent(json_hex(json, "accent") or "#94a3b8", iris_cfg.intensity)
    local fg = ensure_contrast(json_hex(json, "fg") or "#e6e6e6", surface, 4.5)
    local dim = ensure_contrast(json_hex(json, "dim") or "#a0a4ab", surface, 3.0)
    local red = ensure_contrast(json_hex(json, "red") or "#ef4444", bg, 3.0)
    -- Text on the accent: whichever of a near-black and a near-white reads better on it.
    local onmint = contrast("#10161a", accent) >= contrast("#f5f7f5", accent) and "#10161a" or "#f5f7f5"
    local pal = {
        ink = fg, faint = dim, mint = accent,
        mintlo = shade(accent, -0.10), minthi = shade(accent, 0.16),
        onmint = onmint, tint = bg, panel = surface,
        deep = blend(bg, "#000000", 0.45), off = blend(bg, fg, 0.22), alert = red,
    }
    local order = { "ink", "faint", "mint", "mintlo", "minthi", "onmint", "tint", "panel", "deep", "off", "alert" }
    local lines = {
        "//  Written by Vitreus's logic from the wallpaper (Iris); edits here are overwritten.",
        "//  `let`s only: the scene imports this and uses these names everywhere.",
        "",
        "library Palette {",
    }
    for _, k in ipairs(order) do lines[#lines + 1] = string.format("    let %-7s= %s", k, pal[k]) end
    lines[#lines + 1] = "}"
    local text_out = table.concat(lines, "\n") .. "\n"
    if text_out == iris_last_text then return end
    iris_last_text = text_out
    with_dirs(function(d)
        -- Written into the data folder, then copied over the scene's palette.
        pcall(sys.call, "files.write", "palette.plm", text_out)
        run("cp", { d.data .. "/palette.plm", d.conf .. "/palette.plm" }, function() end)
    end)
end

local function run_iris(path)
    run("iris", { "--json-only", path }, function(out, code)
        if code ~= 0 or not out then return end
        local json = out:match("%b{}")
        if json and json_hex(json, "bg") then apply_iris(json) end
    end)
end

-- The wallpaper is asked of awww every half second; when it changes, Iris is run on the new one.
local wp_on_change = function(path) end       -- the wallpaper page, further down, takes this over
local function check_wallpaper()
    run("awww", { "query" }, function(out, code)
        if code ~= 0 or not out then return end
        local path = out:match("currently displaying: image: ([^\n]+)")
        if path and path ~= iris_last_wp then
            iris_last_wp = path
            wp_on_change(path)
            if iris_cfg.enabled then run_iris(path) end
        end
    end)
end

do
    local ok, saved = pcall(sys.ask, "files.read", "iris.json", "json")
    if ok and type(saved) == "table" then
        if saved.enabled ~= nil then iris_cfg.enabled = saved.enabled and true or false end
        if saved.intensity == "subtle" or saved.intensity == "bold" or saved.intensity == "medium" then
            iris_cfg.intensity = saved.intensity
        end
    else
        pcall(sys.call, "files.write", "iris.json", iris_cfg)     -- so there is a file to edit
    end
end
-- `awww query` takes a couple of milliseconds, so a wallpaper changed from elsewhere is noticed fast.
every(500, check_wallpaper)
check_wallpaper()

-- ── Settings: the wallpaper picker ───────────────────────────────────────────────────────
-- The folder is `<Pictures>/Wallpapers` (`xdg-user-dir PICTURES`, else `$HOME/Pictures`). It is listed
-- once and shown twelve at a time: the scene only ever holds one page of thumbnails, since the folder
-- can hold hundreds of full-size images. Choosing one asks awww to fade to it; the wallpaper watcher
-- above then sees the change, which is also what re-runs Iris.
local WP_PER_PAGE = 12
local wp_files = {}
local wp_view = {}                        -- wp_files narrowed by the colour filter: what the gallery pages over
local wp_page = 0
local wp_cur = nil
local wp_dir = nil
local clock_seed = 1

sys.watch("clock", function(c)
    clock_seed = ((c.day * 24 + c.hour) * 60 + c.minute) * 60 + c.second
end)

local function wp_pages() return math.max(1, math.ceil(#wp_view / WP_PER_PAGE)) end

-- ── colour filter ──────────────────────────────────────────────────────────────────────────────────────
-- Each wallpaper is tagged with every colour it really has, not the one that covers the most. (Synoptik keeps
-- only that one, and a dark night scene with neon signs is then just "black": the red, orange and pink that
-- make it what it is never count. Counting every bucket with a few percent of the area is no better: the haze
-- and tan of a landscape then make it "orange".) ImageMagick reduces it to 32 colours, each is put in a bucket
-- (red, orange, ... black) and the areas are added up. A hue bucket is a tag when
--   · it covers a lot (15 %): a dark blue night is blue, however dim, or
--   · 3 % of the picture is VIVID in it (saturation and value both 0.4 or more): neon and flame count, haze does not;
--   · for pink only, 3 % is enough of a soft, pale magenta (saturation 0.12): a glow reads as pink at a saturation
--     where a tan would not read as orange.
-- Black, white, gray and brown, which are about area, need 5 %. Once each, in the background, kept in
-- `wallpaper-colors.json`. The filter, Random and the slideshow all work on what the filter leaves.
local WP_BUCKETS = { "red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink", "brown", "white", "gray", "black" }
local WP_TAG_SHARE = 0.03
local WP_RULE = 3                          -- which rule made the tags in the file: an older file is read again
local wp_tags = {}                        -- path -> { bucket, ... }, the biggest first
local wp_filter = nil                     -- a bucket name, or nil for every wallpaper
local wp_analysing = 0                    -- how many are still waiting to be tagged

local function wp_bucket(r, g, b)         -- 0..255 each; answers the bucket, the saturation and the value
    r, g, b = r / 255, g / 255, b / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local v, d = mx, mx - mn
    local sat = mx == 0 and 0 or d / mx
    local h = 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
    end
    local bucket
    if v < 0.16 then bucket = "black"
    elseif sat < 0.10 then bucket = v > 0.85 and "white" or "gray"
    -- brown is a dark, only moderately saturated orange; a saturated dark red still reads as red
    elseif h >= 10 and h <= 50 and v >= 0.15 and v <= 0.55 and sat >= 0.20 and sat <= 0.75 then bucket = "brown"
    elseif h < 15 or h >= 345 then bucket = "red"
    elseif h < 45 then bucket = "orange"
    elseif h < 65 then bucket = "yellow"
    elseif h < 170 then bucket = "green"
    elseif h < 200 then bucket = "cyan"
    elseif h < 255 then bucket = "blue"
    elseif h < 290 then bucket = "purple"
    else bucket = "pink" end
    return bucket, sat, v
end

local function wp_count_text()
    local n = #wp_files
    local t = wp_filter and string.format("%d of %d", #wp_view, n) or (n .. " wallpapers")
    if wp_analysing > 0 then t = t .. " · reading colours" end
    text.wp_count = t
end

local function wp_rebuild_view()
    if wp_filter then
        wp_view = {}
        for _, f in ipairs(wp_files) do
            for _, tag in ipairs(wp_tags[f] or {}) do
                if tag == wp_filter then
                    wp_view[#wp_view + 1] = f
                    break
                end
            end
        end
    else
        wp_view = wp_files
    end
    wp_count_text()
end

local wp_load_tags                        -- set below, once the analysis is defined

-- Thumbnails are cropped to exactly 16:9 by ImageMagick into a cache folder (`$XDG_CACHE_HOME/pleamar/
-- vitreus/wp`, else under `$HOME/.cache`), once each: every tile the scene draws is then the same shape and
-- size with the same corners, and a full-size wallpaper is never decoded just to fill a small tile. The
-- wallpaper in use gets a bigger crop (`p`) for the preview card. nil = not made, "busy", true, false.
local wp_made = {}
local wp_cache = nil

local function crop_path(f, kind) return wp_cache .. "/" .. (f:match("([^/]+)$") or f) .. "." .. kind .. ".jpg" end

-- Make whichever of `files` has no cropped copy yet, then call `done`.
local function wp_crop(files, kind, w, h, done)
    local todo = {}
    for _, f in ipairs(files) do
        if wp_made[crop_path(f, kind)] == nil then todo[#todo + 1] = f end
    end
    if #todo == 0 then done() return end
    local left = #todo
    for _, f in ipairs(todo) do
        local out = crop_path(f, kind)
        wp_made[out] = "busy"
        run("magick", { f .. "[0]", "-thumbnail", w .. "x" .. h .. "^", "-gravity", "center",
                        "-extent", w .. "x" .. h, "-quality", "88", out }, function(_, code)
            wp_made[out] = code == 0
            left = left - 1
            if left == 0 then done() end
        end)
    end
end

local function wp_show_page()
    local rows, sel = {}, -1
    for i = 1, WP_PER_PAGE do
        local f = wp_view[wp_page * WP_PER_PAGE + i]
        if not f then break end
        local t = crop_path(f, "t")
        rows[i] = { thumb = wp_made[t] == true and t or f }
        if f == wp_cur then sel = i - 1 end
    end
    model.wps = rows
    fact.wp_sel = sel
    text.wp_pager = string.format("%d / %d", wp_page + 1, wp_pages())
end

local function wp_refresh()
    if wp_page >= wp_pages() then wp_page = wp_pages() - 1 end
    if wp_page < 0 then wp_page = 0 end
    if not wp_cache then return end
    local page, on = wp_page, {}
    for i = 1, WP_PER_PAGE do
        local f = wp_view[wp_page * WP_PER_PAGE + i]
        if f then on[#on + 1] = f end
    end
    wp_crop(on, "t", 260, 146, function()
        if page == wp_page then wp_show_page() end
    end)
end

wp_on_change = function(path)
    wp_cur = path
    text.wp_name = path:match("([^/]+)$") or path
    if wp_cache then
        wp_crop({ path }, "p", 320, 180, function()
            if wp_cur == path then
                local pp = crop_path(path, "p")
                text.wp_curpath = wp_made[pp] == true and pp or path
            end
        end)
    else
        text.wp_curpath = path
    end
    for i, f in ipairs(wp_view) do
        if f == path then wp_page = (i - 1) // WP_PER_PAGE break end
    end
    wp_refresh()
end

local function wp_apply(path)
    run("awww", { "img", path, "--transition-type", "fade", "--transition-duration", "0.8" }, function() end)
    wp_on_change(path)
    -- The path is known: Iris starts now, while the fade plays, not when the watcher next notices the
    -- change. Marking it seen stops the watcher running it a second time.
    if iris_cfg.enabled and iris_last_wp ~= path then
        iris_last_wp = path
        run_iris(path)
    end
end

-- Tag every wallpaper that has no colour yet, three at a time so the shell stays quick.
local function wp_tags_write()
    local out = { rule = WP_RULE }
    for path, tags in pairs(wp_tags) do out[path] = tags end
    pcall(sys.call, "files.write", "wallpaper-colors.json", out)
end

local WP_NEUTRAL = { black = true, white = true, gray = true, brown = true }

local function wp_analyse_one(f, done)
    run("magick", { f .. "[0]", "-thumbnail", "100x100", "-colors", "32", "-format", "%c", "histogram:info:" }, function(out, code)
        if code == 0 and out then
            local area, vivid, soft_pink, total = {}, {}, 0, 0
            for count, r, g, b in out:gmatch("(%d+):%s*%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)") do
                local n = tonumber(count)
                local bk, sat, val = wp_bucket(tonumber(r), tonumber(g), tonumber(b))
                area[bk] = (area[bk] or 0) + n
                total = total + n
                if sat >= 0.40 and val >= 0.40 then vivid[bk] = (vivid[bk] or 0) + n end
                if bk == "pink" and sat >= 0.12 and val >= 0.25 then soft_pink = soft_pink + n end
            end
            local order = {}
            for bk in pairs(area) do order[#order + 1] = bk end
            table.sort(order, function(x, y) return area[x] > area[y] end)
            local tags = {}
            for _, bk in ipairs(order) do
                local share, live = area[bk] / total, (vivid[bk] or 0) / total
                local keep
                if WP_NEUTRAL[bk] then
                    keep = share >= 0.05
                else
                    keep = share >= 0.15 or live >= WP_TAG_SHARE or (bk == "pink" and soft_pink / total >= WP_TAG_SHARE)
                end
                if keep then tags[#tags + 1] = bk end
            end
            if #tags == 0 and order[1] then tags[1] = order[1] end
            if #tags > 0 then wp_tags[f] = tags end
        end
        done()
    end)
end

local function wp_analyse_missing()
    local todo = {}
    for _, f in ipairs(wp_files) do
        if wp_tags[f] == nil then todo[#todo + 1] = f end
    end
    wp_analysing = #todo
    wp_count_text()
    if #todo == 0 then return end
    local nexti, active, finished = 1, 0, 0
    local function pump()
        while active < 3 and nexti <= #todo do
            local f = todo[nexti]
            nexti = nexti + 1
            active = active + 1
            wp_analyse_one(f, function()
                active = active - 1
                finished = finished + 1
                wp_analysing = #todo - finished
                if finished % 8 == 0 or wp_analysing == 0 then
                    wp_tags_write()
                    if wp_filter then
                        wp_rebuild_view()
                        wp_refresh()
                    else
                        wp_count_text()
                    end
                end
                pump()
            end)
        end
    end
    pump()
end

wp_load_tags = function()
    local ok, saved = pcall(sys.ask, "files.read", "wallpaper-colors.json", "json")
    if ok and type(saved) == "table" and saved.rule == WP_RULE then
        for path, tags in pairs(saved) do
            if type(tags) == "table" then wp_tags[path] = tags end
        end
    end
    wp_rebuild_view()
    wp_analyse_missing()
end

local function wp_load()
    with_dirs(function(d)
        run("xdg-user-dir", { "PICTURES" }, function(out)
            local pics = ((out or ""):gsub("%s+$", ""))
            -- With no user-dirs config xdg-user-dir answers with the home folder itself: then it is ~/Pictures.
            if pics == "" or pics == d.home then pics = d.home .. "/Pictures" end
            wp_dir = pics .. "/Wallpapers"
            local shown = wp_dir
            if shown:sub(1, #d.home) == d.home then shown = "~" .. shown:sub(#d.home + 1) end
            text.wp_dirtext = shown
            wp_cache = d.cache
            run("mkdir", { "-p", d.cache }, function() end)
            run("ls", { "-1", wp_dir }, function(list, code)
                if code ~= 0 or not list then return end
                wp_files = {}
                for name in list:gmatch("[^\n]+") do
                    local ext = name:match("%.(%w+)$")
                    ext = ext and ext:lower()
                    if ext == "jpg" or ext == "jpeg" or ext == "png" or ext == "webp" or ext == "gif" or ext == "bmp" then
                        wp_files[#wp_files + 1] = wp_dir .. "/" .. name
                    end
                end
                wp_rebuild_view()
                if wp_cur then wp_on_change(wp_cur) else wp_refresh() end
                wp_load_tags()
            end)
        end)
    end)
end

on("wp_pick", function(i)
    local f = wp_view[wp_page * WP_PER_PAGE + i + 1]
    if f then wp_apply(f) end
end)
on("wp_prev", function()
    wp_page = wp_page - 1
    if wp_page < 0 then wp_page = wp_pages() - 1 end
    wp_refresh()
end)
on("wp_next", function()
    wp_page = wp_page + 1
    if wp_page >= wp_pages() then wp_page = 0 end
    wp_refresh()
end)
-- A random one from what the colour filter leaves, never the one already in use.
local function wp_random_pick()
    local pool = wp_view
    if #pool == 0 or (#pool == 1 and pool[1] == wp_cur) then return nil end
    math.randomseed(clock_seed)
    local f
    repeat f = pool[math.random(1, #pool)] until f ~= wp_cur
    return f
end
on("wp_random", function()
    local f = wp_random_pick()
    if f then wp_apply(f) end
end)

-- A colour swatch: filters the gallery, Random and the slideshow to it; the lit one, pressed again, clears it.
on("wp_filter_set", function(i)
    local name = WP_BUCKETS[i + 1]
    wp_filter = (name ~= nil and wp_filter ~= name) and name or nil
    fact.wp_filter = wp_filter and i or -1
    wp_page = 0
    wp_rebuild_view()
    wp_refresh()
end)

-- ── slideshow ────────────────────────────────────────────────────────────────────────────────────────
-- A timer that puts a random wallpaper (from what the filter leaves) on every so many minutes. The setting
-- is kept in `wallpaper.json`. A wallpaper change re-runs Iris, so the palette follows.
local WP_STEPS = { 1, 2, 5, 10, 15, 30, 60, 120, 240, 480 }
local wp_show, wp_mins, wp_next = false, 5, 0

local function wp_show_save()
    pcall(sys.call, "files.write", "wallpaper.json", { slideshow = wp_show, minutes = wp_mins })
end
local function wp_show_refresh()
    fact.wp_show = wp_show
    text.wp_mins_text = wp_mins < 60 and (wp_mins .. " min") or ((wp_mins // 60) .. (wp_mins == 60 and " hour" or " hours"))
    if wp_show then
        local r = math.max(0, wp_next - os.time())
        if r >= 3600 then
            text.wp_show_sub = string.format("Next change in %d:%02d:%02d", r // 3600, (r % 3600) // 60, r % 60)
        else
            text.wp_show_sub = string.format("Next change in %d:%02d", r // 60, r % 60)
        end
    else
        text.wp_show_sub = "Puts a random wallpaper on, on a timer"
    end
end

do
    local ok, saved = pcall(sys.ask, "files.read", "wallpaper.json", "json")
    if ok and type(saved) == "table" then
        wp_show = saved.slideshow == true
        if type(saved.minutes) == "number" and saved.minutes >= 1 then wp_mins = saved.minutes end
    end
    if wp_show then wp_next = os.time() + wp_mins * 60 end
    wp_show_refresh()
end

on("wp_show_toggle", function()
    wp_show = not wp_show
    if wp_show then wp_next = os.time() + wp_mins * 60 end
    wp_show_save()
    wp_show_refresh()
end)
-- The interval's stepper: the next value up or down a short list (a minute, ... eight hours).
on("wp_mins_step", function(d)
    local at = 1
    for i, m in ipairs(WP_STEPS) do
        if m <= wp_mins then at = i end
    end
    wp_mins = WP_STEPS[math.max(1, math.min(#WP_STEPS, at + d))]
    if wp_show then wp_next = os.time() + wp_mins * 60 end
    wp_show_save()
    wp_show_refresh()
end)
every(1000, function()
    if not wp_show then return end
    if os.time() >= wp_next then
        wp_next = os.time() + wp_mins * 60
        local f = wp_random_pick()
        if f then wp_apply(f) end
    end
    wp_show_refresh()
end)

wp_load()

-- ── glass ─────────────────────────────────────────────────────────────────────────────────────────────
-- The Glass page's two sliders. `frost` is how much of the glass effect the bar and the drawers have (their
-- tint, the edge light, and whether the compositor is asked to blur what is behind: below 30 % it is not; at 0
-- they are solid); `opacity` is how solid they are, from 30 % to 100 %. Both are numbers from 0 to 1 that the
-- scene reads, kept in `glass.json` a moment after the last change so a drag does not write a file per pixel.
local glass = { frost = 1, opacity = 1 }
local GLASS_OP_MIN = 0.3
local glass_save_waiting = false

local function glass_refresh()
    fact.glass_frost = glass.frost
    fact.glass_op = glass.opacity
    text.glass_frost_text = string.format("%d%%", math.floor(glass.frost * 100 + 0.5))
    text.glass_op_text = string.format("%d%%", math.floor(glass.opacity * 100 + 0.5))
end
local function glass_save_soon()
    if glass_save_waiting then return end
    glass_save_waiting = true
    after(500, function()
        glass_save_waiting = false
        pcall(sys.call, "files.write", "glass.json", { frost = glass.frost, opacity = glass.opacity })
    end)
end

do
    local ok, saved = pcall(sys.ask, "files.read", "glass.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.frost) == "number" then glass.frost = math.max(0, math.min(1, saved.frost)) end
        if type(saved.opacity) == "number" then glass.opacity = math.max(GLASS_OP_MIN, math.min(1, saved.opacity)) end
    end
    glass_refresh()
end

on("glass_frost_set", function(t)
    glass.frost = math.floor(math.max(0, math.min(1, t)) * 100 + 0.5) / 100
    glass_refresh()
    glass_save_soon()
end)
on("glass_op_set", function(t)
    local v = GLASS_OP_MIN + (1 - GLASS_OP_MIN) * math.max(0, math.min(1, t))
    glass.opacity = math.floor(v * 100 + 0.5) / 100
    glass_refresh()
    glass_save_soon()
end)
on("glass_reset", function()
    glass.frost, glass.opacity = 1, 1
    glass_refresh()
    glass_save_soon()
end)

-- ── Weather, for the calendar panel ──────────────────────────────────────────────────────
-- Fetched from Open-Meteo, as in Synoptik: the place is found by IP (ipwho.is) unless `location` is set
-- in `weather-config.json` in Vitreus's data folder, when it is looked up by name; then the current
-- conditions and the next seven days. `units` there is "fahrenheit" (the default) or "celsius".
-- The sandbox has no JSON parser for what curl brings, so curl writes each answer into the data folder
-- and `files.read` parses it.
local wx_cfg = { location = "", units = "fahrenheit" }
local wx_loc = nil                        -- { lat, lon }
local wx_busy = false
local WX_DESC = {
    [0] = "Clear sky", [1] = "Mainly clear", [2] = "Partly cloudy", [3] = "Overcast",
    [45] = "Foggy", [48] = "Rime fog", [51] = "Light drizzle", [53] = "Drizzle", [55] = "Dense drizzle",
    [56] = "Freezing drizzle", [57] = "Freezing drizzle", [61] = "Slight rain", [63] = "Rain", [65] = "Heavy rain",
    [66] = "Freezing rain", [67] = "Freezing rain", [71] = "Light snow", [73] = "Snow", [75] = "Heavy snow",
    [77] = "Snow grains", [80] = "Light showers", [81] = "Showers", [82] = "Violent showers",
    [85] = "Snow showers", [86] = "Heavy snow showers", [95] = "Thunderstorm", [96] = "Thunderstorm, hail",
    [99] = "Severe thunderstorm",
}
local WX_DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

-- 0 clear · 1 partly cloudy · 2 cloud · 3 fog · 4 rain · 5 snow · 6 storm
local function wx_kind(code)
    if code == 0 then return 0 end
    if code == 1 or code == 2 then return 1 end
    if code == 3 then return 2 end
    if code == 45 or code == 48 then return 3 end
    if (code >= 51 and code <= 67) or (code >= 80 and code <= 82) then return 4 end
    if (code >= 71 and code <= 77) or code == 85 or code == 86 then return 5 end
    if code >= 95 then return 6 end
    return 2
end

local function wx_round(x) return math.floor(x + 0.5) end
local function urlenc(s) return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)) end

local function wx_show(w)
    if type(w) ~= "table" or type(w.current) ~= "table" or type(w.daily) ~= "table" then return false end
    local sym = wx_cfg.units == "celsius" and "°C" or "°F"
    local code = w.current.weather_code or 3
    text.wx_temp = wx_round(w.current.temperature_2m or 0) .. sym
    text.wx_desc = WX_DESC[code] or "—"
    fact.wx_kind = wx_kind(code)
    local rows = {}
    local dd = w.daily
    for i = 1, math.min(7, #(dd.time or {})) do
        local y, m, d = dd.time[i]:match("^(%d+)-(%d+)-(%d+)$")
        local label = "—"
        if y then
            local wd = os.date("*t", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })).wday
            label = WX_DAYS[wd]
        end
        rows[i] = {
            label = label, kind = wx_kind(dd.weather_code[i] or 3),
            hi = wx_round(dd.temperature_2m_max[i]) .. "°", lo = wx_round(dd.temperature_2m_min[i]) .. "°",
            today = i == 1,
        }
    end
    model.wx_days = rows
    fact.wx_ok = true
    return true
end

local function wx_read(name)
    local ok, v = pcall(sys.ask, "files.read", name, "json")
    if ok and type(v) == "table" then return v end
    return nil
end

local function wx_done(ok)
    wx_busy = false
    if not ok then after(60000, function() if not wx_busy then wx_refresh_now() end end) end
end

local function wx_forecast(d)
    local unit = wx_cfg.units == "celsius" and "celsius" or "fahrenheit"
    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. wx_loc.lat .. "&longitude=" .. wx_loc.lon
        .. "&current=temperature_2m,weather_code&daily=weather_code,temperature_2m_max,temperature_2m_min"
        .. "&temperature_unit=" .. unit .. "&timezone=auto&forecast_days=7"
    run("curl", { "-s", "-L", "--max-time", "10", "-o", d.data .. "/wx.json", url }, function(_, code)
        wx_done(code == 0 and wx_show(wx_read("wx.json")))
    end)
end

function wx_refresh_now()
    if wx_busy then return end
    wx_busy = true
    with_dirs(function(d)
        if wx_loc then wx_forecast(d) return end
        local loc = wx_cfg.location
        local url = loc ~= "" and ("https://geocoding-api.open-meteo.com/v1/search?name=" .. urlenc(loc) .. "&count=1&format=json")
            or "https://ipwho.is/"
        run("curl", { "-s", "-L", "--max-time", "10", "-o", d.data .. "/wx-loc.json", url }, function(_, code)
            local r = code == 0 and wx_read("wx-loc.json") or nil
            local lat, lon
            if r and loc ~= "" and type(r.results) == "table" and r.results[1] then
                lat, lon = r.results[1].latitude, r.results[1].longitude
            elseif r and loc == "" and r.success then
                lat, lon = r.latitude, r.longitude
            end
            if lat and lon then
                wx_loc = { lat = lat, lon = lon }
                wx_forecast(d)
            else
                wx_done(false)
            end
        end)
    end)
end

do
    local ok, saved = pcall(sys.ask, "files.read", "weather-config.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.location) == "string" then wx_cfg.location = saved.location end
        if saved.units == "celsius" or saved.units == "fahrenheit" then wx_cfg.units = saved.units end
    else
        pcall(sys.call, "files.write", "weather-config.json", wx_cfg)   -- so there is a file to edit
    end
    wx_show(wx_read("wx.json"))          -- what was fetched last time, while the new answer is on its way
end
wx_refresh_now()
every(1800000, wx_refresh_now)           -- every half hour
