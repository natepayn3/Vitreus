-- The brightness service reads the backlight straight from sysfs, but setting
-- it shells out to brightnessctl - so a real backlight can still report a
-- level with nothing able to move it, if the binary itself is missing.
run("which", { "brightnessctl" }, function(_, code)
    fact.bright_avail = code == 0
end)

-- Workspaces only: what moves is moved by the renderer.
ws_urgent = {}
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do busy[d.id] = d.windows > 0 end
    for i = 1, 5 do fact["ws." .. i .. ".busy"] = busy[i] or false end
    fact["ws.active"] = w.active
    -- Going to a workspace answers whatever was asking for attention on it. (Globals: this chunk is at Luau's limit of locals.)
    if ws_urgent[w.active] then ws_urgent[w.active] = nil; fact["ws." .. w.active .. ".urgent"] = false end
end)
-- Starting a program "on the desktop" (not as this shell's child). On Hyprland that is its own `exec_cmd`, so the program comes from the
-- compositor; Hyprland's environment says whether this is Hyprland. On any other desktop (pleamar-wm) there is no such command, and the
-- program is started directly, in a session of its own. Either way it has ~/.local/bin on its PATH, which Hyprland's has not.
on_hyprland = false                       -- (globals, not locals: this chunk is at Luau's limit of 200 locals)
run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code) on_hyprland = code == 0 and (out or "") ~= "" end)
-- `hyprctl monitors -j`, shared. The bar's monitors, the scene's monitor height and the Display page's watch each started it on their own
-- timer, every four or five seconds. A caller that can use an answer up to `max_age` seconds old gets the last one, and one already on
-- its way is waited for instead of starting another; with 0 it is always asked again.
mon_cache = { out = nil, code = nil, at = -1, waiting = nil }
function hypr_monitors(max_age, cb)
    local c = mon_cache
    if c.out and max_age > 0 and os.time() - c.at <= max_age then return cb(c.out, c.code) end
    if c.waiting then table.insert(c.waiting, cb); return end
    c.waiting = { cb }
    run("hyprctl", { "monitors", "-j" }, function(out, code)
        c.out, c.code, c.at = out, code, os.time()
        local w = c.waiting
        c.waiting = nil
        for _, f in ipairs(w) do f(out, code) end
    end)
end
function exec_on_desktop(cmd)
    local line = 'export PATH="$HOME/.local/bin:$PATH"; ' .. cmd
    if on_hyprland then
        local quoted = (string.format("%q", line):gsub("\\\n", "\\n"))
        run("hyprctl", { "dispatch", "hl.dsp.exec_cmd(" .. quoted .. ")" }, function() end)
    else
        run("setsid", { "-f", "sh", "-c", line }, function() end)
    end
end
-- Under pleamar-wm there is no `workspaces` service (it comes from Hyprland); the window manager is a scene, so its workspaces are asked of
-- it over its socket: which one is shown, and which one each window is on.
function wm_get(name, done) run("pleamar", { "--say", "wm", "get " .. name }, function(out) done(tonumber((out or ""):match("%-?[%d.]+")) or ((out or ""):match("true") and 1) or ((out or ""):match("false") and 0) or nil) end) end
function wm_workspaces()
    wm_get("win.shown.0", function(shown)
        if shown then fact["ws.active"] = shown end
        -- Windows take slots 0 to 5 (`win.count` is only the ones on the shown workspace).
        local busy, left = {}, 6
        for i = 0, 5 do
            wm_get("win." .. i .. ".open", function(open)
                local function done(w)
                    if w then busy[w] = true end
                    left = left - 1
                    if left == 0 then for k = 1, 5 do fact["ws." .. k .. ".busy"] = busy[k] or false end end
                end
                if open == 1 then wm_get("win." .. i .. ".workspace", done) else done(nil) end
            end)
        end
    end)
end
after(1500, function()
    if not on_hyprland then every(500, wm_workspaces) end
end)
function goto_workspace(i)
    if on_hyprland then sys.call("workspaces.focus", i)
    else run("pleamar", { "--say", "wm", "emit workspace " .. tonumber(i) }, function() wm_workspaces() end) end
end
on("go", goto_workspace)
-- From the overview: the overview holds the keyboard while it is open, and when it lets go Hyprland gives the focus back to the window
-- you came from, which would take you straight back. So it closes first and the switch comes once it has let go.
on("ov_go", function(i) after(250, function() goto_workspace(i) end) end)

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
    text.clock_mn = string.format("%02d", c.minute)     -- for the clock stacked down the left bar
    text.bar_ap = c.hour < 12 and "am" or "pm"
    text.bar_ap1 = c.hour < 12 and "a" or "p"
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

-- cava only runs while what it feeds is on screen: the bar's swell on the beat, which only the Island layout
-- has (in the Frame layout the bar is the frame, and `pv` is 0), and the equalizer in the player's panel. Left
-- running in the Frame layout it kept the `pulse` spring moving for nothing, and so the whole scene painting at the
-- monitor's rate for as long as music played. (Globals: this chunk is at Luau's limit of locals.)
cava_playing = false
function cava_want()
    if cava_playing and (fact.bar_anchor == "top" or watching) then listen() else hush() end
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
    cava_playing = m.playing == true
    cava_want()
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

