-- View's logic: which picture is shown, and the others of its folder. Nothing here is drawn.
--
-- It starts with $VIEW_START (a file, or a folder: its first picture), lists the pictures of that folder in the order Files gives names (case left aside,
-- numbers as numbers: img2 before img10), measures the one shown with ImageMagick (`identify -ping`, which reads only its header), and shows it.
-- pleamar reads PNG, JPEG, GIF, WebP and BMP itself; anything else (HEIC, AVIF, JPEG XL, TIFF, ICO, PSD...), and a photo whose camera wrote that it was
-- held turned (EXIF orientation), is first made into a PNG in the runtime folder ($XDG_RUNTIME_DIR/vitreus-view/<pleamar's pid>), which is gone with the session.
--
-- The look is asked of Vitreus (`get look_v`, as Files does) when View starts and each time its window gets the keyboard, so a theme changed meanwhile is
-- taken up; $VIEW_LOOK (0 Glass, 1 Retro, 2 UwU, 3 Cyber, 4 Doodle) names one instead, to see them all without Vitreus.

local NATIVE = { png = true, jpg = true, jpeg = true, jpe = true, jfif = true, gif = true, webp = true, bmp = true }
local PICTURES = { "png", "jpg", "jpeg", "jpe", "jfif", "gif", "webp", "bmp", "svg", "tif", "tiff", "avif", "heic", "heif", "jxl", "ico", "tga", "psd", "qoi", "ppm", "pgm", "pnm", "xcf", "dng", "cr2", "nef", "arw" }
-- Videos are listed with the pictures: what is drawn of one is its first picture (a frame from a few seconds in, made with ffmpeg into the runtime folder),
-- and it plays in View's player (bin/vitreus-view hands it to mpv, with the others of its folder after it).
local VIDEOS = { "mp4", "m4v", "mkv", "webm", "mov", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "ts", "ogv", "3gp", "3g2", "vob", "divx", "f4v" }
local IS_VIDEO = {}
for _, e in ipairs(VIDEOS) do IS_VIDEO[e] = true end
-- Orientations that mean the picture is stored turned a quarter (its width and height swap once it is the right way up).
local QUARTER = { RightTop = true, LeftBottom = true, LeftTop = true, RightBottom = true }
-- Vitreus's look numbers (`look_v`) as View's: 1 Retro, 2 UwU, 3 Cyber (and Proxy), 7 Doodle; Milk (4) and Paper (6) are drawn as Glass, as Snap does.
local LOOKS = { [0] = 0, [1] = 1, [2] = 2, [3] = 3, [7] = 4 }

local st = {
    dir = nil,          -- the folder
    names = {},         -- its pictures, in order
    i = 0,              -- the one shown
    tmp = nil,          -- the runtime folder for the copies
    meta = {},          -- path -> what was found out about it: { src = what pleamar is given, w, h, rest = the line's own part, copy = true if src is a copy } or { bad = true }
    waiting = {},       -- path -> the callbacks waiting for it to be found out (one look at a file at a time)
    n = 0,              -- how many copies have been made
    shown = 0,          -- how many times a picture was shown (for `gen`)
    tap_at = false,     -- a first click is waiting for a second
    look_fixed = false, -- $VIEW_LOOK set: Vitreus is not asked
    toast_n = 0,
    hidden = false,     -- the file opened is a hidden one: hidden files are listed too
    rest = "",          -- the part of the line under the name that is the picture's own
    home = nil,         -- the home folder, written ~ in the details card
}

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function ext_of(name) return (name:match("%.([^./]+)$") or ""):lower() end
local function base_of(p) return p:match("([^/]+)/*$") or p end

local function say(words)
    st.toast_n = st.toast_n + 1
    local n = st.toast_n
    text.toast = words
    fact.toast_on = true
    after(1800, function() if st.toast_n == n then fact.toast_on = false end end)
end

local function cut_words(v) v = v or "" if #v > 70 then return v:sub(1, 69) .. "…" end return v end

local function human(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then return string.format("%d B", bytes) end
    local units = { "KB", "MB", "GB" }
    local v, u = bytes / 1024, 1
    while v >= 1024 and u < #units do v = v / 1024; u = u + 1 end
    return string.format(v < 10 and "%.1f %s" or "%.0f %s", v, units[u])
end

-- Nothing to show: why, a softer line under it, and whether it is a problem (Peek, the cat who keeps the empty window company, wakes up then). Under it
-- is a button to Files: `where` is the folder it opens (nil: the Pictures folder), `label` what it says.
local function nothing(why, hint, sad, label, where)
    fact.ready = false
    fact.is_video = false
    fact.has_msg = true
    fact.sad = sad and true or false
    text.msg = why or ""
    fact.has_why = (why or "") ~= ""
    text.hint = hint or ""
    fact.has_hint = (hint or "") ~= ""
    text.browse = label or "Find pictures in Files"
    st.browse = where
end

local function current() return st.names[st.i] and (st.dir .. "/" .. st.names[st.i]) or nil end
local function path_at(i) return st.names[i] and (st.dir .. "/" .. st.names[i]) or nil end

-- The line under the name: which of how many, then `rest` (its size in pixels, how big the file is, its format).
local function sub_line()
    local count = #st.names
    local which = count > 1 and string.format("%d of %d", st.i, count) or ""
    if which ~= "" and st.rest ~= "" then return which .. "  ·  " .. st.rest end
    return which ~= "" and which or st.rest
end

-- Finds out what a file is and gets it ready to draw: measured, and copied into a PNG when pleamar cannot read it as it is. Done once per file; `done(m)`
-- gets what `st.meta` keeps. What pleamar is given carries the file's modification time as its version (`?mtime`), the same every time it is asked for,
-- so the picture decoded for a neighbour in advance (below) is the very one shown when it comes, and a file changed meanwhile is read again.
local function clock(t)
    t = math.floor(tonumber(t) or 0)
    local h, m, sec = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

local function prepare(path, done)
    local m = st.meta[path]
    if m then done(m) return end
    if st.waiting[path] then table.insert(st.waiting[path], done) return end
    st.waiting[path] = { done }
    local function finish(res)
        st.meta[path] = res
        local list = st.waiting[path] or {}
        st.waiting[path] = nil
        for _, f in ipairs(list) do f(res) end
    end
    -- a video: its first picture (from 5 s in, or its very first for a shorter one), how long it is, its size and how big the file is
    if IS_VIDEO[ext_of(path)] then
        if not st.tmp then finish({ bad = true, why = "There is no room to open this video" }) return end
        st.n = st.n + 1
        local out_path = st.tmp .. "/" .. st.n .. ".png"
        local script = 'ffmpeg -nostdin -v error -ss 5 -i "$1" -frames:v 1 -vf "scale=min(1920\\,iw):-2" -y "$2" 2> /dev/null; '
            .. '[ -s "$2" ] || ffmpeg -nostdin -v error -i "$1" -frames:v 1 -vf "scale=min(1920\\,iw):-2" -y "$2" 2> /dev/null; '
            .. '[ -s "$2" ] || exit 5; magick identify -ping -format "%w %h\n" "$2"; '
            .. 'ffprobe -v error -select_streams v:0 -show_entries stream=width,height:format=duration -of default=nw=1 "$1" 2> /dev/null; '
            .. 'stat -c "size=%s" "$1" 2> /dev/null'
        run("sh", { "-c", script, "sh", path, out_path }, function(out, code)
            out = out or ""
            local tw, th = out:match("^(%d+) (%d+)")
            tw, th = tonumber(tw), tonumber(th)
            if code ~= 0 or not tw then finish({ bad = true, why = "This video could not be opened", video = true }) return end
            local vw, vh = out:match("width=(%d+)"), out:match("height=(%d+)")
            local dur, size = tonumber(out:match("duration=([%d.]+)")), out:match("size=(%d+)")
            local parts = {}
            if vw and vh then parts[#parts + 1] = string.format("%s × %s", vw, vh) end
            if dur then parts[#parts + 1] = clock(dur) end
            if size then parts[#parts + 1] = human(size) end
            parts[#parts + 1] = "Video"
            finish({ src = out_path .. "?1", file = out_path, copy = true, video = true, w = tw, h = th, rest = table.concat(parts, "  ·  ") })
        end)
        return
    end
    -- the header: width, height, how the camera held it, the format; then how big the file is and when it was last changed
    run("sh", { "-c", 'magick identify -ping -format "%w %h %[orientation] %m\\n" "$1[0]" 2> /dev/null | head -n 1; stat -c "%s %Y" "$1" 2> /dev/null', "sh", path }, function(out)
        local w, h, orient, fmt, size, mtime = (out or ""):match("^(%d+) (%d+) (%S*) ?(%S*)\n(%d*) ?(%d*)")
        w, h = tonumber(w), tonumber(h)
        if not w or w == 0 or not h or h == 0 then finish({ bad = true }) return end
        local turned = orient ~= nil and orient ~= "" and orient ~= "Undefined" and orient ~= "TopLeft"
        local real_w, real_h = w, h
        if QUARTER[orient or ""] then real_w, real_h = h, w end
        local parts = { string.format("%d × %d", real_w, real_h) }
        if size and size ~= "" then parts[#parts + 1] = human(size) end
        if fmt and fmt ~= "" then parts[#parts + 1] = fmt end
        local rest = table.concat(parts, "  ·  ")
        local version = (mtime and mtime ~= "") and mtime or "1"
        if NATIVE[ext_of(path)] and not turned then
            finish({ src = path .. "?" .. version, file = path, w = w, h = h, rest = rest })
            return
        end
        -- a copy pleamar can read
        if not st.tmp then finish({ bad = true, why = "There is no room to open this picture" }) return end
        st.n = st.n + 1
        local out_path = st.tmp .. "/" .. st.n .. ".png"
        run("sh", { "-c", 'magick "$1[0]" -auto-orient -define png:compression-level=1 "$2" 2> /dev/null && magick identify -ping -format "%w %h" "$2"', "sh", path, out_path }, function(o2, c2)
            local cw, ch = (o2 or ""):match("(%d+) (%d+)")
            cw, ch = tonumber(cw), tonumber(ch)
            if c2 ~= 0 or not cw then finish({ bad = true, why = "This picture could not be opened" }) return end
            finish({ src = out_path .. "?" .. version, file = out_path, copy = true, w = cw, h = ch, rest = rest })
        end)
    end)
end

-- The pictures either side are got ready while this one is looked at, and drawn out of sight (`pre_a`, `pre_b` in the scene), so going to one of them
-- shows it at once instead of after it has been measured, copied and decoded.
local function preload()
    local count = #st.names
    if count < 2 then text.pre_a = ""; text.pre_b = "" return end
    local i = st.i
    local nexti = i % count + 1
    local previ = (i - 2) % count + 1
    local function one(k, slot)
        local p = path_at(k)
        if not p then return end
        prepare(p, function(m)
            if st.i ~= i then return end
            text[slot] = m.src or ""
        end)
    end
    one(nexti, "pre_a")
    if previ ~= nexti then one(previ, "pre_b") else text.pre_b = "" end
end

local fill_info

show = function(i)
    local count = #st.names
    fact.count = count
    if count == 0 then
        fact.idx = 0
        fact.has_name = false
        text.name = ""
        text.sub = ""
        fact.playing = false
        nothing(nil)                          -- an empty folder: no words, just Peek and the button
        return
    end
    if i < 1 then i = count elseif i > count then i = 1 end
    st.i = i
    fact.idx = i
    local path = current()
    if st.tmp then run("sh", { "-c", 'printf "%s" "$2" > "$1/current"', "sh", st.tmp, path }, function() end) end
    fact.has_name = true
    text.name = st.names[i]
    -- The copies made for pictures pleamar cannot read as they are (EXIF-turned photos, HEIC, TIFF...) are full size and live in the runtime
    -- folder, which is memory: only this picture's and its two neighbours' are kept. (Every one looked at stayed until logout.)
    do
        local keep = { [path] = true }
        if count > 1 then
            keep[st.dir .. "/" .. st.names[(i % count) + 1]] = true
            keep[st.dir .. "/" .. st.names[((i - 2) % count) + 1]] = true
        end
        local gone = {}
        for p, m in pairs(st.meta) do
            if m.copy and not keep[p] then gone[#gone + 1] = m.file; st.meta[p] = nil end
        end
        if #gone > 0 then run("sh", { "-c", 'rm -f -- "$@"', "sh", table.unpack(gone) }, function() end) end
    end
    local known = st.meta[path] ~= nil
    if not known then fact.ready = false; fact.has_msg = false end
    prepare(path, function(m)
        if st.i ~= i or current() ~= path then return end            -- gone on to another meanwhile
        if m.bad then
            fact.is_video = false
            st.rest = ""
            text.sub = sub_line()
            nothing(m.why or "This file could not be read as a picture", m.why and "" or "It may be damaged, or a kind of file View does not know", true, "Show it in Files", path)
            preload()
            return
        end
        st.rest = m.rest
        fact.is_video = m.video and true or false
        st.shown = st.shown + 1
        fact.iw = m.w
        fact.ih = m.h
        text.src = m.src
        text.sub = sub_line()
        fact.has_msg = false
        text.msg = ""
        fact.gen = st.shown
        fact.ready = true
        if fact.info_on then fill_info() end
        preload()
    end)
end

-- The folder's pictures, in order, and the one named chosen (or the first). `keep` keeps the one shown when it is still there.
local function list(dir, pick, after_list)
    local tests = {}
    for _, e in ipairs(PICTURES) do tests[#tests + 1] = '-iname "*.' .. e .. '"' end
    for _, e in ipairs(VIDEOS) do tests[#tests + 1] = '-iname "*.' .. e .. '"' end
    local hide = st.hidden and "" or '! -name ".*" '
    local script = 'cd "$1" 2> /dev/null || exit 3; find . -maxdepth 1 -type f ' .. hide .. '\\( ' .. table.concat(tests, " -o ") .. ' \\) -printf "%f\\n" | LC_ALL=C sort -f -V'
    run("sh", { "-c", script, "sh", dir }, function(out, code)
        if code == 3 then
            st.names = {}
            fact.count = 0
            nothing("This folder could not be opened", "It may be gone, or not yours to look in", true)
            return
        end
        local names = {}
        for line in (out or ""):gmatch("[^\n]+") do names[#names + 1] = line end
        st.dir = dir
        st.names = names
        local at = nil
        if pick then for k, n in ipairs(names) do if n == pick then at = k break end end end
        if after_list then after_list(at) end
    end)
end

local function open(path)
    path = trim(path)
    if path == "" then path = "." end
    run("sh", { "-c", 'if [ -d "$1" ]; then cd "$1" && pwd && echo; elif [ -e "$1" ]; then cd "$(dirname "$1")" && pwd && basename "$1"; else exit 4; fi', "sh", path }, function(out, code)
        local dir, pick = (out or ""):match("^([^\n]*)\n?([^\n]*)")   -- a folder gives its path alone: `run` drops the blank line after it
        if code ~= 0 or not dir or dir == "" then
            fact.has_name = path ~= "."
            text.name = base_of(path)
            nothing("This file is not there any more", "It was moved, renamed or put in the trash", true, "Open its folder in Files", path:match("^(.*)/[^/]*$"))
            return
        end
        if pick == "" then pick = nil end
        st.hidden = pick ~= nil and pick:sub(1, 1) == "."
        list(dir, pick, function(at)
            if pick and not at then
                -- not a picture by its name (a file with no extension, say): shown by itself, if ImageMagick can read it
                table.insert(st.names, 1, pick)
                at = 1
            end
            show(at or 1)
        end)
    end)
end

-- ── what the scene says ──
on("nav", function(d)
    d = tonumber(d) or 1
    if #st.names == 0 then return end
    if d == -2 then show(1) elseif d == 2 then show(#st.names) else show(st.i + d) end
end)

-- a double click is two clicks inside 350 ms, without moving the picture between them
on("tap", function(still)
    if tonumber(still) ~= 1 then st.tap_at = false return end
    if st.tap_at then
        st.tap_at = false
        emit("dbl")
        return
    end
    st.tap_at = true
    local mine = {}
    st.tap_token = mine
    after(350, function() if st.tap_token == mine then st.tap_at = false end end)
end)

-- Edit: Snap opens the picture to draw on, as the Capture window's recent screenshots do (SNAP_FILE, the whole-screen layout), on the monitor that has
-- the pointer's focus, in the shell's typeface (View's own font setup, which bin/vitreus-view took from the shell, goes on to it). The path goes in as an argument, never into the script.
on("do_edit", function()
    local path = current()
    if not path then return end
    local script = 'v="${VIEW_SHELL:-$HOME/.config/pleamar/shells/vitreus}"; p="$v/snap/snap.plm"; [ -f "$p" ] || exit 3; '
        .. 'pgrep -f "pleamar --scene $p" > /dev/null && exit 4; '
        .. 'o=$(hyprctl -j monitors 2> /dev/null | jq -r ".[] | select(.focused) | .name" 2> /dev/null | head -n 1); '
        .. 'export SNAP_FILE="$1" SNAP_FULL=1; '
        .. 'if [ -n "$o" ]; then SNAP_OUTPUT="$o" setsid pleamar --scene "$p" --no-hud --screen "$o" > /dev/null 2>&1 & else setsid pleamar --scene "$p" --no-hud > /dev/null 2>&1 & fi'
    run("sh", { "-c", script, "sh", path }, function(_, code)
        if code == 3 then say("Snap is not there")
        elseif code == 4 then say("Snap is already open")
        elseif code ~= 0 then say("Snap could not be opened") end
    end)
end)

-- The button under Peek: Files, at the folder `nothing` said (the file itself is shown selected, as Show in Files does), or else at the Pictures folder
-- (the home folder, without one). The picture chosen there comes back to this window (`open_req`).
on("do_browse", function()
    -- the button says «Opening Files» for a while (the scene set `opening`): long enough for Files to come up, then it is a button again
    st.open_n = (st.open_n or 0) + 1
    local n = st.open_n
    after(2500, function() if st.open_n == n then fact.opening = false end end)
    -- this window waits for what is chosen there (bin/vitreus-view hands it over): its name, for `pleamar --say`
    local wait = 'n=$VIEW_NAME; if [ -n "$n" ]; then d="${XDG_RUNTIME_DIR:-/tmp}/vitreus-view"; mkdir -p "$d" && printf "%s\\n" "$n" > "$d/waiting"; fi; '
    local script = wait .. 'v="${VIEW_SHELL:-$HOME/.config/pleamar/shells/vitreus}"; p=$1; '
        .. 'if [ -z "$p" ] || [ ! -e "$p" ]; then p=$(xdg-user-dir PICTURES 2> /dev/null); [ -n "$p" ] && [ -d "$p" ] || p=$HOME; fi; '
        .. 'setsid "$v/bin/vitreus-files" "$p" > /dev/null 2>&1 &'
    run("sh", { "-c", script, "sh", st.browse or "" }, function() end)
end)

local to_player                 -- (below, with Play: the player takes this window's place)

-- A picture handed over by bin/vitreus-view (chosen in Files after the button above): opened here, and this window brought to the front.
on("text:open_req", function(p)
    p = trim(p or "")
    if p == "" then return end
    fact.opening = false
    open(p)
    -- a video: it plays at once, the player taking this window's place (View comes back on it when the player closes)
    if IS_VIDEO[ext_of(p)] then say("Opening it in the player…"); to_player(p, p) return end
    run("sh", { "-c", 'hyprctl dispatch focuswindow "pid:$PPID" > /dev/null 2>&1' }, function() end)
end)

-- Show in Files: its folder, with it chosen.
on("do_reveal", function()
    local path = current() or (st.dir and st.dir)
    if not path then return end
    run("sh", { "-c", 'v="${VIEW_SHELL:-$HOME/.config/pleamar/shells/vitreus}"; setsid "$v/bin/vitreus-files" "$1" > /dev/null 2>&1 &', "sh", path }, function() end)
end)

-- Copy: the picture itself to the clipboard, as a PNG (what every program can paste); a PNG goes as it is.
on("do_copy", function()
    local path = current()
    if not path then return end
    local script = 'case "$1" in *.png|*.PNG) wl-copy -t image/png < "$1" ;; *) magick "$1[0]" -auto-orient png:- | wl-copy -t image/png ;; esac'
    run("sh", { "-c", script, "sh", path }, function(_, code)
        if code == 0 then say("Copied") else say("It could not be copied") end
    end, { output = false })   -- (wl-copy stays behind holding the clipboard: waiting for its output ended only at the next copy)
end)

-- The trash: `gio trash`, so it can be taken back out of it in Files. Then the next one (or the one before, at the end).
on("do_trash", function()
    local path = current()
    if not path then return end
    local i = st.i
    run("gio", { "trash", path }, function(_, code)
        if code ~= 0 then say("It could not be put in the trash") return end
        st.meta[path] = nil
        table.remove(st.names, i)
        say("Moved to the trash")
        if #st.names == 0 then show(1) else show(math.min(i, #st.names)) end
    end)
end)

-- The wallpaper: given to awww, as Files does; Vitreus sees awww change (it asks it every few seconds) and takes it as its own, Iris's colours and all.
-- A picture shown from a copy (HEIC, a turned photo...) is copied again where it stays (the runtime folder goes with the session): the data folder's
-- view-wallpapers/, under its own name.
on("do_wall", function()
    local path = current()
    local m = path and st.meta[path]
    if not m or m.bad or m.video then return end
    local function set(pic)
        run("awww", { "img", pic, "--transition-type", "fade", "--transition-duration", "0.8" }, function(_, code)
            say(code == 0 and "That is the wallpaper now" or "The wallpaper could not be changed (is awww running?)")
        end)
    end
    if not m.copy then set(path) return end
    local script = 'd="${XDG_DATA_HOME:-$HOME/.local/share}/pleamar/vitreus/view-wallpapers"; mkdir -p "$d" && n=$(basename "$2"); f="$d/${n%.*}.png"; cp "$1" "$f" && echo "$f"'
    run("sh", { "-c", script, "sh", m.file, path }, function(out, code)
        local f = trim(out)
        if code ~= 0 or f == "" then say("The wallpaper could not be changed") return end
        set(f)
    end)
end)

-- Play: the video shown, in View's player (bin/vitreus-view: mpv, with the others of its folder after it). pleamar cannot draw a video itself, so the
-- player takes this window's place: it is put where this window is (Hyprland: `VIEW_AT`, floating or not and where), this window closes, and once the
-- player closes View comes back there on `back` (`VIEW_BACK`: the video, or the folder that was shown). The slideshow stops.
to_player = function(what, back)
    local script = 'g=$(hyprctl -j clients 2> /dev/null | jq -r --argjson p "$PPID" \'.[] | select(.pid == $p) | "\\(if .floating then 1 else 0 end) \\(.at[0]) \\(.at[1]) \\(.size[0]) \\(.size[1])"\' 2> /dev/null | head -n 1); '
        .. 'v="${VIEW_SHELL:-$HOME/.config/pleamar/shells/vitreus}"; VIEW_AT="$g" VIEW_BACK="$2" VIEW_FROM="$VIEW_NAME" setsid "$v/bin/vitreus-view" "$1" > /dev/null 2>&1 < /dev/null & '
        .. '[ -n "$VIEW_NAME" ] || exit 9'
    -- this window closes once the player's is up (bin/vitreus-view says `bye`); started without a name to be told by, after a moment
    run("sh", { "-c", script, "sh", what, back or "" }, function(_, code)
        if code == 9 then after(900, function() emit("bye") end) end
    end)
end
on("do_play", function()
    local path = current()
    local m = path and st.meta[path]
    if not m or not m.video then return end
    fact.playing = false
    say("Opening it in the player…")
    to_player(path, path)
end)

-- A link written under Peek's button: a video's page (or the video itself) on the web, played in View's player (mpv finds the video with yt-dlp).
on("do_link", function()
    local url = trim(text.link)
    if url == "" then return end
    if not url:find("^https?://") then
        if url:find("^[%w-]+%.[%w.-]+/") or url:find("^www%.") then url = "https://" .. url
        else say("That is not a web link") return end
    end
    text.link = ""
    say("Opening it in the player…")
    to_player(url, current() or st.dir or st.home or "")
end)

-- Cast: the picture or the video shown, on a TV (a Chromecast, or a TV with one built in), with catt. Pressing Cast opens the list of what is on the
-- network (`catt scan`, a few seconds; TVs and screens first, speakers after them, which only play the sound), with the one used last marked; the
-- one chosen is used, and kept as catt's default (`set_default`), so the video player's Cast and the next time start from it. Pressed again while
-- it plays (lit), Cast stops that TV.
-- catt serves a file of this computer to the TV for as long as the TV shows it, so it is started apart (setsid) and outlives View; it is watched for
-- ten seconds, and if it gave up by then (the TV said no, it was not there), its last words are said here. A picture shown from a copy (HEIC, a
-- turned photo) goes as that copy, which the TV can read. A device is named by its address: a name can carry spaces of its own at the end.
local CAST = 'command -v catt > /dev/null 2>&1 || exit 3; log=$(mktemp); setsid catt -d "$2" cast "$1" > "$log" 2>&1 < /dev/null & pid=$!; i=0; '
    .. 'while [ $i -lt 20 ] && kill -0 $pid 2> /dev/null; do sleep 0.5; i=$((i + 1)); done; '
    .. 'if kill -0 $pid 2> /dev/null; then rm -f "$log"; exit 0; fi; wait $pid; c=$?; '
    .. 'if [ $c -eq 0 ]; then rm -f "$log"; exit 0; fi; grep -v "^[[:space:]]*$" "$log" | tail -n 1; rm -f "$log"; exit 1'
local SCAN = 'command -v catt > /dev/null 2>&1 || exit 3; '
    .. 'd=$(sed -n "s/^device *= *//p" "${XDG_CONFIG_HOME:-$HOME/.config}/catt/catt.cfg" 2> /dev/null | head -n 1); printf "default\\t%s\\n" "$d"; '
    .. 'catt scan -j 2> /dev/null | jq -r \'to_entries[] | [.value.host, (.value.friendly_name | gsub("^\\\\s+|\\\\s+$"; "")), (.value.manufacturer // ""), (.value.model_name // "")] | @tsv\''
local SPEAKER = { "mini", "audio", "speaker", "home$", "max$", "chromecast audio" }
local cast_tvs = {}
local cast_host = nil
local function is_speaker(model)
    local m = (model or ""):lower()
    for _, k in ipairs(SPEAKER) do if m:find(k) then return true end end
    return false
end
local function scan()
    fact.scanning = true
    st.scan_n = (st.scan_n or 0) + 1
    local n = st.scan_n
    run("sh", { "-c", SCAN }, function(out, code)
        if n ~= st.scan_n then return end
        fact.scanning = false
        if code == 3 then fact.cast_pick = false; say("Casting needs catt (yay -S catt)") return end
        local def = ""
        local screens, speakers = {}, {}
        for line in (out or ""):gmatch("[^\n]+") do
            local a, b, c, d = line:match("^([^\t]*)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)$")
            if a == "default" then def = trim(b or "")
            elseif a and a ~= "" then
                local tv = { host = a, name = b ~= "" and b or a, maker = c or "", model = d or "" }
                if is_speaker(tv.model) then tv.kind = "Speaker  ·  sound only"; speakers[#speakers + 1] = tv
                else tv.kind = trim(tv.maker .. " " .. tv.model); screens[#screens + 1] = tv end
            end
        end
        for _, tv in ipairs(speakers) do screens[#screens + 1] = tv end
        cast_tvs = {}
        local rows = {}
        for i, tv in ipairs(screens) do
            if i > 8 then break end
            cast_tvs[i] = tv
            local on = def ~= "" and (def == tv.host or def == tv.name)
            rows[i] = { name = tv.name, kind = tv.kind ~= "" and tv.kind or tv.host, on = on }
        end
        model.tvs = rows
        fact.tv_n = #rows
    end)
end
local function cast_to(tv)
    local path = current()
    local m = path and st.meta[path]
    if not m or m.bad then return end
    local what = (m.copy and not m.video) and m.file or path
    fact.playing = false
    fact.casting = true
    cast_host = tv.host
    say("Sending it to " .. tv.name .. "…")
    run("sh", { "-c", 'catt -d "$1" set_default > /dev/null 2>&1', "sh", tv.host }, function() end)
    run("sh", { "-c", CAST, "sh", what, tv.host }, function(out, code)
        if code == 0 then say("On " .. tv.name) return end
        fact.casting = false
        if code == 3 then say("Casting needs catt (yay -S catt)") return end
        local why = trim(out):gsub("^Error:%s*", "")
        say(why ~= "" and ("Could not cast: " .. cut_words(why)) or ("Could not cast: " .. tv.name .. " did not answer"))
    end)
end
on("do_cast", function()
    if fact.casting then
        fact.casting = false
        fact.cast_pick = false
        run("sh", { "-c", 'if [ -n "$1" ]; then catt -d "$1" stop; else catt stop; fi > /dev/null 2>&1', "sh", cast_host or "" }, function() end)
        say("Stopped the TV")
        return
    end
    if fact.cast_pick then fact.cast_pick = false return end
    local path = current()
    local m = path and st.meta[path]
    if not m or m.bad then return end
    fact.cast_pick = true
    scan()
end)
on("pick_tv", function(i)
    local tv = cast_tvs[(tonumber(i) or -1) + 1]
    fact.cast_pick = false
    if tv then cast_to(tv) end
end)

-- The details card: what the file is, where, and what the camera wrote in it (EXIF), when it did. Filled again for each picture while it is open.
local function cut(v, n) if #v > n then return v:sub(1, n - 1) .. "…" end return v end
fill_info = function()
    local path = current()
    local m = path and st.meta[path]
    if not path then model.info = {} fact.info_n = 0 return end
    local i = st.i
    local fmt = '%m|%w|%h|%[colorspace]|%z|%n|%[EXIF:Make]|%[EXIF:Model]|%[EXIF:LensModel]|%[EXIF:DateTimeOriginal]|%[EXIF:ExposureTime]|%[EXIF:FNumber]|%[EXIF:PhotographicSensitivity]|%[EXIF:ISOSpeedRatings]|%[EXIF:FocalLength]\\n'
    run("sh", { "-c", 'magick identify -format "' .. fmt .. '" "$1[0]" 2> /dev/null | head -n 1; stat -c "%s|%y" "$1" 2> /dev/null; magick identify -format "%n\\n" "$1" 2> /dev/null | tail -n 1', "sh", path }, function(out)
        if st.i ~= i then return end
        local lines = {}
        for l in ((out or "") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
        local f = {}
        for v in ((lines[1] or "") .. "|"):gmatch("([^|]*)|") do f[#f + 1] = trim(v) end
        local size, when = (lines[2] or ""):match("^(%d+)|(%S+ %d+:%d+)")
        local frames = tonumber(lines[3] or "") or 1
        local rows = {}
        local function add(k, v) if v and v ~= "" then rows[#rows + 1] = { k = k, v = v } end end
        add("Name", cut(st.names[i] or "", 44))
        local folder = st.dir or ""
        if st.home and st.home ~= "" and (folder == st.home or folder:sub(1, #st.home + 1) == st.home .. "/") then folder = "~" .. folder:sub(#st.home + 1) end
        if #folder > 44 then folder = "…" .. folder:sub(-43) end        -- a long folder keeps its end, which is the part that says where it is
        add("Folder", folder)
        if m and not m.bad then add("Size", m.rest:match("^([^·]+)") and trim(m.rest:match("^([^·]+)")) .. " px") end
        add("File", size and human(size) or nil)
        add("Format", (f[1] or "") .. ((f[4] or "") ~= "" and ("  ·  " .. f[4]) or "") .. ((f[5] or "") ~= "" and ("  ·  " .. f[5] .. "-bit") or ""))
        if frames > 1 then add("Frames", tostring(frames)) end
        add("Modified", when)
        local cam = trim(((f[7] or "") .. " " .. (f[8] or "")))
        if f[8] and f[7] and f[8]:sub(1, #f[7]) == f[7] then cam = f[8] end     -- "Canon Canon EOS R6": the make is already in the model
        add("Camera", cut(cam, 44))
        add("Lens", cut(f[9] or "", 44))
        local taken = (f[10] or ""):gsub("^(%d+):(%d+):(%d+)", "%1-%2-%3")
        add("Taken", taken)
        local function num(v)
            local a, b = (v or ""):match("^(%d+)/(%d+)$")
            if a then return tonumber(a) / math.max(tonumber(b), 1) end
            return tonumber(v)
        end
        local ex = {}
        local et = num(f[11])
        if et then ex[#ex + 1] = et < 1 and string.format("1/%d s", math.floor(1 / et + 0.5)) or string.format("%g s", et) end
        local fn = num(f[12])
        if fn then ex[#ex + 1] = string.format("f/%g", math.floor(fn * 10 + 0.5) / 10) end
        local iso = (f[13] ~= "" and f[13]) or f[14]
        if iso and iso ~= "" then ex[#ex + 1] = "ISO " .. iso:match("^%d+") end
        local fl = num(f[15])
        if fl then ex[#ex + 1] = string.format("%g mm", math.floor(fl * 10 + 0.5) / 10) end
        add("Exposure", table.concat(ex, "  ·  "))
        model.info = rows
        fact.info_n = #rows
    end)
end
on("do_info", function()
    fact.info_on = not fact.info_on
    if fact.info_on then fill_info() end
end)

-- The whole screen: Hyprland's fullscreen for this window (it has the keyboard, so it is the active one).
on("do_full", function()
    run("hyprctl", { "dispatch", "fullscreen", "0" }, function() end)
end)

-- ── the theme, asked of Vitreus ──
local GLASS_FACTS = { gop = "glass_op", gbend = "files_bend", grefr = "glass_refr", gdisp = "glass_disp", gclear = "glass_clear", gdome = "glass_dome", gmilk = "glass_milk", gsmoke = "glass_smoke", grim = "glass_rim" }
local function ask_theme()
    if not st.look_fixed then
        run("pleamar", { "--say", "vitreus", "get look_v" }, function(out, code)
            if code ~= 0 or not out then return end
            local v = tonumber(out:match("%-?%d+"))
            if v and v >= 0 then fact.look = LOOKS[v] or 0 end
        end)
    end
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
    for mine, theirs in pairs(GLASS_FACTS) do
        run("pleamar", { "--say", "vitreus", "get " .. theirs }, function(out, code)
            if code ~= 0 or not out then return end
            if mine == "gbend" then fact.gbend = out:match("true") ~= nil
            else
                local n = tonumber(out:match("%-?[%d.]+"))
                if n then fact[mine] = n end
            end
        end)
    end
end

-- the window's corners, as Hyprland rounds them
local function ask_round()
    run("hyprctl", { "getoption", "decoration:rounding", "-j" }, function(out, code)
        local n = code == 0 and out and tonumber(out:match('"int"%s*:%s*(%-?%d+)'))
        if n and n >= 0 then fact.wr = n return end
        -- not Hyprland (pleamar-wm): the shell knows the windows' corners (Settings > Pleamar-WM)
        run("pleamar", { "--say", "vitreus", "get hy_round" }, function(o, c)
            local r = c == 0 and o and tonumber(o:match("%-?[%d.]+"))
            if r and r >= 0 then fact.wr = r end
        end)
    end)
end

-- the monitor's scale, for the real size
local function ask_scale()
    run("sh", { "-c", 'hyprctl -j monitors 2> /dev/null | jq -r ".[] | select(.focused) | .scale" 2> /dev/null | head -n 1' }, function(out)
        local s = tonumber(trim(out))
        if s and s > 0 then fact.dpr = s end
    end)
end

-- Back at the window: the theme may have changed, and so may the folder (a picture added or taken away elsewhere).
on("focused", function()
    ask_theme()
    ask_round()
    -- The picture shown, changed meanwhile (the Edit button, another editor): read again. (The comment above `prepare` said so; nothing did.)
    local path = st.dir and st.names[st.i] and current() or nil
    local m = path and st.meta[path]
    if m and m.src then
        run("sh", { "-c", 'stat -c %Y -- "$1"', "sh", path }, function(out)
            local v = trim(out)
            if v ~= "" and current() == path and not (m.src:sub(-#v - 1) == "?" .. v) then
                if m.copy then run("sh", { "-c", 'rm -f -- "$1"', "sh", m.file }, function() end) end
                st.meta[path] = nil
                show(st.i)
            end
        end)
    end
    if st.dir then
        local keep = st.names[st.i]
        list(st.dir, keep, function(at)
            if at then
                st.i = at
                fact.idx = at
                fact.count = #st.names
                text.sub = sub_line()          -- only the line under the name changes (which of how many)
            elseif keep then
                show(math.min(st.i, #st.names))         -- it went (renamed, deleted): the one in its place
            end
        end)
    end
end)

-- ── starting ──
run("printenv", { "VIEW_LOOK" }, function(out, code)
    local v = tonumber(trim(out))
    if code == 0 and v then st.look_fixed = true; fact.look = math.max(0, math.min(4, math.floor(v))) end
    ask_theme()
end)
run("printenv", { "HOME" }, function(out) st.home = trim(out) end)
ask_scale()
ask_round()
-- The runtime folder is named after pleamar's own process (the shell's $PPID), so it is the same when the scene reloads: a new theme rewrites ../palette.plm,
-- which reloads View and starts this logic again. The picture shown is kept there (`current`), and a reload opens it rather than the one View started with.
-- (the folders of View windows that have closed go first: each window left its own behind, copies and all, until logout)
run("sh", { "-c", 'for o in "${XDG_RUNTIME_DIR:-/tmp}"/vitreus-view/*/; do p=$(basename "$o"); case $p in *[!0-9]*) continue ;; esac; [ -d "/proc/$p" ] || rm -rf -- "$o"; done; '
    .. 'd="${XDG_RUNTIME_DIR:-/tmp}/vitreus-view/$PPID"; mkdir -p "$d" && chmod 700 "$d" && echo "$d" && { cat "$d/current" 2> /dev/null; true; }' }, function(out, code)
    local d, cur = (out or ""):match("^([^\n]*)\n?(.*)$")
    if code == 0 and d and d ~= "" then st.tmp = d end
    cur = trim(cur)
    if cur ~= "" then open(cur) return end
    run("printenv", { "VIEW_START" }, function(o, c)
        local p = trim(o)
        if c ~= 0 or p == "" then p = "." end
        open(p)
    end)
end)
