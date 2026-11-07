-- Settings > Keybinds: the shell's keybinds as the window manager has them, read from its own file and rewritten there when one is changed.
--   Hyprland: hypr_vitreus.lua  (`hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd("... pleamar --say vitreus \"emit dash_toggle\""))`)
--   pleamar-wm: keys.conf       (`bind Super+d launch pleamar --say vitreus "emit desk_toggle"`)
-- Only the binds that talk to the shell (`pleamar --say ...`) are listed, and the one that opens Files (`vitreus-files`). A bind is changed in place (its `unbind` line too), and Hyprland is
-- reloaded; pleamar-wm reads its keys when it starts. The scene shows the rows (`kb_rows`), the chips for the modifiers and a box that
-- records the next key (`kb_press`, the codes of pages/keybinds_keys.plm: modifiers * 100 + the key's place in KEYS).
return function()
    local KEYS = {}
    for k in ("a b c d e f g h i j k l m n o p q r s t u v w x y z F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 space Return Tab Print BackSpace Delete Insert Home End Prior Next Left Right Up Down comma period slash semicolon apostrophe bracketleft bracketright backslash minus equal grave"):gmatch("%S+") do
        KEYS[#KEYS + 1] = k
    end
    local KEYIDX = {}
    for i, k in ipairs(KEYS) do KEYIDX[k:lower()] = i end
    local DISP = { space = "Space", Return = "Enter", Tab = "Tab", Print = "Print", BackSpace = "Backspace", Delete = "Delete", Insert = "Insert",
        Home = "Home", End = "End", Prior = "PgUp", Next = "PgDn", Left = "←", Right = "→", Up = "↑", Down = "↓", comma = ",", period = ".",
        slash = "/", semicolon = ";", apostrophe = "'", bracketleft = "[", bracketright = "]", backslash = "\\", minus = "-", equal = "=", grave = "`" }
    local function disp_key(k)
        if #k == 1 then return k:upper() end
        return DISP[k] or k
    end
    local MODS = { { 1, "Super" }, { 4, "Ctrl" }, { 8, "Alt" }, { 2, "Shift" } }   -- the order a combo is written in
    local MODBIT = { super = 1, mod = 1, mod4 = 1, win = 1, shift = 2, ctrl = 4, control = 4, alt = 8, mod1 = 8 }

    -- What each bind does, by what it says to the shell. Binds that are not here are left out.
    local ACTS = {
        ["vitreus emit launch_toggle"] = "Launcher",
        ["vitreus emit settings_toggle"] = "Settings",
        ["vitreus emit controls_toggle"] = "Control Center",
        ["lockscreen fact locked true"] = "Lock screen",
        ["vitreus emit wp_picker_toggle"] = "Wallpaper picker",
        ["vitreus emit desk_toggle"] = "Desk",
        ["vitreus emit dash_toggle"] = "Dashboard",
        ["vitreus emit ov_toggle"] = "Workspace overview",
        ["vitreus emit shot 0"] = "Screenshot: region",
        ["vitreus emit shot 1"] = "Screenshot: whole screen",
        ["vitreus emit rec_toggle"] = "Record the screen",
        ["launch vitreus-files"] = "Files",
        ["vitreus-files"] = "Files",
    }
    -- The combos this shell ships with, per window manager, as (modifier bits, key); a second one is for an action that has two.
    local DEFAULTS = {
        hypr = {
            ["vitreus-files"] = { { 1, "e" } },
            ["vitreus emit launch_toggle"] = { { 1, "space" } }, ["vitreus emit settings_toggle"] = { { 3, "space" } }, ["vitreus emit controls_toggle"] = { { 1, "c" } },
            ["lockscreen fact locked true"] = { { 1, "l" } }, ["vitreus emit wp_picker_toggle"] = { { 1, "b" } },
            ["vitreus emit desk_toggle"] = { { 1, "d" } }, ["vitreus emit dash_toggle"] = { { 3, "d" } }, ["vitreus emit ov_toggle"] = { { 1, "Tab" } },
            ["vitreus emit shot 0"] = { { 1, "a" } }, ["vitreus emit shot 1"] = { { 5, "a" } }, ["vitreus emit rec_toggle"] = { { 3, "a" } },
        },
        niri = {
            ["vitreus-files"] = { { 1, "e" } },
            ["vitreus emit launch_toggle"] = { { 1, "space" } }, ["vitreus emit settings_toggle"] = { { 3, "space" } }, ["vitreus emit controls_toggle"] = { { 1, "c" } },
            ["lockscreen fact locked true"] = { { 1, "l" } }, ["vitreus emit wp_picker_toggle"] = { { 1, "b" } },
            ["vitreus emit desk_toggle"] = { { 1, "d" } }, ["vitreus emit dash_toggle"] = { { 3, "d" } }, ["vitreus emit ov_toggle"] = { { 1, "Tab" } },
            ["vitreus emit shot 0"] = { { 1, "a" } }, ["vitreus emit shot 1"] = { { 5, "a" } }, ["vitreus emit rec_toggle"] = { { 3, "a" } },
        },
        pwm = {
            ["vitreus emit launch_toggle"] = { { 1, "space" } }, ["vitreus emit settings_toggle"] = { { 3, "space" } }, ["vitreus emit controls_toggle"] = { { 1, "c" } },
            ["lockscreen fact locked true"] = { { 1, "l" } }, ["vitreus emit wp_picker_toggle"] = { { 1, "b" } },
            ["vitreus emit desk_toggle"] = { { 1, "d" } }, ["vitreus emit dash_toggle"] = { { 3, "d" } }, ["vitreus emit shot 0"] = { { 1, "a" } },
            ["vitreus emit shot 1"] = { { 5, "a" } }, ["vitreus emit rec_toggle"] = { { 3, "a" } },
            ["launch vitreus-files"] = { { 1, "e" } },
        },
    }

    -- What a bind taken out here starts with: the line stays in the file, commented, so it can be put back.
    local REMOVED = { hypr = "-- removed in Settings: ", pwm = "#removed# ", niri = "// removed in Settings: " }

    local K = { rows = {}, sel = 0, mask = 0, key = "" }     -- sel: 1-based, 0 = none

    local function wm() return fact.wm_niri == true and "niri" or (fact.wm_hypr == true and "hypr" or "pwm") end
    local function home() return K.home or "" end
    local function path()
        if wm() == "hypr" then return home() .. "/.config/hypr/hypr_vitreus.lua" end
        if wm() == "niri" then return home() .. "/.config/niri/niri_vitreus.kdl" end
        return home() .. "/.config/pleamar/keys.conf"
    end

    -- A combo as the file writes it, to (modifier bits, key); nil when it does not make sense.
    local function parse_combo(s)
        local parts = {}
        for p in (s or ""):gmatch("[^%+%s]+") do parts[#parts + 1] = p end
        if #parts == 0 then return nil end
        local mask = 0
        for i = 1, #parts - 1 do
            local b = MODBIT[parts[i]:lower()]
            if not b then return nil end
            mask = bit32.bor(mask, b)
        end
        local key = parts[#parts]
        local idx = KEYIDX[key:lower()]
        if not idx then return nil end
        return mask, KEYS[idx]
    end
    -- And back: Hyprland writes `SUPER + SHIFT + D`, pleamar-wm `Super+Shift+d`.
    local function write_combo(mask, key)
        local names = {}
        for _, m in ipairs(MODS) do
            if bit32.band(mask, m[1]) ~= 0 then names[#names + 1] = wm() == "hypr" and m[2]:upper() or (wm() == "niri" and m[2] == "Super" and "Mod" or m[2]) end
        end
        local k = key
        if wm() == "hypr" or wm() == "niri" then
            if #key == 1 then k = key:upper() elseif key == "space" then k = "Space" end    -- as the file has always written them
        end
        names[#names + 1] = k
        return table.concat(names, wm() == "hypr" and " + " or "+")
    end

    -- The words on the key caps: modifiers, then the key; each with its width (in the page's own units, which are 1.69 times the text's pixels: a
    -- cap is 11 of padding and about 4.4 per letter) and how far its middle is from the right end of the row.
    local function caps(mask, key)
        local parts = {}
        for _, m in ipairs(MODS) do if bit32.band(mask, m[1]) ~= 0 then parts[#parts + 1] = m[2] end end
        parts[#parts + 1] = disp_key(key)
        local w = {}
        for i, p in ipairs(parts) do w[i] = math.max(15, 11 + #p * 4.4) end
        local right, off = 0, {}
        for i = #parts, 1, -1 do
            off[i] = right + w[i] / 2
            right = right + w[i] + 5
        end
        return parts, w, off
    end

    local function show()
        local model_rows = {}
        for i, r in ipairs(K.rows) do
            local parts, w, off = caps(r.mask, r.key)
            local row = { name = r.name, chg = r.changed }
            local names = { "a", "b", "c", "d" }
            for j = 1, 4 do
                row[names[j]] = parts[j] or ""
                row["w" .. names[j]] = parts[j] and w[j] or 0
                row["r" .. names[j]] = parts[j] and off[j] or 0
            end
            model_rows[i] = row
        end
        model.kb_rows = model_rows
        fact.kb_ok = #K.rows > 0
    end

    local function dirty()
        local r = K.rows[K.sel]
        fact.kb_dirty = r ~= nil and K.key ~= "" and (K.mask ~= r.mask or K.key ~= r.key)
    end
    local function pick_text()
        text.kb_key = K.key ~= "" and disp_key(K.key) or ""
        fact.kb_has = K.key ~= ""
    end

    local function read(fn)
        run("cat", { path() }, function(out, code)
            local rows = {}
            local seen = {}
            if code == 0 then
                for line in (out or ""):gmatch("[^\n]+") do
                    local combo, scene, cmd
                    if wm() == "niri" then
                        combo, scene, cmd = line:match("^%s*(%S+)%s*{%s*spawn%-sh%s+\"pleamar %-%-say (%S+) '(.-)'\"")
                        if not combo then combo, scene = line:match('^%s*(%S+)%s*{%s*spawn%s+"(vitreus%-files)"') end
                    elseif wm() == "hypr" then
                        combo, scene, cmd = line:match('^hl%.bind%("([^"]+)",.-pleamar %-%-say (%S+) \\"(.-)\\"')
                        if not combo then combo, scene, cmd = line:match('^hl%.bind%("([^"]+)", hl%.dsp%.exec_cmd%(".-(vitreus%-files)"%)') end
                    else
                        combo, scene, cmd = line:match('^bind%s+(%S+)%s+.-pleamar %-%-say (%S+) "(.-)"')
                        if not combo then combo, scene, cmd = line:match('^bind%s+(%S+)%s+(launch)%s+(vitreus%-files)%s*$') end
                    end
                    if combo then
                        local act = cmd and (scene .. " " .. cmd) or scene     -- Hyprland's Files bind has no scene
                        local name = ACTS[act]
                        local mask, key = parse_combo(combo)
                        if name and mask then
                            seen[act] = (seen[act] or 0) + 1
                            -- A bind is unchanged if it is any of the keys the action ships with (a file may keep only one of two, or have them in another order);
                            -- otherwise it is compared with the stock key of its place, which "Reset" puts back.
                            local list = DEFAULTS[wm()][act] or {}
                            local d, same = list[seen[act]], nil
                            for _, x in ipairs(list) do if x[1] == mask and x[2] == key then same = x end end
                            if same then d = same end
                            rows[#rows + 1] = { order = #rows + 1, act = act, name = name, mask = mask, key = key, text = combo, def = d,
                                changed = d ~= nil and same == nil }
                        end
                    end
                end
            end
            table.sort(rows, function(a, b)          -- alphabetical; two binds of one action keep the order they have in the file
                if a.name ~= b.name then return a.name:lower() < b.name:lower() end
                return a.order < b.order
            end)
            K.rows = rows
            show()
            if fn then fn() end
        end)
    end

    local function refresh()
        if K.home then read() return end
        run("printenv", { "HOME" }, function(out)
            K.home = (out or ""):gsub("%s+$", "")
            read()
        end)
    end

    on("kb_refresh", function()
        K.sel = 0
        fact.kb_sel = -1
        fact.kb_cap = false
        fact.kb_dirty = false
        text.kb_msg = ""
        text.kb_where = wm() == "hypr" and "Hyprland  ·  hypr_vitreus.lua" or (wm() == "niri" and "niri  ·  niri_vitreus.kdl" or "Pleamar-WM  ·  keys.conf")
        refresh()
    end)

    on("kb_select", function(i)
        i = (tonumber(i) or 0) + 1
        local r = K.rows[i]
        if not r then return end
        K.sel, K.mask, K.key = i, r.mask, r.key
        fact.kb_sel = i - 1
        fact.kb_cap = false
        fact.kb_mod = r.mask
        text.kb_name = r.name
        text.kb_msg = ""
        pick_text()
        dirty()
    end)

    on("kb_mod_toggle", function(bit)
        bit = tonumber(bit) or 0
        if K.sel == 0 or bit == 0 then return end
        K.mask = bit32.bxor(K.mask, bit)
        fact.kb_mod = K.mask
        text.kb_msg = ""
        dirty()
    end)

    -- A key was pressed while recording: its place in KEYS and the modifiers that were down with it.
    on("kb_press", function(code)
        code = tonumber(code) or 0
        local key = KEYS[code % 100 + 1]
        if not key or K.sel == 0 then return end
        K.mask, K.key = math.floor(code / 100), key
        fact.kb_mod = K.mask
        fact.kb_cap = false
        text.kb_msg = ""
        pick_text()
        dirty()
    end)

    on("kb_cancel", function()
        K.sel = 0
        fact.kb_sel = -1
        fact.kb_cap = false
        fact.kb_dirty = false
        text.kb_msg = ""
    end)

    -- Writes combo `mask`, `key` in place of what row `r` has, in the file; then reloads the window manager and reads the file again.
    local function apply(r, mask, key)
        local old, new = r.text, write_combo(mask, key)
        if not new:match("^[%w_ %+]+$") or not old:match("^[%w_ %+]+$") then text.kb_msg = "That key cannot be written to the file" return end
        for i, o in ipairs(K.rows) do
            if o ~= r and o.mask == mask and o.key == key then text.kb_msg = "Already used by " .. o.name return end
        end
        local script
        if wm() == "hypr" then
            script = 's|"' .. old .. '"|"' .. new .. '"|g'
        elseif wm() == "niri" then
            script = 's|^\\([[:space:]]*\\)' .. old .. '\\([[:space:]]*{\\)|\\1' .. new .. '\\2|'
        else
            script = 's|^\\(unbind[[:space:]]\\{1,\\}\\)' .. old .. '[[:space:]]*$|\\1' .. new .. '|; ' ..
                     's|^\\(bind[[:space:]]\\{1,\\}\\)' .. old .. '\\([[:space:]]\\)|\\1' .. new .. '\\2|'
        end
        run("sed", { "-i", "--follow-symlinks", script, path() }, function(_, code)
            if code ~= 0 then text.kb_msg = "Could not write " .. path() return end
            local function done()
                read(function()
                    K.sel = 0
                    fact.kb_sel = -1
                    fact.kb_dirty = false
                    text.kb_msg = wm() == "hypr" and "Saved. Hyprland has the new key." or (wm() == "niri" and "Saved. niri has the new key." or "Saved. Pleamar-WM uses it from its next start.")
                end)
            end
            if wm() == "hypr" then run("hyprctl", { "reload" }, function() done() end) else done() end     -- (niri reloads a file it includes by itself)
        end)
    end

    on("kb_save", function()
        local r = K.rows[K.sel]
        if not r or K.key == "" then return end
        apply(r, K.mask, K.key)
    end)

    -- Takes the selected bind out of the file: its line is kept as a comment (Reset to defaults puts it back). Under pleamar-wm an `unbind` follows,
    -- so the key does nothing at all and not what `defaults` gives it.
    on("kb_delete", function()
        local r = K.rows[K.sel]
        if not r then return end
        local old = r.text
        if not old:match("^[%w_ %+]+$") then text.kb_msg = "That key cannot be written to the file" return end
        local script
        if wm() == "hypr" then
            script = 's|^\\(hl\\.bind("' .. old .. '",\\)|' .. REMOVED.hypr .. '\\1|'
        elseif wm() == "niri" then
            script = 's|^\\([[:space:]]*' .. old .. '[[:space:]]*{.*\\)$|' .. REMOVED.niri .. '\\1|'
        else
            script = 's|^\\(bind[[:space:]]\\{1,\\}' .. old .. '[[:space:]].*\\)$|' .. REMOVED.pwm .. '\\1\\nunbind ' .. old .. '|'
        end
        run("sed", { "-i", "--follow-symlinks", script, path() }, function(_, code)
            if code ~= 0 then text.kb_msg = "Could not write " .. path() return end
            local function done()
                read(function()
                    K.sel = 0
                    fact.kb_sel = -1
                    fact.kb_dirty = false
                    text.kb_msg = "Removed “" .. r.name .. "”. Reset to defaults puts it back."
                end)
            end
            if wm() == "hypr" then run("hyprctl", { "reload" }, function() done() end) else done() end
        end)
    end)

    -- Reset to defaults: every bind of this shell's goes back to the key it ships with, whether it was changed, taken out here or edited by hand.
    -- Its lines are dropped (and the ones Delete left as comments) and one block of the stock ones is written at the end of the file. Pressed
    -- twice (the first press only arms it): it overwrites the keys that were changed.
    local BLOCK = { hypr = { "-- >>> vitreus defaults (Settings > Keybinds)", "-- <<< vitreus defaults" },
                    pwm = { "# >>> vitreus defaults (Settings > Keybinds)", "# <<< vitreus defaults" },
                    niri = { "// >>> vitreus defaults (Settings > Keybinds)", "// <<< vitreus defaults" } }
    local function default_lines(w)
        local out = { BLOCK[w][1] }
        local acts = {}
        for act in pairs(DEFAULTS[w]) do acts[#acts + 1] = act end
        table.sort(acts)
        for _, act in ipairs(acts) do
            local scene, cmd = act:match("^(%S+) (.+)$")
            for _, d in ipairs(DEFAULTS[w][act]) do
                local combo = write_combo(d[1], d[2])
                if w == "niri" then
                    out[#out + 1] = (act == "vitreus-files") and ("    " .. combo .. ' { spawn "vitreus-files"; }')
                        or ("    " .. combo .. " { spawn-sh \"pleamar --say " .. scene .. " '" .. cmd .. "'\"; }")
                elseif w == "hypr" then
                    local run_it = (act == "vitreus-files") and 'PATH=\\"$HOME/.local/bin:$PATH\\" vitreus-files'
                        or ('PATH=\\"$HOME/.local/bin:$PATH\\" pleamar --say ' .. scene .. ' \\"' .. cmd .. '\\"')
                    out[#out + 1] = 'hl.unbind("' .. combo .. '")'
                    out[#out + 1] = 'hl.bind("' .. combo .. '", hl.dsp.exec_cmd("' .. run_it .. '"))'
                else
                    local run_it = (act == "launch vitreus-files") and "launch vitreus-files"
                        or ('launch pleamar --say ' .. scene .. ' "' .. cmd .. '"')
                    out[#out + 1] = "unbind " .. combo
                    out[#out + 1] = "bind " .. combo .. " " .. run_it
                end
            end
        end
        out[#out + 1] = BLOCK[w][2]
        if w == "niri" then out[#out + 1] = "}" end          -- (niri has one `binds` per file: the block goes inside it, before its closing brace)
        return out
    end
    on("kb_defaults", function()
        if not fact.kb_arm then
            fact.kb_arm = true
            after(4000, function() fact.kb_arm = false end)
            return
        end
        fact.kb_arm = false
        local w = wm()
        local cmds = {}
        for act in pairs(ACTS) do
            local cmd = act:match("^%S+ (emit .+)$") or act:match("^%S+ (fact .+)$")
            if cmd then cmds[#cmds + 1] = cmd end
        end
        table.sort(cmds)
        local alt = table.concat(cmds, "|")
        local drop, script2 = {}, {}
        if w == "niri" then
            drop = { "-e", "/^[[:space:]]*[^[:space:]]+[[:space:]]*\\{[[:space:]]*(spawn-sh[[:space:]]+\"pleamar --say (vitreus|lockscreen) '(" .. alt .. ")'\"|spawn[[:space:]]+\"vitreus-files\")/d",
                     "-e", "/^\\/\\/ removed in Settings: /d",
                     "-e", "/^\\/\\/ >>> vitreus defaults/,/^\\/\\/ <<< vitreus defaults/d",
                     "-e", "${/^}[[:space:]]*$/d}" }
        elseif w == "hypr" then
            drop = { "-e", '/^hl\\.bind\\(.*(--say (vitreus|lockscreen) \\\\"(' .. alt .. ')\\\\"|vitreus-files)/d',
                     "-e", "/^-- removed in Settings: /d",
                     "-e", "/^-- >>> vitreus defaults/,/^-- <<< vitreus defaults/d" }
        else
            drop = { "-e", '/^bind[[:space:]].*(pleamar --say (vitreus|lockscreen) "(' .. alt .. ')"|launch vitreus-files)[[:space:]]*$/d',
                     "-e", "/^#removed# /{N;d}",
                     "-e", "/^# >>> vitreus defaults/,/^# <<< vitreus defaults/d" }
        end
        local args = { "-i", "-E", "--follow-symlinks" }
        for _, a in ipairs(drop) do args[#args + 1] = a end
        args[#args + 1] = path()
        run("sed", args, function(_, code)
            if code ~= 0 then text.kb_msg = "Could not write " .. path() return end
            -- (a second pass: `$a` never fires when the last line is one of those just deleted)
            local add = { "-i", "--follow-symlinks" }
            for _, line in ipairs(default_lines(w)) do
                add[#add + 1] = "-e"
                add[#add + 1] = "$a\\" .. line:gsub("\\", "\\\\")
            end
            add[#add + 1] = path()
            run("sed", add, function(_, code2)
                if code2 ~= 0 then text.kb_msg = "Could not write " .. path() return end
                local function done()
                    read(function()
                        K.sel = 0
                        fact.kb_sel = -1
                        fact.kb_dirty = false
                        text.kb_msg = (w == "hypr" or w == "niri") and "Back to the default keys." or "Back to the default keys. Pleamar-WM uses them from its next start."
                    end)
                end
                if w == "hypr" then run("hyprctl", { "reload" }, function() done() end) else done() end
            end)
        end)
    end)

    on("kb_reset", function()
        local r = K.rows[K.sel]
        if not r or not r.def then text.kb_msg = "No stock key for this one" return end
        apply(r, r.def[1], r.def[2])
    end)
end
