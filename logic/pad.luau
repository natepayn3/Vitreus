-- Pad: a short task list (nine lines) in the desk's Pad tab, kept in desk-tasks.json.
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
    do
        local ok, saved = pcall(sys.ask, "files.read", "desk-tasks.json", "json")
        if ok and type(saved) == "table" and type(saved.items) == "table" then
            for _, x in ipairs(saved.items) do
                if type(x) == "table" and type(x.text) == "string" and #items < MAX then
                    items[#items + 1] = { text = x.text, done = x.done == true }
                end
            end
        end
    end
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
    render()
end
