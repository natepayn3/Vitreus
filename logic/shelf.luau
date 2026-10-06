-- Shelf: things dropped on the desk's Shelf tab (files, links, text), kept between sessions in desk-shelf.json, up to eight, newest first.
-- A card carries its path (or link, or the text itself), so it can be dragged out onto any other program.
return function()
    local MAX = 8
    local items = {}                                    -- { name, path, tag }
    local function save() pcall(sys.call, "files.write", "desk-shelf.json", { items = items }) end
    local function render()
        for k = 0, MAX - 1 do
            local it = items[k + 1]
            text["shelf." .. k .. ".name"] = it and it.name or ""
            text["shelf." .. k .. ".path"] = it and it.path or ""
            text["shelf." .. k .. ".tag"] = it and it.tag or ""
            fact["shelf." .. k .. ".has"] = it ~= nil
        end
        fact.shelf_n = #items
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
        if ok and type(saved) == "table" and type(saved.items) == "table" then
            for _, x in ipairs(saved.items) do
                if type(x) == "table" and type(x.path) == "string" and #items < MAX then
                    items[#items + 1] = { name = tostring(x.name or x.path), path = x.path, tag = tostring(x.tag or "FILE") }
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
        if busy or type(k) ~= "number" or not items[k + 1] then return end
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
    on("shelf_clear", function() items = {}; save(); render() end)
    render()
end
