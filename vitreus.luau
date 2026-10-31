-- The brightness service reads the backlight straight from sysfs, but setting
-- it shells out to brightnessctl - so a real backlight can still report a
-- level with nothing able to move it, if the binary itself is missing.
run("which", { "brightnessctl" }, function(_, code)
    fact.bright_avail = code == 0
end)

-- Workspaces only: what moves is moved by the renderer.
ws_urgent = {}
addon_scenes = {}                          -- the sockets of the running add-ons (logic/addons.luau), told the palette, the bar's room, the look and the weather
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do busy[d.id] = d.windows > 0 end
    for i = 1, 10 do fact["ws." .. i .. ".busy"] = busy[i] or false end
    fact["ws.active"] = w.active
    -- No window on the workspace in view (one that is not in the list at all is empty too): see `ws_empty` in the scene.
    local here = false
    for _, d in ipairs(w.list) do if d.id == w.active and d.windows > 0 then here = true end end
    fact.ws_empty = not here
    -- Going to a workspace answers whatever was asking for attention on it. (Globals: this chunk is at Luau's limit of locals.)
    if ws_urgent[w.active] then ws_urgent[w.active] = nil; fact["ws." .. w.active .. ".urgent"] = false end
end)
-- Starting a program "on the desktop" (not as this shell's child). On Hyprland that is its own `exec_cmd`, so the program comes from the
-- compositor; Hyprland's environment says whether this is Hyprland. On any other desktop (pleamar-wm) there is no such command, and the
-- program is started directly, in a session of its own. Either way it has ~/.local/bin on its PATH, which Hyprland's has not.
on_hyprland = false                       -- (globals, not locals: this chunk is at Luau's limit of 200 locals)
run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code)
    on_hyprland = code == 0 and (out or "") ~= ""
    -- The Settings show the Hyprland page on Hyprland and the Pleamar-WM one anywhere else (as the rest of this file takes it: no Hyprland means pleamar-wm).
    fact.wm_hypr = on_hyprland
    fact.wm_pwm = not on_hyprland
    -- niri: its environment says so (NIRI_SOCKET). Neither the Hyprland page nor the Pleamar-WM one is in the Settings there, and the windows and workspaces are asked of
    -- `hyprctl`, which is pleamar-wm/hyprctl-niri's answer in Hyprland's words (see below).
    if not on_hyprland then
        run("printenv", { "NIRI_SOCKET" }, function(o, c)
            on_niri = c == 0 and (o or "") ~= ""
            if on_niri then fact.wm_pwm = false; fact.wm_niri = true end
        end)
    end
end)
on_niri = false
-- Asking one of our other scenes (the lock screen, the desktop clock and system monitor) for several of its values at once. `pleamar --say`
-- answers one question per command, and starting a command from this shell costs about 30 ms, so a settings page that asked ten questions froze
-- the shell for a third of a second each time it opened. A scene listens on a socket and answers one line per line it is sent, in order: one
-- `socat` carries all the questions. `done` gets the answers (a list, in the order asked), or nothing when the scene does not answer.
rt_dir = "/run/user/1000"
run("printenv", { "XDG_RUNTIME_DIR" }, function(out, code) if code == 0 and (out or ""):match("%S") then rt_dir = (out:gsub("%s+$", "")) end end)
-- Where the other scenes' sockets are: `pleamar` on Hyprland, and `pleamar-<display>` under pleamar-wm (WAYLAND_DISPLAY is `pleamar-1` there). The
-- old folder is still there after a Hyprland session, with sockets nobody listens on. A table, asked once: a global would keep its value from load.
sock_dir = { dir = nil }
function with_sock_dir(fn)
    if sock_dir.dir then return fn(sock_dir.dir) end
    run("printenv", { "WAYLAND_DISPLAY" }, function(out, code)
        local d = (out or ""):gsub("%s+$", "")
        sock_dir.dir = rt_dir .. ((code == 0 and d:match("^pleamar")) and ("/pleamar-" .. d) or "/pleamar")
        fn(sock_dir.dir)
    end)
end
-- Commands that get no answer (`fact x y`): all down one connection, which is let go a moment after.
function say_batch(scene, cmds)
    if #cmds == 0 then return end
    with_sock_dir(function(dir)
        local id = spawn("socat", { "-t1", "-", "UNIX-CONNECT:" .. dir .. "/" .. scene .. ".sock" }, function() end, function() end, { stdin = "open" })
        write(id, table.concat(cmds, "\n") .. "\n")
        after(500, function() kill(id, "term") end)
    end)
