-- Settings > Style: how the shell's hand-drawn pencil is drawn (pages/style.plm), kept in style.json. Four steps, 0 to 3 each, 2 the stock look:
-- boil (how often lines redraw), wobble (how crooked), echo (the faint second stroke) and shade (how strong the fill is), and the fill itself, 0 to 4:
-- Pencil (hatching), Marker, Gradient, Plain, Dots. A preset sets the line's three (boil, wobble, echo); the fill and its strength are left as they are.
return function()
    local O = { boil = 2, wobble = 2, echo = 2, shade = 2, fill = 0 }
    local PRESETS = {
        [0] = { boil = 2, wobble = 2, echo = 2 },   -- Sketch: the stock pencil
        [1] = { boil = 0, wobble = 2, echo = 2 },   -- Steady: held still
        [2] = { boil = 3, wobble = 3, echo = 3 },   -- Lively
        [3] = { boil = 0, wobble = 1, echo = 0 },   -- Ink
        [4] = { boil = 0, wobble = 0, echo = 0 },   -- Clean
    }

    local function show()
        fact.pn_boil_i = O.boil
        fact.pn_wob_i = O.wobble
        fact.pn_echo_i = O.echo
        fact.pn_shade_i = O.shade
        fact.pn_fill_i = O.fill
        -- Files draws its thumbs with the same fill: tell it (it asks again itself when it starts)
        run("pleamar", { "--say", "files", "fact pn_fill_i " .. O.fill }, function() end)
        run("pleamar", { "--say", "files", "fact pn_shade_i " .. O.shade }, function() end)
    end
    local function save() pcall(sys.call, "files.write", "style.json", O) end

    local ok, saved = pcall(sys.ask, "files.read", "style.json", "json")
    if ok and type(saved) == "table" then
        for k in pairs(O) do
            local v = saved[k]
            if type(v) == "number" and v >= 0 and v <= (k == "fill" and 4 or 3) then O[k] = math.floor(v) end
        end
    end
    show()

    local function pick(key, n, hi)
        n = math.floor(tonumber(n) or -1)
        if n < 0 or n > (hi or 3) then return end
        O[key] = n
        show(); save()
    end
    on("pn_pick_boil", function(n) pick("boil", n) end)
    on("pn_pick_wobble", function(n) pick("wobble", n) end)
    on("pn_pick_echo", function(n) pick("echo", n) end)
    on("pn_pick_shade", function(n) pick("shade", n) end)
    on("pn_pick_fill", function(n) pick("fill", n, 4) end)
    on("pn_pick_preset", function(n)
        local p = PRESETS[math.floor(tonumber(n) or -1)]
        if not p then return end
        for k, v in pairs(p) do O[k] = v end
        show(); save()
    end)
end
