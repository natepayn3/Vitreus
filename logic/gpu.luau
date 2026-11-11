-- Settings > Display > "Graphics card": on a laptop with an integrated and a discrete GPU, which of them draws the shell. pleamar
-- draws every scene on the integrated one unless it is started with PLEAMAR_GPU=high, which is the right choice for a light shell and
-- for a battery; a heavy one (full-screen glass at 1920 x 1080 and up) can need the discrete card, whose frames are then handed to the
-- compositor, which still shows them on whichever card drives the screen. The page is only there (`gpu_has`) when the machine has more
-- than one graphics card: the PCI devices of class 0x0300 (VGA) and 0x0302 (3D) are counted.
-- The choice is kept in gpu.json (`discrete`), in Vitreus's data folder, and it is bin/vitreus-keep that reads it, every time it starts the
-- shell, and sets PLEAMAR_GPU for it: so it takes the next start, and the page starts one (the same restart as the Bar page's, without
-- the desktop widgets, which draw on the integrated card whatever this says). Without gpu.json nothing is decided here and the shell
-- is drawn where it was started (PLEAMAR_GPU as the autostart line sets it, which `printenv` tells), so a setup from before is not changed.
return function(with_dirs)
    local G = { discrete = false, busy = false }
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
sleep 0.3
# under its keeper (bin/vitreus-keep), which starts it again by itself and reads gpu.json as it does; without one, started here
if command -v vitreus-keep >/dev/null 2>&1; then exec vitreus-keep "$P" "$L"; fi
if [ "$3" = high ]; then export PLEAMAR_GPU=high; else unset PLEAMAR_GPU; fi
S=$(head -n 1 "$(dirname "$L")/bar-screens" 2>/dev/null | tr -d ' \t')
if [ -n "$S" ]; then exec pleamar --scene "$P" --no-hud --screen "$S" >>"$L" 2>&1; fi
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]

    local function show()
        fact.gpu_dis = G.discrete
        text.gpu_note = G.busy and "Restarting the shell…"
            or (G.discrete and "Drawing on the discrete card. It stays awake: more power, more heat."
                or "Drawing on the integrated card. Lighter on the battery.")
    end

    on("gpu_toggle", function()
        if G.busy then return end
        G.busy = true
        G.discrete = not G.discrete
        pcall(sys.call, "files.write", "gpu.json", { discrete = G.discrete })
        show()
        with_dirs(function(d)
            run("setsid", { "-f", "sh", "-c", RESTART, "sh", d.conf .. "/vitreus.plm", d.data .. "/vitreus.log", G.discrete and "high" or "" }, function() end)
        end)
    end)

    -- More than one graphics card?
    run("find", { "-L", "/sys/bus/pci/devices", "-maxdepth", "2", "-name", "class", "-exec", "grep", "-l", "-E", "^0x03(00|02)", "{}", "+" }, function(out)
        local n = 0
        for _ in (out or ""):gmatch("[^\n]+") do n = n + 1 end
        if n > 1 then fact.gpu_has = true end
    end)

    -- What it is now: gpu.json if there is one, else how the shell was started.
    local ok, saved = pcall(sys.ask, "files.read", "gpu.json", "json")
    if ok and type(saved) == "table" and type(saved.discrete) == "boolean" then
        G.discrete = saved.discrete
        show()
    else
        show()
        run("printenv", { "PLEAMAR_GPU" }, function(out)
            if (out or ""):match("^%s*high") then
                G.discrete = true
                show()
            end
        end)
    end
end
