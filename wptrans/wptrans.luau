-- The wallpaper transition's logic. It is told what was picked (`text target`, and `ox`, `oy` for where the wave starts) and then `go`:
-- it makes the new picture at the screen's size, shows it through the honeycomb, has awww switch to it at once when it covers the
-- screen, and takes the overlay away. While one is on, another `go` is ignored.

local busy = false
local home = ""
local counter = 0
run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code) fact.wp_dec = (code == 0 and (out or "") ~= "") and 1 or 0 end)
run("printenv", { "HOME" }, function(out) home = (out or ""):gsub("%s+$", "") end)

-- A dissolve leaves the picture and the shader's work on the card (~115 MB more, for good: emptying `src` does not give it back). A while after the
-- last one the scene starts again, clean: it quits and its keeper starts it again in ~3 s. 35 s, so that it has always been up over the 30 s within
-- which the keeper counts a stop as a quick one (twenty of those and it gives up), and so that picking several wallpapers in a row restarts it once.
local REFRESH_MS = 35000
local done_n = 0
local function refresh_later()
    done_n = done_n + 1
    local mine = done_n
    after(REFRESH_MS, function()
        if mine ~= done_n or busy then return end
        run("pleamar", { "--say", "wptrans", "quit" }, function() end)
    end)
end

local function finish()
    run("awww", { "img", text.target, "--transition-type", "none" }, function()
        -- awww has to have drawn it before the overlay goes, or the old wallpaper shows for a frame
        after(350, function()
            fact.active = false
            busy = false
            refresh_later()
        end)
    end)
end

on("go", function()
    local path = text.target
    if busy or path == "" or home == "" then return end
    busy = true
    local dir = home .. "/.cache/pleamar/wptrans"
    run("awww", { "query" }, function(out)
        local geo = (out or ""):match("%d+x%d+") or "1920x1080"
        run("mkdir", { "-p", dir }, function()
            counter = counter + 1
            local file = dir .. "/new.jpg"
            -- what awww would show: the picture cropped to fill the screen; then at the size the scene's image is declared at
            run("magick", { path .. "[0]", "-resize", geo .. "^", "-gravity", "center", "-extent", geo,
                            "-resize", "1920x1080!", "-quality", "92", file }, function(_, code)
                if code ~= 0 then busy = false return end
                text.src = file .. "?" .. counter
                after(150, function()           -- a moment for the picture to be read in
                    fact.active = true
                    after(math.floor(fact.dur * 1000) + 80, finish)
                end)
            end)
        end)
    end)
end)

-- Hyprland only: a right press on the wallpaper opens the desktop editor (desktopedit/), started if it is not running (it leaves a while after it is closed:
-- see desktopedit.luau). Once started it is told to open as soon as it answers, not after a fixed wait.
local function open_when_up(mon, tries)
    run("pleamar", { "--say", "desktopedit", "fact emon " .. mon, "fact open true" }, function(out, code)
        local up = code == 0 and (out or ""):find("?", 1, true) ~= 1
        if not up and tries < 30 then after(300, function() open_when_up(mon, tries + 1) end) end
    end)
end
on("edit_req", function()
    local mon = math.floor((tonumber(fact.mmon) or 0) + 0.5)
    run("pleamar", { "--say", "desktopedit", "fact emon " .. mon, "fact open true" }, function(_, code)
        if code ~= 0 then
            run("sh", { "-c", 'PATH="$HOME/.local/bin:$PATH" vitreus-keep "$HOME/.config/pleamar/shells/vitreus/desktopedit/desktopedit.plm" >/dev/null 2>&1 &' }, function() end)
            open_when_up(mon, 0)
        end
    end)
end)
