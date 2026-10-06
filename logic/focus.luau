-- Focus: the timer in the desk's Focus tab (the panel out of the right frame). `ft_state` is 0 ready, 1 running, 2 paused, 3 done;
-- `ft_prog` is the fraction left (the ring), `ft_time` the clock. Starting also silences notifications and keeps the machine awake
-- for that long: the scene sends those two (`dnd_for`, `caf_for`) itself when its switches are on. The end is kept as a time, not a
-- count of ticks, so a busy moment does not make it run long.
return function()
    local total, left, state, ends = 30 * 60, 30 * 60, 0, 0
    local function show()
        text.ft_time = string.format("%02d:%02d", math.floor(left / 60), left % 60)
        fact.ft_prog = total > 0 and left / total or 1
        fact.ft_state = state
    end
    on("ft_set", function(m)
        if (state == 0 or state == 3) and type(m) == "number" and m > 0 then
            total, left, state = m * 60, m * 60, 0
            show()
        end
    end)
    on("ft_toggle", function(m)
        if state == 1 then
            left = math.max(0, ends - os.time())
            state = 2
        elseif state == 2 then
            ends = os.time() + left
            state = 1
        elseif type(m) == "number" and m > 0 then
            total, left = m * 60, m * 60
            ends = os.time() + left
            state = 1
        end
        show()
    end)
    on("ft_reset", function(m)
        state = 0
        if type(m) == "number" and m > 0 then total = m * 60 end
        left = total
        show()
    end)
    every(1000, function()
        if state ~= 1 then return end
        left = math.max(0, ends - os.time())
        if left == 0 then
            state = 3
            pcall(run, "notify-send", { "-a", "Focus", "Focus finished", "Time for a break" }, function() end)
        end
        show()
    end)
    show()
end
