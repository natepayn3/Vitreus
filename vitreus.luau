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
    -- `mine` is this run of cava: one that was asked to stop can still print a last line, and its exit can arrive
    -- after a new one has started, so neither may touch what the new one is doing.
    local mine
    mine = spawn("cava", { "-p", cava_conf }, function(line)
        if cava ~= mine then return end
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
    end, function() if cava == mine then cava = nil end end)
    cava = mine
end

local function hush()
    want_listen = false
    -- Asked to stop, not killed: pleamar only collects (wait()s for) a process that leaves by itself, so a plain
    -- `kill` leaves a zombie behind every time (measured: 22 of them after less than an hour).
    if cava then kill(cava, "term"); cava = nil end
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
    local working = false
    for _, r in ipairs(rows) do if r.busy == 1 or r.busy == 2 then working = true end end
    fact.bt_working = working
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
-- A wallpaper that Vitreus sets is known at once (see `wp_apply`); this is only for one changed from elsewhere, so it
-- does not need to look often. Every look starts a program (`awww query`): twice a second was most of what the shell
-- launched while doing nothing.
every(2000, check_wallpaper)
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

local function wp_apply(path, how)
    -- `how`: awww's transition flags. The galaxy asks for a bloom from the bead that was pressed.
    local args = { "img", path }
    for _, a in ipairs(how or { "--transition-type", "fade", "--transition-duration", "0.8" }) do args[#args + 1] = a end
    run("awww", args, function() end)
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
-- they are solid); `opacity` is how solid they are, from 30 % to 100 % (its track is 0 to 100 %, the first 30 %
-- of it shaded). Both are numbers from 0 to 1 that the
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
    -- the track is 0 to 100 %, like the Glass one; a press in the shaded first 30 % gives the least it can be
    local v = math.max(GLASS_OP_MIN, math.min(1, t))
    glass.opacity = math.floor(v * 100 + 0.5) / 100
    glass_refresh()
    glass_save_soon()
end)
on("glass_reset", function()
    glass.frost, glass.opacity = 1, 1
    glass_refresh()
    glass_save_soon()
end)

-- ── Display ───────────────────────────────────────────────────────────────────────────────────────────
-- The Display page of the settings, after Synoptik's: what Hyprland reports for each monitor (`hyprctl monitors -j`)
-- is read into a DRAFT that the page edits (the mode, its position, scale, rotation and the SDR levels), and
-- Apply sends it to Hyprland with `hyprctl eval` (`hl.monitor{…}`, since this Hyprland reads a Lua config).
-- A change to how the screen looks can leave you with a screen you cannot read, so an applied change is on trial
-- for 15 seconds: Keep makes it stay (and writes it to `vitreus_monitors.lua`, which `hyprland.lua` loads, so it
-- survives a restart), and anything else, including not answering, puts back what was there.
-- (In a block of its own: the file is at Luau's limit of 200 locals in one scope, and this section's are its own.)
do
local DISP_SCALES = { "auto", 1.0, 1.25, 1.333333, 1.5, 1.75, 2.0 }
local DISP_TRIAL = 15
local disp_mons = {}                      -- what Hyprland says: { name, desc, key, w, h, hz, x, y, scale, transform, modes, sdrb, sdrs }
local disp_draft = {}                     -- name -> { res, hz, x, y, scale, transform, sdrb, sdrs }: what the page edits
local disp_saved = {}                     -- name -> the spec last kept, for monitors that are not connected now too
local disp_profiles = {}                  -- { name, key, mons = { name -> spec } }
local disp_auto = true
local disp_sel = 1
local disp_key_seen = nil                 -- the set of connected displays the last time it was looked at
local disp_trial = 0                      -- seconds left of a change on trial; 0 for none
local disp_before = nil                   -- the eval that puts back what a change on trial replaced
local disp_grab = nil                     -- a monitor being dragged on the canvas: { i, dx, dy } in canvas pixels
local disp_grab_scale, disp_grab_origin = 1, nil   -- how the canvas maps to the desk: set each time it is drawn

local function disp_num(n, d) return (string.format("%." .. (d or 2) .. "f", n):gsub("0+$", ""):gsub("%.$", "")) end

-- A display is told apart by what it is and not by its name, which is only the order it was plugged in: make,
-- model and serial when there are, else its description, else its name.
local function disp_key_of(m)
    local serial, make, model = m.serial or "", m.make or "", m.model or ""
    if serial ~= "" and model ~= "" then return make .. "|" .. model .. "|" .. serial end
    if (m.description or "") ~= "" then return "desc:" .. m.description end
    return "name:" .. (m.name or "?")
end

-- "3440x1440@59.999" or "3440x1440@60.00Hz" -> "3440x1440", 60
local function disp_parse_mode(str)
    local w, h, hz = str:match("^(%d+)x(%d+)@([%d%.]+)")
    if not w then return nil end
    return w .. "x" .. h, math.floor(tonumber(hz) + 0.5)
end

local function disp_rotated(t) return t == 1 or t == 3 or t == 5 or t == 7 end
local function disp_size(m, d)            -- the size on the desk: the mode, turned if it is rotated, and shrunk by the scale
    local w, h = tonumber((d.res or ""):match("^(%d+)")) or m.w, tonumber((d.res or ""):match("x(%d+)$")) or m.h
    if disp_rotated(d.transform or 0) then w, h = h, w end
    -- Hyprland lays the monitors out in scaled pixels: a 1920 x 1080 one at scale 2 takes 960 x 540 of the desk
    local scale = d.scale == "auto" and m.scale or d.scale or 1
    return math.floor(w / scale + 0.5), math.floor(h / scale + 0.5)
end

