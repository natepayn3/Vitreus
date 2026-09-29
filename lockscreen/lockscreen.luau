-- The lock screen's logic. It only reports facts: what the wallpaper's blur is called, who is logged
-- in, what is playing, what the password looks like as shapes, and whether the password was right.

-- ── The clock ────────────────────────────────────────────────────────────────────────────────────────
local weekdays = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local months = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
                 "October", "November", "December" }

sys.watch("clock", function(c)
    local h12 = c.hour % 12
    if h12 == 0 then h12 = 12 end
    text.clock_time = string.format("%d:%02d", h12, c.minute)
    text.clock_ampm = c.hour >= 12 and "PM" or "AM"
    text.clock_date = string.format("%s, %s %d, %d", weekdays[c.weekday + 1] or "", months[c.month] or "", c.day, c.year)
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
sys.watch("media", function(m)
    fact.has_media = (m.player or "") ~= "" and ((m.title or "") ~= "" or m.playing == true)
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
        local key = hash("4 " .. path)
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
                    run("magick", { path, "-resize", geo .. "^", "-gravity", "center", "-extent", geo, "-resize", "480x", "-blur", "0x9", "-resize", "960x540!", "-quality", "95", "-sampling-factor", "4:4:4", b }, function(_, c2)
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
every(5000, prepare_wallpaper)
after(500, prepare_wallpaper)

-- ── The password, as shapes ──────────────────────────────────────────────────────────────────────────
-- Every character typed becomes a random shape (one of 16), turned a random quarter and, one time in
-- five, only an outline. The password itself never leaves the input.
local rotations = { 0, 45, 90, 135, 180, 225, 270, 315 }
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
end

on("fact:locked", function(v)
    if v then
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
