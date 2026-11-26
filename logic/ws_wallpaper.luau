-- One wallpaper per workspace (Settings > Wallpaper, the slideshow card's second row).
--
-- While it is on, the wallpaper chosen (the picker, the launcher, Random, the slideshow, one changed from outside) belongs to the workspace in view,
-- and going to another workspace fades in that workspace's own. A workspace that never had one keeps the wallpaper as it is. The whole desktop
-- follows the workspace that has the keyboard: the glass, the parallax and Iris's colours all work from one wallpaper.
--
-- Kept in `ws-wallpapers.json`: { on = bool, map = { ["3"] = "/path" } }. Turning it off keeps the map, so turning it on again brings them back.
--
--   apply(path, how)   put a wallpaper up (wp_apply)
--   current()          the wallpaper in use (wp_cur)
-- It answers `note(path)`, which the wallpaper page calls whenever the wallpaper changes.
return function(apply, current)
    local S = { on = false, map = {}, ws = nil, applying = nil, seq = 0 }

    local function save()
        pcall(sys.call, "files.write", "ws-wallpapers.json", { on = S.on, map = S.map })
    end
    do
        local ok, t = pcall(sys.ask, "files.read", "ws-wallpapers.json", "json")
        if ok and type(t) == "table" then
            S.on = t.on == true
            if type(t.map) == "table" then
                for k, v in pairs(t.map) do if type(v) == "string" and v ~= "" then S.map[tostring(k)] = v end end
            end
        end
    end
    fact.wp_ws = S.on

    --  The workspace in view changed: its own wallpaper comes in, a moment later (a run of switches only brings the last one).
    local function bring(ws)
        if not S.on or ws == nil then return end
        local want = S.map[tostring(ws)]
        if not want or want == current() then return end
        S.seq = S.seq + 1
        local my = S.seq
        after(220, function()
            if my ~= S.seq or not S.on or S.ws ~= ws then return end
            if want == current() then return end
            S.applying = want
            apply(want, { "--transition-type", "fade", "--transition-duration", "0.5", "--transition-fps", "60" })
            -- (the change reaches `note` through the page, which must not take it as a new choice; it is let go once awww has had time to show it)
            after(3000, function() if S.applying == want then S.applying = nil end end)
        end)
    end

    sys.watch("workspaces", function(w)
        local ws = w and w.active
        if ws == nil or ws == S.ws then return end
        S.ws = ws
        bring(ws)
    end)

    on("wp_ws_toggle", function()
        S.on = not S.on
        fact.wp_ws = S.on
        -- Turned on: the wallpaper in use is this workspace's from now on.
        if S.on and S.ws ~= nil then
            local cur = current()
            if cur and cur ~= "" then S.map[tostring(S.ws)] = cur end
        end
        save()
    end)

    return function(path)
        if not S.on or S.ws == nil or not path or path == "" then return end
        if path == S.applying then S.applying = nil return end
        if S.map[tostring(S.ws)] == path then return end
        S.map[tostring(S.ws)] = path
        save()
    end
end
