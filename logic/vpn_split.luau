-- Settings > Network > Skip the VPN (pages/vpn.plm): sites and apps whose traffic goes out the ordinary connection while a VPN is up.
--
-- The routing is root's and lives in bin/vitreus-vpn-split and bin/vitreus-vpn-split-daemon: a one-time setup (Set up, which asks the password)
-- installs root-owned copies that load the list each time it is saved and whenever a VPN or the network comes or goes. The daemon moves a listed
-- app's programs out of the VPN the moment they start, however they were started, and follows a listed site's addresses (and the names under it)
-- as name servers give them. This only writes the list, the data file vpn-split.conf, one entry a line:
--
--   on 1|0                  the switch
--   site DOMAIN             a site and every name under it, or an address or a range (10.0.0.0/8)
--   app ID NAME…            an installed app by its .desktop id, and the names its running programs have
--
-- Nothing here runs on a timer: the line under the switch is asked when the page opens and after a change.
return function()
    local MAX = 10
    local S = { on = false, ready = 0, items = {}, apps = {}, busy = false, state = nil, best = nil, note = nil }

    local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    local function busy(v) S.busy = v; fact.vs_busy = v end

    local function load()
        local ok, txt = pcall(sys.ask, "files.read", "vpn-split.conf")
        S.items = {}
        S.on = false
        if not ok or type(txt) ~= "string" then return end
        for line in txt:gmatch("[^\n]+") do
            local k, rest = line:match("^(%S+)%s*(.*)$")
            if k == "on" then S.on = rest == "1"
            elseif k == "site" and rest ~= "" then S.items[#S.items + 1] = { app = false, key = rest:match("^%S+") }
            elseif k == "app" then
                local id, names = rest:match("^(%S+)%s*(.*)$")
                if id then S.items[#S.items + 1] = { app = true, key = id, names = names or "" } end
            end
        end
    end
    local function save()
        local out = { "# Vitreus: sites and apps that skip the VPN (Settings > Network). Written by the shell.", "on " .. (S.on and "1" or "0") }
        for _, it in ipairs(S.items) do
            if it.app then out[#out + 1] = "app " .. it.key .. " " .. (it.names or "")
            else out[#out + 1] = "site " .. it.key end
        end
        pcall(sys.call, "files.write", "vpn-split.conf", table.concat(out, "\n") .. "\n")
    end

    local function app_by_id(id)
        for _, a in ipairs(S.apps) do if a.id == id then return a end end
        return nil
    end
    local function app_label(it)
        local a = app_by_id(it.key)
        return (a and a.name) or (it.key:gsub("%.desktop$", ""))
    end

    local function render()
        local st = S.state or {}
        local running = tonumber(st.apps or "") or 0
        for i = 0, MAX - 1 do
            local it = S.items[i + 1]
            fact["vs_r." .. i .. ".on"] = it ~= nil
            if it then
                fact["vs_r." .. i .. ".app"] = it.app
                text["vs_r." .. i .. ".name"] = it.app and app_label(it) or it.key
            end
        end
        fact.vs_count = math.min(#S.items, MAX)
        fact.vs_ready = S.ready
        fact.vs_on = S.on
        local hint
        if S.note then hint = S.note
        elseif S.ready == 0 then hint = "Needs a one-time setup: it asks your password"
        elseif S.ready == 2 then hint = "Needs an update: press Update (it asks your password)"
        elseif not S.on then hint = "Off: everything goes through the VPN"
        elseif #S.items == 0 then hint = "On: add a site or an app below"
        elseif st.fail == "1" or (st.watch == "0" and st.on == "1") then hint = "It is not working: press Update"
        elseif st.vpn == "0" then hint = "On: nothing runs until a VPN connects"
        elseif st.on == "1" then
            hint = "Going around it through " .. ((st.dev and st.dev ~= "") and st.dev or "the ordinary connection")
            if running > 0 then hint = hint .. string.format(" · %d program%s", running, running == 1 and "" or "s") end
        else hint = "On: waiting for the network" end
        text.vs_hint = hint
    end
    local function say(msg, ms)
        S.note = msg
        render()
        if msg and ms then
            local m = msg
            after(ms, function() if S.note == m then S.note = nil; render() end end)
        end
    end

    local function status()
        run("vitreus-vpn-split", { "status" }, function(out, code)
            if code ~= 0 and (out or "") == "" then S.ready = 0; render(); return end
            local f = {}
            for k, v in (out or ""):gmatch("(%w+)=([^\n]*)") do f[k] = v end
            S.ready = tonumber(f.ready) or 0
            S.state = { on = f.on, dev = f.dev, apps = f.apps, fail = f.fail, watch = f.watch, vpn = f.vpn }
            render()
        end)
    end

    -- ── the app field: the installed app a few letters name ──────────────────────────────────────────────
    local function best(q)
        q = trim(q):lower()
        if q == "" then return nil end
        local pick, score = nil, 0
        for _, a in ipairs(S.apps) do
            local n = (a.name or ""):lower()
            local id = (a.id or ""):lower()
            local s = 0
            if n == q then s = 4 elseif n:sub(1, #q) == q then s = 3 elseif n:find(q, 1, true) then s = 2 elseif id:find(q, 1, true) then s = 1 end
            if s > score then pick, score = a, s end
        end
        return pick
    end
    -- the names its running programs have: the program its Exec line starts (past `env`, VAR=x and a path), and its window class
    local function names_of(a)
        local seen, out = {}, {}
        local function add(n)
            n = (n or ""):match("([^/]+)$")
            if n and n:match("^[%w%._+-]+$") and not seen[n] then seen[n] = true; out[#out + 1] = n end
        end
        local words = {}
        for w in (a.exec or ""):gsub('"', ""):gmatch("%S+") do words[#words + 1] = w end
        local i = 1
        while words[i] and (words[i] == "env" or words[i]:find("=", 1, true) or words[i]:sub(1, 1) == "-") do i = i + 1 end
        if words[i] == "flatpak" then
            -- (a flatpak's programs have its own names: the id's last part is the usual one)
            local id = words[#words]
            for w = i, #words do if words[w]:match("^%a[%w_-]*%.[%w_.-]+$") then id = words[w]; break end end
            local last = (id or ""):match("([^.]+)$")
            add(last)
            add(last and last:lower())
        else
            add(words[i])
        end
        if a.wmclass and a.wmclass ~= "" then add(a.wmclass:lower()) end
        return table.concat(out, " ")
    end

    on("text:vs_app", function(v)
        S.best = best(v)
        text.vs_app_hint = S.best and S.best.name or (trim(v) ~= "" and "no such app" or "")
        fact.vs_app_ok = S.best ~= nil
    end)

    local function has(app, key)
        for _, it in ipairs(S.items) do if it.app == app and it.key == key then return true end end
        return false
    end
    local function changed()
        save()
        render()
        after(2500, status)        -- (the rules load a moment after the list is saved)
    end

    on("vs_add_site", function()
        local s = trim(text.vs_site):lower()
        s = s:gsub("^%a+://", ""):gsub("[/?#].*$", ""):gsub(":%d+$", ""):gsub("^www%.", "")
        if s == "" then return say("Type a site, like netflix.com", 4000) end
        local ip = s:match("^%d+%.%d+%.%d+%.%d+$") or s:match("^%d+%.%d+%.%d+%.%d+/%d+$") or s:match("^[%x:]+:[%x:.]*$") or s:match("^[%x:]+:[%x:.]*/%d+$")
        if not ip and not s:match("^[%w-]+%.[%w.-]+$") then return say("That does not look like a site: " .. s, 5000) end
        if has(false, s) then text.vs_site = ""; return say(s .. " is on the list already", 3000) end
        if #S.items >= MAX then return say("The list is full: remove one first", 4000) end
        S.items[#S.items + 1] = { app = false, key = s }
        text.vs_site = ""
        changed()
    end)
    on("vs_add_app", function()
        local a = S.best or best(text.vs_app)
        if not a then return say("Type the name of an installed app", 4000) end
        if has(true, a.id) then text.vs_app = ""; text.vs_app_hint = ""; return say((a.name or a.id) .. " is on the list already", 3000) end
        if #S.items >= MAX then return say("The list is full: remove one first", 4000) end
        S.items[#S.items + 1] = { app = true, key = a.id, names = names_of(a) }
        text.vs_app = ""
        text.vs_app_hint = ""
        S.best = nil
        changed()
        say((a.name or a.id) .. " skips the VPN: what it opens from now on goes around it", 5000)
    end)
    on("vs_del", function(i)
        local k = math.floor((tonumber(i) or -1) + 0.5) + 1
        if not S.items[k] then return end
        table.remove(S.items, k)
        changed()
    end)
    on("vs_toggle", function()
        if S.ready ~= 1 then return end
        S.on = not S.on
        changed()
    end)
    on("vs_setup", function()
        busy(true)
        say("Setting up: type your password in the box that opens")
        run("vitreus-vpn-split", { "setup" }, function(out, code)
            busy(false)
            if code == 126 then say("Not set up: the password was cancelled", 5000)
            elseif code == 127 then say("Not set up: the password was not accepted, or no password box could open", 6000)
            elseif code ~= 0 then
                local last = trim((out or ""):match("([^\n]*)%s*$"))
                say("Not set up: " .. (last ~= "" and last or ("failed with code " .. tostring(code))), 6000)
            else
                S.note = nil
                if not S.on then S.on = true end
                save()
            end
            status()
        end, { errors = true })
    end)

    sys.watch("apps", function(list)
        S.apps = list or {}
        render()
    end)

    on("fact:set_page", function(v) if v == "pg_vpn" then load(); status() end end)
    load()
    render()
    after(2000, status)
end
