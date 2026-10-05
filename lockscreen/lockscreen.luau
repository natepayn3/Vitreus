-- The lock screen's logic. It only reports facts: what the wallpaper's blur is called, who is logged
-- in, what is playing, what the password looks like as shapes, and whether the password was right.

-- ── Settings ─────────────────────────────────────────────────────────────────────────────────────────
-- `lockscreen.json`, in this scene's own folder (~/.local/share/pleamar/lockscreen): what is missing from it, or wrong in it, is the
-- default below, and a file that is not there is written so that there is one to edit. It is read when the scene starts.
--   blur        how blurred the wallpaper is, in pixels at 1920 wide: 18 (light), 36 (medium), 60 (heavy), or anything between
--   show_media  the player's pill under the password bar
--   use_12_hour 12 or 24 hour clock;  show_am_pm: the AM/PM pill beside a 12 hour clock
--   date_format "long" (Wednesday, September 30, 2026), "standard" (Wed, Sep 30, 2026), "dayFirst" (30 September 2026), "iso" (2026-09-30)
--   mask_style  what a typed character becomes: "shapes", "dots", "asterisks" or "special" (a random symbol)
--   clock_size  the clock's size in pixels: 100, 150 or 200 (anything from 80 to 240 works; the card below follows)
--   show_seconds H:MM:SS on the clock
--   show_power  the sleep, restart and power off buttons at the bottom (each is held for a second)
--   monitor     where the clock, the password bar and the buttons are: "all", or the name of one monitor ("DP-2"); the others show the wallpaper
--   shape_palette the colours of those: "vibrant", "accent" (the theme's), "neon", "pastel" or "monochrome"
local cfg = { blur = 36, show_media = true, use_12_hour = true, show_am_pm = true, date_format = "long", mask_style = "shapes", shape_palette = "accent", clock_size = 200, show_seconds = false, show_power = true, monitor = "all" }
do
    local ok, saved = pcall(sys.ask, "files.read", "lockscreen.json", "json")
    if ok and type(saved) == "table" then
        for k, v in pairs(cfg) do
            if type(saved[k]) == type(v) then cfg[k] = saved[k] end
        end
        if type(cfg.blur) == "number" then cfg.blur = math.max(0, math.min(120, cfg.blur)) end
        if type(cfg.clock_size) == "number" then cfg.clock_size = math.max(80, math.min(240, cfg.clock_size)) end
    elseif ok and saved == nil then
        pcall(sys.call, "files.write", "lockscreen.json", cfg)
    end
end
fact.show_ampm = cfg.use_12_hour and cfg.show_am_pm
-- The settings as facts, for the shell's Settings page: it reads them with `get` and changes them with `fact` / `text` from outside, which
-- is what the handlers further down listen for (they do not fire for what is set here).
fact.cfg_blur = cfg.blur
fact.cfg_12h = cfg.use_12_hour
fact.cfg_ampm = cfg.show_am_pm
fact.cfg_media = cfg.show_media
text.cfg_date = cfg.date_format
local MASK_FACT = { shapes = "msk_shapes", dots = "msk_dots", asterisks = "msk_stars", special = "msk_special" }
local PAL_FACT = { vibrant = "mp_vibrant", accent = "mp_accent", neon = "mp_neon", pastel = "mp_pastel", monochrome = "mp_mono" }
local MASK_NAME, PAL_NAME = {}, {}
for k, v in pairs(MASK_FACT) do MASK_NAME[v] = k end
for k, v in pairs(PAL_FACT) do PAL_NAME[v] = k end
if not MASK_FACT[cfg.mask_style] then cfg.mask_style = "shapes" end
if not PAL_FACT[cfg.shape_palette] then cfg.shape_palette = "accent" end
fact.mask_style = MASK_FACT[cfg.mask_style]
fact.clock_px = cfg.clock_size
fact.show_power = cfg.show_power
fact.cfg_secs = cfg.show_seconds
fact.mask_pal = PAL_FACT[cfg.shape_palette]
local function save_cfg() pcall(sys.call, "files.write", "lockscreen.json", cfg) end

-- ── Which monitor ────────────────────────────────────────────────────────────────────────────────────
-- Only the chosen monitor shows the lock: the scene's `screens:` line names it (Vitreus's Settings page rewrites that line), and the rest
-- are covered in black. The keyboard goes to the monitor the pointer is on, so the pointer is brought to the chosen one as the lock closes.
text.cfg_monitor = cfg.monitor
on("text:cfg_monitor", function(t)
    t = (t or ""):match("^[%w%._%-]+$") and t or "all"
    cfg.monitor = t
    save_cfg()
end)
local function focus_monitor()
    if cfg.monitor ~= "all" and cfg.monitor ~= "" then
        run("hyprctl", { "dispatch", 'hl.dsp.focus({ monitor = "' .. cfg.monitor .. '" })' }, function() end)
    end
