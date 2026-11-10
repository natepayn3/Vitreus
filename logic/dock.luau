-- The corner dock: the pinned apps in one row, in one of the two corners of the edge opposite the bar (see `cdk.*` in vitreus.plm). A pin keeps what it needs to be
-- drawn and started (`id`, `name`, `icon`, `exec`) so it shows before the apps list has arrived. Kept in dock-pins.json: `pins` in order, `corner` (0 or 1, the
-- scene's `cdk_corner`: where it was left) and `on` (the dock switched on). Pin from the launcher with a right click on an app's row (and again to let it go); in
-- the dock a click starts the app, a right click unpins it, and pulling it takes the dock to the other corner.
return function()
    local MAX = 8
    local pins = {}
    local shown = true
    local mid_on = false               -- Settings > Bar: on the Island, the app dock and the add-on pill are one dock in the middle of the bottom edge (`dock_mid`)
    local room_on = true               -- Settings > Bar: windows keep clear of the docks (kept here and only written to `dock_fx`: a handler reads that table as it was when it was made)
    local known = {}                  -- id -> the app as the apps service reports it, to keep the icons right

    local function save()
        pcall(sys.call, "files.write", "dock-pins.json", { pins = pins, corner = (fact.cdk_corner == 1 or fact.cdk_corner == true) and 1 or 0, on = shown, room = room_on, mid = mid_on })
    end
    local was = 0                 -- whether the dock was out at the last `render`, for the room the windows keep clear of it (`dock_fx`, vitreus.luau)
    local function render()
        local rows = {}
        for i, p in ipairs(pins) do rows[i] = { icon = p.icon or "" } end
        model.cdk_pins = rows
        fact.cdk_on = shown
        local out = shown and #pins or 0
        if out ~= was then was = out; dock_fx.nc = out; dock_fx.c = out > 0; dock_fx.changed() end
    end
    local function clean_exec(e)
        e = (e or ""):gsub("%%%%", "\1"):gsub("%%[fFuUdDnNickvm]", ""):gsub("\1", "%%")
        return (e:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local function take(list)
        for _, p in ipairs(type(list) == "table" and list or {}) do
            if type(p) == "table" and type(p.exec) == "string" and #pins < MAX then pins[#pins + 1] = p end
        end
    end

    local ok, saved = pcall(sys.ask, "files.read", "dock-pins.json", "json")
    if ok and type(saved) == "table" then
        take(saved.pins)
        take(saved.a)                 -- an earlier file had one list for each corner
        take(saved.b)
        if saved.on == false then shown = false end
        if saved.room == false then room_on = false; dock_fx.enabled = false end
        if saved.mid == true then mid_on = true end
        fact.cdk_corner = saved.corner == 1 and 1 or 0
    end
    render()

    local function find(a)
        local id = a.id or a.name or ""
        for i, p in ipairs(pins) do if p.id == id then return i end end
    end
    -- Called by the launcher (vitreus.luau) with the app a row stands for.
    function cdk_pinned(a) return type(a) == "table" and find(a) ~= nil end
    -- A right click on an app's row: pin it, or let it go. True when pinned, false when unpinned, nil when nothing could be done.
    function cdk_toggle(a)
        if type(a) ~= "table" or not a.exec then return nil end
        local i = find(a)
        if i then
            table.remove(pins, i)
            save(); render()
            return false
        end
        if #pins >= MAX then return nil end
        local id = a.id or a.name or ""
        pins[#pins + 1] = { id = id, name = a.name or id, icon = a.icon or "", exec = a.exec }
        save(); render()
        return true
    end

    on("cdk_go", function(i)
        local p = pins[math.floor(i + 0.5) + 1]
        if p then exec_on_desktop(clean_exec(p.exec)) end
    end)
    on("cdk_unpin", function(i)
        local n = math.floor(i + 0.5) + 1
        if not pins[n] then return end
        table.remove(pins, n)
        save(); render()
    end)
    on("fact:cdk_corner", function() save() end)
    fact.bar_dockroom = room_on
    fact.dock_mid = mid_on
    on("dock_mid_toggle", function()
        mid_on = not mid_on
        fact.dock_mid = mid_on
        save()
        dock_fx.changed()          -- (the room the windows keep clear of it follows its height)
    end)
    on("bar_dockroom_toggle", function()       -- Settings > Bar: windows keep clear of the docks, or go under them
        room_on = not room_on
        dock_fx.enabled = room_on
        fact.bar_dockroom = room_on
        save()
        dock_fx.changed()
    end)
    on("fact:cdk_on", function(v) local b = v == true or v == 1; if b ~= shown then shown = b; save(); render() end end)

    -- An icon theme change or an app that came later: refresh the pins' icons from what the apps service says.
    sys.watch("apps", function(list)
        local changed = false
        for _, a in ipairs(list or {}) do known[a.id or a.name or ""] = a end
        for _, p in ipairs(pins) do
            local a = known[p.id]
            if a and a.icon and a.icon ~= p.icon then p.icon = a.icon; changed = true end
        end
        if changed then render() end
    end)
end
