-- The privacy lights on the bar: which apps are using the microphone or the camera, and whether the screen is being shared.
--
-- Microphone: PipeWire's recording streams (`pactl -f json list source-outputs`), leaving out the ones that record an output's monitor
-- (that is how this shell's own spectrum, cava, listens) and the ones that are paused. Camera: who has a /dev/video* open (`fuser`), named
-- with `ps`. Both are read every two seconds. The screen: Hyprland says it itself (`screencast>>1,…` on its event socket), and vitreus.luau's
-- listener on that socket sets `priv_scr` itself; that one is at once.
return function()
    local videos = {}                                  -- /dev/video0, /dev/video1, … (read once: a camera plugged in later shows after a restart)
    local busy = false

    local function names(list)
        local seen, out = {}, {}
        for _, n in ipairs(list) do
            if n ~= "" and not seen[n] then seen[n] = true; out[#out + 1] = n end
        end
        return out
    end
    local function who(list, what)
        if #list == 0 then return "" end
        local s = list[1]
        if #list == 2 then s = list[1] .. " and " .. list[2] elseif #list > 2 then s = list[1] .. " and " .. (#list - 1) .. " others" end
        return s .. (#list == 1 and " is using " or " are using ") .. what
    end

    local function check_mic(done)
        run("pactl", { "-f", "json", "list", "sources" }, function(src_out, c1)
            if c1 ~= 0 then return done() end
            local ok, sources = pcall(json.decode, src_out or "")
            if not ok or type(sources) ~= "table" then return done() end
            local monitor = {}
            for _, s in ipairs(sources) do
                if type(s) == "table" and type(s.name) == "string" and s.name:find("%.monitor$") then monitor[s.index] = true end
            end
            run("pactl", { "-f", "json", "list", "source-outputs" }, function(out, c2)
                local apps = {}
                if c2 == 0 then
                    local ok2, outs = pcall(json.decode, out or "")
                    if ok2 and type(outs) == "table" then
                        for _, o in ipairs(outs) do
                            if type(o) == "table" and not monitor[o.source] and o.corked ~= true then
                                local p = type(o.properties) == "table" and o.properties or {}
                                apps[#apps + 1] = tostring(p["application.name"] or p["application.process.binary"] or "An app")
                            end
                        end
                    end
                end
                apps = names(apps)
                fact.priv_mic = #apps > 0
                text.priv_mic_who = who(apps, "your microphone")
                done()
            end)
        end)
    end

    local function check_cam(done)
        if #videos == 0 then fact.priv_cam = false; text.priv_cam_who = ""; return done() end
        run("fuser", videos, function(out)
            local pids = {}
            for pid in (out or ""):gmatch("%d+") do pids[#pids + 1] = pid end
            if #pids == 0 then
                fact.priv_cam = false
                text.priv_cam_who = ""
                return done()
            end
            run("ps", { "-o", "comm=", "-p", table.concat(pids, ",") }, function(o2)
                local apps = {}
                for line in (o2 or ""):gmatch("[^\n]+") do apps[#apps + 1] = (line:gsub("^%s+", ""):gsub("%s+$", "")) end
                apps = names(apps)
                fact.priv_cam = true
                text.priv_cam_who = who(#apps > 0 and apps or { "An app" }, "your camera")
                done()
            end)
        end)
    end

    local function tick()
        if busy then return end
        busy = true
        check_mic(function() check_cam(function() busy = false end) end)
    end

    run("ls", { "/dev" }, function(out)
        for n in (out or ""):gmatch("[^\n]+") do
            if n:match("^video%d+$") then videos[#videos + 1] = "/dev/" .. n end
        end
        tick()
    end)
    every(2000, tick)

end
