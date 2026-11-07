-- The Desk's Camera (pages/desk_camera.plm): the tablet's own camera, which took the place of the desktop's webcam bubble. ffmpeg reads the first
-- camera's MJPEG, cuts the middle square, mirrors it if asked, and writes the latest frame over one file in the runtime folder (atomically, so it
-- is never read half written); the scene is told to load it again about fifteen times a second. The camera is open only while the Desk shows
-- the Camera app: it is started when the Desk comes out on it or changes to it, and stopped when it changes away or goes (`desk_shown`,
-- `desk_gone`, which the scene sends whoever opened it). Mirroring and the look are kept in desk-camera.json. A photo is the frame on screen, copied to
-- Pictures/myPad and put on the Shelf.
return function()
    -- The looks: ffmpeg's own filters, after the square is cut (and mirrored). A photo is taken with its look.
    local LOOKS = {
        [0] = "",
        "hue=s=0",                                                                       -- Mono
        "hue=s=0,eq=contrast=1.7:brightness=-0.06",                                      -- Noir
        "colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131",            -- Sepia
        "edgedetect=low=0.08:high=0.25,negate",                                          -- Sketch
        "scale=40:40:flags=neighbor,scale=480:480:flags=neighbor",                       -- Pixel
        "hue=s=0,pseudocolor=p=turbo",                                                   -- Thermal
        "eq=saturation=2.3:contrast=1.15",                                               -- Pop
        "rgbashift=rh=-8:bh=8:gv=3,noise=alls=12:allf=t",                                -- Glitch
    }
    local cfg = { mirror = true, look = 0 }
    do
        local ok, s = pcall(sys.ask, "files.read", "desk-camera.json", "json")
        if ok and type(s) == "table" then
            if type(s.mirror) == "boolean" then cfg.mirror = s.mirror end
            if type(s.look) == "number" and LOOKS[s.look] then cfg.look = s.look end
        end
    end
    fact.cam_mirror = cfg.mirror
    fact.cam_filter = cfg.look
    local frame_dir, frame_file, raw_file, proc, n, tries, got = nil, nil, nil, nil, 0, 0, false
    -- the looks again, for the previews: the same, sized for a 120 px picture (the pixels and the shift are smaller)
    local PREVIEW = {
        [0] = "null", "hue=s=0", "hue=s=0,eq=contrast=1.7:brightness=-0.06",
        "colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131",
        "edgedetect=low=0.08:high=0.25,negate", "scale=14:14:flags=neighbor,scale=120:120:flags=neighbor",
        "hue=s=0,pseudocolor=p=turbo", "eq=saturation=2.3:contrast=1.15", "rgbashift=rh=-3:bh=3:gv=1",
    }
    local pv_busy, pv_n = false, 0
    local function showing() return fact.desk_open == true and tonumber(fact.desk_tab) == 8 end
    local start
    local function stop()
        if proc then kill(proc, "term"); proc = nil end
        fact.cam_on = false
        fact.cam_live = false
        fact.cam_pv_on = false
        text.cam_path = ""
    end
    start = function()
        if proc or not frame_dir then return end
        local look = LOOKS[cfg.look] or ""
        -- two pictures from one run: the frame with its look (fifteen a second), and a small one without it (one a second), which the looks'
        -- previews are made from
        local fc = "[0:v]crop=480:480" .. (cfg.mirror and ",hflip" or "") .. ",split[m][r];[m]" .. (look ~= "" and look or "null") .. ",fps=15[o];[r]scale=120:120,fps=1[p]"
        got = false
        fact.cam_on = true
        fact.cam_live = false
        text.cam_msg = "Starting the camera…"
        local mine
        mine = spawn("ffmpeg", { "-loglevel", "error", "-f", "v4l2", "-input_format", "mjpeg", "-framerate", "30", "-video_size", "640x480", "-i", "/dev/video0",
                                 "-filter_complex", fc,
                                 "-map", "[o]", "-q:v", "5", "-f", "image2", "-update", "1", "-atomic_writing", "1", "-y", frame_file,
                                 "-map", "[p]", "-q:v", "4", "-f", "image2", "-update", "1", "-atomic_writing", "1", "-y", raw_file },
            function() end,
            function()
                if proc ~= mine then return end
                proc = nil
                fact.cam_live = false
                -- it stopped while it should be running (the camera is busy, or was just let go of): tried again a few times, then given up
                if showing() then
                    tries = tries + 1
                    if tries <= 4 then
                        text.cam_msg = "The camera is busy: trying again…"
                        after(1500, function() if showing() then start() end end)
                    else
                        fact.cam_on = false
                        text.cam_msg = "No camera could be opened"
                    end
                else
                    fact.cam_on = false
                end
            end)
        proc = mine
    end
    local function want()
        if showing() then tries = 0; start() else stop() end
    end
    run("printenv", { "XDG_RUNTIME_DIR" }, function(out)
        local rt = ((out or ""):gsub("%s+$", ""))
        if rt == "" then rt = "/tmp" end
        frame_dir = rt .. "/vitreus-deskcam"
        frame_file = frame_dir .. "/frame.jpg"
        raw_file = frame_dir .. "/raw.jpg"
        run("mkdir", { "-p", frame_dir }, function() want() end)
    end)
    -- the frame, read again about fifteen times a second while the camera runs; the first one that is there turns the picture on
    every(66, function()
        if not proc or not frame_file then return end
        n = n + 1
        if not got then
            if n % 4 == 0 then
                run("test", { "-s", frame_file }, function(_, c)
                    if c == 0 and proc then got = true; fact.cam_live = true; text.cam_msg = "" end
                end)
            end
            return
        end
        text.cam_path = frame_file .. "?" .. n
    end)
    every(2000, function()
        if not (proc and got and raw_file) or pv_busy then return end
        pv_busy = true
        local parts, outs = { "[0:v]split=9" }, {}
        for f = 0, 8 do parts[1] = parts[1] .. "[s" .. f .. "]" end
        local chain = { parts[1] }
        for f = 0, 8 do chain[#chain + 1] = "[s" .. f .. "]" .. PREVIEW[f] .. "[o" .. f .. "]" end
        local args = { "-loglevel", "error", "-y", "-i", raw_file, "-filter_complex", table.concat(chain, ";") }
        for f = 0, 8 do
            outs[f] = frame_dir .. "/look" .. f .. ".jpg"
            for _, a in ipairs({ "-map", "[o" .. f .. "]", "-frames:v", "1", "-q:v", "4", outs[f] }) do args[#args + 1] = a end
        end
        run("ffmpeg", args, function(_, c)
            pv_busy = false
            if c ~= 0 or not proc then return end
            pv_n = pv_n + 1
            for f = 0, 8 do text["cam_pv." .. f] = outs[f] .. "?" .. pv_n end
            fact.cam_pv_on = true
        end)
    end)
    on("desk_shown", want)
    on("desk_gone", want)
    on("cam_flip", function()
        cfg.mirror = not cfg.mirror
        fact.cam_mirror = cfg.mirror
        pcall(sys.call, "files.write", "desk-camera.json", cfg)
        if proc then stop(); after(400, function() if showing() then start() end end) end
    end)
    on("cam_filter_set", function(f)
        f = tonumber(f)
        if not f or not LOOKS[f] or f == cfg.look then return end
        cfg.look = f
        fact.cam_filter = f
        pcall(sys.call, "files.write", "desk-camera.json", cfg)
        if proc then stop(); after(300, function() if showing() then start() end end) end
    end)
    on("cam_snap", function()
        if not (proc and got and frame_file) then return end
        run("xdg-user-dir", { "PICTURES" }, function(out)
            local pics = ((out or ""):gsub("%s+$", ""))
            if pics == "" then return end
            local dir = pics .. "/myPad"
            local file = dir .. "/photo-" .. os.date("%Y%m%d-%H%M%S") .. ".jpg"
            run("mkdir", { "-p", dir }, function()
                run("cp", { frame_file, file }, function(_, c)
                    if c ~= 0 then text.cam_msg = "The photo could not be saved"; return end
                    if desk_shelf_add then desk_shelf_add(file) end
                    text.cam_msg = "Saved to Pictures/myPad, and on the Shelf"
                    after(2500, function() if text.cam_msg == "Saved to Pictures/myPad, and on the Shelf" then text.cam_msg = "" end end)
                end)
            end)
        end)
    end)
end