end
function say_many(scene, cmds, done)
    with_sock_dir(function(dir)
        local got, finished, id = {}, false, nil
        local function finish(ok)
            if finished then return end
            finished = true
            if id then kill(id, "term") end
            done(ok and got or nil)
        end
        id = spawn("socat", { "-t1", "-", "UNIX-CONNECT:" .. dir .. "/" .. scene .. ".sock" },
            function(line) got[#got + 1] = line; if #got >= #cmds then finish(true) end end,
            function() finish(false) end, { stdin = "open" })
        write(id, table.concat(cmds, "\n") .. "\n")
        after(2500, function() finish(false) end)
    end)
end
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
desk_seen = nil                          -- the last count of right presses on the bare desktop that was looked at
bar_mon = { name = nil, set = nil }      -- the monitor the bar is on ("all" for two), and the set of the names of the ones it is on; set by logic/bar_monitors.luau
function wm_workspaces()
    -- One connection for every question (`say_many`): a `pleamar --say` process for each one, ten times a second, was what made the shell stutter.
    -- The workspace shown is per monitor: the bar's own, which is the one named in its `screens:` (the order of pleamar-wm's monitors is
    -- the order `hyprctl monitors` gives them: "Monitor <name> (ID 1)"), or the one the pointer is on when the bar is on all of them.
    local cmds = { "get mon", "get win.shown.0", "get win.shown.1", "get win.shown.2", "get win.shown.3" }
    for i = 0, 5 do cmds[#cmds + 1] = "get win." .. i .. ".open" end
    for i = 0, 5 do cmds[#cmds + 1] = "get win." .. i .. ".workspace" end
    -- (18 to 21) a right press on the bare desktop, which the window manager's scene counts: the desktop menu opens where it was (see `desk_n` in wm/session.plm)
    for _, k in ipairs({ "desk_n", "desk_x", "desk_y", "desk_mon" }) do cmds[#cmds + 1] = "get " .. k end
    hypr_monitors(30, function(mons)
        local name = bar_mon.name
        local idx = nil
        if name and name ~= "all" and mons then
            idx = tonumber(mons:match("Monitor " .. name:gsub("%-", "%%-") .. " %\(ID (%d+)%\)"))
        end
        say_many("wm", cmds, function(r)
            if not r then return end
            local n = idx or tonumber((r[1] or ""):match("%d+")) or 0
            local shown = tonumber((r[2 + n] or ""):match("%-?[%d.]+"))
            if shown and fact["ws.active"] ~= shown then fact["ws.active"] = shown end
            -- Windows take slots 0 to 5 (`win.count` is only the ones on the shown workspace).
            local busy = {}
            for i = 0, 5 do
                if (r[6 + i] or ""):match("true") then
                    local w = tonumber((r[12 + i] or ""):match("%-?[%d.]+"))
                    if w then busy[w] = true end
                end
            end
            for k = 1, 10 do
                local v = busy[k] or false
                if fact["ws." .. k .. ".busy"] ~= v then fact["ws." .. k .. ".busy"] = v end
            end
            local dn = tonumber((r[18] or ""):match("%-?[%d.]+"))
            if dn then
                -- (the window manager's facts start from 0 again when its scene is read in again: that is not a press)
                if desk_seen ~= nil and dn > 0 and dn ~= desk_seen then
                    local x, y, m = tonumber((r[19] or ""):match("%-?[%d.]+")) or 0, tonumber((r[20] or ""):match("%-?[%d.]+")) or 0, tonumber((r[21] or ""):match("%-?[%d.]+")) or 0
                    -- (the desktop editor, desktopedit/, is what a right press opens; it is started if it is not running)
                    local function say_editor(cb) run("pleamar", { "--say", "desktopedit", "fact emon " .. math.floor(m), "fact open true" }, cb) end
                    say_editor(function(_, code)
                        if code ~= 0 then
                            exec_on_desktop('vitreus-keep "$HOME/.config/pleamar/shells/vitreus/desktopedit/desktopedit.plm"')
                            after(3000, function() say_editor(function() end) end)
                        end
                    end)
                end
                desk_seen = dn
            end
        end)
    end)
end
-- niri: its workspaces (one list on each monitor, numbered from 1) are asked of `hyprctl workspaces -j`, which pleamar-wm/hyprctl-niri answers from `niri msg`. The
-- one on the bar's monitor (or the focused one when the bar is on all of them) is the one shown; a workspace is busy when a window is on it.
function niri_workspaces()
    run("hyprctl", { "workspaces", "-j" }, function(out, code)
        if code ~= 0 or not out then return end
        local ok, list = pcall(json.decode, out)
        if not ok or type(list) ~= "table" then return end
        local want = bar_mon.name
        local mine = false
        if want ~= nil and want ~= "all" then for _, w in ipairs(list) do if w.monitor == want then mine = true end end end      -- (a name that is not plugged in: the focused monitor's)
        local active, busy = nil, {}
        for _, w in ipairs(list) do
            if (not mine or w.monitor == want) and (w.windows or 0) > 0 then busy[w.id] = true end
            if w.active and ((mine and w.monitor == want) or (not mine and w.focused)) then active = w.id end
        end
        if active and fact["ws.active"] ~= active then fact["ws.active"] = active end
        for k = 1, 10 do
            local v = busy[k] or false
            if fact["ws." .. k .. ".busy"] ~= v then fact["ws." .. k .. ".busy"] = v end
        end
        local empty = not (active and busy[active])
        if fact.ws_empty ~= empty then fact.ws_empty = empty end
    end)
end
after(1500, function()
    if on_niri then every(1000, niri_workspaces)
    elseif not on_hyprland then every(500, wm_workspaces) end
end)
function goto_workspace(i)
    if on_hyprland then sys.call("workspaces.focus", i)
    elseif on_niri then run("hyprctl", { "dispatch", "hl.dsp.focus({ workspace = " .. tonumber(i) .. " })" }, function() niri_workspaces() end)
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

-- The dashboard's clock follows the system's own way of writing the time: 24-hour when the locale has no am/pm (`date +%p` is
-- empty), 12-hour with an AM/PM mark when it has. Read at the start and now and then (a changed locale or setting).
local clk24, clk_last = false, nil
local function dash_time(c)
    local h12 = c.hour % 12
    if h12 == 0 then h12 = 12 end
    text.dsh_hh = clk24 and string.format("%02d", c.hour) or tostring(h12)
    text.dsh_ap = clk24 and "" or (c.hour < 12 and "AM" or "PM")
    fact.dsh_ap_on = not clk24
    text.dsh_m1 = string.format("%d", math.floor(c.minute / 10))
    text.dsh_m2 = string.format("%d", c.minute % 10)
end
local function clk_detect()
    run("date", { "+%p" }, function(out)
        local v = tostring(out or ""):match("%S") == nil
        if v ~= clk24 then
            clk24 = v
            if clk_last then dash_time(clk_last) end
        end
    end)
end
clk_detect()
every(600000, clk_detect)

sys.watch("clock", function(c)
    clk_last = c
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
    -- The dashboard's clock: the hour in the system's format, and the minute's two digits apart (they are set staggered).
    dash_time(c)
    -- The clock card's pieces.
    text.clock_hm = string.format("%d:%02d", h, c.minute)
    text.clock_ap = c.hour < 12 and "AM" or "PM"
    text.date_wd = days[c.weekday]:upper()
    text.date_md = months[c.month]:sub(1, 3):upper() .. " " .. c.day
end)

-- The player: whether there is one, and what the three buttons do.
-- cava listens to what is playing and prints one line per frame: 24 bars, 0..1000.
-- It only runs while something plays, and the bass is the mean of the low three.
local cava = nil
local last = 0
local spec_last = {}
local watching = false      -- the player's panel is open: when the equalizer is worth feeding (or while its card floats, `eq_float`)
function fw_on() return fact.fw_on == true or fact.fw_on == 1 end    -- the bottom frame rises into waves with the music (`fw_on`: Frame layout)
function eq_float() return fact.mf_out == true or fact.mf_out == 1 or fact.dash_open == true end    -- the media card is floating on the desktop (a global: this chunk is at Luau's limit of locals)

-- cava wants its config as a file. It is kept here rather than in a file next to the scene, so
-- nothing depends on where Vitreus is installed: it is written into the scene's own data folder (where
-- `dnd.json` and `calendar.json` already live) and cava is pointed at it. That folder is
-- `$XDG_DATA_HOME/pleamar/vitreus`, or `$HOME/.local/share/pleamar/vitreus`, and the sandbox has no
-- `os.getenv`, so the environment is asked of the system once. A player that starts before the
-- answer arrives waits for it.
local CAVA_CONF = table.concat({
    "[general]", "bars = 24", "framerate = 60",
    "[input]", "method = pipewire",
    "[smoothing]", "noise_reduction = 25",     -- cava's own smoothing, low: the springs of `spec.s.*` (vitreus.plm) smooth what is drawn, and the bass keeps its spikes
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
        local bass = math.min(1, (b[1] + b[2] + (b[3] or 0)) / 3)
        -- the equalizer in the media card: only worth sending while that panel is showing
        if watching or eq_float() or fw_on() then
            for i = 1, 24 do
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
    for i = 1, 24 do spec_last[i] = 0; fact["spec." .. (i - 1)] = 0 end
end

-- cava only runs while what it feeds is on screen: the bar's swell on the beat, which only the Island layout
-- has (in the Frame layout the bar is the frame, and `pv` is 0), and the equalizer in the player's panel. Left
-- running in the Frame layout it kept the `pulse` spring moving for nothing, and so the whole scene painting at the
-- monitor's rate for as long as music played. (Globals: this chunk is at Luau's limit of locals.)
cava_playing = false
game_fx = { on = false }          -- Game mode (logic/gamemode.luau) sets `on`: nothing listens to the music while it is
function cava_want()
    if game_fx.on then hush() return end
    if cava_playing and (fact.bar_anchor == "top" or fact.bar_anchor == "bottom" or watching or eq_float() or fw_on()) then listen() else hush() end
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

-- The cover is drawn in a square tile and a picture is fitted inside its cell, so a wide one (a video's thumbnail, most
-- of them) would leave empty bands above and below: crop it to its middle square first.
local art_seq = 0
local function show_art(path)
    art_seq = art_seq + 1
    local mine = art_seq
    if path == "" then
        text.arturl = ""
        fact.art_on = false
        return
    end
    local sq = "/tmp/vitreus-art-" .. hash(path) .. "-sq.png"
    run("magick", { path .. "[0]", "-gravity", "center", "-crop", "1:1", "+repage", "-resize", "256x256", sq }, function(_, code)
        if mine ~= art_seq then return end
        text.arturl = code == 0 and sq or path
        fact.art_on = true
    end)
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
-- A live video's own clock: a browser reports a stream's position inside the segment it has at hand, and that went back to zero every 15 seconds. So for a
-- stream with no end the time shown is counted here, from when the song came up, a second at a time while it plays. (A global: this chunk is at Luau's limit of locals.)
mpl = { sec = 0 }

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
        mpl.sec = 0
        fetch_art(m.player)
        -- players often publish the cover a moment after the title
        after(900, function() fetch_art(m.player) end)
        -- a browser fetches a video's thumbnail on its own time and can be several seconds: while this song has no cover yet, ask again
        -- (stopping as soon as one is there, or the song changes)
        for _, d in ipairs({ 2500, 6000, 12000, 25000 }) do
            after(d, function()
                if song == now and not fact.art_on then fetch_art(m.player) end
            end)
        end
        if not first then emit("trackchange") end
    end
end)
-- The seek row. MPRIS does not say where a song is as it plays, so while the player is open and something plays, `playerctl position` is read once
-- a second; the length comes with the song. A seek goes to the same player (or, if the name the service gave is not one playerctl knows, to whichever is).
local mp_player, mp_quiet = "", 0               -- `mp_quiet`: a seek was just asked for; readings wait, a player takes a moment to get there
local function mp_clock(sec)
    sec = math.max(0, math.floor((sec or 0) + 0.5))
    local h, m, s2 = sec // 3600, (sec % 3600) // 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s2) end
    return string.format("%d:%02d", m, s2)
end
local function mp_show(pos)
    if (fact.mp_len or 0) <= 0 then pos = mpl.sec end       -- a stream with no end: our own count (see `mpl`)
    fact.mp_pos = pos
    text.mp_el = mp_clock(pos)
end
local function mp_read()
    if mp_player == "" or mp_quiet > 0 then return end
    run("playerctl", { "-p", mp_player, "position" }, function(out, code)
        local v = code == 0 and tonumber((tostring(out or "")):match("[%d%.]+")) or nil
        if v then mp_show(v) return end
        run("playerctl", { "position" }, function(out2, code2)
            local w = code2 == 0 and tonumber((tostring(out2 or "")):match("[%d%.]+")) or nil
            if w then mp_show(w) end
        end)
    end)
end
every(1000, function()
    if (fact.mp_len or 0) <= 0 and fact.media_on and cava_playing then mpl.sec = mpl.sec + 1 end
    if (fact.panel == "player" or fact.mf_out or fact.dash_open == true) and fact.media_on and not fact.mp_drag then
        if (fact.mp_len or 0) <= 0 then mp_show(0) else mp_read() end
    end
end)
on("fact:panel", function(v) if v == "player" then mp_read() end end)
on("fact:mf_out", function(v)
    if eq_float() then mp_read() end
    cava_want()
end)
sys.watch("media", function(m)
    mp_player = m.player or ""
    local len = tonumber(m.length) or 0
    if len > 43200 then len = 0 end                       -- half a day or more is a stream with no real end (its "length" is a made-up number)
    fact.mp_len = len
    text.mp_tot = len > 0 and mp_clock(len) or ""
end)
on("mp_seek", function(f)
    if type(f) ~= "number" or (fact.mp_len or 0) <= 0 or mp_player == "" then return end
    local to = math.max(0, math.min(1, f)) * fact.mp_len
    mp_show(to)                                            -- the bar stays where it was let go, not where the last reading had it
    mp_quiet = mp_quiet + 1
    after(1500, function() mp_quiet = math.max(0, mp_quiet - 1) end)
    local secs = string.format("%.2f", to)
    run("playerctl", { "-p", mp_player, "position", secs }, function(_, code)
        if code ~= 0 then run("playerctl", { "position", secs }, function() end) end
    end)
end)
on("mcmd", function(k)
    sys.call(k == 0 and "media.previous" or (k == 1 and "media.toggle" or "media.next"))
end)

-- The volume slider: the scene turns the pointer into 0..1, the mixer takes it.
-- A drag sends a value for every step of the pointer; each used to start its own call, and they queued up behind each other (the slider answered up to a second late). Now only
-- the latest value waits its turn: one call at most every 40 ms, and the last one always goes.
local function coalesced(service)
    local pending, busy = nil, false
    local function pump()
        if pending ~= nil then
            local v = pending
            pending = nil
            sys.call(service, v)
            after(40, pump)
        else
            busy = false
        end
    end
    return function(v)
        pending = v
        if not busy then busy = true; pump() end
    end
end
on("setvol", coalesced("audio.volume"))
on("setbright", coalesced("brightness.level"))
on("setmic", coalesced("audio.input"))

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

-- Quiet hours and "silence while a window is fullscreen" (Settings > Notifications): Do Not Disturb that turns itself on. `DQ.active()` says whether either
-- is holding notifications back right now; pressing the tile's pill while only they are `skip`s them until they would have ended.
local DQ = { on = false, from = 22 * 60, to = 7 * 60, fullscreen = false, fs = false, skip = false }
function DQ.clock(m)
    local h = (m // 60) % 24
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m % 60, h < 12 and "AM" or "PM")
end
function DQ.quiet()
    if not DQ.on or DQ.from == DQ.to then return false end
    local t = os.date("*t")
    local m = t.hour * 60 + t.min
    if DQ.from < DQ.to then return m >= DQ.from and m < DQ.to end
    return m >= DQ.from or m < DQ.to
end
function DQ.active()
    local q, f = DQ.quiet(), DQ.fullscreen and DQ.fs
    if not q and not f then DQ.skip = false end
    return (q or f) and not DQ.skip
end
local function dnd_save()
    pcall(sys.call, "files.write", "dnd.json", { manual = dnd_manual, ends = dnd_until, len = dnd_len,
        quiet = { on = DQ.on, from = DQ.from, to = DQ.to, fullscreen = DQ.fullscreen } })
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
        if i > 50 then break end
        -- one line each: a body with line breaks (a list) would otherwise spill over the row under it
        local title = ((h.title or ""):gsub("%s+", " "))
        local body = ((h.body or ""):gsub("%s+", " "))
        rows[i] = { title = title, sub = body ~= "" and (h.app .. "  ·  " .. body) or h.app, when = nt_when(h.t) }
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
    dnd = dnd_manual or dnd_until > 0 or DQ.active()
    if dnd ~= was and NTR.sync then NTR.sync() end   -- an app's explanation says whether Do Not Disturb holds it back
    fact.dnd_on = dnd
    fact.dnd_len = dnd_until > 0 and dnd_len or 0
    fact.dnd_frac = 0
    if dnd_until > 0 then
        text.dnd_left = dnd_left_text() .. " left"
        text.nt_tile_sub = "Silenced · " .. dnd_left_text()
        text.dnd_big = dnd_left_text()
        text.dnd_small = "left, notifications silenced"
        if dnd_len > 0 then fact.dnd_frac = math.min(1, math.max(0, (dnd_until - os.time()) / (dnd_len * 60))) end
    elseif dnd_manual then
        text.dnd_left = "Until turned off"
        text.nt_tile_sub = "Silenced"
        text.dnd_big = "On"
        text.dnd_small = "silenced until you turn it off"
    elseif dnd and DQ.quiet() then
        text.dnd_left = "Quiet until " .. DQ.clock(DQ.to)
        text.nt_tile_sub = "Quiet until " .. DQ.clock(DQ.to)
        text.dnd_big = "Quiet"
        text.dnd_small = "quiet hours until " .. DQ.clock(DQ.to)
    elseif dnd then
        text.dnd_left = "Fullscreen"
        text.nt_tile_sub = "Silenced · fullscreen"
        text.dnd_big = "Quiet"
        text.dnd_small = "silenced while a window is fullscreen"
    else
        text.dnd_left = "Off"
        text.nt_tile_sub = #nt_hist > 0 and (#nt_hist .. " in history") or "All clear"
        text.dnd_big = "Off"
        text.dnd_small = "notifications come through"
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
        if type(saved.quiet) == "table" then
            DQ.on = saved.quiet.on == true
            DQ.fullscreen = saved.quiet.fullscreen == true
            if type(saved.quiet.from) == "number" then DQ.from = saved.quiet.from % 1440 end
            if type(saved.quiet.to) == "number" then DQ.to = saved.quiet.to % 1440 end
        end
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
        if DQ.active() then DQ.skip = true end            -- only quiet hours or a fullscreen window were holding: let notifications through until they would end
    else
        dnd_manual = true
    end
    dnd_save()
    dnd_refresh()
end)

-- Game mode (logic/gamemode.luau) silences notifications for as long as it is on, as a manual Do Not Disturb. `start` says whether it did
-- (false: something was silencing already, which is then left alone); `stop` lifts only what `start` set.
game_fx.dnd_start = function()
    if dnd then return false end
    dnd_manual = true
    dnd_save()
    dnd_refresh()
    return true
end
game_fx.dnd_stop = function()
    if not dnd_manual then return end                    -- turned off by hand in the meantime: nothing to undo
    dnd_manual, dnd_until, dnd_len = false, 0, 0
    dnd_save()
    dnd_refresh()
end

-- Game mode on niri: animations off, through the same vitreus.kdl the Hyprland page's switch writes (niri reads it again by itself).
-- What was set is put back; nothing is saved to niri-set.json, so a restart of the shell ends it.
game_fx.niri = function(on)
    iris_fx.niri_load()
    if on then
        if game_fx.niri_prior == nil then game_fx.niri_prior = { niri_set.anim } end
        niri_set.anim = false
    else
        local p = game_fx.niri_prior
        if not p then return end
        niri_set.anim = p[1]
        game_fx.niri_prior = nil
    end
    iris_fx.apply_niri()
end
-- And on pleamar-wm: its windows go square, shadowless and fully opaque (the scene's own facts, as Settings > Pleamar-WM sets them).
-- The values it had are asked first and sent back after.
game_fx.wm = function(on)
    local NAMES = { "rad", "shd", "wo_a", "wo_i" }
    if on then
        if game_fx.wm_prior then return end
        local prior, n = {}, 0
        for _, k in ipairs(NAMES) do
            wm_get(k, function(v)
                prior[k] = v
                n = n + 1
                if n == #NAMES then
                    game_fx.wm_prior = prior
                    wm_say("fact rad 0")
                    wm_say("fact shd 0")
                    wm_say("fact wo_a 100")
                    wm_say("fact wo_i 100")
                end
            end)
        end
    else
        local p = game_fx.wm_prior
        if not p then return end
        game_fx.wm_prior = nil
        for _, k in ipairs(NAMES) do if p[k] then wm_say("fact " .. k .. " " .. p[k]) end end
    end
end

-- The Notifications page's card: the schedule and the fullscreen switch, shown through facts (`nt_quiet`, `nt_fs`, and the two times as text).
local function dq_sync()
    fact.nt_quiet = DQ.on
    fact.nt_fs = DQ.fullscreen
    text.nt_qfrom_t = DQ.clock(DQ.from)
    text.nt_qto_t = DQ.clock(DQ.to)
end
on("nt_q_toggle", function() DQ.on = not DQ.on; DQ.skip = false; dnd_save(); dq_sync(); dnd_refresh() end)
on("nt_fs_toggle", function() DQ.fullscreen = not DQ.fullscreen; DQ.fs = false; DQ.skip = false; dnd_save(); dq_sync(); dnd_refresh(); DQ.check() end)
on("nt_q_step", function(k)        -- 0 start earlier, 1 start later, 2 end earlier, 3 end later: half an hour at a time
    k = math.floor((tonumber(k) or 0) + 0.5)
    if k == 0 then DQ.from = (DQ.from - 30) % 1440
    elseif k == 1 then DQ.from = (DQ.from + 30) % 1440
    elseif k == 2 then DQ.to = (DQ.to - 30) % 1440
    elseif k == 3 then DQ.to = (DQ.to + 30) % 1440 end
    DQ.skip = false
    dnd_save(); dq_sync(); dnd_refresh()
end)
dq_sync()
every(20000, dnd_refresh)                                   -- quiet hours begin and end by the clock
-- A fullscreen window is asked of Hyprland (the `fullscreen` of the focused window is 2 for a real fullscreen), only while that switch is on:
-- when Hyprland's event socket says a window went fullscreen or back, or the focus or the workspace moved (`DQ.poke`, from watch_urgent),
-- and every half minute in case an event was missed. (It used to be asked every 2.5 s, and still is without Hyprland.)
function DQ.check()
    if not DQ.fullscreen then return end
    run("hyprctl", { "activewindow", "-j" }, function(out)
        local ok, j = pcall(json.decode, out or "")
        local fs = ok and type(j) == "table" and (tonumber(j.fullscreen) or 0) >= 2
        if fs ~= DQ.fs then DQ.fs = fs; dnd_refresh() end
    end)
end
function DQ.poke()
    if not DQ.fullscreen or DQ.poking then return end
    DQ.poking = true
    after(120, function() DQ.poking = false; DQ.check() end)      -- a burst of events (a workspace switch says several) is asked once
end
-- (Without Hyprland there are no such events, pleamar-wm's `hyprctl activewindow` is asked every 2.5 s, as before.)
DQ.ticks = 0
every(2500, function()
    DQ.ticks = DQ.ticks + 1
    if not on_hyprland or DQ.ticks % 12 == 0 then DQ.check() end
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
-- The dashboard's picture: pressing it opens a browser inside the dashboard (it starts in Pictures): folders to go into, and the
-- pictures in them as square thumbnails (cropped once into a cache, so they are all the same shape). One pressed is cropped square and kept
-- as ~/.face (the lock screen reads it too), and the card reloads it (its path is cleared for a moment, so the same path is read again).
-- (A global table: this chunk is at Luau's limit of locals.)
FACE = { dir = "", ent = {}, token = 0, cache = "" }
FACE_MAX = 72
-- The home folder is asked of the system once: the system monitor (`sm_face`) only runs while the dashboard or the System page is open,
-- so the Wallpaper page's browser cannot count on it.
FACE.h = ""
run("printenv", { "HOME" }, function(out, code) if code == 0 then FACE.h = ((out or ""):gsub("%s+$", "")) end end)
function FACE.home() return FACE.h ~= "" and FACE.h or (text.sm_face:match("^(.*)/[^/]*$") or "") end
function FACE.show(ready)
    local rows = {}
    for k, e in ipairs(FACE.ent) do
        rows[k] = { thumb = (not e.dir and ready[e.key]) and (FACE.cache .. "/" .. e.key .. ".png") or "", name = e.name, dir = e.dir }
    end
    model.face_pics = rows
end
function FACE.load(dir)
    local home = FACE.home()
    if home == "" then return end
    FACE.token = FACE.token + 1
    local tok = FACE.token
    FACE.cache = home .. "/.cache/pleamar/vitreus/face"
    run("find", { "-L", dir, "-maxdepth", "1", "-mindepth", "1", "-printf", "%y\t%T@\t%f\n" }, function(out, code)
        if tok ~= FACE.token then return end
        if code ~= 0 then if dir ~= home then FACE.load(home) end return end
        FACE.dir = dir
        text.face_path = dir == home and "~" or (dir:sub(1, #home + 1) == home .. "/" and "~" .. dir:sub(#home + 1) or dir)
        fact.face_at_top = dir == "/"
        fact.fp_to = 0
        local ds, fs = {}, {}
        for line in (out or ""):gmatch("[^\n]+") do
            local ty, t, name = line:match("^(%a)\t([%d%.]+)\t(.+)$")
            if name and name:sub(1, 1) ~= "." then
                if ty == "d" then ds[#ds + 1] = { name = name, dir = true, path = (dir == "/" and "" or dir) .. "/" .. name }
                else
                    local n = name:lower()
                    if n:match("%.png$") or n:match("%.jpe?g$") or n:match("%.webp$") or n:match("%.avif$") or n:match("%.bmp$") then
                        local p = (dir == "/" and "" or dir) .. "/" .. name
                        fs[#fs + 1] = { name = name, dir = false, path = p, t = tonumber(t) or 0, key = hash(p .. "@" .. t) }
                    end
                end
            end
        end
        table.sort(ds, function(a, b) return a.name:lower() < b.name:lower() end)
        table.sort(fs, function(a, b) return a.t > b.t end)
        FACE.ent = {}
        for _, e in ipairs(ds) do if #FACE.ent < FACE_MAX then FACE.ent[#FACE.ent + 1] = e end end
        for _, e in ipairs(fs) do if #FACE.ent < FACE_MAX then FACE.ent[#FACE.ent + 1] = e end end
        local ready = {}
        FACE.show(ready)
        run("mkdir", { "-p", FACE.cache }, function()
            run("find", { FACE.cache, "-name", "*.png", "-printf", "%f\n" }, function(have)
                if tok ~= FACE.token then return end
                for f in (have or ""):gmatch("[^\n]+") do ready[f:gsub("%.png$", "")] = true end
                FACE.show(ready)
                local todo = {}
                for _, e in ipairs(FACE.ent) do if not e.dir and not ready[e.key] then todo[#todo + 1] = e end end
                local nexti, active = 1, 0
                local function pump()
                    while active < 3 and nexti <= #todo do
                        local e = todo[nexti]
                        nexti = nexti + 1
                        active = active + 1
                        run("magick", { "-define", "jpeg:size=400x400", e.path .. "[0]", "-auto-orient", "-thumbnail", "200x200^", "-gravity", "center", "-extent", "200x200",
                            "PNG:" .. FACE.cache .. "/" .. e.key .. ".png" }, function(_, c)
                            active = active - 1
                            if tok ~= FACE.token then return end
                            if c == 0 then ready[e.key] = true end
                            if active == 0 and nexti > #todo or (nexti - 1) % 6 == 0 then FACE.show(ready) end
                            pump()
                        end)
                    end
                end
                pump()
            end)
        end)
    end)
end
on("face_list", function()
    local home = FACE.home()
    if home ~= "" then FACE.load(home .. "/Pictures") end
end)
on("face_nav", function(i)
    local e = FACE.ent[(tonumber(i) or 0) + 1]
    if e and e.dir then FACE.load(e.path) end
end)
on("face_up", function()
    if FACE.dir ~= "" and FACE.dir ~= "/" then FACE.load(FACE.dir:match("^(.*)/[^/]*$") ~= "" and FACE.dir:match("^(.*)/[^/]*$") or "/") end
end)
on("face_home", function() local h = FACE.home(); if h ~= "" then FACE.load(h) end end)
on("face_set", function(i)
    local e = FACE.ent[(tonumber(i) or 0) + 1]
    local face = text.sm_face
    if not e or e.dir or face == "" then return end
    run("magick", { e.path .. "[0]", "-auto-orient", "-resize", "512x512^", "-gravity", "center", "-extent", "512x512", "PNG:" .. face }, function(_, code)
        if code ~= 0 then return end
        -- A file written again under the same name is read again when asked for with a new version (`?n`).
        FACE.ver = (FACE.ver or 0) + 1
        text.sm_avatar = face .. "?" .. FACE.ver
        fact.sm_has_avatar = true
        -- the login screen shows the same picture: it reads it from a folder install.sh made for it (nothing happens if there is none)
        run("cp", { "-f", face, "/usr/local/share/vitreus-greeter/avatar.png" }, function() end)
    end)
end)

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
        text.caf_big = caf_left_text()
        text.caf_small = "left until it may sleep"
        fact.caf_frac = (caf_len > 0) and math.min(1, math.max(0, (caf_until - os.time()) / (caf_len * 60))) or 0
    elseif caf_on then
        text.caf_left = "On until turned off"
        text.caf_tile_sub = "Awake"
        text.caf_big = "On"
        text.caf_small = "awake until you turn it off"
        fact.caf_frac = 0
    else
        text.caf_left = "Off"
        text.caf_tile_sub = "Off"
        text.caf_big = "Off"
        text.caf_small = "the screen may sleep"
        fact.caf_frac = 0
    end
end

local function caf_poll(after_poll)
    -- Awake is the idle inhibitor (vitreus-inhibit) running: it is what keeps pleamar-wm's screens on, and what the tile shows.
    run("pgrep", { "-x", "vitreus-inhibit" }, function(_, code)
        caf_on = code == 0
        -- the helper is gone on its own (or was never started): whatever timer was running has no meaning
        if not caf_on and caf_until > 0 and not caf_busy then
            caf_until, caf_len = 0, 0
            caf_save()
        end
        caf_refresh()
        if after_poll then after_poll() end
    end)
end

-- Keep the machine awake (the inhibitor runs, and hypridle, where there is one, is stopped), or let it sleep again (the
-- inhibitor ends and hypridle is started), then read what happened.
local function caf_set(awake)
    caf_busy = true
    local done = function() caf_poll(function() caf_busy = false end) end
    if awake then
        run("pkill", { "-x", "hypridle" }, function()
            run("systemctl", { "--user", "stop", "hypridle.service" }, function()
                -- the helper is looked for first: a second press must not start a second one
                run("pgrep", { "-x", "vitreus-inhibit" }, function(_, found)
                    if found ~= 0 then run("setsid", { "-f", "vitreus-inhibit" }, function() after(400, done) end) else done() end
                end)
            end)
        end)
    else
        run("pkill", { "-x", "vitreus-inhibit" }, function()
            -- systemctl returns before the daemon is there to be found: a moment's wait before reading.
            run("systemctl", { "--user", "start", "hypridle.service" }, function() after(400, done) end)
        end)
    end
end

run("which", { "vitreus-inhibit" }, function(_, code)
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
        -- Whether the inhibitor is running: every five seconds while the Controls panel (where the Caffeine tile is) is open, every thirty otherwise.
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
-- Devices a scan found stay in the list (Nearby) for as long as the Bluetooth window is open, not just while the scan runs: BlueZ forgets an
-- unpaired device some seconds after discovery stops, but the list used to drop them the moment the scan ended. `rows` keeps the last row of
-- each by address; one BlueZ has dropped meanwhile is still listed (`gone`), and pressing it scans again for a few seconds before connecting.
-- (A global: this chunk is at Luau's limit of locals.)
BT_SEEN = { rows = {} }

-- The list is built here: what is connected first, then what is paired, then the
-- rest, named ones alphabetically and the anonymous ones (BLE beacons, mostly, which are dozens) last, by
-- address. Unpaired devices are only shown while a scan is running: BlueZ goes on reporting what walked past
-- for minutes afterwards, and a stale list of strangers is worse than none.
-- What a device is, from the icon name BlueZ gives it (or, failing that, its name): the glyph on its row.
-- 0 generic, 1 headphones, 2 keyboard, 3 mouse, 4 phone, 5 game controller, 6 speaker, 7 computer
local function bt_kind(icon, name)
    local i = (icon or ""):lower()
    local n = (name or ""):lower()
    if i:find("headset") or i:find("headphone") or n:find("airpods") or n:find("buds") or n:find("headphone") or n:find("headset") then return 1 end
    if i:find("keyboard") or n:find("keyboard") then return 2 end
    if i:find("mouse") or i:find("tablet") or n:find("mouse") or n:find("trackpad") then return 3 end
    if i:find("phone") then return 4 end
    if i:find("gaming") or n:find("controller") or n:find("gamepad") then return 5 end
    if i:find("audio") or i:find("speaker") or n:find("speaker") or n:find("soundbar") then return 6 end
    if i:find("computer") or i:find("laptop") then return 7 end
    return 0
end
local function bt_is_mac(n) return n:match("^%x%x[-:]%x%x[-:]%x%x[-:]%x%x[-:]%x%x[-:]%x%x$") ~= nil end

-- What a tap has asked for and BlueZ has not answered yet, by address: connecting or disconnecting takes
-- seconds, and BlueZ can drop the device from its list while it works. Until it answers the row stays where it
-- was (remembered from the last time it was seen), says what it is doing, and only then takes its new place.
local bt_pending = {}                     -- address -> { kind = 1 connecting | 2 disconnecting | 3 failed, row = last row, gen = n }
local bt_gen = 0
local bt_open_addr = nil                  -- the address of the row that is open: its index moves when the list re-sorts
local bt_prof_refresh = function() end   -- the open device's audio profiles (set below)
local bt_dev_refresh = function() end    -- the open device's trust and name, and this computer's own details (set below)

local function pick_sec_name(sec) return sec == 1 and "CONNECTED" or (sec == 2 and "PAIRED" or "NEARBY") end

local function bt_render()
    local b = bt_last
    if not b then return end
    local name, name_bat = "", -1
    local rows = {}
    local seen = {}
    for _, d in ipairs(b.devices or {}) do
        if d.connected then name = d.name; name_bat = d.battery or -1 end
        if d.paired or d.connected or bt_scanning or bt_pending[d.address] or BT_SEEN.rows[d.address] then
            local nm = (d.name ~= nil and d.name ~= "") and d.name or d.address
            local row = {
                name = nm, address = d.address, paired = d.paired and true or false,
                connected = d.connected and true or false, battery = d.battery or -1,
                anon = bt_is_mac(nm), busy = 0, hd = 0, kind = bt_kind(d.icon, nm),
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
            if not row.paired and not row.connected then BT_SEEN.rows[d.address] = row end
        end
    end
    -- found by a scan, then forgotten by BlueZ: still listed while the window is open
    for addr, r in pairs(BT_SEEN.rows) do
        if not seen[addr] and not bt_pending[addr] then
            local row = {}
            for k, v in pairs(r) do row[k] = v end
            row.busy, row.gone = 0, true
            seen[addr] = true
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
    while #rows > 22 do table.remove(rows) end
    -- Sections: a heading row goes in front of each run (Connected, Paired, Nearby). It is a row of the list like the others,
    -- so positions stay what the scene sends back; `hd` says which heading it is and a tap on it does nothing.
    local with_heads, last_sec = {}, 0
    for _, r in ipairs(rows) do
        local sec = r.connected and 1 or (r.paired and 2 or 3)
        if sec ~= last_sec then
            last_sec = sec
            with_heads[#with_heads + 1] = {
                name = pick_sec_name(sec), address = "", paired = false, connected = false, battery = -1,
                anon = false, busy = 0, hd = sec, kind = 0,
            }
        end
        with_heads[#with_heads + 1] = r
    end
    rows = with_heads
    local list_h = 0
    for _, r in ipairs(rows) do list_h = list_h + (r.hd > 0 and 20 or 30) + 5 end
    fact.bt_list_h = math.max(0, list_h - 5)
    local working = false
    for _, r in ipairs(rows) do if r.busy == 1 or r.busy == 2 then working = true end end
    fact.bt_working = working
    fact.bt_connected = name ~= ""
    -- the Power window lists the charge of every connected device that reports one
    local bats = {}
    for _, r in ipairs(rows) do
        if r.hd == 0 and r.connected and r.battery >= 0 and #bats < 6 then bats[#bats + 1] = { name = r.name, level = r.battery } end
    end
    fact.bat_n = #bats
    model.bat_devs = bats
    -- the tile says the name and, when the device reports one, its charge: Headphones · 80 %
    text.bt_name = (name ~= "" and name_bat >= 0) and (name .. " · " .. math.floor(name_bat * 100 + 0.5) .. "%") or name
    bt_list = rows
    local sig = {}
    for i, r in ipairs(rows) do
        sig[i] = r.hd .. "|" .. r.kind .. "|" .. r.address .. "|" .. r.name .. "|" .. tostring(r.paired) .. "|" .. tostring(r.connected) .. "|" .. tostring(r.battery) .. "|" .. r.busy
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
        bt_dev_refresh()
    end
end

sys.watch("bluetooth", function(b)
    bt_last = b
    bt_render()
end)

on("fact:bt_open_row", function(i)
    local d = i >= 0 and bt_list[i + 1] or nil
    if d and d.hd > 0 then d = nil end
    bt_open_addr = d and d.address or nil
    bt_prof_refresh()
    bt_dev_refresh()
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

-- What the open device lets you change (its name, and whether it may reconnect by itself) and what this computer shows
-- of itself. BlueZ keeps "trusted" on the device: a trusted one may connect without asking, which is the auto-connect.
-- A device's name is its Alias, set over D-Bus (`bluetoothctl` can only rename the adapter). Both are read when a row
-- opens and when the list changes; the adapter every few seconds, since "discoverable" times out by itself.
do
local adapter = "hci0"
local trusted = false
local discoverable = false
local rename_for = nil

run("busctl", { "--system", "tree", "org.bluez", "--list" }, function(out, code)
    if code ~= 0 then return end
    for path in (out or ""):gmatch("[^\n]+") do
        local a = path:match("^/org/bluez/(hci%d+)%s*$")
        if a then adapter = a; return end
    end
end)

local function adapter_refresh()
    if not (bt_last and bt_last.powered) then return end
    run("bluetoothctl", { "show" }, function(out, code)
        if code ~= 0 then return end
        out = out or ""
        text.bt_adapter = out:match("\n%s*Alias: ([^\n]*)") or ""
        text.bt_adapter_addr = out:match("Controller (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") or ""
        discoverable = out:match("\n%s*Discoverable: (%a+)") == "yes"
        fact.bt_discoverable = discoverable
    end)
end

bt_dev_refresh = function()
    local addr = bt_open_addr
    local dev
    for _, r in ipairs(bt_list) do if r.address == addr then dev = r end end
    if not addr or not dev or not (dev.paired or dev.connected) then
        fact.bt_set_h = 0
        rename_for = nil
        return
    end
    fact.bt_set_h = 74
    if rename_for ~= addr then
        rename_for = addr
        text.bt_rename = dev.name
    end
    run("bluetoothctl", { "info", addr }, function(out, code)
        if code ~= 0 or bt_open_addr ~= addr then return end
        trusted = (out or ""):match("Trusted: (%a+)") == "yes"
        fact.bt_trusted = trusted
    end)
end

on("bt_trust_toggle", function()
    local addr = bt_open_addr
    if not addr then return end
    trusted = not trusted
    fact.bt_trusted = trusted
    run("bluetoothctl", { trusted and "trust" or "untrust", addr }, function() bt_dev_refresh() end)
end)

on("bt_rename_go", function()
    local addr = bt_open_addr
    local name = (text.bt_rename or ""):match("^%s*(.-)%s*$")
    if not addr or name == "" then return end
    local path = "/org/bluez/" .. adapter .. "/dev_" .. addr:gsub(":", "_")
    run("busctl", { "--system", "set-property", "org.bluez", path, "org.bluez.Device1", "Alias", "s", name }, function() end)
end)

on("bt_disc_toggle", function()
    local want = not discoverable
    discoverable = want
    fact.bt_discoverable = want
    if want then
        run("bluetoothctl", { "pairable", "on" }, function()
            run("bluetoothctl", { "discoverable", "on" }, function() adapter_refresh() end)
        end)
    else
        run("bluetoothctl", { "discoverable", "off" }, function() adapter_refresh() end)
    end
end)

adapter_refresh()
-- The adapter's name and "discoverable" are only drawn in the Bluetooth window: read while it is open, not all day.
on("fact:panel_sub", function(v) if tostring(v) == "btview" then adapter_refresh() end end)
every(5000, function() if tostring(fact.panel) == "controls" and tostring(fact.panel_sub) == "btview" then adapter_refresh() end end)
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
    if not d or d.hd > 0 or d.busy == 1 or d.busy == 2 then return end
    if d.connected then
        bt_ask(d, 2, "bluetooth.disconnect")
    elseif d.gone then
        -- BlueZ has forgotten it: look for it again (shown as connecting meanwhile), and connect once it is back; after ten seconds without it,
        -- the row says it could not, as a connection that is not answered does
        bt_pending[d.address] = { kind = 1, row = d, gen = -1 }
        bt_render()
        BT_SEEN.scan(10)
        local tries = 0
        local function look()
            tries = tries + 1
            for _, x in ipairs((bt_last and bt_last.devices) or {}) do
                if x.address == d.address then
                    bt_pending[d.address] = nil
                    return bt_ask(d, 1, "bluetooth.connect")
                end
            end
            if tries < 20 then return after(500, look) end
            local p = bt_pending[d.address]
            if p and p.gen == -1 then
                p.kind = 3
                bt_render()
                after(3000, function()
                    local q = bt_pending[d.address]
                    if q and q.gen == -1 then bt_pending[d.address] = nil; bt_render() end
                end)
            end
        end
        after(500, look)
    else
        bt_ask(d, 1, "bluetooth.connect")
    end
end)

on("bt_forget", function(i)
    local d = bt_list[i + 1]
    if not d or d.hd > 0 then return end
    bt_pending[d.address] = nil
    sys.call("bluetooth.forget", d.address)
    fact.bt_open_row = -1
end)

-- A scan gives the scene no sign of its own, so it is told to show one. Discovery is held open by
-- `bluetoothctl --timeout 12 scan on`: pleamar's own `bluetooth.scan` answers
-- without an error but BlueZ never starts discovering (`Discovering` stays "no"), while this does, and the
-- service picks up what it finds. It ends by itself after twelve seconds.
function BT_SEEN.scan(secs)
    if bt_scanning then return end
    bt_scanning = true
    fact.bt_scanning = true
    bt_render()
    run("bluetoothctl", { "--timeout", tostring(secs), "scan", "on" }, function()
        bt_scanning = false
        fact.bt_scanning = false
        bt_render()
    end)
end
on("bt_scan", function() BT_SEEN.scan(12) end)
-- The window closed: what the scans found is let go (BlueZ has forgotten most of it by now anyway).
function BT_SEEN.clear()
    if next(BT_SEEN.rows) == nil then return end
    BT_SEEN.rows = {}
    bt_render()
end
on("fact:panel_sub", function(v) if tostring(v) ~= "btview" then BT_SEEN.clear() end end)
on("fact:panel", function(v) if tostring(v) ~= "controls" then BT_SEEN.clear() end end)
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
            emit("wifi_scan_done", 1)
        end)
    end)
end)

-- The Wi-Fi window's list is built here from `nmcli`, because the network service has no band, channel or speed. A network
-- shows up once however many access points carry it (the one in use, else the strongest), sorted: in use, saved, then by
-- signal. The one in use also gets its address details from `nmcli device show`. As with Bluetooth, the open row is
-- remembered by name, since its position moves when the list re-sorts.
do
local WF = { rows = {}, sig = nil, open = nil, dev = nil, known = {}, busy = {}, gen = 0 }

-- `nmcli -t` puts a backslash before a ":" or "\" inside a value
local function nm_fields(line)
    local f, cur, i = {}, "", 1
    while i <= #line do
        local c = line:sub(i, i)
        if c == "\\" then cur = cur .. line:sub(i + 1, i + 1); i = i + 2
        elseif c == ":" then f[#f + 1] = cur; cur = ""; i = i + 1
        else cur = cur .. c; i = i + 1 end
    end
    f[#f + 1] = cur
    return f
end

local function wf_security(s)
    s = s or ""
    if s == "" or s == "--" then return "Open" end
    if s:find("WPA3") then return "WPA3" end
    if s:find("WPA2") then return "WPA2" end
    if s:find("WPA1") or s:find("WPA") then return "WPA" end
    if s:find("WEP") then return "WEP" end
    return s
end

local wf_details
local function wf_show()
    local open_row
    for _, r in ipairs(WF.rows) do if r.ssid == WF.open then open_row = r end end
    -- the details block under the connected network's buttons: six lines of 16 and a little air
    fact.wifi_pf_h = (open_row and open_row.active) and 104 or 0
    if open_row and open_row.active then wf_details() end
end

local function wf_render(rows)
    for _, r in ipairs(rows) do
        local b = WF.busy[r.ssid]
        r.busy = 0
        if b then
            if (b.kind == 1 and r.active) or (b.kind == 2 and not r.active) then WF.busy[r.ssid] = nil
            else r.busy = b.kind end
        end
    end
    local parts = {}
    for i, r in ipairs(rows) do
        parts[i] = table.concat({ r.bands or "", r.ssid, tostring(r.active), tostring(r.known), tostring(r.secure), r.band, r.chan, r.rate, r.sec, r.busy, math.floor(r.strength * 20) }, "|")
    end
    local sig = table.concat(parts, "\n")
    WF.rows = rows
    if sig ~= WF.sig then
        WF.sig = sig
        model.wifi_nets = rows
        if WF.open then
            local at = -1
            for i, r in ipairs(rows) do if r.ssid == WF.open then at = i - 1 end end
            if at ~= fact.wifi_open_row then fact.wifi_open_row = at end
        end
    end
    wf_show()
end

local function wf_refresh()
    run("nmcli", { "-t", "-f", "NAME,TYPE", "connection", "show" }, function(out, code)
        if code == 0 then
            local known = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local f = nm_fields(line)
                if f[2] == "802-11-wireless" then known[f[1]] = true end
            end
            WF.known = known
        end
        run("nmcli", { "-t", "-f", "IN-USE,SSID,SIGNAL,FREQ,CHAN,RATE,SECURITY", "device", "wifi", "list" }, function(o2, c2)
            if c2 ~= 0 then return end
            local best, bandset = {}, {}
            for line in (o2 or ""):gmatch("[^\n]+") do
                local f = nm_fields(line)
                local ssid = f[2] or ""
                if ssid ~= "" then
                    local mhz = tonumber((f[4] or ""):match("%d+")) or 0
                    local row = {
                        ssid = ssid, active = f[1] == "*", known = WF.known[ssid] == true,
                        strength = (tonumber(f[3]) or 0) / 100,
                        band = mhz >= 5925 and 6 or (mhz >= 4900 and 5 or (mhz > 0 and 2 or 0)),
                        chan = tonumber(f[5]) or 0, rate = tonumber((f[6] or ""):match("%d+")) or 0,
                        sec = wf_security(f[7]), busy = 0,
                    }
                    row.secure = row.sec ~= "Open"
                    local old = best[ssid]
                    bandset[ssid] = bandset[ssid] or {}
                    bandset[ssid][row.band] = true
                    if not old or (row.active and not old.active) or (not old.active and row.strength > old.strength) then
                        best[ssid] = row
                    end
                end
            end
            local rows = {}
            for _, r in pairs(best) do
                -- a network on several bands says all of them; the details are those of the strongest access point
                local names = {}
                for _, b in ipairs({ 2, 5, 6 }) do
                    if bandset[r.ssid][b] then names[#names + 1] = b == 2 and "2.4" or tostring(b) end
                end
                r.bands = #names > 0 and (table.concat(names, "/") .. " GHz") or ""
                r.bandw = #names > 0 and math.floor(14 + 5.6 * #r.bands) or 0
                rows[#rows + 1] = r
            end
            table.sort(rows, function(x, y)
                if x.active ~= y.active then return x.active end
                if x.known ~= y.known then return x.known end
                if x.strength ~= y.strength then return x.strength > y.strength end
                return x.ssid:lower() < y.ssid:lower()
            end)
            while #rows > 16 do table.remove(rows) end
            wf_render(rows)
        end)
    end)
end

wf_details = function()
    local function show(ip, gw, mac)
        text.wf_ip, text.wf_gw, text.wf_mac = ip or "", gw or "", mac or ""
    end
    local function read(dev)
        run("nmcli", { "-t", "-f", "IP4.ADDRESS,IP4.GATEWAY,GENERAL.HWADDR", "device", "show", dev }, function(out, code)
            if code ~= 0 then return end
            local ip, gw, mac
            for line in (out or ""):gmatch("[^\n]+") do
                local k, v = line:match("^([%w%.]+)[^:]*:(.*)$")
                if k == "IP4.ADDRESS" and not ip then ip = (v:gsub("\\", ""):gsub("/%d+$", ""))
                elseif k == "IP4.GATEWAY" then gw = v
                elseif k == "GENERAL.HWADDR" then mac = (v:gsub("\\", "")) end
            end
            show(ip, gw, mac)
        end)
    end
    if WF.dev then return read(WF.dev) end
    run("nmcli", { "-t", "-f", "DEVICE,TYPE", "device" }, function(out)
        for line in (out or ""):gmatch("[^\n]+") do
            local f = nm_fields(line)
            if f[2] == "wifi" then WF.dev = f[1]; return read(f[1]) end
        end
    end)
end

-- Whether this machine has a Wi-Fi adapter at all (a desktop with only a cable does not): the Control Center's Wi-Fi tile is greyed out without one. Asked of NetworkManager now and every
-- half minute (a USB adapter can be plugged in); if it does not answer, the tile is left as it was.
do
    local function wifi_hw_check()
        run("nmcli", { "-t", "-f", "DEVICE,TYPE", "device" }, function(out, code)
            if code ~= 0 or type(out) ~= "string" or out == "" then return end
            local has = false
            for line in out:gmatch("[^\n]+") do
                if nm_fields(line)[2] == "wifi" then has = true break end
            end
            if fact.wifi_hw ~= has then fact.wifi_hw = has end
        end)
    end
    wifi_hw_check()
    every(30000, wifi_hw_check)
end

on("fact:wifi_open_row", function(i)
    local r = i >= 0 and WF.rows[i + 1] or nil
    WF.open = r and r.ssid or nil
    wf_show()
end)

local function wf_ask(r, kind, call, ...)
    WF.gen = WF.gen + 1
    local gen = WF.gen
    WF.busy[r.ssid] = { kind = kind, gen = gen }
    wf_render(WF.rows)
    sys.call(call, ...)
    after(15000, function()
        local b = WF.busy[r.ssid]
        if b and b.gen == gen then
            WF.busy[r.ssid] = nil
            wf_refresh()
        end
    end)
    after(3000, wf_refresh)
end

on("wifi_pick", function(i)
    local r = WF.rows[math.floor(i + 0.5) + 1]
    if not r or r.busy ~= 0 then return end
    if r.active then wf_ask(r, 2, "network.disconnect")
    else wf_ask(r, 1, "network.connect", r.ssid) end
end)

on("wifi_join_go", function(i)
    local r = WF.rows[math.floor(i + 0.5) + 1]
    local pw = text.wifi_pw
    if not r or r.busy ~= 0 or not pw or pw == "" then return end
    text.wifi_pw = ""
    wf_ask(r, 1, "network.connect", r.ssid, pw)
end)

on("wifi_forget", function(i)
    local r = WF.rows[math.floor(i + 0.5) + 1]
    if not r then return end
    sys.call("network.forget", r.ssid)
    fact.wifi_open_row = -1
    after(1500, wf_refresh)
end)

on("wifi_copy_ip", function()
    local ip = text.wf_ip
    if ip and ip ~= "" then run("wl-copy", { ip }, function() end) end
end)

-- The list is only drawn in the Controls drawer's Wi-Fi window, so it is only read while that is open (and once as it opens): `nmcli device wifi
-- list` starts a scan of the air whenever the last one is older than half a minute, so asking it all day kept the radio scanning all day.
function WF.shown() return tostring(fact.panel) == "controls" and tostring(fact.panel_sub) == "netview" end
sys.watch("network", function() if WF.shown() then wf_refresh() end end)
on("fact:panel_sub", function(v) if tostring(v) == "netview" then wf_refresh() end end)
every(6000, function() if WF.shown() then wf_refresh() end end)
on("wifi_scan_done", wf_refresh)
end

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
-- Two connections in all (`say_many`): which slots are open, then the four things about each open one.
function refresh_tasks_wm()
    local function finish(slots)
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
    local first = {}
    for i = 0, 15 do first[#first + 1] = "get win." .. i .. ".open" end
    say_many("wm", first, function(r)
        if not r then return end
        local open, cmds = {}, {}
        for i = 0, 15 do
            if (r[i + 1] or ""):match("true") then
                open[#open + 1] = i
                for _, f in ipairs({ "title", "app", "workspace", "focused" }) do cmds[#cmds + 1] = "get win." .. i .. "." .. f end
            end
        end
        if #open == 0 then return finish({}) end
        say_many("wm", cmds, function(d)
            if not d then return end
            local slots = {}
            for n, i in ipairs(open) do
                local base = (n - 1) * 4
                local w = { slot = i, title = (d[base + 1] or ""):gsub("%s+$", ""), app = (d[base + 2] or ""):gsub("%s+$", "") }
                w.wsn = tonumber(d[base + 3]) or 0
                w.active = (d[base + 4] or ""):match("true") ~= nil
                if w.title == "" then w.title = w.app ~= "" and w.app or "Window" end
                slots[i] = w
            end
            finish(slots)
        end)
    end)
end

local function refresh_tasks()
    if not on_hyprland and not on_niri then return refresh_tasks_wm() end
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
                if n and n >= 1 and n <= 10 and n ~= tonumber(fact["ws.active"]) then
                    ws_urgent[n] = true
                    fact["ws." .. n .. ".urgent"] = true
                end
                return
            end
        end
    end)
end
-- Which mark a special workspace gets on the bar: 1 for `special:music`, 2 for `special:private`, 0 for the rest (the sparkle).
local function special_kind(name)
    local n = name:gsub("^special:", "")
    if n == "music" then return 1 elseif n == "private" then return 2 end
    return 0
end
local sc_active, sc_gen = 0, 0                       -- screencasts running now, and a counter that tells a later event from the one a timer was set for
function watch_urgent()
    run("printenv", { "XDG_RUNTIME_DIR" }, function(rt)
        run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(sig)
            rt, sig = (rt or ""):gsub("%s+$", ""), (sig or ""):gsub("%s+$", "")
            if rt == "" or sig == "" then return end
            spawn("socat", { "-u", "UNIX-CONNECT:" .. rt .. "/hypr/" .. sig .. "/.socket2.sock", "-" }, function(line)
                -- what can change whether the focused window is fullscreen (Do Not Disturb's "while fullscreen")
                if line:match("^configreloaded>>") and game_fx.hg_check then game_fx.hg_check() end      -- hyprglass loaded or unloaded
                if line:match("^activelayout>>") and LOCKKEYS and LOCKKEYS.layout then LOCKKEYS.layout() end           -- the keyboard layout changed (logic/lockkeys.luau)
                if line:match("^fullscreen>>") or line:match("^activewindowv2>>") or line:match("^workspacev2>>") or line:match("^closewindow>>") then DQ.poke() end
                -- A special workspace (the scratchpads) shown or put away: `activespecial>>special:magic,<name>`, with no name when it is put away.
                local spn = line:match("^activespecial>>([^,]*),")
                if spn then
                    fact["ws.special"] = spn ~= ""
                    fact["ws.spk"] = special_kind(spn)
                end
                local addr = line:match("^urgent>>(%x+)")
                if addr then window_urgent(addr) end
                -- the screen being shared or recorded through the portal (logic/privacy.luau has the rest of the privacy lights)
                -- (Hyprland also says it for a photo of a patch of screen, "region": that is what the glass of this shell and any
                -- screenshot tool take all the time, so only a whole monitor or window counts as sharing.)
                -- A capture only counts as sharing once it has lasted 1.5 s: the overview's window thumbnails (and anything else that grabs a window
                -- for a moment) start and stop within a blink and are not sharing, while a call or a recording goes on far longer. Several clients may
                -- capture at once, each with its own start (1) and stop (0), so they are counted; the light goes out the moment none is left.
                local sc, what = line:match("^screencast>>(%d),(%a+)")
                if sc and what ~= "region" then
                    if sc == "1" then sc_active = sc_active + 1 else sc_active = math.max(0, sc_active - 1) end
                    sc_gen = sc_gen + 1
                    local gen = sc_gen
                    if sc_active > 0 then
                        -- The pictures of windows that this shell asks pleamar for itself (the overview's, THUMB_UNTIL) are captures too, and
                        -- last longer than that wait: they are not sharing. While one is expected the light waits, and goes on only if the
                        -- capture is still there after it.
                        local function light()
                            if gen ~= sc_gen or sc_active <= 0 then return end
                            if os.time() <= (THUMB_UNTIL or 0) then return after(1000, light) end
                            fact.priv_scr = true
                            text.priv_scr_who = "Your screen is being shared"
                        end
                        after(1500, light)
                    else
                        fact.priv_scr = false
                        text.priv_scr_who = ""
                    end
                end
            end, function() after(3000, watch_urgent) end)
        end)
    end)
end
-- The desktop's own scenes (the right-click menu on the wallpaper and the stickers, which live under the windows, and the webcam, which lives over them) are programs of their own, since a scene has one layer. They are
-- not in the autostart file: this starts whichever of them is not running, once, a few seconds after the shell does. (The clock and the system monitor are started by the
-- autostart file, as before.)
after(4000, function()
    if not on_hyprland then return end
    for _, dir in ipairs({ "desktopmenu", "desktopnotes", "webcam", "desktopedit", "desktopcards" }) do
        -- (Hyprland runs the menu's own copy, desktopmenu_hypr.plm: background layer, wallpaper zone always live)
        local file = dir == "desktopmenu" and "desktopmenu_hypr" or dir
        run("pgrep", { "-f", dir .. "/" .. file .. ".plm" }, function(_, code)
            if code ~= 0 then
                exec_on_desktop('vitreus-keep "$HOME/.config/pleamar/shells/vitreus/' .. dir .. '/' .. file .. '.plm"')
            end
        end)
    end
end)
after(2000, function()
    if not on_hyprland then return end
    watch_urgent()
    -- One may already be in view when the shell starts.
    hypr_monitors(0, function(out)
        local sn = out and out:match('"specialWorkspace":%s*{[^}]*"name":%s*"(special:[^"]*)"')
        if sn then fact["ws.special"] = true; fact["ws.spk"] = special_kind(sn) end
    end)
end)

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
on("fact:fw_on", function() cava_want() end)
on("fact:dash_open", function() cava_want() end)
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
local nt_boot = os.time()   -- the notifications that turn up in the first seconds are the backlog from before login: never announced
-- The drawer's own state ("volume", "notif" or "none", in `nt_queue.osd`), mirrored into the scene's `osd_on`. It is not a value of `panel`,
-- so it shows beside Settings, the search, the desk... and never takes the place of a panel the user opened. (Kept on `nt_queue`, not in
-- locals of their own: a chunk may only have 200 of those, and this file is at the limit.)
nt_queue.osd = "none"
fact.osd_on = false         -- a reload of the logic leaves the scene's drawer out with nothing in it to close it: start from shut
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

-- Volume and brightness: whenever one changes, its row comes out in the volume drawer for two seconds (each on its own timer; with both, the drawer
-- holds both, one above the other). The drawer goes back once neither is out. The brightness has no row while the controls are open: their slider shows it.
local lvl_gen = { v = 0, b = 0, m = 0 }
local function show_level(row)
    if nt_queue.osd == "notif" and nt_now and nt_now.n then
        -- The level comes first: the notification on screen goes back to the front of the queue and shows again once the level has gone.
        table.insert(nt_queue, 1, nt_now.n)
        nt_now = nil
    end
    osd_gen = osd_gen + 1
    lvl_gen[row] = lvl_gen[row] + 1
    local gen = lvl_gen[row]
    nt_queue.hold = true            -- no notification is shown while a level is (see `pump`)
    fact["osd_" .. row] = true
    fact.osd_kind = "vol"
    nt_queue.set_osd("volume")
    after(2000, function()
        if gen ~= lvl_gen[row] then return end
        for _, other in ipairs({ "v", "b", "m" }) do
            if other ~= row and fact["osd_" .. other] then
                fact["osd_" .. row] = false                 -- another is still out: this row goes and the drawer shrinks to the rest
                return
            end
        end
        hide_osd("vol")
        nt_queue.hold = false
        if nt_queue.pump then nt_queue.pump() end           -- `pump` is declared further down
        -- the row stays drawn while the drawer folds away, and goes once it is in
        after(450, function() if gen == lvl_gen[row] then fact["osd_" .. row] = false end end)
    end)
end
-- The microphone has no row of its own any more (the user did not want a banner for it, 2026-10-15): its state shows on the mic buttons.
on("mic_toggle", function() sys.call("audio.input_mute") end)
local last_vol, last_mute = nil, nil
sys.watch("audio", function(a)
    local vol = math.floor((a.volume or 0) * 100 + 0.5)
    local mute = a.muted and true or false
    local changed = last_vol ~= nil and (vol ~= last_vol or mute ~= last_mute)
    last_vol, last_mute = vol, mute
    if changed then show_level("v") end
end)
local last_bright = nil
sys.watch("brightness", function(b)
    if not b or not b.present then return end
    local lv = math.floor((b.level or 0) * 100 + 0.5)
    local changed = last_bright ~= nil and lv ~= last_bright
    last_bright = lv
    fact.bright_now = b.level or 0
    if changed and fact.panel ~= "controls" then show_level("b") end
end)
-- A brightness key says the new level itself, at once (hypr_vitreus.lua): the row follows the key, and the service's later look finds nothing new.
on("bright_key", function(f)
    if type(f) ~= "number" then return end
    fact.bright_now = math.max(0, math.min(1, f))
    last_bright = math.floor(fact.bright_now * 100 + 0.5)
    if fact.panel ~= "controls" then show_level("b") end
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
            local crit = tostring(n.urgency) == "critical" or tostring(n.urgency) == "2"
            if (nt_first or os.time() - nt_boot < 10) and not crit then
                pcall(sys.call, "notifications.dismiss", n.id)   -- already there at login (or replayed just after): not announced, and gone for good; only a critical one (the update notice) survives it
            else
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
    nt_queue.set_osd("none")   -- the cross always closes, even when the logic no longer knows what is on screen
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
local iris_cfg = { enabled = true, intensity = "bold" }       -- how far the wallpaper's accent is pushed: always Bold (the Theme page no longer offers a choice)
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

-- The desktop clock takes the palette as facts too (a file import made it reload the scene on every theme change, a few seconds): one `--say` with all of them.
function iris_fx.push_pal(pal)
    pal = pal or iris_fx.last_pal or iris_fx.saved
    if not pal then return end
    local facts = {}
    for _, k in ipairs(iris_fx.order) do
        local r, g, b = hex_to_rgb(pal[k])
        facts[#facts + 1] = string.format("fact pal_%s_r %.4f", k, r)
        facts[#facts + 1] = string.format("fact pal_%s_g %.4f", k, g)
        facts[#facts + 1] = string.format("fact pal_%s_b %.4f", k, b)
    end
    -- (the desktop editor, desktopedit/, reads them the same way)
    local scenes = { "desktopclock", "desktopedit", "desktopcards" }
    for _, sk in ipairs(addon_scenes or {}) do scenes[#scenes + 1] = sk end
    for _, scene in ipairs(scenes) do
        local args = { "--say", scene }
        for _, f in ipairs(facts) do args[#args + 1] = f end
        run("pleamar", args, function() end)
    end
end

-- The room the bar's frame takes round the screen (a framed bar: 76 px on its side, 24 on the others, which is what the windows keep out of; the Island on top: 56 px
-- along the top), told to the desktop scenes so that the grid their widgets sit on starts inside it and nothing can be put under the bar.
iris_fx.rooms = {
    left = { 24, 24, 24, 76 }, right = { 24, 76, 24, 24 }, top = { 76, 24, 24, 24 }, bottom = { 24, 24, 76, 24 },   -- top, right, bottom, left
    seg = { 59, 24, 24, 24 },                                                                                         -- the top frame in pieces: thin, with room at the top for the pieces only
}
function iris_fx.push_room()
    local r = { 0, 0, 0, 0 }
    if fact.bar_frame == true then r = iris_fx.rooms[(fact.bar_seg == true) and "seg" or fact.bar_anchor] or r
    elseif fact.bar_anchor == "top" then r = { 56, 0, 0, 0 } end
    local scenes = { "desktopclock", "desktopsysmon", "desktopcards", "desktopedit" }
    for _, sk in ipairs(addon_scenes or {}) do scenes[#scenes + 1] = sk end
    for _, scene in ipairs(scenes) do
        run("pleamar", { "--say", scene, "fact room_t " .. r[1], "fact room_r " .. r[2], "fact room_b " .. r[3], "fact room_l " .. r[4] }, function() end)
    end
end
on("fact:bar_anchor", function() iris_fx.push_room() end)
on("fact:bar_frame", function() iris_fx.push_room() end)
on("fact:bar_seg", function() iris_fx.push_room() end)

on("pal_push", function() iris_fx.push_pal(); iris_fx.push_room() end)

function iris_fx.apply_palette(pal)
    iris_fx.last_pal = pal
    local order = iris_fx.order
    local tr, tg, tb = hex_to_rgb(pal.tint)
    local wink = (0.2126 * tr + 0.7152 * tg + 0.0722 * tb) > 0.45 and "#f7f4fb" or pal.ink
    local lines = {
        "//  Written by Vitreus's logic from the wallpaper (Iris); edits here are overwritten.",
        "//  `let`s only: the lock screen imports this. (The shell's own scene takes its colours as facts: palette-live.plm.)",
        "",
        "library Palette {",
    }
    for _, k in ipairs(order) do lines[#lines + 1] = string.format("    let %-7s= %s", k, pal[k]) end
    lines[#lines + 1] = string.format("    let %-7s= %s", "wink", wink)
    -- (`wink`: the writing the desktop widgets put straight on the wallpaper, the system monitor's: the palette's ink, unless that palette is a light one
    -- (Retro, UwU), whose ink is dark and would be lost on a wallpaper: then a near-white, which the widgets' own shadow lifts.)
    lines[#lines + 1] = "}"
    local text_out = table.concat(lines, "\n") .. "\n"
    if text_out == iris_last_text then return end
    iris_last_text = text_out
    iris_fx.set_facts(pal)
    iris_fx.push_pal(pal)
    local same_as_saved = iris_fx.saved ~= nil
    if same_as_saved then
        for _, k in ipairs(order) do if iris_fx.saved[k] ~= pal[k] then same_as_saved = false end end
        if iris_fx.saved.wink ~= wink then same_as_saved = false end
    end
    if same_as_saved then iris_fx.apply_hypr(); return end
    local keep = {}
    for _, k in ipairs(order) do keep[k] = pal[k] end
    keep.wink = wink
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
-- Which docks are out (set by logic/dock.luau and logic/addons.luau): the windows keep clear of them (`wm_frame_sync`).
dock_fx = { c = false, a = false, nc = 0, na = 0, enabled = true }     -- `enabled`: Settings > Bar > "Corner docks overlap windows" (off)
-- The corner dock and the add-on pill stand over the windows' area, against the edge opposite the bar (the bottom for the Island and the top frame, the top for the
-- bottom frame; down a side strip it is the far edge, the right one for the strip on the left and the left one for the strip on the right, where each pill stands upright in the top
-- or the bottom corner and reaches in as far as it is thick). While one is out, that edge keeps the room for it: how far from the screen's edge the windows start, in pixels:
-- the frame's 8 * u, the pill (`cdk.t`, 34 * bu high, or `cdk.L`, 30 * bu for each icon and 8 * bu, wide; bu being 1.35 at the bar's size) and a few pixels.
-- `nc`, `na`: how many icons the dock and the add-on pill hold while they are out (0 when not). `room()` is `{ top = n, right = n, bottom = n, left = n }` for the edges that need it.
function dock_fx.room()
    local r = {}
    local c, a = dock_fx.c, dock_fx.a
    if not dock_fx.enabled or not (c or a) then return r end
    local anchor = fact.bar_anchor
    local bu = 1.35 * (bar_fx and bar_fx.size or 1)
    if anchor == "left" or anchor == "right" then
        r[anchor == "left" and "right" or "left"] = math.floor(1.35 * 8 + 34 * bu + 13 + 0.5)       -- (the pills stand upright down a side strip: as thick as along the top)
    else
        r[anchor == "bottom" and "top" or "bottom"] = math.floor(1.35 * 8 + 34 * bu + 13 + 0.5)
    end
    return r
end
-- Raises the gaps `g` ({ top, right, bottom, left }) where a dock needs the room. Not for the gaps as they were (`left == false`), and not for what is written to Hyprland's file.
function dock_fx.raise(g)
    local r = dock_fx.room()
    local out = { g[1], g[2], g[3], g[4] }
    if r.top then out[1] = math.max(out[1], r.top) end
    if r.right then out[2] = math.max(out[2], r.right) end
    if r.bottom then out[3] = math.max(out[3], r.bottom) end
    if r.left then out[4] = math.max(out[4], r.left) end
    return out
end
function dock_fx.on() local r = dock_fx.room(); return r.top ~= nil or r.right ~= nil or r.bottom ~= nil or r.left ~= nil end
function dock_fx.changed()
    if iris_fx and iris_fx.apply_hypr then iris_fx.apply_hypr() end
    if wm_frame_sync then wm_frame_sync() end
end
bar_fx = { left = false, edge = "top", orig = nil, on = "all", mons = {}, thin = false, size = 1 }   -- `left`: a strip and a frame are in use, on `edge` (left, right, top or bottom)
bar_fx.restart = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
pkill -f "^pleamar --scene .*/vitreus/desktop"  # the desktop widgets restart with the shell (their keepers start them again)
sleep 0.3
[ "$(stat -c %s "$L" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$L" "$L.1"
# under its keeper when there is one (bin/vitreus-keep): a keeper already looking after it starts it again itself
command -v vitreus-keep >/dev/null 2>&1 && exec vitreus-keep "$P" "$L"
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]
-- The room round the windows is per monitor: only a monitor the bar is on gets the strip's and the frame's room. `bar_fx.mons` is what is plugged in
-- and `bar_fx.on` where the bar is ("all", or a monitor's name); the Bar page below keeps both. A rule for each monitor (`m[NAME]`) says what its
-- own gaps are, and the global gaps are what a monitor without a rule gets, so a monitor plugged in later does not borrow the bar's room.
-- `left` says where the bar is for this code (false: the gaps as they were before us); left out, it is where the bar is now.
function iris_fx.island_min() return (bar_fx.size or 1) < 0.995 and not bar_fx.left and bar_fx.edge == "top" end   -- the Island below 100 %: no reserved strip (a reserve is a plain number)
function iris_fx.island_room() return math.floor(8 + 1.35 * 40 * (bar_fx.size or 1) + 0.5) end                  -- what it keeps above the windows instead: 8 and the bar (62 at 100 %): the window gap does the rest
function iris_fx.gaps_code(left, nodock)
    local isl = left == nil and iris_fx.island_min()     -- (asked for the gaps as they were: `left` false, then none of this)
    local docked = left == nil and not nodock and dock_fx.on()      -- (`left` false asks for the gaps as they were, and `nodock` for what Hyprland keeps in its file: with no docks)
    if left == nil then left = bar_fx.left or isl end
    local o = bar_fx.orig
    if not left and not o then return nil end
    o = o or { 20, 20, 20, 20 }
    local px = math.floor(1.35 * 8 + 0.5) + 13            -- the frame's thickness (8 * u) and a gap
    local bz = bar_fx.size or 1                           -- Settings > Bar > Size: the bar's size, 0.7 to 1 (`bz` in vitreus.plm)
    local lp = math.floor(1.35 * 46 * bz + 0.5) + 14
    local function cfg(g)
        return string.format("hl.config({ general = { gaps_out = { top = %d, right = %d, bottom = %d, left = %d } } })", g[1], g[2], g[3], g[4])
    end
    local function rule(name, g)
        return string.format('hl.workspace_rule({ workspace = "m[%s]", gaps_out = { top = %d, right = %d, bottom = %d, left = %d } })', name, g[1], g[2], g[3], g[4])
    end
    local WIDE = { top = { lp, px, px, px }, right = { px, lp, px, px }, bottom = { px, px, lp, px }, left = { px, px, px, lp } }   -- top, right, bottom, left: the wide one is the strip's
    local bar_gaps = WIDE[bar_fx.edge] or WIDE.left
    if bar_fx.seg then bar_gaps = { math.floor(1.35 * 36 * bz + 0.5) + 10, px, px, px } end       -- the top frame in pieces: thin, but the windows start below the pieces (36 * u) and a gap
    if isl then bar_gaps = { o[1] + iris_fx.island_room(), o[2], o[3], o[4] } end
    local everywhere = (bar_fx.on or "all") == "all"      -- the bar is on every monitor there is
    local base = (left and everywhere) and bar_gaps or o
    if docked and everywhere then base = dock_fx.raise(base) end
    local parts = { cfg(base) }
    for _, name in ipairs(bar_fx.mons or {}) do
        if name:match("^[%w%._%-]+$") then
            local has_bar = left and (everywhere or (bar_fx.sel ~= nil and bar_fx.sel[name] == true))
            -- a monitor with only the frame (Settings > Bar, "Frame on the other monitors"; logic/bar_monitors.luau) gets the frame's room on every side
            local g = has_bar and bar_gaps or ((left and bar_fx.thin and not isl) and { px, px, px, px } or o)
            -- the docks are on the monitors the bar is on, framed or not
            if docked and (everywhere or (bar_fx.sel ~= nil and bar_fx.sel[name] == true)) then g = dock_fx.raise(g) end
            parts[#parts + 1] = rule(name, g)
        end
    end
    return table.concat(parts, " ")
end
-- niri: the same room round the windows, as `struts` in a KDL file of its own (niri reloads its config when a file it includes changes), and the palette's accent as
-- the focus ring. The user's config.kdl has `include "vitreus.kdl"` at the end (the installer adds it). A strut is what the windows keep clear of on top of niri's own
-- `gaps` (read from the config; 16 is niri's default), so it is the room Hyprland would be given, less that gap. Each monitor the bar is on gets its own `output` block.
-- Settings > niri (below): what the page has changed, kept in niri-set.json. A key that is nil is niri's own (config.kdl's), so nothing is written for it.
niri_set = { gaps = nil, round = nil, border = nil, sens = nil, follow = nil, nat = nil, anim = nil, center = nil, colw = nil, single = nil }
-- It is read when first needed, not when this file is loaded: at that moment the data folder is not there to read yet, and vitreus.kdl was written without the page's values.
niri_set_loaded = false
function iris_fx.niri_load()
    if niri_set_loaded then return end
    local ok, saved = pcall(sys.ask, "files.read", "niri-set.json", "json")
    if ok and type(saved) == "table" then
        niri_set_loaded = true
        for _, k in ipairs({ "gaps", "round", "border", "sens", "follow", "nat", "anim", "center", "colw", "single" }) do      -- (a table of nil keys has none to walk with pairs)
            if saved[k] ~= nil then niri_set[k] = saved[k] end
        end
    end
end
function iris_fx.niri_set_code()
    iris_fx.niri_load()
    local n = niri_set
    local lay, rule, inp, extra = {}, {}, {}, {}
    if n.gaps then lay[#lay + 1] = string.format("gaps %d", n.gaps) end
    if n.center ~= nil then lay[#lay + 1] = string.format('center-focused-column "%s"', ({ [0] = "never", "always", "on-overflow" })[n.center] or "never") end
    -- (a flag can be turned on here, not off again: a config.kdl that has it keeps it)
    if n.single then lay[#lay + 1] = "always-center-single-column" end
    if n.colw ~= nil then lay[#lay + 1] = string.format("default-column-width { proportion %s; }", ({ [0] = "0.33333", "0.5", "0.66667", "1.0" })[n.colw] or "0.5") end
    if n.round then rule[#rule + 1] = string.format("geometry-corner-radius %d\n    clip-to-geometry true", n.round) end
    if n.anim == false then extra[#extra + 1] = "animations {\n    off\n}" end
    if n.follow and n.follow > 0 then inp[#inp + 1] = "focus-follows-mouse" end
    local dev = {}
    if n.nat then dev[#dev + 1] = "natural-scroll" end
    if n.sens and n.sens ~= 0 then dev[#dev + 1] = string.format("accel-speed %.2f", n.sens) end
    return lay, rule, inp, dev, extra
end
function iris_fx.niri_code(gap)
    local px = math.floor(1.35 * 8 + 0.5) + 13
    local bz = bar_fx.size or 1
    local lp = math.floor(1.35 * 46 * bz + 0.5) + 14
    local WIDE = { top = { lp, px, px, px }, right = { px, lp, px, px }, bottom = { px, px, lp, px }, left = { px, px, px, lp } }
    local bar_gaps = WIDE[bar_fx.edge] or WIDE.left
    if bar_fx.seg then bar_gaps = { math.floor(1.35 * 36 * bz + 0.5) + 10, px, px, px } end
    local isl = iris_fx.island_min()
    local everywhere = (bar_fx.on or "all") == "all"
    local function struts(g)
        local t = {}
        for i = 1, 4 do t[i] = math.max(0, math.floor(g[i] - gap + 0.5)) end
        return string.format("struts {\n            top %d\n            right %d\n            bottom %d\n            left %d\n        }", t[1], t[2], t[3], t[4])
    end
    local function room(has_bar)
        local g
        if has_bar then
            g = bar_fx.left and bar_gaps or { isl and iris_fx.island_room() or 0, 0, 0, 0 }
            g = dock_fx.raise(g)
        else
            g = (bar_fx.left and bar_fx.thin) and { px, px, px, px } or { 0, 0, 0, 0 }
        end
        return g
    end
    local parts = { "// Written by Vitreus (the room round the windows, and the focus ring from the palette); edits here are overwritten.\n// config.kdl includes it: include \"vitreus.kdl\"\n" }
    local pal = iris_fx.last_pal
    local ring_in = {}
    if niri_set.border == 0 then ring_in[1] = "off"
    else
        if niri_set.border then ring_in[#ring_in + 1] = string.format("width %d", niri_set.border) end
        if pal then
            ring_in[#ring_in + 1] = string.format('active-color "%s"', pal.mint)
            ring_in[#ring_in + 1] = string.format('inactive-color "%s"', pal.off)
        end
    end
    local ring = #ring_in > 0 and ("\n        focus-ring {\n            " .. table.concat(ring_in, "\n            ") .. "\n        }") or ""
    local lay, rule, inp, dev, extra = iris_fx.niri_set_code()
    local lay_txt = ""
    for _, l in ipairs(lay) do lay_txt = lay_txt .. "\n        " .. l end
    parts[#parts + 1] = "layout {" .. lay_txt .. ring .. "\n        " .. struts(room(everywhere)) .. "\n}\n"
    -- A window that opens maximized to the edges (Chrome asks for it) is laid over the whole monitor, struts and all: so nothing opens that way.
    parts[#parts + 1] = "window-rule {\n    open-maximized-to-edges false" .. (#rule > 0 and ("\n    " .. table.concat(rule, "\n    ")) or "") .. "\n}\n"
    for _, e in ipairs(extra) do parts[#parts + 1] = e .. "\n" end
    if #inp > 0 or #dev > 0 then
        local t = "input {"
        for _, l in ipairs(inp) do t = t .. "\n    " .. l end
        if #dev > 0 then
            t = t .. "\n    touchpad {\n        " .. table.concat(dev, "\n        ") .. "\n    }"
            local m = {}
            for _, l in ipairs(dev) do if l:match("^accel") then m[#m + 1] = l end end
            if #m > 0 then t = t .. "\n    mouse {\n        " .. table.concat(m, "\n        ") .. "\n    }" end
        end
        parts[#parts + 1] = t .. "\n}\n"
    end
    -- What Settings > Display kept for each monitor (display.json, `saved`: mode, scale, transform, position), in niri's words.
    local TRANSFORM = { [0] = "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }
    local disp = {}
    local okd, fd = pcall(sys.ask, "files.read", "display.json", "json")
    if okd and type(fd) == "table" and type(fd.saved) == "table" then disp = fd.saved end
    local names, seen, is_mon = {}, {}, {}
    for _, name in ipairs(bar_fx.mons or {}) do is_mon[name] = true; if not seen[name] then seen[name] = true; names[#names + 1] = name end end
    local extra = {}
    for name in pairs(disp) do if not seen[name] then seen[name] = true; extra[#extra + 1] = name end end
    table.sort(extra)
    for _, name in ipairs(extra) do names[#names + 1] = name end
    for _, name in ipairs(names) do
        if name:match("^[%w%._%-]+$") then
            local lines = {}
            local d = disp[name]
            if type(d) == "table" and d.res and d.hz then lines[#lines + 1] = string.format('    mode "%s@%d.000"', d.res, d.hz) end
            if type(d) == "table" and type(d.scale) == "number" then lines[#lines + 1] = string.format("    scale %s", (string.format("%.6f", d.scale):gsub("0+$", ""):gsub("%.$", ""))) end
            if type(d) == "table" and TRANSFORM[d.transform or 0] then lines[#lines + 1] = string.format('    transform "%s"', TRANSFORM[d.transform or 0]) end
            if type(d) == "table" and d.x and d.y then lines[#lines + 1] = string.format("    position x=%d y=%d", d.x, d.y) end
            local has_bar = everywhere or (bar_fx.sel ~= nil and bar_fx.sel[name] == true)
            if not everywhere and is_mon[name] then
                lines[#lines + 1] = string.format("    layout {\n        %s\n    }", struts(room(has_bar)))
            end
            if #lines > 0 then parts[#parts + 1] = string.format('output "%s" {\n%s\n}\n', name, table.concat(lines, "\n")) end
        end
    end
    return table.concat(parts, "")
end
function iris_fx.apply_niri()
    with_dirs(function(d)
        local cfg = d.conf:gsub("/pleamar/shells/vitreus$", "/niri")
        run("grep", { "-m1", "-E", "^[[:space:]]*gaps[[:space:]]+[0-9.]+", cfg .. "/config.kdl" }, function(out)
            iris_fx.niri_load()
            local gap = niri_set.gaps or tonumber((out or ""):match("gaps%s+([%d%.]+)")) or 16
            local code = iris_fx.niri_code(gap)
            pcall(sys.call, "files.write", "vitreus.kdl", code)
            run("mkdir", { "-p", cfg }, function()
                -- Copied whole then renamed over (cp truncates first: niri can read the half-written file and miss the rewrite), then niri is told to read it again.
                run("cp", { "-f", d.data .. "/vitreus.kdl", cfg .. "/vitreus.kdl.tmp" }, function()
                    run("mv", { "-f", cfg .. "/vitreus.kdl.tmp", cfg .. "/vitreus.kdl" }, function()
                        run("niri", { "msg", "action", "load-config-file" }, function() end)
                    end)
                end)
            end)
        end)
    end)
end
function iris_fx.apply_hypr()
    if on_niri then return iris_fx.apply_niri() end
    local pal = iris_fx.last_pal
    local parts, keep = {}, {}
    if pal then local c = iris_fx.border_code(pal); parts[#parts + 1] = c; keep[#keep + 1] = c end
    local g = iris_fx.gaps_code()
    if g then parts[#parts + 1] = g; if bar_fx.left or iris_fx.island_min() then keep[#keep + 1] = iris_fx.gaps_code(nil, true) end end
    -- The gaps are Hyprland's settings, so they outlive the shell (a layer's reserved zone does not). gaps-undo.lua says how to give
    -- them back, and bin/vitreus-keep sends it when it stops for good; empty with the bar on the top, where there is nothing to undo.
    pcall(sys.call, "files.write", "gaps-undo.lua", (bar_fx.left or iris_fx.island_min() or dock_fx.on()) and (iris_fx.gaps_code(false) or "") or "")
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
local function iris_palette(json, raw)       -- `raw`: a named palette, whose accent is not pushed by the intensity
    local surface = json_hex(json, "surface") or "#1e202b"
    local bg = json_hex(json, "bg") or "#12131a"
    local glass = blend(surface, "#ffffff", 0.12)
    local accent = json_hex(json, "accent") or "#94a3b8"
    if not raw then accent = intensity_accent(accent, iris_cfg.intensity) end
    accent = ensure_contrast(accent, glass, 4.5, 1)
    local fg = ensure_contrast(json_hex(json, "fg") or "#e6e6e6", glass, 4.5, 1)
    local dim = ensure_contrast(json_hex(json, "dim") or "#a0a4ab", glass, 4.5, 1)
    local red = ensure_contrast(json_hex(json, "red") or "#ef4444", glass, 3.0, 1)
    return iris_fx.build_palette(bg, surface, fg, dim, accent, red)
end
local function apply_iris(json, raw) iris_fx.apply_palette(iris_palette(json, raw)) end

-- The wallpaper's colours as Iris reads them, kept apart from the palette in use: the first card of Settings > Theme shows these whichever
-- theme is chosen (so it does not follow a named palette, or the greys). Five of the palette's colours, as facts, and in iris-card.json so
-- that a start has them from its first frame.
local CARD_KEYS = { "tint", "panel", "ink", "mint", "alert" }
local function set_card(pal)
    for _, k in ipairs(CARD_KEYS) do
        local r, g, b = hex_to_rgb(pal[k])
        fact["wcol_" .. k .. "_r"], fact["wcol_" .. k .. "_g"], fact["wcol_" .. k .. "_b"] = r, g, b
    end
end
do
    local ok, saved = pcall(sys.ask, "files.read", "iris-card.json", "json")
    if ok and type(saved) == "table" then
        local whole = true
        for _, k in ipairs(CARD_KEYS) do
            if type(saved[k]) ~= "string" or not saved[k]:match("^#%x%x%x%x%x%x$") then whole = false end
        end
        if whole then set_card(saved) end
    end
end

-- With Iris off the shell is monochrome: neutral greys, and no hue anywhere but the red of an alert (a low battery, a failed
-- action), which has to stay something you notice.
function iris_fx.apply_mono()
    iris_fx.apply_palette(iris_fx.build_palette("#161616", "#232323", "#ececec", "#9c9c9c", "#d6d6d6", "#ef4444"))
end

local function run_iris(path, card_only)
    -- Dark, and for glass (`--glass` adjusts the background for transparency): see apply_iris. `card_only`: only the Theme card's colours
    -- are updated, the shell keeps the palette it has (a named one, or the greys).
    run("iris", { "--json-only", "--dark", "1", "--glass", path }, function(out, code)
        if code ~= 0 or not out then return end
        local json = out:match("%b{}")
        if json and json_hex(json, "bg") then
            local pal = iris_palette(json)
            set_card(pal)
            local keep = {}
            for _, k in ipairs(CARD_KEYS) do keep[k] = pal[k] end
            pcall(sys.call, "files.write", "iris-card.json", keep)
            if not card_only then iris_fx.apply_palette(pal) end
        end
    end)
end

-- ── Video wallpapers ─────────────────────────────────────────────────────────────────────────────────
-- A video (mp4, webm, mov) is played by mpvpaper, over awww's wallpaper. awww is given a frame of the video (the poster, taken a second in
-- by ffmpeg and kept in the cache) so that everything which reads "the wallpaper" as a picture still can: Iris, the thumbnails, the colour
-- filter, the hexagon dissolve and the lock screen. What awww says it shows is then mapped back to the video (`wpv.from_poster`).
wpv = { exts = { mp4 = true, webm = true, mov = true }, frames = nil, dir = nil, cur = nil, next = nil, busy = {} }   -- `dir`: the wallpaper folder

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

-- The wallpaper hook (logic/wallpaper_hook.luau): `rec` is the picture an add-on made for the screen and the wallpaper it was made from, read here at
-- once, so the first look at awww (below) knows that picture is that wallpaper (else Iris would read the frame, and the page would show it as the
-- wallpaper). `busy`: an add-on is making one, and awww still shows the old wallpaper, which is not a change from outside. A global: this chunk is at Luau's limit of locals.
wph = { busy = false, rec = nil, frame = nil }
do
    local ok, r = pcall(sys.ask, "files.read", "wallpaper-frame.json", "json")
    if ok and type(r) == "table" and type(r.out) == "string" and type(r.src) == "string" then wph.rec = r end
end
function wph.src_of(p)
    local r = wph.rec
    if p and r and r.out == p then return r.src end
    return nil
end
-- The wallpaper is asked of awww every half second; when it changes, Iris is run on the new one.
local wp_on_change = function(path) end       -- the wallpaper page, further down, takes this over
-- A wallpaper that the hexagon dissolve is bringing in: awww is told about it only when the dissolve is over, a couple of seconds on, and
-- until then it still says the old one. Taking that for a change made from outside would run Iris on the old wallpaper again (the colours
-- went back, and then, when awww caught up, forward again). So what awww says is not believed until it says this, or the time is up.
local wp_pending, wp_pending_until = nil, 0
-- The wallpaper picker's cards change the wallpaper while they are shifted through; the colours are only worked out once one is kept. Until then what
-- awww shows is not a change made from outside (a global: this chunk is at Luau's limit of locals).
wp_prev = { on = false, touched = false, cancel = false, orig = nil, shown = nil }
-- The glass bends a copy of the wallpaper instead of a capture of the screen (the scene's `lens = image`, in vitreus.plm): half
-- the screen's size is plenty under the frosting. Pleamar looks at the file twice a second and reads it again when it changes (a half-written one fails to decode and is tried again). Called wherever the wallpaper changes
-- (the watcher below, and `wp_apply`, which marks the change as seen so the watcher never notices it). A global: this chunk is at Luau's limit of locals.
function lens_image(path)
    if not path then return end
    run("printenv", { "HOME" }, function(h)
        h = (h or ""):gsub("%s+$", "")
        if h == "" then return end
        run("magick", { path .. "[0]", "-auto-orient", "-resize", "960x540^", "-gravity", "center", "-extent", "960x540", "PNG:" .. h .. "/.cache/pleamar/vitreus/lens.png" }, function() end)
    end)
end
local function check_wallpaper()
    run("awww", { "query" }, function(out, code)
        if code ~= 0 or not out then return end
        if wp_prev.on then return end
        if wph.busy then return end          -- an add-on is making the picture: awww shows the old one, which is not a change from outside
        local path = out:match("currently displaying: image: ([^\n]+)")
        if wp_pending then
            if path == wp_pending then wp_pending = nil
            elseif os.time() < wp_pending_until then return
            else wp_pending = nil end
            wpv.flush()                      -- the dissolve is over: the video that goes with it starts (or the old one stops)
        end
        -- awww shows a video's poster; the wallpaper is the video. One that is playing while awww shows something else was replaced
        -- from outside.
        local framed = wph.src_of(path)      -- a picture an add-on made: the wallpaper is the one it was made from
        local shown = wpv.from_poster(path) or framed or path
        if path and wpv.cur and shown ~= wpv.cur and not wpv.next then
            wpv.cur = nil
            wpv_save()
            exec_on_desktop("pkill -x mpvpaper")
        end
        if path and shown ~= iris_last_wp then
            iris_last_wp = shown
            lens_image(path)
            wp_on_change(shown)
            run_iris(framed or path, not (iris_cfg.enabled and not iris_cfg.preset))
        end
    end)
end

-- Settings > Theme has themes, each a file in themes/ (Vitreus's own) or in ~/.config/pleamar/vitreus-themes/ (a person's; themes/_template.toml is the
-- model to copy). bin/vitreus-themes reads them and leaves `themes.json` here; this is that list. A theme wears one of four shapes (`look`: Glass nil,
-- Retro 8, UwU 9, Cyber 10, the numbers iris.json has always used) and has a palette of its own, or none (Glass takes the wallpaper's: Iris).
-- Picking one takes its palette (`iris_cfg.preset` is its look, or 100 for a person's theme on the Glass shape). The palette can then be changed to the
-- wallpaper's (Iris, `preset` nil) without leaving the theme. Everything that follows the palette follows it: the shell, the lock screen, pleamar-wm's
-- border, Hyprland's borders. `iris_cfg.theme` is the theme's id (nil: Glass); its font, window corners and fonts.json entry are all keyed by it.
iris_fx.CASSETTE = 8
iris_fx.UWU = 9
iris_fx.CYBER = 10
iris_fx.MILK = 11
iris_fx.PROXY = 12
iris_fx.PAPER = 13
iris_fx.CUSTOM = 100
vtheme = { list = {}, by_id = {}, errors = {}, folder = "" }
vtheme.look_id = { [8] = "retro", [9] = "uwu", [10] = "cyber", [11] = "milk", [12] = "proxy", [13] = "paper" }
function vtheme.load()
    local ok, f = pcall(sys.ask, "files.read", "themes.json", "json")
    if not ok or type(f) ~= "table" or type(f.themes) ~= "table" then return false end
    local list, by_id = {}, {}
    for _, t in ipairs(f.themes) do
        if type(t) == "table" and type(t.id) == "string" and type(t.name) == "string" and not by_id[t.id] then
            list[#list + 1] = t
            by_id[t.id] = t
        end
    end
    if #list == 0 then return false end
    vtheme.list, vtheme.by_id = list, by_id
    vtheme.loaded = true
    vtheme.errors = type(f.errors) == "table" and f.errors or {}
    vtheme.folder = type(f.folder) == "string" and f.folder or ""
    return true
end
-- Without themes.json (the keeper makes it before the shell starts; a shell started by hand, or one just updated, may not have it yet) there is Glass, the
-- helper is asked, and the theme that was in use is trusted until the list is there: `current()` stands in for it, so nothing is reset meanwhile.
vtheme.loaded = false
if not vtheme.load() then
    vtheme.list = { { id = "glass", name = "Glass", tagline = "Wallpaper", base = "glass", font = "Space Grotesk", round = 22, builtin = true } }
    vtheme.by_id = { glass = vtheme.list[1] }
end
function vtheme.of_look(look) return vtheme.look_id[look] or "glass" end
function vtheme.current()
    local id = iris_cfg.theme or "glass"
    return vtheme.by_id[id] or (not vtheme.loaded and { id = id, name = id, tagline = "", base = "glass" }) or vtheme.list[1]
end
function vtheme.index(t) for k, v in ipairs(vtheme.list) do if v == t then return k end end return 1 end
function vtheme.font_of(id) local t = vtheme.by_id[id]; return t and t.font or "Space Grotesk" end
function vtheme.round_of(id) local t = vtheme.by_id[id]; return t and t.round end
do
    local ok, saved = pcall(sys.ask, "files.read", "iris.json", "json")
    if ok and type(saved) == "table" then
        if saved.enabled ~= nil then iris_cfg.enabled = saved.enabled and true or false end
        local pr = tonumber(saved.preset)
        if pr and (math.floor(pr) == iris_fx.CASSETTE or math.floor(pr) == iris_fx.UWU or math.floor(pr) == iris_fx.CYBER or math.floor(pr) == iris_fx.MILK or math.floor(pr) == iris_fx.PROXY or math.floor(pr) == iris_fx.PAPER or math.floor(pr) == iris_fx.CUSTOM) then iris_cfg.preset = math.floor(pr) end
        -- The look (the shape of the shell) is its own setting, apart from where the colours come from: Iris may colour a Retro or UwU shell and it stays one.
        local lk = tonumber(saved.look)
        if lk and (math.floor(lk) == iris_fx.CASSETTE or math.floor(lk) == iris_fx.UWU or math.floor(lk) == iris_fx.CYBER or math.floor(lk) == iris_fx.MILK or math.floor(lk) == iris_fx.PROXY or math.floor(lk) == iris_fx.PAPER) then iris_cfg.look = math.floor(lk)
        elseif lk == nil then iris_cfg.look = iris_cfg.preset ~= iris_fx.CUSTOM and iris_cfg.preset or nil end      -- an older file: the look was the palette
        -- The theme itself. An older file has only the look, which names one of Vitreus's own; a theme whose file has gone leaves Glass.
        if type(saved.theme) == "string" then iris_cfg.theme = saved.theme
        elseif iris_cfg.look then iris_cfg.theme = vtheme.of_look(iris_cfg.look) end
        if vtheme.loaded and iris_cfg.theme and not vtheme.by_id[iris_cfg.theme] then iris_cfg.theme, iris_cfg.look, iris_cfg.preset = nil, nil, nil end
    else
        pcall(sys.call, "files.write", "iris.json", iris_cfg)     -- so there is a file to edit
    end
end
hy_theme_changed = nil            -- set by Settings > Hyprland (below): the window corners follow the theme
do
    local INTENSITIES = { "subtle", "medium", "bold" }
    -- The desktop clock and system monitor draw themselves as plastic with Retro and UwU: they are told the theme (0 Glass, 1 Retro, 2 UwU).
    local function push_look()
        local v = iris_cfg.look == iris_fx.CASSETTE and 1 or iris_cfg.look == iris_fx.UWU and 2 or iris_cfg.look == iris_fx.CYBER and 3 or iris_cfg.look == iris_fx.MILK and 4 or iris_cfg.look == iris_fx.PROXY and 3 or iris_cfg.look == iris_fx.PAPER and 4 or 0
        local av = iris_cfg.look == iris_fx.PROXY and 5 or iris_cfg.look == iris_fx.PAPER and 4 or v             -- add-ons know Proxy as 5 (the desktop widgets below still take it as Cyber's 3)
        addon_look = av
        run("pleamar", { "--say", "desktopclock", "fact look " .. v }, function() end)
        run("pleamar", { "--say", "desktopsysmon", "fact look " .. v }, function() end)
        run("pleamar", { "--say", "desktopcards", "fact look " .. v }, function() end)
        run("pleamar", { "--say", "desktopnotes", "fact look " .. v }, function() end)
        run("pleamar", { "--say", "files", "fact look " .. v }, function() end)
        run("pleamar", { "--say", "cursortrail", "fact look " .. v }, function() end)
        for _, sk in ipairs(addon_scenes or {}) do run("pleamar", { "--say", sk, "fact look " .. av }, function() end) end      -- the sparkle trail behind the mouse: UwU only
    end
    local function show()
        push_look()
        after(1200, push_look)         -- the palette file is rewritten with the theme and the desktop widgets reload: tell them again once they are back
        fact.iris_on = iris_cfg.enabled and not iris_cfg.preset
        fact.theme_sel = iris_cfg.theme and (vtheme.index(vtheme.current()) - 1) or (iris_cfg.enabled and 0 or -1)       -- the card's place on the Theme page (-1: Iris switched off on the Wallpaper page, greys)
        fact.cas = iris_cfg.look == iris_fx.CASSETTE
        fact.uwu = iris_cfg.look == iris_fx.UWU
        fact.cyber_on = iris_cfg.look == iris_fx.CYBER
        fact.milk = iris_cfg.look == iris_fx.MILK
        fact.proxy_on = iris_cfg.look == iris_fx.PROXY
        fact.paper_on = iris_cfg.look == iris_fx.PAPER
        if hy_theme_changed then hy_theme_changed(vtheme.current().id) end
        for k, name in ipairs(INTENSITIES) do if name == iris_cfg.intensity then fact.iris_int = k - 1 end end
    end
    local function save()
        pcall(sys.call, "files.write", "iris.json", { enabled = iris_cfg.enabled, intensity = iris_cfg.intensity, preset = iris_cfg.preset, look = iris_cfg.look, theme = iris_cfg.theme })
    end
    local function follow_wallpaper()
        if iris_last_wp then run_iris(iris_last_wp) else check_wallpaper() end
    end
    -- The cards of the Theme page: each theme's name, its small line and its five stripes (three numbers a colour: the model has no colour field).
    -- Glass is `live`: its stripes are the wallpaper's, which the scene already holds. A line under the cards says what is wrong with a file of the
    -- person's, or where to put one.
    local CARDS = 16
    local function fill_cards()
        local rows = {}
        for k, t in ipairs(vtheme.list) do
            if k > CARDS then break end
            local row = { name = t.name, tag = t.tagline or "", live = t.palette == nil }
            for j = 1, 5 do
                local r, g, b = hex_to_rgb(type(t.card) == "table" and t.card[j] or "#808080")
                row["c" .. (j - 1) .. "r"], row["c" .. (j - 1) .. "g"], row["c" .. (j - 1) .. "b"] = r, g, b
            end
            rows[#rows + 1] = row
        end
        model.themes = rows
        local errs = vtheme.errors
        if #errs > 0 then
            text.th_note = errs[1] .. (#errs > 1 and ("  (+" .. (#errs - 1) .. " more)") or "")
        elseif #vtheme.list > CARDS then
            text.th_note = "Only the first " .. CARDS .. " themes are shown"
        else
            text.th_note = "Your themes: ~/.config/pleamar/vitreus-themes"
        end
        fact.th_err = #errs > 0
    end
    -- The files are read again (a person's file may have been added or changed): the list, the cards and, if the theme in use was edited, its colours.
    local function refresh_themes()
        local folder = sys.ask("files.folder")
        if type(folder) ~= "string" then return end
        run("vitreus-themes", { folder }, function(_, code)
            local first = not vtheme.loaded
            if code ~= 0 or not vtheme.load() then return end
            if iris_cfg.theme and not vtheme.by_id[iris_cfg.theme] then iris_cfg.theme, iris_cfg.look, iris_cfg.preset = nil, nil, nil; save(); follow_wallpaper() end
            local cur = vtheme.current()
            if iris_cfg.preset and not cur.palette then iris_cfg.preset = nil; save(); follow_wallpaper()
            elseif iris_cfg.preset then iris_fx.apply_palette(cur.palette) end
            fill_cards()
            show()
            if fonts_refresh then fonts_refresh(first) end
        end)
    end
    on("themes_refresh", refresh_themes)
    if vtheme.loaded and iris_cfg.preset and not vtheme.current().palette then iris_cfg.preset = nil end      -- a theme that has lost its palette follows the wallpaper
    fill_cards()
    fact.th_first = math.max(0, math.min((iris_cfg.theme and vtheme.index(vtheme.current()) or 1) - 4, #vtheme.list - 4))       -- the strip opens with the theme in use in view
    after(500, refresh_themes)       -- a shell started by hand may have no themes.json yet
    show()
    if iris_cfg.preset and vtheme.current().palette then iris_fx.apply_palette(vtheme.current().palette)       -- (before the list is there, palette.json already has the colours)
    elseif not iris_cfg.enabled then iris_fx.apply_mono() end
    -- The switch on the Wallpaper page. Off: greys at once. On: Iris is run on the wallpaper in use, and the colours come back (a theme's own palette is
    -- let go too: the switch says Iris is off while one is in use, and turning it on is asking for the wallpaper's colours). The look stays: Retro or UwU
    -- with the wallpaper's colours is still Retro or UwU.
    on("iris_toggle", function()
        if iris_cfg.preset then
            iris_cfg.preset, iris_cfg.enabled = nil, true
        else
            iris_cfg.enabled = not iris_cfg.enabled
        end
        save()
        show()
        if iris_cfg.enabled then follow_wallpaper() else iris_fx.apply_mono() end
    end)
    -- Settings > Theme: a card is a theme, by its place in the list (0 is Glass, the wallpaper's colours).
    on("theme_pick", function(k)
        local t = vtheme.list[math.floor((tonumber(k) or 0) + 0.5) + 1]
        if not t then return end
        iris_cfg.theme = t.id ~= "glass" and t.id or nil
        iris_cfg.look = t.look
        iris_cfg.enabled = true
        if t.palette then
            iris_cfg.preset = t.look or iris_fx.CUSTOM
            iris_fx.apply_palette(t.palette)
        else
            iris_cfg.preset = nil
            follow_wallpaper()
        end
        save()
        show()
        -- A theme switch is live: nothing restarts. The typeface is the one thing a scene cannot change while it runs (its font names are fixed), so the
        -- font picker (below) says when the new theme's font is not the one in use and offers Apply, which is what starts the shell again.
        if fonts_refresh then fonts_refresh() end
    end)
    -- How strongly the wallpaper's accent is pushed (Subtle, Medium, Bold): it was only a line in iris.json.
    on("iris_int_set", function(k)
        local name = INTENSITIES[math.floor((tonumber(k) or 1) + 0.5) + 1]
        if not name then return end
        iris_cfg.intensity = name
        save()
        show()
        if iris_cfg.enabled and not iris_cfg.preset then follow_wallpaper() elseif iris_last_wp then run_iris(iris_last_wp, true) end
    end)
end
-- ── Settings > Theme: the font picker ─────────────────────────────────────────────────────────────────────
-- Each theme has a typeface: Space Grotesk on Glass, Audiowide on Retro, or whichever is picked here (`fonts.json`: { glass = name, retro = name }). A
-- scene's font names are fixed, so a different typeface is shown by starting the shell with a font setup (see bin/vitreus-fonts, which the keeper runs):
-- Apply saves the choice and stops the shell, and its keeper starts it again. The dropdown is a window of eight rows (`top`) over the list as the search
-- has narrowed it (`view`); a picture of the chosen typeface (ImageMagick, from its file) is the preview, since a scene can only draw in its own font.
-- The arrows move the choice with the dropdown open or shut, and typing opens it and searches.
do
    local ROWS = 8
    local saved = {}                       -- what the shell is drawn in; a theme with no entry has its default
    local all = { { label = "", value = nil } }       -- the theme's default first, then the installed families, sorted
    local view = all                       -- `all` narrowed by what is typed (the default only while nothing is)
    local query = ""
    local chosen = nil                     -- the family chosen on the page (nil: the theme's default)
    local inuse                            -- the family the running shell is drawn in (set once the choice is read; only a start changes it)
    local top = 0                          -- the first row shown
    local pv_n, pv_token = 0, 0
    local function theme() return vtheme.current().id end
    local function label() return vtheme.current().name end
    local function default_font() return vtheme.font_of(theme()) end
    local function index_of(v)
        for i, e in ipairs(view) do if e.value == v then return i end end
        return nil
    end
    local function rows()
        for i = 0, ROWS - 1 do
            local e = view[top + i + 1]
            fact["font_r." .. i .. ".on"] = e ~= nil
            fact["font_r." .. i .. ".lit"] = e ~= nil and e.value == chosen
            text["font_r." .. i .. ".text"] = e and e.label or ""
        end
        local n = #view
        fact.font_sb_h = math.min(1, ROWS / math.max(n, 1))
        fact.font_sb_y = n > ROWS and top / n or 0
        fact.font_none = n == 0
    end
    local function show()
        all[1].label = "Default · " .. default_font()
        text.font_for = "Font for " .. label()
        text.font_name = chosen or default_font()
        local same = (chosen or default_font()) == inuse
        if same then
            text.font_note = chosen and "In use" or ("The default for " .. label())
        else
            text.font_note = "Not applied yet"
        end
        fact.font_dirty = not same
        rows()
    end
    local function narrow()
        if query == "" then
            view = all
        else
            view = {}
            for i = 2, #all do
                if all[i].label:lower():find(query, 1, true) then view[#view + 1] = all[i] end
            end
        end
    end
    local function keep_in_view()
        local i = index_of(chosen)
        if not i then return end
        if i <= top then top = i - 1 elseif i > top + ROWS then top = i - ROWS end
        top = math.max(0, math.min(math.max(0, #view - ROWS), top))
    end
    -- (Both fc programs run without FONTCONFIG_FILE: the shell's own font setup makes "Space Grotesk" the typeface in use, which would answer for it.)
    -- The preview: the typeface's file (fc-match answers with the one the name stands for), drawn as three lines in the text colour.
    local function preview()
        local fam = chosen or default_font()
        local pat = ":family=" .. fam:gsub("[-:,=\\]", "\\%0")
        run("env", { "-u", "FONTCONFIG_FILE", "fc-match", pat, "-f", "%{file}" }, function(file, code)
            if code ~= 0 or not file or file == "" then return end
            local pal = iris_fx.last_pal or iris_fx.saved or {}
            with_dirs(function(d)
                pv_n = pv_n + 1
                local out = d.data .. "/font-preview.png"
                run("magick", { "-background", "none", "-fill", "#ffffff", "-font", file,
                    "-pointsize", "78", "label:Aa Bb Cc 0123", "-pointsize", "40", "label:The quick brown fox jumps over",
                    "-pointsize", "32", "label:Settings · 12:45 PM · Wi-Fi 78%",
                    "-gravity", "west", "-background", "none", "-append", "-gravity", "northwest", "-extent", "1420x440", out },
                    function(_, c2) if c2 == 0 then text.font_prevurl = out .. "?" .. pv_n end end)
            end)
        end)
    end
    -- Each key would start two programs, so the picture is made once the choosing stops.
    local function preview_soon()
        pv_token = pv_token + 1
        local mine = pv_token
        after(250, function() if mine == pv_token then preview() end end)
    end
    local ok, file = pcall(sys.ask, "files.read", "fonts.json", "json")
    if ok and type(file) == "table" then
        for id, family in pairs(file) do
            if type(id) == "string" and type(family) == "string" and family ~= "" then saved[id] = family end      -- by theme id: glass, retro, uwu, cyber, a person's
        end
    end
    chosen = saved[theme()]
    inuse = chosen or default_font()
    show()
    -- A theme was just picked: the picker shows that theme's font (and Apply, if it is not the one in use).
    function fonts_refresh(started_with_stub)
        chosen = saved[theme()]
        if started_with_stub then inuse = chosen or default_font() end      -- the list of themes came after the shell: the font it runs in is the theme's own
        if #all > 0 then
            narrow()
            keep_in_view()
        end
        show()
        preview()
    end
    local SKIP = { "symbol", "emoji", "icon", "awesome", "dingbat", "material", "webdings", "wingdings" }
    run("env", { "-u", "FONTCONFIG_FILE", "fc-list", ":", "family" }, function(out, code)
        if code ~= 0 or not out then return end
        local seen, names = {}, {}
        for line in out:gmatch("[^\n]+") do
            local name = line:match("^([^,:]+)")
            name = name and name:gsub("\\(.)", "%1"):gsub("^%s+", ""):gsub("%s+$", "")      -- fc-list escapes a hyphen: Ari\-W9500
            if name and name ~= "" and not seen[name] and name:sub(1, 1) ~= "." then
                local low, skip = name:lower(), false
                for _, w in ipairs(SKIP) do if low:find(w, 1, true) then skip = true end end
                if not skip then seen[name] = true; names[#names + 1] = name end
            end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        local first = all[1]
        all = { first }
        for _, n in ipairs(names) do all[#all + 1] = { label = n, value = n } end
        narrow()
        show()
        preview()
    end)
    on("font_open", function()                         -- the dropdown opens with the chosen one in view, and nothing searched for
        query = ""
        text.font_q = ""
        narrow()
        local i = index_of(chosen) or 1
        top = math.max(0, math.min(math.max(0, #view - ROWS), i - 3))
        rows()
    end)
    -- Closing it (by any way) clears the search, so the arrows go through the whole list again.
    -- (A moment later: a row pressed closes the dropdown in the same breath, and its pick must still see the list as the search left it.)
    local is_open = false
    on("fact:font_dd_open", function(open)
        is_open = open and true or false
        if open then return end
        after(120, function()
            if is_open then return end
            if query ~= "" or text.font_q ~= "" then
                query = ""
                text.font_q = ""
                narrow()
                keep_in_view()
                rows()
            end
        end)
    end)
    -- A letter typed with the dropdown shut: it opens with that letter searched for.
    on("font_char", function(code)
        query = string.char(math.floor((tonumber(code) or 97) + 0.5))
        text.font_q = query
        narrow()
        top = 0
        if #view > 0 then chosen = view[1].value end
        show()
        preview_soon()
    end)
    -- What is typed in the box: the list narrows, and the choice is the first name that has it.
    on("text:font_q", function()
        local q = (text.font_q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if q == query then return end
        query = q
        narrow()
        top = 0
        if #view > 0 and not index_of(chosen) then chosen = view[1].value end
        if query ~= "" and #view > 0 then chosen = view[1].value end
        show()
        preview_soon()
    end)
    on("font_scroll", function(w)
        w = tonumber(w) or 0
        top = math.max(0, math.min(math.max(0, #view - ROWS), top - math.floor(w * 3 + 0.5)))
        rows()
    end)
    -- The scrollbar as a handle: `frac` is where the pointer is along the track (0 top, 1 bottom); the thumb's middle goes there.
    on("font_bar", function(frac)
        local n = #view
        if n <= ROWS then return end
        frac = math.max(0, math.min(1, tonumber(frac) or 0))
        top = math.max(0, math.min(n - ROWS, math.floor((frac - ROWS / n / 2) * n + 0.5)))
        rows()
    end)
    -- The arrow keys, Page Up and Down, Home and End: the choice moves in the list as it stands, which follows it.
    on("font_step", function(d)
        d = tonumber(d) or 0
        if #view == 0 then return end
        local i = index_of(chosen) or (d > 0 and 0 or #view + 1)
        i = math.max(1, math.min(#view, i + math.floor(d + 0.5)))
        chosen = view[i].value
        keep_in_view()
        show()
        preview_soon()
    end)
    on("font_pick", function(i)
        local e = view[top + math.floor((tonumber(i) or 0) + 0.5) + 1]
        if not e then return end
        chosen = e.value
        show()
        preview()
    end)
    on("font_apply", function()
        if (chosen or default_font()) == inuse and chosen == saved[theme()] then return end
        if fact.font_applying then return end
        fact.font_applying = true
        after(10000, function() fact.font_applying = false end)      -- if nothing started the shell again, the button is not left stuck
        saved[theme()] = chosen
        pcall(sys.call, "files.write", "fonts.json", saved)
        show()
        -- The lock screen is drawn in the same typeface, so it starts again too, unless the session is locked right now (that would unlock it).
        after(500, function()
            run("pleamar", { "--say", "lockscreen", "get locked" }, function(locked)
                local pat = tostring(locked):match("true") and "(vitreus\\.plm|desktop|addons/)" or "(vitreus\\.plm|desktop|addons/|lockscreen/lockscreen\\.plm)"
                run("pkill", { "-f", "pleamar --scene .*/vitreus/" .. pat }, function() end)
            end)
        end)
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
-- once and shown sixteen at a time: the scene only ever holds one page of thumbnails, since the folder
-- can hold hundreds of full-size images. Choosing one asks awww to fade to it; the wallpaper watcher
-- above then sees the change, which is also what re-runs Iris.
local WP_PER_PAGE = 16
wh_hook = { active = function() return false end }      -- Wallhaven's view of the gallery (logic/wallhaven.luau) fills in the rest
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
        local args = { "-limit", "thread", "1", "-define", "jpeg:size=" .. (w * 2) .. "x" .. (h * 2), src .. "[0]",
                       "-auto-orient", "-thumbnail", w .. "x" .. h .. "^", "-gravity", "center",
                       "-extent", w .. "x" .. h, "-quality", "88", out }
        run("magick", args, function(_, code)
            wp_made[out] = code == 0
            left = left - 1
            if left == 0 then done() end
        end)
        end)
    end
end

local function wp_show_page()
    if wh_hook.active() then return end           -- (the gallery is showing Wallhaven's results)
    local rows, sel, ask = {}, -1, -1
    for i = 1, WP_PER_PAGE do
        local f = wp_view[wp_page * WP_PER_PAGE + i]
        if not f then break end
        local t = crop_path(f, "t")
        rows[i] = { thumb = wp_made[t] == true and t or (wpv.is(f) and "" or f) }
        if f == wp_cur then sel = i - 1 end
        if wp_delq and wp_delq.asked == f then ask = i - 1 end
    end
    model.wps = rows
    fact.wp_sel = sel
    fact.wp_ask = ask
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
-- `quiet`: a try, not a change: no video, no colours (Iris), and the wallpaper in use is not changed (the cards' live preview).
local function wp_apply(path, how, started, hex, quiet)
    -- `src`: the picture awww is given: the wallpaper itself, or a video's poster (made first, once)
    wpv.src(path, function(src)
        if not src then return end
        -- `pic`: what awww is given: `src`, or the picture the add-on that frames wallpapers made of it (a quick try from the cards is never sent: it can take seconds)
        local function show(pic)
            local function by_awww()
                local args = { "img", pic }
                for _, a in ipairs(how or { "--transition-type", "fade", "--transition-duration", "0.8" }) do args[#args + 1] = a end
                run("awww", args, function()
                    if not quiet then wpv.settle(path) end
                    if started then started() end     -- `started`: awww has the picture, the change is under way
                end)
            end
            if hex then
                -- the video (or the stop of the one playing) waits for the end of the dissolve: see `check_wallpaper`
                wp_hex(pic, hex.x, hex.y, function() wpv.next = { path }; if started then started() end end, by_awww)
            else
                by_awww()
            end
        end
        -- (a request an add-on is still working on when a newer one comes is dropped, and says `started` so whoever waits for it is not left waiting)
        if quiet or not wph.frame then show(src) else wph.frame(path, src, show, function() if started then started() end end) end
        if quiet then return end
        wp_on_change(path)
        -- The path is known: Iris starts now, while the fade plays, not when the watcher next notices the
        -- change. Marking it seen stops the watcher running it a second time.
        lens_image(src)
        if iris_last_wp ~= path then
            iris_last_wp = path
            run_iris(src, not (iris_cfg.enabled and not iris_cfg.preset))      -- a named palette or the greys: only the Theme card follows
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
            -- Settings > Wallpaper can point it elsewhere (wallpaper-dir.json): "~" is the home folder.
            local okd, saved = pcall(sys.ask, "files.read", "wallpaper-dir.json", "json")
            if okd and type(saved) == "table" and type(saved.dir) == "string" and saved.dir ~= "" then wp_dir = saved.dir end
            wpv.dir = wp_dir
            local shown = wp_dir
            if shown:sub(1, #d.home) == d.home then shown = "~" .. shown:sub(#d.home + 1) end
            text.wp_dirtext = shown
            text.wp_dirpath = wp_dir
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

-- The folder is chosen in the browser (the dashboard picture's: FACE lists and walks folders): "Use this folder" keeps the one being looked at, "Default" goes back
-- to <Pictures>/Wallpapers. A folder that is kept is saved in wallpaper-dir.json and listed at once.
local function wp_dir_use(want)
    with_dirs(function(d)
        if want:sub(1, 1) == "~" then want = d.home .. want:sub(2) end
        if want == "" then
            pcall(sys.call, "files.write", "wallpaper-dir.json", { dir = "" })
            wp_page = 0
            wp_load()
            return
        end
        run("test", { "-d", want }, function(_, code)
            if code ~= 0 then
                local shown = text.wp_dirtext
                text.wp_dirtext = "No such folder"
                after(2500, function() text.wp_dirtext = shown end)
                return
            end
            pcall(sys.call, "files.write", "wallpaper-dir.json", { dir = want })
            wp_page = 0
            wp_load()
        end)
    end)
end
on("wp_dir_browse", function()
    local h = FACE.home()
    local start = wp_dir or (h ~= "" and (h .. "/Pictures") or "")
    if start ~= "" then FACE.load(start) end
end)
on("wp_dir_choose", function() if FACE.dir ~= "" then wp_dir_use(FACE.dir) end end)
on("wp_dir_default", function() wp_dir_use("") end)
on("wp_pick", function(i)
    if wh_hook.active() then wh_hook.pick(i) return end
    local f = wp_view[wp_page * WP_PER_PAGE + i + 1]
    if f then wp_apply(f) end
end)
-- The bin in a gallery thumbnail's corner (not Wallhaven's results, nor the wallpaper in use: the scene does not offer it there). The first press asks, and the
-- thumbnail says so for 4 s; the second sends the picture to the trash (`gio trash`, so it can be put back; without it, into removed-wallpapers/ in the data
-- folder), and the folder is listed again. (`wp_delq` is a global table: this file is at Luau's limit of locals.)
wp_delq = { asked = nil, undo = {} }      -- (`undo`: what was sent away, newest last: { orig = where it was, kept = where it went if not to the trash })
local function wp_undo_arm()                  -- the Undo pill stays for 10 s after the last deletion, then the list is let go (the files stay in the trash)
    fact.wp_undo = #wp_delq.undo > 0
    local n = #wp_delq.undo
    after(10000, function() if #wp_delq.undo == n and n > 0 then wp_delq.undo = {}; fact.wp_undo = false end end)
end
on("wp_del", function(i)
    if wh_hook.active() then return end
    local f = wp_view[wp_page * WP_PER_PAGE + (tonumber(i) or -1) + 1]
    if not f or f == wp_cur then return end
    if wp_delq.asked ~= f then
        wp_delq.asked = f
        wp_show_page()
        after(4000, function() if wp_delq.asked == f then wp_delq.asked = nil; wp_show_page() end end)
        return
    end
    wp_delq.asked = nil
    run("gio", { "trash", f }, function(_, code)
        if code == 0 then
            wp_delq.undo[#wp_delq.undo + 1] = { orig = f }
            wp_undo_arm()
            wp_load()
            return
        end
        with_dirs(function(d)
            local dest = d.data .. "/removed-wallpapers"
            run("mkdir", { "-p", dest }, function()
                run("mv", { "-f", f, dest .. "/" }, function()
                    wp_delq.undo[#wp_delq.undo + 1] = { orig = f, kept = dest .. "/" .. f:match("[^/]+$") }
                    wp_undo_arm()
                    wp_load()
                end)
            end)
        end)
    end)
end)
-- Undo: puts the last picture sent away back where it was (from the trash with `gio move`, found by the path it came from; or out of removed-wallpapers/).
on("wp_undo_do", function()
    local e = table.remove(wp_delq.undo)
    fact.wp_undo = #wp_delq.undo > 0
    if not e then return end
    if e.kept then
        run("mv", { "-n", e.kept, e.orig }, function() wp_load() end)
        return
    end
    run("gio", { "list", "-a", "trash::orig-path", "-u", "trash:///" }, function(out)
        for line in (out or ""):gmatch("[^\n]+") do
            local uri, path = line:match("^([^\t]+)\t.-trash::orig%-path=(.+)$")
            if uri and path == e.orig then
                run("gio", { "move", uri, e.orig }, function() wp_load() end)
                return
            end
        end
    end)
end)
on("wp_prev", function()
    if wh_hook.active() then wh_hook.prev() return end
    wp_page = wp_page - 1
    if wp_page < 0 then wp_page = wp_pages() - 1 end
    wp_refresh()
end)
on("wp_next", function()
    if wh_hook.active() then wh_hook.next() return end
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
-- The Glass page's `opacity`: how solid the bar and the drawers are, from 30 % to 100 % (its track is 0 to 100 %, the first 30 %
-- of it shaded; below 30 % no blur is asked of the compositor). It is a number from 0 to 1 that the
-- scene reads, kept in `glass.json` a moment after the last change so a drag does not write a file per pixel.
-- Four more, all of them multipliers or switches the scene reads: `rim` (how bright the light along the edge is, 0 to 2, 1 as it
-- was), `refr` (how thick the glass is, 0 to 3) and `disp` (the rainbow at the edge, 0 to 2.5) only show when `bend` is on,
-- which swaps the compositor's blur for glass that really bends what is behind it. The blur's own strength is Hyprland's, and
-- lives in the Hyprland section below (it puts its setter in `glass.set_blur`).
-- `clear` (0 clear glass .. 1 frosted, pleamar's `frost:`) and `auto` (frost only where what is behind is busy) are the glass that bends's own
-- frost, and only show with `bend`. (There was once a "glass amount" slider, the scene's `glass:`: it overlapped Opacity and the Glass switch, and is always 100 % now.)
local glass = { opacity = 1, rim = 1, refr = 1, disp = 1, dome = 0, milk = 0, bend = false, live = false, bend_mon = nil, obsidian = false, clear = 1, auto = false, cap_ms = 300 }
local GLASS_OP_MIN = 0.3
local glass_save_waiting = false

-- "Bend on": the glass bends on every monitor, or only on the one named in `glass.bend_mon`. Each copy of the bar knows its monitor by `screen.K.name`
-- (empty until it knows: it bends then), the page's tiles are the Bar page's (`bar_m.i.name`). Only sets what changed.
local function glass_mons()
    for k = 0, 3 do
        local name = text["screen." .. k .. ".name"]
        local on = glass.bend_mon == nil or name == nil or name == "" or name == glass.bend_mon
        if fact["glass_b" .. k] ~= on then fact["glass_b" .. k] = on end
        local lit = glass.bend_mon ~= nil and text["bar_m." .. k .. ".name"] == glass.bend_mon
        if fact["glass_bm." .. k] ~= lit then fact["glass_bm." .. k] = lit end
    end
end
local function glass_refresh()
    glass_mons()
    fact.glass_op = glass.opacity
    text.glass_op_text = string.format("%d%%", math.floor(glass.opacity * 100 + 0.5))
    fact.glass_rim = glass.rim
    fact.glass_refr = glass.refr
    fact.glass_disp = glass.disp
    fact.glass_dome = glass.dome
    fact.glass_milk = glass.milk
    fact.glass_bend = (glass.bend or glass.live) and not glass.game      -- the lens: either switch turns it on (Live bend does not need X-Bend); never in Game Mode
    fact.files_bend = (glass.bend or glass.live) and not glass.game and not glass.hg      -- Files asks for this one as it starts (files.luau)
    fact.glass_x = glass.bend
    fact.glass_live = glass.live
    fact.lens_interval_ms = glass.cap_ms             -- pleamar reads this one: the least time between two captures for Live bend
    fact.glass_clear = glass.clear
    fact.glass_auto = glass.auto
    text.glass_clear_text = string.format("%d%%", math.floor(glass.clear * 100 + 0.5))
    fact.glass_obs = glass.obsidian
    text.glass_rim_text = string.format("%d%%", math.floor(glass.rim * 100 + 0.5))
    text.glass_refr_text = string.format("%d%%", math.floor(glass.refr * 100 + 0.5))
    text.glass_disp_text = string.format("%d%%", math.floor(glass.disp * 100 + 0.5))
    text.glass_dome_text = string.format("%d%%", math.floor(glass.dome * 100 + 0.5))
    text.glass_milk_text = string.format("%d%%", math.floor(glass.milk * 100 + 0.5))
    text.glass_cap_text = string.format("%d ms", glass.cap_ms)
end
-- The desktop clock and system monitor are scenes of their own: they are told when the glass goes off or on (they ask for it themselves when they start).
function glass.push_obs()
    local v = (glass.obsidian or glass.game) and "true" or "false"
    run("pleamar", { "--say", "desktopclock", "fact obs " .. v }, function() end)
    run("pleamar", { "--say", "desktopsysmon", "fact obs " .. v }, function() end)
    run("pleamar", { "--say", "desktopcards", "fact obs " .. v }, function() end)
    run("pleamar", { "--say", "files", "fact obs " .. v }, function() end)
    run("pleamar", { "--say", "desktopnotes", "fact obs " .. v }, function() end)
    run("pleamar", { "--say", "files", "fact gop " .. glass.opacity, "fact gbend " .. tostring((glass.bend or glass.live) and not glass.game and not glass.hg), "fact grefr " .. glass.refr, "fact gdisp " .. glass.disp,
        "fact gclear " .. glass.clear, "fact gdome " .. glass.dome, "fact gmilk " .. glass.milk, "fact grim " .. glass.rim }, function() end)     -- Files wears the same glass
end
-- Game Mode (logic/gamemode.luau) takes the glass away while it is on: the bar and the drawers go flat obsidian (`game_on` in the scene's `obs`) and
-- nothing bends, so nothing is captured behind them, every frame of a game being "something behind that changed"; and with Hyprland's blur off
-- (Game Mode turns it off too) the glass would only be a thin tint over the game. The desktop's own scenes and Files are told as for "glass off".
-- The Glass page keeps showing the person's own settings; nothing is saved.
function game_fx.glass(on)
    glass.game = on and true or false
    glass_refresh()
    glass.push_obs()
end
-- hyprglass (on trial with Files only): when the plugin is loaded in Hyprland, the compositor draws the glass behind the Files window
-- (hypr_vitreus.lua says how), so Files stops bending its own copy of the wallpaper (`gbend`, in glass.push_obs); the shell keeps its own. Looked at as the shell starts and whenever Hyprland's
-- config is read again (a plugin is loaded or unloaded, then `hyprctl reload`: watch_urgent's listener calls this on `configreloaded`).
function game_fx.hg_check()
    if not on_hyprland then return end
    run("hyprctl", { "plugin", "list" }, function(out, code)
        if code ~= 0 then return end
        local on = (out or ""):find("hyprglass", 1, true) ~= nil
        if on ~= (glass.hg == true) then
            glass.hg = on
            glass_refresh()
            glass.push_obs()
        end
    end)
end
after(3000, function() game_fx.hg_check() end)
local function glass_save_soon()
    glass.push_obs()
    if glass_save_waiting then return end
    glass_save_waiting = true
    after(500, function()
        glass_save_waiting = false
        pcall(sys.call, "files.write", "glass.json", { opacity = glass.opacity, rim = glass.rim, refr = glass.refr, disp = glass.disp, dome = glass.dome, milk = glass.milk, bend = glass.bend, live = glass.live, bend_mon = glass.bend_mon, obsidian = glass.obsidian, clear = glass.clear, auto = glass.auto, cap_ms = glass.cap_ms })
    end)
end

do
    local ok, saved = pcall(sys.ask, "files.read", "glass.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.opacity) == "number" then glass.opacity = math.max(GLASS_OP_MIN, math.min(1, saved.opacity)) end
        if type(saved.rim) == "number" then glass.rim = math.max(0, math.min(2, saved.rim)) end
        if type(saved.refr) == "number" then glass.refr = math.max(0, math.min(3, saved.refr)) end
        if type(saved.disp) == "number" then glass.disp = math.max(0, math.min(2.5, saved.disp)) end
        if type(saved.dome) == "number" then glass.dome = math.max(0, math.min(1.5, saved.dome)) end
        if type(saved.milk) == "number" then glass.milk = math.max(0, math.min(1, saved.milk)) end
        if type(saved.bend) == "boolean" then glass.bend = saved.bend end
        if type(saved.live) == "boolean" then glass.live = saved.live end
        if type(saved.bend_mon) == "string" and saved.bend_mon ~= "" then glass.bend_mon = saved.bend_mon end
        if type(saved.obsidian) == "boolean" then glass.obsidian = saved.obsidian end
        if type(saved.clear) == "number" then glass.clear = math.max(0, math.min(1, saved.clear)) end
        if type(saved.auto) == "boolean" then glass.auto = saved.auto end
        if type(saved.cap_ms) == "number" then glass.cap_ms = math.max(50, math.min(1000, saved.cap_ms)) end
    end
    glass_refresh()
end

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
on("glass_refr_set", function(t) glass.refr = glass.step(t, 3); glass_refresh(); glass_save_soon() end)
on("glass_disp_set", function(t) glass.disp = glass.step(t, 2.5); glass_refresh(); glass_save_soon() end)
on("glass_dome_set", function(t) glass.dome = glass.step(t, 1.5); glass_refresh(); glass_save_soon() end)
on("glass_cap_set", function(t) glass.cap_ms = 50 + math.floor(math.max(0, math.min(1, t)) * 19 + 0.5) * 50; glass_refresh(); glass_save_soon() end)
on("glass_milk_set", function(t) glass.milk = glass.step(t, 1); glass_refresh(); glass_save_soon() end)
on("glass_obs_toggle", function() glass.obsidian = not glass.obsidian; glass_refresh(); glass_save_soon() end)
on("glass_bend_mon", function(i)
    local name = text["bar_m." .. math.floor(i) .. ".name"]
    if name == nil or name == "" then return end
    glass.bend_mon = (glass.bend_mon ~= name) and name or nil
    glass_refresh(); glass_save_soon()
end)
-- the monitors' names arrive after the shell starts, and change when one is plugged in
every(2000, glass_mons)
on("glass_live_toggle", function() glass.live = not glass.live; glass_refresh(); glass_save_soon() end)
on("glass_bend_toggle", function() glass.bend = not glass.bend; glass_refresh(); glass_save_soon() end)
on("glass_clear_set", function(t) glass.clear = glass.step(t, 1); glass_refresh(); glass_save_soon() end)
on("glass_auto_toggle", function() glass.auto = not glass.auto; glass_refresh(); glass_save_soon() end)

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
local disp_ro = false                     -- under pleamar-wm: what the monitors are is shown, and it cannot be changed from here (session.conf says it)
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

-- Under pleamar-wm nothing can be changed on the fly (the compositor has no output management): the page edits drafts as on Hyprland, and Apply writes
-- the `monitor` lines of session.conf, which pleamar-wm reads at the next login. What `hyprctl monitors` cannot say is read from files: the lines already in
-- session.conf (a monitor on its side is said there as `transform 90`, while its size is given already turned) and the resolutions the kernel lists for each
-- connector. It lists no refresh rates, so a few usual ones, at or under the current one, are offered. (A global table: this chunk is at Luau's limit of locals.)
disp_wm = { conf = {}, modes = {}, loaded = false }
function disp_wm.path(fn)
    with_dirs(function(d) fn((d.conf:gsub("/shells/vitreus$", "")) .. "/session.conf") end)
end
function disp_wm.load(done)
    disp_wm.path(function(path)
        run("cat", { path }, function(out)
            local conf = {}
            for line in ((out or "") .. "\n"):gmatch("([^\n]*)\n") do
                local name, rest = line:match("^monitor%s+(%S+)%s*(.*)$")
                if name then
                    local t = tonumber(rest:match("transform%s+(%d+)")) or 0
                    conf[name] = { transform = ({ [90] = 1, [180] = 2, [270] = 3 })[t] or 0, vrr = (" " .. rest .. " "):find("%svrr%s") ~= nil }
                end
            end
            disp_wm.conf = conf
            run("find", { "-L", "/sys/class/drm", "-maxdepth", "2", "-name", "modes" }, function(found)
                local paths = {}
                for f in (found or ""):gmatch("%S+") do paths[#paths + 1] = f end
                if #paths == 0 then return done() end
                for _, f in ipairs(paths) do
                    -- /sys/class/drm/card<N>-<name>/modes -> <name>
                    local name = f:match("/card%d+%-([^/]+)/modes$")
                    run("cat", { f }, function(list)
                        if name then
                            local seen, res = {}, {}
                            for r in (list or ""):gmatch("(%d+x%d+)") do
                                if not seen[r] then seen[r] = true; res[#res + 1] = r end
                            end
                            -- (a connector with nothing plugged in has an empty list, and may not answer at all: each one that does is a reason to look again)
                            if #res > 0 then disp_wm.modes[name] = res; done() end
                        end
                    end)
                end
            end)
        end)
    end)
end
-- The modes a monitor offers, in the page's words ("2560x1440@165Hz"): each resolution the kernel lists, with the current refresh rate and the usual ones under it.
function disp_wm.modes_of(name, w, h, hz)
    local rates, seen = {}, {}
    for _, r in ipairs({ hz, 144, 120, 60 }) do
        if r <= hz and not seen[r] then seen[r] = true; rates[#rates + 1] = r end
    end
    local res = {}
    for _, r in ipairs(disp_wm.modes[name] or {}) do res[#res + 1] = r end
    local cur = w .. "x" .. h
    local have = false
    for _, r in ipairs(res) do if r == cur then have = true end end
    if not have then res[#res + 1] = cur end
    local out = {}
    for _, r in ipairs(res) do
        for _, v in ipairs(rates) do out[#out + 1] = string.format("%s@%dHz", r, v) end
    end
    return out
end
-- Apply: every monitor's line in session.conf, from the drafts (positions measured from the top left of the arrangement).
function disp_wm.apply()
    local mx, my = math.huge, math.huge
    for _, m in ipairs(disp_mons) do
        local d = disp_draft[m.name]
        mx, my = math.min(mx, d.x), math.min(my, d.y)
    end
    local lines, names = {}, {}
    for _, m in ipairs(disp_mons) do
        local d = disp_draft[m.name]
        local line = string.format("monitor %s %s@%d at %d,%d", m.name, d.res, d.hz, d.x - mx, d.y - my)
        if d.scale ~= "auto" and math.abs(d.scale - 1) > 0.001 then line = line .. " scale " .. disp_num(d.scale, 6) end
        local t = ({ [1] = " transform 90", [2] = " transform 180", [3] = " transform 270" })[d.transform or 0]
        if t then line = line .. t end
        if (disp_wm.conf[m.name] or {}).vrr then line = line .. " vrr" end
        lines[#lines + 1] = line
        names[#names + 1] = m.name
    end
    if #lines == 0 then return end
    disp_wm.path(function(path)
        -- (two passes: `$a` never fires when the last line is one of those just deleted)
        run("sed", { "-i", "-E", "-e", "/^monitor (" .. table.concat(names, "|") .. ")( |$)/d", path }, function()
            local args = { "-i" }
            for _, l in ipairs(lines) do args[#args + 1] = "-e"; args[#args + 1] = "$a\\" .. l end
            args[#args + 1] = path
            run("sed", args, function(_, code)
                if code ~= 0 then text.disp_msg = "Could not write session.conf."; return end
                text.disp_msg = "Saved to session.conf. It applies at your next login."
                disp_wm.load(function() end)
            end)
        end)
    end)
end

-- Read what Hyprland says, and keep the draft of every monitor that is there.
local function disp_read(done, max_age)
    hypr_monitors(max_age or 0, function(out, code)
        if code ~= 0 or not out then return done and done() end
        local ok, list = pcall(json.decode, out)
        if (not ok or type(list) ~= "table") and out:find("^Monitor ") then
            -- pleamar-wm's `hyprctl monitors` is text: "Monitor <name> (ID 1):", "2560x1440@164.83 at 1440x747", "scale: 1.00" (sizes already turned by the
            -- rotation, no list of modes). Shown as it is, and read-only (disp_ro): that desktop's monitors are said in ~/.config/pleamar/session.conf.
            list = {}
            for name, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID %d+%):\n(.-)\n\n") do
                local w, h, hz, x, y = body:match("(%d+)x(%d+)@([%d%.]+) at (%-?%d+)x(%-?%d+)")
                if w then
                    -- the size is given already turned: back to the monitor's own when session.conf stands it on its side
                    local t = (disp_wm.conf[name] or {}).transform or 0
                    local nw, nh = tonumber(w), tonumber(h)
                    if t == 1 or t == 3 then nw, nh = nh, nw end
                    list[#list + 1] = { name = name, description = "pleamar-wm: applied at the next login (saved in session.conf)", width = nw, height = nh,
                        refreshRate = tonumber(hz), x = tonumber(x), y = tonumber(y), scale = tonumber(body:match("scale:%s*([%d.]+)")) or 1, transform = t,
                        availableModes = disp_wm.modes_of(name, nw, nh, math.floor(tonumber(hz) + 0.5)) }
                end
            end
            if #list == 0 then return done and done() end
            ok, disp_ro = true, true
            if not disp_wm.loaded then
                disp_wm.loaded = true
                disp_wm.load(function() disp_read(done) end)
                return
            end
        else
            disp_ro = false
        end
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
        if on_niri then iris_fx.apply_niri() end           -- niri keeps them in vitreus.kdl, beside the room round the windows
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

-- A new mode makes the shell start again, but only once the trial is over (logic/monitor_height.luau: its surface keeps the size it had, and it
-- waits for Keep). A trial is still written down as it starts, and picked up by the next run, in case the shell stops some other way meanwhile
-- (a crash, a sleep): a trial held only in memory would be lost with it, the question gone and nothing to put back.
local function disp_trial_save(ends, restored)
    pcall(sys.call, "files.write", "display-trial.json", { ends = ends, before = disp_before, restored = restored == true })
end
local function disp_trial_clear()
    pcall(sys.call, "files.write", "display-trial.json", {})
end

local function disp_keep()
    disp_trial, disp_before = 0, nil
    disp_trial_clear()
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
    disp_trial_clear()
    disp_send(before, function()
        for _, m in ipairs(disp_mons) do disp_draft[m.name] = disp_spec_of(m) end
        disp_render()
        text.disp_msg = "Put back."
    end)
end

local function disp_apply()
    if disp_ro then return disp_wm.apply() end
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
    disp_trial_save(os.time() + DISP_TRIAL)
    disp_send(specs, function(ok)
        if not ok then
            disp_before = nil
            disp_trial_clear()
            return
        end
        disp_trial = DISP_TRIAL
        fact.disp_trial = DISP_TRIAL
        disp_trial_save(os.time() + DISP_TRIAL)
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
-- A change was on trial when the shell last stopped (it starts again on a new mode): ask again, here on the page, with the time it had, or a fresh
-- fifteen seconds the first time (the start itself ate most of the first lot). One that has already had its second chance is put back.
do
    local ok, t = pcall(sys.ask, "files.read", "display-trial.json", "json")
    if ok and type(t) == "table" and type(t.before) == "table" and next(t.before) ~= nil then
        disp_before = t.before
        if t.restored and (tonumber(t.ends) or 0) <= os.time() then
            disp_revert()
        else
            disp_trial = DISP_TRIAL
            fact.disp_trial = DISP_TRIAL
            disp_trial_save(os.time() + DISP_TRIAL, true)
            disp_trial_text()
            text.disp_msg = ""
            after(1500, function() fact.set_page = "pg_disp"; set_panel("settings") end)
        end
    end
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
    -- The details beside the temperature (an older cached forecast has none of them: a dash until the next one arrives).
    local c = w.current
    local function nz(v, f) if type(v) == "number" then return f(v) end return "—" end
    text.wx_feels = nz(c.apparent_temperature, function(v) return wx_round(v) .. "°" end)
    text.wx_hum = nz(c.relative_humidity_2m, function(v) return wx_round(v) .. "%" end)
    local dirs = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
    text.wx_wind = nz(c.wind_speed_10m, function(v)
        local d = type(c.wind_direction_10m) == "number" and (" " .. dirs[math.floor((c.wind_direction_10m + 22.5) / 45) % 8 + 1]) or ""
        return wx_round(v) .. (wx_cfg.units == "celsius" and " km/h" or " mph") .. d
    end)
    local pp = w.daily.precipitation_probability_max
    text.wx_rain = nz(type(pp) == "table" and pp[1] or nil, function(v) return wx_round(v) .. "%" end)
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
    if addon_push_wx then addon_push_wx() end
    return true
end

local function wx_read(name)
    local ok, v = pcall(sys.ask, "files.read", name, "json")
    if ok and type(v) == "table" then return v end
    return nil
end

local wx_again = false                -- the place was changed while a fetch was out: ask again when it is back
local function wx_done(ok)
    wx_busy = false
    if wx_again then wx_again = false; wx_refresh_now() return end
    if not ok then after(60000, function() if not wx_busy then wx_refresh_now() end end) end
end

local function wx_forecast(d)
    local unit = wx_cfg.units == "celsius" and "celsius" or "fahrenheit"
    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. wx_loc.lat .. "&longitude=" .. wx_loc.lon
        .. "&current=temperature_2m,weather_code,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
        .. "&wind_speed_unit=" .. (unit == "celsius" and "kmh" or "mph") .. "&temperature_unit=" .. unit .. "&timezone=auto&forecast_days=7"
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
                local g = r.results[1]
                lat, lon = g.latitude, g.longitude
                text.wx_name = tostring(g.name or loc) .. (g.admin1 and (", " .. g.admin1) or "") .. ((g.country_code and g.country_code ~= "US") and (", " .. g.country_code) or "")
            elseif r and loc == "" and r.success then
                lat, lon = r.latitude, r.longitude
                text.wx_name = "Automatic · " .. tostring(r.city or "by your IP")
            elseif r and loc ~= "" then
                text.wx_name = "Not found"
                wx_done(true)              -- nothing to retry (a place that is not there stays not there), but a change made meanwhile is still asked for
                return
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
    text.wx_in = wx_cfg.location
    fact.wx_c = wx_cfg.units == "celsius"
end
local function wx_save() pcall(sys.call, "files.write", "weather-config.json", wx_cfg) end
local function wx_apply(q)
    wx_cfg.location = ((q or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    text.wx_in = wx_cfg.location
    wx_save()
    wx_loc = nil
    text.wx_name = "Looking…"
    if wx_busy then wx_again = true else wx_refresh_now() end
end
on("wx_set", function() wx_apply(text.wx_in) end)
on("submit:wx_in", function() wx_apply(text.wx_in) end)
on("wx_auto", function() wx_apply("") end)
on("wx_units_set", function(i)
    local c = i >= 0.5
    wx_cfg.units = c and "celsius" or "fahrenheit"
    fact.wx_c = c
    wx_save()
    if wx_busy then wx_again = true else wx_refresh_now() end
end)
wx_refresh_now()
every(1800000, wx_refresh_now)           -- every half hour
end

-- ── Settings > Hyprland ───────────────────────────────────────────────────────────────────────────────────────
-- Window-manager knobs: layout, gaps, border resize, tearing, animations and input. The values
-- shown are what Hyprland says now. A change is sent with `hyprctl eval` at once, and once it has settled it is
-- written to vitreus_hypr.lua, which hyprland.lua loads after hypr_style.lua (the installer adds the line, also to an older install) so it wins on the next start.
do
    local LAYOUTS = { "dwindle", "master", "scrolling" }
    local hy = { layout = 3, gaps = 5, round = 10, border = 3, blur = 3, blur_on = true, passes = 1, resize = false, tear = false, anim = true, sens = 0, follow = 1, nat = false, center = 0, colw = 1, single = false }
    local hy_dirty, hy_waiting = false, false

    -- The windows' corners follow the theme: each theme has its own rounding (concentric with the shell's frame: Retro and Cyber are squarer, by the 73 % the drawers take),
    -- and the slider edits the current theme's, which is kept in hy-round.json and comes back when that theme is picked again.
    -- The frame's inner corner is `rc` in vitreus.plm: (26 - 19 * sq) * 1.35, 35 px on Glass and UwU, 9 on Retro and Cyber. A window sits about 13 px inside it
    -- (24 gap - 8 * 1.35 frame), so the window's own corner, concentric with the frame's, is that minus 13: 22 and (almost) square.
    local hy_round_by = {}
    local hy_theme = nil
    do
        local ok, saved = pcall(sys.ask, "files.read", "hy-round.json", "json")
        if ok and type(saved) == "table" then
            for k, v in pairs(saved) do if type(v) == "number" then hy_round_by[k] = math.floor(math.max(0, math.min(30, v))) end end
        end
    end

    -- Reading the options answers twelve times, each answer used to write every fact again; they are written once, when the answers have settled.
    local hy_dirty = false
    local function hy_show_now()
        hy_dirty = false
        fact.hy_layout = hy.layout
        fact.hy_gaps = hy.gaps
        fact.hy_round = hy.round
        fact.hy_border = hy.border
        fact.hy_blur = hy.blur_on and hy.blur or 0
        text.hy_blur_text = hy.blur_on and string.format("%d", hy.blur) or "Off"
        fact.hy_resize = hy.resize
        fact.hy_tear = hy.tear
        fact.hy_anim = hy.anim
        fact.hy_sens = hy.sens
        fact.hy_follow = hy.follow
        fact.hy_nat = hy.nat
        fact.ni_center = hy.center
        fact.ni_colw = hy.colw
        fact.ni_single = hy.single
        text.hy_gaps_text = string.format("%d px", hy.gaps)
        text.hy_round_text = string.format("%d px", hy.round)
        text.hy_border_text = string.format("%d px", hy.border)
        text.hy_sens_text = string.format("%.2f", hy.sens)
    end
    local function hy_show()
        if hy_dirty then return end
        hy_dirty = true
        after(80, hy_show_now)
    end

    local function b(v) return v and "true" or "false" end
    local hy_reduced = false      -- the system asks for less motion: Hyprland's animations are off meanwhile, live only (never written to vitreus_hypr.lua)
    local function hy_code(saved)
        return string.format(
            "hl.config({ general = { gaps_in = %d, border_size = %d, layout = \"%s\", resize_on_border = %s, allow_tearing = %s }, " ..
            "decoration = { rounding = %d, blur = { enabled = %s, size = %d, passes = %d } }, animations = { enabled = %s }, input = { sensitivity = %.2f, follow_mouse = %d, touchpad = { natural_scroll = %s } } })",
            hy.gaps, hy.border, LAYOUTS[hy.layout], b(hy.resize), b(hy.tear), hy.round, b(hy.blur_on), hy.blur, hy.passes, b(hy.anim and (saved or not hy_reduced)), hy.sens, hy.follow, b(hy.nat))
    end

    local function hy_write_file()
        local body = "-- Written by Vitreus (Settings > Hyprland); edits here are overwritten.\n" ..
            "-- hyprland.lua loads it after hypr_style.lua, so it wins over the values there.\n" .. hy_code(true) .. "\n"
        with_dirs(function(d)
            pcall(sys.call, "files.write", "vitreus_hypr.lua", body)
            local hypr = d.conf:gsub("/pleamar/shells/vitreus$", "/hypr")
            run("cp", { "-f", d.data .. "/vitreus_hypr.lua", hypr .. "/vitreus_hypr.lua" }, function() end)
        end)
    end

    -- niri: the same facts, from and to niri-set.json / vitreus.kdl (see `iris_fx.niri_code`) in place of hyprctl. What config.kdl has is what the page shows until it is changed.
    local niri_apply_waiting, niri_ready = false, false
    local niri_read
    local function niri_changed()
        iris_fx.niri_load()
        if not niri_ready then            -- nothing of niri's has been read yet: read it first, so the values written are config.kdl's but for the one that changed
            local r = hy.round
            niri_read(function() niri_ready = true; hy.round = r; niri_changed() end)
            return
        end
        hy_show()
        local n = niri_set
        n.gaps, n.round, n.border, n.sens, n.follow = hy.gaps, hy.round, hy.border, hy.sens, hy.follow
        n.nat, n.anim, n.center, n.colw, n.single = hy.nat, hy.anim, hy.center, hy.colw, hy.single
        pcall(sys.call, "files.write", "niri-set.json", n)
        if niri_apply_waiting then return end
        niri_apply_waiting = true
        after(250, function()
            niri_apply_waiting = false
            iris_fx.apply_niri()
        end)
    end
    niri_read = function(after_read)
        iris_fx.niri_load()
        with_dirs(function(d)
            local cfg = d.conf:gsub("/pleamar/shells/vitreus$", "/niri") .. "/config.kdl"
            run("cat", { cfg }, function(out, code)
                local t = {}
                for line in ((code == 0 and out) or ""):gmatch("[^\n]+") do t[#t + 1] = (line:gsub("//.*$", "")) end
                local txt = table.concat(t, "\n")
                local function has(pat) return txt:find(pat) ~= nil end
                hy.gaps = tonumber(txt:match("\n%s*gaps%s+([%d%.]+)")) or 16
                hy.round = 0
                hy.border = tonumber(txt:match("focus%-ring%s*{[^}]-width%s+([%d%.]+)")) or 4
                if has("focus%-ring%s*{%s*off") then hy.border = 0 end
                hy.follow = has("\n%s*focus%-follows%-mouse") and 1 or 0
                hy.nat = has("\n%s*natural%-scroll")
                hy.anim = not has("animations%s*{[^}]-\n%s*off")
                local c = txt:match('center%-focused%-column%s+"([%a%-]+)"')
                hy.center = c == "always" and 1 or (c == "on-overflow" and 2 or 0)
                hy.single = has("\n%s*always%-center%-single%-column")
                local pr = tonumber(txt:match("default%-column%-width%s*{%s*proportion%s+([%d%.]+)"))
                hy.colw = pr and (pr < 0.4 and 0 or (pr < 0.6 and 1 or (pr < 0.9 and 2 or 3))) or 1
                hy.sens = 0
                -- what the page itself has changed wins
                local n = niri_set
                if n.gaps then hy.gaps = n.gaps end
                if n.round then hy.round = n.round end
                if n.border then hy.border = n.border end
                if n.sens then hy.sens = n.sens end
                if n.follow ~= nil then hy.follow = n.follow end
                if n.nat ~= nil then hy.nat = n.nat end
                if n.anim ~= nil then hy.anim = n.anim end
                if n.center ~= nil then hy.center = n.center end
                if n.colw ~= nil then hy.colw = n.colw end
                if n.single ~= nil then hy.single = n.single end
                niri_ready = true
                hy_show()
                if after_read then after_read() end
            end)
        end)
    end

    local function hy_changed()
        if on_niri then return niri_changed() end
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

    -- One `hyprctl --batch` for all twelve options, not twelve commands: starting a command from this shell costs about 30 ms each, so reading
    -- them one by one froze the whole shell for half a second. Each answer is a line like `int: 3` (or `str:`, `float:`, `bool:`, `css gap data:`).
    local HY_OPTS = { "general:layout", "general:gaps_in", "general:border_size", "decoration:rounding", "decoration:blur:size",
        "decoration:blur:passes", "general:resize_on_border", "general:allow_tearing", "animations:enabled", "input:sensitivity",
        "input:follow_mouse", "input:touchpad:natural_scroll", "decoration:blur:enabled" }
    local function hy_read()
        if on_niri then return niri_read() end
        local cmd = {}
        for i, n in ipairs(HY_OPTS) do cmd[i] = "getoption " .. n end
        run("hyprctl", { "--batch", table.concat(cmd, " ; ") }, function(out, code)
            if code ~= 0 then return end
            local vals = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local k, v = line:match("^([%a ]+): (.*)$")
                if k and k ~= "set" then vals[#vals + 1] = v end
            end
            if #vals < #HY_OPTS then return end
            for i, n in ipairs(LAYOUTS) do if n == vals[1] then hy.layout = i end end
            hy.gaps = tonumber(vals[2]:match("^(%d+)")) or hy.gaps
            hy.border = tonumber(vals[3]) or hy.border
            hy.round = tonumber(vals[4]) or hy.round
            hy.blur = tonumber(vals[5]) or hy.blur
            hy.passes = tonumber(vals[6]) or hy.passes
            hy.resize = vals[7] == "true"
            hy.tear = vals[8] == "true"
            if not hy_reduced then hy.anim = vals[9] == "true" end
            hy.sens = tonumber(vals[10]) or 0
            hy.follow = tonumber(vals[11]) or 1
            hy.nat = vals[12] == "true"
            hy.blur_on = vals[13] ~= "false"
            hy_show()
        end)
    end

    hy_show()
    hy_read()

    hy_theme = vtheme.current().id   -- at start Hyprland already holds what was kept
    hy_theme_changed = function(key)
        if key == hy_theme then return end
        hy_theme = key
        hy.round = hy_round_by[key] or (on_niri and niri_set.round) or vtheme.round_of(key) or hy.round     -- (on niri a value set on the page is kept, whatever theme comes up)
        hy_changed()
    end

    on("hy_layout_set", function(i) hy.layout = math.max(1, math.min(3, math.floor(i + 0.5))); hy_changed() end)
    on("hy_gaps_set", function(t) hy.gaps = math.floor(math.max(0, math.min(1, t)) * 30 + 0.5); hy_changed() end)
    on("hy_border_set", function(t) hy.border = math.floor(math.max(0, math.min(1, t)) * 10 + 0.5); hy_changed() end)
    on("hy_round_set", function(t)
        hy.round = math.floor(math.max(0, math.min(1, t)) * 30 + 0.5)
        if hy_theme then
            hy_round_by[hy_theme] = hy.round
            pcall(sys.call, "files.write", "hy-round.json", hy_round_by)
        end
        hy_changed()
    end)
    on("hy_sens_set", function(t)
        hy.sens = math.floor((math.max(0, math.min(1, t)) * 2 - 1) * 20 + 0.5) / 20
        hy_changed()
    end)
    -- The blur behind the shell, from the Glass page: its size, 1 to 20, and more passes as it grows so a big blur stays smooth. 0 is off
    -- (Hyprland's `blur.enabled`; the size is kept at 1 so that turning it back on is a plain step up).
    local function set_blur(size, passes)
        local v = math.max(0, math.min(20, math.floor(size + 0.5)))
        hy.blur_on = v > 0
        hy.blur = math.max(1, v)
        hy.passes = passes or (1 + math.floor((hy.blur - 1) / 6))
        if on_niri then hy_show() return end         -- (no blur to set on niri)
        hy_changed()
    end
    glass.set_blur = set_blur
    on("glass_blur_set", function(t) set_blur(math.max(0, math.min(1, t)) * 20) end)
    on("hy_follow_set", function(i) hy.follow = math.max(0, math.min(3, math.floor(i + 0.5))); hy_changed() end)
    on("ni_center_set", function(i) hy.center = math.max(0, math.min(2, math.floor(i + 0.5))); hy_changed() end)
    on("ni_colw_set", function(i) hy.colw = math.max(0, math.min(3, math.floor(i + 0.5))); hy_changed() end)
    on("ni_toggle", function(k)
        k = math.floor(k + 0.5)
        if k == 0 then hy.single = not hy.single
        elseif k == 1 then hy.anim = not hy.anim
        else hy.nat = not hy.nat end
        hy_changed()
    end)
    on("hy_toggle", function(k)
        k = math.floor(k + 0.5)
        if k == 0 then hy.resize = not hy.resize
        elseif k == 1 then hy.tear = not hy.tear
        elseif k == 2 then hy.anim = not hy.anim
        else hy.nat = not hy.nat end
        hy_changed()
    end)
    on("hy_refresh", function() hy_read() end)
    on("motion_reduced", function(v)
        local r = v > 0.5
        if r == hy_reduced or on_niri then return end
        hy_reduced = r
        if hy.anim then run("hyprctl", { "eval", hy_code() }, function() end) end
    end)
end

-- ── Settings > Pleamar-WM ─────────────────────────────────────────────────────────────────────────────────────
-- The window manager is a scene, so its layout, gaps and effects are facts of it, set over its socket at once and kept in wm.json (the scene
-- forgets them when it reloads; they are put back when this shell starts). The input lines (pointer, touchpad, idle) are session.conf's,
-- which pleamar-wm reads when it starts: they are rewritten here and apply at the next login.
do
    local wm = { layout = 0, lays = {}, share = 0.56, gap = 12, free = false, rain = false, snow = false, bw = 1.5, ba = 70, rad = 12, shd = 100, tb = 22, tbo = 72, wa = 100, wi = 100, fr = 80, wst = 0, tbt = true }
    -- The windows' corners follow the theme here too, as on Hyprland (same per-theme values, kept apart in wm-round.json): the slider edits the current theme's.
    local wm_round_by, wm_theme = {}, "glass"
    do
        local ok, saved = pcall(sys.ask, "files.read", "wm-round.json", "json")
        if ok and type(saved) == "table" then
            for k, v in pairs(saved) do if type(v) == "number" then wm_round_by[k] = math.floor(math.max(0, math.min(24, v))) end end
        end
    end
    local function wm_theme_key()
        return vtheme.current().id
    end
    -- The layout is each monitor's own, by its name (wm.lays); wm.layout is the one a monitor gets that has none chosen yet. `wm_names` are the
    -- monitors in the window manager's own order (its `lay.N`), `wm_sel` the one the Layout chips are for.
    local wm_names, wm_sel, wm_names_ok = {}, 1, false
    local function layout_of(name) return (name and wm.lays[name]) or wm.layout end
    local inp = { ms = 0, ts = 0, nat = false, tap = false, idle = 7, maccel = "adaptive", taccel = "adaptive", dwt = nil }
    local wm_waiting, in_waiting = false, false

    local function say(line) run("pleamar", { "--say", "wm", line }, function() end) end
    local function b(v) return v and "true" or "false" end

    local function wm_show()
        fact.wm_layout = layout_of(wm_names[wm_sel])
        fact.wm_mon_sel = wm_sel - 1
        for i = 1, 4 do
            fact["wm_m." .. (i - 1) .. ".on"] = wm_names[i] ~= nil
            text["wm_m." .. (i - 1) .. ".name"] = wm_names[i] or ""
        end
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
        fact.wm_wst = wm.wst
        fact.wm_tbt = wm.tbt
        text.wm_fr_text = string.format("%d%%", wm.fr)
        text.wm_share_text = string.format("%d%%", math.floor(wm.share * 100 + 0.5))
        text.wm_gap_text = string.format("%d px", wm.gap)
        text.wm_ms_text = string.format("%.2f", inp.ms)
        text.wm_ts_text = string.format("%.2f", inp.ts)
        text.wm_idle_text = string.format("%d min", inp.idle)
    end

    -- The room the shell's frame keeps round the bar's monitor, which pleamar-wm keeps the windows out of (its `fr.MONITOR.EDGE`; Hyprland has the
    -- same in `gaps_out`, see `iris_fx.gaps_code`): with the bar on the left, 24 px on the top, right and bottom and 76 on the left, from the edge of
    -- the screen; none on a monitor without the bar, or with the bar on top. The window manager puts its gap on top of whatever is set, so that gap is taken off.
    local FRAME_ROOM = { top = 24, right = 24, bottom = 24, left = 76 }
    local FRAME_ROOMS = {
        left = FRAME_ROOM,
        right = { top = 24, right = 76, bottom = 24, left = 24 },
        top = { top = 76, right = 24, bottom = 24, left = 24 },
        bottom = { top = 24, right = 24, bottom = 76, left = 24 },
    }
    local FRAME_SEG = { top = 59, right = 24, bottom = 24, left = 24 }
    local EDGES = { "top", "right", "bottom", "left" }
    function wm_frame_sync()
        if on_hyprland then return end
        hypr_monitors(30, function(mons)
            if not mons then return end
            local names = {}
            for name, id in mons:gmatch("Monitor (%S+) %(ID (%d+)%)") do names[tonumber(id)] = name end
            local framed = fact.bar_frame == true and bar_mon.name ~= nil
            local room = FRAME_ROOMS[fact.bar_anchor] or FRAME_ROOM
            if fact.bar_seg == true and fact.bar_anchor == "top" then room = FRAME_SEG end   -- the top frame in pieces: windows start below the pieces, as on Hyprland (`iris_fx.gaps_code`)
            local island_min = not framed and bar_mon.name ~= nil and iris_fx.island_min() and fact.bar_anchor == "top"   -- the Island below 100 % reserves nothing: its room is kept here
            local want, cmds = {}, {}
            local dock = dock_fx.room()
            for id = 0, 3 do
                local has = framed and names[id] ~= nil and (bar_mon.set ~= nil and bar_mon.set[names[id]] == true)
                -- a monitor with only the frame (Settings > Bar, "Frame on the other monitors") gets the frame's room on every side
                local thin = framed and not has and names[id] ~= nil and fact.bar_others == true
                for _, e in ipairs(EDGES) do
                    want[#want + 1] = has and math.max(0, room[e] - wm.gap) or (thin and math.max(0, FRAME_ROOM.top - wm.gap) or 0)
                    if island_min and e == "top" and names[id] ~= nil and (bar_mon.set ~= nil and bar_mon.set[names[id]] == true) then want[#want] = iris_fx.island_room() end
                    -- the docks are on the monitors the bar is on only
                    if dock[e] and names[id] ~= nil and bar_mon.set ~= nil and bar_mon.set[names[id]] == true then want[#want] = math.max(want[#want], math.max(0, dock[e] - wm.gap)) end
                    cmds[#cmds + 1] = "get fr." .. id .. "." .. e
                end
            end
            say_many("wm", cmds, function(r)
                if not r then return end
                local out, k = {}, 0
                for id = 0, 3 do
                    for _, e in ipairs(EDGES) do
                        k = k + 1
                        if tonumber((r[k] or ""):match("%-?[%d.]+")) ~= want[k] then out[#out + 1] = "fact fr." .. id .. "." .. e .. " " .. want[k] end
                    end
                end
                say_batch("wm", out)
            end)
        end)
    end

    on("fact:bar_seg", function() wm_frame_sync() end)
    on("fact:bar_others", function() wm_frame_sync() end)

    local function wm_send()
        if not wm_names_ok then
            say_many("wm", { "get monname.0", "get monname.1", "get monname.2", "get monname.3" }, function(r)
                if not r then return end
                wm_names = {}
                for i = 1, 4 do wm_names[i] = ((r[i] or ""):match("^%s*([%w%._%-]+)")) end
                wm_names_ok = true
                if wm_sel > 4 or not wm_names[wm_sel] then wm_sel = 1 end
                wm_show()
                wm_send()
            end)
            return
        end
        local cmds = {}
        local function say(line) cmds[#cmds + 1] = line end
        say("fact gap " .. wm.gap)
        say("fact ratio " .. wm.share)
        for m = 0, 3 do
            say("fact lay." .. m .. " " .. layout_of(wm_names[m + 1]))
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
        say("fact wfr " .. wm.fr)
        say("fact wst " .. wm.wst)
        say("fact tbt " .. (wm.tbt and 1 or 0))
        say("fact vit 1")
        say_batch("wm", cmds)
        wm_frame_sync()
    end

    -- Nothing is written to wm.json until the saved choices have been read back (below, a few seconds after the shell starts): a theme is applied at once on
    -- starting, and saving then wrote the first values (no layouts at all) over the file, which the restore then read.
    local wm_restored = false
    local function wm_save()
        if not wm_restored then return end
        pcall(sys.call, "files.write", "wm.json", { layout = wm.layout, lays = wm.lays, share = wm.share, gap = wm.gap, free = wm.free, rain = wm.rain, snow = wm.snow, bw = wm.bw, ba = wm.ba, rad = wm.rad, shd = wm.shd, tb = wm.tb, tbo = wm.tbo, wa = wm.wa, wi = wm.wi, fr = wm.fr, wst = wm.wst, tbt = wm.tbt })
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
        -- Pleamar-WM answers only when it is the window manager; on Hyprland each of these would start a command to get nothing back.
        if on_hyprland then return end
        -- One connection for all of them (`say_many`): a `pleamar --say` program for each of these fifteen made the page stall when it opened.
        local names = { "gap", "ratio", "monname.0", "free.0", "rain", "snow", "bw", "ba", "rad", "shd", "tb", "tbo", "wo_a", "wo_i", "wfr", "wst", "tbt", "vit" }
        local cmds = {}
        for i, n in ipairs(names) do cmds[i] = "get " .. n end
        -- (after those: each monitor's name and the layout it has now, to show what is really there)
        for m = 0, 3 do cmds[#cmds + 1] = "get monname." .. m; cmds[#cmds + 1] = "get lay." .. m end
        say_many("wm", cmds, function(r)
            if not r then return end
            local base = #names
            -- The scene was read in again (a theme or the wallpaper changed its palette) and has its first values, not the ones chosen: taking those as what is
            -- there would forget every layout and setting. The chosen ones go back in instead.
            if (tonumber(((r[base] or ""):match("%-?[%d.]+"))) or 0) ~= 1 then wm_send(); return end
            wm_names = {}
            for m = 0, 3 do
                local n = (r[base + m * 2 + 1] or ""):match("^%s*([%w%._%-]+)")
                wm_names[m + 1] = n
                local l = tonumber(((r[base + m * 2 + 2]) or ""):match("%-?%d+"))
                if n and l then wm.lays[n] = math.max(0, math.min(7, l)) end
            end
            wm_names_ok = true
            if not wm_names[wm_sel] then wm_sel = 1 end
            local function val(i)
                local out = r[i] or ""
                return tonumber(out:match("%-?[%d.]+")) or (out:match("true") and 1) or (out:match("false") and 0) or nil
            end
            local v = {}
            for i = 1, #names do v[i] = val(i) end
            if v[1] then wm.gap = v[1] end
            if v[2] then wm.share = v[2] end
            if v[4] then wm.free = v[4] == 1 end
            if v[5] then wm.rain = v[5] == 1 end
            if v[6] then wm.snow = v[6] == 1 end
            if v[7] then wm.bw = v[7] end
            if v[8] then wm.ba = v[8] end
            if v[9] then wm.rad = v[9] end
            if v[10] then wm.shd = v[10] end
            if v[11] then wm.tb = v[11] end
            if v[12] then wm.tbo = v[12] end
            if v[13] then wm.wa = v[13] end
            if v[14] then wm.wi = v[14] end
            if v[15] then wm.fr = v[15] end
            if v[16] then wm.wst = v[16] end
            if v[17] then wm.tbt = v[17] == 1 end
            wm_show()
        end)
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
        wm_restored = true
        if ok and type(saved) == "table" then
            wm.layout = math.max(0, math.min(7, tonumber(saved.layout) or 0))
            wm.lays = {}
            if type(saved.lays) == "table" then
                for k, v in pairs(saved.lays) do
                    if type(k) == "string" and tonumber(v) then wm.lays[k] = math.max(0, math.min(7, math.floor(tonumber(v)))) end
                end
            end
            wm.share = tonumber(saved.share) or wm.share
            wm.gap = tonumber(saved.gap) or wm.gap
            wm.free, wm.rain, wm.snow = saved.free == true, saved.rain == true, saved.snow == true
            wm.bw, wm.ba, wm.rad = tonumber(saved.bw) or wm.bw, tonumber(saved.ba) or wm.ba, tonumber(saved.rad) or wm.rad
            wm.shd, wm.tb, wm.tbo = tonumber(saved.shd) or wm.shd, tonumber(saved.tb) or wm.tb, tonumber(saved.tbo) or wm.tbo
            wm.wa, wm.wi = tonumber(saved.wa) or wm.wa, tonumber(saved.wi) or wm.wi
            wm.fr = tonumber(saved.fr) or wm.fr
            wm.wst = math.max(0, math.min(3, math.floor(tonumber(saved.wst) or wm.wst)))
            if saved.tbt ~= nil then wm.tbt = saved.tbt == true end
            wm_theme = wm_theme_key()
            wm.rad = wm_round_by[wm_theme] or vtheme.round_of(wm_theme) or wm.rad
            wm_show()
            wm_send()
        end
    end)

    -- The scene is read in again when the wallpaper changes the palette (its border takes a colour from it), and that puts every fact back to its
    -- first value: when the gap is not what was chosen, everything chosen is sent again.
    every(5000, function()
        if on_hyprland then return end
        wm_get("vit", function(v)
            if v ~= nil and v ~= 1 then wm_send() end
        end)
        wm_frame_sync()
    end)

    on("wm_layout_set", function(i)
        local l = math.max(0, math.min(7, math.floor(i + 0.5)))
        local n = wm_names[wm_sel]
        if n then wm.lays[n] = l else wm.layout = l end
        wm_changed()
    end)
    on("wm_mon_pick", function(i)
        local k = math.floor(i + 0.5) + 1
        if wm_names[k] then wm_sel = k; wm_show() end
    end)
    on("wm_wst_set", function(i) wm.wst = math.max(0, math.min(3, math.floor(i + 0.5))); wm_changed() end)
    on("wm_share_set", function(t) wm.share = math.floor((0.3 + math.max(0, math.min(1, t)) * 0.5) * 100 + 0.5) / 100; wm_changed() end)
    on("wm_gap_set", function(t) wm.gap = math.floor(math.max(0, math.min(1, t)) * 32 + 0.5); wm_changed() end)
    on("wm_toggle", function(k)
        k = math.floor(k + 0.5)
        if k == 0 then wm.free = not wm.free; wm_changed()
        elseif k == 1 then wm.rain = not wm.rain; wm_changed()
        elseif k == 2 then wm.snow = not wm.snow; wm_changed()
        elseif k == 5 then wm.tbt = not wm.tbt; wm_changed()
        elseif k == 3 then inp.nat = not inp.nat; in_changed()
        else inp.tap = not inp.tap; in_changed() end
    end)
    local prev_theme_changed = hy_theme_changed
    hy_theme_changed = function(key)
        if prev_theme_changed then prev_theme_changed(key) end
        if on_hyprland or key == wm_theme then return end
        wm_theme = key
        wm.rad = wm_round_by[key] or vtheme.round_of(key) or wm.rad
        wm_changed()
    end

    on("wm_style_set", function(v)
        local i = math.floor(v / 10)
        local t = math.max(0, math.min(1, v - i * 10))
        if i == 0 then wm.bw = math.floor(t * 12 + 0.5) / 2
        elseif i == 1 then wm.ba = math.floor(20 + t * 80 + 0.5)
        elseif i == 2 then
            wm.rad = math.floor(t * 24 + 0.5)
            wm_round_by[wm_theme] = wm.rad
            pcall(sys.call, "files.write", "wm-round.json", wm_round_by)
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
    local MODES = { ["#"] = "files", [">"] = "commands", [":"] = "emoji", ["^"] = "clipboard", ["~"] = "wallpapers", ["@"] = "windows", ["?"] = "web", ["!"] = "web", ["$"] = "snippets", ["="] = "calc", ["+"] = "packages" }
    local LABEL = { apps = "Apps", calc = "Calc", files = "Files", commands = "Commands", emoji = "Emoji", clipboard = "Clipboard", wallpapers = "Wallpapers", windows = "Windows", web = "Web", snippets = "Snippets", packages = "Packages" }
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
                pinnable = r.app ~= nil, pin = r.app ~= nil and cdk_pinned(r.app),
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

    -- A card on the desktop with its own scene: asked how it is, started if it is not running, and shown or put away. (The desktop's right-click menu, desktopmenu/, says
    -- these over `pleamar --say`; the clock is already running, as it starts with the desktop.)
    local function toggle_scene(name, dir)
        run("pleamar", { "--say", name, "get shown" }, function(out, code)
            if code ~= 0 then
                exec_on_desktop('vitreus-keep "$HOME/.config/pleamar/shells/vitreus/' .. dir .. '/' .. dir .. '.plm"')
                after(2500, function() run("pleamar", { "--say", name, "fact shown true" }, function() end) end)
                return
            end
            local on = (out or ""):match("true") ~= nil
            run("pleamar", { "--say", name, "fact shown " .. (on and "false" or "true") }, function() end)
        end)
    end
    on("cam_toggle", function() toggle_scene("webcam", "webcam") end)
    -- A new sticky note: the sticker scene is started if it is not running, then asked for one where the menu said (or the middle).
    local function new_sticker(mon, x, y)
        local function send()
            run("pleamar", { "--say", "desktopnotes", "fact shown true" }, function()
                run("pleamar", { "--say", "desktopnotes", "fact nmon " .. mon }, function()
                    run("pleamar", { "--say", "desktopnotes", "fact nx " .. x }, function()
                        run("pleamar", { "--say", "desktopnotes", "fact ny " .. y }, function()
                            run("pleamar", { "--say", "desktopnotes", "emit note_new" }, function() end)
                        end)
                    end)
                end)
            end)
        end
        run("pleamar", { "--say", "desktopnotes", "get shown" }, function(_, code)
            if code ~= 0 then
                exec_on_desktop('vitreus-keep "$HOME/.config/pleamar/shells/vitreus/desktopnotes/desktopnotes.plm"')
                -- Not a fixed wait: ask again until the scene answers (it takes about a second to start), for five seconds at most.
                local tries = 0
                local function wait()
                    tries = tries + 1
                    run("pleamar", { "--say", "desktopnotes", "get shown" }, function(_, c)
                        if c == 0 or tries >= 25 then send() else after(200, wait) end
                    end)
                end
                after(300, wait)
            else
                send()
            end
        end)
    end
    on("sticky_new", function()
        new_sticker(math.floor((tonumber(fact.sn_mon) or 0) + 0.5), math.floor(tonumber(fact.sn_x) or -1), math.floor(tonumber(fact.sn_y) or -1))
        fact.sn_mon, fact.sn_x, fact.sn_y = 0, -1, -1
    end)
    on("dclock_toggle", function() toggle_scene("desktopclock", "desktopclock") end)
    on("dsys_toggle", function() toggle_scene("desktopsysmon", "desktopsysmon") end)

    -- ── commands ──
    local function open_settings(page)
        return function() fact.set_page = page; set_panel("settings"); return true end
    end
    -- Each command: title, what it is, what it does, and words that find it besides its title (all searched, spaces ignored).
    local COMMANDS = {
        { "Settings: Wallpaper", "open", open_settings("pg_wall"), "background picture image folder slideshow desktop" },
        { "Settings: Glass", "open", open_settings("pg_glass"), "blur transparency frosted liquid look appearance theme" },
        { "Settings: Display", "open", open_settings("pg_disp"), "monitor screen resolution refresh rate scale arrangement vrr position" },
        { "Settings: Idle and sleep", "open", open_settings("pg_idle"), "lock screen off sleep suspend timeout hypridle inactivity minutes" },
        { "Settings: Night mode", "open", open_settings("pg_night"), "nightlight blue light warm tint redshift filter schedule eyes" },
        { "Game mode: toggle", "action", function() spawn('pleamar --say vitreus "emit game_toggle"') end, "game gaming play performance fullscreen tearing latency fps on off" },
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
        { "Settings: Theme", "open", open_settings("pg_theme"), "colours colors palette theme glass retro cassette plastic iris accent wallpaper" },
        { "Settings: Keybinds", "open", open_settings("pg_keys"), "keybinds keyboard shortcuts keys hotkeys bindings shortcut super combo remap" },
        { "Settings: Widgets", "open", open_settings("pg_clock"), "widgets clock system monitor audio visualiser visualizer cava desktop clock glass digits time wallpaper layout inline stacked staggered hero position corner size weight tint 12 24 hour" },
        { "Settings: Weather location", "open", open_settings("pg_vpn"), "weather forecast location city zip code place celsius fahrenheit units vpn calendar temperature" },
        { "Desktop clock: toggle", "action", function()
            run("pleamar", { "--say", "desktopclock", "get shown" }, function(out)
                local on = (out or ""):match("true") ~= nil
                run("pleamar", { "--say", "desktopclock", "fact shown " .. (on and "false" or "true") }, function() end)
            end)
        end, "clock desktop glass digits time wallpaper show hide on off" },
        { "Desktop system monitor: toggle", "action", function()
            -- A card on the desktop (desktopsysmon/) with its own scene: asked how it is, and started if it is not running.
            run("pleamar", { "--say", "desktopsysmon", "get shown" }, function(out, code)
                if code ~= 0 then
                    exec_on_desktop('vitreus-keep "$HOME/.config/pleamar/shells/vitreus/desktopsysmon/desktopsysmon.plm"')
                    after(2500, function() run("pleamar", { "--say", "desktopsysmon", "fact shown true" }, function() end) end)
                    return
                end
                local on = (out or ""):match("true") ~= nil
                run("pleamar", { "--say", "desktopsysmon", "fact shown " .. (on and "false" or "true") }, function() end)
            end)
        end, "system monitor desktop widget card cpu memory gpu network show hide on off" },
        { "Audio visualiser: toggle", "action", function() spawn('pleamar --say vitreus "emit fw_toggle"') end, "audio visualiser visualizer cava spectrum music bars wave equalizer desktop widget show hide on off" },
        { "Webcam: toggle", "action", function() spawn('pleamar --say vitreus "emit cam_toggle"') end, "webcam camera self view mirror face round window record screen show hide on off" },
        { "Webcam: mirror on/off", "action", function() spawn('pleamar --say webcam "emit cam_mirror"') end, "webcam camera mirror flip self view" },
        { "Sticky note: new", "action", function() spawn('pleamar --say vitreus "emit sticky_new"') end, "sticky note sticker new add notes desktop paper write" },
        { "Files", "action", function() spawn('PATH="$HOME/.local/bin:$PATH" vitreus-files') end, "files file manager folder folders browse explorer home documents downloads search sonda nautilus" },
        { "Ask about the clipboard", "action", function()
            -- The last thing copied goes to the Desk's Ask tab as an attachment, to be sent with whatever is typed there (never by itself).
            run("cliphist", { "list" }, function(o)
                local id, txt = (o or ""):match("^(%d+)\t([^\n]*)")
                if not id or txt:find("^%[%[ binary data") then return end
                clip_decode({ id = id }, function(t) ask_attach_from("Clipboard", t or "") end)
            end)
        end, "ai assistant claude ollama question explain paste copied text chat" },
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

    local function urlenc(s) return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)) end
    -- ── units and percentages ──
    -- "5 km to mi", "20 c in f", "2 gb to mib", "15% of 80": worked out here, with nothing to install.
    local UNIT, TEMP = {}, { c = true, f = true, k = true }
    do
        local function add(dim, factor, names) for n in names:gmatch("%S+") do UNIT[n] = { dim = dim, f = factor } end end
        add("len", 1, "m meter meters metre metres"); add("len", 1000, "km kilometer kilometers kilometre kilometres")
        add("len", 0.01, "cm centimeter centimeters"); add("len", 0.001, "mm millimeter millimeters"); add("len", 1e-6, "um micron microns")
        add("len", 1609.344, "mi mile miles"); add("len", 0.9144, "yd yard yards"); add("len", 0.3048, "ft foot feet")
        add("len", 0.0254, "in inch inches"); add("len", 1852, "nmi")
        add("mass", 1, "kg kilogram kilograms kilo kilos"); add("mass", 0.001, "g gram grams"); add("mass", 1e-6, "mg milligram milligrams")
        add("mass", 0.45359237, "lb lbs pound pounds"); add("mass", 0.028349523, "oz ounce ounces"); add("mass", 1000, "t tonne tonnes")
        add("mass", 6.35029318, "st stone")
        add("vol", 1, "l liter liters litre litres"); add("vol", 0.001, "ml milliliter milliliters"); add("vol", 3.785411784, "gal gallon gallons")
        add("vol", 0.946352946, "qt quart quarts"); add("vol", 0.473176473, "pt pint pints"); add("vol", 0.2365882365, "cup cups")
        add("vol", 0.0295735296, "floz"); add("vol", 0.0147867648, "tbsp"); add("vol", 0.00492892159, "tsp")
        add("data", 1, "b byte bytes"); add("data", 0.125, "bit bits"); add("data", 1e3, "kb kilobyte kilobytes"); add("data", 1e6, "mb megabyte megabytes")
        add("data", 1e9, "gb gigabyte gigabytes"); add("data", 1e12, "tb terabyte terabytes"); add("data", 1024, "kib"); add("data", 1048576, "mib")
        add("data", 1073741824, "gib"); add("data", 1099511627776, "tib")
        add("time", 1, "s sec secs second seconds"); add("time", 0.001, "ms millisecond milliseconds"); add("time", 60, "min mins minute minutes")
        add("time", 3600, "h hr hrs hour hours"); add("time", 86400, "d day days"); add("time", 604800, "wk week weeks"); add("time", 31557600, "yr year years")
        add("speed", 1, "m/s mps"); add("speed", 0.277777778, "km/h kph kmh"); add("speed", 0.44704, "mph"); add("speed", 0.514444444, "kn knot knots")
        add("speed", 0.3048, "ft/s")
        add("area", 1, "m2 sqm"); add("area", 1e6, "km2"); add("area", 1e-4, "cm2"); add("area", 1e4, "ha hectare hectares")
        add("area", 4046.8564224, "acre acres"); add("area", 0.09290304, "ft2 sqft"); add("area", 0.00064516, "in2 sqin"); add("area", 2589988.11, "mi2 sqmi")
    end
    local function num_str(v)
        local str = string.format("%.6g", v)
        return str
    end
    local function to_kelvin(v, u) if u == "c" then return v + 273.15 elseif u == "f" then return (v - 32) * 5 / 9 + 273.15 end return v end
    local function from_kelvin(v, u) if u == "c" then return v - 273.15 elseif u == "f" then return (v - 273.15) * 9 / 5 + 32 end return v end
    local function try_units(q)
        local s = q:lower():gsub(",", ""):gsub("°", "")
        -- a percentage: "15% of 80"
        local p, of = s:match("^([%d%.]+)%s*%%%s*of%s+([%d%.]+)$")
        if not p then p, of = s:match("^([%d%.]+)%s*percent%s+of%s+([%d%.]+)$") end
        if p and tonumber(p) and tonumber(of) then
            local str = num_str(tonumber(p) * tonumber(of) / 100)
            return { title = "= " .. str, sub = p .. "% of " .. of .. " · Enter copies", glyph = "%",
                     run = function() run("wl-copy", { "--", str }, function() end) end }
        end
        local n, a, b = s:match("^(%-?[%d%.]+)%s*([%a/%d]+)%s+to%s+([%a/%d]+)$")
        if not n then n, a, b = s:match("^(%-?[%d%.]+)%s*([%a/%d]+)%s+in%s+([%a/%d]+)$") end
        if not n then n, a, b = s:match("^(%-?[%d%.]+)%s*([%a/%d]+)%s+as%s+([%a/%d]+)$") end
        if not n then return nil end
        local v = tonumber(n)
        if not v then return nil end
        local out
        if TEMP[a] and TEMP[b] then
            out = from_kelvin(to_kelvin(v, a), b)
        else
            local ua, ub = UNIT[a], UNIT[b]
            if not ua or not ub or ua.dim ~= ub.dim then return nil end
            out = v * ua.f / ub.f
        end
        local str = num_str(out)
        return { title = "= " .. str .. " " .. b, sub = n .. " " .. a .. " → " .. b .. " · Enter copies", glyph = "=",
                 run = function() run("wl-copy", { "--", str }, function() end) end }
    end

    -- ── the web ──
    -- `?` then what to look for, or `!bang` first: the bang says where (!yt, !gh, !w, !aw …); with none it is DuckDuckGo.
    local BANGS = {
        { "g", "Google", "https://www.google.com/search?q=%s" }, { "ddg", "DuckDuckGo", "https://duckduckgo.com/?q=%s" },
        { "yt", "YouTube", "https://www.youtube.com/results?search_query=%s" }, { "gh", "GitHub", "https://github.com/search?q=%s" },
        { "w", "Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s" }, { "aw", "Arch Wiki", "https://wiki.archlinux.org/index.php?search=%s" },
        { "aur", "AUR", "https://aur.archlinux.org/packages?K=%s" }, { "pkg", "Arch packages", "https://archlinux.org/packages/?q=%s" },
        { "so", "Stack Overflow", "https://stackoverflow.com/search?q=%s" }, { "r", "Reddit", "https://www.reddit.com/search/?q=%s" },
        { "maps", "Maps", "https://www.openstreetmap.org/search?query=%s" }, { "imdb", "IMDb", "https://www.imdb.com/find/?q=%s" },
        { "npm", "npm", "https://www.npmjs.com/search?q=%s" }, { "crates", "crates.io", "https://crates.io/search?q=%s" },
        { "mdn", "MDN", "https://developer.mozilla.org/en-US/search?q=%s" }, { "amazon", "Amazon", "https://www.amazon.com/s?k=%s" },
        { "tr", "Translate", "https://translate.google.com/?sl=auto&tl=en&text=%s&op=translate" },
        { "img", "Images", "https://duckduckgo.com/?q=%s&iax=images&ia=images" }, { "wa", "Wolfram Alpha", "https://www.wolframalpha.com/input?i=%s" },
        { "hn", "Hacker News", "https://hn.algolia.com/?q=%s" }, { "sp", "Spotify", "https://open.spotify.com/search/%s" },
    }
    local BANG = {}
    for _, b in ipairs(BANGS) do BANG[b[1]] = b end
    BANG.wiki, BANG.youtube, BANG.google, BANG.github = BANG.w, BANG.yt, BANG.g, BANG.gh
    local function open_url(url) return function() spawn("xdg-open '" .. url:gsub("'", "'\\''") .. "'") end end
    local function search_web(raw, seq, done)
        local q = trim(raw)
        local bang, rest = q:match("^!(%S+)%s*(.*)$")
        local site = BANG[bang or "ddg"]
        if bang and not site then rest, site = q, BANG.ddg; bang = nil end       -- "!" and nothing known after it: a plain search
        rest = trim(rest or q)
        local out = {}
        if rest == "" then
            -- nothing to look for yet: the places one can ask
            for _, b in ipairs(BANGS) do
                out[#out + 1] = { title = "!" .. b[1] .. "  " .. b[2], sub = "Type !" .. b[1] .. " then what to look for", glyph = "!",
                                  run = function() text.lq = "!" .. b[1] .. " "; focus("lq"); return true end }
            end
            return done(out)
        end
        local looks_url = rest:match("^https?://%S+$") or (not rest:find("%s") and rest:match("^[%w%-]+%.[%a][%w%.%-/%?=&#_%%]*$"))
        if looks_url and not bang then
            local u = rest:match("^https?://") and rest or ("https://" .. rest)
            out[#out + 1] = { title = "Open " .. rest, sub = u, glyph = "W", run = open_url(u) }
        end
        local u = string.format(site[3], urlenc(rest))
        out[#out + 1] = { title = "Search " .. site[2] .. " for “" .. rest .. "”", sub = "Enter opens the results in the browser", glyph = "?", run = open_url(u) }
        if not bang then
            for _, b in ipairs({ BANG.g, BANG.yt, BANG.w }) do
                out[#out + 1] = { title = b[2] .. " for “" .. rest .. "”", sub = "!" .. b[1], glyph = "?", run = open_url(string.format(b[3], urlenc(rest))) }
            end
        end
        done(out)
        -- DuckDuckGo's instant answer (a definition, a calculation, a summary), if it has one: put first when it comes.
        after(350, function()
            if seq ~= S.seq then return end
            run("curl", { "-s", "-m", "4", "https://api.duckduckgo.com/?format=json&no_html=1&skip_disambig=1&q=" .. urlenc(rest) }, function(body, code)
                if seq ~= S.seq or code ~= 0 or not body then return end
                local ok, j = pcall(json.decode, body)
                if not ok or type(j) ~= "table" then return end
                local ans = (j.Answer and j.Answer ~= "") and j.Answer or ((j.AbstractText and j.AbstractText ~= "") and j.AbstractText or nil)
                if not ans then return end
                local url = (j.AbstractURL and j.AbstractURL ~= "") and j.AbstractURL or u
                local row = { title = (j.Heading and j.Heading ~= "" and j.Heading or "Answer"), sub = ans:sub(1, 160), desc = ans, glyph = "i", run = open_url(url) }
                table.insert(out, 1, row)
                done(out)
            end)
        end)
    end

    -- ── open windows ──
    local function window_rows(q, limit, fn)
        run("hyprctl", { "clients" }, function(out, code)
            if code ~= 0 or not out then return fn({}) end
            local list = {}
            local ql = q:lower()
            for _, w in ipairs(parse_clients(out)) do
                local class, title = w.class or "", w.title or ""
                local ws = (w.workspace or ""):match("%((.-)%)") or (w.workspace or ""):match("^(-?%d+)") or ""
                if class ~= "" and (ql == "" or (title .. " " .. class .. " " .. ws):lower():find(ql, 1, true)) then
                    local cl = class:lower()
                    list[#list + 1] = { addr = w.addr, order = (w.focusHistoryID == "0") and -1 or (tonumber(w.focusHistoryID) or 99),
                        row = { title = title ~= "" and title or class, sub = class .. "  ·  workspace " .. ws, glyph = "W", icon = apps_by_class[cl] or cl,
                                run = function() focus_window(w.addr) end } }
                end
            end
            table.sort(list, function(a, b) return a.order < b.order end)
            local rows = {}
            for i, e in ipairs(list) do if i > limit then break end rows[#rows + 1] = e.row end
            fn(rows)
        end)
    end

    -- ── snippets and quicklinks ──
    -- `snippets.json` in the shell's data folder (made with a few examples the first time): "snippets" are text to copy ({date}, {time}, {clipboard}, {uuid} are filled in),
    -- "links" are searches, each with a keyword: `$gh pleamar` opens its url with {query} replaced.
    local SN = { data = nil, path = nil }
    local SN_DEFAULT = {
        snippets = {
            { name = "Today's date", text = "{date}" },
            { name = "Time now", text = "{time}" },
            { name = "Date and time", text = "{date} {time}" },
            { name = "New UUID", text = "{uuid}" },
            { name = "Clipboard, as it is", text = "{clipboard}" },
        },
        links = {
            { name = "GitHub search", keyword = "gh", url = "https://github.com/search?q={query}" },
            { name = "YouTube search", keyword = "yt", url = "https://www.youtube.com/results?search_query={query}" },
            { name = "Arch Wiki", keyword = "aw", url = "https://wiki.archlinux.org/index.php?search={query}" },
        },
    }
    local function snippets_load(fn)
        if SN.data then return fn(SN.data) end
        with_dirs(function(d)
            SN.path = d.data .. "/snippets.json"
            local ok, saved = pcall(sys.ask, "files.read", "snippets.json", "json")
            if ok and type(saved) == "table" and (type(saved.snippets) == "table" or type(saved.links) == "table") then
                SN.data = { snippets = saved.snippets or {}, links = saved.links or {} }
            else
                SN.data = SN_DEFAULT
                pcall(sys.call, "files.write", "snippets.json", SN_DEFAULT)
            end
            fn(SN.data)
        end)
    end
    local function expand(textv, fn)
        local function fill(clip, uuid)
            local out = textv:gsub("{date}", os.date("%Y-%m-%d")):gsub("{time}", os.date("%H:%M")):gsub("{datetime}", os.date("%Y-%m-%d %H:%M"))
            out = out:gsub("{clipboard}", function() return clip or "" end):gsub("{uuid}", function() return uuid or "" end)
            fn(out)
        end
        local function with_uuid(clip)
            if textv:find("{uuid}", 1, true) then
                run("cat", { "/proc/sys/kernel/random/uuid" }, function(u) fill(clip, (u or ""):gsub("%s+$", "")) end)
            else fill(clip, nil) end
        end
        if textv:find("{clipboard}", 1, true) then
            run("wl-paste", { "-n" }, function(c) with_uuid(c or "") end)
        else with_uuid(nil) end
    end
    local function search_snippets(q, done)
        snippets_load(function(data)
            local out = {}
            local kw, rest = q:match("^(%S+)%s+(.+)$")
            for _, l in ipairs(data.links or {}) do
                if kw and l.keyword and kw:lower() == l.keyword:lower() and l.url then
                    out[#out + 1] = { title = (l.name or l.keyword) .. ": " .. rest, sub = "Enter opens it", glyph = "$", run = open_url((l.url:gsub("{query}", urlenc(rest)))) }
                end
            end
            local ql = q:lower()
            for _, sn in ipairs(data.snippets or {}) do
                local name, body = sn.name or "", sn.text or ""
                if ql == "" or name:lower():find(ql, 1, true) or body:lower():find(ql, 1, true) then
                    out[#out + 1] = { title = name, sub = (body:gsub("%s+", " ")):sub(1, 70) .. "  ·  Enter copies", glyph = "$",
                                      run = function() expand(body, function(t) run("wl-copy", { "--", t }, function() end) end) end }
                end
            end
            for _, l in ipairs(data.links or {}) do
                if (not kw or not out[1]) and (ql == "" or (l.name or ""):lower():find(ql, 1, true) or (l.keyword or ""):lower():find(ql, 1, true)) then
                    out[#out + 1] = { title = (l.name or l.keyword or "Link"), sub = "$" .. (l.keyword or "") .. " then what to look for", glyph = "$",
                                      run = function() text.lq = "$" .. (l.keyword or "") .. " "; focus("lq"); return true end }
                end
            end
            out[#out + 1] = { title = "Edit snippets…", sub = SN.path or "snippets.json", glyph = "+", run = function() if SN.path then spawn("xdg-open '" .. SN.path .. "'") end end }
            done(out)
        end)
    end


    -- ── packages (Arch) ──
    -- `+` then a name: the repositories are searched with `pacman -Ss`, or with `paru` or `yay` when there is one, which looks in the AUR too. Enter installs the package in a terminal window of its own: it
    -- may ask for a password, or which of several to take, and the terminal is the progress. The exact name comes first, the official repositories before the AUR, then names that start with what was typed.
    local PK = { tool = nil }
    local function pk_tool(fn)
        if PK.tool then return fn(PK.tool) end
        run("which", { "paru" }, function(_, c1)
            if c1 == 0 then PK.tool = "paru"; return fn("paru") end
            run("which", { "yay" }, function(_, c2)
                if c2 == 0 then PK.tool = "yay"; return fn("yay") end
                run("which", { "pacman" }, function(_, c3)
                    PK.tool = c3 == 0 and "pacman" or "none"
                    fn(PK.tool)
                end)
            end)
        end)
    end
    local function pk_rank(rows, q)
        local needle = q:lower()
        local function group(r) return r.name:lower() == needle and 0 or (r.repo == "aur" and 2 or 1) end
        local function match(r)
            local n = r.name:lower()
            if n:sub(1, #needle) == needle then return 0 end
            if n:find(needle, 1, true) then return 1 end
            return r.desc:lower():find(needle, 1, true) and 2 or 3
        end
        for i, r in ipairs(rows) do r.i = i; r.g = group(r); r.m = match(r) end
        table.sort(rows, function(a, b)
            if a.g ~= b.g then return a.g < b.g end
            if a.m ~= b.m then return a.m < b.m end
            return a.i < b.i
        end)
    end
    local function pk_install(r)
        if r.installed then                                       -- already there: say so, as a notification, instead of doing nothing
            run("notify-send", { "-a", "Vitreus", r.name .. " is already installed" }, function() end)
            return
        end
        local inner = 'tool="$1"; pkg="$2"; if [ "$tool" = pacman ]; then sudo pacman -S -- "$pkg"; else "$tool" -S -- "$pkg"; fi; ec=$?; '
            .. 'if [ "$ec" -eq 0 ]; then notify-send -a Vitreus "$pkg installed"; else notify-send -a Vitreus "$pkg install failed (exit $ec)"; fi; '
            .. 'echo; printf "Press Enter to close… "; read _x; exit "$ec"'
        local args = "_ " .. PK.tool .. " " .. r.name
        spawn('t=$(command -v kitty foot alacritty ghostty konsole xterm | head -n1); [ -n "$t" ] || exit 1; case "$t" in *kitty) "$t" sh -c \'' .. inner .. '\' ' .. args
            .. ' ;; *) "$t" -e sh -c \'' .. inner .. '\' ' .. args .. ' ;; esac')
    end
    local function search_packages(q, seq, done)
        q = trim(q):gsub("^%-+", "")
        if q == "" then return done({}, "Type a package's name to search the repositories and the AUR") end
        if #q < 2 then return done({}, "Keep typing…") end
        text.lmsg = "Searching…"
        after(280, function()
            if seq ~= S.seq then return end
            pk_tool(function(tool)
                if seq ~= S.seq then return end
                if tool == "none" then return done({}, "pacman was not found: Packages is for Arch and its relatives") end
                run(tool, { "--color=never", "-Ss", q }, function(out)
                    if seq ~= S.seq then return end
                    local lines, rows = {}, {}
                    for l in (out or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
                    for i, l in ipairs(lines) do
                        local repo, name, ver = l:match("^([%w%-_.]+)/(%S+)%s+(%S+)")
                        if repo and name:match("^[%w@._+%-]+$") then
                            rows[#rows + 1] = { repo = repo, name = name, ver = ver, installed = l:lower():find("[installed", 1, true) ~= nil or l:lower():find("(installed", 1, true) ~= nil,   -- paru and pacman: [Installed]; yay: (Installed…)
                                                desc = (lines[i + 1] or ""):match("^%s+(.+)$") or "" }
                        end
                    end
                    pk_rank(rows, q)
                    local out_rows = {}
                    for i = 1, math.min(#rows, 40) do
                        local r = rows[i]
                        out_rows[i] = { title = r.name, sub = r.ver, desc = (r.installed and "Installed  ·  " or "") .. r.repo .. (r.desc ~= "" and ("  ·  " .. r.desc:sub(1, 90)) or ""),
                                        glyph = r.installed and "✓" or "+", run = function() return pk_install(r) end }
                    end
                    done(out_rows, "No package matches")
                end)
            end)
        end)
    end

    -- ── what is typed → what is shown ──
    -- The kind of search shown in the header chip; a change of kind also tells the scene (`sr_n`: the Search icon turns a quarter).
    local shown_mode, mode_turns = nil, 0
    local function set_mode(label)
        if label ~= shown_mode then
            if shown_mode ~= nil then mode_turns = mode_turns + 1; fact.sr_n = mode_turns end
            shown_mode = label
        end
        text.lmode = label
    end
    local function search()
        local raw = lq()
        S.last = raw
        S.seq = S.seq + 1
        local seq = S.seq
        local first = raw:sub(1, 1)
        local mode = MODES[first] or "apps"
        local q = trim(MODES[first] and raw:sub(2) or raw)
        if first == "!" then q = trim(raw) end            -- a bang is part of what is said: "!yt lofi"
        S.mode = mode
        local function done(list, msg) if seq == S.seq then show(list, msg) end end
        if mode == "apps" then
            local c = try_units(q) or try_calc(q)
            local list = search_apps(q)
            if c then table.insert(list, 1, c); mode = "calc" end
            set_mode(LABEL[mode])
            fact.lp_on = false
            done(list)
            -- open windows that match, a few, after the apps (they come from Hyprland a moment later)
            if #q >= 2 and not c then
                window_rows(q, 3, function(rows)
                    if seq ~= S.seq or #rows == 0 then return end
                    local all = {}
                    for _, r in ipairs(list) do all[#all + 1] = r end
                    for _, r in ipairs(rows) do all[#all + 1] = r end
                    show(all)
                end)
            end
            return
        end
        set_mode(LABEL[mode])
        fact.lp_on = (mode == "files" or mode == "clipboard" or mode == "wallpapers")
        if mode == "calc" then
            local c = try_units(q) or try_calc(q)
            done(c and { c } or {}, "Type a sum, a conversion (5 km to mi, 20 c to f) or a percentage (15% of 80)")
        elseif mode == "web" then search_web(q, seq, done)
        elseif mode == "windows" then window_rows(q, 30, function(rows) done(rows, "No open window matches") end)
        elseif mode == "snippets" then search_snippets(q, done)
        elseif mode == "packages" then search_packages(q, seq, done)
        elseif mode == "commands" then done(search_commands(q))
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
    on("launch_ctx", function(i)
        local r = S.res[S.start + math.floor(i + 0.5)]
        if r and r.app and cdk_toggle(r.app) ~= nil then render(true) end
    end)
    on("launch_hint", function(i)
        text.lq = ({ "#", ">", ":", "^", "~", "@", "?", "$", "=", "+" })[math.floor(i + 0.5) + 1] or ""
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

-- which graphics card draws the shell (Settings > Display): see logic/gpu.luau
require("logic/gpu")(with_dirs)

-- panels from a key, on the focused monitor: see logic/panel_monitor.luau
require("logic/panel_monitor")()

-- bar position: see logic/bar_position.luau
require("logic/bar_position")()

-- bar size: see logic/bar_size.luau
require("logic/bar_size")()

-- bar layout: see logic/bar_layout.luau
require("logic/bar_layout")()

-- updates: see logic/updates.luau
require("logic/updates")(key, with_dirs)

-- tray: see logic/tray.luau
require("logic/tray")(set_panel)

-- nightmode: see logic/nightmode.luau
require("logic/nightmode")(with_dirs)
-- wallhaven (Settings > Wallpaper): see logic/wallhaven.luau
require("logic/wallhaven")(with_dirs, function() wp_load() end, function(f) wp_apply(f) end, function() wp_refresh() end)
-- idle and sleep: see logic/idle.luau
require("logic/idle")(with_dirs)
-- game mode: see logic/gamemode.luau
require("logic/gamemode")()

-- the audio visualiser (the bottom edge rising into the music): see logic/visualizer.luau
require("logic/visualizer")()

-- add-ons people write (Settings > Widgets > Add-ons): see logic/addons.luau. It hands back what others need of it: their desktop widgets, which
-- Settings > Theme > Pin widgets keeps with the shell's own (the desktop widgets that come with a theme): see logic/theme_widgets.luau
do
    local addons = require("logic/addons")()
    require("logic/theme_widgets")({
        theme = function() if not vtheme.loaded then return nil end local t = vtheme.current(); return t.id, t.name end,
        start = function(dir) exec_on_desktop('vitreus-keep "$HOME/.config/pleamar/shells/vitreus/' .. dir .. '/' .. dir .. '.plm"') end,
        addons = addons.widgets,
    })
end

-- the wallpaper hook for the add-on that frames wallpapers: see logic/wallpaper_hook.luau
require("logic/wallpaper_hook")(wp_apply, function() return wp_cur end)

-- Settings > Theme > Pin wallpaper (a wallpaper that comes with a theme): see logic/theme_wallpaper.luau
require("logic/theme_wallpaper")({
    apply = function(f) wp_apply(f) end,
    cur = function() return wp_cur end,
    files = function() return wp_files end,
    crop = function(fs, done) if wp_cache then wp_crop(fs, "t", 260, 146, done) else done() end end,
    thumb = function(f) local t = wp_cache and crop_path(f, "t"); return (t and wp_made[t] == true) and t or (wpv.is(f) and "" or f) end,
    theme = function() if not vtheme.loaded then return nil end local t = vtheme.current(); return t.id, t.name end,
})

-- how big a notification is (Settings > Notifications): see logic/notif_size.luau
require("logic/notif_size")()

-- Settings > Keybinds.
require("logic/keybinds")()

-- The wallpaper picker (SUPER + B): every wallpaper as a glass hexagon in a tray under the bar. This is the logic side: one
-- ImageMagick pass per wallpaper makes its hexagon picture (already cut to the shape) and reads its
-- colours (the same 32-colour histogram the colour filter uses), the wallpapers are ordered by hue (greys last, by
-- brightness) so the tray reads as a colour ramp, and what was learned is kept in the data folder so this happens
-- once. How big the hexagons are, and where each one goes, is worked out by the scene from how many there are (see
-- the end of vitreus.plm).
;(function()
    local RULE = 10                                     -- which version made the file: an older one is made again (the two before only have their colours read again: `recolour`)
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

    -- What a 32-colour histogram says of a wallpaper: its hue, its saturation and its brightness. The hue is the DOMINANT one, not an average of all of them: a snowy
    -- blue village with orange roofs has two opposite hues, and their average cancels out to an angle that is in neither (it came out pink). Each colour counts by its
    -- area, its saturation and its brightness (so a big pale-blue sky outweighs a few orange roofs, and a bright neon sign outweighs the dark it hangs in); the hue is the
    -- middle of the 60-degree stretch of the wheel that holds the most, as the mean of what lies in it.
    local function colours_of(f, res)
        local total, sat_sum, val_sum = 0, 0, 0
        local entries = {}
        for count, r, g, b in res:gmatch("(%d+):%s*%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)") do
            local n = tonumber(count)
            local h, sa, v = hsv(tonumber(r), tonumber(g), tonumber(b))
            total = total + n
            val_sum = val_sum + n * v
            if v > 0.12 then sat_sum = sat_sum + n * sa end
            entries[#entries + 1] = { h = h, w = n * sa * math.max(v, 0.1) }
        end
        if total <= 0 then return nil end
        local best, most = 0, -1
        for c = 0, 350, 10 do
            local sum = 0
            for _, e in ipairs(entries) do
                if math.abs((e.h - c + 180) % 360 - 180) <= 30 then sum = sum + e.w end
            end
            if sum > most then best, most = c, sum end
        end
        local x, y, wsum = 0, 0, 0
        for _, e in ipairs(entries) do
            if math.abs((e.h - best + 180) % 360 - 180) <= 30 then
                x = x + e.w * math.cos(math.rad(e.h))
                y = y + e.w * math.sin(math.rad(e.h))
                wsum = wsum + e.w
            end
        end
        local hue = (wsum > 1e-6 and (x * x + y * y) > 1e-9) and (math.deg(atan2(y, x)) % 360) or seed_hue(f)
        return { h = hue, s = sat_sum / total, v = val_sum / total }
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
                    local d = colours_of(f, res)
                    if d then G.data[f] = d end
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
        fact.wp_picker_hero_cur = f == wp_cur         -- (the name and its description are written by `describe`, below)
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

    -- Only a wallpaper's colours, again (its hexagon is already made): after the way the hue is worked out changed (the file's rule before this one), two at a time in the
    -- background, and the tray is laid out once more when they are done.
    local function recolour(f, done)
        wpv.src(f, function(src)
            if not src then done() return end
            run("magick", { "-limit", "thread", "1", "-define", "jpeg:size=200x200", src .. "[0]", "-thumbnail", "100x100^", "-gravity", "center", "-extent", "100x100",
                            "-colors", "32", "-format", "%c", "histogram:info:" }, function(res, code)
                if code == 0 and res then
                    local d = colours_of(f, res)
                    if d then G.data[f] = d end
                end
                done()
            end)
        end)
    end
    local function recolour_all()
        if not G.redo then return end
        G.redo = false
        local todo = {}
        for _, f in ipairs(wp_files) do if G.data[f] and G.have[name_of(f)] then todo[#todo + 1] = f end end
        local at, busy = 1, 0
        local function step()
            while busy < 2 and at <= #todo do
                local f = todo[at]
                at = at + 1
                busy = busy + 1
                recolour(f, function()
                    busy = busy - 1
                    if at > #todo and busy == 0 then save(); build() else step() end
                end)
            end
        end
        step()
    end

    local function finish()
        save()
        G.laid = true
        build()
        recolour_all()
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
                    if ok and type(saved) == "table" and (type(saved.rule) == "number" and saved.rule >= RULE - 2 and saved.rule <= RULE) then
                        for f, e in pairs(saved) do
                            if type(e) == "table" and e.h then G.data[f] = e end
                        end
                        G.redo = saved.rule ~= RULE
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
                        recolour_all()
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

    -- ── The cards (the picker's second page) ─────────────────────────────────────────────────────────────────────────
    -- A row of slanted slices with the card in focus opened out (see the scene). The scene holds fifteen slots around the focus (`wp_cards`: a window onto
    -- the list, since every picture would not fit the atlas), each a narrow tall crop of its wallpaper, and two big pictures (`wp_big`: the one in focus and the
    -- one that has just left it, which shrinks back). Shifting through the cards changes the wallpaper as it goes, with a quick fade, once the card has been
    -- still for a moment, and without the colours (Iris) or a video; the wallpaper is only kept (and its colours worked out) when the picker closes, unless Escape
    -- was pressed, which puts the old one back. `wp_prev` (a global, so that the colour watcher can see it) says what is going on.
    local R = 7                              -- slots either side of the focus
    local C = { sel = 0, base = -R, tok = 0, thumbs = 0, flip = 0, big = {}, info = {}, list = {} }
    -- The slots are in drawing order: the left side and the focus from the far end in, then the right side from the far end in again, so that a
    -- slice nearer the focus lies over a farther one.
    local function slot_ix(s) if s <= R then return C.base + s else return C.base + 3 * R + 1 - s end end
    local function strip_path(f) return wp_cache and crop_path(f, "v") or nil end
    local function big_path(f) return wp_cache and crop_path(f, "c") or nil end
    -- What the cards go through: every wallpaper in the picker's order, or, with a colour lit (the same swatches as Settings' wallpaper page, and the same filter),
    -- only the ones of that colour.
    local function card_list()
        local out = {}
        for _, f in ipairs(G.files or {}) do
            local keep = true
            if wp_filter then
                keep = false
                for _, tag in ipairs(wp_tags[f] or {}) do if tag == wp_filter then keep = true break end end
            end
            if keep then out[#out + 1] = f end
        end
        C.list = out
    end
    local function card_rows()
        local files = C.list or {}
        local rows = {}
        local inuse = wp_prev.orig or wp_cur
        for s = 0, 2 * R do
            local ix = slot_ix(s)
            local f = files[ix + 1]
            if f then
                local t = strip_path(f)
                rows[s + 1] = { img = (t and wp_made[t] == true) and t or "", ix = ix, cur = f == inuse, ok = true }
            else
                rows[s + 1] = { img = "", ix = ix, cur = false, ok = false }
            end
        end
        model.wp_cards = rows
        local big = {}
        for k = 1, 2 do
            local e = C.big[k]
            local f = e and files[e.ix + 1]
            if f then
                local t = big_path(f)
                big[k] = { img = (t and wp_made[t] == true) and t or "", ix = e.ix, cur = f == inuse, ok = true }
            else
                big[k] = { img = "", ix = 0, cur = false, ok = false }
            end
        end
        model.wp_big = big
    end
    -- The strips (small, so every wallpaper gets one), the ones near the focus first, a few at a time, so the shell stays quick.
    local function card_thumbs()
        if not wp_cache or not G.files or C.thumbs > 0 then return end
        local todo = {}
        for i, f in ipairs(G.files) do
            if wp_made[crop_path(f, "v")] == nil then todo[#todo + 1] = { f = f, d = math.abs(i - 1 - C.sel) } end
        end
        if #todo == 0 then return end
        table.sort(todo, function(a, b) return a.d < b.d end)
        local at = 1
        local function chunk()
            if at > #todo or not fact.wp_picker_open then C.thumbs = 0; return end
            local part = {}
            for k = at, math.min(at + 3, #todo) do part[#part + 1] = todo[k].f end
            at = at + 4
            wp_crop(part, "v", 96, 216, function()
                card_rows()
                chunk()
            end)
        end
        C.thumbs = 1
        chunk()
    end
    -- What the focus is: its colour (from the picture's own analysis, brightened so it reads on any wallpaper), and its size, kind and weight.
    local function hsv_rgb(h, s, v)
        local c = v * s
        local hp = (h % 360) / 60
        local x = c * (1 - math.abs(hp % 2 - 1))
        local r, g, b = 0, 0, 0
        if hp < 1 then r, g = c, x elseif hp < 2 then r, g = x, c elseif hp < 3 then g, b = c, x
        elseif hp < 4 then g, b = x, c elseif hp < 5 then r, b = x, c else r, b = c, x end
        local m = v - c
        return r + m, g + m, b + m
    end
    -- Where a description goes: the cards' words under the focused card, or the hexagons' under the one the pointer is on (the same words, the same accent). `still`
    -- says the thing described is still the one in view when a slow answer comes back; `pos` and `n` its place in the list and the length of it.
    local DEST_CARD = { name = "wp_card_name", info = "wp_card_info", r = "wp_card_cr", g = "wp_card_cg", b = "wp_card_cb",
        still = function(f) return C.list and C.list[C.sel + 1] == f end, pos = function() return C.sel + 1 end, n = function() return #(C.list or {}) end }
    local DEST_HEX = { name = "wp_picker_hero_name", info = "wp_hex_info", r = "wp_hex_cr", g = "wp_hex_cg", b = "wp_hex_cb",
        still = function(f) local h = tonumber(fact.wp_picker_hot); return h ~= nil and h >= 0 and G.files ~= nil and G.files[math.floor(h + 0.5) + 1] == f end,
        pos = function() return math.floor((tonumber(fact.wp_picker_hot) or 0) + 0.5) + 1 end, n = function() return #(G.files or {}) end }
    local function describe(f, ix, n, dest)
        local d = G.data[f]
        if d then
            local r, g, b = hsv_rgb(d.h, 0.35 + 0.4 * math.min(1, d.s * 1.5), 0.95)
            fact[dest.r], fact[dest.g], fact[dest.b] = r, g, b
        end
        text[dest.name] = stem(f)
        local ext = (name_of(f):match("%.(%w+)$") or ""):upper()
        local pos = string.format("%d of %d", ix + 1, n)
        local have = C.info[f]
        if have then text[dest.info] = have .. pos; return end
        text[dest.info] = (ext ~= "" and ext .. "  ·  " or "") .. pos
        local function done(parts)
            C.info[f] = #parts > 0 and (table.concat(parts, "  ·  ") .. "  ·  ") or ""
            if dest.still(f) then text[dest.info] = C.info[f] .. string.format("%d of %d", dest.pos(), dest.n()) end
        end
        local function weight(parts, fn)
            run("stat", { "-L", "-c", "%s", f }, function(sz)
                local bytes = tonumber((sz or ""):match("%d+"))
                if bytes then parts[#parts + 1] = bytes >= 1048576 and string.format("%.1f MB", bytes / 1048576) or string.format("%d KB", math.floor(bytes / 1024 + 0.5)) end
                fn()
            end)
        end
        if wpv.is(f) then
            -- A video: its size on the screen and how long it runs (ffprobe), and its weight.
            run("ffprobe", { "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "default=nw=1", f }, function(out)
                local w, h, dur = (out or ""):match("width=(%d+)"), (out or ""):match("height=(%d+)"), tonumber((out or ""):match("duration=([%d%.]+)"))
                local parts = { "VIDEO" }
                if w and h then parts[#parts + 1] = w .. " × " .. h end
                if dur then parts[#parts + 1] = string.format("%d:%02d", math.floor(dur / 60), math.floor(dur % 60)) end
                weight(parts, function() parts[#parts + 1] = ext; done(parts) end)
            end)
            return
        end
        run("magick", { "identify", "-ping", "-format", "%w %h", f .. "[0]" }, function(out)
            local w, h = (out or ""):match("(%d+)%s+(%d+)")
            local parts = {}
            if w then parts[#parts + 1] = w .. " × " .. h end
            weight(parts, function() if ext ~= "" then parts[#parts + 1] = ext end; done(parts) end)
        end)
    end
    local function card_focus(f, ix, n) describe(f, ix, n, DEST_CARD) end
    -- The pointer on a hexagon: the same description of that wallpaper under the hexagons.
    on("fact:wp_picker_hot", function(v)
        if type(v) ~= "number" or v < 0 then return end
        local ix = math.floor(v + 0.5)
        local f = G.files and G.files[ix + 1]
        if f then describe(f, ix, #G.files, DEST_HEX) end
    end)
    -- The focus's big picture: into the slot that is not the one it just left, made if it is not yet (and shown when it is).
    local function card_big(f, ix, instant)
        local last = C.big[C.flip == 0 and 1 or 2]
        if last and last.ix == ix then return end
        C.flip = 1 - C.flip
        C.big[C.flip + 1] = { ix = ix }
        card_rows()
        local t = big_path(f)
        if t and wp_made[t] == nil then
            -- Made once the focus has stayed here for a moment (not for every card passed over); `C.tok` is no use for this, the preview changes it at once.
            after(instant and 0 or 90, function()
                if C.sel ~= ix or not fact.wp_picker_open then return end
                wp_crop({ f }, "c", 768, 432, function() card_rows() end)
            end)
        end
    end
    local function card_publish()
        fact.wp_card_base = C.base
        fact.wp_card_sel = C.sel
        card_rows()
        local files = C.list or {}
        local f = files[C.sel + 1]
        if f then card_focus(f, C.sel, #files) else text.wp_card_name = ""; text.wp_card_info = "No wallpaper of this colour" end
    end
    local function card_preview()
        C.tok = C.tok + 1
        local t = C.tok
        after(170, function()
            if t ~= C.tok or not fact.wp_picker_open then return end
            local f = C.list and C.list[C.sel + 1]
            if not f or f == wp_prev.shown then return end
            wp_prev.on, wp_prev.shown = true, f
            -- A video in use plays over awww's picture (mpvpaper), so nothing tried through awww could be seen: it is stopped for as long as the cards are in use (put
            -- back, or the kept one started, when the picker closes). A video card is tried as its poster, a still frame of it.
            if wpv.cur and not wp_prev.stopped then
                wp_prev.stopped = true
                exec_on_desktop("pkill -x mpvpaper")
            end
            wp_apply(f, { "--transition-type", "fade", "--transition-duration", "0.35", "--transition-fps", "60" }, nil, nil, true)
        end)
    end
    local function card_set(i)
        if C.closing then return end
        local n = #(C.list or {})
        if n == 0 then return end
        C.sel = math.max(0, math.min(n - 1, i))
        C.base = C.sel - R
        wp_prev.touched = true
        wp_prev.on = true                    -- from the first step the watcher leaves awww alone, until the picker closes
        card_big(C.list[C.sel + 1], C.sel)
        card_publish()
        card_preview()
    end
    -- Which page it was left on (the hexagons or the cards) is where it opens next time, and the time after a restart.
    do
        local ok, saved = pcall(sys.ask, "files.read", "wallpaper-view.json", "json")
        if ok and type(saved) == "table" and saved.page == 1 then fact.wp_pg = 1 end
    end
    on("fact:wp_pg", function(v)
        pcall(sys.call, "files.write", "wallpaper-view.json", { page = (tonumber(v) or 0) > 0.5 and 1 or 0 })
    end)
    -- A swatch pressed (the handler on the wallpaper page sets the filter; this one runs a moment after it): the cards narrow to that colour, keeping the focus where it
    -- is if that one is still among them. Nothing is tried on the desktop for it.
    on("wp_filter_set", function()
        after(50, function()
            if not fact.wp_picker_open then return end
            local cur = C.list[C.sel + 1]
            card_list()
            C.sel = 0
            for i, f in ipairs(C.list) do if f == cur then C.sel = i - 1 break end end
            C.base = C.sel - R
            C.big, C.flip = {}, 0
            local f = C.list[C.sel + 1]
            if f then card_big(f, C.sel, true) end
            card_publish()
        end)
    end)
    local function cards_open()
        wp_prev.orig, wp_prev.shown, wp_prev.on, wp_prev.touched, wp_prev.cancel, wp_prev.stopped = wp_cur, nil, false, false, false, false
        C.closing = false
        card_list()
        C.sel = 0
        for i, f in ipairs(C.list or {}) do if f == wp_cur then C.sel = i - 1 break end end
        C.base = C.sel - R
        C.tok = C.tok + 1
        C.big, C.flip = {}, 0
        local f = C.list and C.list[C.sel + 1]
        if f then card_big(f, C.sel, true) end
        card_publish()
        card_thumbs()
    end
    -- The picker closes: what the cards left showing is kept (its colours are worked out now, with a plain fade over what is there), or, for Escape,
    -- the old wallpaper comes back. A close that starts here (Enter, a press on the focused card, Escape on the cards) says so itself: a fact the logic
    -- sets does not reach `on("fact:...")`, and the wallpaper would stay as a try that is never made the one in use. One that starts in the scene (a press
    -- outside, Escape on the hexagons) arrives by that handler. Either way it is done once (the flags are cleared as they are read).
    local function cards_close()
        C.tok = C.tok + 1                    -- a try still waiting for its moment is dropped
        local touched, cancel, orig = wp_prev.touched, wp_prev.cancel, wp_prev.orig
        wp_prev.touched, wp_prev.cancel, wp_prev.stopped = false, false, false
        if touched then
            local target = cancel and orig or (C.list and C.list[C.sel + 1])
            local function done() wp_prev.on, wp_prev.shown = false, nil end
            -- Not quiet even for putting the old one back: that starts its video again if it was one (the colours are not worked out twice: it is the one they were
            -- worked out for, and `iris_last_wp` still says so).
            if target then
                wp_apply(target, { "--transition-type", "fade", "--transition-duration", "0.35", "--transition-fps", "60" }, done, nil, false)
            else
                done()
            end
        end         -- (untouched: nothing was tried, so `wp_prev.on` is already off; and a second call, when both ways of closing arrive, finds nothing to do)
    end
    on("fact:wp_picker_open", function(v) if not v then cards_close() end end)
    wp_prev.close = cards_close             -- for the other places that close the picker from the logic (the overview opening)
    local function card_done(cancel)
        if C.closing then return end
        wp_prev.cancel = cancel
        if cancel then
            fact.wp_picker_open = false
            cards_close()
            return
        end
        -- Keeping one: a ripple runs out of the card first (the scene's, off `wp_card_rip`: the card's own edge), and the picker goes when it has run.
        C.closing = true
        C.rip = (C.rip or 0) + 1                -- (counted here: a fact the logic has not set may not read back)
        fact.wp_card_rip = C.rip
        after(760, function()
            C.closing = false
            if not fact.wp_picker_open then return end
            fact.wp_picker_open = false
            cards_close()
        end)
    end
    on("wp_card_step", function(d) card_set(C.sel + math.floor((tonumber(d) or 0) + 0.5)) end)
    on("wp_card_go", function(i)
        i = math.floor((tonumber(i) or 0) + 0.5)
        if i == C.sel then card_done(false) else card_set(i) end
    end)
    on("wp_card_pick", function() card_done(false) end)
    on("wp_card_cancel", function() card_done(true) end)

    on("wp_picker_toggle", function()
        local opening = not fact.wp_picker_open
        if opening then fact.wp_picker_leaving = false; set_panel("none"); if G.laid then build() end end
        fact.wp_picker_open = opening
        if opening then cards_open() else cards_close() end          -- after the fact: the thumbnails are only made while the picker is open; and a close from here (Super+B) is not seen by the fact's handler
    end)

    -- A hexagon was pressed: its wallpaper blooms out of it. `wp_picker_px`, `wp_picker_py` are where it is on the screen, from the
    -- bottom left, which is where awww counts from. Then the tray leaves, and the desktop is what is left.
    on("wp_picker_pick", function(i)
        local f = G.files and G.files[i + 1]
        if not f then return end
        wp_prev.on, wp_prev.touched = false, false          -- a hexagon was chosen: whatever the cards were showing is not kept or put back
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
        wp_prev.on, wp_prev.touched = false, false
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
-- A card for each of the five workspaces, and on it a live picture of each of its windows. The pictures come from pleamar's `thumbnails`
-- service (the compositor's own copy of each window, 30 times a second while the overview is open; the scene reads them straight from
-- the service into `wthumbs`, so the logic never touches a frame). `ovw` is built in the same order as that list: slot n is thumbnail n, and
-- it says which workspace the window is on, where it lies in that workspace's grid and what it is called (from `hyprctl clients`, matched to
-- the service's windows by app and title). A window the compositor is not drawing (another workspace) keeps its last picture; one that has
-- never been seen shows its icon. Pictures are asked for (`thumbnails.want`) for a moment after arriving on a workspace, so those windows
-- have one for the next time, and live (`thumbnails.live`) for as long as the overview is open.
;(function()
    local PER = 9
    local addrs = {}
    local open = false
    local last_sig = ""
    local TH = {}                            -- the service's windows, in its order: { id, title, app, picture, stale }
    local TH_sig = ""
    local clients = {}                       -- the windows as last read from `hyprctl clients`; a move edits this at once, so its card does not wait for Hyprland
    local moving = false                     -- a window was dropped on another workspace and Hyprland has not caught up: do not read the old place back yet
    local front_ids = {}                     -- the service ids of the windows on the workspace in front
    local last_open = false                  -- what `set_open` last did

    -- The windows on the five workspaces, each matched to its entry in the service's list (by app and title; then by app alone).
    local function match()
        local per = { {}, {}, {}, {}, {} }
        local elsewhere = 0
        for _, w in ipairs(clients) do
            if w.mapped == "1" then
                local id = tonumber((w.workspace or ""):match("^(-?%d+)")) or 0
                if id >= 1 and id <= 5 then table.insert(per[id], w) else elsewhere = elsewhere + 1 end
            end
        end
        local taken = {}
        local function find(w, strict)
            local class, title = (w.class or ""):lower(), w.title or ""
            for t, e in ipairs(TH) do
                if not taken[t] and (e.app or ""):lower() == class and (not strict or (e.title or "") == title) then return t end
            end
        end
        local by = {}                        -- thumbnail index -> { w, ws }
        local front = tonumber(fact["ws.active"]) or 1
        front_ids = {}
        for id = 1, 5 do
            -- In a fixed order, so that windows do not swap places as you use them.
            table.sort(per[id], function(a, b) return (a.addr or "") < (b.addr or "") end)
            for k, w in ipairs(per[id]) do
                local t = find(w, true) or find(w, false)
                if t then
                    taken[t] = true
                    if k <= PER then by[t] = { w = w, ws = id, k = k, n = math.min(#per[id], PER) } end
                    if id == front and TH[t].id then front_ids[#front_ids + 1] = TH[t].id end
                end
            end
        end
        return per, by, elsewhere
    end

    local function render()
        local per, by, elsewhere = match()
        local rows, sig = {}, {}
        addrs = {}
        for id = 1, 5 do fact["ov_cnt." .. (id - 1)] = #per[id] end
        fact.ov_else = elsewhere
        for slot = 1, 45 do
            local m = by[slot]
            if m then
                local w = m.w
                local class = (w.class or ""):lower()
                local title = w.title
                if title == nil or title == "" then title = (w.class ~= nil and w.class ~= "") and w.class or "Window" end
                local gc = m.n <= 1 and 1 or (m.n <= 4 and 2 or 3)
                local gr = math.max(1, math.ceil(m.n / gc))
                local e = TH[slot]
                rows[slot] = { ws = m.ws - 1, gx = (m.k - 1) % gc, gy = math.floor((m.k - 1) / gc), gc = gc, gr = gr, title = title,
                               active = w.focusHistoryID == "0", used = true, icon = apps_by_class[class] or class, snap = (e.picture or "") ~= "" }
                addrs[slot] = w.addr
            else
                rows[slot] = { ws = 0, gx = 0, gy = 0, gc = 1, gr = 1, title = "", active = false, used = false, icon = "application-x-executable", snap = false }
            end
            local r = rows[slot]
            sig[slot] = r.ws .. "," .. r.gx .. "," .. r.gy .. "," .. r.gc .. "," .. r.gr .. "|" .. r.title .. "|" .. tostring(r.active) .. "|" .. tostring(r.used) .. "|" .. tostring(r.snap) .. "|" .. r.icon
        end
        local joined = table.concat(sig, "\n")
        if joined ~= last_sig then
            last_sig = joined
            model.ovw = rows
        end
    end
    local function read_clients(fn)
        run("hyprctl", { "clients" }, function(out, code)
            if code ~= 0 then return end
            clients = parse_clients(out)
            if fn then fn() end
        end)
    end
    local function refresh()
        if moving then return end
        read_clients(function() if open and not moving then render() end end)
    end

    -- The service's list: a change in which windows there are (or in whether they have a picture) rebuilds the cards; a new frame does not.
    sys.watch("thumbnails", function(t)
        local list = (type(t) == "table" and t.list) or {}
        local parts = {}
        for i, e in ipairs(list) do parts[i] = (e.id or "") .. "|" .. (e.app or "") .. "|" .. (e.title or "") .. "|" .. ((e.picture or "") ~= "" and "1" or "0") end
        local s = table.concat(parts, "\n")
        TH = list
        if s ~= TH_sig then
            TH_sig = s
            if open then render() end
        end
    end)

    -- Pictures of the windows on the workspace in front, for a moment: so each has one when its workspace is not in front.
    local want_gen = 0
    local function want_front(ms)
        if open then return end
        want_gen = want_gen + 1
        local g = want_gen
        read_clients(function()
            if g ~= want_gen or open then return end                     -- a newer ask came while this one read: that one decides
            match()
            if #front_ids == 0 then return sys.call("thumbnails.want") end   -- nothing here to copy: let go of the last workspace's windows
            THUMB_UNTIL = os.time() + math.ceil(ms / 1000) + 4           -- these captures are ours: the screen-sharing light ignores them
            sys.call("thumbnails.want", front_ids)
            after(ms,function() if g == want_gen and not open then sys.call("thumbnails.want") end end)
        end)
    end

    -- Opening and closing: live pictures while it is open. Called from the scene's own changes (the bar button, a press outside) through the
    -- fact, and from `ov_toggle` below: a change the logic makes itself is not told back to it.
    local function set_open(v)
        if v == open and v == last_open then return end
        open = v
        last_open = v
        if v then
            want_gen = want_gen + 1
            last_sig = ""
            THUMB_UNTIL = os.time() + 86400                              -- live pictures all the while it is open
            sys.call("thumbnails.live", "all")
            refresh()
        else
            THUMB_UNTIL = os.time() + 4
            sys.call("thumbnails.live")
            want_front(1200)
        end
    end
    on("fact:ov_open", function(v) set_open(v == 1 or v == true) end)
    every(1000, function() if open then refresh() end end)
    -- Arriving on a workspace: its windows are copied a moment later, when the switch has settled.
    local was_front = nil
    sys.watch("workspaces", function(w)
        if was_front ~= nil and w.active ~= was_front then after(700, function() want_front(1500) end) end
        was_front = w.active
    end)
    after(4000, function() want_front(2000) end)
    on("ov_toggle", function()
        if not on_hyprland then                     -- pleamar-wm has its own overview (Super+Tab): the button and the launcher toggle that one
            wm_get("overview", function(v) wm_say("fact overview " .. (v == 1 and "false" or "true")) end)
            return
        end
        if fact.ov_open then
            fact.ov_open = false
            set_open(false)
            return
        end
        fact.wp_picker_open = false
        if wp_prev.close then wp_prev.close() end
        if tostring(fact.panel) ~= "none" then fact.panel = "none" end
        fact.ov_open = true
        set_open(true)
        read_clients(render)
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

    -- The network card's lines under the graph: the connection (and its signal), the Bluetooth adapter and what is connected to it, and the
    -- address of the interface the traffic goes over. The first two are told by the services; the address is asked of nmcli when the interface changes.
    local LK = { kind = "none", name = "", strength = 0, bt = nil, iface = nil, ip = "" }
    local function link_show()
        -- the dashboard's line between the network's name and its badge: how strong, and the address
        local parts = {}
        if LK.kind == "wifi" then parts[#parts + 1] = string.format("%d%%", LK.strength) end
        if LK.ip ~= "" then parts[#parts + 1] = LK.ip end
        text.sm_netinfo = table.concat(parts, "  ·  ")
        text.sm_link = LK.kind == "wifi" and ((LK.name ~= "" and LK.name or "Wi-Fi") .. string.format("  ·  %d%%", LK.strength))
            or LK.kind == "wired" and "Wired  ·  connected" or "Not connected"
        local b = LK.bt
        if not b or b.present == false then text.sm_bt = "No adapter"
        elseif not b.powered then text.sm_bt = "Off"
        else
            local names = {}
            for _, dv in ipairs(b.devices or {}) do if dv.connected then names[#names + 1] = dv.name or dv.address end end
            text.sm_bt = #names > 0 and table.concat(names, ", ") or "On  ·  nothing connected"
        end
    end
    sys.watch("network", function(n)
        -- the service gives 0 to 1 in practice (its docs say 0 to 100): both are taken, as the dashboard's bars do
        local s = n.strength or 0
        if s <= 1 then s = s * 100 end
        LK.kind, LK.name, LK.strength = n.kind or "none", n.name or "", math.floor(s + 0.5)
        link_show()
    end)
    sys.watch("bluetooth", function(b) LK.bt = b; link_show() end)
    local function ip_read(iface)
        text.sm_ip = ""
        LK.ip = ""
        link_show()
        if not iface or iface == "" then return end
        run("nmcli", { "-t", "-f", "IP4.ADDRESS", "device", "show", iface }, function(out, code)
            if code ~= 0 or iface ~= LK.iface then return end
            for line in (out or ""):gmatch("[^\n]+") do
                local v = line:match("^IP4%.ADDRESS[^:]*:(.*)$")
                if v then
                    local ip = (v:gsub("\\", ""):gsub("/%d+$", ""))
                    text.sm_ip = ip
                    LK.ip = ip
                    link_show()
                    return
                end
            end
        end)
    end

    local function on_line(line)
        local ok, d = pcall(json.decode, line)
        if not ok or type(d) ~= "table" or not d.cpu then return end
        if d.info then
            text.sm_host = d.info.host or ""
            text.sm_cpu_name = d.info.cpu or ""
            text.sm_kernel = d.info.kernel or ""
            text.sm_user = d.info.user or ""
            text.sm_name = (d.info.name or "") ~= "" and d.info.name or (d.info.user or "")
            if demo_on then text.sm_user = "user"; text.sm_name = "user" end
            text.sm_distro = d.info.distro or ""
            text.sm_avatar = d.info.avatar or ""
            text.sm_face = d.info.face or ""
            fact.sm_has_avatar = (d.info.avatar or "") ~= ""
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
        if nt.iface ~= LK.iface then LK.iface = nt.iface; ip_read(nt.iface) end
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
        -- The page, or the dashboard's System tile (pages/dashboard.plm).
        local want = (fact.panel == "settings" and fact.set_page == "pg_sys") or fact.dash_open == true
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
    on("fact:dash_open", refresh)
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
-- Caps Lock, Num Lock and the keyboard layout: see logic/lockkeys.luau (it fills LOCKKEYS.layout, called by watch_urgent's listener)
LOCKKEYS = { show = show_level }     -- (the volume drawer's rows: the lock keys have the third, "m")
require("logic/lockkeys")()

-- ── A screenshot, as a card ───────────────────────────────────────────────────────────────────────────
-- Capture (logic/capture_power.luau) says `text shot_path <file>` and `emit shot_done` once a picture is taken. It comes up in the volume's and the
-- notifications' drawer (low, out of the right frame) with a big thumbnail, its name, and Open / Copy text / Ask / Delete (the text ones only when
-- tesseract is installed, `shot_ocr`). It waits like the volume does: a notification on screen goes back in the queue until the card has gone.
do
    local SHOT = { path = nil, n = 0, gen = 0 }
    local function shot_hide()
        if nt_queue.osd == "shot" then nt_queue.set_osd("none") end
        nt_queue.hold = false
        if nt_queue.pump then nt_queue.pump() end
    end
    local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
    run("which", { "tesseract" }, function(_, code) fact.shot_ocr = code == 0 end)
    on("shot_done", function()
        local path = text.shot_path
        if type(path) ~= "string" or path == "" then return end
        SHOT.path = path
        with_dirs(function(d)
            local out = d.cache .. "/shot.png"
            run("mkdir", { "-p", d.cache }, function()
                run("magick", { path .. "[0]", "-auto-orient", "-thumbnail", "394x222^", "-gravity", "center", "-extent", "394x222", out }, function(_, code)
                    if code ~= 0 then
                        -- no thumbnail: say it the plain way
                        exec_on_desktop("notify-send -a Vitreus 'Screenshot copied and saved' " .. quote(path))
                        return
                    end
                    SHOT.n = SHOT.n + 1
                    text.shot_imgpath = out .. "?" .. SHOT.n
                    text.shot_name = path:match("([^/]+)$") or path
                    if nt_queue.osd == "notif" and nt_now and nt_now.n then
                        table.insert(nt_queue, 1, nt_now.n)
                        nt_now = nil
                    end
                    osd_gen = osd_gen + 1
                    SHOT.gen = osd_gen
                    nt_queue.hold = true
                    fact.osd_kind = "shot"
                    nt_queue.set_osd("shot")
                    after(10000, function() if SHOT.gen == osd_gen then shot_hide() end end)
                end)
            end)
        end)
    end)
    on("shot_close", function() osd_gen = osd_gen + 1; shot_hide() end)
    on("shot_act", function(i)
        local path = SHOT.path
        if not path then return end
        if i == 0 then
            exec_on_desktop("xdg-open " .. quote(path))
        elseif i == 1 then
            exec_on_desktop("tesseract " .. quote(path) .. " stdout 2>/dev/null | wl-copy && notify-send -a Vitreus 'Text copied' 'The text of the screenshot is on the clipboard.'")
        elseif i == 2 then
            run("tesseract", { path, "stdout" }, function(out)
                if type(out) == "string" and out:match("%S") then ask_attach_from("Screenshot text", out) end
            end)
        elseif i == 3 then
            exec_on_desktop("rm -f " .. quote(path))
        end
        osd_gen = osd_gen + 1
        shot_hide()
    end)
end

-- privacy lights: see logic/privacy.luau
require("logic/privacy")()

-- corner docks: see logic/dock.luau
require("logic/dock")()

-- shelf: see logic/shelf.luau
require("logic/shelf")(with_dirs)

-- pad: see logic/pad.luau
require("logic/pad")()

-- draw: see logic/draw.luau
require("logic/draw")()

-- term: see logic/term.luau
require("logic/term")(key)

-- ask: see logic/ask.luau
require("logic/ask")()
-- clipboard history and pins, for the Desk's Clip tab: see logic/clipboard.luau
require("logic/clipboard")(with_dirs)
-- the charger, read from the kernel instead of pleamar's 20 s battery poll: see logic/charger.luau
require("logic/charger")()
-- Demo mode: ~/.config/vitreus/demo exists -> a made-up battery (69 %, on battery) and the user shown as "user" (globals: this chunk is at Luau's limit of locals)
demo_on = false
run("printenv", { "HOME" }, function(out, code)
    local h = (out or ""):gsub("%s+$", "")
    if code ~= 0 or h == "" then return end
    run("stat", { h .. "/.config/vitreus/demo" }, function(_, c)
        if c ~= 0 then return end
        demo_on = true
        fact.demo = true
        text.sm_user = "user"; text.sm_name = "user"
        text.bat_state = "On battery · 5 h 12 min left"
    end)
end)

-- The panel sound (Settings > Theme): Synoptik's own click, once each time a panel opens. The OSDs (volume, notifications) are not panels.
do
    local snd_on, home, last_at = true, nil, 0
    local file = "sounds.json"
    local ok, saved = pcall(sys.ask, "files.read", file, "json")
    if ok and type(saved) == "table" and type(saved.panel) == "boolean" then snd_on = saved.panel end
    fact.snd_on = snd_on
    run("printenv", { "HOME" }, function(out) home = (out or ""):gsub("%s+$", "") end)
    on("snd_toggle", function()
        snd_on = not snd_on
        fact.snd_on = snd_on
        pcall(sys.call, "files.write", file, { panel = snd_on })
    end)
    local function chime()
        if not snd_on or not home or home == "" then return end
        local now = os.clock()
        if now - last_at < 0.25 then return end   -- one sound at a time, however fast the panels change
        last_at = now
        run("pw-play", { "--volume", "0.25", home .. "/.config/pleamar/shells/vitreus/assets/panel.wav" }, function() end)
    end
    local quiet = { none = true, volume = true, notif = true }
    on("fact:panel", function(v) if not quiet[tostring(v)] then chime() end end)
    on("fact:desk_open", function(v) if v == true then chime() end end)   -- the Desk is not one of the panels: it has its own fact
    on("fact:ax_chime", function() chime() end)   -- an add-on's drawer: the logic opens it, so the scene counts its openings
end
