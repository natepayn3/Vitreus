-- Workspaces only: what moves is moved by the renderer.
sys.watch("workspaces", function(w)
    local busy = {}
    for _, d in ipairs(w.list) do busy[d.id] = d.windows > 0 end
    for i = 1, 5 do fact["ws." .. i .. ".busy"] = busy[i] or false end
    fact["ws.active"] = w.active
end)
on("go", function(i) sys.call("workspaces.focus", i) end)

-- The clock, written the way it is read here: 12 hours with am/pm, and the long date.
local days = { [0] = "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local months = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }

sys.watch("clock", function(c)
    local h = c.hour % 12
    if h == 0 then h = 12 end
    text.clock12 = string.format("%d:%02d %s", h, c.minute, c.hour < 12 and "am" or "pm")
    text.datelong = string.format("%s, %s %d, %d", days[c.weekday], months[c.month], c.day, c.year)
end)

-- The player: whether there is one, and what the three buttons do.
-- cava listens to what is playing and prints one line per frame: six bars, 0..1000.
-- It only runs while something plays, and the bass is the mean of the low two.
local cava = nil
local last = 0

local function listen()
    if cava then return end
    cava = spawn("cava", { "-p", "/home/nick/.config/pleamar/shells/gota/cava.conf" }, function(line)
        local b = {}
        for v in string.gmatch(line, "(%d+);") do b[#b + 1] = tonumber(v) / 1000 end
        if #b < 2 then return end
        local bass = math.min(1, (b[1] + b[2]) / 2)
        -- only report when it moved enough to be seen: the renderer springs the rest
        if math.abs(bass - last) > 0.03 then
            last = bass
            fact.bass = bass
        end
    end, function() cava = nil end)
end

local function hush()
    if cava then kill(cava); cava = nil end
    last = 0
    fact.bass = 0
end

-- The cover. Every player publishes it the same way (MPRIS `mpris:artUrl`), and
-- `playerctl` reads it: a local file (browsers write theirs into /tmp, mpv and VLC
-- point at the folder) or a link (Spotify and most streaming apps). A file is used
-- where it is; a link is fetched once into /tmp and cached under a name made from it.
local art_url = ""

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local function unpercent(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function show_art(path)
    text.arturl = path
    fact.art_on = path ~= ""
end

local function use_art(url)
    if url == art_url then return end
    art_url = url
    if url == "" then show_art("") return end
    if url:sub(1, 7) == "file://" then
        show_art(unpercent(url:sub(8)))
    elseif url:match("^https?://") then
        local path = "/tmp/gota-art-" .. hash(url) .. ".img"
        run("curl", { "-fsSL", "--max-time", "8", "-o", path, url }, function(_, code)
            if code == 0 and art_url == url then show_art(path) end
        end)
    else
        show_art("")
    end
end

local function fetch_art(player)
    run("playerctl", { "-p", player, "metadata", "mpris:artUrl" }, function(out, code)
        local url = tostring(out or ""):gsub("%s+$", "")
        if code == 0 and url ~= "" then
            use_art(url)
        else
            -- the name the service gave may not be one playerctl knows: ask without it
            run("playerctl", { "metadata", "mpris:artUrl" }, function(out2, code2)
                use_art(code2 == 0 and (tostring(out2 or ""):gsub("%s+$", "")) or "")
            end)
        end
    end)
end

local song = ""

sys.watch("media", function(m)
    fact.media_on = m.player ~= ""
    if m.playing then listen() else hush() end
    if m.player == "" then
        song = ""
        use_art("")
        return
    end
    local now = m.player .. "|" .. tostring(m.title) .. "|" .. tostring(m.artist)
    if now ~= song then
        local first = song == ""
        song = now
        fetch_art(m.player)
        -- players often publish the cover a moment after the title
        after(900, function() fetch_art(m.player) end)
        if not first then emit("trackchange") end
    end
end)
on("mcmd", function(k)
    sys.call(k == 0 and "media.previous" or (k == 1 and "media.toggle" or "media.next"))
end)

-- The volume slider: the scene turns the pointer into 0..1, the mixer takes it.
on("setvol", function(v)
    sys.call("audio.volume", v)
end)

-- Where the sound can go. PipeWire's names come with the whole card model in
-- them, so they are only tidied (spaces); the scene truncates to fit its row.
-- The ids stay here: the scene only knows positions, and asks for one by number.
local out_ids = {}

sys.watch("audio", function(a)
    local rows, ids, current = {}, {}, ""
    for _, o in ipairs(a.outputs or {}) do
        local name = tostring(o.name):gsub("%s+", " ")
        rows[#rows + 1] = { name = name, current = o.default == true }
        ids[#ids + 1] = o.id
        if o.default == true then current = name end
    end
    out_ids = ids
    model.outlist = rows
    text.outname = current
end)

on("pick_out", function(i)
    local id = out_ids[i + 1]
    if id ~= nil then sys.call("audio.default", id) end
end)

-- The speaker icon: silence it, or bring the sound back.
on("mute", function()
    sys.call("audio.mute")
end)
