-- Night mode: a warm tint over the whole screen, by hand or on a schedule (Settings > Night mode). It is done with
-- `hyprsunset`, Hyprland's own blue-light filter: a daemon that hands the compositor a colour transform, so nothing is
-- re-rendered. It is started when it is first needed (in identity, so it changes nothing by itself), and driven with
-- `hyprctl hyprsunset temperature <K>` and `identity`. Without it installed, this falls back to a Hyprland screen
-- shader (a few lines of GLSL, `hyprctl eval` to set `decoration:screen_shader`), which works but makes Hyprland rebuild
-- its buffers on every change, and flickers while a blurred panel is open. The temperature is what the slider says; the
-- schedule is here, not in hyprsunset, so the same page drives both. Only what this file set is ever cleared. Kept in
-- night.json.
return function(with_dirs)
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
            -- Its output goes nowhere: `run` waits for the pipe it reads to close, and the daemon (which logs to stdout) kept it open for
            -- as long as it lived, so the callback never came and the first toggle after a login did nothing (the daemon was started, never told).
            run("sh", { "-c", "setsid -f hyprsunset -i >/dev/null 2>&1 </dev/null" }, function() after(300, fn) end)
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
end
