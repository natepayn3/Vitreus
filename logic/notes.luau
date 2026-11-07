-- The Desk's Notes (pages/desk_notes.plm): up to sixteen notes of ten lines each, the first line a note's title, kept in desk-notes.json,
-- in their own order (a new one comes first; Home's Notes widget moves them, `note_move`). One is open while `note_sel` is its place; its lines are the inputs `nl.0` .. `nl.9`, kept as they are typed.
-- Home's Notes widget shows them (the `notes` model). Other modules keep a note with the global `desk_note_add(title, lines)` (an answer in Ask, a Clip entry).
return function()
    local MAX, LINES = 16, 10
    local notes = {}                                      -- { lines = { ... }, t = when it was last changed }
    local sel = -1                                        -- the open one, as a place in `notes` (0-based), or -1
    local loading = false                                 -- the inputs are being filled from a note: their changes are not typing
    local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    local function save()
        local out = {}
        for i, n in ipairs(notes) do out[i] = { lines = n.lines, t = n.t, c = n.c } end
        pcall(sys.call, "files.write", "desk-notes.json", { notes = out })
    end
    local function load()
        notes = {}
        local fresh = false                               -- a note saved before notes had a look of their own: it is given one, and kept
        local ok, s = pcall(sys.ask, "files.read", "desk-notes.json", "json")
        if ok and type(s) == "table" and type(s.notes) == "table" then
            for _, n in ipairs(s.notes) do
                if type(n) == "table" and type(n.lines) == "table" and #notes < MAX then
                    local ls = {}
                    for k = 1, LINES do ls[k] = type(n.lines[k]) == "string" and n.lines[k] or "" end
                    if tonumber(n.c) == nil then fresh = true end
                    notes[#notes + 1] = { lines = ls, t = tonumber(n.t) or 0, c = tonumber(n.c) or math.random(0, 19) }
                end
            end
        end
        if fresh then save() end
    end
    local function title_of(n)
        for _, l in ipairs(n.lines) do if trim(l) ~= "" then return trim(l) end end
        return "Untitled"
    end
    local function body_of(n, skip)                       -- the lines after the title that say something
        local out, past = {}, false
        for _, l in ipairs(n.lines) do
            local t = trim(l)
            if t ~= "" then
                if past or not skip then out[#out + 1] = t end
                past = true
            end
        end
        return out
    end
    -- the time of day as the system writes it: 12-hour with AM/PM when the locale has them (`date +%p` says something), 24-hour when not
    local h24 = false
    run("date", { "+%p" }, function(out) h24 = tostring(out or ""):match("%S") == nil end)
    local function when(t)
        if t <= 0 then return "" end
        local now = os.time()
        if os.date("%Y%m%d", t) == os.date("%Y%m%d", now) then
            if h24 then return os.date("%H:%M", t) end
            return tonumber(os.date("%I", t)) .. os.date(":%M %p", t)
        end
        if now - t < 6 * 86400 then return os.date("%a", t) end
        return (os.date("%b %d", t):gsub(" 0", " "))
    end
    local function empty(n) return #body_of(n, false) == 0 end
    local function new_look()
        local prev = notes[1] and notes[1].c
        local c
        repeat c = math.random(0, 19) until not prev or c % 5 ~= prev % 5
        return c
    end
    local function render()
        local rows = {}
        for i, n in ipairs(notes) do
            local b = body_of(n, true)
            rows[i] = { title = title_of(n), sub = b[1] or "", body = table.concat(b, "\n"), when = when(n.t), c = n.c or 0 }
        end
        model.notes = rows
        fact.note_n = #notes
        fact.note_sel = sel
    end
    local function fill(n)
        loading = true
        for k = 0, LINES - 1 do text["nl." .. k] = n and n.lines[k + 1] or "" end
        after(50, function() loading = false end)
    end
    local function close_open()
        -- leaving a note: an empty one is not kept
        local n = sel >= 0 and notes[sel + 1]
        if n and empty(n) then table.remove(notes, sel + 1) end
        sel = -1
        fill(nil)
        save()
    end
    load()
    render()

    function desk_note_add(title, lines)
        if sel >= 0 then close_open() end
        local ls = { tostring(title or "") }
        for _, l in ipairs(lines or {}) do
            if #ls >= LINES then break end
            ls[#ls + 1] = tostring(l)
        end
        for k = #ls + 1, LINES do ls[k] = "" end
        table.insert(notes, 1, { lines = ls, t = os.time(), c = new_look() })
        while #notes > MAX do table.remove(notes) end
        save()
        render()
    end

    on("note_new", function()
        if sel >= 0 then close_open() end
        if #notes >= MAX then table.remove(notes) end
        local ls = {}
        for k = 1, LINES do ls[k] = "" end
        table.insert(notes, 1, { lines = ls, t = os.time(), c = new_look() })
        sel = 0
        fill(notes[1])
        text.desk_ai_msg = ""
        render()
    end)
    on("note_open", function(i)
        i = tonumber(i) or -1
        if sel >= 0 and sel ~= i then close_open() end
        if not notes[i + 1] then render(); return end
        sel = i
        fill(notes[i + 1])
        text.desk_ai_msg = ""
        render()
    end)
    on("note_back", function() close_open(); render() end)
    -- Home's board: a note carried to another place (from * 100 + to, both places in the list). The open one keeps being the open one.
    on("note_move", function(v)
        v = tonumber(v) or -1
        local from, to = math.floor(v / 100), v % 100
        if from == to or not notes[from + 1] or not notes[to + 1] then return end
        local open = sel >= 0 and notes[sel + 1] or nil
        local n = table.remove(notes, from + 1)
        table.insert(notes, to + 1, n)
        if open then for i, x in ipairs(notes) do if x == open then sel = i - 1 end end end
        save()
        render()
    end)
    on("note_del", function(i)
        i = tonumber(i) or -1
        if not notes[i + 1] then return end
        table.remove(notes, i + 1)
        if sel == i then sel = -1; fill(nil) elseif sel > i then sel = sel - 1 end
        save()
        render()
    end)
    local pending = false
    for k = 0, LINES - 1 do
        on("text:nl." .. k, function(v)
            if loading or sel < 0 or not notes[sel + 1] then return end
            local n = notes[sel + 1]
            n.lines[k + 1] = tostring(v or "")
            n.t = os.time()
            if not pending then
                pending = true
                after(600, function() pending = false; save(); render() end)
            end
        end)
    end
    -- What another tool added, and the file read again while no note is open (pages/desk_decl.plm: `desk_shown`).
    on("desk_shown", function() text.desk_ai_msg = ""; if sel < 0 then load(); render() end end)

    -- ── with the note open ──
    local function note_text(n) return table.concat(body_of(n, false), "\n") end
    on("note_sticky", function()
        local n = sel >= 0 and notes[sel + 1]
        if not n or not desk_sticky_new then return end
        desk_sticky_new(note_text(n))
        text.desk_ai_msg = "Copied to the desktop"
    end)
    on("note_ai", function(k)
        local n = sel >= 0 and notes[sel + 1]
        if not n then return end
        local mine = sel
        local ask = ({
            [0] = "Tidy this note: fix spelling and punctuation, keep its meaning and its lines. First line is the title. At most ten lines.",
            [1] = "Make this note shorter: keep the title as the first line and the important points, at most six lines.",
            [2] = "Continue this note with a few more lines in the same voice. Reply with only the new lines, at most four.",
        })[tonumber(k) or -1]
        if not ask then return end
        desk_llm_ask(ask .. "\n\n" .. note_text(n), function(t)
            if not t or sel ~= mine then return end
            local got = {}
            for line in (t .. "\n"):gmatch("([^\n]*)\n") do got[#got + 1] = line end
            if tonumber(k) == 2 then
                local last = 0
                for i, l in ipairs(n.lines) do if trim(l) ~= "" then last = i end end
                for _, l in ipairs(got) do
                    if trim(l) ~= "" and last < LINES then last = last + 1; n.lines[last] = trim(l) end
                end
            else
                local ls, i = {}, 0
                for _, l in ipairs(got) do if trim(l) ~= "" and i < LINES then i = i + 1; ls[i] = trim(l) end end
                if i == 0 then return end
                for j = i + 1, LINES do ls[j] = "" end
                n.lines = ls
            end
            n.t = os.time()
            fill(n)
            save()
            render()
        end)
    end)

end
