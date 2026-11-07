-- The Desk's local AI: whatever Ollama has installed, nothing else. It is only ever asked when the person presses an AI button, and it never
-- runs anything itself: what it writes is shown to be read (a note's new lines, the tasks it picked out).
-- `desk_ai` (and `desk_ai_have`) is whether Ollama answers with at least one model: there is no switch of its own, Ask's choice of
-- assistant is the one place that says which AI is used. The model is the one Ask uses with Ollama, if it has one, else the first installed.
-- Shared with the other Desk modules as global functions (they cannot hear each other's events): `desk_llm_ask(prompt, done)` calls
-- done(text) or done(nil, why); `desk_llm_check()` looks again.
return function()
    local OLLAMA = "http://localhost:11434"
    local SYSTEM = "You help inside a small panel on the user's Linux desktop. Answer with only what was asked for: no preamble, no Markdown, no quotes round it."
    local model = ""
    local checked = 0
    local busy = false
    local function set_state()
        fact.desk_ai_have = model ~= ""
        fact.desk_ai = model ~= ""
        text.desk_ai_model = model
    end
    function desk_llm_check(force)
        local now = os.time()
        if not force and now - checked < 30 then return end
        checked = now
        run("curl", { "-s", "--max-time", "2", OLLAMA .. "/api/tags" }, function(out, code)
            local names = {}
            if code == 0 then
                local ok, d = pcall(json.decode, out or "")
                if ok and type(d) == "table" and type(d.models) == "table" then
                    for _, m in ipairs(d.models) do
                        if type(m) == "table" and type(m.name) == "string" then names[#names + 1] = m.name end
                    end
                end
            end
            local pick = names[1] or ""
            -- Ask's own choice, when it talks to Ollama and that model is still there
            local ok, a = pcall(sys.ask, "files.read", "desk-ask.json", "json")
            if ok and type(a) == "table" and a.backend == 2 and type(a.model) == "string" then
                for _, n in ipairs(names) do if n == a.model then pick = n end end
            end
            model = pick
            set_state()
        end)
    end
    function desk_llm_on() return fact.desk_ai == true and model ~= "" end
    function desk_llm_ask(prompt, done)
        if busy then done(nil, "Still working on the last one"); return end
        if not desk_llm_on() then done(nil, "The local AI is off"); return end
        busy = true
        fact.desk_ai_busy = true
        text.desk_ai_msg = model .. " is writing…"
        run("curl", { "-s", "--max-time", "180", OLLAMA .. "/api/generate", "-d", "@-" }, function(out, code)
            busy = false
            fact.desk_ai_busy = false
            local ok, d = pcall(json.decode, out or "")
            if code ~= 0 or not ok or type(d) ~= "table" or type(d.response) ~= "string" then
                text.desk_ai_msg = "Ollama did not answer"
                done(nil, "Ollama did not answer")
                return
            end
            text.desk_ai_msg = ""
            local t = d.response:gsub("<think>.-</think>", ""):gsub("^%s+", ""):gsub("%s+$", "")
            done(t)
        end, { input = json.encode({ model = model, prompt = prompt, system = SYSTEM, stream = false }) })
    end
    set_state()
    desk_llm_check(true)
end
