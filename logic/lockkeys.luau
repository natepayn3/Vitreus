-- Caps Lock, Num Lock and the keyboard layout.
--
-- Hyprland says nothing when a lock key is pressed, so hypr_vitreus.lua binds Caps_Lock and Num_Lock without taking them from the window
-- (`non_consuming`): the bind says `emit lockkeys` here, and the state is read from `hyprctl devices -j` a moment later (the main keyboard's
-- `capsLock` and `numLock`). No polling. A change shows a row of the volume drawer for two seconds (pages/osd_drawer.plm).
-- The layout: Hyprland's event socket says `activelayout>>KEYBOARD,NAME` when it changes (vitreus.luau's listener calls `LOCKKEYS.layout`); the bar
-- shows a two-letter chip with the tray icons only when more than one layout is set up (`kb_multi`), and a press on it switches to the next.
-- Under pleamar-wm the window manager scene says the new state itself (`lockkeys_set`, from pleamar-wm/wm/session.luau); the layout is
-- Hyprland's only.
return function()
    local caps, num = nil, nil
    local main_name = nil
    local show_row = LOCKKEYS.show               -- taken now: a handler would read the shared table as it was made
    local function pop(kind, state)
        fact.lk_kind = kind
        fact.lk_state = state and true or false
        if show_row then show_row("m") end       -- the volume drawer's third row, for two seconds
    end
    local function read(cb)
        run("hyprctl", { "devices", "-j" }, function(out, code)
            if code ~= 0 then return end
            local ok, j = pcall(json.decode, out or "")
            if not ok or type(j) ~= "table" or type(j.keyboards) ~= "table" then return end
            local kb
            for _, k in ipairs(j.keyboards) do if type(k) == "table" and k.main then kb = k end end
            kb = kb or j.keyboards[1]
            if type(kb) == "table" then cb(kb) end
        end)
    end
    -- "us,de" and index 1 is "DE"; a variant-only name falls back to the keymap's first letters
    local function show_layout(kb)
        local list = {}
        for l in tostring(kb.layout or ""):gmatch("[^,%s]+") do list[#list + 1] = l end
        main_name = kb.name
        if fact.kb_multi ~= (#list > 1) then fact.kb_multi = #list > 1 end
        local i = (tonumber(kb.active_layout_index) or 0) + 1
        local code = list[i] or tostring(kb.active_keymap or ""):sub(1, 2)
        text.kb_code = code:sub(1, 3):upper()
        text.kb_layout = tostring(kb.active_keymap or code)
    end
    read(function(kb)
        caps, num = kb.capsLock == true, kb.numLock == true
        show_layout(kb)
    end)

    on("lockkeys", function()
        after(120, function()
            read(function(kb)
                local c, n = kb.capsLock == true, kb.numLock == true
                if caps ~= nil and c ~= caps then pop(0, c)
                elseif num ~= nil and n ~= num then pop(1, n) end
                caps, num = c, n
            end)
        end)
    end)

    -- pleamar-wm says the new state itself (its window manager scene passes on `keys.caps` and `keys.num`): nothing to read.
    on("lockkeys_set", function(n)
        n = math.floor((tonumber(n) or 0) + 0.5)
        local kind, state = n // 2, n % 2 == 1
        if kind == 0 then caps = state elseif kind == 1 then num = state else return end
        pop(kind, state)
    end)

    local last_map = nil                -- the layout last seen (a local of this module: see CLAUDE.md on shared globals)
    LOCKKEYS.layout = function()
        read(function(kb)
            -- (the layout's own name, kept here: `kb_name` was also the Keybinds editor's title, so choosing a row there popped this up)
            local before = last_map
            show_layout(kb)
            last_map = kb.active_keymap
            if fact.kb_multi and kb.active_keymap ~= before then pop(2, true) end
        end)
    end
    on("kb_next", function()
        if main_name then run("hyprctl", { "switchxkblayout", main_name, "next" }, function() end) end
    end)
end
