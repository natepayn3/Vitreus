-- Files: the logic of the file manager. It lists a folder with `find`, hands the scene only the rows that are on screen (a folder of thousands costs what a folder of ten does), and does the work
-- with ordinary commands: `xdg-open` to open, `mkdir`, `mv`, `cp -a`, `gio trash`, `bsdtar`, `ln` and so on, each as a job that can be watched, stopped and taken back.
-- It starts in the folder named by $FILES_START when there is one, else in the home folder.
-- What is kept, in this scene's own folder (~/.local/share/pleamar/files): files.json (the view, the sort order, hidden files, zoom, the folders you pinned and the files you starred) and the
-- pictures made for the files' faces.
--
-- This file is put together from lparts/*.luau by build.sh; the pieces are in the order they are needed. Functions live in the table F (and the state in `s`) because a chunk of Luau can only
-- have so many locals.

local GRID_ROWS = 12        -- rows of tiles sent to the scene at once (it declares 12: every record it declares is worked out when it starts, so the fewer the quicker Files opens)
local LINES_PER_ROW = 10    -- in the lines view a row of the scene is a block of this many lines, one under the other: a window full of them is a few blocks, and the scene stays small
local LINES_ROWS = 5        -- ... and this many blocks are sent at once
local MAX_COLS = 10
local LINES_H = 38
local MENU_ROW = 32         -- how tall a line of the menu is (the scene says the same, `mrh`)
local ZOOMS = { 96, 112, 128, 160, 208 }

local s = {
    home = "", data = "", path = "", items = {}, all = {}, back = {}, fwd = {}, picked = {}, anchor = nil, cursor = nil,
    cols = 6, first = 0, scroll = 0, view = "grid", hidden = false, sort = "name", sortrev = false, dirfirst = true, zoom = 3,
    qtext = "", mode = nil, results = nil,      -- the search: what is typed; `filter` (this folder, as you type) or `deep` (the folders under it too, `results`); `recent` and `starred` are lists too
    clip = nil, places = {}, pins = {}, stars = {}, crumbw = 300, crumbs = {}, ask = nil, tick = 0, last_i = nil, last_tick = -100, menu = nil, free = "",
    tabs = {}, tab = 1, vh = 400, tilew = 128,
    undo = {}, flash_until = 0, devices = {}, nets = {},
    so = { where = 0, what = 0, kind = 0 },
}
local F = {}

-- ── small things ──
local function trim(t) return ((t or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function basename(p) return p:match("([^/]+)/*$") or "/" end
local function dirname(p)
    local d = p:gsub("/+$", ""):match("^(.*)/[^/]*$")
    if d == nil then return "/" end
    return d == "" and "/" or d
end
local function join(dir, name) return (dir == "/" and "" or dir) .. "/" .. name end
local function clean(p)
    p = p:gsub("/+", "/")
    -- "." and ".." are taken out: a/b/../c is a/c
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then parts[#parts] = nil
        elseif seg ~= "." then parts[#parts + 1] = seg end
    end
    return "/" .. table.concat(parts, "/")
end
local function size_text(n)
    n = tonumber(n) or 0
    if n < 1000 then return string.format("%d B", n) end
    local units = { "KB", "MB", "GB", "TB" }
    local v = n
    for i = 1, #units do
        v = v / 1000
        if v < 1000 or i == #units then
            return string.format(v < 10 and "%.1f %s" or "%.0f %s", v, units[i])
        end
    end
end
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local function date_text(t)
    t = math.floor(tonumber(t) or 0)
    local ok, v = pcall(os.date, "%d %b %Y, %H:%M", t)
    if ok and type(v) == "string" and v ~= "" then return v end
    -- (without os.date: the day, in UTC)
    local days = math.floor(t / 86400)
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return string.format("%d %s %d", d, MONTHS[m], y)
end
local function commas(n)
    local t = tostring(math.floor(tonumber(n) or 0))
    local out = t:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
local function unescape(u) return (u:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function uri_of(path)
    return "file://" .. path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end)
end
local function copy_set(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end
local function count_set(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
local function plural(n, one, many) return n == 1 and one or many end
local function ext_of(name) local e = name:match("%.([^.]+)$"); return e and e:lower() or "" end
-- the name without its last extension ("a.tar.gz" without ".tar.gz", too)
local function stem_of(name)
    local st = name:gsub("%.tar%.[%w]+$", "")
    if st == name then st = name:gsub("%.[^.]+$", "") end
    if st == "" then st = name end
    return st
end

-- Who is holding Shift and Ctrl (the keyboard says it, a click does not).
local function mods()
    local shift = held("Shift_L") or held("Shift_R")
    local ctrl = held("Control_L") or held("Control_R")
    local alt = held("Alt_L") or held("Alt_R")
    return shift == true, ctrl == true, alt == true
end

-- a message that stays in the bar for a while (the bar goes back to saying how many things there are afterwards)
local function say(msg, secs)
    text.status = msg
    s.flash_msg = msg
    s.flash_until = s.tick + math.floor((secs or 5) * 20)
end

-- what went wrong, in words, from what a command printed
local function why(err)
    err = err or ""
    local l = err:lower()
    if l:find("permission denied", 1, true) or l:find("operation not permitted", 1, true) then return "no permission" end
    if l:find("no space left", 1, true) then return "the disk is full" end
    if l:find("read-only file system", 1, true) then return "the disk is read-only" end
    if l:find("file name too long", 1, true) then return "the name is too long" end
    if l:find("no such file", 1, true) then return "it is not there any more" end
    if l:find("not empty", 1, true) then return "the folder is not empty" end
    if l:find("not supported", 1, true) then return "that is not supported here" end
    if l:find("cross-device", 1, true) then return "it is on another disk" end
    if l:find("are the same file", 1, true) then return "it is the same file" end
    if l:find("not a directory", 1, true) then return "that is not a folder" end
    if l:find("exists", 1, true) then return "the name is taken" end
    local first = trim(err:match("[^\n]+") or "")
    first = first:gsub("^[%w%-]+: ", "")
    if first ~= "" then return (#first > 60 and (first:sub(1, 59) .. "…") or first) end
    return "it did not work"
end

-- ── what a file is ──
local EXT = {}
for kind, list in pairs({
    image = "png jpg jpeg gif webp bmp svg tif tiff avif heic heif ico jxl",
    pdf = "pdf",
    audio = "mp3 flac ogg opus wav m4a aac wma aiff mid midi",
    video = "mp4 mkv webm avi mov wmv flv m4v mpg mpeg ogv",
    code = "lua luau py js ts tsx jsx rs c h cpp hpp cc go java kt sh bash zsh fish json toml yaml yml xml html css scss plm md rb php cs swift sql conf cfg ini txt log csv tsv qml rst tex",
    archive = "zip tar gz xz zst bz2 7z rar tgz iso lz4 cab deb rpm",
    doc = "doc docx odt ods odp xls xlsx ppt pptx rtf epub mobi djvu pages numbers key",
    exec = "appimage desktop exe msi run bin",
}) do
    for e in list:gmatch("%S+") do EXT[e] = kind end
end
local KIND_NUM = { image = 1, pdf = 2, audio = 3, video = 4, code = 5, archive = 6, doc = 9, exec = 8 }
local function ik_of(name, dir, mode)
    if dir then return 0 end
    local e = name:match("%.([^.]+)$")
    local k = e and KIND_NUM[EXT[e:lower()] or ""]
    if k then return k end
    if mode and bit32.band(mode, 73) ~= 0 then return 8 end       -- an executable with a name that says nothing else
    return 7
end
local KIND_LABEL = { [0] = "Folder", "Picture", "PDF document", "Sound", "Video", "Code or text", "Archive", "File", "Program", "Document" }
local function kind_text(e)
    if e.dir then return e.link and "Link to a folder" or "Folder" end
    local x = ext_of(e.name)
    local ik = e.ik
    if ik == 2 then return "PDF document" end
    if ik == 8 then return "Program" end
    if x == "" then return KIND_LABEL[ik] or "File" end
    if ik == 1 then return x:upper() .. " picture" end
    if ik == 3 then return x:upper() .. " sound" end
    if ik == 4 then return x:upper() .. " video" end
    if ik == 6 then return x:upper() .. " archive" end
    if ik == 9 then return x:upper() .. " document" end
    if ik == 5 then return x:upper() .. " text" end
    return x:upper() .. " file"
end
-- which of the search's kinds a thing is: 1 folders, 2 pictures, 3 documents, 4 sounds, 5 videos
local function kind_ok(e, k)
    if k == 0 then return true end
    if k == 1 then return e.dir end
    if e.dir then return false end
    if k == 2 then return e.ik == 1 end
    if k == 3 then return e.ik == 2 or e.ik == 9 or e.ik == 5 end
    if k == 4 then return e.ik == 3 end
    if k == 5 then return e.ik == 4 end
    return true
end

-- the order: by name the way a person counts (file2 before file10), folders first unless that is turned off, the other way round when asked
local function nkey(name)
    return (name:lower():gsub("%d+", function(d) return string.rep("0", math.max(0, 12 - #d)) .. d end))
end
local function make_item(path, name, dir, size, mtime, mode, link, broken)
    return {
        name = name, path = path, dir = dir, size = size, mtime = mtime, hidden = name:sub(1, 1) == ".", ik = ik_of(name, dir, mode),
        nkey = nkey(name), link = link, broken = broken, mode = mode,
    }
end

local function sorted(items)
    local out = {}
    local q = s.mode == "filter" and s.qtext ~= "" and s.qtext:lower() or nil
    local kind = (s.mode == "filter") and s.so.kind or 0
    for _, e in ipairs(items) do
        if (s.hidden or not e.hidden or s.list) and (not q or e.name:lower():find(q, 1, true)) and kind_ok(e, kind) then out[#out + 1] = e end
    end
    if s.list == "recent" then
        table.sort(out, function(a, b) return (a.rank or 0) < (b.rank or 0) end)
        return out
    end
    local rev = s.sortrev
    local key = s.sort
    table.sort(out, function(a, b)
        if s.dirfirst and a.dir ~= b.dir then return a.dir end
        local c = 0
        if key == "date" then
            if a.mtime ~= b.mtime then c = a.mtime > b.mtime and -1 or 1 end
        elseif key == "size" then
            if not a.dir and not b.dir and a.size ~= b.size then c = a.size > b.size and -1 or 1 end    -- (a folder's own size is the room its list takes: they go by name)
        elseif key == "type" then
            local x, y = ext_of(a.name), ext_of(b.name)
            if a.dir ~= b.dir then c = a.dir and -1 or 1
            elseif x ~= y then c = x < y and -1 or 1 end
        end
        if c == 0 then
            if a.nkey ~= b.nkey then c = a.nkey < b.nkey and -1 or 1
            elseif a.name ~= b.name then c = a.name < b.name and -1 or 1 end
        end
        if rev then return c > 0 end
        return c < 0
    end)
    return out
end

-- ── what is kept ──
local SORT_NAMES = { name = "Name", date = "Modified", size = "Size", type = "Kind" }
local function sort_label()
    return "Sort: " .. SORT_NAMES[s.sort] .. (s.sortrev and " ↑" or "")
end
function F.save()
    pcall(sys.call, "files.write", "files.json", {
        view = s.view, hidden = s.hidden, sort = s.sort, sortrev = s.sortrev, dirfirst = s.dirfirst, zoom = s.zoom,
        pins = s.pins, pins_set = true, stars = s.star_list, pin_names = s.pin_names,
    })
end
s.star_list = {}
s.pin_names = {}
do
    local ok, saved = pcall(sys.ask, "files.read", "files.json", "json")
    if ok and type(saved) == "table" then
        if saved.view == "grid" or saved.view == "lines" then s.view = saved.view end
        if type(saved.hidden) == "boolean" then s.hidden = saved.hidden end
        if SORT_NAMES[saved.sort] then s.sort = saved.sort end
        if type(saved.sortrev) == "boolean" then s.sortrev = saved.sortrev end
        if type(saved.dirfirst) == "boolean" then s.dirfirst = saved.dirfirst end
        if type(saved.zoom) == "number" and saved.zoom >= 1 and saved.zoom <= #ZOOMS then s.zoom = math.floor(saved.zoom) end
        if saved.pins_set then s.pins_set = true end
        if type(saved.pins) == "table" then
            for _, p in ipairs(saved.pins) do
                if type(p) == "string" and p:sub(1, 1) == "/" then s.pins[#s.pins + 1] = p end
            end
        end
        if type(saved.pin_names) == "table" then
            for k, v in pairs(saved.pin_names) do
                if type(k) == "string" and type(v) == "string" then s.pin_names[k] = v end
            end
        end
        if type(saved.stars) == "table" then
            for _, p in ipairs(saved.stars) do
                if type(p) == "string" and p:sub(1, 1) == "/" then s.star_list[#s.star_list + 1] = p; s.stars[p] = true end
            end
        end
    end
    fact.view = s.view
    fact.hidden = s.hidden
    fact.sort = s.sort
    fact.sortrev = s.sortrev
    fact.dirfirst = s.dirfirst
    fact.zoom = s.zoom
    fact.tilebase = ZOOMS[s.zoom]
end
text.sortname = sort_label()

-- ── how things are laid out (the scene says how wide a tile is and how tall the window) ──
local function tile_h() return s.view == "grid" and (s.tilew + 4) or LINES_H end
local function cols() return s.view == "grid" and s.cols or LINES_PER_ROW end       -- things to a row of the scene
local function row_h() return s.view == "grid" and tile_h() or LINES_H * LINES_PER_ROW end
local function row_window() return s.view == "grid" and GRID_ROWS or LINES_ROWS end
local function down_by() return s.view == "grid" and s.cols or 1 end        -- what the Up and Down keys move the choice by
local function item_top(idx)
    if s.view == "grid" then return math.floor((idx - 1) / s.cols) * tile_h() end
    return (idx - 1) * LINES_H
end

-- ── what the scene shows ──
local function picked_list()
    local list = {}
    for _, e in ipairs(s.items) do
        if s.picked[e.path] then list[#list + 1] = e end
    end
    return list
end

-- The place something is "in" when it is in a list made of places (a search, the recent files): the folder it is in, as a line under the count.
function F.set_status()
    if s.tick < s.flash_until and s.flash_msg then text.status = s.flash_msg return end
    local n = #s.items
    local list = picked_list()
    if #list == 0 then
        if s.mode == "deep" then
            text.status = string.format("%d %s for \"%s\"%s", n, n == 1 and "result" or "results", s.qtext, n >= 500 and " (the first 500)" or "")
        elseif s.mode == "filter" and (s.qtext ~= "" or s.so.kind ~= 0) then
            local total = 0
            for _, e in ipairs(s.all or {}) do if s.hidden or not e.hidden then total = total + 1 end end
            text.status = string.format("%d of %d", n, total)
        else
            text.status = n == 1 and "1 item" or string.format("%d items", n)
        end
    elseif #list == 1 then
        local e = list[1]
        local where = ""
        if s.mode == "deep" or s.list then where = " · " .. dirname(e.path)
        elseif e.orig then where = " · from " .. dirname(e.orig) end
        text.status = (e.dir and e.name or (e.name .. " · " .. size_text(e.size))) .. where
    else
        local total, dirs, files = 0, 0, 0
        for _, e in ipairs(list) do
            if e.dir then dirs = dirs + 1 else total = total + e.size; files = files + 1 end
        end
        local parts = {}
        if dirs > 0 then parts[#parts + 1] = string.format("%d %s", dirs, plural(dirs, "folder", "folders")) end
        if files > 0 then parts[#parts + 1] = string.format("%d %s", files, plural(files, "file", "files")) end
        text.status = table.concat(parts, ", ") .. " selected" .. (files > 0 and (" · " .. size_text(total)) or "")
    end
end

-- ── the pictures' own pictures ──
-- A small copy of each picture that is on screen is made once and kept in this scene's folder (`th-<hash of its path, size and date>.png`), so that a folder of photos shows them and not a row
-- of icons. Several are made at a time (one thread each, so they do not fight over the processor); one that cannot be made (a broken file) is left with its icon.
-- A video's picture is a frame from its first seconds, a PDF's its first page, a font's a sample of it, a song's the cover that is in it, if there is one.
local FONT_EXT = { ttf = true, otf = true, woff = true, woff2 = true, ttc = true }
local THUMB_MAX_BYTES = 300 * 1000 * 1000
local THUMB_JOBS = 6
s.thumbs, s.pending, s.queue, s.making = {}, {}, {}, 0
local tdir = nil
do
    local ok, folder = pcall(sys.ask, "files.folder")
    if ok and type(folder) == "string" and folder ~= "" then tdir = folder end
end
-- The scene's folder is only there once something has been saved in it, and magick does not make the folder it writes to.
if tdir then run("mkdir", { "-p", "--", tdir }, function() end) end
local function thumb_name(e)
    local key = e.path .. "|" .. e.size .. "|" .. e.mtime
    local h1, h2 = 7, 13
    for i = 1, #key do
        local b = key:byte(i)
        h1 = (h1 * 31 + b) % 2147483647
        h2 = (h2 * 131 + b) % 1000000007
    end
    return string.format("th-%d-%d.png", h1, h2)
end
local function can_thumb(e)
    if e.dir or e.broken then return false end
    if e.ik == 4 or e.ik == 3 then return true end                  -- a video or a song: ffmpeg only reads the start
    if e.ik == 2 then return e.size < 200 * 1000 * 1000 end
    if e.size > THUMB_MAX_BYTES then return false end
    if e.ik == 1 then return true end
    if e.ik == 7 then return FONT_EXT[ext_of(e.name)] == true end
    return false
end
local function tkey(e) return e.path .. "|" .. e.size .. "|" .. e.mtime end
function F.flush_later()
    if s.flush then return end
    s.flush = true
    after(150, function()
        s.flush = false
        F.show_rows()
    end)
end
function F.pump()
    while s.making < THUMB_JOBS and #s.queue > 0 do
        local e = table.remove(s.queue, 1)
        local name = thumb_name(e)
        local out = tdir .. "/" .. name
        if dirname(e.path) ~= s.path and s.mode == nil then
            s.pending[e.path] = nil            -- the folder has changed since: not wanted any more
        else
            s.making = s.making + 1
            local tmp = out .. ".tmp.png"
            local function done(ok)
                s.making = s.making - 1
                s.pending[e.path] = nil
                s.thumbs[tkey(e)] = ok and out or false
                F.flush_later()
                F.pump()
            end
            local function finish(code)
                if code == 0 then
                    run("mv", { "-f", "--", tmp, out }, function(_, c2) done(c2 == 0) end)
                else
                    run("rm", { "-f", "--", tmp }, function() done(false) end)
                end
            end
            if e.ik == 4 then
                -- a frame a second in (a shorter video gives none there, so the first frame is asked for then)
                local function frame(at, retry)
                    run("ffmpeg", { "-v", "error", "-y", "-ss", at, "-i", e.path, "-frames:v", "1", "-vf", "scale=288:216:force_original_aspect_ratio=increase,crop=288:216", "-compression_level", "1", tmp }, function(_, code)
                        if code ~= 0 and retry then frame("0", false) else finish(code) end
                    end)
                end
                frame("1", true)
            elseif e.ik == 3 then
                run("ffmpeg", { "-v", "error", "-y", "-i", e.path, "-an", "-frames:v", "1", "-vf", "scale=288:216:force_original_aspect_ratio=increase,crop=288:216", "-compression_level", "1", tmp }, function(_, code) finish(code) end)
            elseif e.ik == 2 then
                local base = out .. ".page"
                run("pdftoppm", { "-f", "1", "-l", "1", "-singlefile", "-png", "-scale-to-x", "576", "-scale-to-y", "-1", e.path, base }, function(_, code)
                    if code ~= 0 then done(false) return end
                    run("magick", { base .. ".png", "-background", "white", "-alpha", "remove", "-thumbnail", "288x216^", "-gravity", "north", "-extent", "288x216", "-strip", "-define", "png:compression-level=1", tmp }, function(_, c2)
                        run("rm", { "-f", "--", base .. ".png" }, function() finish(c2) end)
                    end)
                end)
            elseif e.ik == 7 then
                run("magick", { "-size", "288x216", "xc:none", "-fill", "white", "-font", e.path, "-pointsize", "96", "-gravity", "center", "-annotate", "0", "Aa", "-define", "png:compression-level=1", tmp }, function(_, code) finish(code) end)
            else
                run("magick", { "-limit", "thread", "1", "-define", "jpeg:size=480x480", e.path .. "[0]", "-auto-orient", "-thumbnail", "288x216^", "-gravity", "center", "-extent", "288x216", "-strip", "-define", "png:compression-level=1", tmp }, function(_, code) finish(code) end)
            end
        end
    end
end
-- what is on screen and has no picture yet: from the cache, or asked for
function F.prime_thumbs()
    if not tdir then return end
    local c = cols()
    local from = s.first * c + 1
    local upto = math.min(#s.items, (s.first + row_window()) * c)
    local queued = false
    for i = from, upto do
        local e = s.items[i]
        if e and can_thumb(e) then
            local k = tkey(e)
            if s.thumbs[k] == nil and not s.pending[e.path] then
                local name = thumb_name(e)
                local ok, there = pcall(sys.ask, "files.exists", name)
                if ok and there then
                    s.thumbs[k] = tdir .. "/" .. name
                else
                    s.pending[e.path] = true
                    s.queue[#s.queue + 1] = e
                    queued = true
                end
            end
        end
    end
    if queued then F.pump() end
end

-- ── the picture in the hand ──
-- While a file is dragged out, a small card goes under the pointer (the zone's `carry_icon:` is this file): a badge for the kind of thing, or its own picture, with the name and a line
-- under it ("3.0 KB", "Folder", "+2 more"). It is made with ImageMagick when a tile is pressed, so that it is there by the time the pointer has moved enough to start the drag; until it is,
-- the drag has none. Each one has a number in its file name, so that one still being made cannot be drawn over the one that was asked for next.
local ICON_W, ICON_H = 232, 64
local ICON_COLOR = { [0] = "#e0a43a", "#a86fdf", "#e0584d", "#4aa3df", "#4fb286", "#8a93a0", "#c9a14a", "#7f8c99", "#d9783c", "#5c8ad6" }
local ICON_LABEL = { [0] = "DIR", "IMG", "PDF", "SND", "VID", "TXT", "ZIP", "FILE", "RUN", "DOC" }
local icon_seq, icon_font = 0, nil
run("fc-match", { "-f", "%{file}", "Space Grotesk:bold" }, function(out, code)
    if code == 0 and type(out) == "string" and out:sub(1, 1) == "/" then icon_font = trim(out) end
end)
local function mtext(t, max)
    -- text for ImageMagick's -annotate: its `%` and `\` mean things, and a leading `@` reads a file
    t = t:gsub("[%c]", " "):gsub("^@", "")
    if #t > max then t = t:sub(1, max - 1) .. "…" end
    return (t:gsub("\\", "\\\\"):gsub("%%", "%%%%"))
end
function F.prep_drag_icon()
    text.dragicon = ""
    if not tdir then return end
    local list = picked_list()
    local first = list[1]
    if not first then return end
    icon_seq = icon_seq + 1
    local mine = icon_seq
    local out = string.format("%s/dragicon-%d.png", tdir, mine % 6)
    local sub
    if #list > 1 then sub = string.format("+%d more", #list - 1)
    elseif first.dir then sub = "Folder"
    else sub = size_text(first.size) end
    local args = { "-size", ICON_W .. "x" .. ICON_H, "xc:none", "-fill", "#1b2127ee", "-stroke", "#ffffff70", "-strokewidth", "1", "-draw", string.format("roundrectangle 1,1 %d,%d 14,14", ICON_W - 2, ICON_H - 2) }
    local thumb = (#list == 1 and not first.dir) and s.thumbs[tkey(first)] or nil
    local color = ICON_COLOR[first.ik] or ICON_COLOR[7]
    if thumb then
        -- its own picture, in the same rounded square as the badge
        for _, a in ipairs({ "(", thumb, "-auto-orient", "-resize", "46x46^", "-gravity", "center", "-extent", "46x46", "(", "-size", "46x46", "xc:none", "-fill", "white", "-draw", "roundrectangle 0,0 45,45 9,9", ")", "-alpha", "set", "-compose", "DstIn", "-composite", ")", "-gravity", "northwest", "-geometry", "+9+9", "-compose", "over", "-composite" }) do args[#args + 1] = a end
    else
        for _, a in ipairs({ "-stroke", "none", "-fill", color, "-draw", "roundrectangle 9,9 55,55 10,10" }) do args[#args + 1] = a end
        local label = #list > 1 and tostring(#list) or (ICON_LABEL[first.ik] or "FILE")
        if not first.dir and first.ik == 7 then label = (first.name:match("%.([^.]+)$") or "FILE"):upper():sub(1, 4) end
        if icon_font then args[#args + 1] = "-font"; args[#args + 1] = icon_font end
        for _, a in ipairs({ "-stroke", "none", "-fill", "white", "-pointsize", "15", "-gravity", "northwest", "-annotate", string.format("+%d+24", math.floor(32 - #label * 4.4)), mtext(label, 5) }) do args[#args + 1] = a end
    end
    if icon_font then args[#args + 1] = "-font"; args[#args + 1] = icon_font end
    for _, a in ipairs({ "-stroke", "none", "-gravity", "northwest", "-fill", "white", "-pointsize", "16", "-annotate", "+66+12", mtext(first.name, 18), "-fill", "#b8c2cc", "-pointsize", "13", "-annotate", "+66+36", mtext(sub, 20), "-define", "png:compression-level=1", out }) do args[#args + 1] = a end
    run("magick", args, function(_, code)
        if code == 0 and mine == icon_seq then text.dragicon = out end
    end)
end

local carry_all = nil      -- the whole choice as one text, made once for each showing of the rows (a folder's worth of paths, for every tile in it, would be a lot of text)
local function carry_of(e)
    -- what a drag out of this tile takes: the whole choice when this tile is in it, else just itself
    if s.picked[e.path] then
        if carry_all == nil then
            local paths = {}
            for _, it in ipairs(s.items) do if s.picked[it.path] then paths[#paths + 1] = it.path end end
            carry_all = #paths > 1 and table.concat(paths, "\n") or false
        end
        if carry_all then return carry_all end
    end
    return e.path
end

local function cell(i, e)
    local th = s.thumbs[tkey(e)]
    return {
        carry = carry_of(e),
        at = i - 1, name = e.name, ik = e.ik, thumb = th or "", ["has.thumb"] = th ~= nil and th ~= false, picked = s.picked[e.path] == true, hidden = e.hidden,
        cut = s.clip ~= nil and s.clip.cut and s.clip.set[e.path] == true, cur = s.cursor == i,
        link = e.link == true, broken = e.broken == true, star = s.stars[e.path] == true,
        size = e.dir and "" or size_text(e.size), date = e.deld or date_text(e.mtime), kind = kind_text(e),
    }
end

-- A name that says nothing of what is in the file (no ending, an ending that nobody knows): `file` is asked, for the ones on screen, a lot at a time.
local MIME_IK = {
    ["application/pdf"] = 2,
    ["application/json"] = 5, ["application/xml"] = 5, ["application/javascript"] = 5, ["application/x-shellscript"] = 5, ["application/x-desktop"] = 5, ["application/toml"] = 5, ["application/yaml"] = 5,
    ["application/zip"] = 6, ["application/x-tar"] = 6, ["application/gzip"] = 6, ["application/x-xz"] = 6, ["application/zstd"] = 6, ["application/x-7z-compressed"] = 6, ["application/x-rar"] = 6,
    ["application/vnd.rar"] = 6, ["application/x-bzip2"] = 6, ["application/x-iso9660-image"] = 6,
    ["application/x-executable"] = 8, ["application/x-pie-executable"] = 8, ["application/x-sharedlib"] = 8, ["application/x-mach-binary"] = 8,
    ["application/msword"] = 9, ["application/rtf"] = 9, ["application/epub+zip"] = 9,
}
local function mime_ik(mime)
    if MIME_IK[mime] then return MIME_IK[mime] end
    local top = mime:match("^(%a+)/")
    if top == "text" then return 5 end
    if top == "image" then return 1 end
    if top == "video" then return 4 end
    if top == "audio" then return 3 end
    if mime:find("opendocument", 1, true) or mime:find("officedocument", 1, true) then return 9 end
    return nil
end
function F.prime_kinds()
    if s.kind_busy then return end
    local c = cols()
    local from = s.first * c + 1
    local upto = math.min(#s.items, (s.first + row_window()) * c)
    local todo = {}
    for i = from, upto do
        local e = s.items[i]
        if e and e.ik == 7 and not e.dir and not e.broken and not e.kind_done and e.size > 0 then
            todo[#todo + 1] = e
            if #todo >= 60 then break end
        end
    end
    if #todo == 0 then return end
    s.kind_busy = true
    local args = { "-b", "--mime-type", "--" }
    for _, e in ipairs(todo) do args[#args + 1] = e.path; e.kind_done = true end
    run("file", args, function(out)
        s.kind_busy = false
        local n, changed = 0, false
        for line in (out or ""):gmatch("([^\n]*)\n?") do
            n = n + 1
            local e = todo[n]
            if not e then break end
            local k = mime_ik(trim(line))
            if k and k ~= e.ik then e.ik = k; changed = true end
        end
        if changed then F.flush_later() end
    end)
end

function F.show_rows()
    carry_all = nil
    F.prime_thumbs()
    F.prime_kinds()
    local c = cols()
    local n = #s.items
    local total = math.ceil(n / c)
    fact.total = total
    fact.itemsn = n
    local rw = row_window()
    local first = math.max(0, math.min(s.first, math.max(total - rw, 0)))
    local rows = {}
    for r = 1, rw do
        local row = first + r - 1
        if row >= total then break end
        local cells = {}
        for k = 1, c do
            local i = row * c + k
            if i > n then break end
            cells[k] = cell(i, s.items[i])
        end
        rows[r] = { cells = cells }
    end
    fact.first = first
    model.rows = rows
    F.set_status()
end

-- what to say when there is nothing to show
function F.set_empty()
    if s.mode == "deep" then text.empty = "Nothing found"
    elseif s.mode == "filter" and (s.qtext ~= "" or s.so.kind ~= 0) then text.empty = "Nothing here with that"
    elseif s.list == "recent" then text.empty = "No recent files yet"
    elseif s.list == "starred" then text.empty = "Nothing starred yet: right-click something and add it"
    elseif fact["in.trash"] == true then text.empty = "The Trash is empty"
    else text.empty = "This folder is empty" end
end

function F.show_crumbs()
    -- the way down to here: "Home" first when it is under the home folder, else the root; at most five, the last ones
    local parts, acc = {}, ""
    if s.path == "recent:" then parts[1] = { name = "Recent", path = "recent:" }
    elseif s.path == "starred:" then parts[1] = { name = "Starred", path = "starred:" }
    elseif s.path == s.home or s.path:sub(1, #s.home + 1) == s.home .. "/" then
        parts[1] = { name = "Home", path = s.home }
        local rest = s.path:sub(#s.home + 2)
        acc = s.home
        for seg in rest:gmatch("[^/]+") do
            acc = acc .. "/" .. seg
            parts[#parts + 1] = { name = seg, path = acc }
        end
    else
        parts[1] = { name = "Computer", path = "/" }
        acc = ""
        for seg in s.path:gmatch("[^/]+") do
            acc = acc .. "/" .. seg
            parts[#parts + 1] = { name = seg, path = acc }
        end
    end
    local function widths()
        local out, total = {}, 0
        for i, p in ipairs(parts) do
            local nm = p.name
            if #nm > 22 then nm = nm:sub(1, 21) .. "…" end
            out[i] = { nm = nm, w = 8 + #nm * 7.6 }
            total = total + out[i].w + 26
        end
        return out, total
    end
    -- the last folders that fit the room (the one you are in always stays), with a "…" for the way up that does not
    local ws, total = widths()
    local dropped_one = false
    while #parts > 1 and total > s.crumbw do
        table.remove(parts, 1)
        dropped_one = true
        ws, total = widths()
    end
    if dropped_one then
        local up = dirname(parts[1].path)
        table.insert(parts, 1, { name = "…", path = up })
        ws = widths()
    end
    local rows, x = {}, 0
    for i, p in ipairs(parts) do
        local w = ws[i].w
        rows[i] = { at = i - 1, name = ws[i].nm, path = p.path, x = x, w = w, last = i == #parts }
        x = x + w + 26
    end
    s.crumbs = rows
    model.crumbs = rows
end

function F.show_free()
    if s.path == "recent:" or s.path == "starred:" then text.free = "" return end
    run("df", { "-B1", "--output=avail", s.path }, function(out)
        local n = tonumber((out or ""):match("\n%s*(%d+)"))
        text.free = n and (size_text(n) .. " free") or ""
    end)
end

function F.nav_flags()
    fact["can.back"] = #s.back > 0
    fact["can.fwd"] = #s.fwd > 0
end

-- the tabs, as the scene draws them
function F.show_tabs()
    local n = #s.tabs
    local rows = {}
    local w = math.min(200, math.floor((tonumber(s.tabs_room) or 700) / math.max(n, 1)))
    for i, t in ipairs(s.tabs) do
        rows[i] = { at = i - 1, name = t.name or "…", x = (i - 1) * w, w = w, active = i == s.tab }
    end
    model.tabs = rows
end

-- ── listing a folder ──
-- `find -L` says what each thing is after its links are followed (a link to a folder is a folder), and a second `find` which of them are links. A link that leads nowhere is a `l` even to the first.
function F.list_dir(path, cb)
    local first_out, first_code, links, waiting = nil, nil, {}, 2
    local function both()
        waiting = waiting - 1
        if waiting > 0 then return end
        if first_code ~= 0 and (first_out or "") == "" then cb(nil) return end
        local items = {}
        for line in (first_out or ""):gmatch("[^\n]+") do
            local ty, sz, mt, mode, name = line:match("^(%a)\t(%d+)\t([%d%.]+)\t(%d+)\t(.*)$")
            if name and name ~= "" then
                local broken = ty == "l"
                items[#items + 1] = make_item(join(path, name), name, ty == "d", tonumber(sz) or 0, tonumber(mt) or 0, tonumber(mode, 8) or 0, links[name] == true, broken)
            end
        end
        -- a `.hidden` file in a folder lists names (a line each) that are not to be shown, as the file managers do
        local has_hidden = false
        for _, e in ipairs(items) do if e.name == ".hidden" then has_hidden = true end end
        if not has_hidden then cb(items) return end
        run("cat", { "--", join(path, ".hidden") }, function(out)
            local names = {}
            for l in (out or ""):gmatch("[^\n]+") do names[l] = true end
            for _, e in ipairs(items) do if names[e.name] then e.hidden = true end end
            cb(items)
        end)
    end
    run("find", { "-L", path, "-maxdepth", "1", "-mindepth", "1", "-printf", "%y\t%s\t%T@\t%m\t%f\n" }, function(out, code) first_out, first_code = out, code; both() end)
    run("find", { path, "-maxdepth", "1", "-mindepth", "1", "-type", "l", "-printf", "%f\n" }, function(out)
        for l in (out or ""):gmatch("[^\n]+") do links[l] = true end
        both()
    end)
end

-- Things that are given by their paths (the recent files, the starred ones, the ones a search found): what is still there, in the order they were asked for.
function F.list_paths(paths, cb)
    if #paths == 0 then cb({}) return end
    local out_items = {}
    local chunk, pending = 120, 0
    local rank_of = {}
    for i, p in ipairs(paths) do rank_of[p] = i end
    local function finish()
        table.sort(out_items, function(a, b) return (a.rank or 0) < (b.rank or 0) end)
        cb(out_items)
    end
    local at = 1
    while at <= #paths do
        local args = { "-L" }
        for i = at, math.min(at + chunk - 1, #paths) do args[#args + 1] = paths[i] end
        for _, x in ipairs({ "-maxdepth", "0", "-printf", "%y\t%s\t%T@\t%m\t%p\n" }) do args[#args + 1] = x end
        pending = pending + 1
        run("find", args, function(out)
            for line in (out or ""):gmatch("[^\n]+") do
                local ty, sz, mt, mode, p = line:match("^(%a)\t(%d+)\t([%d%.]+)\t(%d+)\t(.*)$")
                if p then
                    local e = make_item(p, basename(p), ty == "d", tonumber(sz) or 0, tonumber(mt) or 0, tonumber(mode, 8) or 0, false, ty == "l")
                    e.rank = rank_of[p] or 0
                    out_items[#out_items + 1] = e
                end
            end
            pending = pending - 1
            if pending == 0 then finish() end
        end)
        at = at + chunk
    end
end

-- What the Trash knows about each thing in it: where it came from and when it was put there (the `.trashinfo` files).
function F.trash_info(items, cb)
    local info = s.data .. "/Trash/info"
    run("grep", { "-r", "-H", "-E", "^(Path|DeletionDate)=", info }, function(out)
        local by = {}
        for line in (out or ""):gmatch("[^\n]+") do
            local file, key, val = line:match("^(.-)%.trashinfo:(%a+)=(.*)$")
            if file then
                local name = basename(file)
                by[name] = by[name] or {}
                by[name][key] = val
            end
        end
        for _, e in ipairs(items) do
            local t = by[e.name]
            if t then
                if t.Path then e.orig = unescape(t.Path) end
                if t.DeletionDate then e.deld = (t.DeletionDate:gsub("T", " ")):sub(1, 16) end
            end
        end
        cb()
    end)
end

local function visible()
    if s.list then return sorted(s.all or {}) end
    return sorted((s.mode == "deep" and s.results) or s.all or {})
end
F.visible = visible

-- ── going somewhere ──
local go_seq = 0          -- each going has a number: the answer of one that was overtaken (two clicks in a row, the first folder slow) is dropped
function F.reset_search()
    if s.mode then s.mode, s.results, s.qtext = nil, nil, ""; text.sq = ""; fact.searching = false end       -- (a search belongs to the folder it was made in)
end
function F.after_list(path, how, then_pick)
    s.items = visible()
    s.picked = {}
    s.anchor, s.cursor = nil, nil
    if then_pick then
        for i, e in ipairs(s.items) do
            if e.name == then_pick then s.picked[e.path] = true; s.anchor = i; s.cursor = i end
        end
    end
    s.first = 0
    s.scroll = 0
    fact.sct = 0
    fact.gen = (tonumber(fact.gen) or 0) + 1
    F.nav_flags()
    F.show_crumbs()
    F.show_places()
    F.set_empty()
    F.show_rows()
    F.show_free()
    fact.ready = true
    if then_pick and s.cursor then F.ensure_visible(s.cursor) end
end

function F.go(path, how, then_pick, on_fail)
    if path == "recent:" or path == "starred:" then return F.go_list(path, how) end
    path = clean(path)
    go_seq = go_seq + 1
    local mine = go_seq
    F.list_dir(path, function(items)
        if mine ~= go_seq then return end
        if not items then
            say("Can't open " .. basename(path))
            if on_fail then on_fail() end
            return
        end
        local function arrive()
            if mine ~= go_seq then return end
            if how == nil and s.path ~= "" and s.path ~= path then
                s.back[#s.back + 1] = s.path
                s.fwd = {}
            end
            s.path = path
            s.list = nil
            fact["in.trash"] = path == s.data .. "/Trash/files"
            fact["in.list"] = false
            F.reset_search()
            s.loc = nil
            fact["loc.edit"] = false
            s.all = items
            local t = s.tabs[s.tab]
            if t then t.path = path; t.name = (path == s.home) and "Home" or basename(path); t.back = s.back; t.fwd = s.fwd end
            F.show_tabs()
            F.after_list(path, how, then_pick)
            F.watch(path)
        end
        if path == s.data .. "/Trash/files" then F.trash_info(items, arrive) else arrive() end
    end)
end

-- the recent files and the starred ones are folders that are not: lists of places, shown the way a search's finds are
function F.go_list(which, how)
    go_seq = go_seq + 1
    local mine = go_seq
    local function got(items)
        if mine ~= go_seq then return end
        if how == nil and s.path ~= "" and s.path ~= which then
            s.back[#s.back + 1] = s.path
            s.fwd = {}
        end
        s.path = which
        s.list = which == "recent:" and "recent" or "starred"
        fact["in.trash"] = false
        fact["in.list"] = true
        F.reset_search()
        s.loc = nil
        fact["loc.edit"] = false
        s.all = items
        local t = s.tabs[s.tab]
        if t then t.path = which; t.name = which == "recent:" and "Recent" or "Starred"; t.back = s.back; t.fwd = s.fwd end
        F.show_tabs()
        F.watch(nil)
        F.after_list(which, how, nil)
    end
    if which == "starred:" then
        F.list_paths(s.star_list, function(items)
            -- a starred thing that has gone is forgotten
            local there = {}
            for _, e in ipairs(items) do there[e.path] = true end
            local keep, changed = {}, false
            for _, p in ipairs(s.star_list) do
                if there[p] then keep[#keep + 1] = p else changed = true; s.stars[p] = nil end
            end
            if changed then s.star_list = keep; F.save() end
            got(items)
        end)
    else
        run("grep", { "-o", "<bookmark href=\"[^\"]*\" added=\"[^\"]*\" modified=\"[^\"]*\"", s.data .. "/recently-used.xbel" }, function(out)
            local found = {}
            for href, modified in (out or ""):gmatch("href=\"file://([^\"]*)\" added=\"[^\"]*\" modified=\"([^\"]*)\"") do
                found[#found + 1] = { path = unescape(href):gsub("&amp;", "&"):gsub("&apos;", "'"):gsub("&quot;", "\""), modified = modified }
            end
            table.sort(found, function(a, b) return a.modified > b.modified end)
            local paths, seen = {}, {}
            for _, f in ipairs(found) do
                if not seen[f.path] and #paths < 120 then seen[f.path] = true; paths[#paths + 1] = f.path end
            end
            F.list_paths(paths, got)
        end)
    end
end

function F.refresh(then_pick, cb)
    local here = s.path
    if s.list then
        local which = s.path
        local function again(items)
            if which ~= s.path then return end
            s.all = items
            s.items = visible()
            local old = s.picked
            s.picked = {}
            for _, e in ipairs(s.items) do if old[e.path] then s.picked[e.path] = true end end
            F.set_empty()
            F.show_rows()
            if cb then cb() end
        end
        if which == "starred:" then F.list_paths(s.star_list, again) else F.go_list(which, "refresh") end
        return
    end
    F.list_dir(here, function(items)
        if not items or here ~= s.path then return end       -- (or we have gone somewhere else meanwhile: that listing is of the old folder)
        local function arrive()
            if here ~= s.path then return end
            local old = {}
            for p in pairs(s.picked) do old[p] = true end
            s.all = items
            if s.mode == "deep" then F.run_search(true) return end       -- what was found is looked for again
            s.items = visible()
            s.picked = {}
            s.anchor = s.anchor and math.min(s.anchor, #s.items) or nil
            for i, e in ipairs(s.items) do
                if then_pick then
                    if e.name == then_pick then s.picked[e.path] = true; s.anchor = i; s.cursor = i end
                elseif old[e.path] then
                    s.picked[e.path] = true
                end
            end
            if s.cursor and s.cursor > #s.items then s.cursor = #s.items > 0 and #s.items or nil end
            F.set_empty()
            F.show_rows()
            F.show_free()
            if then_pick and s.cursor then F.ensure_visible(s.cursor) end
            if cb then cb() end
        end
        if fact["in.trash"] == true then F.trash_info(items, arrive) else arrive() end
    end)
end

-- What is in the folder now is looked at again a moment after it changes (the changes come in bursts: a download is a hundred of them).
function F.watch(path)
    if s.mon then kill(s.mon); s.mon = nil end
    if not path or path == "/" then return end
    s.mon = spawn("gio", { "monitor", "-d", path }, function()
        if s.mon_timer then return end
        s.mon_timer = true
        after(350, function()
            s.mon_timer = false
            if s.path ~= "" and not s.busy then F.refresh() end
        end)
    end, function() end)
end

function F.open_item(e)
    if e.dir then F.go(e.path) else spawn("xdg-open", { e.path }, function() end, function() end) end
end

-- ── the places on the left ──
-- Recent and starred things, the ones you know, then the drives, the places on the network and the folders you pinned.
function F.build_places(found)
    found = found or s.found or {}
    s.found = found
    local list = {
        { name = "Recent", path = "recent:", pk = 10 },
        { name = "Starred", path = "starred:", pk = 11 },
        { name = "Home", path = s.home, pk = 1 },
        { name = "Desktop", path = found.DESKTOP, pk = 12 },
        { name = "Documents", path = found.DOCUMENTS, pk = 5 },
        { name = "Downloads", path = found.DOWNLOAD, pk = 4 },
        { name = "Music", path = found.MUSIC, pk = 7 },
        { name = "Pictures", path = found.PICTURES, pk = 6 },
        { name = "Videos", path = found.VIDEOS, pk = 8 },
        { name = "Trash", path = s.data .. "/Trash/files", pk = 2 },
    }
    s.places = {}
    local seen = {}
    for _, p in ipairs(list) do
        if p.path then s.places[#s.places + 1] = p; seen[p.path] = true end
    end
    s.places[#s.places + 1] = { name = "DEVICES", kind = 1 }
    s.places[#s.places + 1] = { name = "Computer", path = "/", pk = 3 }
    for _, d in ipairs(s.devices) do
        s.places[#s.places + 1] = { name = d.name, path = d.path or ("dev:" .. d.dev), pk = d.removable and 14 or 9, kind = 2, eject = d.eject, use = d.use, dev = d.dev, parent = d.parent, mounted = d.path ~= nil }
    end
    s.places[#s.places + 1] = { name = "NETWORK", kind = 1 }
    for _, n in ipairs(s.nets) do
        s.places[#s.places + 1] = { name = n.name, path = n.path, pk = 13, kind = 0, eject = not n.sys, net = true, sys = n.sys }
    end
    s.places[#s.places + 1] = { name = "Connect to server…", path = "connect:", pk = 15 }
    local pinned = {}
    for _, path in ipairs(s.pins) do
        if not seen[path] then
            pinned[#pinned + 1] = { name = s.pin_names[path] or basename(path), path = path, pk = 0, pinned = true }
            seen[path] = true
        end
    end
    if #pinned > 0 then
        s.places[#s.places + 1] = { name = "PINNED", kind = 1 }
        for _, p in ipairs(pinned) do s.places[#s.places + 1] = p end
    end
end
function F.show_places()
    local rows = {}
    for i, p in ipairs(s.places) do
        rows[i] = { at = i - 1, name = p.name, path = p.path or "", pk = p.pk or 0, here = p.path ~= nil and p.path == s.path, pinned = p.pinned == true, kind = p.kind or 0, eject = p.eject == true, use = p.use or -1 }
    end
    model.places = rows
end

-- drives: the ones that are plugged in and not the computer's own (what is mounted under /run/media, /media or /mnt; a stick or a disk that is not mounted yet is there to be)
function F.poll_devices()
    run("lsblk", { "-J", "-b", "-o", "NAME,LABEL,SIZE,TYPE,MOUNTPOINT,FSAVAIL,FSUSED,RM,HOTPLUG,PATH,FSTYPE,PKNAME" }, function(out, code)
        if code ~= 0 or not out or out == "" then return end
        local ok, data = pcall(json.decode, out)
        if not ok or type(data) ~= "table" or type(data.blockdevices) ~= "table" then return end
        local devs = {}
        local function truthy(v) return v == true or v == "1" or v == 1 end
        local function walk(list, parent_hot)
            for _, d in ipairs(list) do
                local mp = type(d.mountpoint) == "string" and d.mountpoint or nil
                local hot = truthy(d.hotplug) or truthy(d.rm) or parent_hot
                local user_mp = mp and (mp:find("^/run/media/") or mp:find("^/media/") or mp:find("^/mnt/")) ~= nil
                local fstype = type(d.fstype) == "string" and d.fstype or nil
                if (user_mp or (mp == nil and hot and fstype and fstype ~= "swap" and fstype ~= "crypto_LUKS" and d.type == "part")) then
                    local avail, used = tonumber(d.fsavail), tonumber(d.fsused)
                    local use = (avail and used and (avail + used) > 0) and (used / (avail + used)) or -1
                    local label = type(d.label) == "string" and d.label ~= "" and d.label or (size_text(tonumber(d.size) or 0) .. " " .. (hot and "drive" or "disk"))
                    devs[#devs + 1] = { name = label, path = mp, dev = d.path, use = use, removable = hot, eject = mp ~= nil or hot, parent = type(d.pkname) == "string" and d.pkname or nil }
                end
                if type(d.children) == "table" then walk(d.children, hot) end
            end
        end
        walk(data.blockdevices, false)
        local sig = {}
        for _, d in ipairs(devs) do sig[#sig + 1] = (d.dev or "") .. "|" .. (d.path or "") .. "|" .. string.format("%.2f", d.use) end
        local key = table.concat(sig, ";")
        if key ~= s.dev_sig then
            s.dev_sig = key
            s.devices = devs
            if s.home ~= "" then F.build_places(); F.show_places() end
        end
    end)
    -- places on the network and phones: what gvfs has mounted
    if s.runtime and s.runtime ~= "" then
        run("find", { s.runtime .. "/gvfs", "-maxdepth", "1", "-mindepth", "1", "-printf", "%f\n" }, function(o)
            local nets = {}
            for l in (o or ""):gmatch("[^\n]+") do
                local scheme, rest = l:match("^([%w%-]+):(.*)$")
                local host = rest and (rest:match("host=([^,]+)") or rest:match("server=([^,]+)")) or nil
                local share = rest and rest:match("share=([^,]+)") or nil
                local nm = share and host and (share .. " on " .. host) or host or l
                if scheme == "mtp" or scheme == "gphoto2" then nm = "Phone or camera" end
                nets[#nets + 1] = { name = nm, path = s.runtime .. "/gvfs/" .. l }
            end
            s.nets_gvfs = nets
            F.merge_nets()
        end)
    end
    -- and the network filesystems the kernel itself has mounted: from fstab, from an automount, or by hand.
    -- gvfs knows nothing of those, so without this a share mounted at boot shows up nowhere on the left, and
    -- the only way to reach it is to pin its folder.
    run("findmnt", { "-rno", "FSTYPE,TARGET,SOURCE", "-t", "cifs,smb3,nfs,nfs4,fuse.sshfs" }, function(o)
        local nets = {}
        for l in (o or ""):gmatch("[^\n]+") do
            local target, source = l:match("^%S+%s+(%S+)%s+(%S+)")
            if target then
                target = target:gsub("\\040", " ")
                local host, share = source:match("^//([^/]+)/(.+)$")     -- //server/share
                if not host then host, share = source:match("^([^:/]+):(.+)$") end   -- server:/export
                local nm = (host and share) and (basename(share) .. " on " .. host) or basename(target)
                nets[#nets + 1] = { name = nm, path = target, sys = true }
            end
        end
        s.nets_sys = nets
        F.merge_nets()
    end)
end

-- The two sources of network places together: what gvfs mounted and what the kernel mounted. The list is
-- rebuilt only when it really changed, so the sidebar does not flicker on every poll.
function F.merge_nets()
    local nets = {}
    for _, n in ipairs(s.nets_gvfs or {}) do nets[#nets + 1] = n end
    for _, n in ipairs(s.nets_sys or {}) do nets[#nets + 1] = n end
    local sig = {}
    for _, n in ipairs(nets) do sig[#sig + 1] = n.path end
    local key = table.concat(sig, ";")
    if key ~= s.net_sig then
        s.net_sig = key
        s.nets = nets
        if s.home ~= "" then F.build_places(); F.show_places() end
    end
end

-- let a drive go: put it away, and if it is a disk of its own (a stick) switch it off too
function F.eject_place(p)
    if p.net and not p.sys then
        run("gio", { "mount", "-u", "--", p.path }, function(_, code)
            say(code == 0 and ("Disconnected from " .. p.name) or ("Could not disconnect " .. p.name))
            F.poll_devices()
        end, { errors = true })
        return
    end
    if not p.dev then return end
    say("Putting " .. p.name .. " away…")
    local function power_off()
        if not p.parent then F.poll_devices() return end
        run("udisksctl", { "power-off", "-b", "/dev/" .. p.parent }, function() F.poll_devices() end)
    end
    if p.mounted then
        if s.path == p.path or s.path:sub(1, #p.path + 1) == p.path .. "/" then F.go(s.home) end
        run("udisksctl", { "unmount", "-b", p.dev }, function(out, code)
            if code ~= 0 then say("Could not put " .. p.name .. " away: " .. why(out)) return end
            say(p.name .. " can be taken out now")
            power_off()
        end, { errors = true })
    else
        power_off()
    end
end

-- a drive that is not mounted yet is mounted when it is clicked
function F.open_place(p)
    if p.path == "connect:" then F.ask_dialog("connect", "Connect to server", "", "Connect") return end
    if p.pk == 2 then
        -- the Trash folder is only there once something has been put in it
        run("mkdir", { "-p", "--", p.path }, function() F.go(p.path) end)
    elseif p.dev and not p.mounted then
        say("Mounting " .. p.name .. "…")
        run("udisksctl", { "mount", "-b", p.dev }, function(out, code)
            local at = (out or ""):match(" at (/[^\n]-)%.?%s*$")
            if code == 0 and at then F.poll_devices(); F.go(at) else say("Could not mount " .. p.name .. ": " .. why(out)) end
        end, { errors = true })
    else
        F.go(p.path)
    end
end

local DEFAULT_DIR = { DESKTOP = "Desktop", DOCUMENTS = "Documents", DOWNLOAD = "Downloads", MUSIC = "Music", PICTURES = "Pictures", VIDEOS = "Videos", TEMPLATES = "Templates" }

function F.start()
    run("printenv", { "HOME" }, function(h)
        s.home = trim(h)
        run("printenv", { "USER" }, function(u) s.user = trim(u) end)
        run("printenv", { "XDG_DATA_HOME" }, function(d)
            s.data = trim(d) ~= "" and trim(d) or (s.home .. "/.local/share")
            run("printenv", { "XDG_RUNTIME_DIR" }, function(r)
                s.runtime = trim(r)
                local names = { "DESKTOP", "DOCUMENTS", "DOWNLOAD", "MUSIC", "PICTURES", "VIDEOS", "TEMPLATES" }
                local found = {}
                local function nextdir(k)
                    if k > #names then
                        -- (only the ones that are there: the user-dirs file names Desktop and the rest even when the folders were never made)
                        local paths = {}
                        for _, n in ipairs(names) do if found[n] then paths[#paths + 1] = found[n] end end
                        local function finish(there)
                            for _, n in ipairs(names) do if found[n] and not there[found[n]] then found[n] = nil end end
                            s.templates = found.TEMPLATES
                            s.found = found
                            -- the bookmarks of the other file managers (GTK's) are the first folders pinned, once
                            local function begin()
                                F.build_places(found)
                                run("printenv", { "FILES_START" }, function(o, code)
                                    local start_at = trim(o)
                                    local want = code == 0 and start_at:sub(1, 1) == "/" and start_at or s.home
                                    s.tabs = { { path = want, name = basename(want), back = {}, fwd = {} } }
                                    s.tab = 1
                                    F.go(want, nil, nil, function() if want ~= s.home then F.go(s.home) end end)       -- a start folder that is not there: the home folder, not an empty window
                                    F.poll_devices()
                                    every(4000, F.poll_devices)
                                end)
                            end
                            if s.pins_set then begin() return end
                            run("cat", { s.home .. "/.config/gtk-3.0/bookmarks" }, function(out)
                                local have = {}
                                for _, p in ipairs(s.pins) do have[p] = true end
                                for line in (out or ""):gmatch("[^\n]+") do
                                    local u = line:match("^file://(/%S*)")
                                    if u then
                                        u = unescape(u)
                                        if not have[u] then s.pins[#s.pins + 1] = u; have[u] = true end
                                    end
                                end
                                s.pins_set = true
                                F.save()
                                begin()
                            end)
                        end
                        if #paths == 0 then finish({}) return end
                        local args = {}
                        for _, p in ipairs(paths) do args[#args + 1] = p end
                        for _, x in ipairs({ "-maxdepth", "0", "-type", "d", "-printf", "%p\n" }) do args[#args + 1] = x end
                        run("find", args, function(out)
                            local there = {}
                            for line in (out or ""):gmatch("[^\n]+") do there[line] = true end
                            finish(there)
                        end)
                        return
                    end
                    run("xdg-user-dir", { names[k] }, function(o, code)
                        local p = trim(o)
                        -- (xdg-user-dir says the home folder for one that was never set: then the usual name, if that folder is there)
                        if code ~= 0 or p == "" or p == s.home then p = s.home .. "/" .. DEFAULT_DIR[names[k]] end
                        found[names[k]] = p
                        nextdir(k + 1)
                    end)
                end
                nextdir(1)
            end)
        end)
    end)
end

-- how much room the path has (the scene says): the last folders that fit are shown
on("fact:crumbw", function(v)
    v = tonumber(v)
    if v and math.abs(v - s.crumbw) > 4 then
        s.crumbw = v
        if s.path ~= "" then F.show_crumbs() end
    end
end)
on("fact:roomw", function(v)
    v = tonumber(v)
    if v and math.abs(v - (s.tabs_room or 0)) > 4 then
        s.tabs_room = v
        F.show_tabs()
    end
end)
on("fact:vh", function(v) s.vh = tonumber(v) or s.vh end)
on("fact:sct", function(v) s.scroll = tonumber(v) or 0 end)
on("fact:tilew", function(v)
    v = tonumber(v)
    if v and v ~= s.tilew then
        s.tilew = v
        if s.path ~= "" then F.show_rows() end
    end
end)

-- A window that is already open (this logic was reloaded) has its columns already: take them, or rows would be laid out for one count and drawn for another.
do
    local c = math.floor(tonumber(fact.cols) or 0)
    if c >= 1 and c <= MAX_COLS then s.cols = c end
    local t = tonumber(fact.tilew)
    if t and t >= 60 then s.tilew = t end
end

-- ── tabs ──
function F.tab_new(path, background)
    if #s.tabs >= 10 then say("That is as many tabs as there is room for") return end
    path = path or s.path
    local t = { path = path, name = path == s.home and "Home" or basename(path), back = {}, fwd = {} }
    if path == "recent:" then t.name = "Recent" elseif path == "starred:" then t.name = "Starred" end
    table.insert(s.tabs, s.tab + 1, t)
    if background then
        F.show_tabs()
        return
    end
    F.tab_go(s.tab + 1, true)
end
function F.tab_go(i, fresh)
    if i < 1 or i > #s.tabs or (i == s.tab and not fresh) then return end
    local cur = s.tabs[s.tab]
    if cur and not fresh then cur.path = s.path; cur.back = s.back; cur.fwd = s.fwd end
    if fresh then
        -- the tab just made is the one after this one: this one is kept as it is
        if cur then cur.path = s.path; cur.back = s.back; cur.fwd = s.fwd end
    end
    s.tab = i
    local t = s.tabs[i]
    s.back, s.fwd = t.back or {}, t.fwd or {}
    t.back, t.fwd = s.back, s.fwd
    F.show_tabs()
    F.go(t.path, "tab")
end
function F.tab_close(i)
    if #s.tabs <= 1 then F.close_window() return end
    local was = s.tab
    table.remove(s.tabs, i)
    if i < was then s.tab = was - 1
    elseif i == was then
        s.tab = math.min(was, #s.tabs)
        local t = s.tabs[s.tab]
        s.back, s.fwd = t.back or {}, t.fwd or {}
        F.show_tabs()
        F.go(t.path, "tab")
        return
    end
    F.show_tabs()
end
function F.close_window()
    -- close this window: Hyprland closes the one that has the pointer (the one just clicked); elsewhere the window has its own cross, and this asks the scene to quit (by its own name)
    run("hyprctl", { "dispatch", "hl.dsp.window.close()" }, function(_, code)
        if code ~= 0 then
            -- bin/vitreus-files --close: the window that runs it asks for the name that is its own (a second window is not "files")
            run("vitreus-files", { "--close" }, function() end)
        end
    end)
end

-- ── choosing ──
function F.max_scroll()
    local n = #s.items
    local content = (s.view == "grid" and math.ceil(n / math.max(s.cols, 1)) * tile_h() or n * LINES_H) + 8
    return math.max(content - s.vh, 0)
end
function F.scroll_to(px)
    px = math.max(0, math.min(px, F.max_scroll()))
    s.scroll = px
    fact.sct = px
end
function F.ensure_visible(idx)
    local top = item_top(idx)
    local th = tile_h()
    local target
    if top < s.scroll then target = top
    elseif top + th > s.scroll + s.vh then target = top + th - s.vh end
    if target then F.scroll_to(target) end
end

local function index_of_path(p)
    for i, e in ipairs(s.items) do if e.path == p then return i end end
    return nil
end

function F.select_range(a, b, base)
    s.picked = base and copy_set(base) or {}
    local lo, hi = math.min(a, b), math.max(a, b)
    for i = lo, hi do
        local e = s.items[i]
        if e then s.picked[e.path] = true end
    end
end

function F.select_all()
    s.picked = {}
    for _, e in ipairs(s.items) do s.picked[e.path] = true end
    F.show_rows()
end
function F.invert()
    local new = {}
    for _, e in ipairs(s.items) do if not s.picked[e.path] then new[e.path] = true end end
    s.picked = new
    F.show_rows()
end

-- A click on a tile: alone it chooses that one; with Ctrl it adds or takes away; with Shift it chooses all the way from the one chosen last. A tile that is already in a choice of several
-- keeps the choice at first (so that all of them can be dragged away) and gives it up when the button comes up without a drag.
on("tile", function(i)
    F.close_menu()
    if i < 0 then
        local shift, ctrl = mods()
        s.band_base = (shift or ctrl) and copy_set(s.picked) or {}
        if not shift and not ctrl then s.picked = {} end
        F.show_rows()
        return
    end
    local e = s.items[i + 1]
    if not e then return end
    local shift, ctrl = mods()
    local double = s.last_i == i and s.tick - s.last_tick < 9 and not shift and not ctrl
    s.last_i, s.last_tick = i, s.tick
    s.defer = nil
    if double then
        s.last_i = nil
        F.open_item(e)
        return
    end
    if shift then
        local a = s.anchor or (i + 1)
        F.select_range(a, i + 1, ctrl and s.picked or nil)
        s.cursor = i + 1
    elseif ctrl then
        if s.picked[e.path] then s.picked[e.path] = nil else s.picked[e.path] = true end
        s.anchor, s.cursor = i + 1, i + 1
    else
        if s.picked[e.path] and count_set(s.picked) > 1 then
            s.defer = i
        else
            s.picked = { [e.path] = true }
        end
        s.anchor, s.cursor = i + 1, i + 1
    end
    F.show_rows()
    F.prep_drag_icon()
end)
on("tile_up", function(i)
    if s.defer == i then
        s.defer = nil
        local e = s.items[i + 1]
        if e then s.picked = { [e.path] = true }; F.show_rows() end
    end
end)

-- the box dragged over the folder: what it touches is chosen (with Ctrl or Shift held when it began, along with what was chosen then)
on("band", function()
    local ax, ay, bx, by = tonumber(fact["rb.ax"]) or 0, tonumber(fact["rb.ay"]) or 0, tonumber(fact["rb.bx"]) or 0, tonumber(fact["rb.by"]) or 0
    local x0, x1, y0, y1 = math.min(ax, bx), math.max(ax, bx), math.min(ay, by), math.max(ay, by)
    local hits, sig = {}, 0
    if s.view == "grid" then
        local tw, th = s.tilew, tile_h()
        local c0, c1 = math.floor(x0 / tw), math.floor(x1 / tw)
        local r0, r1 = math.floor(y0 / th), math.floor(y1 / th)
        for r = r0, r1 do
            for c = c0, math.min(c1, s.cols - 1) do
                local idx = r * s.cols + c + 1
                local e = s.items[idx]
                if e and x1 >= c * tw and x0 <= c * tw + tw - 8 and y1 >= r * th and y0 <= r * th + th - 4 then hits[idx] = true; sig = sig + idx end
            end
        end
    else
        for r = math.floor(y0 / LINES_H), math.floor(y1 / LINES_H) do
            local idx = r + 1
            if s.items[idx] and y1 >= r * LINES_H and y0 <= r * LINES_H + LINES_H - 4 then hits[idx] = true; sig = sig + idx end
        end
    end
    local key = sig .. ":" .. count_set(hits)
    if key == s.band_sig then return end
    s.band_sig = key
    s.picked = s.band_base and copy_set(s.band_base) or {}
    local last
    for idx in pairs(hits) do
        s.picked[s.items[idx].path] = true
        last = idx
    end
    if last then s.anchor, s.cursor = last, last end
    F.show_rows()
end)
on("band_end", function()
    s.band_sig = nil
    F.prep_drag_icon()
end)

-- The keys that move the choice. Alone they choose the next thing; with Shift they stretch the choice; with Ctrl they only move the frame (Ctrl+Space then chooses what it is on).
function F.move_choice(d, how, to)
    local n = #s.items
    if n == 0 then return end
    local cur = s.cursor or s.anchor
    if not cur then
        local first = picked_list()[1]
        if first then cur = index_of_path(first.path) end
    end
    local idx
    if to then idx = to
    elseif not cur then idx = d >= 0 and 1 or n
    else idx = cur + d end
    idx = math.max(1, math.min(n, idx))
    s.cursor = idx
    if how == "cursor" then
        -- the frame moves, the choice stays
    elseif how == "extend" then
        s.anchor = s.anchor or cur or idx
        F.select_range(s.anchor, idx, nil)
    else
        s.anchor = idx
        s.picked = { [s.items[idx].path] = true }
    end
    F.show_rows()
    F.ensure_visible(idx)
end
function F.toggle_cursor()
    local e = s.items[s.cursor or 0]
    if not e then return end
    if s.picked[e.path] then s.picked[e.path] = nil else s.picked[e.path] = true end
    s.anchor = s.cursor
    F.show_rows()
end
function F.page_by()
    return math.max(1, math.floor(s.vh / tile_h())) * down_by()
end

-- on the places: click a place, a crumb, and a click on the empty middle
on("place", function(i)
    F.close_menu()
    local p = s.places[(tonumber(i) or -1) + 1]
    if p and p.path then F.open_place(p) end
end)
on("place_eject", function(i)
    local p = s.places[(tonumber(i) or -1) + 1]
    if p then F.eject_place(p) end
end)
on("crumb", function(i)
    local c = s.crumbs[(tonumber(i) or -1) + 1]
    if c then F.go(c.path) end
end)
on("slid", function(scroll)
    s.scroll = tonumber(scroll) or 0
    local back = s.view == "grid" and 2 or 1
    local first = math.max(math.floor(s.scroll / row_h()) - back, 0)
    if math.abs(first - s.first) >= back or first ~= s.first and first == 0 then
        s.first = first
        F.show_rows()
    end
end)
on("set_cols", function(n)
    n = math.max(1, math.min(math.floor(tonumber(n) or 1), MAX_COLS))
    if n ~= s.cols then
        s.cols = n
        fact.cols = n
        F.show_rows()
    end
end)
on("tab_go", function(i) F.tab_go((tonumber(i) or -1) + 1) end)
on("tab_close", function(i) F.tab_close((tonumber(i) or -1) + 1) end)
on("tile_mid", function(i)
    local e = s.items[(tonumber(i) or -1) + 1]
    if e and e.dir then F.tab_new(e.path, true) end
end)
on("spring", function(i)
    -- held over a folder while something is carried: go in, so that it can be put further down
    local e = s.items[(tonumber(i) or -1) + 1]
    if e and e.dir then F.go(e.path) end
end)

-- ── a name to give: a new folder, a new name, a place to connect to ──
function F.ask_dialog(kind, title, value, ok)
    s.ask = kind
    fact["ask.input"] = true
    fact["ask.danger"] = false
    text["ask.title"] = title
    text["ask.ok"] = ok
    text.askin = value or ""
    fact["ask.on"] = true
    fact["ask.gen"] = (tonumber(fact["ask.gen"]) or 0) + 1
    after(60, function() focus("askin") end)
end
-- a question with Cancel and one button, in the alert colour: for what cannot be undone
function F.confirm(title, msg, ok, fn)
    s.ask = "confirm"
    s.confirm_fn = fn
    fact["ask.input"] = false
    fact["ask.danger"] = true
    text["ask.title"] = title
    text["ask.msg"] = msg
    text["ask.ok"] = ok
    fact["ask.on"] = true
end
function F.close_ask()
    s.ask = nil
    s.confirm_fn = nil
    fact["ask.on"] = false
    focus()
end

-- A list to choose from: `rows` are { label =, sub =, ic = (a picture of the menu's), … }, and `fn` is told which one was chosen.
function F.pick(title, rows, fn)
    local m = {}
    for i, r in ipairs(rows) do
        if i > 14 then break end
        m[i] = { at = i - 1, label = r.label, sub = r.sub or "", hs = r.sub ~= nil and r.sub ~= "", ic = r.ic or 8 }
    end
    s.picker = { rows = rows, fn = fn }
    model.picks = m
    text["pick.title"] = title
    fact["pick.on"] = true
end
function F.close_pick()
    s.picker = nil
    fact["pick.on"] = false
end
on("pick_ok", function(i)
    local p = s.picker
    if not p then return end
    local r = p.rows[(tonumber(i) or -1) + 1]
    F.close_pick()
    if r and p.fn then p.fn(r) end
end)

-- a name that is already there: ask what to do (the answer can be for all the others too)
function F.conflict(name, dest_name, is_dir, cb)
    s.cf = { cb = cb }
    fact["cf.all"] = false
    text["cf.msg"] = string.format("There is already %s called \"%s\" in %s. What should happen to the one that is coming?", is_dir and "a folder" or "a file", name, dest_name)
    fact["cf.on"] = true
end
on("cf_pick", function(k)
    k = math.floor(tonumber(k) or 0)
    if k == 9 then fact["cf.all"] = not (fact["cf.all"] == true) return end
    local cf = s.cf
    if not cf then return end
    local all = fact["cf.all"] == true
    s.cf = nil
    fact["cf.on"] = false
    cf.cb(({ [0] = "stop", "skip", "both", "replace" })[k] or "stop", all)
end)

-- ── the menu ──
function F.close_menu()
    s.menu = nil
    fact["menu.on"] = false
end
on("menu_close", F.close_menu)

local function set_menu(kind, rows)
    local h = 14
    for _, r in ipairs(rows) do h = h + MENU_ROW + (r.sep and 9 or 0) end
    s.menu = kind
    model.menuitems = rows
    fact["menu.h"] = h
    fact["menu.on"] = true
end
local function menu_row(rows, label, k, on, ic, key, sep, danger, chk)
    rows[#rows + 1] = { label = label, k = k, on = on, ic = ic, key = key or "", sep = sep == true, danger = danger == true, chk = chk == true }
end
-- ── custom actions (local) ──
-- Your own commands in the right-click menu, from ~/.config/pleamar/vitreus-files-actions.json (files/actions.example.json is a model; outside the shell's folder: updating Vitreus
-- never touches it). Each: { "name", "command", "group" (optional, shown as "Group › Name"), "on": "files" | "folders" | "both" |
-- "background" (a click on the empty part of a folder), "patterns": ["*.jpg", …] (optional, files only), "many": true (optional: also with
-- several picked) }. In the command %f is the item (or the folder, for background), %F every one picked, %d the folder in view, %n the
-- item's name; each comes quoted. The file is read again each time a menu opens (what changed shows from the next one). Commands run
-- through `sh`, as you wrote them: the menu is yours, it is not sandboxed.
local CUSTOM = {}
local SHOWN = {}               -- the actions the open menu was built from (the file may be read again before a click: its places must not move under it)
local CUSTOM_K = 200            -- their keys in the menu: 200 + their place
local function load_custom()
    run("sh", { "-c", 'cat "${XDG_CONFIG_HOME:-$HOME/.config}/pleamar/vitreus-files-actions.json" 2>/dev/null' }, function(out, code)
        if code ~= 0 or not out or out == "" then CUSTOM = {} return end
        local ok, d = pcall(json.decode, out)
        if not ok or type(d) ~= "table" or type(d.actions) ~= "table" then CUSTOM = {} return end
        local list = {}
        for _, a in ipairs(d.actions) do
            if type(a) == "table" and type(a.name) == "string" and a.name ~= "" and type(a.command) == "string" and a.command ~= "" then
                local on = (a.on == "folders" or a.on == "both" or a.on == "background") and a.on or "files"
                local pats = {}
                if type(a.patterns) == "table" then
                    for _, p in ipairs(a.patterns) do
                        if type(p) == "string" and p ~= "" then
                            -- a shell pattern (* and ?) made into a Lua one, compared without case
                            pats[#pats + 1] = "^" .. p:lower():gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
                        end
                    end
                end
                list[#list + 1] = { name = a.name, group = type(a.group) == "string" and a.group or "", command = a.command, on = on, pats = pats, many = a.many == true }
            end
            if #list >= 8 then break end
        end
        CUSTOM = list
    end)
end
load_custom()
local function custom_fits(a, kind, list)
    if kind == "bg" then return a.on == "background" end
    if a.on == "background" or #list == 0 or (#list > 1 and not a.many) then return false end
    for _, e in ipairs(list) do
        if e.dir then
            if a.on ~= "folders" and a.on ~= "both" then return false end
        else
            if a.on ~= "files" and a.on ~= "both" then return false end
            if #a.pats > 0 then
                local nm, hit = basename(e.path):lower(), false
                for _, pat in ipairs(a.pats) do if nm:match(pat) then hit = true break end end
                if not hit then return false end
            end
        end
    end
    return true
end
local function add_custom(rows, kind, list)
    local first = true
    SHOWN = CUSTOM
    for i, a in ipairs(CUSTOM) do
        if custom_fits(a, kind, list) then
            menu_row(rows, a.group ~= "" and (a.group .. " › " .. a.name) or a.name, CUSTOM_K + i, true, 30, "", first)
            first = false
        end
    end
end
local function shq(p) return "'" .. tostring(p):gsub("'", "'\\''") .. "'" end
local function run_custom(i, ctx)
    local a = SHOWN[i]
    if not a then return end
    local list = ctx.menu == "bg" and {} or picked_list()
    -- only on what the menu offered it for: a key sent from outside (`emit act`) with something else picked does nothing
    if not custom_fits(a, ctx.menu == "bg" and "bg" or "item", list) then return end
    local cur = s.path or s.home
    local f = list[1] and list[1].path or cur
    local all = {}
    for _, e in ipairs(list) do all[#all + 1] = shq(e.path) end
    if #all == 0 then all[1] = shq(cur) end
    local cmd = (a.command:gsub("%%(.)", function(c)
        if c == "f" then return shq(f) elseif c == "F" then return table.concat(all, " ")
        elseif c == "d" then return shq(cur) elseif c == "n" then return shq(basename(f)) elseif c == "%" then return "%" end
        return "%" .. c
    end))
    -- in the folder in view, on its own (setsid: it outlives this window)
    run("sh", { "-c", "cd " .. shq(cur) .. " && setsid -f sh -c " .. shq(cmd) .. " >/dev/null 2>&1" }, function(_, code)
        if code ~= 0 then say("“" .. a.name .. "” did not start") end
    end)
end

function F.open_menu(kind)
    load_custom()                   -- (for the next menu: an edit to the file shows from then on)
    local rows = {}
    local list = picked_list()
    local n = #list
    local in_trash = fact["in.trash"] == true
    local in_list = s.list ~= nil or s.mode == "deep"
    local e = list[1]
    local function add(...) menu_row(rows, ...) end
    if kind == "item" then
        if in_trash then
            add("Restore", 44, n >= 1, 25, "")
            add("Delete Permanently", 17, n >= 1, 13, "Shift+Del", true, true)
            add("Properties", 16, n >= 1, 16, "Alt+Enter", true)
        else
            add("Open", 7, n >= 1, 8, "Enter")
            if n == 1 and not e.dir then add("Open With…", 26, true, 30, "") end
            if n >= 1 and e.dir then
                add("Open in New Tab", 27, true, 18, "")
                add("Open in New Window", 28, true, 19, "")
                add("Open in Terminal", 29, n == 1, 17, "")
            end
            add("Cut", 5, n >= 1, 11, "Ctrl+X", true)
            add("Copy", 4, n >= 1, 10, "Ctrl+C")
            if n == 1 and e.dir and not in_list then add("Paste Into Folder", 45, fact["clip.on"] == true, 12, "") end
            add("Duplicate", 25, n >= 1 and not in_list, 27, "")
            add("Rename", 2, n == 1, 9, "F2", true)
            add("Move to Trash", 3, n >= 1, 13, "Del", false, true)
            local first_extra = true
            if n == 1 and e.ik == 6 then add("Extract Here", 35, true, 23, "", first_extra); first_extra = false end
            add("Compress…", 34, n >= 1, 22, "", first_extra)
            add("Create Link", 36, n >= 1 and not in_list, 21, "")
            add("Copy Path", 37, n >= 1, 26, "Ctrl+Shift+C")
            add(n >= 1 and s.stars[e.path] and "Remove from Starred" or "Add to Starred", 38, n >= 1, 24, "")
            if n == 1 and e.ik == 1 then add("Set as Wallpaper", 39, true, 29, "") end
            if n == 1 and in_list then add("Show in Folder", 63, true, 8, "") end
            add_custom(rows, "item", list)
            add("Properties", 16, n >= 1, 16, "Alt+Enter", true)
        end
        set_menu("item", rows)
    elseif kind == "bg" then
        if in_trash then add("Empty Trash", 18, #s.items > 0, 13, "", false, true) end
        if not in_list then
            add("New Folder", 1, not in_trash, 6, "Ctrl+Shift+N", in_trash)
            add("New File…", 24, not in_trash, 28, "")
            if s.has_templates and not in_trash then add("New from Template…", 48, true, 28, "") end
            add("Paste", 6, not in_trash, 12, "Ctrl+V", true)
        end
        add("Select All", 8, #s.items > 0, 14, "Ctrl+A", not in_list)
        add("Invert Selection", 46, #s.items > 0, 14, "Ctrl+I")
        add(s.hidden and "Hide Hidden Files" or "Show Hidden Files", 14, true, 5, "Ctrl+H", true)
        add("Refresh", 9, true, 15, "F5")
        if not in_list then
            add("Open in Terminal", 29, true, 17, "", true)
            add("Pin This Folder", 49, true, 36, "Ctrl+D")
        end
        if not in_trash then add_custom(rows, "bg", {}) end
        add("Sort and Zoom…", 15, true, 31, "", true)
        add("Properties", 16, not in_list, 16, "Alt+Enter")
        set_menu("bg", rows)
    elseif kind == "sort" then
        add("Name", 70, true, 31, "", false, false, s.sort == "name")
        add("Size", 71, true, 31, "", false, false, s.sort == "size")
        add("Kind", 72, true, 31, "", false, false, s.sort == "type")
        add("Modified", 73, true, 31, "", false, false, s.sort == "date")
        add("Reverse Order", 74, true, 34, "", true, false, s.sortrev)
        add("Folders First", 75, true, 6, "", false, false, s.dirfirst)
        add("Show Hidden Files", 14, true, 5, "Ctrl+H", false, false, s.hidden)
        add("Bigger Icons", 51, s.zoom < #ZOOMS, 32, "Ctrl++", true)
        add("Smaller Icons", 52, s.zoom > 1, 33, "Ctrl+-")
        add("Normal Size", 53, s.zoom ~= 3, 15, "Ctrl+0")
        set_menu("sort", rows)
    end
end
on("tile_menu", function(i)
    local e = s.items[(tonumber(i) or -1) + 1]
    if e and not s.picked[e.path] then
        s.picked = { [e.path] = true }
        s.anchor, s.cursor = i + 1, i + 1
        F.show_rows()
    end
    F.open_menu("item")
end)
on("bg_menu", function() F.open_menu("bg") end)
on("place_menu", function(i)
    local p = s.places[(tonumber(i) or -1) + 1]
    if not p or not p.path then return end
    s.menu_place = p
    local rows = {}
    if p.pk == 2 then
        menu_row(rows, "Open", 42, true, 8, "")
        menu_row(rows, "Empty Trash", 43, true, 13, "", true, true)
    elseif p.path == "connect:" then
        menu_row(rows, "Connect…", 42, true, 8, "")
    else
        menu_row(rows, "Open", 42, true, 8, "")
        if p.path:sub(1, 1) == "/" and (not p.dev or p.mounted) then
            menu_row(rows, "Open in New Tab", 27, true, 18, "")
            menu_row(rows, "Open in New Window", 28, true, 19, "")
        end
        if p.dev then menu_row(rows, p.mounted and "Unmount" or "Mount", p.mounted and 64 or 42, true, 34, "", true) end
        if p.net and not p.sys then menu_row(rows, "Disconnect", 64, true, 34, "", true) end
        if p.pinned then
            menu_row(rows, "Rename…", 65, true, 9, "", true)
            menu_row(rows, "Move Up", 66, true, 34, "")
            menu_row(rows, "Move Down", 67, true, 34, "")
            menu_row(rows, "Unpin from the Sidebar", 41, true, 7, "", true)
        end
    end
    set_menu("place", rows)
end)

-- ── the properties card ──
local function close_props()
    s.props = nil
    s.props_e = nil
    fact["prop.on"] = false
    fact["pm.on"] = false
end
F.close_props = close_props
local function set_prows(rows, perm)
    for _, r in ipairs(rows) do
        r.btn = r.btn or ""
        r.hb = r.btn ~= ""
        r.k = r.k or 0
        r.tog = r.tog == true
        r.on = r.on == true
    end
    model.prows = rows
    fact["prop.h"] = 90 + 14 + #rows * 30 + (perm and 104 or 0) + 14 + 54
end

-- the programs that can open a kind of file: the default first, then the others that say they can
local APP_DIRS = { "/.local/share/applications", "/usr/share/applications", "/usr/local/share/applications", "/var/lib/flatpak/exports/share/applications", "/.local/share/flatpak/exports/share/applications" }
function F.apps_for(mime, cb)
    run("gio", { "mime", mime }, function(out)
        local ids, seen = {}, {}
        local def = (out or ""):match("Default application for[^:]*: ([^\n]+)")
        if def and def ~= "No default applications" then def = trim(def); ids[1] = def; seen[def] = true else def = nil end
        for line in (out or ""):gmatch("\t([^\n]+%.desktop)") do
            line = trim(line)
            if not seen[line] then seen[line] = true; ids[#ids + 1] = line end
        end
        if #ids == 0 then cb({}, nil) return end
        local args = { "-m1", "-H", "^Name=" }
        local dirs = {}
        for _, d in ipairs(APP_DIRS) do dirs[#dirs + 1] = d:sub(1, 1) == "/" and (d:find("^/%.local") and (s.home .. d) or d) end
        for _, id in ipairs(ids) do
            for _, d in ipairs(dirs) do args[#args + 1] = d .. "/" .. id end
        end
        run("grep", args, function(o2)
            local found = {}
            for path, nm in (o2 or ""):gmatch("([^\n]-%.desktop):Name=([^\n]*)") do
                local id = basename(path)
                if not found[id] then found[id] = { name = nm, path = path, id = id } end
            end
            local apps = {}
            for _, id in ipairs(ids) do if found[id] then apps[#apps + 1] = found[id] end end
            cb(apps, def)
        end)
    end)
end
function F.mime_of(path, cb)
    run("file", { "-b", "--mime-type", "--", path }, function(m) cb(trim(m)) end)
end

function F.open_with(e)
    F.mime_of(e.path, function(mime)
        F.apps_for(mime, function(apps)
            if #apps == 0 then say("Nothing is known that opens " .. e.name) return end
            local rows = {}
            for i, a in ipairs(apps) do rows[i] = { label = a.name, sub = i == 1 and "Default" or nil, ic = 30, app = a } end
            F.pick("Open " .. e.name .. " with", rows, function(r)
                local ok = pcall(spawn, "gio", { "launch", r.app.path, e.path }, function() end, function(_, code) if code ~= 0 then say("Could not start " .. r.app.name) end end)
                if not ok then say("Could not start " .. r.app.name) end
            end)
        end)
    end)
end

local show_props
function show_props()
    local list = picked_list()
    local gen = (s.pgen or 0) + 1
    s.pgen = gen
    s.props = gen
    F.close_menu()
    if #list > 1 then
        local files, dirs, bytes = 0, 0, 0
        for _, e in ipairs(list) do
            if e.dir then dirs = dirs + 1 else files = files + 1; bytes = bytes + e.size end
        end
        model.pinfo = { { name = string.format("%d items", #list), sub = string.format("%d %s, %d %s", files, plural(files, "file", "files"), dirs, plural(dirs, "folder", "folders")), ik = 7, thumb = "", ["has.thumb"] = false } }
        local rows = {
            { label = "Location", value = s.path },
            { label = "Size", value = size_text(bytes) .. (dirs > 0 and "  and the folders…" or "") },
        }
        set_prows(rows, false)
        fact["pm.on"] = false
        fact["prop.on"] = true
        if dirs > 0 then
            local args = { "-sbc", "-x", "--" }
            for _, e in ipairs(list) do args[#args + 1] = e.path end
            run("du", args, function(d)
                if s.props ~= gen then return end
                local n = tonumber((d or ""):match("(%d+)%s+total%s*$"))
                if n then rows[2].value = size_text(n) .. " (" .. commas(n) .. " bytes)"; model.prows = rows end
            end)
        end
        return
    end
    local e = list[1] or { name = basename(s.path), path = s.path, dir = true, size = 0, mtime = 0, ik = 0, hidden = false }
    local th = e.dir and nil or s.thumbs[tkey(e)]
    run("stat", { "-c", "%F\t%s\t%Y\t%X\t%W\t%U\t%G\t%A\t%a\t%N", "--", e.path }, function(out, code)
        if s.props ~= gen then return end
        local f = {}
        for v in (out or ""):gmatch("([^\t\n]*)\t?") do f[#f + 1] = v end
        local size, mtime, atime, btime, user, group, perm_s, perm_o, nm = tonumber(f[2]) or e.size, tonumber(f[3]) or e.mtime, tonumber(f[4]) or 0, tonumber(f[5]) or 0, f[6], f[7], f[8], f[9], f[10] or ""
        local target = nm:match("%-> '(.*)'$")
        local rows = {}
        local function add(label, value, extra)
            if value and value ~= "" then
                local r = { label = label, value = value }
                if extra then for k, v in pairs(extra) do r[k] = v end end
                rows[#rows + 1] = r
            end
        end
        local mine = user ~= nil and user == s.user and not e.link and fact["in.trash"] ~= true and #list == 1
        add("Type", kind_text(e))
        add("Location", dirname(e.path))
        if e.orig then add("Came from", dirname(e.orig)) end
        if e.deld then add("Deleted", e.deld) end
        if e.dir then add("Size", "Calculating…") else add("Size", size_text(size) .. " (" .. commas(size) .. " bytes)") end
        if e.dir then add("Contains", "…") end
        add("Modified", date_text(mtime))
        if atime > 0 then add("Accessed", date_text(atime)) end
        if btime > 0 then add("Created", date_text(btime)) end
        if e.ik == 1 then add("Dimensions", "…") end
        if e.ik == 3 or e.ik == 4 then add("Media", "…") end
        if not e.dir and #list == 1 then add("Opens with", "…", { btn = "Change…", k = 1 }) end
        if not mine then add("Permissions", (perm_s or "") .. "  (" .. (perm_o or "") .. ")") end
        add("Owner", (user or "") .. " : " .. (group or ""))
        if target then add("Link to", target) end
        if not e.dir and #list == 1 and size > 0 then add("Checksum", "SHA-256", { btn = "Calculate", k = 2 }) end
        if list[1] and fact["in.trash"] ~= true then
            s.props_e = e
            rows[#rows + 1] = { label = "Hidden", value = e.hidden and "Yes (the name starts with a dot)" or "No", tog = true, on = e.hidden == true, k = 3 }
        end
        model.pinfo = { { name = e.name, sub = kind_text(e) .. (e.dir and "" or (" · " .. size_text(size))), ik = e.ik, thumb = th or "", ["has.thumb"] = th ~= nil and th ~= false } }
        s.props_path = e.path
        s.props_mime = nil
        if mine then
            s.props_bits = (tonumber(perm_o, 8) or 0) % 512
            fact["pm.bits"] = s.props_bits
        end
        fact["pm.on"] = mine
        set_prows(rows, mine)
        fact["prop.on"] = true
        local function update(label, value)
            if s.props ~= gen then return end
            for _, r in ipairs(rows) do if r.label == label then r.value = value end end
            model.prows = rows
        end
        s.props_update = update
        -- what the file is, by its contents
        if not e.dir then
            F.mime_of(e.path, function(mime)
                if s.props ~= gen or mime == "" then return end
                s.props_mime = mime
                update("Type", kind_text(e) .. "  (" .. mime .. ")")
                F.apps_for(mime, function(apps, def)
                    local nm = "none"
                    for _, a in ipairs(apps) do if a.id == def then nm = a.name end end
                    if nm == "none" and apps[1] then nm = apps[1].name end
                    update("Opens with", nm)
                end)
            end)
        end
        if e.dir then
            if e.path == "/" then
                update("Size", "—")       -- (adding up the whole computer takes minutes, and is not stopped when the card is closed)
            else
                local id
                id = spawn("du", { "-sbxD", "--", e.path }, function(d)       -- D: a link to a folder is its folder; x: not into other disks
                    local n = tonumber((d or ""):match("^(%d+)"))
                    if n then update("Size", size_text(n) .. " (" .. commas(n) .. " bytes)") else update("Size", "unknown") end
                end, function() end)
                s.props_job = id
            end
            run("find", { "-H", e.path, "-mindepth", "1", "-maxdepth", "1", "-printf", "." }, function(c)
                local n = #(c or "")
                update("Contains", n == 1 and "1 item" or (commas(n) .. " items"))
            end)
        elseif e.ik == 1 then
            run("identify", { "-format", "%w × %h pixels", e.path .. "[0]" }, function(o) update("Dimensions", trim(o) ~= "" and trim(o) or "unknown") end)
        elseif e.ik == 3 or e.ik == 4 then
            run("ffprobe", { "-v", "error", "-show_entries", "format=duration:stream=codec_name,width,height", "-of", "default=nw=1", e.path }, function(o)
                local dur = tonumber((o or ""):match("duration=([%d%.]+)"))
                local codec = (o or ""):match("codec_name=(%w+)")
                local w, h = (o or ""):match("width=(%d+)"), (o or ""):match("height=(%d+)")
                local parts = {}
                if dur then parts[#parts + 1] = string.format("%d:%02d", math.floor(dur / 60), math.floor(dur % 60)) end
                if w and h then parts[#parts + 1] = w .. " × " .. h end
                if codec then parts[#parts + 1] = codec end
                update("Media", #parts > 0 and table.concat(parts, " · ") or "unknown")
            end)
        end
    end)
end
F.show_props = show_props
function F.close_props_job()
    if s.props_job then kill(s.props_job); s.props_job = nil end
end

on("prop_act", function(k)
    k = math.floor(tonumber(k) or 0)
    local e = s.props_e or picked_list()[1]
    if k == 3 then F.toggle_hidden_file() return end
    if k == 1 and e and s.props_mime then
        local mime = s.props_mime
        F.apps_for(mime, function(apps)
            if #apps == 0 then say("Nothing is known that opens that") return end
            local rows = {}
            for i, a in ipairs(apps) do rows[i] = { label = a.name, sub = i == 1 and "The one now" or nil, ic = 30, app = a } end
            F.pick("Open " .. mime .. " with", rows, function(r)
                run("gio", { "mime", mime, r.app.id }, function(_, code)
                    say(code == 0 and (r.app.name .. " opens those now") or "Could not change that")
                    if s.props_update then s.props_update("Opens with", r.app.name) end
                end)
            end)
        end)
    elseif k == 2 and e and s.props_update then
        s.props_update("Checksum", "Working it out…")
        run("sha256sum", { "--", e.path }, function(o)
            local h = (o or ""):match("^(%x+)")
            if s.props_update then s.props_update("Checksum", h or "could not") end
        end)
    end
end)
-- the permissions' switches: each one flips a bit of the mode
on("perm", function(b)
    b = math.floor(tonumber(b) or -1)
    if b < 0 or b > 8 or not s.props_path or not s.props_bits then return end
    local new = bit32.bxor(s.props_bits, bit32.lshift(1, b))
    local path = s.props_path
    run("chmod", { string.format("%03o", new), "--", path }, function(out, code)
        if code ~= 0 then say("Could not change that: " .. why(out)) return end
        s.props_bits = new
        fact["pm.bits"] = new
    end, { errors = true })
end)

-- Hidden or not: a name that starts with a dot is hidden, so the switch adds the dot or takes it away.
function F.toggle_hidden_file()
    local e = s.props_e
    if not (e and s.props) then return end
    local new = e.hidden and e.name:gsub("^%.", "") or ("." .. e.name)
    if new == "" or new == "." or new == ".." or new == e.name then return end
    local dir = dirname(e.path)
    F.name_taken(dir, new, function(taken)
        if taken then say("\"" .. new .. "\" is already there") return end
        F.run_job({ title = "Renaming", tasks = { { kind = "rename", src = e.path, dst = join(dir, new) } }, quiet = true, after = function(ok)
            if not ok then return end
            if (not e.hidden) and not s.hidden then
                -- hidden now, and hidden files are not shown: it leaves the list
                close_props()
                say("\"" .. new .. "\" is hidden now (Ctrl+H shows hidden files)")
            else
                F.refresh(new, function() show_props() end)
            end
        end })
    end)
end

-- ── a look at a file (Space) ──
local pv_seq = 0
function F.close_preview()
    s.pv = nil
    fact["pv.on"] = false
end
function F.show_preview(idx)
    local e = s.items[idx]
    if not e then return end
    s.pv = idx
    s.cursor = idx
    if not s.picked[e.path] or count_set(s.picked) > 1 then s.picked = { [e.path] = true }; s.anchor = idx; F.show_rows(); F.ensure_visible(idx) end
    pv_seq = pv_seq + 1
    local mine = pv_seq
    text["pv.name"] = e.name
    text["pv.sub"] = kind_text(e) .. (e.dir and "" or (" · " .. size_text(e.size))) .. " · " .. date_text(e.mtime)
    text["pv.text"] = ""
    fact["pv.kind"] = 0
    fact["pv.n"] = idx
    fact["pv.of"] = #s.items
    fact["pv.on"] = true
    local function picture(src_path, tmp_cleanup)
        local out = string.format("%s/preview-%d.png", tdir, mine % 4)
        run("magick", { src_path .. "[0]", "-auto-orient", "-background", "none", "-resize", "1000x640", "-gravity", "center", "-extent", "1000x640", "-define", "png:compression-level=1", out }, function(_, code)
            if tmp_cleanup then run("rm", { "-f", "--", tmp_cleanup }, function() end) end
            if mine ~= pv_seq or code ~= 0 then return end
            text["pv.path"] = out
            fact["pv.kind"] = 1
        end)
    end
    if not tdir then return end
    if e.dir then
        run("find", { "-H", e.path, "-mindepth", "1", "-maxdepth", "1", "-printf", "." }, function(c)
            if mine ~= pv_seq then return end
            local n = #(c or "")
            text["pv.text"] = n == 0 and "An empty folder" or (n == 1 and "1 thing in it" or (commas(n) .. " things in it"))
            fact["pv.kind"] = 2
        end)
    elseif e.ik == 1 then
        picture(e.path)
    elseif e.ik == 2 then
        local base = string.format("%s/preview-pdf-%d", tdir, mine % 2)
        run("pdftoppm", { "-f", "1", "-l", "1", "-singlefile", "-png", "-scale-to-x", "1400", "-scale-to-y", "-1", e.path, base }, function(_, code)
            if mine ~= pv_seq or code ~= 0 then return end
            picture(base .. ".png", base .. ".png")
        end)
    elseif e.ik == 4 then
        local frame = string.format("%s/preview-frame-%d.png", tdir, mine % 2)
        run("ffmpeg", { "-v", "error", "-y", "-ss", "1", "-i", e.path, "-frames:v", "1", frame }, function(_, code)
            if mine ~= pv_seq then return end
            if code ~= 0 then
                run("ffmpeg", { "-v", "error", "-y", "-i", e.path, "-frames:v", "1", frame }, function(_, c2)
                    if mine == pv_seq and c2 == 0 then picture(frame, frame) end
                end)
            else
                picture(frame, frame)
            end
        end)
    elseif e.ik == 3 then
        run("ffprobe", { "-v", "error", "-show_entries", "format=duration:format_tags=title,artist,album,date,genre", "-of", "default=nw=1", e.path }, function(o)
            if mine ~= pv_seq then return end
            local lines = {}
            local dur = tonumber((o or ""):match("duration=([%d%.]+)"))
            for _, k in ipairs({ "title", "artist", "album", "date", "genre" }) do
                local v = (o or ""):match("TAG:" .. k .. "=([^\n]+)") or (o or ""):match("TAG:" .. k:upper() .. "=([^\n]+)")
                if v then lines[#lines + 1] = k:sub(1, 1):upper() .. k:sub(2) .. ":  " .. v end
            end
            if dur then lines[#lines + 1] = string.format("Length:  %d:%02d", math.floor(dur / 60), math.floor(dur % 60)) end
            text["pv.text"] = #lines > 0 and table.concat(lines, "\n") or "No tags in it"
            fact["pv.kind"] = 2
        end)
        -- (its cover, if it has one, is shown as the picture)
        local cover = string.format("%s/preview-cover-%d.png", tdir, mine % 2)
        run("ffmpeg", { "-v", "error", "-y", "-i", e.path, "-an", "-frames:v", "1", cover }, function(_, code)
            if mine == pv_seq and code == 0 then picture(cover, cover) end
        end)
    else
        -- text of any kind: what is in the first lines
        F.mime_of(e.path, function(mime)
            if mine ~= pv_seq then return end
            local texty = mime:find("^text/") or mime:find("json") or mime:find("xml") or mime:find("javascript") or mime:find("x%-shellscript") or mime:find("x%-empty") or mime:find("x%-desktop") or mime:find("toml") or mime:find("yaml")
            if not texty then
                text["pv.text"] = "No look at this one: " .. mime
                fact["pv.kind"] = 2
                return
            end
            run("head", { "-c", "6000", "--", e.path }, function(body)
                if mine ~= pv_seq then return end
                local lines, n = {}, 0
                for l in (body or ""):gmatch("([^\n]*)\n?") do
                    n = n + 1
                    if n > 26 then break end
                    lines[#lines + 1] = (l:gsub("\t", "    "):gsub("[%c]", ""))
                end
                text["pv.text"] = table.concat(lines, "\n")
                fact["pv.kind"] = 2
            end)
        end)
    end
end
function F.preview_step(d)
    if not s.pv then return end
    local n = #s.items
    if n == 0 then return end
    local idx = s.pv + d
    if idx < 1 then idx = n elseif idx > n then idx = 1 end
    F.show_preview(idx)
end
function F.toggle_preview()
    if s.pv then F.close_preview() return end
    local idx = s.cursor
    local first = picked_list()[1]
    if first then idx = index_of_path(first.path) or idx end
    if idx then F.show_preview(idx) end
end

-- ── doing things to what is chosen: jobs ──
-- Everything that changes the disk is a job: a list of small tasks done one after the other, with a card that says how far it is (when it takes a while) and a way to stop it, a question when a name is
-- taken, a message that says what went wrong in words, and, when it is over, a way to take it back (Ctrl+Z, or the button that comes up for a moment).
-- A task is { kind = "copy" | "move" | "rename" | "mkdir" | "touch" | "trash" | "delete" | "link" | "restore" | "exec", ... }.

function F.name_taken(dir, name, cb)
    run("stat", { "-c", "%n", "--", join(dir, name) }, function(_, code) cb(code == 0) end)
end

local function names_in(job, dir, cb)
    if job.names[dir] then cb(job.names[dir]) return end
    run("find", { dir, "-maxdepth", "1", "-mindepth", "1", "-printf", "%f\n" }, function(out)
        local set = {}
        for n in (out or ""):gmatch("[^\n]+") do set[n] = true end
        job.names[dir] = set
        cb(set)
    end)
end
-- a name that is free among `taken`: "name copy", "name copy 2" … (before the extension)
local function free_in(name, taken)
    if not taken[name] then return name end
    local stem, ext = name:match("^(.+)(%.[^.]+)$")
    if not stem or name:match("%.tar%.[%w]+$") then
        stem, ext = name:match("^(.-)(%.tar%.[%w]+)$")
        if not stem then stem, ext = name, "" end
    end
    local n = 1
    while true do
        local cand = stem .. (n == 1 and " copy" or (" copy " .. n)) .. ext
        if not taken[cand] then return cand end
        n = n + 1
    end
end
F.free_in = free_in

-- the card: what is being done and how far it has got
function F.job_text()
    local job = s.job
    if not job then return end
    local n = #job.spec.tasks
    local i = math.min(job.i - 1, n)
    text["job.text"] = job.spec.title .. (n > 1 and string.format(" · %d of %d", math.max(i, 1), n) or "") .. (job.cur_name and (" · " .. job.cur_name) or "")
    if job.indeterminate then fact["job.p"] = -1
    else fact["job.p"] = math.min(((math.max(i, 1) - 1) + (job.sub or 0)) / math.max(n, 1), 1) end
end

-- run a program as the job's: it can be stopped, and what it said about its trouble is kept
function F.exec(job, cmd, args, cb)
    local lines = {}
    local ok, id = pcall(spawn, cmd, args, function(l) lines[#lines + 1] = l end, function(_, code)
        job.proc = nil
        cb(code == 0, table.concat(lines, "\n"))
    end, { errors = true })
    if ok then job.proc = id else cb(false, "could not start " .. cmd) end
end

-- a long copy says how far it is: the size of the copy so far against the size of the original, looked at twice a second after the first second
local function watch_progress(job, src, dst)
    job.cur_dst = dst
    after(1000, function()
        if job.cur_dst ~= dst or s.job ~= job then return end
        run("du", { "-sbx", "--", src }, function(o)
            local total = tonumber((o or ""):match("^(%d+)"))
            if not total or total < 1 or job.cur_dst ~= dst then return end
            local function poll()
                if job.cur_dst ~= dst or s.job ~= job then return end
                run("du", { "-sb", "--", dst }, function(o2)
                    if job.cur_dst ~= dst or s.job ~= job then return end
                    local got = tonumber((o2 or ""):match("^(%d+)")) or 0
                    job.sub = math.min(got / total, 0.99)
                    F.job_text()
                    after(500, poll)
                end)
            end
            poll()
        end)
    end)
end

local TASK = {}

-- copy and move: the name in the other folder may be taken (and then it is asked, or what was said for all of them is done)
local function transfer_task(job, t, done)
    local name = t.name or basename(t.src)
    local into = t.into or dirname(t.dst)
    local function go_on(dst, mode)
        -- mode: nil (a new name), "replace" (over what is there), "merge" (a folder into a folder)
        job.cur_name = basename(dst)
        F.job_text()
        watch_progress(job, t.src, dst)
        local function finished(ok, err)
            job.cur_dst = nil
            job.sub = 0
            if job.cancel then
                if not mode then F.exec(job, "rm", { "-rf", "--", dst }, function() done() end) else done() end
                return
            end
            if ok then
                job.results[#job.results + 1] = { kind = t.kind, src = t.src, dst = dst }
                local set = job.names[into]
                if set then set[basename(dst)] = true end
            else
                job.failed = job.failed + 1
                job.errors[#job.errors + 1] = string.format("Could not %s \"%s\": %s", t.kind == "move" and "move" or "copy", basename(t.src), why(err))
            end
            done()
        end
        if t.kind == "copy" then
            if mode == "merge" then F.exec(job, "cp", { "-a", "--reflink=auto", "-T", "--", t.src, dst }, finished)
            elseif mode == "replace" then F.exec(job, "cp", { "-a", "--reflink=auto", "--remove-destination", "--", t.src, dst }, finished)
            else F.exec(job, "cp", { "-a", "--reflink=auto", "--", t.src, dst }, finished) end
        else
            if mode == "merge" then
                F.exec(job, "cp", { "-a", "--reflink=auto", "-T", "--", t.src, dst }, function(ok, err)
                    if ok and not job.cancel then F.exec(job, "rm", { "-rf", "--", t.src }, function(ok2, err2) finished(ok2, err2) end)
                    else finished(ok, err) end
                end)
            elseif mode == "replace" then F.exec(job, "mv", { "-f", "--", t.src, dst }, finished)
            else F.exec(job, "mv", { "-n", "--", t.src, dst }, finished) end
        end
    end
    names_in(job, into, function(set)
        local dst = t.dst or join(into, name)
        local exists = set[basename(dst)]
        if t.dst and not set[basename(dst)] then exists = false end
        if not exists then go_on(dst) return end
        if dst == t.src then
            -- onto itself: a copy gets a name of its own; a move is nothing
            if t.kind == "move" then done() return end
            go_on(join(into, free_in(basename(dst), set)))
            return
        end
        if t.auto_both then go_on(join(into, free_in(basename(dst), set))) return end
        local function decide(choice)
            if choice == "stop" then job.cancel = true; done()
            elseif choice == "skip" then job.skipped = job.skipped + 1; done()
            elseif choice == "both" then go_on(join(into, free_in(basename(dst), set)))
            else
                -- replace: a folder over a folder is joined with it; a file over a file is written over; anything else puts the old one in the Trash first
                run("find", { "-L", dst, "-maxdepth", "0", "-type", "d" }, function(o)
                    local dst_dir = trim(o) ~= ""
                    local src_dir = false
                    for _, e in ipairs(job.spec.src_info or {}) do if e.path == t.src then src_dir = e.dir end end
                    if dst_dir and src_dir then go_on(dst, "merge")
                    elseif not dst_dir and not src_dir then go_on(dst, "replace")
                    else
                        F.exec(job, "gio", { "trash", "--", dst }, function() go_on(dst) end)
                    end
                end)
            end
        end
        if job.policy then decide(job.policy) return end
        local is_dir = false
        for _, e in ipairs(job.spec.src_info or {}) do if e.path == t.src then is_dir = e.dir end end
        fact["job.on"] = false
        F.conflict(basename(dst), basename(into) == "" and "/" or basename(into), is_dir, function(choice, all)
            if all and choice ~= "stop" then job.policy = choice end
            decide(choice)
        end)
    end)
end
TASK.copy = transfer_task
TASK.move = transfer_task

function TASK.rename(job, t, done)
    job.cur_name = basename(t.dst)
    F.exec(job, "mv", { "-n", "--", t.src, t.dst }, function(ok, err)
        if ok then job.results[#job.results + 1] = { kind = "rename", src = t.src, dst = t.dst }
        else job.failed = job.failed + 1; job.errors[#job.errors + 1] = string.format("Could not rename \"%s\": %s", basename(t.src), why(err)) end
        done()
    end)
end
function TASK.mkdir(job, t, done)
    job.cur_name = basename(t.dst)
    F.exec(job, "mkdir", { "--", t.dst }, function(ok, err)
        if ok then job.results[#job.results + 1] = { kind = "create", dst = t.dst }
        else job.failed = job.failed + 1; job.errors[#job.errors + 1] = string.format("Could not make \"%s\": %s", basename(t.dst), why(err)) end
        done()
    end)
end
function TASK.touch(job, t, done)
    job.cur_name = basename(t.dst)
    F.exec(job, "touch", { "--", t.dst }, function(ok, err)
        if ok then job.results[#job.results + 1] = { kind = "create", dst = t.dst }
        else job.failed = job.failed + 1; job.errors[#job.errors + 1] = string.format("Could not make \"%s\": %s", basename(t.dst), why(err)) end
        done()
    end)
end
function TASK.link(job, t, done)
    names_in(job, dirname(t.dst), function(set)
        local dst = join(dirname(t.dst), free_in(basename(t.dst), set))
        job.cur_name = basename(dst)
        F.exec(job, "ln", { "-s", "--", t.src, dst }, function(ok, err)
            if ok then job.results[#job.results + 1] = { kind = "create", dst = dst }; set[basename(dst)] = true
            else job.failed = job.failed + 1; job.errors[#job.errors + 1] = string.format("Could not link \"%s\": %s", basename(t.src), why(err)) end
            done()
        end)
    end)
end
-- any other program (an archive being made or opened)
function TASK.exec(job, t, done)
    job.cur_name = t.label
    job.indeterminate = true
    F.job_text()
    F.exec(job, t.cmd, t.args, function(ok, err)
        job.indeterminate = false
        if job.cancel then
            if t.created then F.exec(job, "rm", { "-rf", "--", t.created }, function() done() end) else done() end
            return
        end
        if ok then
            if t.created then job.results[#job.results + 1] = { kind = "create", dst = t.created } end
        else
            job.failed = job.failed + 1
            job.errors[#job.errors + 1] = string.format("%s: %s", t.fail or "That did not work", why(err))
            if t.created then F.exec(job, "rm", { "-rf", "--", t.created }, function() done() end) return end
        end
        done()
    end)
end
-- into the Trash: all at once. What cannot go there (a disk that has no Trash) is offered for deleting for good.
function TASK.trash(job, t, done)
    job.cur_name = #t.srcs == 1 and basename(t.srcs[1]) or (#t.srcs .. " items")
    local args = { "trash", "--" }
    for _, p in ipairs(t.srcs) do args[#args + 1] = p end
    F.exec(job, "gio", args, function(ok, err)
        -- what is gone from where it was went to the Trash
        local remain = {}
        for _, p in ipairs(t.srcs) do remain[#remain + 1] = p end
        for _, x in ipairs({ "-maxdepth", "0", "-printf", "%p\n" }) do remain[#remain + 1] = x end
        run("find", remain, function(out)
            local still = {}
            for l in (out or ""):gmatch("[^\n]+") do still[l] = true end
            -- (a link that leads nowhere is not seen by -L: it is looked for as itself)
            for _, p in ipairs(t.srcs) do
                if still[p] then
                    job.failed = job.failed + 1
                else
                    job.results[#job.results + 1] = { kind = "trash", src = p }
                end
            end
            if not ok and next(still) then
                local left = {}
                for _, p in ipairs(t.srcs) do if still[p] then left[#left + 1] = p end end
                if err:find("not supported", 1, true) or err:find("Trashing on system", 1, true) then
                    job.unsupported = left
                else
                    job.errors[#job.errors + 1] = string.format("Could not move %s to the Trash: %s", #left == 1 and ("\"" .. basename(left[1]) .. "\"") or (#left .. " items"), why(err))
                end
            end
            done()
        end)
    end)
end
function TASK.delete(job, t, done)
    job.cur_name = #t.srcs == 1 and basename(t.srcs[1]) or (#t.srcs .. " items")
    job.indeterminate = true
    local args = { "-rf", "--" }
    for _, p in ipairs(t.srcs) do args[#args + 1] = p end
    F.exec(job, "rm", args, function(ok, err)
        job.indeterminate = false
        if not ok then job.failed = job.failed + 1; job.errors[#job.errors + 1] = "Could not delete: " .. why(err) end
        done()
    end)
end
-- out of the Trash, back to where it came from (the folder is made again if it has gone); a name that is taken there gets "copy"
function TASK.restore(job, t, done)
    local orig = t.orig
    job.cur_name = basename(orig)
    local dir = dirname(orig)
    F.exec(job, "mkdir", { "-p", "--", dir }, function()
        names_in(job, dir, function(set)
            local dst = join(dir, free_in(basename(orig), set))
            F.exec(job, "mv", { "-n", "--", t.src, dst }, function(ok, err)
                if ok then
                    set[basename(dst)] = true
                    job.results[#job.results + 1] = { kind = "restore", src = t.src, dst = dst }
                    F.exec(job, "rm", { "-f", "--", s.data .. "/Trash/info/" .. basename(t.src) .. ".trashinfo" }, function() done() end)
                else
                    job.failed = job.failed + 1
                    job.errors[#job.errors + 1] = string.format("Could not put \"%s\" back: %s", basename(orig), why(err))
                    done()
                end
            end)
        end)
    end)
end

local function next_task(job)
    if job.cancel then F.finish_job(job) return end
    local t = job.spec.tasks[job.i]
    if not t then F.finish_job(job) return end
    job.i = job.i + 1
    job.sub = 0
    local fn = TASK[t.kind]
    if not fn then next_task(job) return end
    fn(job, t, function() next_task(job) end)
end

function F.run_job(spec)
    if s.job then
        s.jobq = s.jobq or {}
        s.jobq[#s.jobq + 1] = spec
        return
    end
    local job = { spec = spec, i = 1, results = {}, names = {}, skipped = 0, failed = 0, errors = {} }
    s.job = job
    s.busy = true
    if not spec.quiet then
        after(700, function()
            if s.job == job and not (s.cf) then fact["job.on"] = true; F.job_text() end
        end)
    end
    next_task(job)
end

function F.finish_job(job)
    if s.job ~= job then return end
    s.job = nil
    s.busy = false
    fact["job.on"] = false
    job.cur_dst = nil
    local ok = job.failed == 0
    if #job.errors > 0 then
        local msg = job.errors[1]
        if #job.errors > 1 then msg = msg .. string.format("  (and %d more)", #job.errors - 1) end
        say(msg, 8)
    end
    if job.unsupported then
        local left = job.unsupported
        F.confirm("Cannot go to the Trash", string.format("%s cannot be put in the Trash here (this disk has none). Delete %s for good?", #left == 1 and ("\"" .. basename(left[1]) .. "\"") or (#left .. " items"), #left == 1 and "it" or "them"), "Delete", function()
            F.run_job({ title = "Deleting", tasks = { { kind = "delete", srcs = left } } })
        end)
    end
    local entry = job.spec.undo and #job.results > 0 and job.spec.undo(job) or nil
    if entry then F.push_undo(entry) end
    if job.spec.after then job.spec.after(ok and not job.cancel, job.results) end
    if job.cancel then say("Stopped") end
    F.refresh(job.spec.pick_name)
    local q = s.jobq and table.remove(s.jobq, 1)
    if q then F.run_job(q) end
end

on("job_cancel", function()
    local job = s.job
    if not job then return end
    job.cancel = true
    -- (asked to stop, not forgotten: it says it has ended, and the job goes on from there, taking away what was half made)
    if job.proc then kill(job.proc, "term") end
end)

-- ── taking back ──
function F.push_undo(entry)
    s.undo[#s.undo + 1] = entry
    if #s.undo > 20 then table.remove(s.undo, 1) end
    text["undo.text"] = entry.text
    fact["undo.on"] = true
    s.undo_until = s.tick + 240
end
function F.undo()
    local entry = table.remove(s.undo)
    if not entry then say("Nothing to undo") return end
    fact["undo.on"] = false
    s.undo_until = 0
    say("Undoing: " .. entry.text)
    entry.fn()
end
-- the Trash gives back what was put there from these places (what the Trash says it came from is matched by its file)
function F.restore_paths(origs, then_fn)
    local args = { "-r", "-l", "-x", "-F" }
    for _, p in ipairs(origs) do
        args[#args + 1] = "-e"
        args[#args + 1] = "Path=" .. uri_of(p):gsub("^file://", "")
    end
    args[#args + 1] = s.data .. "/Trash/info"
    run("grep", args, function(out)
        local tasks = {}
        for f in (out or ""):gmatch("[^\n]+") do
            local name = basename(f):gsub("%.trashinfo$", "")
            tasks[#tasks + 1] = { kind = "restore", src = s.data .. "/Trash/files/" .. name }
        end
        -- where each came from: the info files again
        run("grep", { "-r", "-H", "-E", "^Path=", s.data .. "/Trash/info" }, function(o)
            local from = {}
            for line in (o or ""):gmatch("[^\n]+") do
                local file, val = line:match("^(.-)%.trashinfo:Path=(.*)$")
                if file then from[basename(file)] = unescape(val) end
            end
            local keep = {}
            for _, t in ipairs(tasks) do
                t.orig = from[basename(t.src)]
                if t.orig then keep[#keep + 1] = t end
            end
            if #keep == 0 then say("It is not in the Trash any more") return end
            F.run_job({ title = "Putting back", tasks = keep, quiet = true, after = then_fn })
        end)
    end)
end

local function items_text(n) return n == 1 and "1 item" or (n .. " items") end

-- ── the things that are done ──
function F.new_folder(name)
    local dst = join(s.path, name)
    F.run_job({ title = "Making a folder", quiet = true, tasks = { { kind = "mkdir", dst = dst } }, pick_name = name,
        undo = function(job) return { text = "Made folder " .. name, fn = function() F.run_job({ title = "Removing", quiet = true, tasks = { { kind = "trash", srcs = { dst } } } }) end } end })
end
function F.new_file(name)
    local dst = join(s.path, name)
    F.run_job({ title = "Making a file", quiet = true, tasks = { { kind = "touch", dst = dst } }, pick_name = name,
        undo = function(job) return { text = "Made file " .. name, fn = function() F.run_job({ title = "Removing", quiet = true, tasks = { { kind = "trash", srcs = { dst } } } }) end } end })
end
function F.rename(e, name)
    local dir = dirname(e.path)
    local dst = join(dir, name)
    F.run_job({ title = "Renaming", quiet = true, tasks = { { kind = "rename", src = e.path, dst = dst } }, pick_name = (dir == s.path) and name or nil,
        undo = function(job) return { text = "Renamed " .. e.name, fn = function() F.run_job({ title = "Renaming", quiet = true, tasks = { { kind = "rename", src = dst, dst = e.path } } }) end } end })
end

function F.trash_selected()
    local list = picked_list()
    if #list == 0 then return end
    local srcs = {}
    for _, e in ipairs(list) do srcs[#srcs + 1] = e.path end
    F.run_job({ title = "Moving to the Trash", quiet = #srcs < 4, tasks = { { kind = "trash", srcs = srcs } },
        undo = function(job)
            local origs = {}
            for _, r in ipairs(job.results) do origs[#origs + 1] = r.src end
            return { text = "Moved " .. items_text(#origs) .. " to the Trash", fn = function() F.restore_paths(origs) end }
        end })
end
function F.restore_selected()
    local list = picked_list()
    if #list == 0 then return end
    local tasks = {}
    for _, e in ipairs(list) do
        if e.orig then tasks[#tasks + 1] = { kind = "restore", src = e.path, orig = e.orig } end
    end
    if #tasks == 0 then say("Nothing there knows where it came from") return end
    F.run_job({ title = "Putting back", quiet = #tasks < 4, tasks = tasks,
        undo = function(job)
            local now = {}
            for _, r in ipairs(job.results) do now[#now + 1] = r.dst end
            return { text = "Put back " .. items_text(#now), fn = function() F.run_job({ title = "Moving to the Trash", quiet = true, tasks = { { kind = "trash", srcs = now } } }) end }
        end })
end

-- a path that must never be deleted, however it is asked for: the root, the home folder, and the places in the sidebar
local function protected(path)
    if path == "/" or path == s.home or path == s.data .. "/Trash" or path == s.data .. "/Trash/files" then return true end
    for _, p in ipairs(s.places) do if p.path == path then return true end end
    local _, depth = path:gsub("/", "")
    return depth < 2
end
function F.delete_for_good()
    local list = picked_list()
    if #list == 0 then return end
    for _, e in ipairs(list) do
        if protected(e.path) then say("That one is not to be deleted") return end
    end
    local what = #list == 1 and ("\"" .. list[1].name .. "\"") or (#list .. " items")
    F.confirm("Delete for good?", what .. " will be deleted permanently. This cannot be undone.", "Delete", function()
        local srcs = {}
        for _, e in ipairs(list) do srcs[#srcs + 1] = e.path end
        F.run_job({ title = "Deleting", tasks = { { kind = "delete", srcs = srcs } } })
    end)
end
function F.empty_trash(from_place)
    if #s.items == 0 and not from_place and fact["in.trash"] == true then return end
    F.confirm("Empty the Trash?", "Everything in the Trash will be deleted permanently. This cannot be undone.", "Empty", function()
        run("gio", { "trash", "--empty" }, function(_, code)
            if code ~= 0 then say("The Trash could not be emptied") end
            F.refresh()
        end)
    end)
end

-- Copy and cut go on the system clipboard (what the file managers use: `x-special/gnome-copied-files`, a first line `copy` or `cut` and then one `file://` address a line), so that
-- another window of this, or another file manager, can paste what was copied here, and the other way round. `s.clip` only remembers what this window cut, to draw it faint.
function F.set_clip(cut)
    local list = picked_list()
    if #list == 0 then return end
    local set, uris = {}, { cut and "cut" or "copy" }
    for _, e in ipairs(list) do set[e.path] = true; uris[#uris + 1] = uri_of(e.path) end
    s.clip = { cut = cut, set = set }
    run("wl-copy", { "-t", "x-special/gnome-copied-files", "--", table.concat(uris, "\n") }, function(_, code)
        if code ~= 0 then say("The clipboard could not be written") end
    end)
    fact["clip.on"] = true
    say(string.format("%d %s", #list, cut and "cut" or "copied"), 3)
    F.show_rows()
end
function F.clear_clip()
    s.clip = nil
    fact["clip.on"] = false
    run("wl-copy", { "--clear" }, function() end)
end
local function paths_of(data)
    local out = {}
    for line in (data or ""):gmatch("[^\r\n]+") do
        local p = line:match("^file://(/.*)$")
        if p then p = unescape(p) elseif line:sub(1, 1) == "/" then p = line end
        if p and p ~= "/" then out[#out + 1] = (p:gsub("/+$", "")) end
    end
    return out
end
F.paths_of = paths_of
-- What is on the clipboard, from this window or any other program: the paths and whether they were cut. The file managers' own kind first, then a plain list of addresses.
function F.read_clip(cb)
    run("wl-paste", { "--no-newline", "-t", "x-special/gnome-copied-files" }, function(out, code)
        if code == 0 and out and out ~= "" then
            local paths = paths_of(out)
            if #paths > 0 then cb(paths, out:match("^[^\r\n]*") == "cut") return end
        end
        run("wl-paste", { "--no-newline", "-t", "text/uri-list" }, function(out2, code2)
            local paths = code2 == 0 and paths_of(out2) or {}
            if #paths > 0 then cb(paths, false) else cb(nil) end
        end)
    end)
end

-- Look at what each of these is (a folder or not), so that a question about a name can say which.
function F.src_info(paths, cb)
    local args = { "-L" }
    for _, p in ipairs(paths) do args[#args + 1] = p end
    for _, x in ipairs({ "-maxdepth", "0", "-printf", "%y\t%p\n" }) do args[#args + 1] = x end
    run("find", args, function(out)
        local info = {}
        for line in (out or ""):gmatch("[^\n]+") do
            local ty, p = line:match("^(%a)\t(.*)$")
            if p then info[#info + 1] = { path = p, dir = ty == "d" } end
        end
        cb(info)
    end)
end

-- Into `dest`: `mode` "copy" or "move"; a copy into the folder it came from gets a name of its own at once, and anything else that is taken is asked about.
function F.bring(paths, dest, mode, opts)
    opts = opts or {}
    local jobs = {}
    for _, src in ipairs(paths) do
        local same_dir = dirname(src) == dest
        if src == dest or (dest .. "/"):sub(1, #src + 1) == src .. "/" then
            say("A folder cannot go into itself")
        elseif mode == "move" and same_dir then
            -- nothing to do
        else
            jobs[#jobs + 1] = { kind = mode, src = src, into = dest, auto_both = same_dir and mode == "copy" }
        end
    end
    if #jobs == 0 then say("Already in " .. (basename(dest) == "" and "/" or basename(dest))) return end
    F.src_info(paths, function(info)
        F.run_job({
            title = mode == "move" and "Moving" or "Copying", tasks = jobs, src_info = info,
            undo = function(job)
                local made = {}
                for _, r in ipairs(job.results) do made[#made + 1] = r end
                if #made == 0 then return nil end
                if mode == "move" then
                    return { text = "Moved " .. items_text(#made), fn = function()
                        local back = {}
                        for _, r in ipairs(made) do back[#back + 1] = { kind = "move", src = r.dst, dst = r.src, into = dirname(r.src) } end
                        F.run_job({ title = "Moving back", tasks = back, src_info = {} })
                    end }
                end
                return { text = "Copied " .. items_text(#made), fn = function()
                    local srcs = {}
                    for _, r in ipairs(made) do srcs[#srcs + 1] = r.dst end
                    F.run_job({ title = "Removing the copies", quiet = true, tasks = { { kind = "trash", srcs = srcs } } })
                end }
            end,
            after = opts.after,
        })
    end)
end

function F.paste(into)
    into = into or s.path
    if s.list then say("Open a folder to paste into it") return end
    F.read_clip(function(paths, cut)
        if not paths then
            -- no files, but maybe a picture (a screenshot): it becomes a new file here
            run("sh", { "-c", 'wl-paste -l 2>/dev/null | grep -qx image/png || exit 3; '
                .. 'f=' .. shq(into) .. '/"screenshot_$(date +%F_%H-%M-%S).png"; wl-paste --no-newline -t image/png > "$f" || { rm -f "$f"; exit 1; }' }, function(_, code)
                if code == 0 then say("Pasted the picture"); F.refresh()
                elseif code == 3 then say("Nothing to paste")
                else say("The picture could not be pasted") end
            end)
            return
        end
        if cut then
            F.bring(paths, into, "move", { after = function(ok) if ok then F.clear_clip() end end })
        else
            F.bring(paths, into, "copy")
        end
    end)
end

-- dropped from another window or program (or from here), onto a folder: moved if it is on the same disk, copied if not; Ctrl forces a copy and Shift a move
function F.transfer(paths, dest)
    local shift, ctrl = mods()
    if dest == s.data .. "/Trash/files" then
        F.run_job({ title = "Moving to the Trash", quiet = #paths < 4, tasks = { { kind = "trash", srcs = paths } },
            undo = function(job)
                local origs = {}
                for _, r in ipairs(job.results) do origs[#origs + 1] = r.src end
                return { text = "Moved " .. items_text(#origs) .. " to the Trash", fn = function() F.restore_paths(origs) end }
            end })
        return
    end
    if ctrl then F.bring(paths, dest, "copy") return end
    if shift then F.bring(paths, dest, "move") return end
    local args = { "-c", "%d", "--", dest }
    for _, p in ipairs(paths) do args[#args + 1] = p end
    run("stat", args, function(out)
        local devs = {}
        for line in (out or ""):gmatch("[^\n]+") do devs[#devs + 1] = line end
        local move, copy = {}, {}
        for i, p in ipairs(paths) do
            if devs[1] ~= nil and devs[1] == devs[i + 1] then move[#move + 1] = p else copy[#copy + 1] = p end
        end
        if #move > 0 then F.bring(move, dest, "move") end
        if #copy > 0 then F.bring(copy, dest, "copy") end
    end)
end

function F.duplicate()
    local list = picked_list()
    local paths = {}
    for _, e in ipairs(list) do paths[#paths + 1] = e.path end
    if #paths == 0 then return end
    local jobs = {}
    for _, p in ipairs(paths) do jobs[#jobs + 1] = { kind = "copy", src = p, into = dirname(p), auto_both = true } end
    F.src_info(paths, function(info)
        F.run_job({ title = "Copying", tasks = jobs, src_info = info,
            undo = function(job)
                local srcs = {}
                for _, r in ipairs(job.results) do srcs[#srcs + 1] = r.dst end
                return { text = "Duplicated " .. items_text(#srcs), fn = function() F.run_job({ title = "Removing the copies", quiet = true, tasks = { { kind = "trash", srcs = srcs } } }) end }
            end })
    end)
end
function F.make_links()
    local list = picked_list()
    if #list == 0 then return end
    local tasks = {}
    for _, e in ipairs(list) do tasks[#tasks + 1] = { kind = "link", src = e.path, dst = join(s.path, "Link to " .. e.name) } end
    F.run_job({ title = "Making links", quiet = true, tasks = tasks,
        undo = function(job)
            local srcs = {}
            for _, r in ipairs(job.results) do srcs[#srcs + 1] = r.dst end
            return { text = "Made " .. items_text(#srcs) .. " of links", fn = function() F.run_job({ title = "Removing", quiet = true, tasks = { { kind = "trash", srcs = srcs } } }) end }
        end })
end

local ARCHIVES = {
    { label = "Zip", sub = "Opens everywhere, Windows and Mac too", ext = ".zip", ic = 22 },
    { label = "Tar with gzip", sub = ".tar.gz", ext = ".tar.gz", ic = 22 },
    { label = "Tar with xz", sub = ".tar.xz, smaller and slower", ext = ".tar.xz", ic = 22 },
    { label = "Tar with zstd", sub = ".tar.zst, small and quick", ext = ".tar.zst", ic = 22 },
}
function F.compress()
    local list = picked_list()
    if #list == 0 then return end
    local dir = dirname(list[1].path)
    for _, e in ipairs(list) do
        if dirname(e.path) ~= dir then say("Compress works on things that are in one folder") return end
    end
    F.pick("Make an archive of " .. (#list == 1 and list[1].name or (#list .. " things")), ARCHIVES, function(r)
        local base = #list == 1 and stem_of(list[1].name) or "Archive"
        run("find", { dir, "-maxdepth", "1", "-mindepth", "1", "-printf", "%f\n" }, function(out)
            local set = {}
            for n in (out or ""):gmatch("[^\n]+") do set[n] = true end
            local name = free_in(base .. r.ext, set)
            local dst = join(dir, name)
            local args = { "-a", "-cf", dst, "-C", dir }
            for _, e in ipairs(list) do args[#args + 1] = e.name end
            F.run_job({ title = "Making an archive", tasks = { { kind = "exec", cmd = "bsdtar", args = args, created = dst, label = name, fail = "Could not make the archive" } }, pick_name = name,
                undo = function(job) return { text = "Made " .. name, fn = function() F.run_job({ title = "Removing", quiet = true, tasks = { { kind = "trash", srcs = { dst } } } }) end } end })
        end)
    end)
end
function F.extract()
    local e = picked_list()[1]
    if not e or e.ik ~= 6 then return end
    local dir = dirname(e.path)
    run("find", { dir, "-maxdepth", "1", "-mindepth", "1", "-printf", "%f\n" }, function(out)
        local set = {}
        for n in (out or ""):gmatch("[^\n]+") do set[n] = true end
        local name = free_in(stem_of(e.name), set)
        local dst = join(dir, name)
        F.run_job({ title = "Opening an archive",
            tasks = { { kind = "mkdir", dst = dst }, { kind = "exec", cmd = "bsdtar", args = { "-xf", e.path, "-C", dst }, label = e.name, fail = "Could not open the archive" } },
            pick_name = name,
            undo = function(job) return { text = "Opened " .. e.name, fn = function() F.run_job({ title = "Removing", quiet = true, tasks = { { kind = "trash", srcs = { dst } } } }) end } end })
    end)
end

function F.from_template()
    if not s.templates then return end
    run("find", { s.templates, "-maxdepth", "1", "-mindepth", "1", "-type", "f", "-printf", "%f\n" }, function(out)
        local rows = {}
        for n in (out or ""):gmatch("[^\n]+") do rows[#rows + 1] = { label = n, ic = 28, name = n } end
        table.sort(rows, function(a, b) return a.label < b.label end)
        if #rows == 0 then say("There is nothing in the Templates folder") return end
        F.pick("New from a template", rows, function(r)
            F.run_job({ title = "Making a file", quiet = true, tasks = { { kind = "copy", src = join(s.templates, r.name), into = s.path, auto_both = true } },
                undo = function(job)
                    local srcs = {}
                    for _, x in ipairs(job.results) do srcs[#srcs + 1] = x.dst end
                    return { text = "Made " .. basename(srcs[1] or r.name), fn = function() F.run_job({ title = "Removing", quiet = true, tasks = { { kind = "trash", srcs = srcs } } }) end }
                end })
        end)
    end)
end

function F.copy_path()
    local list = picked_list()
    local paths = {}
    for _, e in ipairs(list) do paths[#paths + 1] = e.path end
    if #paths == 0 then paths[1] = s.path end
    run("wl-copy", { "--", table.concat(paths, "\n") }, function(_, code)
        say(code == 0 and (#paths == 1 and "Path copied" or (#paths .. " paths copied")) or "The clipboard could not be written", 3)
    end)
end
function F.star_toggle()
    local list = picked_list()
    if #list == 0 then return end
    local add = not s.stars[list[1].path]
    for _, e in ipairs(list) do
        if add and not s.stars[e.path] then s.stars[e.path] = true; s.star_list[#s.star_list + 1] = e.path
        elseif not add and s.stars[e.path] then
            s.stars[e.path] = nil
            for i, p in ipairs(s.star_list) do if p == e.path then table.remove(s.star_list, i) break end end
        end
    end
    F.save()
    say(add and (items_text(#list) .. " starred") or "Not starred any more", 3)
    if s.list == "starred" then F.refresh() else F.show_rows() end
end
function F.set_wallpaper()
    local e = picked_list()[1]
    if not e or e.ik ~= 1 then return end
    run("awww", { "img", e.path, "--transition-type", "fade", "--transition-duration", "0.8" }, function(_, code)
        say(code == 0 and "That is the wallpaper now" or "Could not change the wallpaper (is awww running?)", 4)
    end)
end

-- a terminal in a folder
local TERMINALS = {
    { "kitty", { "--directory" } },
    { "alacritty", { "--working-directory" } },
    { "foot", { "--working-directory" } },
    { "wezterm", { "start", "--cwd" } },
    { "konsole", { "--workdir" } },
    { "gnome-terminal", { "--working-directory" } },
}
function F.open_terminal(dir)
    dir = dir or s.path
    if not dir or dir:sub(1, 1) ~= "/" then dir = s.home end
    local function try(i)
        local t = TERMINALS[i]
        if not t then say("No terminal was found (set $TERMINAL)") return end
        run("which", { t[1] }, function(_, code)
            if code ~= 0 then try(i + 1) return end
            local args = {}
            for _, a in ipairs(t[2]) do args[#args + 1] = a end
            args[#args + 1] = dir
            spawn(t[1], args, function() end, function() end)
        end)
    end
    run("printenv", { "TERMINAL" }, function(o, code)
        local want = trim(o)
        if code == 0 and want ~= "" then
            for i, t in ipairs(TERMINALS) do
                if t[1] == basename(want) then try(i) return end
            end
        end
        try(1)
    end)
end
function F.new_window(path)
    spawn("vitreus-files", { path or s.path }, function() end, function() end)
end

-- a folder pinned to the places
function F.pin_folders(paths)
    if #paths == 0 then return end
    local args = {}
    for _, p in ipairs(paths) do args[#args + 1] = p end
    for _, x in ipairs({ "-maxdepth", "0", "-type", "d", "-printf", "%p\n" }) do args[#args + 1] = x end
    run("find", args, function(out)
        local added = {}
        local have = {}
        for _, p in ipairs(s.places) do if p.path then have[p.path] = true end end
        for line in (out or ""):gmatch("[^\n]+") do
            if not have[line] then
                s.pins[#s.pins + 1] = line
                have[line] = true
                added[#added + 1] = basename(line)
            end
        end
        if #added == 0 then
            say("Only folders can be pinned, and not twice")
            return
        end
        F.save()
        F.build_places()
        F.show_places()
        say("Pinned " .. table.concat(added, ", "), 3)
    end)
end
function F.unpin(path)
    for i, p in ipairs(s.pins) do if p == path then table.remove(s.pins, i) break end end
    F.save()
    F.build_places()
    F.show_places()
end

-- Several things given a name and a number each ("Holiday 1.jpg", "Holiday 2.jpg"…), in the order they are in the folder; the ending of each stays.
function F.batch_rename(base)
    local list = picked_list()
    if #list < 2 then F.close_ask() return end
    if base:find("/", 1, true) or base == "." or base == ".." then say("A name cannot have a slash in it") return end
    local taken = {}
    for _, e in ipairs(s.all or {}) do taken[e.name] = true end
    local tasks, plan = {}, {}
    local digits = #tostring(#list)
    for i, e in ipairs(list) do
        local ext = e.dir and "" or (e.name:match("(%.[^.]+)$") or "")
        local name = string.format("%s %0" .. digits .. "d%s", base, i, ext)
        if taken[name] then say("\"" .. name .. "\" is already there") return end
        tasks[#tasks + 1] = { kind = "rename", src = e.path, dst = join(dirname(e.path), name) }
        plan[#plan + 1] = { from = e.path, to = join(dirname(e.path), name) }
    end
    F.close_ask()
    F.run_job({ title = "Renaming", quiet = true, tasks = tasks,
        undo = function(job)
            return { text = "Renamed " .. items_text(#job.results), fn = function()
                local back = {}
                for _, r in ipairs(job.results) do back[#back + 1] = { kind = "rename", src = r.dst, dst = r.src } end
                F.run_job({ title = "Renaming", quiet = true, tasks = back })
            end }
        end })
end

-- ── search ──
-- The magnifier (or Ctrl+F, or just typing) opens a field where the path was. What is typed narrows this folder as it is typed (`filter`); Enter looks in the folders under it as well (`deep`: up to
-- 500 finds, eight folders down, leaving out version control, caches and, unless hidden files are shown, the hidden folders) and shows them as the folder's own list, so they open, copy, cut and go to
-- the Trash like anything else. The choices under the field say whether to look at names or at what is written in the files, for one kind of thing, in this folder or all the home folder. A search that
-- is going on stops when another is asked for, or when the field is closed (Escape, the magnifier again, or going to another folder), which puts the folder back.
local search_seq = 0

local function patterns_for(kind)
    local want = ({ [2] = { image = true }, [3] = { pdf = true, doc = true, code = true }, [4] = { audio = true }, [5] = { video = true } })[kind]
    local list = {}
    if want then
        for ext, k in pairs(EXT) do if want[k] then list[#list + 1] = ext end end
        table.sort(list)
    end
    return list
end

function F.stop_search()
    if s.search_proc then kill(s.search_proc); s.search_proc = nil end
    s.search_timer = nil
end

function F.run_search(again)
    local q = trim(s.qtext)
    local kind = s.so.kind
    if q == "" and kind == 0 then return end
    F.stop_search()
    search_seq = search_seq + 1
    local mine = search_seq
    local here = s.so.where == 1 and s.home or s.path
    if s.list then here = s.so.where == 1 and s.home or s.home end
    s.search_root = here
    local items, count = {}, 0
    local running = true
    local function publish(final)
        if mine ~= search_seq or not s.mode then return end
        s.mode, s.results = "deep", items
        s.items = F.visible()
        s.picked = {}
        if not again then
            s.first = 0
            s.scroll = 0
            fact.sct = 0
            fact.gen = (tonumber(fact.gen) or 0) + 1
            again = true
        end
        fact["in.list"] = true
        F.set_empty()
        F.show_rows()
        if not final then say(string.format("Searching… %d found", #items), 2) else s.flash_until = 0 F.set_status() end
    end
    local function tick_publish()
        if mine ~= search_seq or not running then return end
        if #items > 0 then publish(false) end
        after(450, tick_publish)
    end
    say("Searching…", 30)
    if s.so.what == 1 and q ~= "" then
        local args = { here, "-mindepth", "1", "(", "-name", ".git", "-o", "-name", "node_modules", "-o", "-name", ".cache" }
        if not s.hidden then for _, x in ipairs({ "-o", "-name", ".*" }) do args[#args + 1] = x end end
        for _, x in ipairs({ ")", "-prune", "-o", "-type", "f", "-exec", "grep", "-l", "-I", "-i", "-F", "--", q, "{}", "+" }) do args[#args + 1] = x end
        local paths = {}
        s.search_proc = spawn("find", args, function(line)
            if #paths < 500 and line ~= "" then paths[#paths + 1] = line end
        end, function()
            s.search_proc = nil
            if mine ~= search_seq then return end
            F.list_paths(paths, function(found)
                running = false
                if mine ~= search_seq then return end
                for _, e in ipairs(found) do
                    if kind_ok(e, kind) then items[#items + 1] = e end
                end
                publish(true)
            end)
        end)
        return
    end
    local args = { here, "-mindepth", "1", "-maxdepth", "8", "(", "-name", ".git", "-o", "-name", "node_modules", "-o", "-name", ".cache" }
    if not s.hidden then for _, a in ipairs({ "-o", "-name", ".*" }) do args[#args + 1] = a end end
    for _, a in ipairs({ ")", "-prune", "-o" }) do args[#args + 1] = a end
    if kind == 1 then
        args[#args + 1] = "-type"; args[#args + 1] = "d"
    elseif kind > 1 then
        args[#args + 1] = "!"; args[#args + 1] = "-type"; args[#args + 1] = "d"
        args[#args + 1] = "("
        local first = true
        for _, ext in ipairs(patterns_for(kind)) do
            if not first then args[#args + 1] = "-o" end
            first = false
            args[#args + 1] = "-iname"
            args[#args + 1] = "*." .. ext
        end
        args[#args + 1] = ")"
    end
    if q ~= "" then
        local glob = q:gsub("[%*%?%[%]\\]", "\\%0")
        args[#args + 1] = "-iname"
        args[#args + 1] = "*" .. glob .. "*"
    end
    for _, a in ipairs({ "-printf", "%y\t%s\t%T@\t%m\t%p\n" }) do args[#args + 1] = a end
    s.search_proc = spawn("find", args, function(line)
        if mine ~= search_seq or count >= 500 then return end
        local ty, sz, mt, mode, path = line:match("^(%a)\t(%d+)\t([%d%.]+)\t(%d+)\t(.*)$")
        if path then
            count = count + 1
            items[#items + 1] = make_item(path, basename(path), ty == "d", tonumber(sz) or 0, tonumber(mt) or 0, tonumber(mode, 8) or 0, ty == "l", false)
            if count >= 500 and s.search_proc then kill(s.search_proc) end
        end
    end, function()
        s.search_proc = nil
        running = false
        if mine ~= search_seq then return end
        publish(true)
    end)
    after(450, tick_publish)
end

function F.open_search()
    F.close_menu()
    if not s.mode then
        s.mode, s.qtext = "filter", ""
        text.sq = ""
        fact.searching = true
    end
    after(60, function() focus("sq") end)
end
function F.close_search()
    if not s.mode then return end
    search_seq = search_seq + 1
    F.stop_search()
    s.mode, s.results, s.qtext = nil, nil, ""
    text.sq = ""
    fact.searching = false
    fact["in.list"] = s.list ~= nil
    s.flash_until = 0
    focus()
    s.items = F.visible()
    s.picked = {}
    s.first = 0
    s.scroll = 0
    fact.sct = 0
    fact.gen = (tonumber(fact.gen) or 0) + 1
    F.set_empty()
    F.show_rows()
end
-- while it is typed: this folder is narrowed at once (only when it is names in this folder that are looked for; anything else waits for Enter)
function F.typed(v)
    s.qtext = v or ""
    if not s.mode then return end
    search_seq = search_seq + 1
    F.stop_search()
    s.mode, s.results = "filter", nil
    fact["in.list"] = s.list ~= nil
    s.items = F.visible()
    s.picked = {}
    s.first = 0
    s.scroll = 0
    fact.sct = 0
    fact.gen = (tonumber(fact.gen) or 0) + 1
    F.set_empty()
    F.show_rows()
end
on("text:sq", function(v)
    if (s.so.where == 1 or s.so.what == 1) and s.mode then
        -- (looking at contents, or all the home folder, is for Enter: the folder as it is stays on screen)
        s.qtext = v or ""
        return
    end
    F.typed(v)
end)
on("search_go", function() F.run_search() end)
on("sopt", function(k)
    k = math.floor(tonumber(k) or 0)
    if k == 10 or k == 11 then s.so.what = k - 10; fact["so.what"] = s.so.what
    elseif k >= 20 and k <= 25 then s.so.kind = k - 20; fact["so.kind"] = s.so.kind
    elseif k == 30 or k == 31 then s.so.where = k - 30; fact["so.where"] = s.so.where end
    if s.mode == "deep" then
        F.run_search(true)
    elseif s.mode == "filter" then
        if s.so.where == 1 or s.so.what == 1 then
            -- the folder as it is until Enter
            s.items = F.visible()
            F.show_rows()
        else
            F.typed(s.qtext)
        end
        if s.so.kind ~= 0 and s.qtext == "" and (s.so.where == 1 or s.so.what == 1) then F.run_search() end
    end
    after(60, function() focus("sq") end)
end)

-- ── dragging files in and out ──
-- What was carried arrives by the zone's name (`drop:<zone>`, the paths as `file://…` lines) and where it was dropped by the scene's event `dropped(k)`: whichever comes second does the work.
-- k: a tile's number (a folder takes it in; a file means this folder), -1 the empty middle, -100 - n a place, -200 - n a folder of the path, -300 - n a tab, -400 the pin zone.
local function do_drop(data, k)
    local paths = F.paths_of(data)
    if #paths == 0 then return end
    if k == -400 then F.pin_folders(paths) return end
    local dest = s.path
    if k >= 0 then
        local e = s.items[k + 1]
        if e and e.dir then dest = e.path end
    elseif k <= -300 then
        local t = s.tabs[-300 - k + 1]
        if t then dest = t.path end
    elseif k <= -200 then
        local c = s.crumbs[-200 - k + 1]
        if c then dest = c.path end
    elseif k <= -100 then
        local p = s.places[-100 - k + 1]
        if p and p.path then dest = p.path end
    end
    if dest:sub(1, 1) ~= "/" then say("Open a folder to drop things into") return end
    F.transfer(paths, dest)
end
-- More than one zone says it was dropped on (a folder, and the middle behind it): for a moment they are collected and the most specific one is the one that counts.
local drop_data, drop_at, drop_rank = nil, nil, 0
local drop_timer = false
local function rank(k)
    if k >= 0 then return 3 end
    if k <= -100 then return 2 end
    return 1
end
local function settle()
    if drop_timer then return end
    drop_timer = true
    after(120, function()
        drop_timer = false
        local data, k = drop_data, drop_at
        drop_data, drop_at, drop_rank = nil, nil, 0
        if data and k then do_drop(data, k) end
    end)
end
for _, zone in ipairs({ "midzone", "t", "pz", "cz", "pinzone", "tz" }) do       -- (the list lies over the middle: a drop on its empty part is the middle's)
    on("drop:" .. zone, function(data)
        drop_data = data
        settle()
    end)
end
on("dropped", function(k)
    k = math.floor(tonumber(k) or 0)
    if rank(k) > drop_rank then drop_at, drop_rank = k, rank(k) end
    settle()
end)

-- ── the name dialog's answer ──
function F.ask_ok()
    if s.ask == "confirm" then
        local fn = s.confirm_fn
        F.close_ask()
        if fn then fn() end
        return
    end
    local name = trim(text.askin)
    if name == "" then return end
    local kind = s.ask
    if kind == "connect" then
        F.close_ask()
        F.connect(name)
        return
    end
    if kind == "pinname" then
        F.close_ask()
        if s.pin_edit then
            if name == basename(s.pin_edit) then s.pin_names[s.pin_edit] = nil else s.pin_names[s.pin_edit] = name end
            F.save()
            F.build_places()
            F.show_places()
        end
        return
    end
    if kind == "batch" then
        F.batch_rename(name)
        return
    end
    if name:find("/", 1, true) or name == "." or name == ".." then
        say("A name cannot have a slash in it")
        return
    end
    if kind == "new" or kind == "newfile" then
        F.name_taken(s.path, name, function(taken)
            if taken then say("\"" .. name .. "\" is already there") return end
            F.close_ask()
            if kind == "new" then F.new_folder(name) else F.new_file(name) end
        end)
    elseif kind == "rename" then
        local e = picked_list()[1]
        if not e then F.close_ask() return end
        if name == e.name then F.close_ask() return end
        F.name_taken(dirname(e.path), name, function(taken)
            if taken then say("\"" .. name .. "\" is already there") return end
            F.close_ask()
            F.rename(e, name)
        end)
    end
end
on("ask_ok", function() F.ask_ok() end)

-- ── the path, typed ──
function F.loc_edit()
    F.close_menu()
    s.loc = true
    fact["loc.edit"] = true
    text.locin = (s.path:sub(1, 1) == "/") and (s.path == "/" and "/" or (s.path .. "/")) or ""
    after(60, function() focus("locin") end)
end
function F.loc_end()
    s.loc = nil
    fact["loc.edit"] = false
    focus()
end
-- a place on the network: gvfs mounts it (a password is not asked for here: one that is saved, or none, is what it can use), and then it is a folder like any other
function F.connect(uri)
    if not uri:find("^%a[%w+.-]*://") then uri = "smb://" .. uri end
    say("Connecting to " .. uri .. "…", 20)
    run("gio", { "mount", "--", uri }, function(out, code)
        if code ~= 0 then say("Could not connect: " .. why(out), 8) return end
        F.poll_devices()
        local host = uri:match("://([^/:]+)") or ""
        after(900, function()
            if s.runtime and s.runtime ~= "" then
                run("find", { s.runtime .. "/gvfs", "-maxdepth", "1", "-mindepth", "1", "-printf", "%f\n" }, function(o)
                    local pick
                    for l in (o or ""):gmatch("[^\n]+") do
                        if host ~= "" and l:find(host, 1, true) then pick = l end
                    end
                    if pick then F.go(s.runtime .. "/gvfs/" .. pick) else say("Connected") end
                end)
            end
        end)
    end, { errors = true })
end
function F.loc_commit(v)
    F.loc_end()
    if v == "" then return end
    if v:sub(1, 1) == "~" then v = s.home .. v:sub(2) end
    if v:find("^%a[%w+.-]*://") then
        if v:find("^file://") then v = unescape(v:sub(8)) else F.connect(v) return end
    end
    if v:sub(1, 1) ~= "/" then v = join(s.path, v) end
    v = clean(v)
    F.go(v, nil, nil, function()
        -- not a folder: a file is gone to, by its folder, and chosen
        run("find", { "-L", v, "-maxdepth", "0", "-type", "f" }, function(o)
            if trim(o) ~= "" then F.go(dirname(v), nil, basename(v)) else say("There is no folder " .. v, 6) end
        end)
    end)
end
on("loc_go", function() F.loc_commit(trim(text.locin)) end)
-- Tab finishes the folder's name as far as it can be told
function F.loc_complete()
    local v = trim(text.locin)
    if v:sub(1, 1) == "~" then v = s.home .. v:sub(2) end
    if v:sub(1, 1) ~= "/" then v = join(s.path, v) end
    local dir, prefix = v:match("^(.*)/([^/]*)$")
    if not dir then return end
    if dir == "" then dir = "/" end
    local glob = prefix:gsub("[%*%?%[%]\\]", "\\%0")
    run("find", { "-L", dir, "-maxdepth", "1", "-mindepth", "1", "-type", "d", "-name", glob .. "*", "-printf", "%f\n" }, function(out)
        local names = {}
        for n in (out or ""):gmatch("[^\n]+") do names[#names + 1] = n end
        table.sort(names)
        if #names == 0 then return end
        local common = names[1]
        for _, n in ipairs(names) do
            local i = 1
            while i <= #common and i <= #n and common:sub(i, i) == n:sub(i, i) do i = i + 1 end
            common = common:sub(1, i - 1)
        end
        local full = join(dir, common)
        if #names == 1 then full = full .. "/" end
        text.locin = full
        if #names > 1 then say(#names .. " folders start like that", 3) end
    end)
end

-- ── zoom, sort ──
function F.set_zoom(z)
    z = math.max(1, math.min(#ZOOMS, z))
    if z == s.zoom then return end
    s.zoom = z
    fact.zoom = z
    fact.tilebase = ZOOMS[z]
    F.save()
    F.show_rows()
end
function F.apply_sort()
    fact.sort = s.sort
    fact.sortrev = s.sortrev
    fact.dirfirst = s.dirfirst
    text.sortname = sort_label()
    F.save()
    s.items = F.visible()
    F.show_rows()
end
on("sort_by", function(k)
    k = math.floor(tonumber(k) or 0)
    local key = ({ [0] = "name", "size", "type", "date" })[k] or "name"
    if s.sort == key then s.sortrev = not s.sortrev else s.sort = key; s.sortrev = false end
    F.apply_sort()
end)

-- the escape key (and a click beside a card) takes away the topmost thing
function F.escape()
    if s.pv then F.close_preview()
    elseif s.cf then
        local cf = s.cf
        s.cf = nil
        fact["cf.on"] = false
        cf.cb("stop", false)
    elseif s.picker then F.close_pick()
    elseif s.props then F.close_props(); F.close_props_job()
    elseif s.ask then F.close_ask()
    elseif s.menu then F.close_menu()
    elseif s.loc then F.loc_end()
    elseif s.mode then F.close_search()
    elseif next(s.picked) then s.picked = {}; F.show_rows() end
end

-- ── what the buttons, the menus and the keys ask for ──
local ACT = {}
ACT[1] = function()
    if fact["in.trash"] == true then say("A folder cannot be made in the Trash") return end
    if s.list then say("Open a folder to make one in it") return end
    F.ask_dialog("new", "New folder", "", "Create")
end
ACT[2] = function()
    local list = picked_list()
    if #list == 1 then F.ask_dialog("rename", "Rename", list[1].name, "Rename")
    elseif #list > 1 then F.ask_dialog("batch", string.format("Rename %d items: a name, and they are numbered", #list), "Name", "Rename") end
end
ACT[3] = function() if fact["in.trash"] == true then F.delete_for_good() else F.trash_selected() end end
ACT[4] = function() F.set_clip(false) end
ACT[5] = function() F.set_clip(true) end
ACT[6] = function()
    if fact["in.trash"] == true then say("Use Move to Trash to put things in the Trash") return end
    F.paste()
end
ACT[7] = function()
    local list = picked_list()
    if #list == 1 then F.open_item(list[1])
    else
        for _, e in ipairs(list) do
            if e.dir then F.tab_new(e.path, true) else F.open_item(e) end
        end
    end
end
ACT[8] = function() F.select_all() end
ACT[9] = function() F.refresh() end
ACT[11] = function()
    if s.list then F.go(s.home) return end
    if s.path ~= "/" then F.go(dirname(s.path), nil, basename(s.path)) end
end
ACT[12] = function()
    local p = table.remove(s.back)
    if p then
        s.fwd[#s.fwd + 1] = s.path
        F.go(p, "nav", nil, function() table.remove(s.fwd); s.back[#s.back + 1] = p end)       -- (a folder that has gone: the history stays as it was)
    end
end
ACT[13] = function()
    local p = table.remove(s.fwd)
    if p then
        s.back[#s.back + 1] = s.path
        F.go(p, "nav", nil, function() table.remove(s.back); s.fwd[#s.fwd + 1] = p end)
    end
end
ACT[14] = function()
    s.hidden = not s.hidden
    fact.hidden = s.hidden
    F.save()
    if s.mode == "deep" then F.run_search(true) return end
    s.items = F.visible()
    s.picked = {}
    F.show_rows()
end
ACT[15] = function() F.open_menu("sort") end
ACT[16] = function() F.show_props() end
ACT[17] = function() F.delete_for_good() end
ACT[18] = function() F.empty_trash() end
ACT[24] = function()
    if fact["in.trash"] == true or s.list then say("Open a folder to make a file in it") return end
    F.ask_dialog("newfile", "New file", "Untitled.txt", "Create")
end
ACT[25] = function() F.duplicate() end
ACT[26] = function()
    local e = picked_list()[1]
    if e and not e.dir then F.open_with(e) end
end
ACT[27] = function(ctx)
    if ctx.menu == "place" and ctx.place then F.tab_new(ctx.place.path) return end
    local list = picked_list()
    if #list == 0 then F.tab_new(s.path) return end
    for _, e in ipairs(list) do if e.dir then F.tab_new(e.path, #list > 1) end end
end
ACT[28] = function(ctx)
    if ctx.menu == "place" and ctx.place then F.new_window(ctx.place.path) return end
    local list = picked_list()
    if #list == 0 then F.new_window(s.path) return end
    for _, e in ipairs(list) do if e.dir then F.new_window(e.path) end end
end
ACT[29] = function(ctx)
    local e = picked_list()[1]
    if ctx.menu == "item" and e and e.dir then F.open_terminal(e.path) else F.open_terminal(s.path) end
end
ACT[30] = function() F.open_search() end
ACT[31] = function()
    s.view = "grid"; fact.view = s.view; s.first = 0; F.save(); F.scroll_to(0); F.show_rows()
end
ACT[32] = function()
    s.view = "lines"; fact.view = s.view; s.first = 0; F.save(); F.scroll_to(0); F.show_rows()
end
ACT[33] = function() if s.mode then F.close_search() else F.open_search() end end       -- (the magnifier: open, or shut)
ACT[34] = function() F.compress() end
ACT[35] = function() F.extract() end
ACT[36] = function() F.make_links() end
ACT[37] = function() F.copy_path() end
ACT[38] = function() F.star_toggle() end
ACT[39] = function() F.set_wallpaper() end
ACT[41] = function(ctx)
    local p = ctx.place
    if p and p.pinned then F.unpin(p.path) end
end
ACT[42] = function(ctx) if ctx.place then F.open_place(ctx.place) end end
ACT[43] = function() F.empty_trash(true) end
ACT[44] = function() F.restore_selected() end
ACT[45] = function()
    local e = picked_list()[1]
    if e and e.dir then F.paste(e.path) end
end
ACT[46] = function() F.invert() end
ACT[47] = function() F.undo() end
ACT[48] = function() F.from_template() end
ACT[49] = function() if s.path:sub(1, 1) == "/" then F.pin_folders({ s.path }) end end
ACT[50] = function() F.close_window() end
ACT[51] = function() F.set_zoom(s.zoom + 1) end
ACT[52] = function() F.set_zoom(s.zoom - 1) end
ACT[53] = function() F.set_zoom(3) end
ACT[55] = function() F.toggle_preview() end
ACT[56] = function() F.tab_new(s.path) end
ACT[57] = function() F.tab_close(s.tab) end
ACT[58] = function() if #s.tabs > 1 then F.tab_go(s.tab % #s.tabs + 1) end end
ACT[59] = function() if #s.tabs > 1 then F.tab_go((s.tab - 2) % #s.tabs + 1) end end
ACT[60] = function() F.loc_edit() end
ACT[61] = function() F.go(s.home) end
ACT[62] = function() F.ask_dialog("connect", "Connect to server", "", "Connect") end
ACT[63] = function()
    local e = picked_list()[1]
    if e then F.go(dirname(e.path), nil, e.name) end
end
ACT[64] = function(ctx) if ctx.place then F.eject_place(ctx.place) end end
ACT[65] = function(ctx)
    local p = ctx.place
    if not (p and p.pinned) then return end
    s.pin_edit = p.path
    F.ask_dialog("pinname", "Name this shortcut", p.name, "Rename")
end
local function move_pin(ctx, d)
    local p = ctx.place
    if not (p and p.pinned) then return end
    for i, path in ipairs(s.pins) do
        if path == p.path then
            local j = i + d
            if j >= 1 and j <= #s.pins then s.pins[i], s.pins[j] = s.pins[j], s.pins[i] end
            break
        end
    end
    F.save()
    F.build_places()
    F.show_places()
end
ACT[66] = function(ctx) move_pin(ctx, -1) end
ACT[67] = function(ctx) move_pin(ctx, 1) end
ACT[70] = function() s.sort = "name"; s.sortrev = false; F.apply_sort() end
ACT[71] = function() s.sort = "size"; s.sortrev = false; F.apply_sort() end
ACT[72] = function() s.sort = "type"; s.sortrev = false; F.apply_sort() end
ACT[73] = function() s.sort = "date"; s.sortrev = false; F.apply_sort() end
ACT[74] = function() s.sortrev = not s.sortrev; F.apply_sort() end
ACT[75] = function() s.dirfirst = not s.dirfirst; F.apply_sort() end

on("act", function(k)
    k = math.floor(tonumber(k) or 0)
    local ctx = { menu = s.menu, place = s.menu_place }
    if k == 10 then F.escape() return end
    if s.menu then F.close_menu() end
    if k > CUSTOM_K and k <= CUSTOM_K + 8 then run_custom(k - CUSTOM_K, ctx) return end
    local fn = ACT[k]
    if fn then fn(ctx) end
end)

-- ── the keys ──
-- Every key comes here, with what it writes; what is typed in a field is that field's, so while one has the keys (a name being given, the search, the path) only the few that mean something to it are
-- looked at. A letter typed with nothing else open begins a search.
local function parse_key(name)
    local parts = {}
    for p in name:gmatch("[^+]+") do parts[#parts + 1] = p end
    local base = parts[#parts] or name
    local m = { ctrl = false, alt = false, shift = false, super = false }
    for i = 1, #parts - 1 do
        local x = parts[i]:lower()
        if x == "ctrl" or x == "control" then m.ctrl = true
        elseif x == "alt" then m.alt = true
        elseif x == "shift" then m.shift = true
        elseif x == "super" then m.super = true end
    end
    return base, m
end
local MODKEYS = { Shift_L = true, Shift_R = true, Control_L = true, Control_R = true, Alt_L = true, Alt_R = true, Super_L = true, Super_R = true, Caps_Lock = true, ISO_Level3_Shift = true, Meta_L = true, Meta_R = true, Num_Lock = true }

on("key", function(name, txt)
    local b, m = parse_key(name)
    if MODKEYS[b] then return end
    local lb = #b == 1 and b:lower() or b
    if lb == "Escape" then F.escape() return end
    -- a question that waits for its answer
    if s.cf then return end
    if s.ask then
        if s.ask == "confirm" and lb == "Return" then F.ask_ok() end
        return
    end
    if s.picker then return end
    if s.props then return end
    if s.pv then
        if lb == "Left" or lb == "Up" then F.preview_step(-1)
        elseif lb == "Right" or lb == "Down" then F.preview_step(1)
        elseif lb == "space" then F.close_preview()
        elseif lb == "Return" then local e = s.items[s.pv]; F.close_preview(); if e then F.open_item(e) end end
        return
    end
    if s.menu then return end
    if s.loc then
        if lb == "Tab" then F.loc_complete() end
        return
    end
    if fact.searching == true then
        if lb == "Down" and not m.ctrl then
            focus()
            if #s.items > 0 then F.move_choice(0, "single", 1) end
        elseif lb == "f" and m.ctrl then F.close_search() end
        return
    end
    if m.super then return end
    -- the keys with Alt
    if m.alt and not m.ctrl then
        if lb == "Up" then ACT[11]({}) return end
        if lb == "Left" then ACT[12]({}) return end
        if lb == "Right" then ACT[13]({}) return end
        if lb == "Home" then ACT[61]({}) return end
        if lb == "Return" then ACT[16]({}) return end
        if lb:match("^%d$") then F.tab_go(tonumber(lb)) return end
        return
    end
    if m.ctrl then
        if lb == "c" then if m.shift then ACT[37]({}) else ACT[4]({}) end return end
        if lb == "x" then ACT[5]({}) return end
        if lb == "v" then ACT[6]({}) return end
        if lb == "a" then ACT[8]({}) return end
        if lb == "i" then ACT[46]({}) return end
        if lb == "z" then ACT[47]({}) return end
        if lb == "h" then ACT[14]({}) return end
        if lb == "n" then if m.shift then ACT[1]({}) else F.new_window(s.path) end return end
        if lb == "f" then ACT[30]({}) return end
        if lb == "l" then ACT[60]({}) return end
        if lb == "t" then ACT[56]({}) return end
        if lb == "w" then if #s.tabs > 1 then ACT[57]({}) else F.close_window() end return end
        if lb == "d" then ACT[49]({}) return end
        if lb == "o" then ACT[7]({}) return end
        if lb == "r" then ACT[9]({}) return end
        if lb == "1" then ACT[31]({}) return end
        if lb == "2" then ACT[32]({}) return end
        if lb == "plus" or lb == "equal" or lb == "KP_Add" then ACT[51]({}) return end
        if lb == "minus" or lb == "KP_Subtract" then ACT[52]({}) return end
        if lb == "0" or lb == "KP_0" then ACT[53]({}) return end
        if lb == "Tab" or lb == "Next" then ACT[58]({}) return end
        if lb == "ISO_Left_Tab" or lb == "Prior" then ACT[59]({}) return end
        if lb == "space" then F.toggle_cursor() return end
        if lb == "Left" or lb == "Right" or lb == "Up" or lb == "Down" or lb == "Home" or lb == "End" then
            -- (Ctrl moves the frame and leaves the choice; with Shift too it stretches it)
            local how = m.shift and "extend" or "cursor"
            local d = ({ Left = -1, Right = 1, Up = -down_by(), Down = down_by() })[lb]
            if (lb == "Left" or lb == "Right") and s.view ~= "grid" then return end
            if lb == "Home" then F.move_choice(0, how, 1) elseif lb == "End" then F.move_choice(0, how, #s.items) else F.move_choice(d, how) end
        end
        return
    end
    local how = m.shift and "extend" or "single"
    if lb == "Return" then ACT[7]({}) return end
    if lb == "F2" then ACT[2]({}) return end
    if lb == "Delete" or lb == "KP_Delete" then if m.shift then ACT[17]({}) else ACT[3]({}) end return end
    if lb == "F5" then ACT[9]({}) return end
    if lb == "BackSpace" then ACT[11]({}) return end
    if lb == "space" then ACT[55]({}) return end
    if lb == "Left" then if s.view == "grid" then F.move_choice(-1, how) end return end
    if lb == "Right" then if s.view == "grid" then F.move_choice(1, how) end return end
    if lb == "Up" then F.move_choice(-down_by(), how) return end
    if lb == "Down" then F.move_choice(down_by(), how) return end
    if lb == "Home" then F.move_choice(0, how, 1) return end
    if lb == "End" then F.move_choice(0, how, #s.items) return end
    if lb == "Prior" then F.move_choice(-F.page_by(), how) return end
    if lb == "Next" then F.move_choice(F.page_by(), how) return end
    if lb == "Menu" or (lb == "F10" and m.shift) then
        local e = s.items[s.cursor or 0]
        if e and not s.picked[e.path] then s.picked = { [e.path] = true }; F.show_rows() end
        fact["menu.x"] = 300; fact["menu.y"] = 200
        F.open_menu(next(s.picked) and "item" or "bg")
        return
    end
    -- a letter, or a figure, with nothing else open: a search that begins with it
    if type(txt) == "string" and #txt == 1 and txt:byte() >= 33 and txt:byte() < 127 and not m.ctrl and not m.alt then
        F.open_search()
        text.sq = txt
        F.typed(txt)
        return
    end
end)

-- coming back to this window: what was dragged out or in from another one shows
on("focused", function()
    if s.path ~= "" and not s.busy then F.refresh() end
    -- a cut that was pasted from another window (which clears the clipboard) is not a cut here any more
    if s.clip then
        F.read_clip(function(paths) if not paths and s.clip then s.clip = nil; fact["clip.on"] = false; F.show_rows() end end)
    end
    if s.path ~= "" then F.poll_devices() end
end)

-- the clock: for telling a double click from two clicks, for how long a message stays, and for how long the button that takes things back stays
every(50, function()
    s.tick = s.tick + 1
    if s.flash_msg and s.tick >= s.flash_until then s.flash_msg = nil; F.set_status() end
    if s.undo_until and s.tick > s.undo_until and fact["undo.on"] == true then fact["undo.on"] = false end
end)

-- ── the theme: asked of Vitreus when this starts (it says so itself when it changes), and again a few seconds in ──
local function ask_obs()
    run("pleamar", { "--say", "vitreus", "get glass_obs" }, function(out, code)
        if code == 0 and out then fact.obs = out:match("true") ~= nil end
    end)
end
local function ask_look()
    run("pleamar", { "--say", "vitreus", "get cas" }, function(cas, code)
        if code ~= 0 or not cas then return end
        run("pleamar", { "--say", "vitreus", "get uwu" }, function(uwu, code2)
            if code2 ~= 0 or not uwu then return end
            run("pleamar", { "--say", "vitreus", "get cyber_on" }, function(cy, code3)
                if code3 ~= 0 or not cy then return end
                fact.look = cas:match("true") and 1 or (uwu:match("true") and 2 or (cy:match("true") and 3 or 0))
            end)
        end)
    end)
end
local GLASS_FACTS = { gop = "glass_op", gbend = "files_bend", grefr = "glass_refr", gdisp = "glass_disp", gclear = "glass_clear", gdome = "glass_dome", gmilk = "glass_milk", grim = "glass_rim" }
local function ask_glass()
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
ask_obs()
ask_look()
ask_glass()
after(4000, function() ask_obs(); ask_look(); ask_glass() end)

F.start()
