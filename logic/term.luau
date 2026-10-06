-- The Desk's Term tab. `bin/vitreus-term` runs the shell in a pseudo-terminal, keeps its screen (pyte) and prints it as a line of JSON
-- each time it changes: stretches of one colour, and the cursor. It starts the first time the tab is shown and keeps running (the shell
-- with it) when the tab or the desk is shut, so the session is still there next time. Keys typed while the terminal has the keyboard go
-- to it as pleamar names them (`Ctrl+c`, `Up`) with what they type, and the helper turns them into what a terminal sends.
return function(key)
    local COLS, ROWS = 64, 35                -- the scene's grid (64 by 35 cells of 7.19 by 16 px)
    local proc = nil
    local function hex(s)
        return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
    end
    local function rgb(h)
        return (tonumber(h:sub(1, 2), 16) or 0) / 255, (tonumber(h:sub(3, 4), 16) or 0) / 255, (tonumber(h:sub(5, 6), 16) or 0) / 255
    end
    local function on_line(line)
        local ok, f = pcall(json.decode, line)
        if not ok or type(f) ~= "table" then return end
        if f.error then
            text.term_msg = tostring(f.error)
            fact.term_state = 3
            return
        end
        local runs = {}
        for i, r in ipairs(f.runs or {}) do
            local t, fg, bg = tostring(r[3] or ""), tostring(r[4] or ""), tostring(r[5] or "")
            local rec = { t = t, x = r[2] or 0, y = r[1] or 0, n = utf8.len(t) or #t, bold = r[6] == true, fg = fg ~= "", hasbg = bg ~= "" }
            if rec.fg then rec.r, rec.g, rec.b = rgb(fg) end
            if rec.hasbg then rec.br, rec.bg, rec.bb = rgb(bg) end
            runs[i] = rec
        end
        model.term_runs = runs
        fact.term_cx = f.cx or 0
        fact.term_cy = f.cy or 0
        fact.term_cur = f.cursor == true
        fact.term_scrolled = f.scrolled or 0
    end
    local function start()
        if proc then return end
        fact.term_state = 1
        local mine
        mine = spawn("vitreus-term", { tostring(COLS), tostring(ROWS) },
            function(line) if proc == mine then on_line(line) end end,
            function()
                if proc ~= mine then return end
                proc = nil
                if fact.term_state ~= 3 then
                    fact.term_state = 2
                    model.term_runs = {}
                    fact.term_cur = false
                    fact.term_scrolled = 0
                end
            end,
            { stdin = "open" })
        proc = mine
    end
    local function showing()
        return fact.desk_open == true and fact.desk_tab == 3
    end
    -- Not started yet, or it could not run (pyte missing): opening the tab tries again, so installing it needs no restart.
    local function refresh()
        if showing() and (fact.term_state == 0 or fact.term_state == 3) then start() end
    end
    on("fact:desk_open", refresh)
    on("fact:desk_tab", refresh)
    on("key", function(name, typed)
        if not (showing() and fact.desk_kb == true) then return end
        if not proc then
            if fact.term_state == 2 or fact.term_state == 3 then start() end
            return
        end
        write(proc, "k " .. tostring(name) .. " " .. hex(typed or "") .. "\n")
    end)
    on("term_scroll", function(n)
        if proc and type(n) == "number" and n ~= 0 then write(proc, "s " .. (n > 0 and "3" or "-3") .. "\n") end
    end)
    refresh()
end
