-- The Desk's Home (pages/desk_home.plm) and the tablet round it: your title and line, which tools the dock shows and in what order, which one
-- the Desk opens on, and whether the local AI is on, all kept in desk-home.json.
return function()
    local TOOLS = { 7, 0, 1, 2, 3, 4, 5, 8 }            -- the dock's tools, in their first order: Notes, Pad, Shelf, Clip, Focus, Term, Ask, Camera
    local st = { title = "", line = "", order = {}, off = {}, start = 6, ai = true }
    local function save()
        pcall(sys.call, "files.write", "desk-home.json", { title = st.title, line = st.line, order = st.order, off = st.off, start = st.start, ai = st.ai })
    end
    local function render()
        local n = 0
        for s = 0, #TOOLS - 1 do
            local id = st.order[s + 1]
            local on = not st.off[tostring(id)]
            fact["dk." .. s .. ".id"] = id
            fact["dk." .. s .. ".on"] = on
            fact["dk." .. s .. ".x"] = n
            if on then n = n + 1 end
        end
        fact.dk_n = n
        fact.desk_start = st.start
        text.desk_title = st.title ~= "" and st.title or "My Desk"
    end
    do
        local ok, s = pcall(sys.ask, "files.read", "desk-home.json", "json")
        if ok and type(s) == "table" then
            if type(s.title) == "string" then st.title = s.title end
            if type(s.line) == "string" then st.line = s.line end
            if type(s.start) == "number" then st.start = s.start end
            if type(s.ai) == "boolean" then st.ai = s.ai end
            if type(s.off) == "table" then for k, v in pairs(s.off) do if v == true then st.off[tostring(k)] = true end end end
            -- the saved order, keeping only tools there are and adding any it does not have (a new one, in a later version)
            if type(s.order) == "table" then
                local seen = {}
                for _, id in ipairs(s.order) do
                    for _, t in ipairs(TOOLS) do
                        if t == id and not seen[id] then st.order[#st.order + 1] = id; seen[id] = true end
                    end
                end
                for _, t in ipairs(TOOLS) do if not seen[t] then st.order[#st.order + 1] = t end end
            end
        end
        if #st.order ~= #TOOLS then st.order = { table.unpack(TOOLS) } end
        local known = st.start == 6
        for _, t in ipairs(TOOLS) do if t == st.start then known = true end end
        if not known or (st.start ~= 6 and st.off[tostring(st.start)]) then st.start = 6 end
    end
    text.desk_title_in = st.title
    text.desk_line_in = st.line
    render()

    local pending = false
    local function save_soon()
        if pending then return end
        pending = true
        after(700, function() pending = false; save() end)
    end
    on("text:desk_title_in", function(v)
        st.title = tostring(v or "")
        text.desk_title = st.title ~= "" and st.title or "My Desk"
        save_soon()
    end)
    on("text:desk_line_in", function(v) st.line = tostring(v or ""); save_soon() end)
    on("dk_move", function(v)
        v = tonumber(v) or -1
        local s, dir = math.floor(v / 10), v % 10
        local j = dir == 0 and s - 1 or s + 1
        if s < 0 or s > #TOOLS - 1 or j < 0 or j > #TOOLS - 1 then return end
        st.order[s + 1], st.order[j + 1] = st.order[j + 1], st.order[s + 1]
        save(); render()
    end)
    on("dk_toggle", function(s)
        local id = st.order[(tonumber(s) or -1) + 1]
        if not id then return end
        local k = tostring(id)
        if st.off[k] then st.off[k] = nil else st.off[k] = true end
        if st.off[k] and st.start == id then st.start = 6 end
        save(); render()
    end)
    on("desk_start_set", function(id)
        id = tonumber(id)
        if not id or (id ~= 6 and st.off[tostring(id)]) then return end
        st.start = id
        save(); render()
    end)
    on("desk_shown", function()
        if desk_llm_check then desk_llm_check(false) end
    end)
end
