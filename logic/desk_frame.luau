-- Home's slideshow (pages/desk_home.plm), at the top of Home: the pictures of one folder, shuffled, one after another
-- every twelve seconds while the Desk shows Home, cross-fading (the scene has two slots, `pf_a` and `pf_b`, and `pf_which` says which is on top).
-- Each picture is cut once to the frame's shape into the cache (shelf/ beside the Shelf's, by a hash of its path), so a big photo is not
-- read again at every turn. The folder is one of three (Customize's row, `pf_folder`): 0 the Camera's photos (Pictures/myPad), 1 Pictures,
-- 2 Pictures/Wallpapers; kept in desk-frame.json. A press opens the picture shown; `pf_next` goes on to the next at once.
return function(with_dirs)
    local NAMES = { [0] = "myPad photos", "Pictures", "Wallpapers" }
    local cfg = { folder = 0 }
    do
        local ok, s = pcall(sys.ask, "files.read", "desk-frame.json", "json")
        if ok and type(s) == "table" and NAMES[tonumber(s.folder) or -1] then cfg.folder = tonumber(s.folder) end
    end
    text.pf_folder_name = NAMES[cfg.folder]
    local list, at, listed, cur = {}, 0, 0, ""
    local busy = false
    local function hash(str)
        local h = 5381
        for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
        return string.format("%08x", h)
    end
    local function showing() return fact.desk_open == true and tonumber(fact.desk_tab) == 6 end
    local function folder(done)
        run("xdg-user-dir", { "PICTURES" }, function(out)
            local pics = ((out or ""):gsub("%s+$", ""))
            if pics == "" then done(nil); return end
            local d = ({ [0] = pics .. "/myPad", pics, pics .. "/Wallpapers" })[cfg.folder]
            -- where it is, as a person would write it (for "Add pictures to …" while it is empty)
            run("printenv", { "HOME" }, function(h)
                h = ((h or ""):gsub("%s+$", ""))
                text.pf_folder_path = (h ~= "" and d:sub(1, #h) == h) and ("~" .. d:sub(#h + 1)) or d
            end)
            done(d)
        end)
    end
    -- the next picture: cut to the frame (900 by 260) into the cache unless it is there, then put in the slot underneath and faded up
    local function show_next()
        if busy or #list == 0 then return end
        busy = true
        at = at % #list + 1
        local src = list[at]
        with_dirs(function(d)
            local dir = (d.cache:gsub("/wp$", "")) .. "/shelf"
            local out = dir .. "/frame-" .. hash(src) .. ".jpg"
            local function put()
                busy = false
                cur = src
                local top = fact.pf_which == true
                if top then text.pf_a = out else text.pf_b = out end
                fact.pf_which = not top
                text.pf_name = src:match("([^/]+)$") or src
                fact.pf_has = true
            end
            run("test", { "-s", out }, function(_, c)
                if c == 0 then put(); return end
                run("mkdir", { "-p", dir }, function()
                    run("magick", { "-limit", "thread", "1", src .. "[0]", "-auto-orient", "-resize", "900x260^", "-gravity", "center", "-extent", "900x260", "-quality", "86", out },
                        function(_, mc) if mc == 0 then put() else busy = false; table.remove(list, at); at = at - 1 end end)
                end)
            end)
        end)
    end
    -- the folder's pictures, shuffled; read again at most once a minute (or at once when the folder changes)
    local function load(force)
        if not force and os.time() - listed < 60 then return end
        listed = os.time()
        folder(function(dir)
            if not dir then list = {}; fact.pf_has = false; return end
            run("find", { dir, "-maxdepth", "1", "-type", "f", "(", "-iname", "*.jpg", "-o", "-iname", "*.jpeg", "-o", "-iname", "*.png", "-o", "-iname", "*.webp", ")" }, function(out)
                local got = {}
                for line in (out or ""):gmatch("[^\n]+") do got[#got + 1] = line end
                for i = #got, 2, -1 do local j = math.random(1, i); got[i], got[j] = got[j], got[i] end
                list, at = got, 0
                if #list == 0 then fact.pf_has = false else show_next() end
            end)
        end)
    end
    every(12000, function() if showing() then show_next() end end)
    on("desk_shown", function() if showing() then load(false) end end)
    on("pf_next", show_next)
    on("pf_open", function()
        if cur ~= "" and exec_on_desktop then exec_on_desktop("xdg-open '" .. cur:gsub("'", "'\\''") .. "'") end
    end)
    on("pf_folder", function()
        cfg.folder = (cfg.folder + 1) % 3
        text.pf_folder_name = NAMES[cfg.folder]
        pcall(sys.call, "files.write", "desk-frame.json", cfg)
        fact.pf_has = false
        load(true)
    end)
    load(true)
end
