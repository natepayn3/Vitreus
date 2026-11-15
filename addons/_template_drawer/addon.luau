-- The logic of the drawer template: it keeps the number of presses in this add-on's own data folder (~/.local/share/pleamar/<the scene's name>/, which the `files` services
-- read and write by file name), so the dots are still lit after a restart. Delete it if your add-on needs no logic.
--
-- What else a logic can do:
--   local ok, folder = pcall(sys.ask, "files.folder")                 -- the data folder's path, for a program that needs it
--   run("wl-paste", { "--no-newline" }, function(out, code) ... end)   -- a program (it has to be in `permissions { run: ... }`); `out` is what it printed
--   on("some_event", function(arg) ... end)                            -- an `event some_event ->` of the scene, emitted from a rule with `emit some_event`
--   every(60000, function() ... end), after(500, function() ... end)  -- timers, in milliseconds
local ok, saved = pcall(sys.ask, "files.read", "state.json", "json")
if ok and type(saved) == "table" and type(saved.clicks) == "number" then fact.clicks = saved.clicks end
on("fact:clicks", function(v)
    pcall(sys.call, "files.write", "state.json", { clicks = tonumber(v) or 0 })
end)

-- The field (see the scene): the shell takes the keys for it. Where it is, from the top left of the content: 0 in from the left, 246 down, 36 tall, and 0 in from the
-- right edge (so it follows the panel's width). Told again each time the panel comes out: the shell forgets it when the panel shuts.
local function say_shell(cmds)
    local args = { "--say", "vitreus" }
    for _, c in ipairs(cmds) do args[#args + 1] = c end
    run("pleamar", args, function() end)
end
-- Which copy of this scene is on the panel's monitor: the one whose `screen.K.name` is the name the shell sent (`slot_mon`). None matching (the name not known
-- yet): the scene falls back to the monitor's size.
local function find_monitor()
    local name = text.slot_mon or ""
    local any = false
    for k = 0, 3 do
        local here = name ~= "" and text["screen." .. k .. ".name"] == name
        if fact["mon_c" .. k] ~= here then fact["mon_c" .. k] = here end
        any = any or here
    end
    if fact.mon_known ~= any then fact.mon_known = any end
end
local was_open = false
on("fact:slot_open", function(v)       -- (the shell says it again every two seconds while the panel is out: only its coming out counts)
    find_monitor()
    local now = v == true
    if now == was_open then return end
    was_open = now
    if now then say_shell({ "fact axf_l 0", "fact axf_t 246", "fact axf_r 0", "fact axf_h 36", "text axf_q ", "fact axf_on true" }) end
end)
on("field_enter", function()
    text.hello = text.field_q ~= "" and ("Hello, " .. text.field_q) or ""
    say_shell({ "text axf_q ", "emit axf_set" })      -- empty the field again
    text.field_q = ""
end)
