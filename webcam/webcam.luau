-- The webcam's logic: it runs `ffmpeg` on the first camera while the pane is on, and keeps where the pane is and how big. Kept in this scene's own folder
-- (~/.local/share/pleamar/webcam), in webcam.json (a file that is not there is written, so that there is one to edit):
--   x, y      the pane's top left in the desktop (all the monitors together), or -1 for the bottom right corner of the first monitor
--   scale     how big, 0.5 to 2 times 240
--   mirror    whether the picture is mirrored, as a mirror is (true by default)
-- The camera is only open while `shown` is true, and `shown` is false every time this starts.
local BASE = 240
local cfg = { x = -1, y = -1, scale = 1, mirror = true }
do
    local ok, saved = pcall(sys.ask, "files.read", "webcam.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
        cfg.scale = math.max(0.5, math.min(2, cfg.scale))
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "webcam.json", cfg)
    end
end
local function save() pcall(sys.call, "files.write", "webcam.json", cfg) end

fact.shown = false
fact.gs = cfg.scale
fact.gx, fact.gy = cfg.x, cfg.y

-- A camera left open by an earlier run of this (the scene was killed with ffmpeg still running) is closed.
run("pkill", { "-f", "vitreus-cam/frame.jpg" }, function() end)

-- ── where the monitors lie ──
-- `hyprctl monitors -j`: each one's top left and size in the layout (logical pixels), in the order Hyprland numbers them, which is the order of the scene's copies (`screen.index`).
local mons = { { x = 0, y = 0, w = 1920, h = 1080 } }
local function refresh_monitors(done)
    run("hyprctl", { "monitors", "-j" }, function(out, code)
        if code == 0 and out then
            local ok, list = pcall(json.decode, out)
            if ok and type(list) == "table" and #list > 0 then
                table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
                local m = {}
                for i, d in ipairs(list) do
                    if i > 4 then break end
                    local sc = tonumber(d.scale) or 1
                    local w, h = (tonumber(d.width) or 1920) / sc, (tonumber(d.height) or 1080) / sc
                    if (tonumber(d.transform) or 0) % 2 == 1 then w, h = h, w end
                    m[i] = { x = tonumber(d.x) or 0, y = tonumber(d.y) or 0, w = math.floor(w + 0.5), h = math.floor(h + 0.5) }
                end
                mons = m
            end
        end
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, 4 do
            local d = mons[i]
            fact["m" .. (i - 1) .. "x"] = d and d.x or 0
            fact["m" .. (i - 1) .. "y"] = d and d.y or 0
            if d then x0, y0, x1, y1 = math.min(x0, d.x), math.min(y0, d.y), math.max(x1, d.x + d.w), math.max(y1, d.y + d.h) end
        end
        fact.vx0, fact.vy0, fact.vx1, fact.vy1 = x0, y0, x1, y1
        if done then done() end
    end)
end
-- Nowhere yet: the bottom right corner of the first monitor.
refresh_monitors(function()
    if cfg.x < 0 or cfg.y < 0 then
        local m = mons[1]
        local s = BASE * cfg.scale
        cfg.x, cfg.y = math.floor(m.x + m.w - s - 40), math.floor(m.y + m.h - s - 40)
        fact.gx, fact.gy = cfg.x, cfg.y
        save()
    end
end)
every(5000, function() if fact.shown then refresh_monitors() end end)

-- ── the camera ──
-- ffmpeg reads the camera's MJPEG, cuts the middle square, mirrors it if asked, and writes the latest frame over one file (atomically, so that it is never read half
-- written); the scene is told to load it again about fifteen times a second.
local frame_dir, frame_file, proc, n, tries = nil, nil, nil, 0, 0
local start_cam
start_cam = function()
    if proc or not frame_dir then return end
    local vf = "crop=480:480" .. (cfg.mirror and ",hflip" or "") .. ",fps=15"
    local mine
    mine = spawn("ffmpeg", { "-loglevel", "error", "-f", "v4l2", "-input_format", "mjpeg", "-framerate", "30", "-video_size", "640x480", "-i", "/dev/video0",
                             "-vf", vf, "-q:v", "6", "-f", "image2", "-update", "1", "-atomic_writing", "1", "-y", frame_file },
                 function() end,
                 function()
                     if proc ~= mine then return end
                     proc = nil
                     -- It stopped while it should be running (the camera is busy, or was just let go of): tried again a few times, then given up (the pane goes off).
                     if fact.shown then
                         tries = tries + 1
                         if tries <= 5 then after(1500, start_cam) else fact.shown = false; text.cam_path = "" end
                     end
                 end)
    proc = mine
end
local function stop_cam()
    if proc then kill(proc, "term"); proc = nil end
    text.cam_path = ""
end
run("printenv", { "XDG_RUNTIME_DIR" }, function(out)
    local rt = ((out or ""):gsub("%s+$", ""))
    if rt == "" then rt = "/tmp" end
    frame_dir = rt .. "/vitreus-cam"
    frame_file = frame_dir .. "/frame.jpg"
    run("mkdir", { "-p", frame_dir }, function() if fact.shown then start_cam() end end)
end)
every(66, function()
    if proc and frame_file then
        n = n + 1
        text.cam_path = frame_file .. "?" .. n
    end
end)
-- It comes on or goes off by `fact shown` (the launcher, the menu, `pleamar --say`).
on("fact:shown", function(v) if v then tries = 0; start_cam() else stop_cam() end end)
on("cam_mirror", function()
    cfg.mirror = not cfg.mirror
    save()
    if proc then stop_cam(); after(400, start_cam) end
end)

-- Dragging and pulling set `gx`, `gy`, `gs` over and over: kept once they have stopped for a moment.
local token = 0
local function moved()
    token = token + 1
    local t = token
    after(500, function()
        if t ~= token then return end
        local x, y, s = tonumber(fact.gx), tonumber(fact.gy), tonumber(fact.gs)
        if x and y and s and x >= 0 and y >= 0 then
            cfg.x, cfg.y, cfg.scale = math.floor(x + 0.5), math.floor(y + 0.5), math.max(0.5, math.min(2, s))
            save()
        end
    end)
end
on("fact:gx", moved)
on("fact:gy", moved)
on("fact:gs", moved)