local NTR = {}                           -- the notification rules (see "Notification rules and sounds"): decide, play, sync
local function dnd_refresh()
    if dnd_until > 0 and os.time() >= dnd_until then
        dnd_until, dnd_len = 0, 0
        dnd_save()
    end
    local was = dnd
    dnd = dnd_manual or dnd_until > 0
    if dnd ~= was and NTR.sync then NTR.sync() end   -- an app's explanation says whether Do Not Disturb holds it back
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
-- (In a block of its own, like the Display page's: the file's top level is near Luau's limit of 200 locals in one scope.)
do
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
        -- Whether hypridle is running: every five seconds while the Controls panel (where the Caffeine tile is) is open, every thirty otherwise.
        caf_ticks = 0
        every(5000, function()
            caf_ticks = caf_ticks + 1
            if fact.panel == "controls" or caf_ticks % 6 == 0 then caf_poll() end
        end)
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
end

-- Bluetooth only says a device's name inside its `devices` list, not as a
-- top-level field - so the connected one (there is at most one that matters
-- here) is picked out here, the same way the audio watcher below picks the
-- default output out of its list. `bt_list` is the same list again, kept only
-- so a row's tap (a position - see the Wi-Fi list below for why) can find its
-- address.
-- (In a block of its own, like the Display page's: the file's top level is near Luau's limit of 200 locals in one scope.)
do
local bt_list = {}
local bt_last = nil                       -- the last thing the service said
local bt_sig = nil                        -- what the list said last time it was handed over
local bt_scanning = false                 -- a scan is running (see `bt_scan` below)

-- The list is built here: what is connected first, then what is paired, then the
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
local bt_prof_refresh = function() end   -- the open device's audio profiles (set below)

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
        bt_prof_refresh()
    end
end

sys.watch("bluetooth", function(b)
    bt_last = b
    bt_render()
end)

on("fact:bt_open_row", function(i)
    local d = i >= 0 and bt_list[i + 1] or nil
    bt_open_addr = d and d.address or nil
    bt_prof_refresh()
end)

-- The audio profile of the open, connected device (High Fidelity, Headset, Off...). PipeWire keeps it on the device's card, so it is read with
-- `pactl -f json list cards` and set with `pactl set-card-profile`, as the mixer does. A call flips a headset to the telephone profile (mono, mic on)
-- and nothing flips it back, which is what this is for. A profile the device does not offer right now is left out: its pill would do nothing.
-- It is read when a row opens, when the list changes (a connection) and every few seconds while one is open, since a call can change it.
do
local BTP = { card = nil, profs = {}, active = nil }

local function bt_prof_label(name)
    local n = name:lower()
    if n == "off" then return "Off" end
    local codec = (n:match("^a2dp%-sink[-_]?(.*)$"))
    if codec then return codec == "" and "Hi-Fi" or ("Hi-Fi (" .. codec:upper():gsub("_", " ") .. ")") end
    codec = (n:match("^headset%-head%-unit[-_]?(.*)$")) or (n:match("^handsfree%-head%-unit[-_]?(.*)$"))
    if codec then return codec == "" and "Headset" or ("Headset (" .. codec:upper():gsub("_", " ") .. ")") end
    if n:find("^a2dp%-source") then return "Audio source" end
    return name
end

local function bt_prof_rank(name)
    local n = name:lower()
    if n:find("^a2dp%-sink") then return 0 end
    if n:find("^headset") or n:find("^handsfree") then return 1 end
    if n == "off" then return 9 end
    return 5
end

local function bt_prof_show()
    local n = #BTP.profs
    for i = 0, 5 do
        local pr = BTP.profs[i + 1]
        fact["bt_po." .. i] = pr ~= nil
        fact["bt_pa." .. i] = pr ~= nil and pr.name == BTP.active
        text["bt_pl." .. i] = pr and pr.label or ""
    end
    -- the heading and its hairline (30), then two to a line, 26 apart; nothing to choose between with fewer than two
    fact.bt_pf_h = n >= 2 and (math.ceil(n / 2) * 26 + 30) or 0
end

local function bt_prof_clear()
    BTP.card, BTP.profs, BTP.active = nil, {}, nil
    bt_prof_show()
end

bt_prof_refresh = function()
    local addr = bt_open_addr
    local dev
    for _, r in ipairs(bt_list) do if r.address == addr then dev = r end end
    if not addr or not dev or not dev.connected then
        if BTP.card ~= nil or #BTP.profs > 0 then bt_prof_clear() end
        return
    end
    local want = ("bluez_card." .. addr:gsub(":", "_")):upper()
    run("pactl", { "-f", "json", "list", "cards" }, function(out, code)
        if code ~= 0 or bt_open_addr ~= addr then return end
        local ok, cards = pcall(json.decode, out or "")
        if not ok or type(cards) ~= "table" then return end
        local found
        for _, c in ipairs(cards) do
            if type(c) == "table" and type(c.name) == "string" and c.name:upper() == want then found = c end
        end
        if not found or type(found.profiles) ~= "table" then
            -- the card is not there (yet): nothing to choose from
            bt_prof_clear()
            return
        end
        local profs = {}
        for pn, p in pairs(found.profiles) do
            local off = type(p) == "table" and (p.available == false or p.available == "no")
            if not off then profs[#profs + 1] = { name = pn, label = bt_prof_label(pn) } end
        end
        table.sort(profs, function(x, y)
            local rx, ry = bt_prof_rank(x.name), bt_prof_rank(y.name)
            if rx ~= ry then return rx < ry end
            return x.name < y.name
        end)
        while #profs > 6 do table.remove(profs) end
        BTP.card, BTP.profs, BTP.active = found.name, profs, found.active_profile
        bt_prof_show()
    end)
end

on("bt_prof_set", function(i)
    local pr = BTP.profs[math.floor(i + 0.5) + 1]
    if not pr or not BTP.card then return end
    BTP.active = pr.name                      -- the pill answers at once; the next read says what PipeWire did
    bt_prof_show()
    run("pactl", { "set-card-profile", BTP.card, pr.name }, function()
        after(600, bt_prof_refresh)
    end)
end)

every(3000, function()
    if bt_open_addr then bt_prof_refresh() end
end)
end

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
-- `bluetoothctl --timeout 12 scan on`: pleamar's own `bluetooth.scan` answers
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
end

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
local function key(y, m, d) return string.format("%04d-%02d-%02d", y, m, d) end
local function today()
    local t = os.date("*t")
    return t.year, t.month, t.day
end
-- (In a block of its own, like the Display page's: the file's top level is near Luau's limit of 200 locals in one scope.)
do
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

end
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

-- Under pleamar-wm the list comes from its scene: every slot (0 to 15) that is open, with its title, program, workspace and focus.
function refresh_tasks_wm()
    local slots, left = {}, 16
    local function finish()
        local list = {}
        for i = 0, 15 do if slots[i] then list[#list + 1] = slots[i] end end
        table.sort(list, function(a, b)
            if a.active ~= b.active then return a.active end
            if a.wsn ~= b.wsn then return a.wsn < b.wsn end
            return a.title:lower() < b.title:lower()
        end)
        local rows = {}
        task_addrs = {}
        for i, w in ipairs(list) do
            if i > 12 then break end
            rows[i] = { title = w.title, ws = tostring(w.wsn), active = w.active, icon = apps_by_class[w.app:lower()] or w.app:lower() }
            task_addrs[i] = w
        end
        local sig = {}
        for i, r in ipairs(rows) do sig[i] = r.title .. "|" .. r.ws .. "|" .. tostring(r.active) .. "|" .. tostring(r.icon) end
        local joined = table.concat(sig, "\n")
        if joined ~= last_task_sig then
            last_task_sig = joined
            model.tasks = rows
        end
    end
    local function raw(name, cb) run("pleamar", { "--say", "wm", "get " .. name }, function(out) cb((out or ""):gsub("%s+$", "")) end) end
    for i = 0, 15 do
        raw("win." .. i .. ".open", function(open)
            if open ~= "true" then left = left - 1; if left == 0 then finish() end; return end
            local w = { slot = i }
            raw("win." .. i .. ".title", function(t)
                w.title = t
                raw("win." .. i .. ".app", function(a)
                    w.app = a
                    raw("win." .. i .. ".workspace", function(ws)
                        w.wsn = tonumber(ws) or 0
                        raw("win." .. i .. ".focused", function(f)
                            w.active = f == "true"
                            if w.title == "" then w.title = w.app ~= "" and w.app or "Window" end
                            slots[i] = w
                            left = left - 1
                            if left == 0 then finish() end
                        end)
                    end)
                end)
            end)
        end)
    end
end

local function refresh_tasks()
    if not on_hyprland then return refresh_tasks_wm() end
    run("hyprctl", { "clients" }, function(out, code)
        if code ~= 0 then return end
        local list = {}
        local pc = parse_clients(out)
        for _, w in ipairs(pc) do
            if w.mapped == "1" then list[#list + 1] = w end
        end
        -- The one with the keyboard first, then by workspace, then by title.
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

-- Hyprland says `urgent>>ADDRESS` on its event socket when a window asks for attention. If it is on a workspace that is out of view, that
-- workspace's dot warms until it is visited (see the workspaces watch at the top).
function window_urgent(addr)
    run("hyprctl", { "clients" }, function(out, code)
        if code ~= 0 then return end
        for _, w in ipairs(parse_clients(out)) do
            if w.addr == addr then
                local n = tonumber((w.workspace or ""):match("^(-?%d+)"))
                if n and n >= 1 and n <= 5 and n ~= tonumber(fact["ws.active"]) then
                    ws_urgent[n] = true
                    fact["ws." .. n .. ".urgent"] = true
                end
                return
            end
        end
    end)
end
function watch_urgent()
    run("printenv", { "XDG_RUNTIME_DIR" }, function(rt)
        run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(sig)
            rt, sig = (rt or ""):gsub("%s+$", ""), (sig or ""):gsub("%s+$", "")
            if rt == "" or sig == "" then return end
            spawn("socat", { "-u", "UNIX-CONNECT:" .. rt .. "/hypr/" .. sig .. "/.socket2.sock", "-" }, function(line)
                local addr = line:match("^urgent>>(%x+)")
                if addr then window_urgent(addr) end
            end, function() after(3000, watch_urgent) end)
        end)
    end)
end
after(2000, function() if on_hyprland then watch_urgent() end end)

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
    cava_want()
end)
on("fact:bar_anchor", function() cava_want() end)
every(1000, function() if watching then refresh_tasks() end end)
-- This Hyprland takes its dispatchers in Lua. `close` has no way to name a window that is not the
-- focused one (a selector it does not understand is ignored, and the focused window closes), so a
-- row's close button first focuses that window, checks it really has the focus, and only then closes.
local function focus_window(addr, then_fn)
    run("hyprctl", { "dispatch", 'hl.dsp.focus({ window = "address:0x' .. addr .. '" })' }, then_fn or function() end)
end
function wm_say(line, fn) run("pleamar", { "--say", "wm", line }, fn or function() end) end
on("task_focus", function(i)
    local addr = task_addrs[i + 1]
    if type(addr) == "table" then
        wm_say("emit workspace " .. addr.wsn)
        after(150, function() wm_say("emit focus_slot " .. addr.slot, function() after(300, refresh_tasks) end) end)
    elseif addr then focus_window(addr) end
end)
on("task_close", function(i)
    local addr = task_addrs[i + 1]
    if type(addr) == "table" then wm_say("emit close_slot " .. addr.slot, function() after(400, refresh_tasks) end) return end
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
-- The drawer's own state ("volume", "notif" or "none", in `nt_queue.osd`), mirrored into the scene's `osd_on`. It is not a value of `panel`,
-- so it shows beside Settings, the search, the desk... and never takes the place of a panel the user opened. (Kept on `nt_queue`, not in
-- locals of their own: a chunk may only have 200 of those, and this file is at the limit.)
nt_queue.osd = "none"
function nt_queue.set_osd(name)
    nt_queue.osd = name
    fact.osd_on = name ~= "none"
end

local function panel_is(name) return tostring(cur_panel) == name end
-- The scene tells the logic when `panel` changes from its side, not when the logic changes it, so
-- every write from here also updates the local copy.
local function set_panel(name)
    cur_panel = name
    nt_queue.want = name     -- what was asked for: the scene closes an open panel before opening another (it goes through "none"), see below
    fact.panel = name
end
local function osd_free() return true end

local function hide_osd(kind)
    if nt_queue.osd == (kind == "vol" and "volume" or "notif") then nt_queue.set_osd("none") end
end

-- Volume: whenever the level or the mute changes with nothing else open.
local last_vol, last_mute = nil, nil
sys.watch("audio", function(a)
    local vol = math.floor((a.volume or 0) * 100 + 0.5)
    local mute = a.muted and true or false
    local changed = last_vol ~= nil and (vol ~= last_vol or mute ~= last_mute)
    last_vol, last_mute = vol, mute
    if not changed then return end
    if nt_queue.osd == "notif" and nt_now and nt_now.n then
        -- The volume comes first: the notification on screen goes back to the front of the queue and shows again once the volume has gone.
        table.insert(nt_queue, 1, nt_now.n)
        nt_now = nil
    end
    osd_gen = osd_gen + 1
    local gen = osd_gen
    nt_queue.hold = true            -- no notification is shown while the volume is (see `pump`)
    fact.osd_kind = "vol"
    nt_queue.set_osd("volume")
    after(2000, function()
        if gen == osd_gen then
            hide_osd("vol")
            nt_queue.hold = false
            if nt_queue.pump then nt_queue.pump() end      -- `pump` is declared further down
        end
    end)
end)

-- Notifications: Vitreus is the notification server now, so this is where they arrive.
local function strip(s)
    return ((s or ""):gsub("<[^>]*>", ""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'))
end

-- (all of it in one scope, exposing three names: a Lua chunk may only have 200 local variables, and this file is long)
do
-- ── Notification rules and sounds ──────────────────────────────────────────────────────────────────────────────
-- ONE place decides what happens to an arriving notification (`decide`): is it recorded in
-- the history, is it shown, does it make a sound, how long does it stay. A rule belongs to an app (its name, lower-cased: the
-- notification service does not say more than that), and only what differs from the defaults is kept. The rules, the apps that have
-- spoken (so the list of them does not depend on a history that is cleared) and the global switches are in `notification-rules.json`.
--
--   mute    no popup (still in the history)        silent   no sound           bypass   shows even in Do Not Disturb
--   hide    not even in the history                sound    one of the sounds below (0: the default one)
--   timeout 0 the usual, else milliseconds, -1 until dismissed         urgency  0 as sent, 1 low, 2 normal, 3 critical
local NT_SOUNDS = {
    { "message-new-instant", "Message" }, { "message", "Soft" }, { "bell", "Bell" }, { "dialog-information", "Info" },
    { "complete", "Done" }, { "device-added", "Device" }, { "alarm-clock-elapsed", "Alarm" }, { "dialog-warning", "Warning" },
}
local NT_SOUND_DIR = "/usr/share/sounds/freedesktop/stereo/"
local NT_TIMEOUTS = { 0, 4000, 8000, 15000, -1 }
local nt_rules = {}                          -- key -> { mute, silent, bypass, hide, sound, timeout, urgency } (sparse)
local nt_apps = {}                           -- key -> { label, count }
local nt_glob = { sounds = true, sound = 1, allow_critical = true }
local nt_sel = nil                           -- the app whose rules are open in Settings
local nt_dirty = false
local nt_list = {}                           -- the apps as Settings lists them (sorted), by position
local nt_sync_ui                             -- (defined below: `decide` needs it before it exists)

local RULE_DEFAULTS = { mute = false, silent = false, bypass = false, hide = false, sound = 0, timeout = 0, urgency = 0 }
local function nt_key(app) return ((app or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower() end
local function rule_for(key)
    local r, stored = {}, nt_rules[key] or {}
    for k, v in pairs(RULE_DEFAULTS) do if stored[k] ~= nil then r[k] = stored[k] else r[k] = v end end
    return r
end
local function nt_save()
    nt_dirty = false
    pcall(sys.call, "files.write", "notification-rules.json", { rules = nt_rules, apps = nt_apps, global = nt_glob })
end
local function nt_play(idx)
    local snd = NT_SOUNDS[idx] or NT_SOUNDS[1]
    run("pw-play", { "--volume=0.7", NT_SOUND_DIR .. snd[1] .. ".oga" }, function() end)
end

-- What becomes of this one: recorded, shown, heard, and for how long.
local function decide(n)
    local key = nt_key(n.app ~= "" and n.app or "system")
    local a = nt_apps[key]
    if not a then a = { label = (n.app ~= nil and n.app ~= "") and n.app or "System", count = 0 }; nt_apps[key] = a end
    a.count = a.count + 1
    if not nt_dirty then nt_dirty = true; after(4000, function() if nt_dirty then nt_save() end end) end
    nt_sync_ui()                                   -- the list in Settings follows what has been heard

    local r = rule_for(key)
    local u = tostring(n.urgency)
    local sent = (u == "critical" or u == "2") and 3 or ((u == "low" or u == "0") and 1 or 2)
    local eff = r.urgency > 0 and r.urgency or sent
    local critical = eff == 3
    local d = { key = key, record = true, show = true, sound = false, critical = critical, timeout = 4000, sound_idx = 1 }
    if r.hide then d.record = false; d.show = false; return d end
    if r.mute then d.show = false; return d end
    if dnd and not r.bypass and not (critical and nt_glob.allow_critical) then d.show = false; return d end
    d.sound = nt_glob.sounds and not r.silent
    d.sound_idx = r.sound > 0 and r.sound or nt_glob.sound
    if r.timeout == -1 then d.timeout = 0
    elseif r.timeout > 0 then d.timeout = r.timeout
    elseif critical then d.timeout = 0
    else d.timeout = (n.actions ~= nil and #n.actions > 0) and 8000 or 4000 end
    return d
end

-- A plain account of what would happen to an ordinary notification from this app right now, for Settings.
local function nt_explain(key)
    local r = rule_for(key)
    local lines = {}
    if r.hide then lines[#lines + 1] = "Hidden: no popup, no sound, not in the history."
    elseif r.mute then lines[#lines + 1] = "Muted: kept in the history only."
    elseif dnd and not r.bypass then lines[#lines + 1] = "Held back by Do Not Disturb: kept in the history only."
    else
        local quiet = r.silent or not nt_glob.sounds
        lines[#lines + 1] = "Shown" .. (quiet and ", without sound." or (", with " .. NT_SOUNDS[r.sound > 0 and r.sound or nt_glob.sound][2] .. "."))
    end
    if r.urgency > 0 then lines[#lines + 1] = "Urgency is always " .. ({ "low", "normal", "critical" })[r.urgency] .. "." end
    if r.timeout == -1 then lines[#lines + 1] = "Stays until you dismiss it."
    elseif r.timeout > 0 then lines[#lines + 1] = "Stays " .. (r.timeout // 1000) .. " seconds." end
    if r.bypass then lines[#lines + 1] = "Ignores Do Not Disturb." end
    if not nt_rules[key] then lines[#lines + 1] = "No rule of its own: the shell's defaults." end
    return table.concat(lines, " ")
end

-- The facts and models Settings reads.
nt_sync_ui = function()
    fact.ntg_sounds = nt_glob.sounds
    fact.ntg_crit = nt_glob.allow_critical
    fact.ntg_snd = nt_glob.sound - 1
    local list = {}
    for k, a in pairs(nt_apps) do list[#list + 1] = { key = k, label = a.label, count = a.count } end
    table.sort(list, function(x, y) if x.count ~= y.count then return x.count > y.count end return x.label:lower() < y.label:lower() end)
    local rows = {}
    local sel_idx = -1
    for i, e in ipairs(list) do
        if i > 14 then break end
        rows[i] = { name = e.label, info = e.count == 1 and "1 notification" or (e.count .. " notifications"), rule = nt_rules[e.key] ~= nil }
        if e.key == nt_sel then sel_idx = i - 1 end
    end
    model.nta_apps = rows
    fact.nta_sel = sel_idx
    fact.nta_count = #rows
    nt_list = list
    if nt_sel and sel_idx >= 0 then
        local r = rule_for(nt_sel)
        fact.nta_mute, fact.nta_silent, fact.nta_bypass, fact.nta_hide = r.mute, r.silent, r.bypass, r.hide
        fact.nta_urg = r.urgency
        local ti = 0
        for i, v in ipairs(NT_TIMEOUTS) do if v == r.timeout then ti = i - 1 end end
        fact.nta_to = ti
        fact.nta_snd = r.sound
        text.nta_name = nt_apps[nt_sel] and nt_apps[nt_sel].label or nt_sel
        text.nta_explain = nt_explain(nt_sel)
        fact.nta_has_rule = nt_rules[nt_sel] ~= nil
    end
end

-- Settings > Notifications: what the page presses comes back here.
do
    local ok, saved = pcall(sys.ask, "files.read", "notification-rules.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.rules) == "table" then nt_rules = saved.rules end
        if type(saved.apps) == "table" then nt_apps = saved.apps end
        if type(saved.global) == "table" then for k, v in pairs(saved.global) do nt_glob[k] = v end end
    end
    if type(nt_glob.sound) ~= "number" or not NT_SOUNDS[nt_glob.sound] then nt_glob.sound = 1 end
    nt_sync_ui()
end
local function rule_set(field, value)
    if not nt_sel then return end
    local r = nt_rules[nt_sel] or {}
    if value == RULE_DEFAULTS[field] then r[field] = nil else r[field] = value end
    if next(r) == nil then nt_rules[nt_sel] = nil else nt_rules[nt_sel] = r end
    nt_save()
    nt_sync_ui()
end
on("nta_pick", function(i)
    i = math.floor(i + 0.5)
    local e = nt_list[i + 1]
    if not e then return end
    nt_sel = (nt_sel == e.key) and nil or e.key
    nt_sync_ui()
end)
on("nta_flag", function(k)
    k = math.floor(k + 0.5)
    local f = ({ "mute", "silent", "bypass", "hide" })[k + 1]
    if f and nt_sel then rule_set(f, not rule_for(nt_sel)[f]) end
end)
on("nta_urgency", function(v) rule_set("urgency", math.floor(v + 0.5)) end)
on("nta_timeout", function(v) rule_set("timeout", NT_TIMEOUTS[math.floor(v + 0.5) + 1] or 0) end)
on("nta_sound", function(v)
    v = math.floor(v + 0.5)
    rule_set("sound", v)
    if v > 0 then nt_play(v) end
end)
on("nta_reset", function()
    if nt_sel and nt_rules[nt_sel] then nt_rules[nt_sel] = nil; nt_save(); nt_sync_ui() end
end)
on("ntg_flag", function(k)
    k = math.floor(k + 0.5)
    if k == 0 then nt_glob.sounds = not nt_glob.sounds else nt_glob.allow_critical = not nt_glob.allow_critical end
    nt_save()
    nt_sync_ui()
end)
on("ntg_sound", function(v)
    v = math.floor(v + 0.5) + 1
    if NT_SOUNDS[v] then nt_glob.sound = v; nt_save(); nt_sync_ui(); nt_play(v) end
end)
on("nt_test", function()
    run("notify-send", { "-a", "Vitreus", "Notification test", "This is how a notification looks and sounds with the rules as they are." }, function() end)
end)

NTR.decide, NTR.play, NTR.sync = decide, nt_play, nt_sync_ui
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
    local d = n._d or { critical = tostring(n.urgency) == "critical" or tostring(n.urgency) == "2", sound = false, timeout = nil }
    local critical = d.critical
    if d.sound then NTR.play(d.sound_idx) end
    local keys, rows = {}, {}
    for _, a in ipairs(n.actions or {}) do
        if a.key ~= "default" and a.label and a.label ~= "" and #rows < 3 then
            rows[#rows + 1] = { label = a.label }
            keys[#keys + 1] = a.key
        end
    end
    local icon = (n.image ~= nil and n.image ~= "") and n.image or (n.icon or "")
    local body = strip(n.body)
    nt_now = { id = n.id, keys = keys, n = n }
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
    nt_queue.set_osd("notif")
    emit("ntnew")
    -- How long it stays is decided with the rest (`decide`): a critical one until it is dismissed, one with buttons longer, and
    -- an app's own rule over both. 0 is "until it is dismissed".
    local stay = d.timeout or (critical and 0 or (#rows > 0 and 8000 or 4000))
    if stay > 0 then
        after(stay, function()
            if gen == osd_gen and nt_now and nt_now.id == n.id then
                finish_notification()
                after(400, pump)
            end
        end)
    end
end

pump = function()
    if nt_now or #nt_queue == 0 or not osd_free() or nt_queue.hold then return end
    show_notification(table.remove(nt_queue, 1))
end
nt_queue.pump = pump

pcall(sys.call, "notifications.keep", true)
sys.watch("notifications", function(list)
    -- The newest come first. What was already there when Vitreus started is not announced.
    for i = #list, 1, -1 do
        local n = list[i]
        if not nt_seen[n.id] then
            nt_seen[n.id] = true
            if not nt_first then
                local d = NTR.decide(n)
                n._d = d
                if d.record then nt_add(n) end
                if d.show then
                    nt_queue[#nt_queue + 1] = n
                else
                    pcall(sys.call, "notifications.dismiss", n.id)   -- muted, hidden or held back by Do Not Disturb: it never shows
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
    -- The scene closes the panel that is open before it opens the one asked for, so on its way it says "none": that is not a panel being
    -- closed by the user, and the notification on screen must not count as seen because of it.
    if tostring(v) == "none" and nt_queue.want and nt_queue.want ~= "none" then return end
    nt_queue.want = nil
    cur_panel = v
    pump()
end)

-- The drawer closed from the scene (a press on the volume plate): a notification on screen counts as seen, and the next one may come.
on("fact:osd_on", function(v)
    if v == true or tostring(v) == "true" then return end
    nt_queue.osd = "none"
    if nt_now then
        pcall(sys.call, "notifications.dismiss", nt_now.id)
        nt_now = nil
    end
    pump()
end)

-- ── Iris: the palette from the wallpaper ─────────────────────────────────────────────────
-- Iris is run as `iris --json-only <wallpaper>` and its bg / surface / fg / dim / accent / red are used,
-- with a legibility floor on the text and a subtle / medium / bold push on the accent. The result
-- goes to the scene as facts (`pal_*`, three per colour), which `palette-live.plm` turns into its `let` colours with
-- `rgb(...)`; the lock screen, another program, still gets `palette.plm`. `iris.json` in Vitreus's data folder
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
-- `dir` (1 lighter, -1 darker) forces the way it moves; without it, away from the background's lightness.
local function ensure_contrast(hex, bg, min_ratio, dir)
    if contrast(hex, bg) >= min_ratio then return hex end
    local h, s, l = rgb_to_hsl(hex_to_rgb(hex))
    local _, _, bl = rgb_to_hsl(hex_to_rgb(bg))
    dir = dir or (l >= bl and 1 or -1)
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

-- Hyprland's window border follows the palette: the active border is the accent running to its lighter shade (as it did
-- under Synoptik), the inactive one a quiet shade of the background. It is sent to Hyprland at once (`hyprctl eval`) and kept in
-- vitreus_colors.lua, which hyprland.lua loads after hypr_style.lua (the installer adds the line, also to an older install) so it wins on the next start.
iris_fx = {}
function iris_fx.rgba(hex, alpha) return string.format('"rgba(%s%s)"', hex:sub(2), alpha) end
function iris_fx.border_code(pal)
    return string.format(
        "hl.config({ general = { col = { active_border = { colors = { %s, %s }, angle = 45 }, inactive_border = %s } } })",
        iris_fx.rgba(pal.mint, "ff"), iris_fx.rgba(pal.minthi, "ff"), iris_fx.rgba(pal.off, "aa"))
end

-- The palette's names, in the order `palette.plm` lists them. The scene's colours are three facts each (`pal_ink_r`, `_g`, `_b`…, read by
-- `palette-live.plm` as `rgb(...)`), so a new palette is a change of facts: nothing is written for the scene and it does not reload.
iris_fx.order = { "ink", "faint", "mint", "mintlo", "minthi", "onmint", "tint", "panel", "deep", "off", "alert" }
function iris_fx.set_facts(pal)
    for _, k in ipairs(iris_fx.order) do
        local r, g, b = hex_to_rgb(pal[k])
        fact["pal_" .. k .. "_r"], fact["pal_" .. k .. "_g"], fact["pal_" .. k .. "_b"] = r, g, b
    end
end
-- The last palette is kept in `palette.json` (the scene does not import it), so a start paints the colours it ended with from its first frame,
-- not the stock ones until Iris has answered.
do
    local ok, saved = pcall(sys.ask, "files.read", "palette.json", "json")
    if ok and type(saved) == "table" then
        local whole = true
        for _, k in ipairs(iris_fx.order) do
            if type(saved[k]) ~= "string" or not saved[k]:match("^#%x%x%x%x%x%x$") then whole = false end
        end
        if whole then
            iris_fx.set_facts(saved)
            iris_fx.saved = saved
        end
    end
end

function iris_fx.apply_palette(pal)
    iris_fx.last_pal = pal
    local order = iris_fx.order
    local lines = {
        "//  Written by Vitreus's logic from the wallpaper (Iris); edits here are overwritten.",
        "//  `let`s only: the lock screen imports this. (The shell's own scene takes its colours as facts: palette-live.plm.)",
        "",
        "library Palette {",
    }
    for _, k in ipairs(order) do lines[#lines + 1] = string.format("    let %-7s= %s", k, pal[k]) end
    lines[#lines + 1] = "}"
    local text_out = table.concat(lines, "\n") .. "\n"
    if text_out == iris_last_text then return end
    iris_last_text = text_out
    iris_fx.set_facts(pal)
    local same_as_saved = iris_fx.saved ~= nil
    if same_as_saved then
        for _, k in ipairs(order) do if iris_fx.saved[k] ~= pal[k] then same_as_saved = false end end
    end
    if same_as_saved then iris_fx.apply_hypr(); return end
    local keep = {}
    for _, k in ipairs(order) do keep[k] = pal[k] end
    iris_fx.saved = keep
    pcall(sys.call, "files.write", "palette.json", keep)
    with_dirs(function(d)
        -- The lock screen's file, and what pleamar-wm's scene takes from the palette (the focused window's border: the accent's lighter
        -- shade, which shows on glass). Each of those is another program, and reloads itself on a change.
        pcall(sys.call, "files.write", "palette.plm", text_out)
        run("cp", { d.data .. "/palette.plm", d.conf .. "/palette.plm" }, function() end)
        local wm_text = "//  Written by Vitreus's logic from the wallpaper (Iris); edits here are overwritten.\n" ..
            "//  What pleamar-wm's scene takes from it: the colour of the focused window's border.\n\nlibrary WmPalette {\n    let wm_border = " ..
            pal.minthi .. "\n}\n"
        if wm_text ~= iris_cfg.last_wm then
            iris_cfg.last_wm = wm_text
            pcall(sys.call, "files.write", "wm-palette.plm", wm_text)
            run("cp", { d.data .. "/wm-palette.plm", d.conf .. "/wm-palette.plm" }, function() end)
        end
        iris_fx.apply_hypr()
    end)
end

-- What Hyprland is told: the window borders from the palette, and, with the bar down the left (bar_fx.left), the room the strip and the frame
-- take round the windows (gaps_out: the layer's own reserved zone is not moved when the surface changes edge). It is sent at once and kept in
-- vitreus_colors.lua, which hyprland.lua loads last (the installer adds the line). Up on the top, the gaps go back to what they were (bar_fx.orig, read once).
bar_fx = { left = false, orig = nil, on = "all", mons = {} }
bar_fx.restart = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
sleep 0.3
[ "$(stat -c %s "$L" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$L" "$L.1"
# under its keeper when there is one (bin/vitreus-keep): a keeper already looking after it starts it again itself
command -v vitreus-keep >/dev/null 2>&1 && exec vitreus-keep "$P" "$L"
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]
-- The room round the windows is per monitor: only a monitor the bar is on gets the strip's and the frame's room. `bar_fx.mons` is what is plugged in
-- and `bar_fx.on` where the bar is ("all", or a monitor's name); the Bar page below keeps both. A rule for each monitor (`m[NAME]`) says what its
-- own gaps are, and the global gaps are what a monitor without a rule gets, so a monitor plugged in later does not borrow the bar's room.
function iris_fx.gaps_code()
    local o = bar_fx.orig
    if not bar_fx.left and not o then return nil end
    o = o or { 20, 20, 20, 20 }
    local px = math.floor(1.35 * 8 + 0.5) + 13            -- the frame's thickness (8 * u) and a gap
    local lp = math.floor(1.35 * 46 + 0.5) + 14
    local function cfg(g)
        return string.format("hl.config({ general = { gaps_out = { top = %d, right = %d, bottom = %d, left = %d } } })", g[1], g[2], g[3], g[4])
    end
    local function rule(name, g)
        return string.format('hl.workspace_rule({ workspace = "m[%s]", gaps_out = { top = %d, right = %d, bottom = %d, left = %d } })', name, g[1], g[2], g[3], g[4])
    end
    local bar_gaps = { px, px, px, lp }
    local everywhere = (bar_fx.on or "all") == "all"
    local parts = { cfg((bar_fx.left and everywhere) and bar_gaps or o) }
    for _, name in ipairs(bar_fx.mons or {}) do
        if name:match("^[%w%._%-]+$") then
            local has_bar = bar_fx.left and (everywhere or bar_fx.on == name)
            parts[#parts + 1] = rule(name, has_bar and bar_gaps or o)
        end
    end
    return table.concat(parts, " ")
end
function iris_fx.apply_hypr()
    local pal = iris_fx.last_pal
    local parts, keep = {}, {}
    if pal then local c = iris_fx.border_code(pal); parts[#parts + 1] = c; keep[#keep + 1] = c end
    local g = iris_fx.gaps_code()
    if g then parts[#parts + 1] = g; if bar_fx.left then keep[#keep + 1] = g end end
    if #parts == 0 then return end
    run("hyprctl", { "eval", table.concat(parts, " ") }, function() end)
    with_dirs(function(d)
        pcall(sys.call, "files.write", "vitreus_colors.lua",
            "-- Written by Vitreus (the wallpaper's colours, Iris, or greys with Iris off; and the room round the windows with the bar on the left);\n" ..
            "-- edits here are overwritten. hyprland.lua loads it after hypr_style.lua, so it wins over the values there.\n" ..
            table.concat(keep, "\n") .. "\n")
        local hypr = d.conf:gsub("/pleamar/shells/vitreus$", "/hypr")
        run("cp", { "-f", d.data .. "/vitreus_colors.lua", hypr .. "/vitreus_colors.lua" }, function() end)
    end)
end

function iris_fx.build_palette(bg, surface, fg, dim, accent, red)
    -- Text on the accent: whichever of a near-black and a near-white reads better on it.
    local onmint = contrast("#10161a", accent) >= contrast("#f5f7f5", accent) and "#10161a" or "#f5f7f5"
    return {
        ink = fg, faint = dim, mint = accent,
        mintlo = shade(accent, -0.10), minthi = shade(accent, 0.16),
        onmint = onmint, tint = bg, panel = surface,
        deep = blend(bg, "#000000", 0.45), off = blend(bg, fg, 0.22), alert = red,
    }
end

-- The text is not on Iris's `surface`: it is on the glass, which shows the blurred wallpaper through the tint and reads dark whatever the
-- wallpaper (measured behind the Settings text on a light one: #263746 to #434D4C). So Iris is asked for a dark scheme for glass, and every
-- colour that is read is held to 4.5:1 against a reference a little LIGHTER than that glass (the worst case for light text), moving only
-- lighter. The accent counts as text: it labels the chosen page, the breadcrumb, the values. An alert only has to be seen: 3:1.
local function apply_iris(json)
    local surface = json_hex(json, "surface") or "#1e202b"
    local bg = json_hex(json, "bg") or "#12131a"
    local glass = blend(surface, "#ffffff", 0.12)
    local accent = ensure_contrast(intensity_accent(json_hex(json, "accent") or "#94a3b8", iris_cfg.intensity), glass, 4.5, 1)
    local fg = ensure_contrast(json_hex(json, "fg") or "#e6e6e6", glass, 4.5, 1)
    local dim = ensure_contrast(json_hex(json, "dim") or "#a0a4ab", glass, 4.5, 1)
    local red = ensure_contrast(json_hex(json, "red") or "#ef4444", glass, 3.0, 1)
    iris_fx.apply_palette(iris_fx.build_palette(bg, surface, fg, dim, accent, red))
end

-- With Iris off the shell is monochrome: neutral greys, and no hue anywhere but the red of an alert (a low battery, a failed
-- action), which has to stay something you notice.
function iris_fx.apply_mono()
    iris_fx.apply_palette(iris_fx.build_palette("#161616", "#232323", "#ececec", "#9c9c9c", "#d6d6d6", "#ef4444"))
end

local function run_iris(path)
    -- Dark, and for glass (`--glass` adjusts the background for transparency): see apply_iris.
    run("iris", { "--json-only", "--dark", "1", "--glass", path }, function(out, code)
        if code ~= 0 or not out then return end
        local json = out:match("%b{}")
        if json and json_hex(json, "bg") then apply_iris(json) end
    end)
end

-- ── Video wallpapers ─────────────────────────────────────────────────────────────────────────────────
-- A video (mp4, webm) is played by mpvpaper, over awww's wallpaper. awww is given a frame of the video (the poster, taken a second in
-- by ffmpeg and kept in the cache) so that everything which reads "the wallpaper" as a picture still can: Iris, the thumbnails, the colour
-- filter, the hexagon dissolve and the lock screen. What awww says it shows is then mapped back to the video (`wpv.from_poster`).
wpv = { exts = { mp4 = true, webm = true }, frames = nil, dir = nil, cur = nil, next = nil, busy = {} }   -- `dir`: the wallpaper folder

function wpv.is(f)
    local ext = f and f:match("%.(%w+)$")
    return ext ~= nil and wpv.exts[ext:lower()] == true
end

function wpv.poster(f) return wpv.frames .. "/" .. (f:match("([^/]+)$") or f) .. ".jpg" end

-- The video a poster was taken from, or nil when `path` is not a poster.
function wpv.from_poster(path)
    if not (wpv.frames and wpv.dir and path) then return nil end
    local name = path:match("^" .. wpv.frames:gsub("%p", "%%%0") .. "/([^/]+)%.jpg$")
    return name and (wpv.dir .. "/" .. name) or nil
end

-- Calls `fn` with the picture to read for `f`: `f` itself, or its poster (made first when there is none yet; nil when it cannot be).
function wpv.src(f, fn)
    if not wpv.is(f) then fn(f) return end
    if not wpv.frames then fn(nil) return end
    local p = wpv.poster(f)
    local waiting = wpv.busy[p]
    if waiting then waiting[#waiting + 1] = fn return end
    wpv.busy[p] = { fn }
    local function finish(ok)
        local list = wpv.busy[p]
        wpv.busy[p] = nil
        for _, cb in ipairs(list) do cb(ok and p or nil) end
    end
    local function grab(ss, then_fn)
        local args = { "-y", "-loglevel", "error" }
        if ss then args[#args + 1] = "-ss"; args[#args + 1] = ss end
        for _, a in ipairs({ "-i", f, "-frames:v", "1", "-vf", "scale=960:-1", "-q:v", "2", p }) do args[#args + 1] = a end
        run("ffmpeg", args, then_fn)
    end
    run("stat", { "-c", "%s", p }, function(out, code)
        if code == 0 and (tonumber((out or ""):match("%d+")) or 0) > 0 then finish(true) return end
        run("mkdir", { "-p", wpv.frames }, function()
        -- a clip shorter than a second has no frame at 00:00:01: the first one then
        grab("00:00:01", function(_, code)
            if code == 0 then finish(true) return end
            grab(nil, function(_, code2) finish(code2 == 0) end)
        end)
        end)
    end)
end

local function wpv_save()
    pcall(sys.call, "files.write", "wallpaper-video.json", { path = wpv.cur or "" })
end

-- The wallpaper `f` is now what awww shows: stop the video that was playing, and play `f` if it is one.
function wpv.settle(f, keep_running)
    wpv.cur = wpv.is(f) and f or nil
    wpv_save()
    local line = "pkill -x mpvpaper"
    if wpv.cur then
        -- `keep_running`: the shell restarted, and the video it left playing is the one wanted
        line = (keep_running and "pgrep -x mpvpaper > /dev/null || " or (line .. "; ")) .. "exec mpvpaper -vs -o 'input-terminal=no loop-file=inf no-audio panscan=1.0 video-unscaled=no' '*' '"
            .. f:gsub("'", "'\\''") .. "' < /dev/null > /dev/null 2>&1"
    end
    exec_on_desktop(line)
end

-- The hexagon dissolve is still bringing the wallpaper in: it is settled when the dissolve is over (see `check_wallpaper`).
function wpv.flush()
    local n = wpv.next
    wpv.next = nil
    if n then wpv.settle(n[1]) end
end

-- The wallpaper is asked of awww every half second; when it changes, Iris is run on the new one.
local wp_on_change = function(path) end       -- the wallpaper page, further down, takes this over
-- A wallpaper that the hexagon dissolve is bringing in: awww is told about it only when the dissolve is over, a couple of seconds on, and
-- until then it still says the old one. Taking that for a change made from outside would run Iris on the old wallpaper again (the colours
-- went back, and then, when awww caught up, forward again). So what awww says is not believed until it says this, or the time is up.
local wp_pending, wp_pending_until = nil, 0
local function check_wallpaper()
    run("awww", { "query" }, function(out, code)
        if code ~= 0 or not out then return end
        local path = out:match("currently displaying: image: ([^\n]+)")
        if wp_pending then
            if path == wp_pending then wp_pending = nil
            elseif os.time() < wp_pending_until then return
            else wp_pending = nil end
            wpv.flush()                      -- the dissolve is over: the video that goes with it starts (or the old one stops)
        end
        -- awww shows a video's poster; the wallpaper is the video. One that is playing while awww shows something else was replaced
        -- from outside.
        local shown = wpv.from_poster(path) or path
        if path and wpv.cur and shown ~= wpv.cur and not wpv.next then
            wpv.cur = nil
            wpv_save()
            exec_on_desktop("pkill -x mpvpaper")
        end
        if path and shown ~= iris_last_wp then
            iris_last_wp = shown
            wp_on_change(shown)
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
do
    local function show() fact.iris_on = iris_cfg.enabled end
    local function save() pcall(sys.call, "files.write", "iris.json", { enabled = iris_cfg.enabled, intensity = iris_cfg.intensity }) end
    show()
    if not iris_cfg.enabled then iris_fx.apply_mono() end
    -- The switch on the Wallpaper page. Off: greys at once. On: Iris is run on the wallpaper in use, and the colours come back.
    on("iris_toggle", function()
        iris_cfg.enabled = not iris_cfg.enabled
        save()
        show()
        if iris_cfg.enabled then
            if iris_last_wp then run_iris(iris_last_wp) else check_wallpaper() end
        else
            iris_fx.apply_mono()
        end
    end)
end
-- A wallpaper that Vitreus sets is known at once (see `wp_apply`); this is only for one changed from elsewhere, so it
-- does not need to look often. Every look starts a program (`awww query`): twice a second was most of what the shell
-- launched while doing nothing, and every two seconds was still a third of it: every six.
every(6000, check_wallpaper)
check_wallpaper()
-- A video that was playing comes back with the desktop (awww restores its poster; mpvpaper is not restored by anything).
with_dirs(function(d)
    wpv.frames = d.cache .. "/frames"
    local ok, saved = pcall(sys.ask, "files.read", "wallpaper-video.json", "json")
    local f = ok and type(saved) == "table" and saved.path
    if type(f) == "string" and f ~= "" and wpv.is(f) then
        wpv.dir = f:match("^(.*)/[^/]+$")
        wpv.src(f, function(src)
            if not src then return end
            wpv.settle(f, true)
            iris_last_wp = nil                       -- awww's poster was taken for the wallpaper before this was known
            check_wallpaper()
        end)
    else
        check_wallpaper()
    end
end)

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
-- Each wallpaper is tagged with every colour it really has, not the one that covers the most. (Keeping
-- only that one, a dark night scene with neon signs is then just "black": the red, orange and pink that
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
local wp_picker_start = function() end   -- the picker takes this over, further down: it builds as soon as the folder is listed

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
        wpv.src(f, function(src)
        if not src then wp_made[out] = false; left = left - 1; if left == 0 then done() end return end
        -- `jpeg:size` lets the decoder shrink while it reads (a 4K picture is not decoded whole to make a thumbnail), and one
        -- thread each keeps a page of these from taking every core.
        run("magick", { "-limit", "thread", "1", "-define", "jpeg:size=" .. (w * 2) .. "x" .. (h * 2), src .. "[0]",
                        "-thumbnail", w .. "x" .. h .. "^", "-gravity", "center",
                        "-extent", w .. "x" .. h, "-quality", "88", out }, function(_, code)
            wp_made[out] = code == 0
            left = left - 1
            if left == 0 then done() end
        end)
        end)
    end
end

local function wp_show_page()
    local rows, sel = {}, -1
    for i = 1, WP_PER_PAGE do
        local f = wp_view[wp_page * WP_PER_PAGE + i]
        if not f then break end
        local t = crop_path(f, "t")
        rows[i] = { thumb = wp_made[t] == true and t or (wpv.is(f) and "" or f) }
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
                text.wp_curpath = wp_made[pp] == true and pp or (wpv.is(path) and "" or path)
            end
        end)
    else
        text.wp_curpath = wpv.is(path) and "" or path
    end
    for i, f in ipairs(wp_view) do
        if f == path then wp_page = (i - 1) // WP_PER_PAGE break end
    end
    wp_refresh()
end

-- The hexagon dissolve is a scene of its own (wptrans). It is told what was picked, and where on the screen (pixels from the top left),
-- and it has awww switch to the picture itself once it covers the screen. When it is not running there is no answer, and `fail_fn` has
-- awww do the change with a transition of its own.
local function wp_hex(path, x, y, ok_fn, fail_fn)
    local function say(cmd, fn) run("pleamar", { "--say", "wptrans", cmd }, fn) end
    say("text target " .. path, function(_, code)
        if code ~= 0 then fail_fn() return end
        wp_pending, wp_pending_until = path, os.time() + 8
        say("fact ox " .. x, function()
            say("fact oy " .. y, function()
                say("emit go", function() ok_fn() end)
            end)
        end)
    end)
end

-- `how`: awww's transition flags. `hex`, `{ x =, y = }`: the dissolve from that point instead (the wallpaper picker's).
local function wp_apply(path, how, started, hex)
    -- `src`: the picture awww is given: the wallpaper itself, or a video's poster (made first, once)
    wpv.src(path, function(src)
        if not src then return end
        local function by_awww()
            local args = { "img", src }
            for _, a in ipairs(how or { "--transition-type", "fade", "--transition-duration", "0.8" }) do args[#args + 1] = a end
            run("awww", args, function()
                wpv.settle(path)
                if started then started() end     -- `started`: awww has the picture, the change is under way
            end)
        end
        if hex then
            -- the video (or the stop of the one playing) waits for the end of the dissolve: see `check_wallpaper`
            wp_hex(src, hex.x, hex.y, function() wpv.next = { path }; if started then started() end end, by_awww)
        else
            by_awww()
        end
        wp_on_change(path)
        -- The path is known: Iris starts now, while the fade plays, not when the watcher next notices the
        -- change. Marking it seen stops the watcher running it a second time.
        if iris_cfg.enabled and iris_last_wp ~= path then
            iris_last_wp = path
            run_iris(src)
        end
    end)
end

-- Tag every wallpaper that has no colour yet, three at a time so the shell stays quick.
local function wp_tags_write()
    local out = { rule = WP_RULE }
    for path, tags in pairs(wp_tags) do out[path] = tags end
    pcall(sys.call, "files.write", "wallpaper-colors.json", out)
end

local WP_NEUTRAL = { black = true, white = true, gray = true, brown = true }

local function wp_analyse_one(f, done)
  wpv.src(f, function(src)
    if not src then done() return end
    run("magick", { src .. "[0]", "-thumbnail", "100x100", "-colors", "32", "-format", "%c", "histogram:info:" }, function(out, code)
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
            wpv.dir = wp_dir
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
                    if ext == "jpg" or ext == "jpeg" or ext == "png" or ext == "webp" or ext == "gif" or ext == "bmp" or wpv.exts[ext] then
                        wp_files[#wp_files + 1] = wp_dir .. "/" .. name
                    end
                end
                wp_rebuild_view()
                if wp_cur then wp_on_change(wp_cur) else wp_refresh() end
                wp_load_tags()
                wp_picker_start()
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
-- Seeded once, here, from the time: seeding on every pick from the clock service's time (which only changes now and then) gave the same
-- number to every press in between, so Random flipped between two wallpapers.
math.randomseed(os.time())
-- A random one from what the colour filter leaves, never the one already in use.
local function wp_random_pick()
    local pool = wp_view
    if #pool == 0 or (#pool == 1 and pool[1] == wp_cur) then return nil end
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
-- Four more, all of them multipliers or switches the scene reads: `rim` (how bright the light along the edge is, 0 to 2, 1 as it
-- was), `refr` (how thick the glass is, 0 to 2) and `disp` (the rainbow at the edge, 0 to 2.5) only show when `bend` is on,
-- which swaps the compositor's blur for glass that really bends what is behind it. The blur's own strength is Hyprland's, and
-- lives in the Hyprland section below (it puts its setter in `glass.set_blur`).
local glass = { frost = 1, opacity = 1, rim = 1, refr = 1, disp = 1, bend = false }
local GLASS_OP_MIN = 0.3
local glass_save_waiting = false

local function glass_refresh()
    fact.glass_frost = glass.frost
    fact.glass_op = glass.opacity
    text.glass_frost_text = string.format("%d%%", math.floor(glass.frost * 100 + 0.5))
    text.glass_op_text = string.format("%d%%", math.floor(glass.opacity * 100 + 0.5))
    fact.glass_rim = glass.rim
    fact.glass_refr = glass.refr
    fact.glass_disp = glass.disp
    fact.glass_bend = glass.bend
    text.glass_rim_text = string.format("%d%%", math.floor(glass.rim * 100 + 0.5))
    text.glass_refr_text = string.format("%d%%", math.floor(glass.refr * 100 + 0.5))
    text.glass_disp_text = string.format("%d%%", math.floor(glass.disp * 100 + 0.5))
end
local function glass_save_soon()
    if glass_save_waiting then return end
    glass_save_waiting = true
    after(500, function()
        glass_save_waiting = false
        pcall(sys.call, "files.write", "glass.json", { frost = glass.frost, opacity = glass.opacity, rim = glass.rim, refr = glass.refr, disp = glass.disp, bend = glass.bend })
    end)
end

do
    local ok, saved = pcall(sys.ask, "files.read", "glass.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.frost) == "number" then glass.frost = math.max(0, math.min(1, saved.frost)) end
        if type(saved.opacity) == "number" then glass.opacity = math.max(GLASS_OP_MIN, math.min(1, saved.opacity)) end
        if type(saved.rim) == "number" then glass.rim = math.max(0, math.min(2, saved.rim)) end
        if type(saved.refr) == "number" then glass.refr = math.max(0, math.min(2, saved.refr)) end
        if type(saved.disp) == "number" then glass.disp = math.max(0, math.min(2.5, saved.disp)) end
        if type(saved.bend) == "boolean" then glass.bend = saved.bend end
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
-- A slider's track is 0 to 1; these turn it into the value, in steps of 5 %.
function glass.step(t, top) return math.floor(math.max(0, math.min(1, t)) * top * 20 + 0.5) / 20 end
on("glass_rim_set", function(t) glass.rim = glass.step(t, 2); glass_refresh(); glass_save_soon() end)
on("glass_refr_set", function(t) glass.refr = glass.step(t, 2); glass_refresh(); glass_save_soon() end)
on("glass_disp_set", function(t) glass.disp = glass.step(t, 2.5); glass_refresh(); glass_save_soon() end)
on("glass_bend_toggle", function() glass.bend = not glass.bend; glass_refresh(); glass_save_soon() end)
on("glass_reset", function()
    glass.frost, glass.opacity, glass.rim, glass.refr, glass.disp, glass.bend = 1, 1, 1, 1, 1, false
    if glass.set_blur then glass.set_blur(3, 1) end
    glass_refresh()
    glass_save_soon()
end)

-- ── Display ───────────────────────────────────────────────────────────────────────────────────────────
-- The Display page of the settings: what Hyprland reports for each monitor (`hyprctl monitors -j`)
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
local disp_wp = {}                        -- monitor name -> the wallpaper it shows (what awww says)
local disp_grab_origin = nil               -- how the canvas maps to the desk (`f` the scale): set each time it is drawn

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
    local cw, ch, pad = 400, 190, 12
    local f, ox, oy
    if disp_grab and disp_grab_origin then
        -- while a box is being dragged the canvas holds still: refitting it on every move shifts the ground under
        -- the pointer, which is what made the drag jump to the top or bottom
        f, ox, oy, x0, y0 = disp_grab_origin.f, disp_grab_origin.ox, disp_grab_origin.oy, disp_grab_origin.x0, disp_grab_origin.y0
    else
        -- room round the monitors (a quarter of the biggest one on each side), so a box can be moved past the others
        local mw, mh = 0, 0
        for _, m in ipairs(disp_mons) do
            local w, h = disp_size(m, disp_draft[m.name])
            mw, mh = math.max(mw, w), math.max(mh, h)
        end
        x0, y0, x1, y1 = x0 - mw / 4, y0 - mh / 4, x1 + mw / 4, y1 + mh / 4
        f = math.min((cw - 2 * pad) / math.max(1, x1 - x0), (ch - 2 * pad) / math.max(1, y1 - y0))
        ox = (cw - (x1 - x0) * f) / 2
        oy = (ch - (y1 - y0) * f) / 2
    end
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
            text["disp_b." .. i .. ".scale"] = (d.scale == "auto" and "auto" or disp_num(d.scale, 2)) .. "×"
            text["disp_b." .. i .. ".wp"] = disp_wp[m.name] or ""
            fact["disp_b." .. i .. ".main"] = d.x == 0 and d.y == 0
        end
    end
    disp_grab_origin = { f = f, x0 = x0, y0 = y0, ox = ox, oy = oy }
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
        local mm = disp_mons[4 - i]       -- the slots run right to left, and slot i selects monitor 3 - i (0-based)
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
local function disp_read(done, max_age)
    hypr_monitors(max_age or 0, function(out, code)
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
        -- the wallpaper each monitor shows, for the canvas's tiles
        run("awww", { "query" }, function(o, c)
            if c ~= 0 or not o then return end
            local wp = {}
            for line in o:gmatch("[^\n]+") do
                local name, path = line:match("^:%s*([^:]+):.-currently displaying: image: (.+)$")
                if name then wp[name] = path end
            end
            disp_wp = wp
            disp_render()
        end)
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
on("disp_rot_mon", function(i)
    local m = disp_mons[i + 1]
    if not m then return end
    disp_sel = i + 1
    disp_edit(function(_, d) d.transform = ((d.transform or 0) % 4 + 1) % 4 end)
end)
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
    local o = disp_grab_origin
    local f = o.f
    disp_grab = { i = i, dx = fact.disp_px - (o.ox + (d.x - o.x0) * f), dy = fact.disp_py - (o.oy + (d.y - o.y0) * f) }
    disp_render()
end)
on("disp_drag", function()
    if not disp_grab or not disp_grab_origin then return end
    local m = disp_mons[disp_grab.i]
    if not m then return end
    local d = disp_draft[m.name]
    local o = disp_grab_origin
    local f = o.f
    local x = o.x0 + (fact.disp_px - disp_grab.dx - o.ox) / f
    local y = o.y0 + (fact.disp_py - disp_grab.dy - o.oy) / f
    local w, h = disp_size(m, d)
    local snap = 4 / f                     -- four canvas units, in desk pixels: close enough to feel the edge, not to fight the pointer
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
    end, 4)
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
-- Fetched from Open-Meteo: the place is found by IP (ipwho.is) unless `location` is set
-- in `weather-config.json` in Vitreus's data folder, when it is looked up by name; then the current
-- conditions and the next seven days. `units` there is "fahrenheit" (the default) or "celsius".
-- The sandbox has no JSON parser for what curl brings, so curl writes each answer into the data folder
-- and `files.read` parses it.
-- (In a block of its own, like the Display page's: the file's top level is near Luau's limit of 200 locals in one scope.)
do
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
end

-- ── Settings > Hyprland ───────────────────────────────────────────────────────────────────────────────────────
-- Window-manager knobs: layout, gaps, border resize, tearing, animations and input. The values
-- shown are what Hyprland says now. A change is sent with `hyprctl eval` at once, and once it has settled it is
-- written to vitreus_hypr.lua, which hyprland.lua loads after hypr_style.lua (the installer adds the line, also to an older install) so it wins on the next start.
do
    local LAYOUTS = { "dwindle", "master", "scrolling" }
    local hy = { layout = 3, gaps = 5, round = 10, border = 3, blur = 3, passes = 1, resize = false, tear = false, anim = true, sens = 0, follow = 1, nat = false }
    local hy_dirty, hy_waiting = false, false

    local function hy_show()
        fact.hy_layout = hy.layout
        fact.hy_gaps = hy.gaps
        fact.hy_round = hy.round
        fact.hy_border = hy.border
        fact.hy_blur = hy.blur
        text.hy_blur_text = string.format("%d", hy.blur)
        fact.hy_resize = hy.resize
        fact.hy_tear = hy.tear
        fact.hy_anim = hy.anim
        fact.hy_sens = hy.sens
        fact.hy_follow = hy.follow
        fact.hy_nat = hy.nat
        text.hy_gaps_text = string.format("%d px", hy.gaps)
        text.hy_round_text = string.format("%d px", hy.round)
        text.hy_border_text = string.format("%d px", hy.border)
        text.hy_sens_text = string.format("%.2f", hy.sens)
    end

    local function b(v) return v and "true" or "false" end
    local function hy_code()
        return string.format(
            "hl.config({ general = { gaps_in = %d, border_size = %d, layout = \"%s\", resize_on_border = %s, allow_tearing = %s }, " ..
            "decoration = { rounding = %d, blur = { size = %d, passes = %d } }, animations = { enabled = %s }, input = { sensitivity = %.2f, follow_mouse = %d, touchpad = { natural_scroll = %s } } })",
            hy.gaps, hy.border, LAYOUTS[hy.layout], b(hy.resize), b(hy.tear), hy.round, hy.blur, hy.passes, b(hy.anim), hy.sens, hy.follow, b(hy.nat))
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
        opt("general:border_size", function(j) local n = tonumber(j.int); if n then hy.border = n; hy_show() end end)
        opt("decoration:rounding", function(j) local n = tonumber(j.int); if n then hy.round = n; hy_show() end end)
        opt("decoration:blur:size", function(j) local n = tonumber(j.int); if n then hy.blur = n; hy_show() end end)
        opt("decoration:blur:passes", function(j) local n = tonumber(j.int); if n then hy.passes = n; hy_show() end end)
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
    on("hy_border_set", function(t) hy.border = math.floor(math.max(0, math.min(1, t)) * 10 + 0.5); hy_changed() end)
    on("hy_round_set", function(t) hy.round = math.floor(math.max(0, math.min(1, t)) * 30 + 0.5); hy_changed() end)
    on("hy_sens_set", function(t)
        hy.sens = math.floor((math.max(0, math.min(1, t)) * 2 - 1) * 20 + 0.5) / 20
        hy_changed()
    end)
    -- The blur behind the glass, from the Glass page: its size, 1 to 20, and more passes as it grows so a big blur stays smooth.
    local function set_blur(size, passes)
        hy.blur = math.max(1, math.min(20, math.floor(size + 0.5)))
        hy.passes = passes or (1 + math.floor((hy.blur - 1) / 6))
        hy_changed()
    end
    glass.set_blur = set_blur
    on("glass_blur_set", function(t) set_blur(1 + math.max(0, math.min(1, t)) * 19) end)
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

-- ── Settings > Pleamar-WM ─────────────────────────────────────────────────────────────────────────────────────
-- The window manager is a scene, so its layout, gaps and effects are facts of it, set over its socket at once and kept in wm.json (the scene
-- forgets them when it reloads; they are put back when this shell starts). The input lines (pointer, touchpad, idle) are session.conf's,
-- which pleamar-wm reads when it starts: they are rewritten here and apply at the next login.
do
    local wm = { layout = 0, share = 0.56, gap = 12, free = false, rain = false, snow = false, bw = 1.5, ba = 70, rad = 12, shd = 100, tb = 22, tbo = 72, wa = 100, wi = 100, fr = 80 }
    local inp = { ms = 0, ts = 0, nat = false, tap = false, idle = 7, maccel = "adaptive", taccel = "adaptive", dwt = nil }
    local wm_waiting, in_waiting = false, false

    local function say(line) run("pleamar", { "--say", "wm", line }, function() end) end
    local function b(v) return v and "true" or "false" end

    local function wm_show()
        fact.wm_layout = wm.layout
        fact.wm_share = wm.share
        fact.wm_gap = wm.gap
        fact.wm_free = wm.free
        fact.wm_rain = wm.rain
        fact.wm_snow = wm.snow
        fact.wm_ms = inp.ms
        fact.wm_ts = inp.ts
        fact.wm_nat = inp.nat
        fact.wm_tap = inp.tap
        fact.wm_idle = inp.idle
        fact.wm_bw, fact.wm_ba, fact.wm_rad = wm.bw, wm.ba, wm.rad
        fact.wm_shd, fact.wm_tb, fact.wm_tbo = wm.shd, wm.tb, wm.tbo
        text.wm_bw_text = string.format("%.1f px", wm.bw)
        text.wm_ba_text = string.format("%d%%", wm.ba)
        text.wm_rad_text = string.format("%d px", wm.rad)
        text.wm_shd_text = string.format("%d%%", wm.shd)
        text.wm_tb_text = string.format("%d px", wm.tb)
        text.wm_tbo_text = string.format("%d%%", wm.tbo)
        fact.wm_wa, fact.wm_wi = wm.wa, wm.wi
        text.wm_wa_text = string.format("%d%%", wm.wa)
        text.wm_wi_text = string.format("%d%%", wm.wi)
        fact.wm_fr = wm.fr
        text.wm_fr_text = string.format("%d%%", wm.fr)
        text.wm_share_text = string.format("%d%%", math.floor(wm.share * 100 + 0.5))
        text.wm_gap_text = string.format("%d px", wm.gap)
        text.wm_ms_text = string.format("%.2f", inp.ms)
        text.wm_ts_text = string.format("%.2f", inp.ts)
        text.wm_idle_text = string.format("%d min", inp.idle)
    end

    local function wm_send()
        say("fact gap " .. wm.gap)
        say("fact ratio " .. wm.share)
        for m = 0, 3 do
            say("fact lay." .. m .. " " .. wm.layout)
            say("fact free." .. m .. " " .. (wm.free and 1 or 0))
        end
        say("fact rain " .. b(wm.rain))
        say("fact snow " .. b(wm.snow))
        say("fact bw " .. wm.bw)
        say("fact ba " .. wm.ba)
        say("fact rad " .. wm.rad)
        say("fact shd " .. wm.shd)
        say("fact tb " .. wm.tb)
        say("fact tbo " .. wm.tbo)
        say("fact wo_a " .. wm.wa)
        say("fact wo_i " .. wm.wi)
        say("fact fr " .. wm.fr)
    end

    local function wm_save()
        pcall(sys.call, "files.write", "wm.json", { layout = wm.layout, share = wm.share, gap = wm.gap, free = wm.free, rain = wm.rain, snow = wm.snow, bw = wm.bw, ba = wm.ba, rad = wm.rad, shd = wm.shd, tb = wm.tb, tbo = wm.tbo, wa = wm.wa, wi = wm.wi, fr = wm.fr })
    end

    local function wm_changed()
        wm_show()
        wm_send()
        if wm_waiting then return end
        wm_waiting = true
        after(800, function() wm_waiting = false; wm_save() end)
    end

    local function conf_path(fn)
        with_dirs(function(d) fn((d.conf:gsub("/shells/vitreus$", "")) .. "/session.conf") end)
    end

    local function onoff(v) return v and "on" or "off" end
    local function in_write()
        conf_path(function(path)
            local pt = string.format("pointer accel %s speed %.2f", inp.maccel, inp.ms)
            local tp = string.format("touchpad accel %s speed %.2f natural %s tap %s", inp.taccel, inp.ts, onoff(inp.nat), onoff(inp.tap))
            if inp.dwt ~= nil then tp = tp .. " dwt " .. inp.dwt end
            -- (two passes: `$a` never fires when the last line is one of those just deleted)
            run("sed", { "-i", "-E", "-e", "/^(pointer|touchpad|idle) /d", path }, function()
                run("sed", { "-i", "-e", "$a\\" .. pt, "-e", "$a\\" .. tp, "-e", "$a\\idle off-after " .. inp.idle * 60, path }, function() end)
            end)
        end)
    end

    local function in_changed()
        wm_show()
        if in_waiting then return end
        in_waiting = true
        after(700, function() in_waiting = false; in_write() end)
    end

    local function wm_read()
        local function num(name, cb) wm_get(name, function(v) if v ~= nil then cb(v) end end) end
        num("gap", function(v) wm.gap = v end)
        num("ratio", function(v) wm.share = v end)
        num("lay.0", function(v) wm.layout = v end)
        num("free.0", function(v) wm.free = v == 1 end)
        num("rain", function(v) wm.rain = v == 1 end)
        num("snow", function(v) wm.snow = v == 1 end)
        num("bw", function(v) wm.bw = v end)
        num("ba", function(v) wm.ba = v end)
        num("rad", function(v) wm.rad = v end)
        num("shd", function(v) wm.shd = v end)
        num("tb", function(v) wm.tb = v end)
        num("tbo", function(v) wm.tbo = v end)
        num("wo_a", function(v) wm.wa = v end)
        num("wo_i", function(v) wm.wi = v end)
        num("fr", function(v) wm.fr = v end)
        conf_path(function(path)
            run("grep", { "-E", "^(pointer|touchpad|idle) ", path }, function(out)
                for line in (out or ""):gmatch("[^\n]+") do
                    local kind = line:match("^(%S+)")
                    local v = {}
                    for k, val in line:gsub("^%S+%s+", ""):gmatch("(%S+)%s+(%S+)") do v[k] = val end
                    if kind == "pointer" then
                        inp.ms = tonumber(v.speed) or inp.ms
                        inp.maccel = v.accel or inp.maccel
                    elseif kind == "touchpad" then
                        inp.ts = tonumber(v.speed) or inp.ts
                        inp.taccel = v.accel or inp.taccel
                        if v.natural then inp.nat = v.natural == "on" end
                        if v.tap then inp.tap = v.tap == "on" end
                        inp.dwt = v.dwt or inp.dwt
                    elseif kind == "idle" then
                        local secs = tonumber(v["off-after"])
                        if secs then inp.idle = math.max(1, math.min(30, math.floor(secs / 60 + 0.5))) end
                    end
                end
                wm_show()
            end)
        end)
        after(400, wm_show)
    end

    wm_show()
    -- The saved choices go back into the window manager when this shell starts (it forgets them when it reloads).
    after(3000, function()
        if on_hyprland then return end
        local ok, saved = pcall(sys.ask, "files.read", "wm.json", "json")
        if ok and type(saved) == "table" then
            wm.layout = math.max(0, math.min(4, tonumber(saved.layout) or 0))
            wm.share = tonumber(saved.share) or wm.share
            wm.gap = tonumber(saved.gap) or wm.gap
            wm.free, wm.rain, wm.snow = saved.free == true, saved.rain == true, saved.snow == true
            wm.bw, wm.ba, wm.rad = tonumber(saved.bw) or wm.bw, tonumber(saved.ba) or wm.ba, tonumber(saved.rad) or wm.rad
            wm.shd, wm.tb, wm.tbo = tonumber(saved.shd) or wm.shd, tonumber(saved.tb) or wm.tb, tonumber(saved.tbo) or wm.tbo
            wm.wa, wm.wi = tonumber(saved.wa) or wm.wa, tonumber(saved.wi) or wm.wi
            wm.fr = tonumber(saved.fr) or wm.fr
            wm_show()
            wm_send()
        end
    end)

    -- The scene is read in again when the wallpaper changes the palette (its border takes a colour from it), and that puts every fact back to its
    -- first value: when the gap is not what was chosen, everything chosen is sent again.
    every(5000, function()
        if on_hyprland then return end
        wm_get("gap", function(v)
            if v ~= nil and v ~= wm.gap then wm_send() end
        end)
    end)

    on("wm_layout_set", function(i) wm.layout = math.max(0, math.min(4, math.floor(i + 0.5))); wm_changed() end)
    on("wm_share_set", function(t) wm.share = math.floor((0.3 + math.max(0, math.min(1, t)) * 0.5) * 100 + 0.5) / 100; wm_changed() end)
    on("wm_gap_set", function(t) wm.gap = math.floor(math.max(0, math.min(1, t)) * 32 + 0.5); wm_changed() end)
    on("wm_toggle", function(k)
        k = math.floor(k + 0.5)
        if k == 0 then wm.free = not wm.free; wm_changed()
        elseif k == 1 then wm.rain = not wm.rain; wm_changed()
        elseif k == 2 then wm.snow = not wm.snow; wm_changed()
        elseif k == 3 then inp.nat = not inp.nat; in_changed()
        else inp.tap = not inp.tap; in_changed() end
    end)
    on("wm_style_set", function(v)
        local i = math.floor(v / 10)
        local t = math.max(0, math.min(1, v - i * 10))
        if i == 0 then wm.bw = math.floor(t * 12 + 0.5) / 2
        elseif i == 1 then wm.ba = math.floor(20 + t * 80 + 0.5)
        elseif i == 2 then wm.rad = math.floor(t * 24 + 0.5)
        elseif i == 3 then wm.shd = math.floor(t * 200 + 0.5)
        elseif i == 4 then wm.tb = math.floor(16 + t * 18 + 0.5)
        elseif i == 5 then wm.tbo = math.floor(40 + t * 60 + 0.5)
        elseif i == 6 then wm.wa = math.floor(40 + t * 60 + 0.5)
        elseif i == 7 then wm.wi = math.floor(40 + t * 60 + 0.5)
        else wm.fr = math.floor(t * 100 + 0.5) end
        wm_changed()
    end)
    on("wm_input_set", function(v)
        local i = math.floor(v / 10)
        local t = math.max(0, math.min(1, v - i * 10))
        if i == 0 then inp.ms = math.floor((t * 2 - 1) * 20 + 0.5) / 20
        elseif i == 1 then inp.ts = math.floor((t * 2 - 1) * 20 + 0.5) / 20
        else inp.idle = math.floor(1 + t * 29 + 0.5) end
        in_changed()
    end)
    on("wm_refresh", function() wm_read() end)
end

-- ── The launcher (SUPER + Space) ──────────────────────────────────────────────────────────────────────────────
-- The launcher. The scene has a field (`text.lq`) and a list (`model.lres`, six rows at most, with
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
                sel = (S.start + i) == S.sel, hasicon = (r.icon or "") ~= "", icon = r.icon or "", deletable = r.del ~= nil,
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
        exec_on_desktop(cmd)
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

    -- Taking an entry out of the history: cliphist reads the entry's line (its id first) on its input, as `decode` does. It has its own
    -- file, so a preview being decoded at the same moment does not read a half-written one.
    local function clip_delete(c)
        with_dirs(function(d)
            pcall(sys.call, "files.write", "lp-del.txt", c.id .. "\t")
            run("cliphist", { "delete" }, function() end, { stdin = d.data .. "/lp-del.txt" })
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
    -- Each command: title, what it is, what it does, and words that find it besides its title (all searched, spaces ignored).
    local COMMANDS = {
        { "Settings: Wallpaper", "open", open_settings("pg_wall"), "background picture image folder slideshow desktop" },
        { "Settings: Glass", "open", open_settings("pg_glass"), "blur transparency frosted liquid look appearance theme" },
        { "Settings: Display", "open", open_settings("pg_disp"), "monitor screen resolution refresh rate scale arrangement vrr position" },
        { "Settings: Night mode", "open", open_settings("pg_night"), "nightlight blue light warm tint redshift filter schedule eyes" },
        { "Night mode: toggle", "action", function() spawn('pleamar --say vitreus "emit night_toggle"') end, "nightlight blue light warm tint redshift filter on off" },
        { "Settings: Hyprland", "open", open_settings("pg_hypr"), "window manager gaps border layout animations tearing input keyboard mouse touchpad" },
        { "Settings: Pleamar-WM", "open", open_settings("pg_wm"), "pleamar wm window manager gaps layout columns rows grid leader floating free rain snow weather pointer mouse touchpad speed natural scroll tap idle screen off keybinds session" },
        { "Settings: About", "open", open_settings("pg_about"), "version info credits vitreus pleamar" },
        { "Settings: System monitor", "open", open_settings("pg_sys"), "cpu gpu ram memory disk network temperature fan processes task manager performance usage" },
        { "Settings: Notifications", "open", open_settings("pg_nt"), "alerts do not disturb dnd sounds rules apps banner mute" },
        { "Settings: Bar", "open", open_settings("pg_bar"), "panel widgets order clock tray media title items layout island frame top left position" },
        { "Settings: Lock screen", "open", open_settings("pg_lock"), "lockscreen lock password mask blur clock date format media player shapes dots asterisks symbols special palette colours colors example live test glyphs vibrant neon pastel monochrome security idle" },
        { "Calendar", "panel", function() set_panel("calendar"); return true end, "date month day reminders schedule" },
        { "Controls", "panel", function() set_panel("controls"); return true end, "quick settings wifi bluetooth volume brightness power profile capture screenshot record" },
        { "Player", "panel", function() set_panel("player"); return true end, "music media playback spotify song pause play next" },
        { "Wallpaper picker", "action", function() spawn('pleamar --say vitreus "emit wp_picker_toggle"') end, "backgrounds wallpapers hexagons colour choose change" },
        { "Workspace overview", "action", function() spawn('pleamar --say vitreus "emit ov_toggle"') end, "workspaces windows switch expose desktops" },
        { "Random wallpaper", "action", function() local f = wp_random_pick(); if f then wp_apply(f) end end, "shuffle background change surprise" },
        { "Lock session", "action", function() spawn('pleamar --say lockscreen "fact locked true"') end, "lockscreen lock screen secure away password" },
        { "Settings: Clock", "open", open_settings("pg_clock"), "desktop clock glass digits time wallpaper layout inline stacked staggered hero position corner size weight tint 12 24 hour" },
        { "Desktop clock: toggle", "action", function()
            run("pleamar", { "--say", "desktopclock", "get shown" }, function(out)
                local on = (out or ""):match("true") ~= nil
                run("pleamar", { "--say", "desktopclock", "fact shown " .. (on and "false" or "true") }, function() end)
            end)
        end, "clock desktop glass digits time wallpaper show hide on off" },
        { "Suspend", "action", function() run("systemctl", { "suspend" }, function() end) end, "sleep standby" },
        { "Reload Hyprland", "action", function() run("hyprctl", { "reload" }, function() end) end, "restart config refresh compositor" },
    }
    local function search_commands(q)
        q = q:lower()
        local qn = q:gsub("%s+", "")
        local out = {}
        for _, c in ipairs(COMMANDS) do
            -- found by the title or by its words; every word typed has to be in them, or what was typed (spaces and all) is in them with
            -- the spaces left out, so "lockscreen" finds "Lock screen" and "settings: lockscreen" finds its page
            local hay = (c[1] .. " " .. (c[4] or "")):lower()
            local match = q == ""
            if not match then
                match = hay:gsub("%s+", ""):find(qn, 1, true) ~= nil
                if not match then
                    match = true
                    for word in q:gmatch("%S+") do
                        if not hay:find(word, 1, true) then match = false break end
                    end
                end
            end
            if match then
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
                        del = function() clip_delete(c) end,
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
    -- Remove a row that can be removed (the clipboard's): it goes from the list at once, and the chosen place stays where it was, so
    -- that Shift + Delete can be pressed again for the next one.
    local function remove_result(r)
        if not r or not r.del then return end
        r.del()
        for i, x in ipairs(S.res) do
            if x == r then table.remove(S.res, i) break end
        end
        if #S.res == 0 then text.lmsg = "Nothing in the clipboard history" end
        S.prev = nil
        render(true)
    end
    on("launch_del", function(i) remove_result(S.res[S.start + math.floor(i + 0.5)]) end)
    on("launch_delsel", function() remove_result(S.res[S.sel]) end)
    on("launch_pick", function(i) run_result(S.res[S.start + math.floor(i + 0.5)]) end)
    on("launch_run", function() run_result(S.res[S.sel]) end)
    on("launch_hint", function(i)
        text.lq = ({ "#", ">", ":", "^", "~" })[math.floor(i + 0.5) + 1] or ""
        focus("lq")
    end)
end)()

-- ── The mixer under the volume slider ─────────────────────────────────────────────────────────────────────────
-- Right-click the volume plate in Controls: one slider for each app that is playing sound.
-- pleamar's audio service has no per-app streams, so these are `pactl` sink inputs: listed while the mixer is
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

-- bar monitors: see logic/bar_monitors.luau
require("logic/bar_monitors")(with_dirs)

-- bar position: see logic/bar_position.luau
require("logic/bar_position")()

-- bar layout: see logic/bar_layout.luau
require("logic/bar_layout")()

-- updates: see logic/updates.luau
require("logic/updates")(key, with_dirs)

-- tray: see logic/tray.luau
require("logic/tray")(set_panel)

-- nightmode: see logic/nightmode.luau
require("logic/nightmode")(with_dirs)

-- The wallpaper picker (SUPER + B): every wallpaper as a glass hexagon in a tray under the bar. This is the logic side: one
-- ImageMagick pass per wallpaper makes its hexagon picture (already cut to the shape) and reads its
-- colours (the same 32-colour histogram the colour filter uses), the wallpapers are ordered by hue (greys last, by
-- brightness) so the tray reads as a colour ramp, and what was learned is kept in the data folder so this happens
-- once. How big the hexagons are, and where each one goes, is worked out by the scene from how many there are (see
-- the end of vitreus.plm).
;(function()
    local RULE = 8                                      -- which version made the file: an older one is made again
    local TW, TH = 120, 139                              -- the hexagon picture, in pixels (a pointy-top hexagon is 0.866 as wide as tall)
    local PAD = 2                                        -- the transparent margin round it (the file is TW + 2 PAD by TH + 2 PAD: see vitreus.plm)
    local HERO = 260                                     -- the square picture the hexagon is cut from
    local MAX = 200                                      -- what the model holds
    local G = { data = {}, dir = nil, busy = 0, queue = {}, started = false, laid = false, total = 0, have = {} }
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
    local function seed_hue(f)                            -- a grey has no hue: any steady angle will do
        local h = 5381
        for i = 1, #f do h = (h * 33 + f:byte(i)) % 360007 end
        return h % 360
    end

    local function hex_of(f) return G.dir .. "/" .. name_of(f) .. ".hex.png" end

    -- One wallpaper: its square picture and its colours (one ImageMagick pass), then its hexagon: that picture cut to the
    -- shape, with a little gloss on it. One small picture per wallpaper, already the right shape, keeps the atlas (one
    -- texture for every image and letter on screen) from filling up.
    local function analyse(f, done)
      wpv.src(f, function(src)
        if not src then done() return end
        local hw = TW / 2
        local poly = string.format("polygon %g,0 %d,%g %d,%g %g,%d 0,%g 0,%g", hw, TW, TH * 0.25, TW, TH * 0.75, hw, TH, TH * 0.75, TH * 0.25)
        -- One pass, one thread: the picture is read once (shrunk while it is decoded, `jpeg:size`), cut to the hexagon and written,
        -- and the same square picture gives the colour histogram. This was two programs per wallpaper, the first reading the whole
        -- picture with every core, and the second reading back the square picture it had written.
        run("magick", { "-limit", "thread", "1", "-define", "jpeg:size=" .. (HERO * 2) .. "x" .. (HERO * 2), src .. "[0]",
                        "-thumbnail", HERO .. "x" .. HERO .. "^", "-gravity", "center", "-extent", HERO .. "x" .. HERO,
                        "(", "+clone", "-resize", TW .. "x" .. TH .. "^", "-extent", TW .. "x" .. TH, "-alpha", "set",
                             "(", "-size", TW .. "x" .. TH, "xc:none", "-fill", "white", "-draw", poly, ")",
                             "-compose", "DstIn", "-composite",
                             -- two transparent pixels all round: the picture's own edge is never a hexagon's, so it never shows as a hairline
                             -- (back to Over first: `-extent` and `-border` composite with the DstIn still set above, and erase the picture)
                             "-compose", "Over", "-background", "none", "-gravity", "center", "-extent", (TW + 2 * PAD) .. "x" .. (TH + 2 * PAD),
                             "-write", "PNG32:" .. hex_of(f), "+delete", ")",
                        "-thumbnail", "100x100", "-colors", "32", "-format", "%c", "histogram:info:" },
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
                        G.data[f] = { h = hue, s = sat_sum / total, v = val_sum / total }
                    end
                end
                done()
            end)
      end)
    end

    local function save()
        local out = { rule = RULE }
        for f, d in pairs(G.data) do out[f] = { h = d.h, s = d.s, v = d.v } end
        pcall(sys.call, "files.write", "wallpaper-picker.json", out)
    end

    -- The tray's order: the colourful ones round the colour wheel, then the greys from dark to light.
    local function ordered()
        local files = {}
        for _, f in ipairs(wp_files) do if G.data[f] and G.have[name_of(f)] then files[#files + 1] = f end end
        local function key(f)
            local d = G.data[f]
            if d.s < 0.12 then return 1000 + d.v * 100 end
            return d.h
        end
        table.sort(files, function(a, b)
            local ka, kb = key(a), key(b)
            if ka ~= kb then return ka < kb end
            return a < b
        end)
        return files
    end

    local function set_name(i)
        local f = G.files and G.files[i + 1]
        if not f then return end
        text.wp_picker_hero_name = name_of(f)
        fact.wp_picker_hero_cur = f == wp_cur
    end
    on("fact:wp_picker_hot", function(v) if type(v) == "number" and v >= 0 then set_name(math.floor(v + 0.5)) end end)

    local function build()
        local rows = {}
        local files = ordered()
        for i, f in ipairs(files) do
            if i > MAX then break end
            local d = G.data[f]
            local dim = false
            if wp_filter then
                dim = true
                for _, tag in ipairs(wp_tags[f] or {}) do if tag == wp_filter then dim = false; break end end
            end
            rows[i] = { img = hex_of(f), hue = d.h, cur = f == wp_cur, dim = dim, name = stem(f) }
        end
        G.files = files
        model.wp_picker = rows
    end

    local function finish()
        save()
        G.laid = true
        build()
    end

    local function pump()
        while G.busy < 3 and #G.queue > 0 do
            local f = table.remove(G.queue)
            G.busy = G.busy + 1
            analyse(f, function()
                G.busy = G.busy - 1
                G.have[name_of(f)] = G.data[f] ~= nil
                text.wp_picker_status = string.format("Reading your wallpapers…  %d of %d", G.total - #G.queue - G.busy, G.total)
                if G.busy == 0 and #G.queue == 0 then text.wp_picker_status = ""; finish() else pump() end
            end)
        end
    end

    -- Start once the wallpaper folder has been read: what is already known is used at once, the rest is made.
    local function start()
        if G.started or #wp_files == 0 then return end
        G.started = true
        with_dirs(function(d)
            G.dir = d.cache .. "/wp_picker"
            run("mkdir", { "-p", G.dir }, function()
                -- the earlier versions' pictures are not used any more
                run("find", { G.dir, "-maxdepth", "1", "(", "-name", "*.bead.png", "-o", "-name", "*.jpg", ")", "-delete" }, function() end)
                run("find", { G.dir, "-maxdepth", "1", "-name", "*.hex.png", "-printf", "%f\n" }, function(out)
                    for line in (out or ""):gmatch("[^\n]+") do G.have[line:gsub("%.hex%.png$", "")] = true end
                    local ok, saved = pcall(sys.ask, "files.read", "wallpaper-picker.json", "json")
                    if ok and type(saved) == "table" and saved.rule == RULE then
                        for f, e in pairs(saved) do
                            if type(e) == "table" and e.h then G.data[f] = e end
                        end
                    end
                    local missing = 0
                    for _, f in ipairs(wp_files) do
                        if not (G.data[f] and G.have[name_of(f)]) then
                            G.data[f] = nil
                            G.queue[#G.queue + 1] = f
                            missing = missing + 1
                        end
                    end
                    if missing == 0 then
                        G.laid = true
                        build()
                    else
                        G.total = missing
                        text.wp_picker_status = string.format("Reading your wallpapers…  0 of %d", missing)
                        pump()
                    end
                end)
            end)
        end)
    end
    wp_picker_start = start                              -- built at once when the folder is listed, not when the picker is first opened
    every(2000, function() if not G.started then start() end end)    -- and again if the first listing found nothing

    on("wp_picker_toggle", function()
        local opening = not fact.wp_picker_open
        if opening then fact.wp_picker_leaving = false; set_panel("none"); if G.laid then build() end end
        fact.wp_picker_open = opening
    end)

    -- A hexagon was pressed: its wallpaper blooms out of it. `wp_picker_px`, `wp_picker_py` are where it is on the screen, from the
    -- bottom left, which is where awww counts from. Then the tray leaves, and the desktop is what is left.
    on("wp_picker_pick", function(i)
        local f = G.files and G.files[i + 1]
        if not f then return end
        local px, py = math.floor((fact.wp_picker_px or 0) + 0.5), math.floor((fact.wp_picker_py or 0) + 0.5)
        local mh = tonumber(fact.mon_h) or 1080
        wp_apply(f, { "--transition-type", "grow", "--transition-pos", px .. "," .. py, "--transition-duration", "1.6",
                      "--transition-fps", "60", "--transition-step", "60" }, function()
            -- Only now does the tray leave: before, the desktop would show the old wallpaper while it is being made ready.
            fact.wp_picker_leaving = true
            after(350, function() fact.wp_picker_open = false end)
            -- `leaving` stays up until the tray has shut: its opacity is `show` times `veil`, so letting `veil` go back to 1 while `show` is still
            -- on its way to 0 brings the tray back for a moment. Opening it again puts it back (see wp_picker_toggle).
            after(1800, function() fact.wp_picker_leaving = false end)
        end, { x = px, y = mh - py })           -- the dissolve counts from the top left; awww's position counts from the bottom
    end)
    -- Random: any wallpaper, from the middle of the screen.
    on("wp_picker_random", function()
        local f = wp_random_pick()
        if not f then return end
        local mh = tonumber(fact.mon_h) or 1080
        wp_apply(f, { "--transition-type", "grow", "--transition-pos", "center", "--transition-duration", "1.6",
                      "--transition-fps", "60", "--transition-step", "60" }, function()
            fact.wp_picker_leaving = true
            after(350, function() fact.wp_picker_open = false end)
            -- `leaving` stays up until the tray has shut: its opacity is `show` times `veil`, so letting `veil` go back to 1 while `show` is still
            -- on its way to 0 brings the tray back for a moment. Opening it again puts it back (see wp_picker_toggle).
            after(1800, function() fact.wp_picker_leaving = false end)
        end, { x = math.floor(mh * 16 / 9 / 2), y = math.floor(mh / 2) })
    end)
end)()


-- ── The workspace overview ───────────────────────────────────────────────────────────────────────────────────────────
-- Three windows to a workspace, in the order of `ovw`'s slots: the scene draws slot n as tile n % 3 of column n / 3. Each
-- tile shows a picture of the window. A compositor will not stream a window it is not showing, so the pictures are taken
-- (by grim, from the screen) when a workspace is in front: a moment after you arrive on it, and just before the overview
-- opens. A window on a workspace you are not looking at shows the last picture taken of it.
;(function()
    local PER = 9
    local TW, TH = 456, 257                  -- the tile's picture, in pixels: what the scene draws, a single window filling a screen, at 1.35 scale
    local addrs = {}
    local open = false
    local last_sig = ""
    local dir = nil                          -- where the pictures go
    local shots = {}                         -- "addr-pid" -> the file of its latest picture
    local serial = 0
    local busy = false
    local function ensure_dir(fn)
        if dir then return fn() end
        with_dirs(function(d)
            dir = (d.cache:gsub("/wp$", "/ws"))
            run("mkdir", { "-p", dir }, function()
                -- Pictures of earlier runs are named in a way this run would repeat: start clean.
                run("find", { dir, "-type", "f", "-delete" }, function() fn() end)
            end)
        end)
    end
    local function key_of(w) return (w.addr or "") .. "-" .. (w.pid or "0") end

    -- Take a picture of each window on the workspace in front, one after another.
    local function capture(done)
        if busy or fact.ov_open or fact.wp_picker_open or fact.pk_open then if done then done() end return end
        busy = true
        local function finish() busy = false; if done then done() end end
        ensure_dir(function()
            run("pleamar", { "--say", "lockscreen", "get locked" }, function(locked)
                if tostring(locked):match("true") then finish() return end
                run("hyprctl", { "clients" }, function(out, code)
                    if code ~= 0 then finish() return end
                    local todo = {}
                    local front = tonumber(fact["ws.active"]) or 1
                    for _, w in ipairs(parse_clients(out)) do
                        local id = tonumber((w.workspace or ""):match("^(-?%d+)")) or 0
                        local x, y = (w.at or ""):match("^(-?%d+),(-?%d+)")
                        local cw, ch = (w.size or ""):match("^(%d+),(%d+)")
                        if w.mapped == "1" and w.hidden ~= "1" and id == front and x and cw and tonumber(cw) > 40 and tonumber(ch) > 40 and #todo < 9 then
                            todo[#todo + 1] = { key = key_of(w), geo = string.format("%d,%d %dx%d", x, y, cw, ch) }
                        end
                    end
                    local i = 0
                    local function step()
                        i = i + 1
                        local t = todo[i]
                        if not t then finish() return end
                        serial = serial + 1
                        local raw, out_f = dir .. "/raw.jpg", dir .. "/" .. t.key .. "-" .. serial .. ".jpg"
                        run("grim", { "-g", t.geo, "-t", "jpeg", "-q", "92", raw }, function(_, c1)
                            if c1 ~= 0 then step() return end
                            run("magick", { raw, "-thumbnail", TW .. "x" .. TH .. "^", "-gravity", "north", "-extent", TW .. "x" .. TH,
                                            "-strip", "-quality", "85", out_f }, function(_, c2)
                                if c2 == 0 then
                                    shots[t.key] = out_f
                                    -- the window's earlier pictures are not wanted any more
                                    run("find", { dir, "-name", t.key .. "-*.jpg", "!", "-name", t.key .. "-" .. serial .. ".jpg", "-delete" }, function() end)
                                end
                                step()
                            end)
                        end)
                    end
                    step()
                end)
            end)
        end)
    end
    local capture_gen = 0
    local function capture_soon(ms)
        capture_gen = capture_gen + 1
        local g = capture_gen
        after(ms, function() if g == capture_gen then capture() end end)
    end

    local clients = {}              -- the windows as last read from `hyprctl clients`; a move edits this at once, so its card does not wait for Hyprland
    local moving = false            -- a window was dropped on another workspace and Hyprland has not caught up: do not read the old place back yet
    local function render()
        do
            local per = { {}, {}, {}, {}, {} }
            local elsewhere = 0
            for _, w in ipairs(clients) do
                if w.mapped == "1" then
                    local id = tonumber((w.workspace or ""):match("^(-?%d+)")) or 0
                    if id >= 1 and id <= 5 then table.insert(per[id], w) else elsewhere += 1 end
                end
            end
            local rows, sig = {}, {}
            addrs = {}
            for id = 1, 5 do
                -- In a fixed order, so that windows do not swap places as you use them.
                table.sort(per[id], function(a, b) return (a.addr or "") < (b.addr or "") end)
                fact["ov_cnt." .. (id - 1)] = #per[id]
                -- How the workspace's windows are laid out: one fills the screen, then side by side, then a grid.
                local cnt = math.min(#per[id], PER)
                local gc = cnt <= 1 and 1 or (cnt <= 4 and 2 or 3)
                local gr = math.max(1, math.ceil(cnt / gc))
                for k = 1, PER do
                    local slot = (id - 1) * PER + k
                    local w = per[id][k]
                    if w then
                        local class = (w.class or ""):lower()
                        local title = w.title
                        if title == nil or title == "" then title = (w.class ~= nil and w.class ~= "") and w.class or "Window" end
                        local shot = shots[key_of(w)]
                        rows[slot] = { gx = (k - 1) % gc, gy = math.floor((k - 1) / gc), gc = gc, gr = gr, title = title, active = w.focusHistoryID == "0", used = true, icon = apps_by_class[class] or class,
                                       snap = shot ~= nil, thumb = shot or "application-x-executable" }
                        addrs[slot] = w.addr
                    else
                        rows[slot] = { gx = 0, gy = 0, gc = 1, gr = 1, title = "", active = false, used = false, icon = "application-x-executable", snap = false, thumb = "application-x-executable" }
                    end
                    sig[slot] = rows[slot].gx .. "," .. rows[slot].gy .. "," .. rows[slot].gc .. "," .. rows[slot].gr .. "|" .. rows[slot].title .. "|" .. tostring(rows[slot].active) .. "|" .. tostring(rows[slot].icon) .. "|" .. rows[slot].thumb
                end
            end
            fact.ov_else = elsewhere
            local joined = table.concat(sig, "\n")
            if joined ~= last_sig then
                last_sig = joined
                model.ovw = rows
            end
        end
    end
    local function refresh()
        if moving then return end
        run("hyprctl", { "clients" }, function(out, code)
            if code ~= 0 or not open or moving then return end
            clients = parse_clients(out)
            render()
        end)
    end
    on("fact:ov_open", function(v)
        open = v == 1 or v == true
        if open then last_sig = ""; refresh() end
    end)
    every(1000, function() if open then refresh() end end)
    -- Arriving on a workspace: its windows are taken a moment later, when the switch has settled.
    local was_front = nil
    sys.watch("workspaces", function(w)
        if was_front ~= nil and w.active ~= was_front then capture_soon(700) end
        was_front = w.active
    end)
    after(4000, function() capture_soon(0) end)
    on("ov_toggle", function()
        if fact.ov_open then
            fact.ov_open = false
            open = false
            return
        end
        fact.wp_picker_open = false
        -- A drawer that is open would be in the pictures: let it go, and wait for it to leave.
        local wait = 0
        if tostring(fact.panel) ~= "none" then fact.panel = "none"; wait = 350 end
        after(wait, function()
            capture(function()
                fact.ov_open = true
                open = true
                last_sig = ""
                refresh()
            end)
        end)
    end)
    -- A window dropped on a column: move it to that workspace, and keep the overview open.
    on("ov_move", function(n)
        local col = fact.ov_col
        local addr = addrs[n + 1]
        local ws = math.floor((tonumber(col) or -1) + 1)
        if not addr or ws < 1 or ws > 5 then return end
        -- The card goes to its new workspace now, and what Hyprland says is not read back until it has done it (otherwise the card shows on the old
        -- workspace again for a moment, until the next read).
        moving = true
        for _, w in ipairs(clients) do
            if w.addr == addr then w.workspace = tostring(ws) end
        end
        render()
        run("hyprctl", { "dispatch", string.format('hl.dsp.window.move({ workspace = %d, follow = false, window = "address:0x%s" })', ws, addr) }, function()
            after(250, function() moving = false; refresh() end)
        end)
        after(1500, function() moving = false end)         -- whatever happens, the overview does not stay frozen
    end)
    on("ov_focus", function(n)
        local addr = addrs[n + 1]
        if addr then after(250, function() focus_window(addr) end) end       -- once the overview has let go (see `ov_go`)
    end)
end)()

-- monitor height: see logic/monitor_height.luau
require("logic/monitor_height")()

-- capture power: see logic/capture_power.luau
require("logic/capture_power")(set_panel)

-- The authentication dialog. Vitreus is this session's polkit agent: `bin/vitreus-polkit-agent` (started here) registers with
-- polkit, and when something asks for admin rights it sets `pk_open` and the dialog's texts in the scene. The scene handles the
-- dialog's own keys and buttons itself (Enter sets `pk_go`, Cancel and Escape close it), and the agent watches those facts and
-- reads the password out of the scene's `pk_pw` field itself (never through a command line). Nothing in this file is needed for
-- that: it only starts the agent. If another agent already holds the session (polkit-gnome, hyprpolkitagent...), ours says so and
-- ends, and that one keeps answering.
;(function()
    spawn("vitreus-polkit-agent", { "--scene", "vitreus" },
        function(line) log("polkit agent:", line) end,
        function(_, code) log("polkit agent ended:", code) end)
end)()

-- Settings > System monitor. `bin/vitreus-sysmon` prints what the machine is doing once a second (as a line of JSON); it is started when
-- that page is showing and stopped (asked to, with "term": a plain kill would leave a zombie, as it did with cava) when it is not, so
-- nothing runs while nobody looks. Every line is turned into the facts, texts and models the page reads (see the top of vitreus.plm).
;(function()
    local N = 60
    local hist = {}                       -- the last minute: { cpu, mem, gpu, rx, tx, dr, dw }, raw (rates in bytes a second)
    local proc = nil
    local mounts_cache = {}

    local function clamp(v) return math.max(0, math.min(1, v or 0)) end
    local function size(b)
        b = b or 0
        local units = { "B", "KB", "MB", "GB", "TB", "PB" }
        local i = 1
        while b >= 1024 and i < #units do b = b / 1024; i = i + 1 end
        if i == 1 then return string.format("%d B", b) end
        if b >= 100 then return string.format("%.0f %s", b, units[i]) end
        if b >= 10 then return string.format("%.1f %s", b, units[i]) end
        return string.format("%.2f %s", b, units[i])
    end
    local function rate(b) return size(b) .. "/s" end
    local function kb(v) return size((v or 0) * 1024) end
    local function uptime(s)
        s = s or 0
        local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
        if d > 0 then return string.format("%dd %dh", d, h) end
        if h > 0 then return string.format("%dh %dm", h, m) end
        return string.format("%dm", m)
    end

    local function on_line(line)
        local ok, d = pcall(json.decode, line)
        if not ok or type(d) ~= "table" or not d.cpu then return end
        if d.info then
            text.sm_host = d.info.host or ""
            text.sm_cpu_name = d.info.cpu or ""
            text.sm_kernel = d.info.kernel or ""
            text.sm_threads = string.format("%d threads", d.info.threads or 0)
        end

        -- the processor
        local c = d.cpu
        local total = c.total or 0
        fact.sm_cpu = clamp(total / 100)
        text.sm_cpu_txt = string.format("%d%%", math.floor(total + 0.5))
        local sum, n = 0, 0
        for _, f in ipairs(c.mhz or {}) do if f > 0 then sum = sum + f; n = n + 1 end end
        local meta = n > 0 and string.format("%.1f GHz", sum / n / 1000) or ""
        for _, t in ipairs(d.temps or {}) do
            if t.l == "CPU package" then meta = (meta ~= "" and (meta .. " · ") or "") .. string.format("%d°C", math.floor(t.c + 0.5)); break end
        end
        text.sm_cpu_meta = meta
        if c.load then text.sm_load = string.format("%.2f  %.2f  %.2f", c.load[1] or 0, c.load[2] or 0, c.load[3] or 0) end
        text.sm_uptime = uptime(d.up)
        local cores = {}
        for i, p in ipairs(c.cores or {}) do cores[i] = { pct = clamp(p / 100) } end
        model.sm_core = cores

        -- memory
        local m = d.mem or {}
        local mt = math.max(m.total or 1, 1)
        fact.sm_mem_f = clamp((m.used or 0) / mt)
        fact.sm_cache_f = clamp((m.cache or 0) / mt)
        text.sm_mem_pct = string.format("%d%%", math.floor(clamp((m.used or 0) / mt) * 100 + 0.5))
        text.sm_mem_total = kb(m.total) .. " installed"
        text.sm_mem_used = kb(m.used)
        text.sm_mem_cache = kb(m.cache)
        text.sm_mem_free = kb(m.free)
        fact.sm_swap_f = (m.swap_total or 0) > 0 and clamp((m.swap_used or 0) / m.swap_total) or 0
        text.sm_swap_txt = (m.swap_total or 0) > 0 and (kb(m.swap_used) .. " of " .. kb(m.swap_total)) or "none"

        -- the graphics card
        local g = d.gpu
        fact.sm_gpu_on = g ~= nil
        if g then
            fact.sm_gpu_f = clamp((g.util or 0) / 100)
            fact.sm_vram_f = (g.mem_total or 0) > 0 and clamp((g.mem_used or 0) / g.mem_total) or 0
            fact.sm_pw_f = (g.power_max or 0) > 0 and clamp((g.power or 0) / g.power_max) or 0
            text.sm_gpu_name = g.name or ""
            text.sm_gpu_txt = string.format("%d%%", math.floor((g.util or 0) + 0.5))
            text.sm_gpu_vram = (g.mem_total or 0) > 0 and string.format("%.1f / %.1f GB", (g.mem_used or 0) / 1024, g.mem_total / 1024) or ""
            text.sm_gpu_power = (g.power_max or 0) > 0 and string.format("%.0f / %.0f W", g.power or 0, g.power_max) or "—"
            text.sm_gpu_temp = g.temp and string.format("%d°C", math.floor(g.temp + 0.5)) or "—"
            text.sm_gpu_fan = g.fan and string.format("%d%%", math.floor(g.fan + 0.5)) or "—"
            text.sm_gpu_clock = g.clock and string.format("%d MHz", math.floor(g.clock + 0.5)) or "—"
        end

        -- the network and the drives
        local nt = d.net or {}
        text.sm_iface = nt.iface or ""
        text.sm_rx_txt = rate(nt.rx)
        text.sm_tx_txt = rate(nt.tx)
        text.sm_rx_total = size(nt.rx_total) .. " received"
        text.sm_tx_total = size(nt.tx_total) .. " sent"
        local dk = d.disk or {}
        text.sm_dr_txt = rate(dk.read)
        text.sm_dw_txt = rate(dk.write)
        local mts = {}
        for i, mo in ipairs(dk.mounts or {}) do
            mts[i] = { name = mo.m, info = size(mo.used) .. " of " .. size(mo.total), pct = clamp(mo.total > 0 and mo.used / mo.total or 0) }
        end
        if #mts > 0 or #mounts_cache == 0 then mounts_cache = mts end
        model.sm_mnt = mounts_cache

        -- temperatures and fans
        local tmps = {}
        for i, t in ipairs(d.temps or {}) do
            tmps[i] = { label = t.l, txt = string.format("%d°C", math.floor(t.c + 0.5)), f = clamp((t.c - 25) / 70), heat = clamp((t.c - 70) / 25) }
        end
        model.sm_tmp = tmps
        local fans = {}
        for _, f in ipairs(d.fans or {}) do fans[#fans + 1] = string.format("%s %d rpm", f.l or "Fan", f.rpm or 0) end
        text.sm_fans = #fans > 0 and table.concat(fans, "   ·   ") or ""

        -- the busiest programs
        local prs = {}
        for i, p in ipairs(d.procs or {}) do
            prs[i] = { name = p.n, cpu = clamp((p.cpu or 0) / 100), cpu_txt = string.format("%.1f%%", p.cpu or 0), mem_txt = string.format("%.1f%%", p.mem or 0) }
        end
        model.sm_proc = prs

        -- the last minute of it: rates are drawn against the biggest one in view
        hist[#hist + 1] = { cpu = clamp(total / 100), mem = clamp((m.used or 0) / mt), gpu = g and clamp((g.util or 0) / 100) or 0,
                            rx = nt.rx or 0, tx = nt.tx or 0, dr = dk.read or 0, dw = dk.write or 0 }
        if #hist > N then table.remove(hist, 1) end
        local mx_net, mx_dk = 50 * 1024, 1024 * 1024
        for _, h in ipairs(hist) do
            mx_net = math.max(mx_net, h.rx, h.tx)
            mx_dk = math.max(mx_dk, h.dr, h.dw)
        end
        local rows = {}
        for i, h in ipairs(hist) do
            rows[i] = { cpu = h.cpu, mem = h.mem, gpu = h.gpu, rx = h.rx / mx_net, tx = h.tx / mx_net, dr = h.dr / mx_dk, dw = h.dw / mx_dk }
        end
        model.sm_hist = rows
    end

    local function refresh()
        local want = fact.panel == "settings" and fact.set_page == "pg_sys"
        if want and not proc then
            hist = {}
            local mine
            mine = spawn("vitreus-sysmon", {}, function(line) if proc == mine then on_line(line) end end,
                function() if proc == mine then proc = nil end end)
            proc = mine
        elseif not want and proc then
            kill(proc, "term")
            proc = nil
        end
    end
    on("fact:panel", refresh)
    on("fact:set_page", refresh)
    refresh()
end)()

-- lockscreen: see logic/lockscreen.luau
require("logic/lockscreen")(key, with_dirs)

-- clock: see logic/clock.luau
require("logic/clock")()

-- Settings > VPN. NetworkManager owns the profiles (WireGuard ones, and the ones a VPN plugin such as OpenVPN makes), and this page
-- drives it through nmcli: the list, connect / disconnect, delete, and three ways to add one (a WireGuard form, an OpenVPN form, or a
-- .conf / .ovpn file). nmcli's `-t` output escapes ":" and "\"; its error text goes to stderr, which `run` does not give back, so a
-- failure is explained from nmcli's exit code. Profiles are named by UUID: two can share a name.
;(function()
    local MAX = 8
    local profs, kinds, ips = {}, {}, {}
    local home = ""
    local working = false
    local arm = nil
    local want_ip = nil

    run("printenv", { "HOME" }, function(out) home = ((out or ""):gsub("%s+$", "")) end)

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

    local function nm(args, done) run("nmcli", args, done) end
    local NM_CODE = {
        [2] = "NetworkManager did not accept those settings (for OpenVPN, is the networkmanager-openvpn plugin installed?)",
        [3] = "it took too long",
        [4] = "the connection could not be started: check the keys, the endpoint and the password",
        [5] = "it could not be disconnected",
        [7] = "it could not be deleted",
        [8] = "NetworkManager is not running",
        [10] = "NetworkManager has no such profile",
    }

    local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    local function say(msg) text.vpn_msg = msg or "" end
    local function why(_, code) return NM_CODE[code] or ("nmcli failed with code " .. tostring(code)) end
    local function set_working(v) working = v; fact.vpn_busy = v end

    local function kind_label(p)
        if p.type == "wireguard" then return "WireGuard" end
        local k = kinds[p.uuid]
        if k == nil then return "VPN" end
        return k
    end

    local function render()
        local active
        for _, p in ipairs(profs) do if p.active and not active then active = p end end
        fact.vpn_count = #profs
        fact.vpn_on = active ~= nil
        if active then
            text.vpn_title = active.name
            local sub = kind_label(active)
            if ips[active.uuid] and ips[active.uuid] ~= "" then sub = sub .. " · " .. ips[active.uuid] end
            text.vpn_sub = sub
        else
            text.vpn_title = "Not connected"
            text.vpn_sub = #profs == 0 and "No profiles yet: add one below" or "Pick a profile to connect"
        end
        for i = 0, MAX - 1 do
            local p = profs[i + 1]
            fact["vpn_r." .. i .. ".on"] = p ~= nil
            if p then
                text["vpn_r." .. i .. ".name"] = p.name
                text["vpn_r." .. i .. ".sub"] = kind_label(p)
                fact["vpn_r." .. i .. ".active"] = p.active
            else
                fact["vpn_r." .. i .. ".active"] = false
            end
        end
    end

    local function learn_kinds()
        for _, p in ipairs(profs) do
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
            end
        end
    end

    local function learn_ip(p)
        if not p or want_ip == p.uuid then return end
        want_ip = p.uuid
        nm({ "-g", "IP4.ADDRESS", "connection", "show", "uuid", p.uuid }, function(out, code)
            ips[p.uuid] = code == 0 and (trim(out):match("[^\n]+") or "") or ""
            render()
        end)
    end

    local function refresh()
        nm({ "-t", "-f", "NAME,UUID,TYPE,ACTIVE", "connection", "show" }, function(out, code)
            if code ~= 0 then
                profs = {}
                render()
                text.vpn_sub = "NetworkManager did not answer"
                return
            end
            local list = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local f = terse(line)
                if #f >= 4 and (f[3] == "wireguard" or f[3] == "vpn") then
                    list[#list + 1] = { name = f[1], uuid = f[2], type = f[3], active = f[4] == "yes" }
                end
            end
            -- connected first, then by name
            table.sort(list, function(a, b)
                if a.active ~= b.active then return a.active end
                return a.name:lower() < b.name:lower()
            end)
            profs = list
            local active
            for _, p in ipairs(profs) do if p.active and not active then active = p end end
            if not active then want_ip = nil end
            render()
            learn_kinds()
            learn_ip(active)
        end)
    end

    local function arm_clear() arm = nil; fact.vpn_arm = -1 end

    on("vpn_refresh", refresh)

    local function toggle(i)
        local p = profs[i + 1]
        if not p or working then return end
        arm_clear()
        set_working(true)
        say((p.active and "Disconnecting " or "Connecting ") .. p.name .. "…")
        nm({ "connection", p.active and "down" or "up", "uuid", p.uuid }, function(out, code)
            set_working(false)
            say(code == 0 and "" or ((p.active and "Could not disconnect: " or "Could not connect: ") .. why(out, code)))
            refresh()
        end)
    end
    on("vpn_toggle", toggle)
    on("vpn_down", function()
        for i, p in ipairs(profs) do if p.active then return toggle(i - 1) end end
    end)

    on("vpn_arm_ask", function(i)
        local p = profs[i + 1]
        if not p then return end
        if arm == p.uuid then arm_clear() else arm = p.uuid; fact.vpn_arm = i end
    end)

    on("vpn_delete", function(i)
        local p = profs[i + 1]
        arm_clear()
        if not p or working then return end
        set_working(true)
        nm({ "connection", "delete", "uuid", p.uuid }, function(out, code)
            set_working(false)
            say(code == 0 and ("Deleted " .. p.name .. ".") or ("Could not delete: " .. why(out, code)))
            refresh()
        end)
    end)

    -- After an import or add: give the new profile the name the user typed, then say how it went.
    local function added(out, code, label, rename)
        set_working(false)
        if code ~= 0 then say("Could not add it: " .. why(out, code)) return end
        local uuid = (out or ""):match("%(([%x%-]+)%)")
        local function done()
            say("Added " .. label .. ".")
            refresh()
        end
        if rename and uuid and rename ~= "" then
            nm({ "connection", "modify", "uuid", uuid, "connection.id", rename }, function() done() end)
        else
            done()
        end
    end

    local function ifname_of(name)
        local s = name:gsub("[^%w_%-]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
        if s == "" then s = "vpn" end
        return s:sub(1, 15)
    end

    local function data_dir()
        return cava_conf and cava_conf:match("^(.*)/cava%.conf$") or nil
    end

    -- Both WireGuard paths end here: a wg-quick file in the shell's folder (only the user may read it), imported and removed.
    local function import_conf(path, label, rename, temp, kind, file)
        set_working(true)
        say("Adding " .. label .. "…")
        local function finish(out, code)
            if temp then pcall(sys.call, "files.remove", file) end
            added(out, code, label, rename)
        end
        local function go() nm({ "connection", "import", "type", kind, "file", path }, finish) end
        if temp then run("chmod", { "600", path }, function() go() end) else go() end
    end

    local function clean_path(p)
        p = trim(p)
        if p:sub(1, 2) == "~/" then p = home .. p:sub(2) end
        return p
    end

    on("vpn_import", function()
        if working then return end
        local path = clean_path(text.vpn_file)
        if path == "" then say("Type the path of a .conf or .ovpn file.") return end
        local kind = path:lower():match("%.conf$") and "wireguard" or (path:lower():match("%.ovpn$") and "openvpn" or nil)
        if not kind then say("That is not a .conf (WireGuard) or .ovpn (OpenVPN) file.") return end
        run("stat", { path }, function(_, code)
            if code ~= 0 then say("No file there: " .. path) return end
            import_conf(path, path:match("([^/]+)$"), nil, false, kind, nil)
            text.vpn_file = ""
        end)
    end)

    local function b64(s) return s:match("^[A-Za-z0-9+/]+=?$") ~= nil and #s == 44 end

    on("vpn_add_wg", function()
        if working then return end
        local name, addr = trim(text.vpnw_name), trim(text.vpnw_addr)
        local key, peer = trim(text.vpnw_key), trim(text.vpnw_peer)
        local endpoint, dns = trim(text.vpnw_end), trim(text.vpnw_dns)
        local allowed, psk = trim(text.vpnw_ips), trim(text.vpnw_psk)
        if name == "" then say("Give the profile a name.") return end
        if not b64(key) then say("The private key should be 44 characters of base64.") return end
        if addr == "" or not addr:match("%d") then say("Add the address this device gets, e.g. 10.2.0.2/32.") return end
        if not b64(peer) then say("The peer's public key should be 44 characters of base64.") return end
        if not endpoint:match("^[%w%.%-%[%]:]+:%d+$") then say("The endpoint should look like host:51820.") return end
        if psk ~= "" and not b64(psk) then say("The preshared key should be 44 characters of base64.") return end
        if allowed == "" then allowed = "0.0.0.0/0, ::/0" end
        local dir = data_dir()
        if not dir then say("Not ready yet, try again in a moment.") return end
        local ifn = ifname_of(name)
        local conf = { "[Interface]", "PrivateKey = " .. key, "Address = " .. addr }
        if dns ~= "" then conf[#conf + 1] = "DNS = " .. dns end
        conf[#conf + 1] = ""
        conf[#conf + 1] = "[Peer]"
        conf[#conf + 1] = "PublicKey = " .. peer
        if psk ~= "" then conf[#conf + 1] = "PresharedKey = " .. psk end
        conf[#conf + 1] = "AllowedIPs = " .. allowed
        conf[#conf + 1] = "Endpoint = " .. endpoint
        conf[#conf + 1] = "PersistentKeepalive = 25"
        local file = ifn .. ".conf"
        if not pcall(sys.call, "files.write", file, table.concat(conf, "\n") .. "\n") then say("Could not write the temporary file.") return end
        for _, k in ipairs({ "vpnw_name", "vpnw_addr", "vpnw_key", "vpnw_peer", "vpnw_end", "vpnw_dns", "vpnw_ips", "vpnw_psk" }) do text[k] = "" end
        import_conf(dir .. "/" .. file, name, name ~= ifn and name or nil, true, "wireguard", file)
    end)

    on("vpn_add_ovpn", function()
        if working then return end
        local name, server = trim(text.vpno_name), trim(text.vpno_server)
        local port, user = trim(text.vpno_port), trim(text.vpno_user)
        local pw, ca = text.vpno_pw or "", clean_path(text.vpno_ca)
        if name == "" then say("Give the profile a name.") return end
        if server == "" then say("Type the server's host name or address.") return end
        if port == "" then port = "1194" end
        if not port:match("^%d+$") then say("The port should be a number.") return end
        if user == "" then say("Type the user name.") return end
        local data = { "remote=" .. server .. ":" .. port, "connection-type=password", "username=" .. user, "password-flags=" .. (pw ~= "" and "0" or "2") }
        if fact.vpn_tcp then data[#data + 1] = "proto-tcp=yes" end
        if ca ~= "" then data[#data + 1] = "ca=" .. ca end
        local args = { "connection", "add", "type", "vpn", "vpn-type", "openvpn", "con-name", name, "ifname", "--", "vpn.data", table.concat(data, ", ") }
        if pw ~= "" then args[#args + 1] = "vpn.secrets"; args[#args + 1] = "password=" .. pw end
        set_working(true)
        say("Adding " .. name .. "…")
        nm(args, function(out, code)
            if code == 0 then for _, k in ipairs({ "vpno_name", "vpno_server", "vpno_port", "vpno_user", "vpno_pw", "vpno_ca" }) do text[k] = "" end end
            added(out, code, name, nil)
        end)
    end)

    -- The file browser of the Import tab: one folder at a time, folders first, only .conf and .ovpn files. It starts in Downloads.
    local ROWS = 8
    local dir, entries, first = nil, {}, 0
    local function brender()
        text.vpn_dir = dir or ""
        for i = 0, ROWS - 1 do
            local e = entries[first + i + 1]
            fact["vpn_f." .. i .. ".on"] = e ~= nil
            if e then
                text["vpn_f." .. i .. ".name"] = e.name
                fact["vpn_f." .. i .. ".dir"] = e.dir
            end
        end
        fact.vpn_fmore = #entries > ROWS
    end
    local function browse(path, fallback)
        run("find", { "-L", path, "-maxdepth", "1", "-mindepth", "1", "-printf", "%y\t%f\n" }, function(out, code)
            if code ~= 0 and fallback then return browse(fallback) end
            if code ~= 0 then return end
            dir, first = path, 0
            local ds, fs = {}, {}
            for line in (out or ""):gmatch("[^\n]+") do
                local ty, name = line:match("^(%a)\t(.+)$")
                if name and name:sub(1, 1) ~= "." then
                    if ty == "d" then ds[#ds + 1] = { name = name, dir = true }
                    else
                        local l = name:lower()
                        if l:match("%.conf$") or l:match("%.ovpn$") then fs[#fs + 1] = { name = name, dir = false } end
                    end
                end
            end
            local function by(a, b) return a.name:lower() < b.name:lower() end
            table.sort(ds, by); table.sort(fs, by)
            entries = {}
            if path ~= "/" then entries[1] = { name = "..", dir = true } end
            for _, e in ipairs(ds) do entries[#entries + 1] = e end
            for _, e in ipairs(fs) do entries[#entries + 1] = e end
            brender()
        end)
    end
    local function start_browser()
        if dir then return end
        browse(home .. "/Downloads", home)
    end
    on("vpn_fpick", function(i)
        local e = entries[first + i + 1]
        if not e or not dir then return end
        if e.dir then
            if e.name == ".." then browse(dir:match("^(.*)/[^/]*$") ~= "" and dir:match("^(.*)/[^/]*$") or "/")
            else browse((dir == "/" and "" or dir) .. "/" .. e.name) end
        else
            text.vpn_file = (dir == "/" and "" or dir) .. "/" .. e.name
        end
    end)
    on("vpn_fscroll", function(w)
        local max = math.max(0, #entries - ROWS)
        first = math.max(0, math.min(max, first - (w > 0 and 1 or -1) * 2))
        brender()
    end)

    -- Only while the page is in view.
    local function open() return fact.panel == "settings" and fact.set_page == "pg_vpn" end
    on("fact:set_page", function(v) arm_clear(); if v == "pg_vpn" and fact.panel == "settings" then refresh(); start_browser() end end)
    on("fact:panel", function(v) arm_clear(); if v == "settings" and fact.set_page == "pg_vpn" then refresh(); start_browser() end end)
    every(4000, function() if open() and not working then refresh() end end)
    render()
end)()

-- focus: see logic/focus.luau
require("logic/focus")()

-- shelf: see logic/shelf.luau
require("logic/shelf")()

-- pad: see logic/pad.luau
require("logic/pad")()

-- draw: see logic/draw.luau
require("logic/draw")()

-- term: see logic/term.luau
require("logic/term")(key)

-- ask: see logic/ask.luau
require("logic/ask")()
