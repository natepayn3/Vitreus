-- The Desk's Ask tab: a small chat with whichever assistants are installed. Claude Code (`claude -p`, streamed), Ollama (its HTTP API through curl,
-- streamed) and, in the same way, Codex and Gemini. Each one is a program the logic spawns: nothing here talks to a network itself.
-- Claude is run with no tools, no MCP servers, no settings and nothing saved, so it is a plain chat and does not leave sessions behind.
-- The conversation and the choice of assistant are kept in desk-ask.json between sessions.
return function()
    local KEEP = 40                                   -- messages kept (and shown)
    local CONTEXT = 12                                -- how many of them an assistant is shown with the new one
    local NAMES = { "claude", "ollama", "codex", "gemini" }
    local LABELS = { "Claude", "Ollama", "Codex", "Gemini" }
    local SYSTEM = "You are a concise assistant in a small panel on the user's Linux desktop. Answer in plain text, no Markdown headings, short paragraphs; code goes in indented lines."
    local OLLAMA = "http://localhost:11434"

    local have = { false, false, false, false }
    local state = { backend = 1, model = "", history = {} }   -- backend: 1 claude, 2 ollama, 3 codex, 4 gemini
    local usage = nil                                 -- Claude's plan usage, as the last answer reported it: { u5, r5, u7, r7 } (fractions, and when each window resets)
    local models = {}
    local load_models                                 -- (below)
    local ollama_down = false                         -- `ollama list` could not talk to the server
    local proc = nil                                  -- the running answer, if any

    local function save()
        local h = {}
        for _, m in ipairs(state.history) do
            if m.role ~= "note" then h[#h + 1] = { role = m.role, text = m.text, who = m.who } end
        end
        pcall(sys.call, "files.write", "desk-ask.json", { backend = state.backend, model = state.model, history = h, usage = usage })
    end

    local function status()
        local b = state.backend
        if not (have[1] or have[2] or have[3] or have[4]) then
            text.ask_status = "No assistant found: install claude or ollama"
        elseif not have[b] then
            text.ask_status = LABELS[b] .. " is not installed"
        elseif b == 2 then
            text.ask_status = ollama_down and "Ollama's server is not running: start `ollama serve`"
                or state.model == "" and "no model yet: run `ollama pull llama3.2`"
                or (#models > 1 and ("model  " .. state.model .. "   (tap to change)") or ("model  " .. state.model .. "   (the only one installed)"))
        elseif b == 1 then
            text.ask_status = "Claude Code · plain chat, no tools, nothing saved"
        else
            text.ask_status = LABELS[b] .. " · one answer at a time"
        end
        fact.ask_nmodels = #models
        fact.ask_ok = have[b] == true and (b ~= 2 or state.model ~= "")
    end

    local render_waiting = false
    local function render()
        render_waiting = false
        local parts = {}
        for _, m in ipairs(state.history) do
            parts[#parts + 1] = (m.role == "user" and "You" or (m.who or "Assistant")) .. "\n" .. m.text
        end
        text.ask_log = table.concat(parts, "\n\n")
        fact.ask_n = #state.history
    end

    -- While an answer streams, the whole conversation is re-laid out for every token, which on a long one holds the painting up for a moment
    -- each time (and a key typed meanwhile shows late): so those updates are gathered, at most one every 80 ms.
    local function render_soon()
        if render_waiting then return end
        render_waiting = true
        after(80, function() if render_waiting then render() end end)
    end

    local function trim()
        while #state.history > KEEP do table.remove(state.history, 1) end
    end

    local function finish(mine)
        if proc ~= mine then return end
        proc = nil
        fact.ask_busy = false
        local last = state.history[#state.history]
        if last and last.role == "assistant" and last.text == "" then last.text = "(no answer)" end
        save()
        render()
    end

    local function append(mine, s)
        if proc ~= mine or type(s) ~= "string" or s == "" then return end
        local last = state.history[#state.history]
        if last and last.role == "assistant" then
            last.text = last.text .. s
            render_soon()
        end
    end

    local function fail(mine, msg)
        if proc ~= mine then return end
        local last = state.history[#state.history]
        if last and last.role == "assistant" then
            last.text = (last.text ~= "" and (last.text .. "\n\n") or "") .. "[" .. msg .. "]"
            render()
        end
    end

    -- Claude says how full its plan windows are (the five-hour and the seven-day) with every answer, and when each one resets: the page draws them
    -- as thin bars. A window whose reset time has passed is empty again, whatever was last said of it.
    local function clock(t, day)
        local f = day and "%a %I:%M %p" or "%I:%M %p"
        return (os.date(f, t):gsub("^0", ""):gsub(" 0(%d:)", " %1"))
    end
    local function show_usage()
        local now = os.time()
        local function one(u, r, day, fu, ft)
            if type(u) ~= "number" then fact[fu] = -1; text[ft] = ""; return end
            if type(r) == "number" and r <= now then u = 0 end
            fact[fu] = math.max(0, math.min(1, u))
            text[ft] = type(r) == "number" and ((r <= now and "reset " or "resets ") .. clock(r, day or r - now > 20 * 3600)) or ""
        end
        one(usage and usage.u5, usage and usage.r5, false, "ask_u5", "ask_r5")
        one(usage and usage.u7, usage and usage.r7, true, "ask_u7", "ask_r7")
    end
    local function take_usage(info)
        local w = type(info) == "table" and info.unifiedWindows
        if type(w) ~= "table" then return end
        usage = usage or {}
        local five, seven = w.five_hour, w.seven_day
        if type(five) == "table" and tonumber(five.utilization) then usage.u5, usage.r5 = tonumber(five.utilization), tonumber(five.resetsAt) end
        if type(seven) == "table" and tonumber(seven.utilization) then usage.u7, usage.r7 = tonumber(seven.utilization), tonumber(seven.resetsAt) end
        show_usage()
        save()
    end

    -- The conversation as one prompt, for the programs that take a prompt and keep nothing: the last few messages, then the new one.
    local function prompt_for(msgs)
        local out = {}
        for i = math.max(1, #msgs - CONTEXT), #msgs - 1 do
            local m = msgs[i]
            if m.role ~= "note" then out[#out + 1] = (m.role == "user" and "User: " or "Assistant: ") .. m.text end
        end
        local now = msgs[#msgs].text
        if #out == 0 then return now end
        return "Conversation so far:\n" .. table.concat(out, "\n") .. "\n\nNew message from the user:\n" .. now
    end

    local function run_claude(mine, msgs)
        local sawdelta = false
        local args = { "-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose", "--no-session-persistence",
                       "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "", "--append-system-prompt", SYSTEM }
        return spawn("claude", args, function(line)
            local ok, d = pcall(json.decode, line)
            if not ok or type(d) ~= "table" then return end
            if d.type == "stream_event" and type(d.event) == "table" and d.event.type == "content_block_delta"
               and type(d.event.delta) == "table" and d.event.delta.type == "text_delta" then
                sawdelta = true
                append(mine, d.event.delta.text)
            elseif d.type == "rate_limit_event" then
                take_usage(d.rate_limit_info)
            elseif d.type == "result" then
                if d.is_error then fail(mine, tostring(d.result or "claude failed"))
                elseif not sawdelta then append(mine, tostring(d.result or "")) end
            end
        end, function(_, code)
            if code ~= 0 and not sawdelta then fail(mine, "claude exited with " .. tostring(code)) end
            finish(mine)
        end, { input = prompt_for(msgs) })
    end

    local function run_ollama(mine, msgs)
        local m = { { role = "system", content = SYSTEM } }
        for i = math.max(1, #msgs - CONTEXT), #msgs do
            if msgs[i].role ~= "note" then m[#m + 1] = { role = msgs[i].role, content = msgs[i].text } end
        end
        local got = false
        return spawn("curl", { "-sN", "--max-time", "600", OLLAMA .. "/api/chat", "-d", "@-" }, function(line)
            local ok, d = pcall(json.decode, line)
            if not ok or type(d) ~= "table" then return end
            if d.error then fail(mine, tostring(d.error)) return end
            if type(d.message) == "table" and type(d.message.content) == "string" then
                got = true
                append(mine, d.message.content)
            end
        end, function(_, code)
            if code ~= 0 and not got then fail(mine, "can't reach Ollama: is `ollama serve` running?") end
            finish(mine)
        end, { input = json.encode({ model = state.model, stream = true, messages = m }) })
    end

    local function run_plain(mine, msgs, name)
        local p = prompt_for(msgs)
        local args = name == "codex" and { "exec", p } or { "-p", p }
        local first = true
        return spawn(name, args, function(line)
            append(mine, (first and "" or "\n") .. line)
            first = false
        end, function(_, code)
            if code ~= 0 then fail(mine, name .. " exited with " .. tostring(code)) end
            finish(mine)
        end)
    end

    local function ask(v)
        if type(v) ~= "string" then return end
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" or proc then return end
        for i = #state.history, 1, -1 do
            if state.history[i].role == "note" then table.remove(state.history, i) end
        end
        if fact.ask_ok ~= true then
            -- It cannot answer: say why in the conversation (not as part of it) and give the text back, so nothing is lost silently.
            local b = state.backend
            local why
            if not have[b] then why = LABELS[b] .. " is not installed."
            elseif b == 2 and ollama_down then why = "Ollama's server is not running. Start it with `ollama serve`, then try again."
            elseif b == 2 then why = "Ollama has no models yet. Run `ollama pull llama3.2` in a terminal, then try again."
            else why = LABELS[b] .. " can't answer right now." end
            table.insert(state.history, { role = "note", text = why, who = "Note" })
            text.ask_in = v
            render()
            if b == 2 and have[2] then load_models() end
            return
        end
        table.insert(state.history, { role = "user", text = v })
        table.insert(state.history, { role = "assistant", text = "", who = LABELS[state.backend] })
        trim()
        fact.ask_busy = true
        render()
        local msgs = {}
        for i = 1, #state.history - 1 do msgs[i] = state.history[i] end
        local mine = {}
        proc = mine
        local id
        if state.backend == 1 then id = run_claude(mine, msgs)
        elseif state.backend == 2 then id = run_ollama(mine, msgs)
        else id = run_plain(mine, msgs, NAMES[state.backend]) end
        mine.id = id
    end

    local function stop()
        local mine = proc
        if not mine then return end
        if mine.id then kill(mine.id) end
        fail(mine, "stopped")
        finish(mine)
    end

    local function pick(i)
        if type(i) ~= "number" then return end
        i = i + 1
        if i < 1 or i > 4 or not have[i] then return end
        state.backend = i
        fact.ask_backend = i - 1
        status()
        save()
    end

    load_models = function()
        run("ollama", { "list" }, function(out, code)
            models = {}
            ollama_down = code ~= 0
            if code == 0 and type(out) == "string" then
                local first = true
                for line in out:gmatch("[^\r\n]+") do
                    if first then first = false
                    else
                        local name = line:match("^(%S+)")
                        if name then models[#models + 1] = name end
                    end
                end
            end
            local found = false
            for _, n in ipairs(models) do if n == state.model then found = true end end
            if not found then state.model = models[1] or "" end
            status()
        end)
    end

    on("ask_pick", pick)
    on("ask_stop", stop)
    on("ask_new", function()
        stop()
        state.history = {}
        save()
        render()
    end)
    on("ask_cycle", function()
        if state.backend ~= 2 or #models == 0 then return end
        local at = 0
        for i, n in ipairs(models) do if n == state.model then at = i end end
        state.model = models[at % #models + 1]
        status()
        save()
    end)
    on("submit:ask_in", function(v)
        text.ask_in = ""
        ask(v)
    end)

    do
        local ok, saved = pcall(sys.ask, "files.read", "desk-ask.json", "json")
        if ok and type(saved) == "table" then
            if type(saved.backend) == "number" and saved.backend >= 1 and saved.backend <= 4 then state.backend = math.floor(saved.backend) end
            if type(saved.model) == "string" then state.model = saved.model end
            if type(saved.usage) == "table" then usage = { u5 = tonumber(saved.usage.u5), r5 = tonumber(saved.usage.r5), u7 = tonumber(saved.usage.u7), r7 = tonumber(saved.usage.r7) } end
            if type(saved.history) == "table" then
                for _, m in ipairs(saved.history) do
                    if type(m) == "table" and type(m.text) == "string" and (m.role == "user" or m.role == "assistant") then
                        state.history[#state.history + 1] = { role = m.role, text = m.text, who = type(m.who) == "string" and m.who or nil }
                    end
                end
                trim()
            end
        end
    end
    fact.ask_backend = state.backend - 1
    render()
    status()
    show_usage()
    every(60000, show_usage)
    local waiting = #NAMES
    for i, name in ipairs(NAMES) do
        run("which", { name }, function(_, code)
            have[i] = code == 0
            fact["ask_have." .. (i - 1)] = have[i]
            waiting = waiting - 1
            if waiting == 0 then
                if not have[state.backend] then
                    for j = 1, 4 do if have[j] then state.backend = j; break end end
                    fact.ask_backend = state.backend - 1
                end
                status()
                if have[2] then load_models() end
            end
        end)
    end
end
