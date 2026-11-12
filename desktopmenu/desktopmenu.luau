-- Hyprland only: a right press on the wallpaper opens the desktop editor (desktopedit/), started if it is not running (it leaves a while after it is closed:
-- see desktopedit.luau). Once started it is told to open as soon as it answers, not after a fixed wait.
local function open_when_up(mon, tries)
    run("pleamar", { "--say", "desktopedit", "fact emon " .. mon, "fact open true" }, function(out, code)
        local up = code == 0 and (out or ""):find("?", 1, true) ~= 1
        if not up and tries < 30 then after(300, function() open_when_up(mon, tries + 1) end) end
    end)
end
on("edit_req", function()
    local mon = math.floor((tonumber(fact.mmon) or 0) + 0.5)
    run("pleamar", { "--say", "desktopedit", "fact emon " .. mon, "fact open true" }, function(_, code)
        if code ~= 0 then
            run("sh", { "-c", 'PATH="$HOME/.local/bin:$PATH" vitreus-keep "$HOME/.config/pleamar/shells/vitreus/desktopedit/desktopedit.plm" >/dev/null 2>&1 &' }, function() end)
            open_when_up(mon, 0)
        end
    end)
end)
