-- The Desk's Clip tab: the clipboard history (cliphist), with pins. A pin keeps the text itself, in desk-clip-pins.json, so it outlives the history; pinned
-- entries are listed first. Clicking a row copies it again; a row can be pinned, asked about (it goes to the Ask tab as an attachment) or deleted.
-- Images stay in the history and copy back through vitreus-clipimg; they cannot be asked about. A pinned picture is saved as a file (and a thumbnail of it)
-- in clip-pins, in the data folder, so it outlives the history as a text pin does. A row for one shows a small thumbnail (made once,
-- in the cache, one at a time) and what cliphist knows of it: its format, size in pixels and weight. cliphist keeps no file name for a picture.
-- Clear wipes the history (every pin stays, pictures too), after a second press.
return function(with_dirs)
    local MAX_RECENT = 40                         -- entries read from cliphist
    local MAX_PINS = 12
    local pins = {}                               -- { text } or { image = true, file, thumb, label, sub, mime, key }, newest first
    local pdir = nil                              -- where pinned pictures are kept
    local recent = {}                             -- { id, label, sub, key, image } from cliphist, newest first
    local thumbs = {}                             -- key -> the thumbnail's path, once made (the key is the id and the picture's size, ids start again after a wipe)
    local queue, making = {}, false
    local tdir = nil
    local shown = {}                              -- what the list shows: { label, pinned, image, id, text (a pin's) }
    local flat                                    -- (below)

    function flat(s)
        s = s:gsub("[\r\n\t]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #s > 160 then s = s:sub(1, 160) end
        return s
    end

    local function save() pcall(sys.call, "files.write", "desk-clip-pins.json", { items = pins }) end

    local function render()
        shown = {}
        local pinned_key = {}
        for _, p in ipairs(pins) do
            if p.image then
                pinned_key["img:" .. (p.key or "")] = true
                shown[#shown + 1] = { label = p.label, sub = p.sub, pinned = true, image = true, hasthumb = p.thumb ~= nil, thumb = p.thumb or "", file = p.file, mime = p.mime }
            else
                pinned_key[flat(p.text):sub(1, 100)] = true
                shown[#shown + 1] = { label = flat(p.text), sub = "", pinned = true, image = false, hasthumb = false, thumb = "", text = p.text }
            end
        end
        for _, c in ipairs(recent) do
            if (c.image and not pinned_key["img:" .. c.key]) or (not c.image and not pinned_key[c.label:sub(1, 100)]) then
                local t = c.image and thumbs[c.key] or nil
                shown[#shown + 1] = { label = c.label, sub = c.sub, pinned = false, image = c.image, hasthumb = t ~= nil, thumb = t or "", id = c.id, key = c.key, mime = c.mime }
            end
        end
        model.clip_rows = shown
        fact.clip_n = #shown
    end

    local refresh
    local function make_next()
        if making or #queue == 0 or not tdir then return end
        making = true
        local c = table.remove(queue, 1)
        local out = tdir .. "/" .. c.key .. ".png"
        run("vitreus-clipimg", { "thumb", c.id, out, "96x64" }, function(_, code)
            making = false
            if code == 0 then thumbs[c.key] = out; render() end
            make_next()
        end)
    end

    function refresh()
        run("cliphist", { "list" }, function(out)
            recent = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local id, txt = line:match("^(%d+)\t(.*)$")
                if id then
                    local image = txt:find("^%[%[ binary data") ~= nil
                    local label, sub, key = flat(txt), "", id
                    if image then
                        local size, fmt, w, h = txt:match("binary data ([%d%.]+ %a+) (%a+) (%d+)x(%d+)")
                        label = fmt and string.format("%s image", fmt:upper()) or "Image"
                        sub = w and string.format("%s × %s  ·  %s", w, h, size) or ""
                        key = id .. "-" .. (size or "") .. "-" .. (w or "") .. "x" .. (h or "")
                        key = key:gsub("[^%w%-x]", "")
                    end
                    recent[#recent + 1] = { id = id, label = label, sub = sub, key = key, image = image, mime = image and ("image/" .. ((txt:match("binary data [%d%.]+ %a+ (%a+)") or "png"):lower():gsub("^jpg$", "jpeg"))) or nil }
                    if #recent >= MAX_RECENT then break end
                end
            end
            render()
            for _, c in ipairs(recent) do
                if c.image and not thumbs[c.key] and not c.queued then c.queued = true; queue[#queue + 1] = c end
            end
            make_next()
        end)
    end

    -- The whole text of a history entry (the list only carries a line of it), as `cliphist decode` prints it for an id on its input.
    local function decode(id, done)
        local lines = {}
        spawn("cliphist", { "decode" }, function(line) lines[#lines + 1] = line end, function()
            done(table.concat(lines, "\n"))
        end, { input = id .. "\t" })
    end

    local flash = 0
    local function msg(t)
        text.clip_msg = t
        fact.clip_flash = true
        flash = flash + 1
        local mine = flash
        after(1600, function() if mine == flash then fact.clip_flash = false end end)
    end

    local function with_text(r, fn)
        if r.text then return fn(r.text) end
        if r.id and not r.image then decode(r.id, fn) end
    end

    -- A pinned picture's files go with it.
    local function drop_files(p)
        if p and p.image then
            if p.file then run("find", { p.file, "-delete" }, function() end) end
            if p.thumb then run("find", { p.thumb, "-delete" }, function() end) end
        end
    end
    -- Unpinning puts the item back in the history (`cliphist store`: it is the newest there), so that it does not vanish when the history had been
    -- cleared and the pin was the only copy. Deleting a pinned row (its cross) does not: it goes for good.
    local function unpin(r, restore)
        for k, p in ipairs(pins) do
            if (r.image and p.file == r.file) or (not r.image and not p.image and p.text == r.text) then
                local gone = table.remove(pins, k)
                if restore and gone.image then
                    run("cliphist", { "store" }, function() drop_files(gone); refresh() end, { stdin = gone.file })
                else
                    if restore then spawn("cliphist", { "store" }, function() end, function() refresh() end, { input = gone.text }) end
                    drop_files(gone)
                end
                break
            end
        end
        save()
        render()
    end
    local function add_pin(p)
        table.insert(pins, 1, p)
        while #pins > MAX_PINS do drop_files(table.remove(pins)) end
        save()
        render()
    end

    on("clip_copy", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r then return end
        if r.image then
            if r.file then
                run("vitreus-clipimg", { "copyfile", r.file, r.mime or "image/png" }, function() msg("Copied") end)
            else
                run("vitreus-clipimg", { "copy", r.id, r.mime or "image/png" }, function() msg("Copied") end)
            end
        else
            with_text(r, function(t) run("wl-copy", { "--", t }, function() msg("Copied") end) end)
        end
    end)
    on("clip_pin", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r then return end
        if r.pinned then return unpin(r, true) end
        if r.image then
            -- the picture is written to a file of its own, with a thumbnail, so that it outlives the history
            if not pdir then return end
            local ext = ((r.mime or "image/png"):match("/(%w+)") or "png"):gsub("^jpeg$", "jpg")
            local name = os.time() .. "-" .. r.id
            local file, thumb = pdir .. "/" .. name .. "." .. ext, pdir .. "/" .. name .. ".thumb.png"
            run("vitreus-clipimg", { "save", r.id, file }, function(_, code)
                if code ~= 0 then return msg("Could not pin it") end
                run("vitreus-clipimg", { "thumbfile", file, thumb, "96x64" }, function(_, c2)
                    add_pin({ image = true, file = file, thumb = c2 == 0 and thumb or nil, label = r.label, sub = r.sub, mime = r.mime, key = r.key })
                end)
            end)
            return
        end
        decode(r.id, function(t)
            if t == "" then return end
            for k, p in ipairs(pins) do if not p.image and p.text == t then table.remove(pins, k) break end end
            add_pin({ text = t })
        end)
    end)
    on("clip_del", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r then return end
        if r.pinned then
            unpin(r, false)
        else
            spawn("cliphist", { "delete" }, function() end, function() refresh() end, { input = r.id .. "\t" })
        end
    end)
    on("clip_ask", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r or r.image then return end
        with_text(r, function(t) ask_attach_from("Clipboard history", t) end)
    end)
    local confirm = 0
    on("clip_clear", function()
        if not fact.clip_confirm then
            fact.clip_confirm = true
            confirm = confirm + 1
            local mine = confirm
            after(3500, function() if mine == confirm then fact.clip_confirm = false end end)
            return
        end
        confirm = confirm + 1
        fact.clip_confirm = false
        queue, thumbs = {}, {}
        run("cliphist", { "wipe" }, function()
            if tdir then run("find", { tdir, "-type", "f", "-name", "*.png", "-delete" }, function() end) end
            recent = {}
            render()
            msg("Cleared  ·  pins kept")
        end)
    end)
    on("clip_refresh", refresh)
    on("fact:desk_tab", function(v) if tonumber(v) == 2 and fact.desk_open then refresh() end end)
    on("fact:desk_open", function(v) if (v == true or tostring(v) == "true") and tonumber(fact.desk_tab) == 2 then refresh() end end)
    every(3000, function() if fact.desk_open and tonumber(fact.desk_tab) == 2 then refresh() end end)

    do
        local ok, saved = pcall(sys.ask, "files.read", "desk-clip-pins.json", "json")
        if ok and type(saved) == "table" and type(saved.items) == "table" then
            for _, p in ipairs(saved.items) do
                if type(p) == "table" and #pins < MAX_PINS then
                    if p.image == true and type(p.file) == "string" then
                        pins[#pins + 1] = { image = true, file = p.file, thumb = type(p.thumb) == "string" and p.thumb or nil,
                                            label = tostring(p.label or "Image"), sub = tostring(p.sub or ""), mime = type(p.mime) == "string" and p.mime or "image/png",
                                            key = type(p.key) == "string" and p.key or nil }
                    elseif type(p.text) == "string" and p.text ~= "" then
                        pins[#pins + 1] = { text = p.text }
                    end
                end
            end
        end
    end
    render()
    with_dirs(function(d)
        pdir = d.data .. "/clip-pins"
        run("mkdir", { "-p", pdir }, function() end)
        tdir = d.cache .. "/clip"
        -- pictures that went out of the history a week ago leave the cache
        run("mkdir", { "-p", tdir }, function()
            run("find", { tdir, "-type", "f", "-mtime", "+7", "-delete" }, function() end)
        end)
    end)
end
