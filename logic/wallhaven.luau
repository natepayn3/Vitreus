-- Wallhaven in the wallpaper gallery (Settings > Wallpaper): the pill beside the gallery's title switches its source from the folder to wallhaven.cc. With Wallhaven on, the grid
-- shows sixteen results of the search (thumbnails fetched into the cache), the arrows page through them sixteen at a time, and a pick downloads the full picture into the wallpaper
-- folder and sets it. bin/vitreus-wallhaven does the network (`--list` for a window of the results, `--one` for a picture). Which purities to ask for (SFW, sketchy, NSFW) and the API key
-- are kept in wallhaven.json in the data folder (mode 600); the key reaches the script by that file's path, never on a command line. NSFW needs a key (Wallhaven's rule).
-- vitreus.luau's gallery handlers ask `wh_hook` first: while this is on, the pager, the arrows and the picks are this file's.
return function(with_dirs, reload, apply, refresh_local)
    local W = { sfw = true, sketchy = false, nsfw = false, key = "" }
    local DIR, CACHE, FOLDER
    local live, page, pages, results, token, busy = false, 0, 1, {}, 0, false
    local SORTS = { { "toplist", "Top" }, { "date_added", "New" }, { "views", "Views" }, { "favorites", "Faves" }, { "random", "Random" }, { "relevance", "Match" } }
    local sort = 1
    local function say(s) text.wh_status = s end

    local function purity() return (W.sfw and "1" or "0") .. (W.sketchy and "1" or "0") .. (W.nsfw and "1" or "0") end
    local function show_page()
        local rows = {}
        for i, r in ipairs(results) do rows[i] = { thumb = r.thumb } end
        model.wps = rows
        fact.wp_sel = -1
        text.wp_pager = string.format("%d / %d", page + 1, pages)
    end
    local function show_keys()
        fact.wh_sfw, fact.wh_sk, fact.wh_nsfw = W.sfw, W.sketchy, W.nsfw
        fact.wh_key = W.key ~= ""
        text.wh_keyinfo = W.key ~= "" and "Key saved" or "No key"
        text.wh_sort_t = SORTS[sort][2]
        fact.wh_sort_i = sort - 1
    end
    local function save()
        pcall(sys.call, "files.write", "wallhaven.json", W)
        if DIR then run("chmod", { "600", DIR .. "/wallhaven.json" }, function() end) end
    end

    local function search(p)
        if not DIR or not CACHE then return end
        if W.nsfw and W.key == "" then results = {}; show_page(); say("NSFW needs an API key: set it below (wallhaven.cc > Account)"); return end
        local q = (text.wh_q or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local s = SORTS[sort][1]
        if s == "relevance" and q == "" then s = "toplist" end
        token = token + 1
        local mine = token
        busy = true
        model.wps = {}                    -- (the grid empties at once: the folder's pictures would hide the note, and look like nothing happened)
        fact.wp_sel = -1
        local dots = 0
        local function tick()             -- "Searching" with dots that come and go, while the search and the thumbnails are on their way
            if mine ~= token or not busy then return end
            say("Searching" .. string.rep(".", dots % 4))
            dots = dots + 1
            after(350, tick)
        end
        tick()
        run("vitreus-wallhaven", { "--list", "--offset", tostring(p * 16), "--count", "16", "--thumbs", CACHE, "--sort", s, "--range", "1y",
            "--purity", purity(), "--config", DIR .. "/wallhaven.json", "--", q }, function(out, code)
            if mine ~= token then return end
            busy = false
            if code ~= 0 then results = {}; page = 0; pages = 1; show_page(); say("Could not reach Wallhaven: check the network and the key"); return end
            local rows = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local id, thumb, res = line:match("^R\t([^\t]+)\t([^\t]+)\t?(.*)$")
                if id then rows[#rows + 1] = { id = id, thumb = thumb, res = res }
                else
                    local n = line:match("^META\t(%d+)")
                    if n then pages = math.min(tonumber(n), 40) end
                end
            end
            results, page = rows, p
            show_page()
            if #rows == 0 then say("Nothing found") end
        end)
    end

    local function leave_busy_note(msg)
        local keep = text.wp_pager
        text.wp_pager = msg
        after(2500, function() if live then text.wp_pager = string.format("%d / %d", page + 1, pages) end end)
    end

    on("wp_src_set", function(i)
        i = math.floor((tonumber(i) or 0) + 0.5)
        if i == 1 and not live then
            live = true
            fact.wp_src = 1
            if #results == 0 then search(0) else show_page() end
        elseif i == 0 and live then
            live = false
            token = token + 1
            fact.wp_src = 0
            refresh_local()
        end
    end)
    on("wh_search", function() if live then search(0) end end)
    on("wh_sort_set", function(i)
        i = math.floor((tonumber(i) or 0) + 0.5) + 1
        if not SORTS[i] or i == sort then return end
        sort = i
        show_keys()
        if live then search(0) end
    end)

    wh_hook.active = function() return live end
    wh_hook.next = function() if live and not busy then search((page + 1) % pages) end end
    wh_hook.prev = function() if live and not busy then search((page - 1) % pages) end end
    wh_hook.pick = function(i)
        local r = results[i + 1]
        if not r or not FOLDER or FOLDER == "" then return end
        text.wp_pager = "Downloading…"
        run("vitreus-wallhaven", { "--one", r.id, "--dir", FOLDER, "--config", DIR .. "/wallhaven.json" }, function(out, code)
            local path = (out or ""):match("[^\n]+")
            if code ~= 0 or not path then leave_busy_note("Download failed"); return end
            reload()
            apply(path)
            text.wp_pager = string.format("%d / %d", page + 1, pages)
        end)
    end

    on("wh_toggle", function(which)
        local k = ({ [0] = "sfw", [1] = "sketchy", [2] = "nsfw" })[math.floor((tonumber(which) or 0) + 0.5)]
        if not k then return end
        W[k] = not W[k]
        if not (W.sfw or W.sketchy or W.nsfw) then W.sfw = true end        -- (one of them stays on)
        say(W.nsfw and W.key == "" and "NSFW needs an API key" or "")
        show_keys(); save()
        if live then search(0) end
    end)

    on("wh_savekey", function()
        local k = (text.wh_key_in or ""):gsub("%s+", "")
        text.wh_key_in = ""
        if k == "" then W.key = ""; W.nsfw = false; say("Key removed")
        elseif k:match("^[%w]+$") and #k >= 16 and #k <= 64 then W.key = k; say("Key saved")
        else say("That does not look like an API key"); return end
        show_keys(); save()
    end)

    with_dirs(function(d)
        DIR = d.data
        CACHE = d.cache .. "/wallhaven"
        local ok, saved = pcall(sys.ask, "files.read", "wallhaven.json", "json")
        if ok and type(saved) == "table" then
            W.sfw, W.sketchy, W.nsfw = saved.sfw ~= false, saved.sketchy == true, saved.nsfw == true
            if type(saved.key) == "string" then W.key = saved.key end
        end
        show_keys()
        -- (the wallpaper folder: wpv.dir, set by the gallery once it has found it)
        every(2000, function() FOLDER = (text.wp_dirpath or "") end)
        FOLDER = text.wp_dirpath or ""
    end)
end
