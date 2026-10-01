-- The wallpaper transition's logic. It is told what was picked (`text target`, and `ox`, `oy` for where the wave starts) and then `go`:
-- it makes the new picture at the screen's size, shows it through the honeycomb, has awww switch to it at once when it covers the
-- screen, and takes the overlay away. While one is on, another `go` is ignored.

local busy = false
local home = ""
local counter = 0
run("printenv", { "HYPRLAND_INSTANCE_SIGNATURE" }, function(out, code) fact.wp_dec = (code == 0 and (out or "") ~= "") and 1 or 0 end)
run("printenv", { "HOME" }, function(out) home = (out or ""):gsub("%s+$", "") end)

local function finish()
    run("awww", { "img", text.target, "--transition-type", "none" }, function()
        -- awww has to have drawn it before the overlay goes, or the old wallpaper shows for a frame
        after(350, function()
            fact.active = false
            busy = false
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