-- The resolutions a monitor offers, biggest first, and for each the refresh rates it has.
local function disp_options(m)
    local by, order = {}, {}
    for _, mode in ipairs(m.modes) do
        local res, hz = disp_parse_mode(mode)
        if res then
            if not by[res] then
                by[res] = {}
                order[#order + 1] = res
            end
            local seen = false
            for _, v in ipairs(by[res]) do if v == hz then seen = true end end
            if not seen then by[res][#by[res] + 1] = hz end
        end
    end
    table.sort(order, function(a, b)
        local aw, ah = a:match("^(%d+)x(%d+)")
        local bw, bh = b:match("^(%d+)x(%d+)")
        return tonumber(aw) * tonumber(ah) > tonumber(bw) * tonumber(bh)
    end)
    for _, res in ipairs(order) do table.sort(by[res], function(a, b) return a > b end) end
    return order, by
end

-- The code that tells Hyprland how a set of monitors is to be.
local function disp_spec_code(specs)
    local parts = {}
    for name, d in pairs(specs) do
        local scale = d.scale == "auto" and '"auto"' or disp_num(d.scale, 6)
        parts[#parts + 1] = string.format(
            'hl.monitor({ output = "%s", mode = "%s@%d", position = "%dx%d", scale = %s, transform = %d, sdrbrightness = %s, sdrsaturation = %s })',
            name, d.res, d.hz, d.x, d.y, scale, d.transform or 0, disp_num(d.sdrb or 1, 2), disp_num(d.sdrs or 1, 2))
    end
    table.sort(parts)
    return table.concat(parts, "\n")
end

local function disp_spec_of(m)            -- what a monitor is at this moment, as a spec
    local res = m.w .. "x" .. m.h
    return { res = res, hz = math.floor(m.hz + 0.5), x = m.x, y = m.y, scale = m.scale, transform = m.transform,
             sdrb = m.sdrb, sdrs = m.sdrs }
end

local function disp_copy(d)
    local c = {}
    for k, v in pairs(d) do c[k] = v end
    return c
end

local function disp_changed(m, d)
    local cur = disp_spec_of(m)
    return cur.res ~= d.res or cur.hz ~= d.hz or cur.x ~= d.x or cur.y ~= d.y or math.abs(cur.scale - (d.scale == "auto" and cur.scale or d.scale)) > 0.001
        or d.scale == "auto" or cur.transform ~= d.transform or math.abs((cur.sdrb or 1) - (d.sdrb or 1)) > 0.004
        or math.abs((cur.sdrs or 1) - (d.sdrs or 1)) > 0.004
end

-- What the page shows: the canvas (each monitor a box, all fitted into 400 x 118), the rows of choices for the
-- monitor that is selected, and how far its draft is from what is on the screen.
local function disp_render()
    local n = #disp_mons
    fact.disp_count = n
    if disp_sel > n then disp_sel = math.max(1, n) end
    fact.disp_sel = disp_sel - 1
    local dirty = false
    for _, m in ipairs(disp_mons) do
        if disp_changed(m, disp_draft[m.name]) then dirty = true end
    end
    fact.disp_dirty = dirty
    if n == 0 then
        text.disp_title, text.disp_desc, text.disp_cur = "No monitor", "", ""
        for i = 0, 3 do fact["disp_b." .. i .. ".on"] = false end
        for i = 0, 5 do fact["disp_hz." .. i .. ".on"] = false end
        for i = 0, 13 do fact["disp_r." .. i .. ".on"] = false end
        fact.disp_res_count = 0
        return
    end
    -- the canvas
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, m in ipairs(disp_mons) do
        local d = disp_draft[m.name]
        local w, h = disp_size(m, d)
        x0, y0 = math.min(x0, d.x), math.min(y0, d.y)
        x1, y1 = math.max(x1, d.x + w), math.max(y1, d.y + h)
    end
    local cw, ch, pad = 400, 96, 12
    local f = math.min((cw - 2 * pad) / math.max(1, x1 - x0), (ch - 2 * pad) / math.max(1, y1 - y0))
    local ox = (cw - (x1 - x0) * f) / 2
    local oy = (ch - (y1 - y0) * f) / 2
    for i = 0, 3 do
        local m = disp_mons[i + 1]
        if not m then
            fact["disp_b." .. i .. ".on"] = false
        else
            local d = disp_draft[m.name]
            local w, h = disp_size(m, d)
            fact["disp_b." .. i .. ".on"] = true
            fact["disp_b." .. i .. ".x"] = ox + (d.x - x0) * f
            fact["disp_b." .. i .. ".y"] = oy + (d.y - y0) * f
            fact["disp_b." .. i .. ".w"] = math.max(14, w * f)
            fact["disp_b." .. i .. ".h"] = math.max(10, h * f)
            fact["disp_b." .. i .. ".sel"] = i + 1 == disp_sel
            fact["disp_b." .. i .. ".dirty"] = disp_changed(m, d)
            text["disp_b." .. i .. ".name"] = m.name
            text["disp_b." .. i .. ".mode"] = d.res:gsub("x", " × ") .. " · " .. d.hz .. " Hz"
        end
    end
    disp_grab_scale = f
    disp_grab_origin = { x0 = x0, y0 = y0, ox = ox, oy = oy }
    -- the selected monitor
    local m = disp_mons[disp_sel]
    local d = disp_draft[m.name]
    text.disp_title = m.name
    text.disp_desc = m.desc ~= "" and m.desc or "Unknown display"
    text.disp_cur = string.format("On now: %dx%d @ %d Hz · scale %s%s", m.w, m.h, math.floor(m.hz + 0.5), disp_num(m.scale, 2),
        m.transform ~= 0 and (" · turned " .. (m.transform % 4) * 90 .. "°") or "")
    local order, by = disp_options(m)
    text.disp_res_text = (d.res:gsub("x", " × "))
    -- the dropdown's options, biggest first (at most 14)
    fact.disp_res_count = math.min(#order, 14)
    local longest = 0
    for i = 1, math.min(#order, 14) do longest = math.max(longest, #(order[i]:gsub("x", " × "))) end
    fact.disp_res_chars = longest
    for i = 0, 13 do
        local r = order[i + 1]
        fact["disp_r." .. i .. ".on"] = r ~= nil
        fact["disp_r." .. i .. ".lit"] = r ~= nil and r == d.res
        text["disp_r." .. i .. ".text"] = r and (r:gsub("x", " × ")) or ""
    end
    local hzs = by[d.res] or {}
    for i = 0, 5 do
        local hz = hzs[i + 1]
        fact["disp_hz." .. i .. ".on"] = hz ~= nil
        fact["disp_hz." .. i .. ".lit"] = hz ~= nil and hz == d.hz
        text["disp_hz." .. i .. ".text"] = hz and (hz .. " Hz") or ""
    end
    -- the monitors, for the inspector's pills
    for i = 0, 3 do
        local mm = disp_mons[i + 1]
        fact["disp_pill." .. i .. ".on"] = mm ~= nil and n > 1
        text["disp_pill." .. i .. ".text"] = mm and mm.name or ""
    end
    local si = 0
    for i, v in ipairs(DISP_SCALES) do
        if (d.scale == "auto" and v == "auto") or (v ~= "auto" and d.scale ~= "auto" and math.abs(v - d.scale) < 0.02) then si = i end
    end
    fact.disp_scale = si - 1
    fact.disp_rot = (d.transform or 0) < 4 and (d.transform or 0) or -1
    fact.disp_sdrb = d.sdrb or 1
    fact.disp_sdrs = d.sdrs or 1
    text.disp_sdrb_text = disp_num(d.sdrb or 1, 2)
    text.disp_sdrs_text = disp_num(d.sdrs or 1, 2)
    -- the topology and the profiles
    local keys = {}
    for _, mm in ipairs(disp_mons) do keys[#keys + 1] = mm.key end
    table.sort(keys)
    local names = {}
    for _, mm in ipairs(disp_mons) do names[#names + 1] = mm.name end
    text.disp_topo = table.concat(names, " + ")
    local current = table.concat(keys, " + ")
    for i = 0, 3 do
        local p = disp_profiles[i + 1]
        fact["disp_p." .. i .. ".on"] = p ~= nil
        if p then
            local pn = {}
            for name in pairs(p.mons) do pn[#pn + 1] = name end
            table.sort(pn)
            text["disp_p." .. i .. ".name"] = p.name
            text["disp_p." .. i .. ".sub"] = table.concat(pn, " + ")
            fact["disp_p." .. i .. ".active"] = p.key == current
        end
    end
    fact.disp_auto = disp_auto
    fact.disp_pcount = math.min(#disp_profiles, 4)
end

local function disp_profiles_save()
    pcall(sys.call, "files.write", "display-profiles.json", { auto = disp_auto, profiles = disp_profiles })
end

-- Read what Hyprland says, and keep the draft of every monitor that is there.
local function disp_read(done)
    run("hyprctl", { "monitors", "-j" }, function(out, code)
        if code ~= 0 or not out then return done and done() end
        local ok, list = pcall(json.decode, out)
        if not ok or type(list) ~= "table" then return done and done() end
        local mons = {}
        for _, j in ipairs(list) do
            local modes = {}
            for _, mode in ipairs(j.availableModes or {}) do modes[#modes + 1] = mode end
            mons[#mons + 1] = {
                name = j.name, desc = j.description or "", key = disp_key_of(j), w = j.width, h = j.height, hz = j.refreshRate or 60,
                x = j.x, y = j.y, scale = j.scale or 1, transform = j.transform or 0, modes = modes,
                sdrb = j.sdrBrightness or 1, sdrs = j.sdrSaturation or 1,
            }
        end
        disp_mons = mons
        local fresh = {}
        for _, m in ipairs(mons) do
            -- a draft that is untouched follows the screen; one being edited is left alone
            local d = disp_draft[m.name]
            if not d or not disp_changed(m, d) then fresh[m.name] = disp_spec_of(m) else fresh[m.name] = d end
        end
        disp_draft = fresh
        disp_render()
        if done then done() end
    end)
end

-- The file `hyprland.lua` loads: every monitor that has been kept, connected or not.
local function disp_write_file()
    local lines = {
        "-- Written by Vitreus (Settings > Display); edits here are overwritten.",
        "-- hyprland.lua loads it after hypr_style.lua, so it wins for the monitors it names.",
    }
    local names = {}
    for name in pairs(disp_saved) do names[#names + 1] = name end
    table.sort(names)
    local specs = {}
    for _, name in ipairs(names) do specs[name] = disp_saved[name] end
    lines[#lines + 1] = disp_spec_code(specs)
    local body = table.concat(lines, "\n") .. "\n"
    with_dirs(function(d)
        pcall(sys.call, "files.write", "vitreus_monitors.lua", body)
        local hypr = d.conf:gsub("/pleamar/shells/vitreus$", "/hypr")
        run("cp", { "-f", d.data .. "/vitreus_monitors.lua", hypr .. "/vitreus_monitors.lua" }, function() end)
        pcall(sys.call, "files.write", "display.json", { saved = disp_saved })
    end)
end

local function disp_specs_now()           -- what the screens are, as specs: to put back
    local specs = {}
    for _, m in ipairs(disp_mons) do specs[m.name] = disp_spec_of(m) end
    return specs
end

-- Sends specs to Hyprland; answers whether it took them.
local function disp_send(specs, then_)
    run("hyprctl", { "eval", disp_spec_code(specs) }, function(out, code)
        local ok = code == 0 and (out or ""):match("^%s*ok") ~= nil
        if not ok then text.disp_msg = "Hyprland did not take it: " .. ((out or ""):gsub("%s+$", "")) end
        after(900, function() disp_read(function() then_(ok) end) end)
    end)
end

local function disp_trial_text()
    text.disp_trial_text = string.format("Keep these display settings? Putting them back in %d s", disp_trial)
end

local function disp_keep()
    disp_trial, disp_before = 0, nil
    fact.disp_trial = 0
    for _, m in ipairs(disp_mons) do
        disp_saved[m.name] = disp_spec_of(m)
        disp_draft[m.name] = disp_spec_of(m)
    end
    disp_render()
    disp_write_file()
    text.disp_msg = "Kept, and saved for the next start."
end

local function disp_revert()
    if not disp_before then return end
    local before = disp_before
    disp_trial, disp_before = 0, nil
    fact.disp_trial = 0
    disp_send(before, function()
        for _, m in ipairs(disp_mons) do disp_draft[m.name] = disp_spec_of(m) end
        disp_render()
        text.disp_msg = "Put back."
    end)
end

local function disp_apply()
    if disp_trial > 0 then return end
    local specs = {}
    -- every position is measured from the top left of the whole arrangement
    local mx, my = math.huge, math.huge
    for _, m in ipairs(disp_mons) do
        local d = disp_draft[m.name]
        mx, my = math.min(mx, d.x), math.min(my, d.y)
    end
    for _, m in ipairs(disp_mons) do
        local d = disp_copy(disp_draft[m.name])
        d.x, d.y = d.x - mx, d.y - my
        -- only what is different from what is on the screen is sent: a monitor that was not touched is not told anything
        if disp_changed(m, d) then specs[m.name] = d end
    end
    if next(specs) == nil then
        text.disp_msg = "Nothing to change."
        return
    end
    disp_before = {}
    for name in pairs(specs) do
        for _, m in ipairs(disp_mons) do
            if m.name == name then disp_before[name] = disp_spec_of(m) end
        end
    end
    text.disp_msg = "Applying…"
    disp_send(specs, function(ok)
        if not ok then
            disp_before = nil
            return
        end
        disp_trial = DISP_TRIAL
        fact.disp_trial = DISP_TRIAL
        disp_trial_text()
        text.disp_msg = ""
    end)
end

every(1000, function()
    if disp_trial <= 0 then return end
    disp_trial = disp_trial - 1
    fact.disp_trial = disp_trial
    if disp_trial <= 0 then
        disp_revert()
    else
        disp_trial_text()
    end
end)

-- ── the page's events ──
local function disp_edit(fn)
    local m = disp_mons[disp_sel]
    if not m then return end
    fn(m, disp_draft[m.name])
    disp_render()
end
on("disp_pick_mon", function(i) disp_sel = math.max(1, math.min(#disp_mons, i + 1)); disp_render() end)
on("disp_pick_res", function(i)
    disp_edit(function(m, d)
        local order, by = disp_options(m)
        local res = order[i + 1]
        if not res then return end
        d.res = res
        -- keep the refresh rate if the new resolution has it, else the highest
        local has = false
        for _, hz in ipairs(by[res]) do if hz == d.hz then has = true end end
        if not has then d.hz = by[res][1] end
    end)
end)
on("disp_pick_hz", function(i)
    disp_edit(function(m, d)
        local _, by = disp_options(m)
        local hz = (by[d.res] or {})[i + 1]
        if hz then d.hz = hz end
    end)
end)
on("disp_pick_scale", function(i) disp_edit(function(_, d) d.scale = DISP_SCALES[i + 1] or d.scale end) end)
on("disp_pick_rot", function(i) disp_edit(function(_, d) d.transform = i end) end)
-- The sliders: SDR brightness from 1.0 to 2.0, saturation from 0.9 to 1.1, in hundredths.
on("disp_sdrb_set", function(t) disp_edit(function(_, d) d.sdrb = math.floor((1 + math.max(0, math.min(1, t))) * 100 + 0.5) / 100 end) end)
on("disp_sdrs_set", function(t) disp_edit(function(_, d) d.sdrs = math.floor((0.9 + 0.2 * math.max(0, math.min(1, t))) * 100 + 0.5) / 100 end) end)
on("disp_apply", disp_apply)
on("disp_keep", disp_keep)
on("disp_revert", disp_revert)
on("disp_reset", function()
    for _, m in ipairs(disp_mons) do disp_draft[m.name] = disp_spec_of(m) end
    disp_render()
end)
on("disp_refresh", function() disp_read() end)

-- Dragging a monitor on the canvas: the page says where the pointer is (canvas units, in `fact.disp_px/py`) when it
-- grabs a box and as it moves; the box keeps the distance it was grabbed at, and snaps to the edges of the others.
on("disp_grab", function()
    local i = fact.disp_grab_i + 1
    local m = disp_mons[i]
    if not m or not disp_grab_origin then return end
    disp_sel = i
    local d = disp_draft[m.name]
    local f, o = disp_grab_scale, disp_grab_origin
    disp_grab = { i = i, dx = fact.disp_px - (o.ox + (d.x - o.x0) * f), dy = fact.disp_py - (o.oy + (d.y - o.y0) * f) }
    disp_render()
end)
on("disp_drag", function()
    if not disp_grab or not disp_grab_origin then return end
    local m = disp_mons[disp_grab.i]
    if not m then return end
    local d = disp_draft[m.name]
    local f, o = disp_grab_scale, disp_grab_origin
    local x = o.x0 + (fact.disp_px - disp_grab.dx - o.ox) / f
    local y = o.y0 + (fact.disp_py - disp_grab.dy - o.oy) / f
    local w, h = disp_size(m, d)
    local snap = 40 / f * 0.4              -- a few canvas pixels, in real ones
    for _, other in ipairs(disp_mons) do
        if other ~= m then
            local od = disp_draft[other.name]
            local ow, oh = disp_size(other, od)
            -- edge to edge, and lined up on the other axis
            local xs = { od.x + ow, od.x - w, od.x, od.x + ow - w }
            local ys = { od.y + oh, od.y - h, od.y, od.y + oh - h }
            for _, c in ipairs(xs) do if math.abs(x - c) < snap then x = c end end
            for _, c in ipairs(ys) do if math.abs(y - c) < snap then y = c end end
        end
    end
    d.x, d.y = math.floor(x + 0.5), math.floor(y + 0.5)
    disp_render()
end)
on("disp_drop", function() disp_grab = nil end)
-- Buttons over the canvas: side by side, or the two swapped.
on("disp_arrange", function()
    local x = 0
    for _, m in ipairs(disp_mons) do
        local d = disp_draft[m.name]
        local w = disp_size(m, d)
        d.x, d.y = x, 0
        x = x + w
    end
    disp_render()
end)
on("disp_swap", function()
    -- the order left to right, turned round, and packed side by side again
    if #disp_mons < 2 then return end
    local order = {}
    for _, m in ipairs(disp_mons) do order[#order + 1] = m end
    table.sort(order, function(a, b) return disp_draft[a.name].x < disp_draft[b.name].x end)
    local x = 0
    for i = #order, 1, -1 do
        local d = disp_draft[order[i].name]
        local w = disp_size(order[i], d)
        d.x, d.y = x, 0
        x = x + w
    end
    disp_render()
end)

-- ── profiles ──
local function disp_topology_key()
    local keys = {}
    for _, m in ipairs(disp_mons) do keys[#keys + 1] = m.key end
    table.sort(keys)
    return table.concat(keys, " + ")
end
on("disp_profile_save", function()
    if #disp_mons == 0 then return end
    local key = disp_topology_key()
    local specs = {}
    for _, m in ipairs(disp_mons) do specs[m.name] = disp_spec_of(m) end
    -- a set of displays has one profile: saving again replaces it
    for i, p in ipairs(disp_profiles) do
        if p.key == key then table.remove(disp_profiles, i) break end
    end
    local name = ((text.disp_profile_name or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if name == "" then name = "Profile " .. (#disp_profiles + 1) end
    table.insert(disp_profiles, 1, { name = name, key = key, mons = specs })
    while #disp_profiles > 6 do table.remove(disp_profiles) end
    text.disp_profile_name = ""
    disp_profiles_save()
    disp_render()
    text.disp_msg = "Saved “" .. name .. "”."
end)
on("disp_profile_apply", function(i)
    local p = disp_profiles[i + 1]
    if not p then return end
    for name, spec in pairs(p.mons) do
        if disp_draft[name] then disp_draft[name] = disp_copy(spec) end
    end
    disp_render()
    disp_apply()
end)
on("disp_profile_delete", function(i)
    table.remove(disp_profiles, i + 1)
    disp_profiles_save()
    disp_render()
end)
on("disp_auto_toggle", function()
    disp_auto = not disp_auto
    disp_profiles_save()
    fact.disp_auto = disp_auto
end)

-- Plugging a display in or out: the set of displays that is there changes, and if a profile was saved for exactly
-- that set (and automatic arrangement is on) it is put on, without the trial: it is one the user has already kept.
local function disp_watch()
    disp_read(function()
        local key = disp_topology_key()
        if disp_key_seen ~= nil and key ~= disp_key_seen and disp_auto and disp_trial <= 0 then
            for _, p in ipairs(disp_profiles) do
                if p.key == key then
                    local specs = {}
                    for name, spec in pairs(p.mons) do
                        if disp_draft[name] then specs[name] = disp_copy(spec) end
                    end
                    disp_key_seen = key
                    disp_send(specs, function() text.disp_msg = "Put on the profile “" .. p.name .. "”." end)
                    return
                end
            end
        end
        disp_key_seen = key
    end)
end

do
    local ok, saved = pcall(sys.ask, "files.read", "display-profiles.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.auto) == "boolean" then disp_auto = saved.auto end
        if type(saved.profiles) == "table" then disp_profiles = saved.profiles end
    end
    local ok2, kept = pcall(sys.ask, "files.read", "display.json", "json")
    if ok2 and type(kept) == "table" and type(kept.saved) == "table" then disp_saved = kept.saved end
end
disp_read()
every(5000, function() if disp_trial <= 0 and disp_grab == nil then disp_watch() end end)
end

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

-- ── Settings > Hyprland ───────────────────────────────────────────────────────────────────────────────────────
-- Window-manager knobs after Synoptik's: layout, gaps, border resize, tearing, animations and input. The values
-- shown are what Hyprland says now. A change is sent with `hyprctl eval` at once, and once it has settled it is
-- written to vitreus_hypr.lua, which hyprland.lua loads after hypr_style.lua so it wins on the next start.
do
    local LAYOUTS = { "dwindle", "master", "scrolling" }
    local hy = { layout = 3, gaps = 5, resize = false, tear = false, anim = true, sens = 0, follow = 1, nat = false }
    local hy_dirty, hy_waiting = false, false

    local function hy_show()
        fact.hy_layout = hy.layout
        fact.hy_gaps = hy.gaps
        fact.hy_resize = hy.resize
        fact.hy_tear = hy.tear
        fact.hy_anim = hy.anim
        fact.hy_sens = hy.sens
        fact.hy_follow = hy.follow
        fact.hy_nat = hy.nat
        text.hy_gaps_text = string.format("%d px", hy.gaps)
        text.hy_sens_text = string.format("%.2f", hy.sens)
    end

    local function b(v) return v and "true" or "false" end
    local function hy_code()
        return string.format(
            "hl.config({ general = { gaps_in = %d, layout = \"%s\", resize_on_border = %s, allow_tearing = %s }, " ..
            "animations = { enabled = %s }, input = { sensitivity = %.2f, follow_mouse = %d, touchpad = { natural_scroll = %s } } })",
            hy.gaps, LAYOUTS[hy.layout], b(hy.resize), b(hy.tear), b(hy.anim), hy.sens, hy.follow, b(hy.nat))
    end

    local function hy_write_file()
        local body = "-- Written by Vitreus (Settings > Hyprland); edits here are overwritten.\n" ..
            "-- hyprland.lua loads it after hypr_style.lua, so it wins over the values there.\n" .. hy_code() .. "\n"
        with_dirs(function(d)
            pcall(sys.call, "files.write", "vitreus_hypr.lua", body)
            local hypr = d.conf:gsub("/pleamar/shells/vitreus$", "/hypr")
            run("cp", { "-f", d.data .. "/vitreus_hypr.lua", hypr .. "/vitreus_hypr.lua" }, function() end)
        end)
    end

    local function hy_changed()
        hy_show()
        hy_dirty = true
        run("hyprctl", { "eval", hy_code() }, function() end)
        if hy_waiting then return end
        hy_waiting = true
        after(800, function()
            hy_waiting = false
            hy_write_file()
        end)
    end

    local function hy_read()
        local function opt(name, cb)
            run("hyprctl", { "getoption", name, "-j" }, function(out, code)
                if code ~= 0 then return end
                local ok, j = pcall(json.decode, out or "")
                if ok and type(j) == "table" then cb(j) end
            end)
        end
        opt("general:layout", function(j)
            for i, n in ipairs(LAYOUTS) do if n == j.str then hy.layout = i end end
            hy_show()
        end)
        opt("general:gaps_in", function(j)
            local n = tonumber(tostring(j.css or ""):match("^(%d+)"))
            if n then hy.gaps = n; hy_show() end
        end)
        opt("general:resize_on_border", function(j) hy.resize = j.bool == true; hy_show() end)
        opt("general:allow_tearing", function(j) hy.tear = j.bool == true; hy_show() end)
        opt("animations:enabled", function(j) hy.anim = j.bool == true; hy_show() end)
        opt("input:sensitivity", function(j) hy.sens = tonumber(j.float) or 0; hy_show() end)
        opt("input:follow_mouse", function(j) hy.follow = tonumber(j.int) or 1; hy_show() end)
        opt("input:touchpad:natural_scroll", function(j) hy.nat = j.bool == true; hy_show() end)
    end

    hy_show()
    hy_read()

    on("hy_layout_set", function(i) hy.layout = math.max(1, math.min(3, math.floor(i + 0.5))); hy_changed() end)
    on("hy_gaps_set", function(t) hy.gaps = math.floor(math.max(0, math.min(1, t)) * 30 + 0.5); hy_changed() end)
    on("hy_sens_set", function(t)
        hy.sens = math.floor((math.max(0, math.min(1, t)) * 2 - 1) * 20 + 0.5) / 20
        hy_changed()
    end)
    on("hy_follow_set", function(i) hy.follow = math.max(0, math.min(3, math.floor(i + 0.5))); hy_changed() end)
    on("hy_toggle", function(k)
        k = math.floor(k + 0.5)
        if k == 0 then hy.resize = not hy.resize
        elseif k == 1 then hy.tear = not hy.tear
        elseif k == 2 then hy.anim = not hy.anim
        else hy.nat = not hy.nat end
        hy_changed()
    end)
    on("hy_refresh", function() hy_read() end)
end

-- ── The launcher (SUPER + Space) ──────────────────────────────────────────────────────────────────────────────
-- After Synoptik's LauncherOSD. The scene has a field (`text.lq`) and a list (`model.lres`, six rows at most, with
-- the chosen one in the middle of the window; the wheel scrolls the window, and the chosen one stays inside it). What is typed picks the search: apps by default (and a sum, if the text
-- is one), and after a first character `#` files, `>` commands, `:` emoji, `^` the clipboard, `~` wallpapers.
;(function()
    local schedule_preview_fwd
    local S = { desc = {}, apps = {}, res = {}, sel = 1, start = 1, last = nil, seq = 0, counts = {}, emoji = nil, clip = nil }
    local ROWS = 6
    local MODES = { ["#"] = "files", [">"] = "commands", [":"] = "emoji", ["^"] = "clipboard", ["~"] = "wallpapers" }
    local LABEL = { apps = "Apps", calc = "Calc", files = "Files", commands = "Commands", emoji = "Emoji", clipboard = "Clipboard", wallpapers = "Wallpapers" }
    local HINT = {
        apps = "Search apps…  # files  > commands  : emoji  ^ clipboard  ~ wallpapers",
    }

    local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    local function lq() return text.lq or "" end

    -- The window of rows shown: the chosen one is kept in view.
    local function render(keep)
        local n = #S.res
        S.sel = math.max(1, math.min(math.max(1, n), S.sel))
        if keep then S.start = math.max(1, math.min(S.start, n - ROWS + 1))
        else S.start = math.max(1, math.min(S.sel - math.floor(ROWS / 2), n - ROWS + 1)) end
        local rows = {}
        for i = 0, ROWS - 1 do
            local r = S.res[S.start + i]
            if not r then break end
            rows[#rows + 1] = {
                title = r.title, sub = r.sub or "", desc = r.desc or "", hasdesc = (r.desc or "") ~= "", glyph = r.glyph or (r.title or "?"):sub(1, 1):upper(),
                sel = (S.start + i) == S.sel, hasicon = (r.icon or "") ~= "", icon = r.icon or "",
            }
        end
        model.lres = rows
        fact.lcount = #rows
        text.lfoot = n > 0 and string.format("%d / %d", S.sel, n) or ""
        S.shown = S.res[S.sel]
        if S.shown ~= S.prev then S.prev = S.shown; schedule_preview_fwd(S.shown) end
    end

    local function show(list, msg)
        S.res = list
        S.sel = 1
        text.lmsg = (#list == 0) and (msg or "No results") or ""
        render()
    end

    local function lua_quote(s) return string.format("%q", s):gsub("\\\n", "\\n") end
    local function spawn(cmd)              -- start it on the desktop, detached from this shell
        run("hyprctl", { "dispatch", "hl.dsp.exec_cmd(" .. lua_quote(cmd) .. ")" }, function() end)
    end
    local function set_panel(name) cur_panel = name; fact.panel = name end
    local function close() set_panel("none") end

    -- Launch counts, so what is used most comes first when nothing is typed.
    do
        local ok, saved = pcall(sys.ask, "files.read", "launcher.json", "json")
        if ok and type(saved) == "table" and type(saved.counts) == "table" then S.counts = saved.counts end
    end
    local function bump(id)
        if not id or id == "" then return end
        S.counts[id] = (S.counts[id] or 0) + 1
        pcall(sys.call, "files.write", "launcher.json", { counts = S.counts })
    end

    sys.watch("apps", function(list) S.apps = list or {}; if S.last ~= nil and S.mode == "apps" then S.last = nil end end)

    -- What each app says about itself (the Comment of its .desktop file, else its GenericName): one pass over the
    -- folders the apps live in, with `find` running `grep` on the files it finds.
    with_dirs(function(d)
        local dirs = { "/usr/share/applications", d.home .. "/.local/share/applications",
                       "/var/lib/flatpak/exports/share/applications", d.home .. "/.local/share/flatpak/exports/share/applications" }
        local args = {}
        for _, dir in ipairs(dirs) do args[#args + 1] = dir end
        for _, x in ipairs({ "-name", "*.desktop", "-exec", "grep", "-H", "-E", "^(Comment|GenericName)=", "{}", "+" }) do args[#args + 1] = x end
        run("find", args, function(out)
            local comment, generic = {}, {}
            for path, key, val in (out or ""):gmatch("([^\n:]+%.desktop):(%a+)=([^\n]*)") do
                local id = path:match("([^/]+)%.desktop$")
                if key == "Comment" then comment[id] = comment[id] or val else generic[id] = generic[id] or val end
            end
            for id, v in pairs(generic) do S.desc[id] = v end
            for id, v in pairs(comment) do S.desc[id] = v end
            S.last = nil                      -- the rows are made again, now with their lines
        end)
    end)

    -- ── the preview beside the rows (files, the clipboard, wallpapers) ──
    local P = { n = 0, seq = 0 }
    local IMG = { jpg = true, jpeg = true, png = true, webp = true, gif = true, bmp = true, tiff = true, avif = true, jxl = true }
    local function fmt_size(n)
        n = tonumber(n) or 0
        if n < 1024 then return string.format("%d B", n) end
        local units = { "KiB", "MiB", "GiB", "TiB" }
        local v = n
        for _, u in ipairs(units) do
            v = v / 1024
            if v < 1024 or u == "TiB" then return string.format(v < 10 and "%.1f %s" or "%.0f %s", v, u) end
        end
    end
    local function detail(i, k, v) text["lp_k" .. i] = k or ""; text["lp_v" .. i] = v or "" end
    local function clear_preview()
        text.lp_kind, text.lp_title, text.lp_path, text.lp_body = "", "", "", ""
        for i = 1, 4 do detail(i) end
        fact.lp_img_on = false
    end
    local function short(path, home) return (path:gsub("^" .. home:gsub("%p", "%%%0"), "~")) end

    -- A small copy of a picture (the scene draws a fixed 480 x 320 image, asked for again with a new version).
    local function thumb(src, seq)
        with_dirs(function(d)
            local out = d.cache .. "/lp.png"
            run("mkdir", { "-p", d.cache }, function()
                run("magick", { src .. "[0]", "-auto-orient", "-thumbnail", "480x320", "-background", "none",
                                "-gravity", "center", "-extent", "480x320", out }, function(_, code)
                    if code == 0 and seq == P.seq then
                        P.n = P.n + 1
                        text.lp_imgpath = out .. "?" .. P.n
                        fact.lp_img_on = true
                    end
                end)
            end)
        end)
    end

    -- A file: its name and place, then size, date and type as they come in, and the picture if it is one.
    local function preview_file(path, kind, seq)
        with_dirs(function(d)
            text.lp_kind = kind
            text.lp_title = path:match("([^/]+)$") or path
            text.lp_path = short(path:match("^(.*)/[^/]*$") or "", d.home)
        end)
        detail(1, "Size", "…"); detail(2, "Modified", "…"); detail(3, "Type", "…"); detail(4)
        run("stat", { "-c", "%s|%Y|%F", path }, function(out)
            if seq ~= P.seq then return end
            local size, mtime, kindname = (out or ""):match("^(%d+)|(%d+)|(.-)%s*$")
            if not size then detail(1, "Size", "gone"); detail(2); detail(3); return end
            detail(1, "Size", kindname == "directory" and "Folder" or fmt_size(size))
            detail(2, "Modified", os.date("%Y-%m-%d %H:%M", tonumber(mtime)))
        end)
        run("file", { "--mime-type", "-b", path }, function(out)
            if seq ~= P.seq then return end
            local m = (out or ""):gsub("%s+$", "")
            if m ~= "" then detail(3, "Type", m) end
        end)
        local ext = (path:match("%.(%w+)$") or ""):lower()
        if IMG[ext] then
            run("magick", { "identify", "-format", "%wx%h", path .. "[0]" }, function(out, code)
                if seq == P.seq and code == 0 then detail(4, "Size px", (out or ""):gsub("%s+$", "")) end
            end)
            thumb(path, seq)
        end
    end

    -- Called with the chosen row: the preview follows a moment after the selection settles.
    local function schedule_preview(r)
        P.seq = P.seq + 1
        local seq = P.seq
        if not (r and r.pv) then return clear_preview() end
        after(110, function()
            if seq ~= P.seq then return end
            clear_preview()
            r.pv(seq)
        end)
    end

    schedule_preview_fwd = schedule_preview
    -- cliphist wants the entry's line on its input, and `run` has an input from a file: write the id, decode.
    local function clip_decode(c, cb)
        with_dirs(function(d)
            pcall(sys.call, "files.write", "lp-line.txt", c.id .. "\t")
            run("cliphist", { "decode" }, cb, { stdin = d.data .. "/lp-line.txt" })
        end)
    end

    local function preview_clip(c, seq)
        if c.image then
            text.lp_kind = "IMAGE"
            text.lp_title = "Copied image"
            local size, fmt, dims = c.text:match("binary data ([%d%.]+ %a+) (%a+) (%d+x%d+)")
            detail(1, "Size", size); detail(2, "Format", fmt and fmt:upper()); detail(3, "Size px", dims); detail(4)
            with_dirs(function(d)
                local out = d.cache .. "/lp.png"
                run("mkdir", { "-p", d.cache }, function()
                    run("vitreus-clipimg", { "thumb", c.id, out }, function(_, code)
                        if code == 0 and seq == P.seq then
                            P.n = P.n + 1
                            text.lp_imgpath = out .. "?" .. P.n
                            fact.lp_img_on = true
                        end
                    end)
                end)
            end)
            return
        end
        clip_decode(c, function(o)
            if seq ~= P.seq then return end
            o = o or ""
            local one = o:gsub("%s+$", "")
            if not one:find("\n") and (one:find("^/") or one:find("^file://")) then
                return preview_file((one:gsub("^file://", "")), "FILE", seq)
            end
            text.lp_kind = "TEXT"
            text.lp_title = string.format("%d characters", #o)
            text.lp_body = o:sub(1, 600)
        end)
    end


    -- ── apps ──
    local function clean_exec(e)
        e = (e or ""):gsub("%%%%", "\1"):gsub("%%[fFuUdDnNickvm]", ""):gsub("\1", "%%")
        return trim(e)
    end
    local function app_row(a)
        return { title = a.name or a.id or "?", sub = "", desc = S.desc[((a.id or ""):gsub("%.desktop$", ""))] or "", icon = a.icon or "", app = a,
                 run = function() bump(a.id or a.name); spawn(clean_exec(a.exec)) end }
    end
    local function search_apps(q)
        local out = {}
        q = q:lower()
        if q == "" then
            local list = {}
            for _, a in ipairs(S.apps) do list[#list + 1] = a end
            table.sort(list, function(x, y)
                local cx, cy = S.counts[x.id or x.name] or 0, S.counts[y.id or y.name] or 0
                if cx ~= cy then return cx > cy end
                return (x.name or ""):lower() < (y.name or ""):lower()
            end)
            for _, a in ipairs(list) do out[#out + 1] = app_row(a) end
            return out
        end
        local scored = {}
        for _, a in ipairs(S.apps) do
            local name = (a.name or ""):lower()
            local sc = 0
            if name == q then sc = 100
            elseif name:sub(1, #q) == q then sc = 80
            elseif name:find(" " .. q, 1, true) then sc = 60
            elseif name:find(q, 1, true) then sc = 40
            elseif (a.id or ""):lower():find(q, 1, true) or (a.wmclass or ""):lower():find(q, 1, true) then sc = 20 end
            if sc > 0 then
                sc = sc + math.min(10, S.counts[a.id or a.name] or 0)
                scored[#scored + 1] = { sc = sc, a = a }
            end
        end
        table.sort(scored, function(x, y)
            if x.sc ~= y.sc then return x.sc > y.sc end
            return (x.a.name or ""):lower() < (y.a.name or ""):lower()
        end)
        for _, e in ipairs(scored) do out[#out + 1] = app_row(e.a) end
        return out
    end

    -- ── a sum ──
    local function calc(src)
        local pos = 1
        local s = src:gsub("%s+", ""):lower()
        local function peek() return s:sub(pos, pos) end
        local expr
        local FUN = { sqrt = math.sqrt, sin = math.sin, cos = math.cos, tan = math.tan, abs = math.abs,
                      floor = math.floor, ceil = math.ceil, log = math.log10, ln = math.log,
                      round = function(x) return math.floor(x + 0.5) end }
        local function atom()
            local c = peek()
            if c == "(" then
                pos = pos + 1
                local v = expr()
                if peek() ~= ")" then error("paren") end
                pos = pos + 1
                return v
            elseif c == "-" then pos = pos + 1; return -atom()
            elseif c == "+" then pos = pos + 1; return atom() end
            local num = s:match("^%d*%.?%d+", pos) or s:match("^%d+", pos)
            if num then pos = pos + #num; return tonumber(num) end
            local id = s:match("^%a+", pos)
            if id then
                pos = pos + #id
                if id == "pi" then return math.pi elseif id == "e" then return math.exp(1) end
                local f = FUN[id]
                if not f or peek() ~= "(" then error("name") end
                pos = pos + 1
                local v = expr()
                if peek() ~= ")" then error("paren") end
                pos = pos + 1
                return f(v)
            end
            error("token")
        end
        local function pow()
            local v = atom()
            if peek() == "^" then pos = pos + 1; return v ^ pow() end
            return v
        end
        local function term()
            local v = pow()
            while true do
                local c = peek()
                if c == "*" then pos = pos + 1; v = v * pow()
                elseif c == "/" then pos = pos + 1; v = v / pow()
                elseif c == "%" then pos = pos + 1; v = v % pow()
                else return v end
            end
        end
        expr = function()
            local v = term()
            while true do
                local c = peek()
                if c == "+" then pos = pos + 1; v = v + term()
                elseif c == "-" then pos = pos + 1; v = v - term()
                else return v end
            end
        end
        local v = expr()
        if pos <= #s then error("trailing") end
        return v
    end
    local function try_calc(q)
        if not q:find("%d") or not q:find("[%+%-%*/%%%^%(]") and not q:find("%a%(") then return nil end
        if q:find("[^%d%a%s%.%+%-%*/%%%^%(%)]") then return nil end
        local ok, v = pcall(calc, q)
        if not ok or type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
        local str = string.format("%.10g", v)
        return { title = "= " .. str, sub = q .. " · Enter copies", glyph = "=",
                 run = function() run("wl-copy", { "--", str }, function() end) end }
    end

    -- ── commands ──
    local function open_settings(page)
        return function() fact.set_page = page; set_panel("settings"); return true end
    end
    local COMMANDS = {
        { "Settings: Wallpaper", "open", open_settings("pg_wall") },
        { "Settings: Glass", "open", open_settings("pg_glass") },
        { "Settings: Display", "open", open_settings("pg_disp") },
        { "Settings: Night mode", "open", open_settings("pg_night") },
        { "Night mode: toggle", "action", function() spawn('pleamar --say vitreus "emit night_toggle"') end },
        { "Settings: Hyprland", "open", open_settings("pg_hypr") },
        { "Settings: About", "open", open_settings("pg_about") },
        { "Calendar", "panel", function() set_panel("calendar"); return true end },
        { "Controls", "panel", function() set_panel("controls"); return true end },
        { "Player", "panel", function() set_panel("player"); return true end },
        { "Wallpaper galaxy", "action", function() spawn('pleamar --say vitreus "emit gal_toggle"') end },
        { "Random wallpaper", "action", function() local f = wp_random_pick(); if f then wp_apply(f) end end },
        { "Lock session", "action", function() spawn('pleamar --say lockscreen "fact locked true"') end },
        { "Suspend", "action", function() run("systemctl", { "suspend" }, function() end) end },
        { "Reload Hyprland", "action", function() run("hyprctl", { "reload" }, function() end) end },
    }
    local function search_commands(q)
        q = q:lower()
        local out = {}
        for _, c in ipairs(COMMANDS) do
            if q == "" or c[1]:lower():find(q, 1, true) then
                out[#out + 1] = { title = c[1], sub = c[2], glyph = ">", run = c[3] }
            end
        end
        return out
    end

    -- ── wallpapers ──
    local function search_wallpapers(q)
        q = q:lower()
        local out = {}
        for _, f in ipairs(wp_files) do
            local name = f:match("([^/]+)$") or f
            if q == "" or name:lower():find(q, 1, true) then
                out[#out + 1] = { title = name, sub = "wallpaper", glyph = "▣", run = function() wp_apply(f) end,
                                  pv = function(seq) preview_file(f, "WALLPAPER", seq) end }
                if #out >= 60 then break end
            end
        end
        return out
    end

    -- ── emoji ──
    local function search_emoji(q, done)
        local function go()
            q = q:lower()
            local scored = {}
            for i, e in ipairs(S.emoji) do
                local sc = 0
                if q == "" then
                    if e.g == "Smileys" then sc = 1000 - i end
                else
                    local n, k = (e.n or ""):lower(), (e.k or ""):lower()
                    if n == q or k == q then sc = 100
                    elseif n:sub(1, #q) == q then sc = 80
                    elseif n:find(" " .. q, 1, true) then sc = 60
                    elseif n:find(q, 1, true) or k:find(q, 1, true) then sc = 40 end
                end
                if sc > 0 then scored[#scored + 1] = { sc = sc, i = i, e = e } end
            end
            table.sort(scored, function(a, b) if a.sc ~= b.sc then return a.sc > b.sc end return a.i < b.i end)
            local out = {}
            for _, x in ipairs(scored) do
                local ch = x.e.c
                out[#out + 1] = { title = x.e.n, sub = x.e.g, glyph = ch,
                                  run = function() run("wl-copy", { "--", ch }, function() end) end }
                if #out >= 80 then break end
            end
            done(out)
        end
        if S.emoji then return go() end
        with_dirs(function(d)
            run("cp", { "-n", d.conf .. "/assets/emoji.json", d.data .. "/emoji.json" }, function()
                local ok, data = pcall(sys.ask, "files.read", "emoji.json", "json")
                S.emoji = (ok and type(data) == "table") and data or {}
                go()
            end)
        end)
    end

    -- ── the clipboard (cliphist) ──
    local function search_clip(q, done)
        local function go()
            q = q:lower()
            local out = {}
            for _, c in ipairs(S.clip) do
                if q == "" or c.text:lower():find(q, 1, true) then
                    out[#out + 1] = { title = c.text, sub = c.image and "image" or "text", glyph = c.image and "▣" or "T",
                        pv = function(seq) preview_clip(c, seq) end,
                        run = function()
                            if c.image then return run("vitreus-clipimg", { "copy", c.id }, function() end) end
                            clip_decode(c, function(o) run("wl-copy", { "--", o or "" }, function() end) end)
                        end }
                    if #out >= 60 then break end
                end
            end
            done(out)
        end
        run("cliphist", { "list" }, function(o)
            S.clip = {}
            for line in (o or ""):gmatch("[^\n]+") do
                local id, txt = line:match("^(%d+)\t(.*)$")
                if id then
                    S.clip[#S.clip + 1] = { id = id, text = txt, image = txt:find("^%[%[ binary data") ~= nil }
                end
            end
            go()
        end)
    end

    -- ── files ──
    local function search_files(q, done)
        if #q < 2 then return done({}, "Type two letters to search your files") end
        with_dirs(function(d)
            run("find", { d.home, "-maxdepth", "5", "(", "-name", ".*", "-prune", ")", "-o", "-iname", "*" .. q .. "*", "-print" },
                function(o)
                    local out = {}
                    for path in (o or ""):gmatch("[^\n]+") do
                        local name = path:match("([^/]+)$") or path
                        local dir = (path:match("^(.*)/[^/]*$") or ""):gsub("^" .. d.home:gsub("%p", "%%%0"), "~")
                        out[#out + 1] = { title = name, sub = dir, glyph = "F",
                                          run = function() spawn("xdg-open " .. "'" .. path:gsub("'", "'\\''") .. "'") end,
                                          pv = function(seq) preview_file(path, "FILE", seq) end }
                        if #out >= 60 then break end
                    end
                    table.sort(out, function(a, b) return #a.title < #b.title end)
                    done(out)
                end)
        end)
    end

    -- ── what is typed → what is shown ──
    local function search()
        local raw = lq()
        S.last = raw
        S.seq = S.seq + 1
        local seq = S.seq
        local first = raw:sub(1, 1)
        local mode = MODES[first] or "apps"
        local q = trim(MODES[first] and raw:sub(2) or raw)
        S.mode = mode
        local function done(list, msg) if seq == S.seq then show(list, msg) end end
        if mode == "apps" then
            local c = try_calc(q)
            local list = search_apps(q)
            if c then table.insert(list, 1, c); mode = "calc" end
            text.lmode = LABEL[mode]
            fact.lp_on = false
            return done(list)
        end
        text.lmode = LABEL[mode]
        fact.lp_on = (mode == "files" or mode == "clipboard" or mode == "wallpapers")
        if mode == "commands" then done(search_commands(q))
        elseif mode == "wallpapers" then done(search_wallpapers(q))
        elseif mode == "emoji" then search_emoji(q, done)
        elseif mode == "clipboard" then search_clip(q, done)
        elseif mode == "files" then
            text.lmsg = "Searching…"
            after(220, function()
                if seq == S.seq then search_files(q, done) end
            end)
        end
    end

    every(90, function()
        if cur_panel ~= "launch" then return end
        if lq() ~= S.last then search() end
    end)

    on("launch_open", function()
        text.lq = ""
        S.last = nil
        S.sel = 1
        search()
    end)
    on("launch_move", function(d)
        local n = #S.res
        if n == 0 then return end
        S.sel = S.sel + math.floor(d + 0.5)
        if S.sel < 1 then S.sel = n elseif S.sel > n then S.sel = 1 end
        render()
    end)
    -- The wheel: the window moves a row a notch (a touchpad's fractions add up), and the chosen one is carried along
    -- when it would fall out of view.
    local wheel_left = 0
    on("launch_scroll", function(d)
        local n = #S.res
        if n <= ROWS then return end
        wheel_left = wheel_left + d
        local steps = wheel_left >= 0 and math.floor(wheel_left) or math.ceil(wheel_left)
        if steps == 0 then return end
        wheel_left = wheel_left - steps
        S.start = math.max(1, math.min(S.start + steps, n - ROWS + 1))
        S.sel = math.max(S.start, math.min(S.sel, S.start + ROWS - 1))
        render(true)
    end)
    local function run_result(r)
        if not r or not r.run then return end
        if not r.run() then close() end
    end
    on("launch_pick", function(i) run_result(S.res[S.start + math.floor(i + 0.5)]) end)
    on("launch_run", function() run_result(S.res[S.sel]) end)
    on("launch_hint", function(i)
        text.lq = ({ "#", ">", ":", "^", "~" })[math.floor(i + 0.5) + 1] or ""
        focus("lq")
    end)
end)()

-- ── The mixer under the volume slider ─────────────────────────────────────────────────────────────────────────
-- Right-click the volume plate in Controls: one slider for each app that is playing sound, after Synoptik's per-app
-- volumes. pleamar's audio service has no per-app streams, so these are `pactl` sink inputs: listed while the mixer is
-- open (once a second), set with `set-sink-input-volume`, silenced with `set-sink-input-mute`.
;(function()
    local M = { ids = {}, rows = {}, open = false, busy_until = 0, pending = nil, waiting = false }

    local function now_ms() return math.floor(os.clock() * 1000) end

    local function show()
        model.mixer = M.rows
    end

    local function refresh()
        if M.pending or now_ms() < M.busy_until then return end
        run("pactl", { "-f", "json", "list", "sink-inputs" }, function(out, code)
            if code ~= 0 or M.pending or now_ms() < M.busy_until then return end
            local ok, list = pcall(json.decode, out or "[]")
            if not ok or type(list) ~= "table" then return end
            local ids, rows = {}, {}
            for _, s in ipairs(list) do
                local p = s.properties or {}
                local name = p["application.name"] or p["media.name"] or "Unknown"
                if #rows < 6 and not (name == "quickshell" and not p["application.name"]) then
                    local vol = s.volume and (s.volume["front-left"] or s.volume["mono"] or select(2, next(s.volume)))
                    local pct = vol and tonumber((tostring(vol.value_percent or "0")):match("(%d+)")) or 0
                    ids[#ids + 1] = s.index
                    rows[#rows + 1] = {
                        name = name, pct = pct, muted = s.mute == true, corked = s.corked == true,
                        icon = p["application.icon_name"] or p["application.process.binary"] or name,
                    }
                end
            end
            M.ids, M.rows = ids, rows
            show()
        end)
    end

    on("fact:vm_open", function(v)
        M.open = (v == true or v == 1)
        if M.open then refresh() end
    end)
    -- Listed while Controls is open, open mixer or not: the dots only show when there is an app to turn down.
    every(1000, function() if M.open or cur_panel == "controls" then refresh() end end)

    -- The slider is sent a moment after the last movement, and the row shows the new number at once.
    local function flush()
        M.waiting = false
        local pend = M.pending
        M.pending = nil
        if not pend then return end
        run("pactl", { "set-sink-input-volume", tostring(pend.id), pend.pct .. "%" }, function() end)
        M.busy_until = now_ms() + 700
    end
    on("mix_set", function(v)
        local row = math.floor(v / 4)
        local ratio = math.max(0, math.min(1, v - row * 4))
        local id = M.ids[row + 1]
        if not id then return end
        local pct = math.floor(ratio * 100 + 0.5)
        M.rows[row + 1].pct = pct
        show()
        M.pending = { id = id, pct = pct }
        M.busy_until = now_ms() + 700
        if not M.waiting then M.waiting = true; after(60, flush) end
    end)
    on("mix_mute", function(row)
        row = math.floor(row + 0.5)
        local id, r = M.ids[row + 1], M.rows[row + 1]
        if not id then return end
        r.muted = not r.muted
        show()
        M.busy_until = now_ms() + 700
        run("pactl", { "set-sink-input-mute", tostring(id), r.muted and "1" or "0" }, function() end)
    end)
end)()

-- The Bar page of the settings: which monitors the bar shows on. pleamar reads that (`screens:` on the scene's
-- surface) only when it starts, so choosing rewrites that line of vitreus.plm and starts the bar again, from a
-- command left running on its own (`setsid`) that asks this one to quit and then opens the scene afresh. What was
-- chosen is kept in bar.json; a chosen monitor that is not plugged in puts the bar on all of them until it is back.
;(function()
    local B = { pref = nil, file = nil, mons = {}, busy = false, awake = false }
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
sleep 0.3
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]

    local function connected(name)
        for i, m in ipairs(B.mons) do if m.name == name then return i end end
        return nil
    end
    -- Where the bar should be now: the choice, or all of them while the chosen one is away.
    local function target()
        local pref = B.pref or "all"
        if pref ~= "all" and not connected(pref) then return "all" end
        return pref
    end

    local function show()
        local pref = B.pref or "all"
        local at = pref ~= "all" and connected(pref) or nil
        fact.bar_scr = at and (at - 1) or -1
        for i = 0, 3 do
            local m = B.mons[i + 1]
            fact["bar_m." .. i .. ".on"] = m ~= nil
            if m then
                text["bar_m." .. i .. ".name"] = m.name
                text["bar_m." .. i .. ".sub"] = m.sub
            end
        end
        if B.busy then
            text.bar_msg = "Moving the bar…"
        elseif pref ~= "all" and not at and #B.mons > 0 then
            text.bar_msg = pref .. " isn't plugged in, so the bar is on every monitor until it's back."
        else
            text.bar_msg = ""
        end
    end

    local function restart(to)
        if B.busy then return end
        if to ~= "all" and not to:match("^[%w%._%-]+$") then return end
        B.busy = true
        show()
        with_dirs(function(d)
            local plm = d.conf .. "/vitreus.plm"
            local value = to == "all" and "all" or ('"' .. to .. '"')
            run("sed", { "-i", "-E", "/^    surface \\{ size: 900, 800;/s/screens: [^;]*;/screens: " .. value .. ";/", plm }, function(_, code)
                if code ~= 0 then
                    B.busy = false
                    show()
                    text.bar_msg = "Couldn't change where the bar shows."
                    return
                end
                B.file = to
                run("setsid", { "-f", "sh", "-c", RESTART, "sh", plm, d.data .. "/vitreus.log" }, function() end)
            end)
        end)
    end

    -- Put the bar where it should be, once what the file says and what is plugged in are both known. Not in the
    -- first seconds after starting, so a monitor that is still waking up does not send it back and forth.
    local function settle()
        if B.busy or B.file == nil or #B.mons == 0 then return end
        if not B.awake then return end
        local to = target()
        if to ~= B.file then restart(to) end
    end

    local function read_mons()
        run("hyprctl", { "monitors", "-j" }, function(out, code)
            if code ~= 0 or not out then return end
            local ok, list = pcall(json.decode, out)
            if not ok or type(list) ~= "table" then return end
            local mons = {}
            for _, j in ipairs(list) do
                local t = j.transform or 0
                mons[#mons + 1] = { name = j.name, x = j.x or 0, y = j.y or 0, tall = t == 1 or t == 3 or t == 5 or t == 7 }
            end
            table.sort(mons, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
            for i, m in ipairs(mons) do
                local where = #mons == 1 and "" or (i == 1 and "left" or (i == #mons and "right" or "middle"))
                if m.tall then where = where == "" and "portrait" or (where .. ", portrait") end
                m.sub = where
            end
            B.mons = mons
            show()
            settle()
        end)
    end

    on("bar_pick_scr", function(i)
        if B.busy then return end
        local pref = "all"
        if i >= 0 then
            local m = B.mons[math.floor(i + 0.5) + 1]
            if not m then return end
            pref = m.name
        end
        B.pref = pref
        pcall(sys.call, "files.write", "bar.json", { screens = pref })
        show()
        local to = target()
        if B.file ~= nil and to ~= B.file then restart(to) end
    end)

    local ok, saved = pcall(sys.ask, "files.read", "bar.json", "json")
    if ok and type(saved) == "table" and type(saved.screens) == "string" then B.pref = saved.screens end
    -- What this bar was started with: the `screens:` of the scene's surface.
    with_dirs(function(d)
        run("grep", { "-o", "-m1", "-E", "screens: [^;]*;", d.conf .. "/vitreus.plm" }, function(out)
            local v = (out or ""):match("screens:%s*(.-)%s*;")
            if v == nil then return end
            B.file = v:match('^"([^"]+)"') or "all"
            if B.pref == nil then B.pref = B.file end
            show()
            settle()
        end)
    end)
    read_mons()
    every(5000, read_mons)
    after(8000, function() B.awake = true; settle() end)
end)()

-- The Bar page's layout: the order of the bar's pieces and which are hidden, edited by dragging chips on a small copy
-- of the bar (see the Bar page in vitreus.plm). The bar reads `bo.<piece>` (its place) and `bv.<piece>` (shown); the
-- editor reads `bc.<n>` (where each chip is). Kept in bar-layout.json. The settings gear cannot be hidden: it is the way
-- back to this page.
;(function()
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
end)()

-- The About page of the settings (System): the build this shell runs from, and how to update it. Vitreus is a git
-- checkout in its config folder, so its build is that commit plus pleamar's version. Checking is a `git fetch`,
-- updating is `git pull --ff-only` (it will not merge over changes of yours), and after it the shell is started again
-- the way the Bar page does it: a command left running on its own (`setsid`) that asks this one to quit and opens the
-- scene afresh. ssh is told not to ask for anything, so a fetch that needs a passphrase fails instead of hanging.
;(function()
    local A = { busy = false, dir = nil }
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
sleep 0.3
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]
    local SSH = "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=15"

    local function busy(b, msg)
        A.busy = b
        fact.about_busy = b
        if msg then text.about_msg = msg end
    end

    local function git(args, cb)
        local full = { "-C", A.dir, "-c", SSH }
        for _, a in ipairs(args) do full[#full + 1] = a end
        run("git", full, cb)
    end

    local function lines(out)
        local t = {}
        for l in (out or ""):gmatch("[^\n]+") do t[#t + 1] = l end
        return t
    end

    -- This shell's commit, its branch, whether there is anything of yours not committed, and pleamar's version.
    local function read_build()
        git({ "log", "-1", "--format=%h%n%cd%n%s", "--date=format:%b %d, %Y" }, function(out, code)
            local l = lines(out)
            if code ~= 0 or #l < 3 then
                text.about_commit = "not a git checkout"
                text.about_date = ""
                text.about_sub = ""
                return
            end
            text.about_date = l[2]
            text.about_sub = l[3]
            git({ "rev-parse", "--abbrev-ref", "HEAD" }, function(b)
                local branch = lines(b)[1] or ""
                git({ "status", "--porcelain", "--untracked-files=no" }, function(st)
                    local dirty = #lines(st) > 0
                    text.about_commit = l[1] .. (branch ~= "" and (" · " .. branch) or "") .. (dirty and " · local changes" or "")
                end)
            end)
        end)
        run("pleamar", { "--version" }, function(out)
            text.about_pl = lines(out)[1] or "unknown"
        end)
    end

    local function check(after)
        if A.busy then return end
        busy(true, "Checking…")
        git({ "fetch", "--quiet" }, function(_, code)
            if code ~= 0 then
                fact.about_behind = -1
                return busy(false, "Couldn't reach the remote. Is there a network, and an ssh key that needs no passphrase?")
            end
            git({ "rev-list", "--count", "HEAD..@{u}" }, function(behind, c1)
                git({ "rev-list", "--count", "@{u}..HEAD" }, function(ahead, c2)
                    local n = tonumber(lines(behind)[1] or "")
                    local m = tonumber(lines(ahead)[1] or "") or 0
                    if c1 ~= 0 or n == nil then
                        fact.about_behind = -1
                        return busy(false, "This branch doesn't follow a remote one, so there is nothing to check.")
                    end
                    fact.about_behind = n
                    local msg
                    if n == 0 then msg = "Up to date."
                    elseif m > 0 then msg = n .. " new upstream, but you have " .. m .. " commit(s) of your own: update by hand."; fact.about_behind = 0
                    else msg = n == 1 and "1 update available." or (n .. " updates available.") end
                    busy(false, msg)
                    if after then after() end
                end)
            end)
        end)
    end

    local function restart()
        with_dirs(function(d)
            text.about_msg = "Restarting…"
            fact.about_busy = true
            run("setsid", { "-f", "sh", "-c", RESTART, "sh", d.conf .. "/vitreus.plm", d.data .. "/vitreus.log" }, function() end)
        end)
    end

    on("about_check", function() check() end)
    on("about_restart", function()
        if A.busy then return end
        A.busy = true
        restart()
    end)
    on("about_update", function()
        if A.busy or (fact.about_behind or 0) <= 0 then return end
        busy(true, "Updating…")
        git({ "pull", "--ff-only", "--quiet" }, function(_, code)
            if code ~= 0 then
                return busy(false, "Couldn't update: something of yours is in the way. Try `git pull` in the shell's folder.")
            end
            restart()
        end)
    end)

    with_dirs(function(d)
        A.dir = d.conf
        read_build()
    end)
end)()

-- The system tray: the apps that live in it and have no window. They are listed in the window-title panel (with a pin
-- and a menu button each) and ride the bar as icons: all of them, or only the pinned ones (`tray_only_pinned`). A left
-- click is what clicking the icon would do, a right click opens the app's own menu, drawn here from the tree the app
-- publishes (`tray.menu`) with its submenus opening in place. Which apps are pinned, and the bar's mode, are kept in
-- tray.json. An app is known by its `id`, which survives restarts; its bus name does not.
;(function()
    local items = {}            -- what the service reported, in the order the bar shows
    local listed = {}           -- row of `trays` -> item
    local barred = {}           -- row of `bartrays` -> item
    local pinned = {}           -- id -> true
    local only_pinned = false
    local cur = nil             -- the app whose menu is open
    local tree = nil            -- its menu, as it came
    local unfolded = {}         -- the submenus that are open, by their place: "2/1"
    local flat = {}             -- row of `tray_menu` -> { entry, place }

    local function ident(t)
        if t.id ~= nil and t.id ~= "" then return t.id end
        return t.key or ""
    end
    local function title_of(t)
        if t.title ~= nil and t.title ~= "" then return t.title end
        return ident(t)
    end

    local function save()
        local ids = {}
        for id in pairs(pinned) do ids[#ids + 1] = id end
        table.sort(ids)
        pcall(sys.call, "files.write", "tray.json", { pinned = ids, only_pinned = only_pinned })
    end

    local function header()
        if not cur then return end
        text.tm_title = title_of(cur)
        text.tm_sub = ident(cur)
        text.tm_iconurl = cur.icon or ""
        fact.tm_pinned = pinned[ident(cur)] == true
    end

    local function render()
        local rows, bar_rows = {}, {}
        listed, barred = {}, {}
        for _, t in ipairs(items) do
            local pin = pinned[ident(t)] == true
            if #rows < 16 then
                rows[#rows + 1] = { title = title_of(t), icon = t.icon or "", pinned = pin, menu = t.menu == true }
                listed[#rows] = t
            end
            if #bar_rows < 8 and (pin or not only_pinned) then
                bar_rows[#bar_rows + 1] = { icon = t.icon or "" }
                barred[#bar_rows] = t
            end
        end
        model.trays = rows
        model.bartrays = bar_rows
        fact.tray_only_pinned = only_pinned
        header()
    end

    sys.watch("tray", function(list)
        items = {}
        for _, t in ipairs(list or {}) do items[#items + 1] = t end
        -- a stable order: the bus registration order changes with what started first
        table.sort(items, function(a, b) return ident(a) < ident(b) end)
        render()
    end)

    -- Labels use a leading underscore for the accelerator (`_File`); `__` is a real one.
    local function clean(label)
        label = (label or ""):gsub("__", "\1")
        label = label:gsub("_", "")
        label = label:gsub("\1", "_")
        return label
    end

    local function flatten()
        local rows = {}
        local h = 0
        flat = {}
        local function walk(list, depth, place)
            for i, e in ipairs(list or {}) do
                if #rows >= 40 then return end
                local p = place .. "/" .. i
                local kids = type(e.children) == "table" and #e.children > 0
                local open = kids and unfolded[p] == true
                local sep = e.separator == true
                rows[#rows + 1] = {
                    label = clean(e.label), enabled = e.enabled ~= false, sep = sep,
                    checked = e.checked == true or e.checked == 1, kids = kids, open = open, depth = depth,
                }
                flat[#rows] = { entry = e, place = p, kids = kids }
                h = h + (sep and 10 or 28) + 2
                if open then walk(e.children, depth + 1, p) end
            end
        end
        walk(tree, 0, "")
        model.tray_menu = rows
        fact.tm_h = math.max(0, h - 2)
    end

    local function open_menu(t)
        if not t then return end
        cur = t
        unfolded = {}
        tree = nil
        if t.menu then
            local ok, m = pcall(sys.ask, "tray.menu", t.key)
            if ok and type(m) == "table" then tree = m end
        end
        fact.tm_has_menu = tree ~= nil and #tree > 0
        header()
        flatten()
        set_panel("tray")
    end

    -- A left click. An app that is only a menu (no id, but a menu) has nothing to activate: it opens the menu.
    local function primary(t)
        if not t then return end
        if t.menu and (t.id == nil or t.id == "") then return open_menu(t) end
        pcall(sys.call, "tray.activate", t.key)
    end

    local function toggle_pin(t)
        if not t then return end
        local id = ident(t)
        if id == "" then return end
        if pinned[id] then pinned[id] = nil else pinned[id] = true end
        save()
        render()
    end

    on("tray_click", function(i) primary(listed[i + 1]) end)
    on("bar_tray_click", function(i)
        local t = barred[i + 1]
        if not t then return end
        primary(t)
        if not (t.menu and (t.id == nil or t.id == "")) then set_panel("none") end
    end)
    on("tray_menu_open", function(i) open_menu(listed[i + 1]) end)
    on("bar_tray_menu", function(i) open_menu(barred[i + 1]) end)
    on("tray_pin", function(i) toggle_pin(listed[i + 1]) end)
    on("tm_pin", function() toggle_pin(cur) end)
    on("tm_open", function()
        if cur then pcall(sys.call, "tray.activate", cur.key) end
        set_panel("none")
    end)
    on("tm_alt", function()
        if cur then pcall(sys.call, "tray.secondary", cur.key) end
        set_panel("none")
    end)
    on("tray_mode", function()
        only_pinned = not only_pinned
        save()
        render()
    end)
    on("tray_menu_pick", function(i)
        local row = flat[i + 1]
        if not row or not cur then return end
        if row.kids then
            unfolded[row.place] = not unfolded[row.place] or nil
            flatten()
            return
        end
        if row.entry.enabled == false or row.entry.separator == true then return end
        pcall(sys.call, "tray.menu_click", cur.key, row.entry.id)
        set_panel("none")
    end)

    local ok, saved = pcall(sys.ask, "files.read", "tray.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.pinned) == "table" then
            for _, id in ipairs(saved.pinned) do if type(id) == "string" then pinned[id] = true end end
        end
        only_pinned = saved.only_pinned == true
        render()
    end
end)()

-- Night mode: a warm tint over the whole screen, by hand or on a schedule (Settings > Night mode). It is done with
-- `hyprsunset`, Hyprland's own blue-light filter: a daemon that hands the compositor a colour transform, so nothing is
-- re-rendered. It is started when it is first needed (in identity, so it changes nothing by itself), and driven with
-- `hyprctl hyprsunset temperature <K>` and `identity`. Without it installed, this falls back to a Hyprland screen
-- shader (a few lines of GLSL, `hyprctl eval` to set `decoration:screen_shader`), which works but makes Hyprland rebuild
-- its buffers on every change, and flickers while a blurred panel is open. The temperature is what the slider says; the
-- schedule is here, not in hyprsunset, so the same page drives both. Only what this file set is ever cleared. Kept in
-- night.json.
;(function()
    local WARM_K, COOL_K = 2500, 6500                 -- the slider's ends: 1 is the warmest
    local N = { on = false, auto = false, t = 0.65, start = 42, stop = 12, applied = false, last_should = nil, timer = false, sun = nil }
    local file = nil                                    -- the shader's path, once the data folder is known

    -- What a blackbody of `k` kelvin looks like, as a multiplier per channel (Tanner Helland's fit).
    local function kelvin(k)
        local t = k / 100
        local r, g, b
        if t <= 66 then r = 255 else r = 329.698727446 * (t - 60) ^ -0.1332047592 end
        if t <= 66 then g = 99.4708025861 * math.log(t) - 161.1195681661 else g = 288.1221695283 * (t - 60) ^ -0.0755148492 end
        if t >= 66 then b = 255 elseif t <= 19 then b = 0 else b = 138.5177312231 * math.log(t - 10) - 305.0447927307 end
        local function c(v) return math.max(0, math.min(1, v / 255)) end
        return c(r), c(g), c(b)
    end
    local function temp() return math.floor((COOL_K - N.t * (COOL_K - WARM_K)) / 100 + 0.5) * 100 end

    local function shader()
        local r, g, b = kelvin(temp())
        return string.format([[#version 300 es
precision highp float;

in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

void main() {
    vec4 base = texture(tex, v_texcoord);
    fragColor = vec4(base.rgb * vec3(%.4f, %.4f, %.4f), base.a);
}
]], r, g, b)
    end

    -- Half hours, 0 to 47, as the clock is read here.
    local function slot_text(i)
        local m = i * 30
        local h, mm = m // 60, m % 60
        local h12 = h % 12
        if h12 == 0 then h12 = 12 end
        return string.format("%d:%02d %s", h12, mm, h < 12 and "AM" or "PM")
    end

    local function in_window(now)                        -- now, in minutes; handles a window that crosses midnight
        local a, z = N.start * 30, N.stop * 30
        if a == z then return false end
        if a < z then return now >= a and now < z end
        return now >= a or now < z
    end

    local function show()
        fact.night_on = N.on
        fact.night_auto = N.auto
        fact.night_t = N.t
        text.night_temp_text = string.format("%d K", temp())
        text.night_start_text = slot_text(N.start)
        text.night_end_text = slot_text(N.stop)
        if N.auto then
            text.night_status = N.on and ("On until " .. slot_text(N.stop)) or ("Off · starts at " .. slot_text(N.start))
        else
            text.night_status = N.on and "On" or "Off"
        end
    end

    local function save()
        pcall(sys.call, "files.write", "night.json", { on = N.on, auto = N.auto, t = N.t, start = N.start, stop = N.stop })
    end

    local function set_option(value)
        run("hyprctl", { "eval", 'hl.config({ decoration = { screen_shader = "' .. value .. '" } })' }, function() end)
    end

    -- hyprsunset: make sure its daemon is there (started in identity: it changes nothing until told), then call back.
    local function with_sunset(fn)
        run("pgrep", { "-x", "hyprsunset" }, function(_, code)
            if code == 0 then return fn() end
            run("setsid", { "-f", "hyprsunset", "-i" }, function() after(700, fn) end)
        end)
    end

    -- Make the screen agree with `N.on`.
    local function apply()
        if N.sun == nil then return end                     -- not known yet: init calls this again
        if N.sun then
            if N.on then
                with_sunset(function()
                    run("hyprctl", { "hyprsunset", "temperature", tostring(temp()) }, function() end)
                    N.applied = true
                end)
            elseif N.applied then
                run("hyprctl", { "hyprsunset", "identity" }, function() end)
                N.applied = false
            end
            return
        end
        with_dirs(function(d)
            file = d.data .. "/night.frag"
            if file:find('"', 1, true) then return end     -- it goes inside a string that Hyprland reads
            if N.on then
                pcall(sys.call, "files.write", "night.frag", shader())
                set_option(file)
                N.applied = true
            elseif N.applied then
                set_option("")
                N.applied = false
            end
        end)
    end

    -- The slider sends a stream of values: the shader is rewritten at most every 150 ms, and only while it is on.
    local function apply_soon()
        if N.timer then return end
        N.timer = true
        after(150, function() N.timer = false; if N.on then apply() end end)
    end

    local function set_on(v)
        N.on = v
        show()
        save()
        apply()
    end

    -- The schedule: at a boundary it puts night mode where the schedule says, and then leaves it to be changed by hand
    -- until the next one. Turning it on, or moving a time, decides at once.
    local function evaluate(now, force)
        if not N.auto then return end
        local should = in_window(now)
        if force or N.last_should == nil or should ~= N.last_should then
            N.last_should = should
            if N.on ~= should then set_on(should) else show() end
        end
    end
    local function minutes_now()
        local t = os.date("*t")
        return t.hour * 60 + t.min
    end

    on("night_toggle", function() set_on(not N.on) end)
    on("night_auto_toggle", function()
        N.auto = not N.auto
        N.last_should = nil
        show()
        save()
        if N.auto then evaluate(minutes_now(), true) end
    end)
    on("night_temp_set", function(v)
        N.t = math.max(0, math.min(1, v))
        show()
        save()
        apply_soon()
    end)
    on("night_start_step", function(d)
        N.start = (N.start + (d < 0 and -1 or 1)) % 48
        show(); save(); evaluate(minutes_now(), true)
    end)
    on("night_end_step", function(d)
        N.stop = (N.stop + (d < 0 and -1 or 1)) % 48
        show(); save(); evaluate(minutes_now(), true)
    end)

    -- Every minute: the schedule, and that Hyprland still has the shader.
    sys.watch("clock", function(c)
        evaluate(c.hour * 60 + c.minute, false)
        if N.on and N.applied then
            if N.sun then
                -- the daemon was stopped (it crashed, or somebody killed it): start it again with the tint
                run("pgrep", { "-x", "hyprsunset" }, function(_, code) if code ~= 0 then apply() end end)
            else
                run("hyprctl", { "getoption", "decoration:screen_shader", "-j" }, function(out)
                    if out and not out:find("night.frag", 1, true) then apply() end
                end)
            end
        end
    end)

    local ok, saved = pcall(sys.ask, "files.read", "night.json", "json")
    if ok and type(saved) == "table" then
        N.on = saved.on == true
        N.auto = saved.auto == true
        if type(saved.t) == "number" then N.t = math.max(0, math.min(1, saved.t)) end
        if type(saved.start) == "number" then N.start = math.floor(saved.start) % 48 end
        if type(saved.stop) == "number" then N.stop = math.floor(saved.stop) % 48 end
    end
    show()
    run("which", { "hyprsunset" }, function(_, code)
        N.sun = code == 0
        -- A shader this file left behind (the shell died with night mode on, or an earlier version used one) is taken
        -- off, so it never stacks with the new tint; anybody else's stays. Where the shader is the way, and night mode is
        -- on, it is put back by `apply` below.
        run("hyprctl", { "getoption", "decoration:screen_shader", "-j" }, function(out)
            if out and out:find("night.frag", 1, true) and (N.sun or not N.on) then set_option("") end
        end)
        if N.on then apply() end
    end)
end)()

-- The wallpaper galaxy (SUPER + B): every wallpaper as a glass bead, placed on a colour wheel by its dominant hue (the
-- angle) and how vivid it is (the radius: greys in the middle, saturated ones out at the rim), so the whole collection
-- reads as a map of colour. This is the logic side: one ImageMagick pass per wallpaper makes its square bead picture and
-- reads its colours (the same 32-colour histogram the colour filter uses), the beads are then laid out (a relaxation so
-- none overlaps, drawn back towards where its hue puts it), and the result is kept in wallpaper-galaxy.json so this
-- happens once. The overlay itself is in vitreus.plm (`surface galaxy`).
;(function()
    local RULE = 3                                       -- which version made the file: an older one is made again
    local BEAD = 88                                      -- the bead picture, in pixels: small, there are 140 of them in one atlas
    local HERO = 260                                     -- the picture of the one under the pointer, and the middle
    local MAX = 140                                      -- what the model holds
    local G = { data = {}, dir = nil, busy = 0, queue = {}, started = false, laid = false, total = 0 }
    local atan2 = math.atan2 or math.atan

    local function name_of(f) return f:match("([^/]+)$") or f end
    local function stem(f) return (name_of(f):gsub("%.%w+$", "")) end

    local function hsv(r, g, b)                          -- 0..255 in; hue 0..360, saturation and value 0..1
        r, g, b = r / 255, g / 255, b / 255
        local mx, mn = math.max(r, g, b), math.min(r, g, b)
        local d = mx - mn
        local h = 0
        if d > 0 then
            if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
            h = h * 60
        end
        return h, mx == 0 and 0 or d / mx, mx
    end
    local function hex(h, s2, v)                          -- the inverse, as "#rrggbb"
        local c = v * s2
        local x = c * (1 - math.abs((h / 60) % 2 - 1))
        local m = v - c
        local r, g, b = 0, 0, 0
        local k = math.floor(h / 60) % 6
        if k == 0 then r, g, b = c, x, 0 elseif k == 1 then r, g, b = x, c, 0 elseif k == 2 then r, g, b = 0, c, x
        elseif k == 3 then r, g, b = 0, x, c elseif k == 4 then r, g, b = x, 0, c else r, g, b = c, 0, x end
        return string.format("#%02x%02x%02x", math.floor((r + m) * 255 + 0.5), math.floor((g + m) * 255 + 0.5), math.floor((b + m) * 255 + 0.5))
    end
    local function seed_hue(f)                            -- a grey has no hue: any steady angle will do
        local h = 5381
        for i = 1, #f do h = (h * 33 + f:byte(i)) % 360007 end
        return h % 360
    end

    local function hero_of(f) return G.dir .. "/" .. name_of(f) .. ".hero.jpg" end
    local function bead_of(f) return G.dir .. "/" .. name_of(f) .. ".bead.png" end

    -- One wallpaper: its square picture and its colours (one ImageMagick pass), then its bead: that picture made small,
    -- cut to a circle with a little gloss on it. One picture per bead, already round, is what keeps the atlas (one texture
    -- for every image and letter on screen) from filling up: at 160 pixels each, 140 of them did not fit, and the ones
    -- that did not were drawn again every frame.
    local function analyse(f, done)
        run("magick", { f .. "[0]", "-thumbnail", HERO .. "x" .. HERO .. "^", "-gravity", "center", "-extent", HERO .. "x" .. HERO,
                        "-quality", "88", "-write", hero_of(f), "-thumbnail", "100x100", "-colors", "32", "-format", "%c", "histogram:info:" },
            function(res, code)
                if code == 0 and res then
                    local total, sat_sum, val_sum, x, y, wsum = 0, 0, 0, 0, 0, 0
                    for count, r, g, b in res:gmatch("(%d+):%s*%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)") do
                        local n = tonumber(count)
                        local h, sa, v = hsv(tonumber(r), tonumber(g), tonumber(b))
                        total = total + n
                        val_sum = val_sum + n * v
                        if v > 0.12 then sat_sum = sat_sum + n * sa end
                        -- the hue that counts is the vivid one: a dark scene with a neon sign is that sign's colour
                        local w = n * sa ^ 1.6 * (0.25 + v)
                        x = x + w * math.cos(math.rad(h))
                        y = y + w * math.sin(math.rad(h))
                        wsum = wsum + w
                    end
                    if total > 0 then
                        local hue = (wsum > 1e-6 and (x * x + y * y) > 1e-9) and (math.deg(atan2(y, x)) % 360) or seed_hue(f)
                        local sat, val = sat_sum / total, val_sum / total
                        G.data[f] = { h = hue, s = sat, v = val }
                    end
                end
                if not G.data[f] then return done() end
                local c, r = BEAD / 2, BEAD / 2
                run("magick", { hero_of(f), "-resize", BEAD .. "x" .. BEAD, "-alpha", "set",
                                "(", "-size", BEAD .. "x" .. BEAD, "xc:none", "-fill", "white", "-draw", string.format("circle %d,%d %d,0", c, c, c), ")",
                                "-compose", "DstIn", "-composite",
                                "(", "-size", BEAD .. "x" .. BEAD, "xc:none", "-fill", "rgba(255,255,255,0.11)",
                                "-draw", string.format("ellipse %d,%d %d,%d 0,360", math.floor(c * 0.72), math.floor(c * 0.6), math.floor(c * 0.52), math.floor(c * 0.42)), ")",
                                "-compose", "Over", "-composite", "PNG32:" .. bead_of(f) },
                    function(_, code2)
                        if code2 ~= 0 then G.data[f] = nil end
                        done()
                    end)
            end)
    end

    -- Where each bead goes: its hue is its angle, its vividness its distance from the middle; then nobody may overlap.
    local function layout(files)
        local P, T = {}, {}
        for i, f in ipairs(files) do
            local d = G.data[f]
            local ang = math.rad(d.h) - math.pi / 2                -- red at the top, round clockwise
            local q = math.max(0, math.min(1, d.s / 0.62))
            local rho = 0.30 + 0.66 * q ^ 0.6                      -- the middle is left for the wallpaper in use
            T[i] = { math.cos(ang) * rho, math.sin(ang) * rho }
            P[i] = { T[i][1], T[i][2] }
        end
        local gap = 0.142                                            -- bead spacing, as a fraction of the wheel's radius
        for iter = 1, 200 do
            local pull = 0.07 * (1 - iter / 200)                     -- drawn back less and less, so nobody ends up on top
            for i = 1, #P do
                for j = i + 1, #P do
                    local dx, dy = P[j][1] - P[i][1], P[j][2] - P[i][2]
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist < gap then
                        if dist < 1e-6 then dx, dy, dist = 0.001, 0, 0.001 end
                        local push = (gap - dist) / 2 / dist
                        P[i][1], P[i][2] = P[i][1] - dx * push, P[i][2] - dy * push
                        P[j][1], P[j][2] = P[j][1] + dx * push, P[j][2] + dy * push
                    end
                end
            end
            for i = 1, #P do                                         -- drawn back towards its own place; kept inside the wheel
                P[i][1] = P[i][1] + (T[i][1] - P[i][1]) * pull
                P[i][2] = P[i][2] + (T[i][2] - P[i][2]) * pull
                local r = math.sqrt(P[i][1] ^ 2 + P[i][2] ^ 2)
                if r > 0.95 then P[i][1], P[i][2] = P[i][1] * 0.95 / r, P[i][2] * 0.95 / r end
                if r < 0.27 then P[i][1], P[i][2] = P[i][1] * 0.27 / math.max(r, 1e-6), P[i][2] * 0.27 / math.max(r, 1e-6) end
            end
        end
        for i, f in ipairs(files) do G.data[f].x, G.data[f].y = P[i][1], P[i][2] end
    end

    local function save()
        local out = { rule = RULE }
        for f, d in pairs(G.data) do out[f] = { h = d.h, s = d.s, v = d.v, x = d.x, y = d.y } end
        pcall(sys.call, "files.write", "wallpaper-galaxy.json", out)
    end

    -- The lens (the bead under the pointer, swollen) and the middle (the wallpaper in use) are each ONE picture, big and
    -- sharp: the picture of whichever wallpaper is meant is copied over a fixed file and loaded again in place (`?n`).
    -- A picture of their own for every bead would take room in the atlas for good, one for each one hovered over.
    local lens_n, now_n = 0, 0
    local function set_lens(i)
        local f = G.files and G.files[i + 1]
        if not f then return end
        text.gal_hero_name = stem(f)
        fact.gal_hero_cur = f == wp_cur
        run("cp", { "-f", hero_of(f), G.dir .. "/lens.jpg" }, function(_, code)
            if code == 0 then lens_n = lens_n + 1; text.gal_hero = G.dir .. "/lens.jpg?" .. lens_n end
        end)
    end
    local function set_now()
        if not wp_cur or not G.dir then return end
        run("cp", { "-f", hero_of(wp_cur), G.dir .. "/now.jpg" }, function(_, code)
            if code == 0 then now_n = now_n + 1; text.gal_now = G.dir .. "/now.jpg?" .. now_n end
        end)
    end
    on("fact:gal_hot", function(v) if type(v) == "number" and v >= 0 then set_lens(math.floor(v + 0.5)) end end)

    local function build()
        local rows = {}
        local files = {}
        for _, f in ipairs(wp_files) do if G.data[f] and G.data[f].x then files[#files + 1] = f end end
        for i, f in ipairs(files) do
            if i > MAX then break end
            local d = G.data[f]
            local dim = false
            if wp_filter then
                dim = true
                for _, tag in ipairs(wp_tags[f] or {}) do if tag == wp_filter then dim = false; break end end
            end
            rows[i] = { img = bead_of(f), x = d.x, y = d.y, hue = d.h, hi = math.floor(d.h / 10 + 0.5) % 36,
                        cur = f == wp_cur, dim = dim, name = stem(f) }
        end
        G.files = files
        model.gal = rows
        set_now()
    end

    local function finish()
        local files = {}
        for _, f in ipairs(wp_files) do if G.data[f] then files[#files + 1] = f end end
        layout(files)
        save()
        G.laid = true
        build()
    end

    local function pump()
        while G.busy < 2 and #G.queue > 0 do
            local f = table.remove(G.queue)
            G.busy = G.busy + 1
            analyse(f, function()
                G.busy = G.busy - 1
                text.gal_status = string.format("Reading your wallpapers…  %d of %d", G.total - #G.queue - G.busy, G.total)
                if G.busy == 0 and #G.queue == 0 then text.gal_status = ""; finish() else pump() end
            end)
        end
    end

    -- Start once the wallpaper folder has been read: what is already known is used at once, the rest is made.
    local function start()
        if G.started or #wp_files == 0 then return end
        G.started = true
        with_dirs(function(d)
            G.dir = d.cache .. "/gal"
            run("mkdir", { "-p", G.dir }, function()
                -- the earlier version's 160 pixel pictures (`name.jpg`) are not used any more; the new ones are `.hero.jpg` and `.bead.png`
                run("find", { G.dir, "-maxdepth", "1", "-name", "*.jpg", "!", "-name", "*.hero.jpg", "-delete" }, function() end)
                local ok, saved = pcall(sys.ask, "files.read", "wallpaper-galaxy.json", "json")
                if ok and type(saved) == "table" and saved.rule == RULE then
                    for f, e in pairs(saved) do
                        if type(e) == "table" and e.x then G.data[f] = e end
                    end
                end
                local missing, all_laid = 0, true
                for _, f in ipairs(wp_files) do
                    if not G.data[f] then
                        G.queue[#G.queue + 1] = f
                        missing = missing + 1
                    end
                end
                if missing == 0 then
                    G.laid = true
                    build()
                else
                    G.total = missing
                    text.gal_status = string.format("Reading your wallpapers…  0 of %d", missing)
                    pump()
                end
            end)
        end)
    end
    every(2000, function() if not G.started then start() end end)

    on("gal_toggle", function()
        local opening = not fact.gal_open
        if opening then set_panel("none"); if G.laid then build() end end
        fact.gal_open = opening
    end)

    -- A bead was pressed: its wallpaper blooms out of it. `gal_px`, `gal_py` are where it is on the screen, from the
    -- bottom left, which is where awww counts from. Then the overlay leaves, and the desktop is what is left.
    on("gal_pick", function(i)
        local f = G.files and G.files[i + 1]
        if not f then return end
        local px, py = math.floor((fact.gal_px or 0) + 0.5), math.floor((fact.gal_py or 0) + 0.5)
        wp_apply(f, { "--transition-type", "grow", "--transition-pos", px .. "," .. py, "--transition-duration", "1.6",
                      "--transition-fps", "60", "--transition-step", "60" })
        fact.gal_leaving = true                            -- the overlay fades, and the desktop is what is left to see
        after(1900, function() fact.gal_open = false; fact.gal_leaving = false end)
    end)
    -- The middle of the wheel: any wallpaper, from the middle of the screen.
    on("gal_random", function()
        local f = wp_random_pick()
        if not f then return end
        wp_apply(f, { "--transition-type", "grow", "--transition-pos", "center", "--transition-duration", "1.6",
                      "--transition-fps", "60", "--transition-step", "60" })
        fact.gal_leaving = true
        after(1900, function() fact.gal_open = false; fact.gal_leaving = false end)
    end)
end)()
