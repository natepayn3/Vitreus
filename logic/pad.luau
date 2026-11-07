-- Reminders: the short to-do list (nine lines) in the Desk's Notes (its Reminders side: it used to be the Pad's), kept in desk-tasks.json.
return function()
    local MAX = 9
    local items = {}                                    -- { text, done }
    local function save() pcall(sys.call, "files.write", "desk-tasks.json", { items = items }) end
    local function render()
        for k = 0, MAX - 1 do
            local it = items[k + 1]
            text["task." .. k .. ".text"] = it and it.text or ""
            fact["task." .. k .. ".has"] = it ~= nil
            fact["task." .. k .. ".done"] = it ~= nil and it.done == true
        end
        fact.task_n = #items
    end
    local function load()
        items = {}
        local ok, saved = pcall(sys.ask, "files.read", "desk-tasks.json", "json")
        if ok and type(saved) == "table" and type(saved.items) == "table" then
            for _, x in ipairs(saved.items) do
                if type(x) == "table" and type(x.text) == "string" and #items < MAX then
                    items[#items + 1] = { text = x.text, done = x.done == true }
                end
            end
        end
    end
    load()
    on("submit:task_in", function(v)
        local t = tostring(v or ""):match("^%s*(.-)%s*$")
        if t == "" or #items >= MAX then return end
        items[#items + 1] = { text = t, done = false }
        text.task_in = ""
        save()
        render()
    end)
    on("task_toggle", function(k)
        local it = type(k) == "number" and items[k + 1]
        if it then it.done = not it.done; save(); render() end
    end)
    local busy = false
    on("task_del", function(k)
        if busy or type(k) ~= "number" or not items[k + 1] then return end
        busy = true
        fact["task." .. k .. ".gone"] = true                -- the line slides off and fades; then it goes and the rest glide up
        after(200, function()
            table.remove(items, k + 1)
            save()
            fact["task." .. k .. ".gone"] = false
            render()
            emit("task_shifted", k)
            busy = false
        end)
    end)
    -- Tasks from elsewhere on the Desk (a note's lines, Home's `+` capture), as a global: the modules cannot hear each other's events.
    -- Returns how many fitted.
    function desk_tasks_add(list)
        local k = 0
        for _, t in ipairs(list or {}) do
            t = tostring(t or ""):match("^%s*(.-)%s*$")
            if t ~= "" and #items < MAX then items[#items + 1] = { text = t, done = false }; k = k + 1 end
        end
        if k > 0 then save(); render() end
        return k
    end
    -- Focus on a task: the Focus tab says which (`ft_task`) and, when the focus ends, offers to tick it off. Its words are remembered, not its
    -- place, so it is still the right one if others were ticked or deleted meanwhile.
    local focused = nil                                   -- the task's words (the list is read again from its file, so not the task itself)
    on("focus_task", function(k)
        local it = type(k) == "number" and items[k + 1]
        if not it then return end
        focused = it.text
        text.ft_task = it.text
        fact.ft_has_task = true
    end)
    on("focus_task_done", function()
        if focused then
            for _, it in ipairs(items) do
                if it.text == focused and not it.done then it.done = true; save(); render(); break end
            end
        end
        focused = nil
        text.ft_task = ""
        fact.ft_has_task = false
    end)
    on("ft_reset", function()
        focused = nil
        text.ft_task = ""
        fact.ft_has_task = false
    end)
    on("desk_shown", function() if not busy then load(); render() end end)
    render()
end
