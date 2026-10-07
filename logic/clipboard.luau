-- The Desk's Clip tab: the clipboard history (cliphist), with pins. A pin keeps the text itself, in desk-clip-pins.json, so it outlives the history; pinned
-- entries are listed first. Clicking a row copies it again; a row can be pinned, asked about (it goes to the Ask tab as an attachment) or deleted.
-- Images stay in the history and copy back through vitreus-clipimg; they cannot be pinned or asked about.
return function()
    local MAX_RECENT = 40                         -- entries read from cliphist
    local MAX_PINS = 12
    local pins = {}                               -- { text }, newest first
    local recent = {}                             -- { id, label, image } from cliphist, newest first
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
            pinned_key[flat(p.text):sub(1, 100)] = true
            shown[#shown + 1] = { label = flat(p.text), pinned = true, image = false, text = p.text }
        end
        for _, c in ipairs(recent) do
            if c.image or not pinned_key[c.label:sub(1, 100)] then
                shown[#shown + 1] = { label = c.label, pinned = false, image = c.image, id = c.id }
            end
        end
        model.clip_rows = shown
        fact.clip_n = #shown
    end

    local function refresh()
        run("cliphist", { "list" }, function(out)
            recent = {}
            for line in (out or ""):gmatch("[^\n]+") do
                local id, txt = line:match("^(%d+)\t(.*)$")
                if id then
                    local image = txt:find("^%[%[ binary data") ~= nil
                    recent[#recent + 1] = { id = id, label = image and "Image" or flat(txt), image = image }
                    if #recent >= MAX_RECENT then break end
                end
            end
            render()
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

    on("clip_copy", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r then return end
        if r.image then
            run("vitreus-clipimg", { "copy", r.id }, function() msg("Copied") end)
        else
            with_text(r, function(t) run("wl-copy", { "--", t }, function() msg("Copied") end) end)
        end
    end)
    on("clip_pin", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r or r.image then return end
        if r.pinned then
            for k, p in ipairs(pins) do if p.text == r.text then table.remove(pins, k) break end end
            save()
            render()
        else
            decode(r.id, function(t)
                if t == "" then return end
                for k, p in ipairs(pins) do if p.text == t then table.remove(pins, k) break end end
                table.insert(pins, 1, { text = t })
                while #pins > MAX_PINS do table.remove(pins) end
                save()
                render()
            end)
        end
    end)
    on("clip_del", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r then return end
        if r.pinned then
            for k, p in ipairs(pins) do if p.text == r.text then table.remove(pins, k) break end end
            save()
            render()
        else
            spawn("cliphist", { "delete" }, function() end, function() refresh() end, { input = r.id .. "\t" })
        end
    end)
    on("clip_ask", function(i)
        local r = shown[(tonumber(i) or -1) + 1]
        if not r or r.image then return end
        with_text(r, function(t) ask_attach_from("Clipboard history", t) end)
    end)
    on("clip_refresh", refresh)
    on("fact:desk_tab", function(v) if tonumber(v) == 2 and fact.desk_open then refresh() end end)
    on("fact:desk_open", function(v) if (v == true or tostring(v) == "true") and tonumber(fact.desk_tab) == 2 then refresh() end end)
    every(3000, function() if fact.desk_open and tonumber(fact.desk_tab) == 2 then refresh() end end)

    do
        local ok, saved = pcall(sys.ask, "files.read", "desk-clip-pins.json", "json")
        if ok and type(saved) == "table" and type(saved.items) == "table" then
            for _, p in ipairs(saved.items) do
                if type(p) == "table" and type(p.text) == "string" and p.text ~= "" and #pins < MAX_PINS then pins[#pins + 1] = { text = p.text } end
            end
        end
    end
    render()
end
