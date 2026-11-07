-- Shelf: things dropped on the desk's Shelf tab (files, links, text), kept between sessions in desk-shelf.json, up to eight, newest first.
-- A card carries its path (or link, or the text itself), so it can be dragged out onto any other program. A picture's or a video's card shows a small
-- picture of it (made with magick or ffmpeg into the cache, `shelf/`).
--
-- The shelf can be a locker (`lock` in the file): it starts out shut, and again each time the desk closes or "Lock now" is pressed; shut, nothing of what is on it
-- is put in the scene (no names, no paths to carry, no pictures) until the login password is given (PAM, as the lock screen's). That hides it from the panel, not
-- from the disk: desk-shelf.json is not encrypted.
return function(with_dirs)
    local MAX = 8
    local items = {}                                    -- { name, path, tag }
    local lock_on, locked = false, false                -- the box is ticked, and it is shut now
    local function save() pcall(sys.call, "files.write", "desk-shelf.json", { items = items, lock = lock_on }) end

    -- Pictures of what is on the shelf: an image's own, a video's first moments, 200 px square, kept by a hash of the path.
    local IMG = { png = 1, jpg = 1, jpeg = 1, gif = 1, webp = 1, bmp = 1, tif = 1, tiff = 1, avif = 1, heic = 1, svg = 1, ico = 1 }
    local VID = { mp4 = 1, mkv = 1, webm = 1, mov = 1, avi = 1, m4v = 1, flv = 1, wmv = 1, mpg = 1, mpeg = 1, ogv = 1 }
    local thumbs, making = {}, {}                       -- path -> the file of its picture (false: it could not be made); the ones being made
    local render
    local function kind_of(path)
        if path:sub(1, 1) ~= "/" then return nil end
        local e = path:match("%.(%w+)$")
        e = e and e:lower()
        if e and IMG[e] then return "img" end
        if e and VID[e] then return "vid" end
        return nil
    end
    local function hash(str)
        local h = 5381
        for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
        return string.format("%08x", h)
    end
    local function make_thumb(it)
        local kind = (it.tag ~= "TXT" and it.tag ~= "URL") and kind_of(it.path) or nil
        if not kind or thumbs[it.path] ~= nil or making[it.path] then return end
        making[it.path] = true
        with_dirs(function(d)
            local dir = (d.cache:gsub("/wp$", "")) .. "/shelf"
            local out = dir .. "/" .. hash(it.path .. "#200") .. ".jpg"
            local function finish(ok)
                making[it.path] = nil
                thumbs[it.path] = ok and out or false
                if ok then render() end
            end
            run("mkdir", { "-p", dir }, function()
                if kind == "img" then
                    run("magick", { "-limit", "thread", "1", "-define", "jpeg:size=400x400", it.path .. "[0]", "-thumbnail", "200x200^", "-gravity", "center",
                                    "-extent", "200x200", "-quality", "88", out }, function(_, code) finish(code == 0) end)
                else
                    local vf = "scale=200:200:force_original_aspect_ratio=increase,crop=200:200"
                    local function try(ss, again)
                        local args = { "-y", "-loglevel", "error" }
                        if ss then args[#args + 1] = "-ss"; args[#args + 1] = ss end
                        for _, a in ipairs({ "-i", it.path, "-frames:v", "1", "-vf", vf, "-q:v", "3", out }) do args[#args + 1] = a end
                        run("ffmpeg", args, function(_, code)
                            run("stat", { "-c", "%s", out }, function(_, sc)
                                if code == 0 and sc == 0 then finish(true) elseif again then again() else finish(false) end
                            end)
                        end)
                    end
                    -- a second in (past a black first frame), and from the start for one shorter than that
                    try("1", function() try(nil, nil) end)
                end
            end)
        end)
    end

    render = function()
        for k = 0, MAX - 1 do
            local it = (not locked) and items[k + 1] or nil
            local th = it and thumbs[it.path] or nil
            text["shelf." .. k .. ".name"] = it and it.name or ""
            text["shelf." .. k .. ".path"] = it and it.path or ""
            text["shelf." .. k .. ".tag"] = it and it.tag or ""
            text["shelf." .. k .. ".thumb"] = th or ""
            fact["shelf." .. k .. ".thumbed"] = th ~= nil and th ~= false
            fact["shelf." .. k .. ".has"] = it ~= nil
            fact["shelf." .. k .. ".askable"] = it ~= nil and (it.tag == "TXT" or it.tag == "URL")
            local kd = it and it.tag ~= "TXT" and it.tag ~= "URL" and kind_of(it.path) or nil
            fact["shelf." .. k .. ".img"] = kd == "img"
            fact["shelf." .. k .. ".vid"] = kd == "vid"
            if it then make_thumb(it) end
        end
        fact.shelf_n = locked and 0 or #items
        fact.shelf_lock_on = lock_on
        fact.shelf_locked = locked
        text.shelf_locked_txt = locked and (#items == 0 and "Nothing inside" or (#items == 1 and "1 thing inside" or (#items .. " things inside"))) or ""
    end
    local function unescape(u) return (u:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
    local function add(it)
        for i, x in ipairs(items) do
            if x.path == it.path then table.remove(items, i); break end
        end
        table.insert(items, 1, it)
        while #items > MAX do table.remove(items) end
    end
    do
        local ok, saved = pcall(sys.ask, "files.read", "desk-shelf.json", "json")
        if ok and type(saved) == "table" and saved.lock == true then lock_on, locked = true, true end
        if ok and type(saved) == "table" and type(saved.items) == "table" then
            for _, x in ipairs(saved.items) do
                if type(x) == "table" and type(x.path) == "string" and #items < MAX then
                    items[#items + 1] = { name = tostring(x.name or x.path), path = x.path, tag = tostring(x.tag or "FILE"), len = type(x.len) == "string" and x.len or nil }
                end
            end
        end
    end
    on("drop:desk_drop", function(data)
        if type(data) ~= "string" or data == "" then return end
        local found = false
        for line in data:gmatch("[^\r\n]+") do
            local p = line:match("^file://(.*)$")
            if p then
                p = unescape(p)
                local name = p:match("([^/]+)/*$") or p
                local ext = name:match("%.(%w+)$")
                add({ name = name, path = p, tag = ext and ext:sub(1, 4):upper() or "FILE" })
                found = true
            elseif line:match("^https?://") then
                local name = (line:gsub("^https?://", "")):sub(1, 40)
                add({ name = name, path = line, tag = "URL" })
                found = true
            end
        end
        if not found then
            local name = (data:gsub("%s+", " ")):sub(1, 40)
            add({ name = name, path = data, tag = "TXT" })
        end
        save()
        render()
    end)
    local busy = false
    on("shelf_del", function(k)
        if locked or busy or type(k) ~= "number" or not items[k + 1] then return end
        busy = true
        fact["shelf." .. k .. ".gone"] = true               -- the card slides off and fades; then it goes and the rest glide up
        after(200, function()
            table.remove(items, k + 1)
            save()
            fact["shelf." .. k .. ".gone"] = false
            render()
            emit("shelf_shifted", k)
            busy = false
        end)
    end)
    -- A click opens it with the default app (a file, or a link in the browser); a text has no app, so it is copied. Run from the desktop (the compositor's own
    -- `exec_cmd`), so that the app is the desktop's and not this shell's child.
    local function quote(str) return "'" .. str:gsub("'", "'\\''") .. "'" end
    on("shelf_open", function(k)
        local it = (not locked) and type(k) == "number" and items[k + 1]
        if not it then return end
        if it.tag == "TXT" then
            run("wl-copy", { it.path }, function() end)
        else
            exec_on_desktop("xdg-open " .. quote(it.path))
        end
    end)
    -- A text or link card can be asked about: it goes to the Ask tab as an attachment (logic/ask.luau).
    on("shelf_ask", function(k)
        local it = (not locked) and type(k) == "number" and items[k + 1]
        if not it or not (it.tag == "TXT" or it.tag == "URL") then return end
        ask_attach_from(it.tag == "URL" and "Link" or "Shelf text", it.path)
    end)
    -- ── What can be done with a file on the shelf (pages/desk.plm: its menu), `shelf_act(k * 10 + what)` ──
    -- A picture: 0 as PNG, 1 as JPG, 2 at half its size, 3 the text in it (tesseract; it goes on the shelf as text, and is copied). A video: 4 a short GIF, 5 its sound. What is made is written next to the original and put on the shelf, newest first.
    local function add_file(p, tag, len)
        local name = p:match("([^/]+)$") or p
        add({ name = name, path = p, tag = tag or ((name:match("%.(%w+)$") or "FILE"):sub(1, 4):upper()), len = len })
        save()
        render()
    end
    local function free_name(base, ext, done)
        -- base-1.ext, base-2.ext ... the first that is not there
        local function try(n)
            local p = base .. (n > 0 and ("-" .. n) or "") .. "." .. ext
            run("test", { "-e", p }, function(_, c) if c ~= 0 or n > 50 then done(p) else try(n + 1) end end)
        end
        try(0)
    end
    -- A file put on the shelf from elsewhere on the Desk (the Camera's photos), as a global: the modules cannot hear each other's events.
    function desk_shelf_add(p) if not locked then add_file(p) end end
    on("shelf_act", function(v)
        v = tonumber(v) or -1
        local k, what = math.floor(v / 10), v % 10
        local it = (not locked) and items[k + 1]
        fact.shelf_menu = -1
        if not it then return end
        local kd = kind_of(it.path)
        local base = it.path:gsub("%.[^./]+$", "")
        local function done(msg) text.shelf_busy = msg; after(2600, function() if text.shelf_busy == msg then text.shelf_busy = "" end end) end
        if kd == "img" and (what == 0 or what == 1) then
            text.shelf_busy = "Converting…"
            free_name(base, what == 0 and "png" or "jpg", function(out)
                run("magick", { it.path .. "[0]", out }, function(_, c) if c == 0 then add_file(out); done("Made " .. out:match("([^/]+)$")) else done("It could not be converted") end end)
            end)
        elseif kd == "img" and what == 2 then
            text.shelf_busy = "Resizing…"
            local ext = it.path:match("%.(%w+)$") or "png"
            free_name(base .. "-half", ext, function(out)
                run("magick", { it.path .. "[0]", "-resize", "50%", out }, function(_, c) if c == 0 then add_file(out); done("Half the size") else done("It could not be resized") end end)
            end)
        elseif kd == "img" and what == 3 then
            text.shelf_busy = "Reading the text…"
            run("tesseract", { it.path, "-", "--psm", "3" }, function(out, c)
                local t = ((out or ""):gsub("\f", ""):gsub("^%s+", ""):gsub("%s+$", ""))
                if c ~= 0 or t == "" then done("No text found"); return end
                add({ name = (t:gsub("%s+", " ")):sub(1, 40), path = t, tag = "TXT" })
                save()
                render()
                run("wl-copy", { "--", t }, function() end)
                done("Text copied, and on the shelf")
            end)
        elseif kd == "vid" and what == 4 then
            text.shelf_busy = "Making a GIF…"
            free_name(base, "gif", function(out)
                run("ffmpeg", { "-y", "-loglevel", "error", "-t", "8", "-i", it.path, "-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", out },
                    function(_, c) if c == 0 then add_file(out); done("GIF made") else done("No GIF: ffmpeg said no") end end)
            end)
        elseif kd == "vid" and what == 5 then
            text.shelf_busy = "Taking the sound out…"
            free_name(base, "mp3", function(out)
                run("ffmpeg", { "-y", "-loglevel", "error", "-i", it.path, "-vn", "-q:a", "2", out },
                    function(_, c) if c == 0 then add_file(out); done("Sound saved") else done("It has no sound to take") end end)
            end)
        end
    end)

    on("shelf_clear", function() if locked then return end items = {}; save(); render() end)

    -- The locker. Ticking the box shuts it at once; unticking needs it open (the box is only there then).
    on("shelf_lock_toggle", function()
        if locked then return end
        lock_on = not lock_on
        if lock_on then locked = true end
        text.shelf_pw = ""
        fact.shelf_bad = false
        save(); render()
    end)
    on("shelf_lock_now", function()
        if not lock_on or locked then return end
        locked = true
        render()
    end)
    -- Closing the desk shuts it too, so that what was open does not stay open behind you.
    on("fact:desk_open", function(v)
        if (v == false or tostring(v) == "false") and lock_on and not locked then
            locked = true
            text.shelf_pw = ""
            render()
        end
    end)
    local misses = 0                                   -- wrong tries in a row: the system locks password checks after three (faillock), logins and sudo with them
    local function unlock()
        if not locked or fact.shelf_authing then return end
        local pw = text.shelf_pw
        if pw == "" then return end
        fact.shelf_authing = true
        fact.shelf_bad = false
        local called, ok = pcall(sys.ask, "auth.check", pw)       -- PAM, as the lock screen does; the answer takes a moment, longer when it is wrong
        text.shelf_pw = ""
        fact.shelf_authing = false
        if called and ok then
            misses = 0
            text.shelf_warn = ""
            locked = false
            fact.desk_kb = false
            render()
        else
            fact.shelf_bad = true
            if called then
                misses = misses + 1
                text.shelf_warn = misses >= 2 and "One more wrong try and the system locks password checks for 10 minutes" or ""
            end
            -- `auth` is a service the scene has to be allowed (its permissions); if the call itself failed, say so rather than call the password wrong
            if not called then text.shelf_locked_txt = "The password could not be checked here" end
        end
    end
    on("shelf_unlock", unlock)
    on("submit:shelf_pw", unlock)
    render()
end