end

-- ── The clock ────────────────────────────────────────────────────────────────────────────────────────
local weekdays = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local months = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
                 "October", "November", "December" }

local function date_text(c)
    local wd, mo = weekdays[c.weekday + 1] or "", months[c.month] or ""
    if cfg.date_format == "standard" then return string.format("%s, %s %d, %d", wd:sub(1, 3), mo:sub(1, 3), c.day, c.year) end
    if cfg.date_format == "dayFirst" then return string.format("%d %s %d", c.day, mo, c.year) end
    if cfg.date_format == "iso" then return string.format("%04d-%02d-%02d", c.year, c.month, c.day) end
    return string.format("%s, %s %d, %d", wd, mo, c.day, c.year)
end

local last_clock = nil
local function show_clock(c)
    local sec = cfg.show_seconds and string.format(":%02d", c.second or 0) or ""
    if cfg.use_12_hour then
        local h12 = c.hour % 12
        if h12 == 0 then h12 = 12 end
        text.clock_time = string.format("%d:%02d", h12, c.minute) .. sec
    else
        text.clock_time = string.format("%02d:%02d", c.hour, c.minute) .. sec
    end
    text.clock_ampm = c.hour >= 12 and "PM" or "AM"
    text.clock_date = date_text(c)
end
sys.watch("clock", function(c)
    last_clock = c
    show_clock(c)
end)
-- Every second, but only while there is something to draw: a clock with seconds, on a locked screen.
sys.watch("clock.seconds", function(c)
    if cfg.show_seconds and fact.locked then
        last_clock = c
        show_clock(c)
    end
end)
local function truthy(v) return v == true or v == 1 or v == "true" end
on("fact:cfg_secs", function(v)
    cfg.show_seconds = truthy(v)
    save_cfg()
    if last_clock then show_clock(last_clock) end
end)
on("fact:show_power", function(v)
    cfg.show_power = truthy(v)
    save_cfg()
end)
on("fact:clock_px", function(v)
    local n = tonumber(v)
    if not n then return end
    cfg.clock_size = math.max(80, math.min(240, n))
    save_cfg()
end)
-- The power buttons: held for a second in the scene, so when this is called it was meant. They do not undo.
on("lock_power", function(i)
    if not fact.locked then return end
    i = math.floor(i + 0.5)
    if i == 0 then sys.call("session.suspend")
    elseif i == 1 then sys.call("session.reboot")
    elseif i == 2 then sys.call("session.poweroff") end
end)
on("fact:cfg_12h", function(v)
    cfg.use_12_hour = truthy(v)
    fact.show_ampm = cfg.use_12_hour and cfg.show_am_pm
    save_cfg()
    if last_clock then show_clock(last_clock) end
end)
on("fact:cfg_ampm", function(v)
    cfg.show_am_pm = truthy(v)
    fact.show_ampm = cfg.use_12_hour and cfg.show_am_pm
    save_cfg()
end)
on("fact:mask_style", function(v)
    local name = MASK_NAME[v]
    if name then cfg.mask_style = name; save_cfg() end
end)
on("fact:mask_pal", function(v)
    local name = PAL_NAME[v]
    if name then cfg.shape_palette = name; save_cfg() end
end)
on("text:cfg_date", function(t)
    if t == "long" or t == "standard" or t == "dayFirst" or t == "iso" then
        cfg.date_format = t
        save_cfg()
        if last_clock then show_clock(last_clock) end
    end
end)

-- ── Who is locked in ─────────────────────────────────────────────────────────────────────────────────
local home, user = "", ""
run("printenv", { "HOME" }, function(out)
    home = (out or ""):gsub("%s+$", "")
    run("printenv", { "USER" }, function(uout)
        user = (uout or ""):gsub("%s+$", "")
        -- the name shown is the real name if there is one, and the login name if not
        if user ~= "" then text.realname = user end
        run("getent", { "passwd", user }, function(line)
            -- name:x:uid:gid:GECOS:home:shell, and the real name is the first of GECOS's comma-separated parts
            local gecos = (line or ""):match("^[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):")
            local name = gecos and gecos:match("^[^,]*") or ""
            if name ~= "" then text.realname = name end
        end)
        -- the avatar: ~/.face, ~/.face.icon or AccountsService's, whichever exists first
        local candidates = { home .. "/.face", home .. "/.face.icon", "/var/lib/AccountsService/icons/" .. user }
        local function try(i)
            if i > #candidates then return end
            run("ls", { candidates[i] }, function(_, code)
                if code == 0 then
                    text.avatar_path = candidates[i]
                    fact.has_avatar = true
                else
                    try(i + 1)
                end
            end)
        end
        try(1)
    end)
end)

