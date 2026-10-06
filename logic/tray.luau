-- The system tray: the apps that live in it and have no window. They are listed in the window-title panel (with a pin
-- and a menu button each) and ride the bar as icons: all of them, or only the pinned ones (`tray_only_pinned`). A left
-- click is what clicking the icon would do, a right click opens the app's own menu, drawn here from the tree the app
-- publishes (`tray.menu`) with its submenus opening in place. Which apps are pinned, and the bar's mode, are kept in
-- tray.json. An app is known by its `id`, which survives restarts; its bus name does not.
return function(set_panel)
    local items = {}            -- what the service reported, in the order the bar shows
    local listed = {}           -- row of `trays` -> item
    local barred = {}           -- row of `bartrays` -> item
    local pinned = {}           -- id -> true
    local only_pinned = false
    local cur = nil             -- the app whose menu is open
    local tree = nil            -- its menu, as it came
    local unfolded = {}         -- the submenus that are open, by their place: "2/1"
    local flat = {}             -- row of `tray_menu` -> { entry, place }

    local function ident(t)
        if t.id ~= nil and t.id ~= "" then return t.id end
        return t.key or ""
    end
    local function title_of(t)
        if t.title ~= nil and t.title ~= "" then return t.title end
        return ident(t)
    end

    local function save()
        local ids = {}
        for id in pairs(pinned) do ids[#ids + 1] = id end
        table.sort(ids)
        pcall(sys.call, "files.write", "tray.json", { pinned = ids, only_pinned = only_pinned })
    end

    local function header()
        if not cur then return end
        text.tm_title = title_of(cur)
        text.tm_sub = ident(cur)
        text.tm_iconurl = cur.icon or ""
        fact.tm_pinned = pinned[ident(cur)] == true
    end

    local function render()
        local rows, bar_rows = {}, {}
        listed, barred = {}, {}
        for _, t in ipairs(items) do
            local pin = pinned[ident(t)] == true
            if #rows < 16 then
                rows[#rows + 1] = { title = title_of(t), icon = t.icon or "", pinned = pin, menu = t.menu == true }
                listed[#rows] = t
            end
            if #bar_rows < 8 and (pin or not only_pinned) then
                bar_rows[#bar_rows + 1] = { icon = t.icon or "" }
                barred[#bar_rows] = t
            end
        end
        model.trays = rows
        model.bartrays = bar_rows
        fact.tray_only_pinned = only_pinned
        header()
    end

    sys.watch("tray", function(list)
        items = {}
        for _, t in ipairs(list or {}) do items[#items + 1] = t end
        -- a stable order: the bus registration order changes with what started first
        table.sort(items, function(a, b) return ident(a) < ident(b) end)
        render()
    end)

    -- Labels use a leading underscore for the accelerator (`_File`); `__` is a real one.
    local function clean(label)
        label = (label or ""):gsub("__", "\1")
        label = label:gsub("_", "")
        label = label:gsub("\1", "_")
        return label
    end

    local function flatten()
        local rows = {}
        local h = 0
        flat = {}
        local function walk(list, depth, place)
            for i, e in ipairs(list or {}) do
                if #rows >= 40 then return end
                local p = place .. "/" .. i
                local kids = type(e.children) == "table" and #e.children > 0
                local open = kids and unfolded[p] == true
                local sep = e.separator == true
                rows[#rows + 1] = {
                    label = clean(e.label), enabled = e.enabled ~= false, sep = sep,
                    checked = e.checked == true or e.checked == 1, kids = kids, open = open, depth = depth,
                }
                flat[#rows] = { entry = e, place = p, kids = kids }
                h = h + (sep and 10 or 28) + 2
                if open then walk(e.children, depth + 1, p) end
            end
        end
        walk(tree, 0, "")
        model.tray_menu = rows
        fact.tm_h = math.max(0, h - 2)
    end

    local function open_menu(t)
        if not t then return end
        cur = t
        unfolded = {}
        tree = nil
        if t.menu then
            local ok, m = pcall(sys.ask, "tray.menu", t.key)
            if ok and type(m) == "table" then tree = m end
        end
        fact.tm_has_menu = tree ~= nil and #tree > 0
        header()
        flatten()
        set_panel("tray")
    end

    -- A left click. An app that is only a menu (no id, but a menu) has nothing to activate: it opens the menu.
    local function primary(t)
        if not t then return end
        if t.menu and (t.id == nil or t.id == "") then return open_menu(t) end
        pcall(sys.call, "tray.activate", t.key)
    end

    local function toggle_pin(t)
        if not t then return end
        local id = ident(t)
        if id == "" then return end
        if pinned[id] then pinned[id] = nil else pinned[id] = true end
        save()
        render()
    end

    on("tray_click", function(i) primary(listed[i + 1]) end)
    on("bar_tray_click", function(i)
        local t = barred[i + 1]
        if not t then return end
        primary(t)
        if not (t.menu and (t.id == nil or t.id == "")) then set_panel("none") end
    end)
    on("tray_menu_open", function(i) open_menu(listed[i + 1]) end)
    on("bar_tray_menu", function(i) open_menu(barred[i + 1]) end)
    on("tray_pin", function(i) toggle_pin(listed[i + 1]) end)
    on("tm_pin", function() toggle_pin(cur) end)
    on("tm_open", function()
        if cur then pcall(sys.call, "tray.activate", cur.key) end
        set_panel("none")
    end)
    on("tm_alt", function()
        if cur then pcall(sys.call, "tray.secondary", cur.key) end
        set_panel("none")
    end)
    on("tray_mode", function()
        only_pinned = not only_pinned
        save()
        render()
    end)
    on("tray_menu_pick", function(i)
        local row = flat[i + 1]
        if not row or not cur then return end
        if row.kids then
            unfolded[row.place] = not unfolded[row.place] or nil
            flatten()
            return
        end
        if row.entry.enabled == false or row.entry.separator == true then return end
        pcall(sys.call, "tray.menu_click", cur.key, row.entry.id)
        set_panel("none")
    end)

    local ok, saved = pcall(sys.ask, "files.read", "tray.json", "json")
    if ok and type(saved) == "table" then
        if type(saved.pinned) == "table" then
            for _, id in ipairs(saved.pinned) do if type(id) == "string" then pinned[id] = true end end
        end
        only_pinned = saved.only_pinned == true
        render()
    end
end
