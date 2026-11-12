-- The panels opened from a key (the launcher, Settings, the desk) open on the monitor that has the focus. A press on the bar or on a notch
-- already says which copy of the scene it came from (`panel_scr = screen.index`); a key bind does not, so the panel came out wherever the
-- last one had been. The scene's own rules for these events are gone (vitreus.plm): here the focused monitor is asked of Hyprland first.
-- Which copy is on which monitor is learnt from the scene itself (`describe` says each copy's size), and matched by size; where two monitors
-- are the same size, Hyprland's order of monitors is what the copies follow when they are made. It is asked at each press (about 30 ms):
-- which copies are open changes without any monitor changing (the bar moved to another monitor, the others' copies closed or opened).
return function()
    local copies = nil       -- { { i = copy index, w = , h = } }: the open copies, from `describe`

    -- `describe` makes the renderer drop its composed frame and walk every zone of the scene, a stall of tens of milliseconds at each key press. What it says
    -- changes only when a copy opens or closes or a monitor changes, so it is asked again only when one of those facts has.
    local seen_sig = nil
    local function signature()
        local t = {}
        for k = 0, 3 do
            t[#t + 1] = tostring(fact["bar_c" .. k]) .. ":" .. tostring(text["screen." .. k .. ".name"]) .. ":" .. tostring(fact["screen." .. k .. ".width"]) .. "x" .. tostring(fact["screen." .. k .. ".height"])
        end
        t[#t + 1] = tostring(fact.bar_others)
        return table.concat(t, ",")
    end

    local function learn(done)
        local sig = signature()
        if copies ~= nil and seen_sig == sig then return done() end
        run("pleamar", { "--say", "vitreus", "describe" }, function(out)
            local list = {}
            -- Each open copy's header: "main (screen N) · panel W×H". The first copy says no "(screen 0)" when the bar was started with its monitors by
            -- name (`--screen`, bin/vitreus-keep since #67): a header with no number is copy 0.
            for line in (out or ""):gmatch("[^\n]+") do
                if line:match("^main[ ·]") then
                    local w, h = line:match("(%d+)×(%d+)")
                    if w then list[#list + 1] = { i = tonumber(line:match("^main %(screen (%d+)%)")) or 0, w = tonumber(w), h = tonumber(h) } end
                end
            end
            copies = list
            seen_sig = sig
            done()
        end)
    end

    -- The copy on the focused monitor, or nil when it cannot be told.
    local function focused_copy(done)
        hypr_monitors(0, function(out, code)
            if code ~= 0 or not out then return done(nil) end
            local ok, list = pcall(json.decode, out)
            if not ok or type(list) ~= "table" then
                -- Under pleamar-wm `hyprctl monitors` is its own text, one block a monitor ("Monitor DP-2 (ID 1):", "2560x1440@165 at 1440x730",
                -- "scale: 1.00", "focused: yes"), the size already turned for a rotated monitor: read that, and the copy is matched by size as below.
                list = {}
                for name, id, body in (out .. "\n\n"):gmatch("Monitor (%S+) %(ID (%d+)%):(.-)\n\n") do
                    local w, h = body:match("(%d+)x(%d+)@")
                    list[#list + 1] = { name = name, id = tonumber(id), width = tonumber(w), height = tonumber(h), transform = 0, scale = 1,
                                        focused = body:match("focused: yes") ~= nil }
                end
                if #list == 0 then return done(nil) end
            end
            local names, foc = {}, nil
            for _, j in ipairs(list) do
                names[#names + 1] = tostring(j.name)
                if j.focused then foc = j end
            end
            if not foc then return done(nil) end
            local t = foc.transform or 0
            local sc = (foc.scale and foc.scale > 0) and foc.scale or 1
            local w, h = math.floor((foc.width or 0) / sc + 0.5), math.floor((foc.height or 0) / sc + 0.5)
            if t == 1 or t == 3 or t == 5 or t == 7 then w, h = h, w end
            local function pick()
                local hit, n = nil, 0
                for _, c in ipairs(copies or {}) do
                    if math.abs(c.w - w) < 2 and math.abs(c.h - h) < 2 then hit, n = c.i, n + 1 end
                end
                if n == 1 then return done(hit) end
                -- the copies are made in Hyprland's order of monitors
                done(type(foc.id) == "number" and foc.id < math.max(#(copies or {}), #names) and foc.id or nil)
            end
            -- With one copy open (the bar on one monitor) the panel goes to that one; with none told apart (a scene with no copy per monitor) the toggle is the
            -- plain one, on the copy that is open (the bar's monitor switched off and on again left `panel_scr` on a copy that has closed since: the panels
            -- opened from a key were drawn there, unseen).
            local function pick_or_plain()
                if not copies or #copies == 0 then
                    for k = 0, 3 do
                        if fact["bar_c" .. k] == true and (text["screen." .. k .. ".name"] or "") ~= "" then return done(k) end
                    end
                    return done(nil)
                end
                if #copies == 1 then return done(copies[1].i) end
                pick()
            end
            learn(pick_or_plain)
        end)
    end

    local function same(a, b) return a ~= nil and b ~= nil and math.floor(a + 0.5) == math.floor(b + 0.5) end

    -- `is_open` / `open(bool)` for the thing; it closes when it is open on the focused monitor, moves there when it is open on another.
    local function toggle_here(is_open, open)
        -- (not `on_hyprland`: a module sees the globals as they were when it was required, and that one is only known later. Without Hyprland
        -- `hyprctl monitors -j` is pleamar-wm's text, not JSON, and the copy is not known: the toggle is then the plain one.)
        focused_copy(function(i)
            if i == nil then return open(not is_open()) end
            if is_open() then
                if same(fact.panel_scr, i) then return open(false) end
                open(false)
                after(220, function() fact.panel_scr = i; open(true) end)
                return
            end
            fact.panel_scr = i
            open(true)
        end)
    end

    local function panel_toggle(name)
        toggle_here(function() return tostring(fact.panel) == name end, function(v)
            if v then fact.panel = name elseif tostring(fact.panel) == name then fact.panel = "none" end
        end)
    end
    on("launch_toggle", function() panel_toggle("launch") end)
    on("settings_toggle", function() panel_toggle("settings") end)
    on("controls_toggle", function() panel_toggle("controls") end)
    on("desk_toggle", function()
        toggle_here(function() return fact.desk_open == true end, function(v)
            if v then fact.desk_tab = tonumber(fact.desk_start) or 6 end   -- it opens on Home, or the tool chosen in Customize
            fact.desk_open = v
            if v and snd_hook and snd_hook.chime then snd_hook.chime() end   -- set from the logic, so the fact handler does not hear it
        end)
    end)
end