-- ── What is playing ──────────────────────────────────────────────────────────────────────────────────
local last_media = nil
local function show_media_pill()
    local m = last_media
    fact.has_media = cfg.show_media and m ~= nil and (m.player or "") ~= "" and ((m.title or "") ~= "" or m.playing == true)
end
sys.watch("media", function(m)
    last_media = m
    show_media_pill()
end)
on("fact:cfg_media", function(v)
    cfg.show_media = truthy(v)
    save_cfg()
    show_media_pill()
end)
on("media_prev", function() sys.call("media.previous") end)
on("media_play", function() sys.call("media.toggle") end)
on("media_next", function() sys.call("media.next") end)

-- ── The wallpaper, made ready before it is needed ────────────────────────────────────────────────────
-- A lock has to be instant, so the two pictures it uses are made ahead of time, each time the wallpaper
-- changes: a sharp one, and one already blurred (a blur that smooth needs few pixels; one made at a tenth of the
-- screen's showed as round blobs when stretched over it). The names carry a hash of the wallpaper's path, so a new
-- wallpaper is a new file and never a stale cached one.
--
-- An `image` is declared with a fixed size in the scene (1280 x 720 for the sharp one, 960 x 540 for the blur), and
-- the picture is fitted inside that cell and then the cell is stretched over the screen. So both pictures are made
-- exactly 16:9 (the cell), from the wallpaper cropped to the MONITOR's shape and then squashed to fit it: drawn over
-- the screen, the cell stretches them back to the shape they had. They are small on purpose: pleamar keeps images and
-- glyphs in one 2048 x 2048 texture, and two 1920 x 1080 pictures filled it, so the clock's new digits had no room and
-- were not painted. The blur is smooth, so half the pixels lose nothing; the sharp one is only on screen while it
-- blurs away.
local prep_busy = false
local made_key = nil

local function hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + string.byte(str, i)) % 4294967296 end
    return tostring(h)
end

-- What the scene draws is always the same two files, `sharp.jpg` and `blur.jpg`, overwritten with the new
-- wallpaper's pictures and asked for again by a version on the end of the path (`blur.jpg?7`): that is how pleamar
-- is told a file written under the same name has changed. (A scene that instead was pointed at a new file
-- name each time, and had the old files deleted, drew nothing on the lock: it went on asking for a path that
-- was gone.) The pictures made for each wallpaper are kept under their own names, one pair at a time.
local publish_count = 0

local function publish(s, b, done)
    local dir = home .. "/.cache/pleamar/lockscreen"
    local fs, fb = dir .. "/sharp.jpg", dir .. "/blur.jpg"
    run("cp", { "-f", s, fs }, function(_, c1)
        run("cp", { "-f", b, fb }, function(_, c2)
            if c1 == 0 and c2 == 0 then
                publish_count = publish_count + 1
                local version = "?" .. (os.time() * 100 + publish_count % 100)
                text.wp_sharp = fs .. version
                text.wp_blur = fb .. version
                fact.has_wall = true
            end
            if done then done() end
        end)
    end)
end

