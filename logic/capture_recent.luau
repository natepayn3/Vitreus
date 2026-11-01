-- Recent screenshots, for the strip at the foot of the Controls drawer's Capture window: the newest four pictures in ~/Pictures/Screenshots, each as a small
-- picture (made with magick into the cache, `capr/`, kept by a hash of its path and its time). The list is read when the window opens (the scene says
-- `emit capr_refresh`) and when a shot is saved. A press opens the picture; it can also be dragged out onto another program (the scene's `carries`).
return function(with_dirs, set_panel)
    local N = 4
    local items = {}                                    -- { path, name }
    local thumbs, making = {}, {}                       -- path#mtime -> the file of its picture (false: could not be made); the ones being made
    local render
    local function lua_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local function hash(str)
        local h = 5381
        for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
        return string.format("%08x", h)
    end
    local function make_thumb(it)
        if thumbs[it.key] ~= nil or making[it.key] then return end
        making[it.key] = true
        with_dirs(function(d)
            local dir = (d.cache:gsub("/wp$", "")) .. "/capr"
            local out = dir .. "/" .. hash(it.key .. "#128") .. ".jpg"
            run("mkdir", { "-p", dir }, function()
                run("magick", { "-limit", "thread", "1", "-define", "jpeg:size=256x160", it.path .. "[0]", "-auto-orient", "-thumbnail", "128x80^",
                                "-gravity", "center", "-extent", "128x80", "-quality", "85", out }, function(_, code)
                    making[it.key] = nil
                    thumbs[it.key] = code == 0 and out or false
                    if code == 0 then render() end
                end)
            end)
        end)
    end
    render = function()
        for k = 0, N - 1 do
            local it = items[k + 1]
            local th = it and thumbs[it.key] or nil
            text["capr." .. k .. ".path"] = it and it.path or ""
            text["capr." .. k .. ".name"] = it and it.name or ""
            text["capr." .. k .. ".thumb"] = th or ""
            fact["capr." .. k .. ".has"] = it ~= nil
            fact["capr." .. k .. ".thumbed"] = th ~= nil and th ~= false
            if it then make_thumb(it) end
        end
        fact.capr_n = #items
    end
    local function refresh()
        -- newest first; the time goes in the key, so a picture drawn over and saved again gets a new thumbnail
        with_dirs(function(d)
            local dir = d.home .. "/Pictures/Screenshots"
            run("ls", { "-lt", "--time-style=+%s", dir }, function(out)
                items = {}
                if type(out) == "string" then
                    for line in out:gmatch("[^\r\n]+") do
                        local mt, name = line:match("^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)%s+(.+)$")
                        local ext = name and name:match("%.(%w+)$")
                        ext = ext and ext:lower()
                        if mt and (ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "webp") and #items < N then
                            local path = dir .. "/" .. name
                            items[#items + 1] = { path = path, name = name, key = path .. "@" .. mt }
                        end
                    end
                end
                render()
            end)
        end)
    end
    on("capr_refresh", refresh)
    on("capr_open", function(k)
        local it = type(k) == "number" and items[k + 1] or nil
        if not it then return end
        -- in Snap, to draw on it again (see CAPTURE_SNAP_FILE in capture_power.luau); with a path that cannot go into its script, in the viewer
        if not (CAPTURE_SNAP_FILE and CAPTURE_SNAP_FILE(it.path)) then
            exec_on_desktop("xdg-open " .. lua_quote(it.path))
            set_panel("none")
        end
    end)
    refresh()
end
