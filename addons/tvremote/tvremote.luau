-- The logic of the TV Remote: it runs tvremote.py (JSON lines in and out), keeps the saved TVs and which one is in use in the add-on's data folder, tells the scene what stage it is at and
-- sends the presses. The panel's field is typed through the shell (see the template's addon.luau): it holds the address, then the pairing code, then text for the TV.
local U = 1.1
local ok_f, folder = pcall(sys.ask, "files.folder")
if not ok_f then folder = "" end

-- The saved TVs: { tvs = { { host, name, kind, mac }, ... }, cur = which one is in use }. `kind` is "atv" (a Google TV / Android TV) or "webos" (an LG),
-- `mac` an LG's, for Wake-on-LAN. The first version kept one `host`: it becomes the first TV; TVs saved before kinds are Google TVs.
local MAXTV = 5
local cfg = { tvs = {}, cur = 1 }
do
    local ok, saved = pcall(sys.ask, "files.read", "config.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.tvs) == "table" then
            for _, tv in ipairs(saved.tvs) do
                if type(tv) == "table" and type(tv.host) == "string" and tv.host ~= "" then
                    cfg.tvs[#cfg.tvs + 1] = { host = tv.host, name = type(tv.name) == "string" and tv.name or "", kind = tv.kind == "webos" and "webos" or "atv",
                        mac = type(tv.mac) == "string" and tv.mac or "" }
                end
            end
            cfg.cur = math.max(1, math.min(#cfg.tvs, math.floor(tonumber(saved.cur) or 1)))
        elseif type(saved.host) == "string" and saved.host ~= "" then
            cfg.tvs[1] = { host = saved.host, name = "", kind = "atv", mac = "" }
        end
    end
end
local function save_cfg() pcall(sys.call, "files.write", "config.json", cfg) end
local function cur_tv() return cfg.tvs[cfg.cur] end
local function cur_host() local tv = cur_tv() return tv and tv.host or "" end
local function cur_kind() local tv = cur_tv() return tv and tv.kind or "atv" end
local function cur_mac() local tv = cur_tv() return tv and tv.mac or "" end
local function lg() return cur_kind() == "webos" end
local function tv_label(tv) return tv.name ~= "" and tv.name or tv.host end
local function saved_host(h) for i, tv in ipairs(cfg.tvs) do if tv.host == h then return i end end return nil end

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end
local function say_shell(cmds)
    local args = { "--say", "vitreus" }
    for _, c in ipairs(cmds) do args[#args + 1] = c end
    run("pleamar", args, function() end)
end

-- ── the helper ──
local helper = nil
local stopping = false
local function send(t)
    if helper then write(helper, json.encode(t) .. "\n") end
end

-- ── the field ──
local st = 0
local was_open = false
-- Where the field is, from the content's top left, in the pixels the scene draws it at: the design box (260 x 406 units) is scaled to the panel and centred, as in tvremote.plm.
local function field_box()
    local w, h = tonumber(fact.slot_w) or 0, tonumber(fact.slot_h) or 0
    local W0, H0 = 260 * U, 406 * U
    local sc = math.max(0.5, math.min(2.5, math.min(w / W0, h / H0)))
    if w <= 0 or h <= 0 then sc = 1 end
    local l = (w - sc * W0) / 2 + 22 * U * sc
    local t = 61 * U * sc
    return { "fact axf_l " .. math.floor(l), "fact axf_t " .. math.floor(t), "fact axf_r " .. math.floor(l), "fact axf_h " .. math.floor(34 * U * sc) }
end
local function place_field()
    local cmds = field_box()
    cmds[#cmds + 1] = "text axf_q "
    cmds[#cmds + 1] = "fact axf_on true"
    cmds[#cmds + 1] = "emit axf_set"
    say_shell(cmds)
end
local resize_due = false
local function on_resize()                  -- the panel is being resized: the field's box follows (what is written in it stays)
    if resize_due or not was_open or fact.fld_on ~= true then return end
    resize_due = true
    after(120, function()
        resize_due = false
        if was_open and fact.fld_on == true then say_shell(field_box()) end
    end)
end
on("fact:slot_w", on_resize)
on("fact:slot_h", on_resize)
local function clear_field()
    text.field_q = ""
    say_shell({ "text axf_q ", "emit axf_set" })
end
local PH = { [1] = "Type into the TV, then Enter", [2] = "TV address, like 192.168.x.x", [4] = "The 6-character code on the TV" }
local found = {}
local fail_kind = "conn"       -- what the "unreachable" screen is about: "conn" (the TV does not answer) or "pair" (the pairing failed)
local function show_found()
    fact.found_cnt = st == 2 and math.min(#found, 3) or 0
    for k = 0, 2 do text["found_" .. k] = found[k + 1] and ((found[k + 1].name ~= "" and found[k + 1].name or "TV") .. "  ·  " .. found[k + 1].host) or "" end
end
local function refresh_menu()       -- the switcher's rows (the saved TVs, then "Add a TV") and the name in the header
    local n = #cfg.tvs
    fact.tv_cnt = n
    fact.tv_cur = cfg.cur - 1
    for k = 0, 5 do
        local tv = cfg.tvs[k + 1]
        text["menu_" .. k] = tv and tv_label(tv) or ((k == n and n < MAXTV) and "Add a TV…" or "")
    end
    fact.menu_cnt = n < MAXTV and n + 1 or n
    local cur = cur_tv()
    text.tv_name = cur and tv_label(cur) or "TV"
    fact.tv_kind = lg() and 1 or 0
end
local function set_stage(n, t, s, b)
    local changed = n ~= st
    st = n
    fact.st = n
    local want = (n == 1 or n == 2 or n == 4)
    fact.fld_on = want
    text.field_ph = PH[n] or ""
    text.setup_t = t or ""
    text.setup_s = s or ""
    text.setup_b = b or ""
    if n ~= 1 then text.sub = n == 5 and "Offline" or "" end          -- (what the TV said last time is not true any more)
    fact.setup_btn = (b and b ~= "") and 1 or 0
    if changed and was_open then
        if want then place_field() else say_shell({ "fact axf_on false" }) end
    end
    if changed then text.field_q = "" end
    show_found()
    if n == 2 and changed then send({ cmd = "scan" }) end
end
-- The shell forgets the field when the panel shuts: told again as it comes out.
on("fact:slot_open", function(v)
    local now = v == true
    if now == was_open then return end
    was_open = now
    if now then
        if fact.fld_on == true then place_field() end
    end
end)

-- ── what the TV says ──
local APPS = {
    ["com.google.android.youtube.tv"] = "YouTube", ["com.netflix.ninja"] = "Netflix", ["com.amazon.amazonvideo.livingroom"] = "Prime Video",
    ["com.disney.disneyplus"] = "Disney+", ["com.spotify.tv.android"] = "Spotify", ["com.google.android.tvlauncher"] = "Home",
    ["com.google.android.apps.tv.launcherx"] = "Home", ["com.google.android.tv.settings"] = "Settings", ["com.android.vending"] = "Play Store",
    ["com.plexapp.android"] = "Plex", ["org.videolan.vlc"] = "VLC", ["com.google.android.youtube.tvmusic"] = "YouTube Music",
    ["youtube.leanback.v4"] = "YouTube", ["netflix"] = "Netflix", ["amazon"] = "Prime Video", ["com.webos.app.livetv"] = "Live TV",
    ["com.webos.app.home"] = "Home", ["com.webos.app.homeconnect"] = "Home Dashboard",
}
local function app_label(pkg)
    if pkg == nil or pkg == "" then return "" end
    local hdmi = pkg:match("^com%.webos%.app%.hdmi(%d)$")         -- an LG on one of its inputs
    if hdmi then return "HDMI " .. hdmi end
    return APPS[pkg] or (pkg:match("([^%.]+)$") or pkg)
end
local function show_ready(ev)
    set_stage(1)
    fact.tv_on = ev.on == true
    local model = ev.model or ""
    local cur = cur_tv()
    if cur and cur.name == "" and model ~= "" then cur.name = model save_cfg() refresh_menu() end
    local bits = {}
    if ev.on == true then
        local a = app_label(ev.app)
        bits[#bits + 1] = a ~= "" and a or "On"
    else
        bits[#bits + 1] = "Standby"
    end
    if type(ev.vol) == "number" and ev.vol >= 0 then
        local mx = (type(ev.max) == "number" and ev.max > 0) and ev.max or 100
        local pct = math.floor(ev.vol * 100 / mx + 0.5)
        fact.vol_pct = pct
        bits[#bits + 1] = ev.muted and "muted" or ("vol " .. pct)
    end
    fact.muted = ev.muted == true
    text.sub = table.concat(bits, " · ")
end
-- An LG's inputs or apps, as a list over the remote: eight rows a page, and a ninth that turns the page when there are more.
local sheet = { kind = "inputs", list = {}, page = 0 }
local PER = 8
local function show_sheet()
    local n = #sheet.list
    local pages = math.max(1, math.ceil(n / PER))
    sheet.page = sheet.page % pages
    local first = sheet.page * PER
    local title = sheet.kind == "inputs" and "Inputs" or "Apps"
    text.sheet_t = pages > 1 and (title .. "  ·  " .. (sheet.page + 1) .. " of " .. pages) or title
    local rows, cur = 0, -1
    for k = 0, PER - 1 do
        local it = sheet.list[first + k + 1]
        text["sheet_" .. k] = it and (it.label or it.id or "") or ""
        if it then
            rows = k + 1
            if it.on then cur = k end
        end
    end
    text.sheet_8 = pages > 1 and "More…" or ""
    fact.sheet_cnt = pages > 1 and PER + 1 or rows
    fact.sheet_cur = cur
    fact.sheet_open = true
    fact.menu_open = false
end

local function on_line(line)
    local ok, ev = pcall(json.decode, line)
    if not ok or type(ev) ~= "table" then return end
    if ev.ev == "hello" then
        if cur_host() ~= "" then send({ cmd = "connect", host = cur_host(), kind = cur_kind(), mac = cur_mac() }) else send({ cmd = "scan" }) end
    elseif ev.ev == "found" then
        found = {}
        for _, tv in ipairs(type(ev.tvs) == "table" and ev.tvs or {}) do
            if not saved_host(tv.host) then found[#found + 1] = tv end      -- the ones already saved are in the switcher
        end
        if st == 2 then
            show_found()
            text.setup_s = #found > 0 and "Pick yours, or type its address in the field." or "None found. Type its address in the field (the TV's Settings > Network shows it)."
        end
    elseif ev.ev == "state" then
        local s = ev.stage
        if s == "ready" then show_ready(ev)
        elseif s == "connecting" then
            if st ~= 1 and st ~= 5 then set_stage(0, "Connecting…", cur_host()) end      -- (an unreachable TV is retried quietly: the screen stays as it is until it answers)
        elseif s == "needs_pairing" then
            if lg() then
                set_stage(3, "Pair with your TV", "Your TV will ask whether to allow Vitreus: answer with its own remote.", "Pair with TV")
            else
                set_stage(3, "Pair with your TV", "A six-character code will appear on the TV. Type it here.", "Pair with TV")
            end
        elseif s == "pair_wait_accept" then                     -- an LG: the question is on its screen
            set_stage(0, "Accept on your TV", "Use the TV's own remote to allow Vitreus. The question is on its screen now.")
        elseif s == "pair_wait_code" then
            set_stage(4, "Type the code", ev.msg and (ev.msg .. ". Look at the TV again.") or "It is on the TV's screen, six letters and numbers.")
        elseif s == "pairing_failed" then
            fail_kind = "pair"
            set_stage(5, "Pairing did not work", (ev.msg or "") .. "\nIs the TV on, at " .. cur_host() .. "?", "Pair again")
        elseif s == "paired" then
            set_stage(0, "Paired", "Connecting…")
        elseif s == "error" then
            fail_kind = "conn"
            set_stage(5, "Can't reach the TV", "It may be off. This tries again by itself, and you can switch TVs from the name above.", lg() and "Wake TV" or "Try now")
        end
    elseif ev.ev == "kind" then                                -- a typed address turned out to be an LG: pair it as one
        local i = saved_host(ev.host)
        if i and ev.kind == "webos" then
            cfg.tvs[i].kind = "webos"
            save_cfg()
            refresh_menu()
            set_stage(0, "Asking the TV…", "A question is about to appear on its screen.")
            send({ cmd = "pair", host = ev.host, kind = "webos", mac = cfg.tvs[i].mac })
        end
    elseif ev.ev == "inputs" or ev.ev == "apps" then
        sheet.kind = ev.ev
        sheet.list = type(ev.list) == "table" and ev.list or {}
        sheet.page = 0
        show_sheet()
    elseif ev.ev == "log" then
        log("tvremote", ev.msg)
    end
end
local function start_helper()
    if helper then return end
    helper = spawn("vitreus-tvremote", { folder }, on_line, function(_, code)
        helper = nil
        log("tvremote helper ended", code)
        if not stopping then after(3000, start_helper) end
    end, { stdin = "open", errors = true })
end

-- ── presses ──
local KEY = { [1] = "UP", [2] = "DOWN", [3] = "LEFT", [4] = "RIGHT", [5] = "OK", [10] = "BACK", [11] = "HOME", [12] = "SETTINGS", [13] = "VOL_DOWN", [14] = "MUTE",
    [15] = "VOL_UP", [16] = "PLAY_PAUSE", [30] = "POWER" }
local LINK = { [17] = "https://www.youtube.com", [18] = "https://www.netflix.com/title", [19] = "https://app.primevideo.com", [20] = "https://www.disneyplus.com" }
local function add_stage()
    fact.menu_open = false
    fact.sheet_open = false
    set_stage(2, "Add a TV", "Looking for TVs on your network…", #cfg.tvs > 0 and "Cancel" or "")
    send({ cmd = "scan" })
end
local function use(i)                      -- connect to the i-th saved TV
    cfg.cur = i
    save_cfg()
    fact.menu_open = false
    fact.sheet_open = false
    refresh_menu()
    set_stage(0, "Connecting…", cur_host())
    send({ cmd = "connect", host = cur_host(), kind = cur_kind(), mac = cur_mac() })
end
local function add_tv(host, name, kind, mac)
    local i = saved_host(host)
    if not i then
        if #cfg.tvs >= MAXTV then return end
        cfg.tvs[#cfg.tvs + 1] = { host = host, name = name or "", kind = kind == "webos" and "webos" or "atv", mac = mac or "" }
        i = #cfg.tvs
    end
    use(i)
end
on("tv_act", function(id)
    id = math.floor((tonumber(id) or 0) + 0.5)
    if id == 40 then
        if st == 2 then if #cfg.tvs > 0 then use(cfg.cur) end return end          -- Cancel
        if st == 5 and fail_kind == "conn" then
            set_stage(0, "Connecting…", cur_host())
            if lg() then send({ cmd = "wake", host = cur_host(), mac = cur_mac() }) end      -- an LG in standby: Wake-on-LAN first
            send({ cmd = "reconnect", host = cur_host(), kind = cur_kind(), mac = cur_mac() })
            return
        end
        if lg() then
            set_stage(0, "Asking the TV…", "A question is about to appear on its screen.")
        else
            set_stage(0, "Asking the TV…", "A code is about to appear on its screen.")
        end
        send({ cmd = "pair", host = cur_host(), kind = cur_kind(), mac = cur_mac() })
    elseif lg() and (id == 17 or id == 18) then       -- an LG's Inputs and Apps: the list comes back as an event
        send({ cmd = id == 17 and "inputs" or "apps" })
    elseif lg() and (id == 19 or id == 20) then
        send({ cmd = "launch", id = id == 19 and "youtube.leanback.v4" or "netflix" })
    elseif KEY[id] then
        send({ cmd = "key", key = KEY[id] })
    elseif LINK[id] then
        send({ cmd = "app", link = LINK[id] })
    end
end)
on("tv_sheet", function(k)                 -- a row of an LG's list
    k = math.floor((tonumber(k) or 0) + 0.5)
    if k == PER then sheet.page = sheet.page + 1 show_sheet() return end
    local it = sheet.list[sheet.page * PER + k + 1]
    if not it then return end
    if sheet.kind == "inputs" then send({ cmd = "input", id = it.id }) else send({ cmd = "launch", id = it.id }) end
    fact.sheet_open = false
end)
on("tv_menu", function(k)                  -- a row of the switcher
    k = math.floor((tonumber(k) or 0) + 0.5) + 1
    if k <= #cfg.tvs then
        if k == cfg.cur and st == 1 then fact.menu_open = false else use(k) end
    else
        add_stage()
    end
end)
on("tv_forget", function(k)
    k = math.floor((tonumber(k) or 0) + 0.5) + 1
    local tv = cfg.tvs[k]
    if not tv then return end
    send({ cmd = "unpair", host = tv.host, kind = tv.kind })
    table.remove(cfg.tvs, k)
    if #cfg.tvs == 0 then
        cfg.cur = 1
        save_cfg()
        refresh_menu()
        add_stage()
        return
    end
    local was_cur = k == cfg.cur
    if k < cfg.cur then cfg.cur = cfg.cur - 1 end
    cfg.cur = math.max(1, math.min(#cfg.tvs, cfg.cur))
    save_cfg()
    refresh_menu()
    if was_cur then use(cfg.cur) end
end)
on("tv_pick", function(k)
    local tv = found[math.floor((tonumber(k) or 0) + 0.5) + 1]
    if not tv or st ~= 2 then return end
    add_tv(tv.host, tv.name, tv.kind, tv.mac)
end)
on("field_enter", function()
    local q = trim(text.field_q)
    if q == "" then return end
    if st == 2 then
        add_tv(q, "", "atv", "")                      -- (an LG is recognised when it is paired: the helper says `kind`)
    elseif st == 4 then
        send({ cmd = "code", code = q })
    elseif st == 1 then
        send({ cmd = "text", text = q })
        clear_field()
    end
end)

-- ── start ──
refresh_menu()
if cur_host() == "" then
    set_stage(2, "Add a TV", "Looking for TVs on your network…")
else
    set_stage(0, "Connecting…", cur_host())
end
start_helper()

-- Which copy of this scene is on the panel's monitor: the one whose `screen.K.name` is the name the shell sent (`slot_mon`), as in the template. Without it the
-- size decided, and on monitors of the same size every copy drew the panel: a ghost of it on the other monitors.
local function find_monitor()
    local name = text.slot_mon or ""
    local any = false
    for k = 0, 3 do
        local here = name ~= "" and text["screen." .. k .. ".name"] == name
        if fact["mon_c" .. k] ~= here then fact["mon_c" .. k] = here end
        any = any or here
    end
    if fact.mon_known ~= any then fact.mon_known = any end
end
on("fact:slot_open", function() find_monitor() end)      -- (the shell says it again every two seconds while the panel is out, and `slot_mon` before it)
on("text:slot_mon", function() find_monitor() end)