local function prepare_wallpaper()
    if prep_busy or fact.locked or home == "" then return end
    prep_busy = true
    local dir = home .. "/.cache/pleamar/lockscreen"
    local function done() prep_busy = false end
    run("awww", { "query" }, function(out)
        local line = (out or ""):match("[^\n]+") or ""
        local path = line:match("currently displaying: image: (.-)%s*$")
        local geo = line:match("%d+x%d+")
        if not path or not geo then return done() end
        local sigma = cfg.blur / 4              -- the blurred picture is made at 480 wide, a quarter of the screen
        local key = hash(string.format("5 %g ", sigma) .. path)
        if key == made_key then return done() end
        local s, b = dir .. "/sharp-" .. key .. ".jpg", dir .. "/blur-" .. key .. ".jpg"
        -- the pictures of every earlier wallpaper are of no use any more (the two the scene draws are not theirs)
        local function forget_old()
            run("ls", { dir }, function(listing)
                for name in (listing or ""):gmatch("[^\n]+") do
                    if (name:match("^sharp%-%d+%.jpg$") or name:match("^blur%-%d+%.jpg$")) and not name:find("-" .. key .. ".jpg", 1, true) then
                        run("rm", { "-f", dir .. "/" .. name }, function() end)
                    end
                end
            end)
        end
        run("ls", { s, b }, function(_, code)
            if code == 0 then
                made_key = key
                publish(s, b, done)
                return
            end
            run("mkdir", { "-p", dir }, function()
                run("magick", { path, "-resize", geo .. "^", "-gravity", "center", "-extent", geo, "-resize", "1280x720!", "-quality", "90", s }, function(_, c1)
                    if c1 ~= 0 then return done() end
                    run("magick", { path, "-resize", geo .. "^", "-gravity", "center", "-extent", geo, "-resize", "480x", "-blur", "0x" .. sigma, "-resize", "960x540!", "-quality", "95", "-sampling-factor", "4:4:4", b }, function(_, c2)
                        if c2 == 0 then
                            made_key = key
                            publish(s, b, function()
                                forget_old()
                                done()
                            end)
                        else
                            done()
                        end
                    end)
                end)
            end)
        end)
    end)
end
on("fact:cfg_blur", function(v)
    local n = tonumber(v)
    if not n then return end
    cfg.blur = math.max(0, math.min(120, n))
    save_cfg()
    made_key = nil                          -- the blurred picture is made again, at the new blur
    prepare_wallpaper()
end)
every(5000, prepare_wallpaper)
after(500, prepare_wallpaper)

-- ── The password, as shapes ──────────────────────────────────────────────────────────────────────────
-- Every character typed becomes a random shape (one of 16), turned a random quarter and, one time in
-- five, only an outline. The password itself never leaves the input.
local rotations = { 0, 45, 90, 135, 180, 225, 270, 315 }
local symbols = { "!", "@", "#", "$", "%", "^", "&", "*", "~", "?", "§", "+", "=", "<", ">", "/" }
local list = {}

local function set_shapes(n)
    if n == 0 then
        list = {}
    elseif n > #list then
        for _ = #list + 1, n do
            list[#list + 1] = {
                idx = math.random(0, 15),
                rot = rotations[math.random(1, #rotations)],
                outline = math.random() < 0.22,
                ci = math.random(0, 59),                  -- the colour, from whatever palette is chosen (see the scene)
                sym = symbols[math.random(1, #symbols)],  -- and the symbol, for the "special" style
            }
        end
    else
        while #list > n do list[#list] = nil end
    end
    -- the list holds at most 40; a longer password shows its last 40
    local shown = list
    if #list > 40 then
        shown = {}
        for i = #list - 39, #list do shown[#shown + 1] = list[i] end
    end
    model.shapes = shown
    fact.pw_len = n
end

on("text:password", function(t)
    if fact.right then return end
    local n = utf8.len(t) or #t
    if n ~= #list then set_shapes(n) end
end)

local function reset()
    list = {}
    model.shapes = {}
    fact.pw_len = 0
    fact.authing = false
    fact.wrong = false
    fact.right = false
    text.password = ""
    text.status = "System Locked"
end

on("clear", function()
    if fact.authing or fact.right then return end
    reset()
end)

-- ── Locking and unlocking ────────────────────────────────────────────────────────────────────────────
-- What has to happen once a lock is over, however it ended: nothing of it is left written (the password, its
-- shapes, the verdict). This is called from both ways a lock can end: from outside (`fact:locked`, which only fires
-- for a change made from outside the logic) and from the logic itself, when the password was right, which does not
-- fire it.
local function after_unlock()
    reset()
    fact.settled = false
    fact.safe = false                        -- a test lock (safe: Esc or a minute opens it) is a test of one lock only
end

on("fact:locked", function(v)
    if v then
        focus_monitor()
        reset()
        fact.settled = false
        -- the entrance is 2.2 s; after that nothing on the screen needs the clock any more
        after(2400, function() fact.settled = true end)
    else
        after_unlock()
    end
end)

on("tryauth", function()
    local pw = text.password
    if fact.authing or fact.right or pw == "" then return end
    fact.authing = true
    text.status = "Verifying..."
    local ok = sys.ask("auth.check", pw)
    fact.authing = false
    if ok then
        fact.right = true
        text.status = "Unlocked!"
        after(320, function()
            run("loginctl", { "unlock-session" }, function() end)
            fact.locked = false
            after_unlock()
        end)
    else
        fact.wrong = true
        text.status = "Incorrect password. Try again."
        after(650, function()
            reset()
        end)
    end
end)
