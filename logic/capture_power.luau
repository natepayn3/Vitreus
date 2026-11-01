-- Capture (screenshots and screen recording) and Power (the session, and the power profile): the two tiles of the
-- Controls drawer's third row, and their windows. Nothing here is drawn by this file: it starts the programs, and reports
-- the state of the recording and of the profile as facts.
return function(set_panel)
    local function lua_quote(s) return (string.format("%q", s):gsub("\\\n", "\\n")) end
    local function spawn(cmd)                      -- start it on the desktop, detached from this shell
        exec_on_desktop(cmd)
    end
    local function sh(script) return "sh -c '" .. script .. "'" end   -- the scripts below hold no single quote

    -- The drawer has to be out of the way before anything is captured.
    local function after_closed(fn)
        set_panel("none")
        after(450, fn)
    end

    -- ── Screenshots ──────────────────────────────────────────────────────────────────────────────────────────────
    -- Region (0) opens Snap (snap/snap.plm): the screen frozen, a part of it picked and drawn on, then copied or saved; a saved one comes up as the
    -- card (`shot_done`, in vitreus.luau), told by Snap itself. Only one Snap at a time: a press while it is open does nothing. It is put on the
    -- focused monitor (`--screen`) and takes that one (SNAP_OUTPUT): left to choose, pleamar opened it on the other monitor, over a picture of this one.
    -- Without Hyprland the focused monitor is the one under the mouse: pleamar-wm's `mon`, named from its `desktop` file.
    -- And in the theme's typeface: the font setup bin/vitreus-fonts makes for the shell (nothing for Space Grotesk). Snap reads the look itself.
    -- The whole screen (1) opens Snap too (SNAP_FULL=1): the picture shown smaller with the bar under it, to draw on, copy or save like a region.
    local function start_snap(full, wait, extra)
        spawn(sh('p="$HOME/.config/pleamar/shells/vitreus/snap/snap.plm"; pgrep -f "pleamar --scene $p" > /dev/null && exit 0; '
            .. 'export SNAP_NOT_BEFORE=$(( $(date +%s%3N) + ' .. wait .. ' )); '
            .. (full and 'export SNAP_FULL=1; ' or '') .. extra
            .. 'o=$(hyprctl -j monitors 2> /dev/null | jq -r ".[] | select(.focused) | .name" 2> /dev/null | head -n 1); if [ -z "$o" ]; then i=$(pleamar --say wm "get mon" 2>/dev/null); o=$(grep "^monitor " "${PLEAMAR_SOCKETS:-/nonexistent}/desktop" 2>/dev/null | sed -n "$((${i:-0} + 1))p" | cut -d" " -f2); fi; '
            .. 'fc=$("$HOME/.config/pleamar/shells/vitreus/bin/vitreus-fonts" "${XDG_DATA_HOME:-$HOME/.local/share}/pleamar/vitreus" 2> /dev/null) && [ -n "$fc" ] && export FONTCONFIG_FILE="$fc"; '
            .. 'if [ -n "$o" ]; then SNAP_OUTPUT="$o" exec pleamar --scene "$p" --no-hud --screen "$o"; else exec pleamar --scene "$p" --no-hud; fi'))
    end
    -- An old screenshot opened in Snap again (the Capture window's recent pictures): the whole-screen layout, with this file as the picture (SNAP_FILE: snap.luau
    -- puts it on a canvas of the screen's shape instead of taking the screen). False when the path could not go safely into the script (the caller opens it another way).
    CAPTURE_SNAP_FILE = function(path)
        if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("[%$`\"'\\%c]") then return false end
        set_panel("none")
        start_snap(true, 0, 'export SNAP_FILE="' .. path .. '"; ')
        return true
    end
    on("shot", function(mode)
        -- Snap is started at once, while the drawer closes: it takes the picture only once the drawer is gone (SNAP_NOT_BEFORE, the 450 ms
        -- `after_closed` waits; the whole screen waits 800, since its picture shows the drawer's closing ripple if it is taken sooner), and pleamar's own start (~220 ms) happens meanwhile instead of after.
        if mode == 0 or mode == 1 then
            set_panel("none")
            start_snap(mode == 1, mode == 1 and 800 or 450, "")
            return
        end
        after_closed(function()
            spawn(sh('d="$HOME/Pictures/Screenshots"; mkdir -p "$d"; f="$d/screenshot_$(date +%F_%H-%M-%S).png"; '
                .. 'grim "$f" && wl-copy < "$f" && pleamar --say vitreus "text shot_path $f" && pleamar --say vitreus "emit shot_done"'))
        end)
    end)

    -- ── Screen recording ─────────────────────────────────────────────────────────────────────────────────────────
    -- `wf-recorder`, video only (or with the microphone, when `rec_mic` is on, or the system sound, when `rec_sys` is), into ~/Videos. The whole-screen one names the focused monitor (`-o`): with two, wf-recorder
    -- otherwise asks which one on a terminal that is not there, and records nothing. Pressing the tile's button again (or Stop) ends it cleanly, which is
    -- what makes the file playable. Whether it is running is asked of `pgrep`, so a recording started from anywhere counts.
    local seen = nil                                -- when it was first seen running
    local starting_until = 0                        -- after a start, until when to keep looking: slurp may take a while to pick the region
    local function rec_show(running)
        fact.rec_on = running
        if running then
            starting_until = 0
            seen = seen or os.time()
            local n = os.time() - seen
            text.rec_time = string.format("%d:%02d", n // 60, n % 60)
        else
            seen = nil
            text.rec_time = ""
        end
    end
    local function rec_poll()
        run("pgrep", { "-x", "wf-recorder" }, function(_, code) rec_show(code == 0) end)
    end
    local function rec_start(mode)
        if fact.rec_on then return end
        starting_until = os.time() + 120
        after_closed(function()
            local a = fact.rec_sys and ' -a"$(pactl get-default-sink).monitor"'   -- the system sound: the monitor of the default output
                or (fact.rec_mic and " -a" or "")                          -- -a: the default input (the microphone) goes into the file too
            local pick = (mode == 0) and ('g=$(slurp) || exit 0; wf-recorder' .. a .. ' -g "$g" -f "$f"') or ('wf-recorder' .. a .. ' -o "$(hyprctl monitors | awk "/^Monitor /{n=\\$2} /focused: yes/{print n; exit}")" -f "$f"')
            spawn(sh('d="$HOME/Videos"; mkdir -p "$d"; f="$d/recording_$(date +%F_%H-%M-%S).mp4"; '
                .. pick .. '; if [ -s "$f" ]; then notify-send -a Vitreus "Recording saved" "$f"; else notify-send -a Vitreus "Recording failed" "Nothing was saved"; fi'))
            after(1500, rec_poll)
        end)
    end
    local function rec_stop()
        run("pkill", { "-INT", "-x", "wf-recorder" }, function() after(800, rec_poll) end)
    end
    on("rec_start", rec_start)
    on("rec_stop", rec_stop)
    on("rec_mic_toggle", function() fact.rec_mic = not fact.rec_mic; if fact.rec_mic then fact.rec_sys = false end end)
    on("rec_sys_toggle", function() fact.rec_sys = not fact.rec_sys; if fact.rec_sys then fact.rec_mic = false end end)
    -- The tile's button: stop if recording, else record a region.
    on("rec_toggle", function()
        if fact.rec_on then rec_stop() else rec_start(0) end
    end)
    every(1000, function() if fact.rec_on then rec_show(true) end end)
    -- Asking `pgrep` is a process started each time, so it is only done while it matters: a recording is on (to see it end),
    -- or the Controls drawer, where the Capture tile shows it, is open; and once as that drawer opens.
    every(2000, function() if fact.rec_on or fact.panel == "controls" then rec_poll() end end)
    -- and every second for a while after a start, so the bar's dot is there as soon as the recording is, not at the next click.
    every(1000, function() if not fact.rec_on and os.time() < starting_until then rec_poll() end end)
    on("fact:panel", function(v) if v == "controls" then rec_poll() end end)
    rec_poll()

    -- ── The session ──────────────────────────────────────────────────────────────────────────────────────────────
    -- 0 lock, 1 sleep, 2 log out, 3 restart, 4 power off. The scene only says so (`pow_press`) after the button has
    -- been held for one second, so nothing here has to ask again.
    local user = nil
    run("printenv", { "USER" }, function(out) user = (out or ""):gsub("%s+$", "") end)
    local function do_it(i)
        if i == 0 then spawn('pleamar --say lockscreen "fact locked true"')
        elseif i == 1 then run("systemctl", { "suspend" }, function() end)
        elseif i == 2 then
            -- Leave through the compositor, so the session ends by itself and SDDM gets its helper back and shows the login screen again.
            -- (`loginctl terminate-user` kills SDDM's own helper along with the session: SDDM calls that a crash and shows nothing.)
            -- Asked now, not read from `on_hyprland`: the sandbox keeps a global's value from when the file loaded (false, before `printenv` answered).
            run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code)
                if code == 0 and (out or "") ~= "" then run("hyprctl", { "dispatch", "hl.dsp.exit()" }, function() end)
                else
                    -- niri leaves by its own action (the button was held for a second: no need for its "are you sure" box); pleamar-wm by being ended
                    run("printenv", { "NIRI_SOCKET" }, function(o, c)
                        if c == 0 and (o or "") ~= "" then run("niri", { "msg", "action", "quit", "--skip-confirmation" }, function() end)
                        else run("pkill", { "-TERM", "-x", "pleamar-wm" }, function() end) end
                    end)
                end
            end)
        elseif i == 3 then run("systemctl", { "reboot" }, function() end)
        elseif i == 4 then run("systemctl", { "poweroff" }, function() end) end
    end
    on("pow_press", function(i)
        i = math.floor(i + 0.5)
        -- The button shatters first (about a second in the scene): the window closes and the action runs once the shards have flown.
        after(900, function() set_panel("none") end)
        after(1000, function() do_it(i) end)
    end)

    -- ── The power profile ────────────────────────────────────────────────────────────────────────────────────────
    -- power-profiles-daemon, through `powerprofilesctl`: 0 power saver, 1 balanced, 2 performance, -1 not there.
    local NAMES = { "power-saver", "balanced", "performance" }
    local function prof_poll()
        run("powerprofilesctl", { "get" }, function(out, code)
            if code ~= 0 then fact.pow_prof = -1; return end
            local now = (out or ""):gsub("%s+$", "")
            fact.pow_prof = -1
            for i, n in ipairs(NAMES) do if n == now then fact.pow_prof = i - 1 end end
        end)
    end
    on("pow_prof_set", function(i)
        local name = NAMES[math.floor(i + 0.5) + 1]
        if not name then return end
        run("powerprofilesctl", { "set", name }, function() prof_poll() end)
    end)
    -- Only while the Controls panel (where its tile is) is open, at most every ten seconds: `powerprofilesctl` is a Python program,
    -- a seventh of a second each time it starts.
    local prof_at = 0
    every(2000, function()
        if fact.panel == "controls" and os.time() - prof_at >= 10 then prof_at = os.time(); prof_poll() end
    end)
    prof_poll()
end
