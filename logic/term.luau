-- The Desk's Term tab. The terminal itself is pleamar's own element (`terminal term`, in pages/desk.plm): a real shell in its own pty,
-- drawn by the scene, with its own mouse, selection, history and keyboard. The shell lives while `term_wanted` holds (set when the tab is
-- first shown). All this logic does is start a new shell after one ended, and type Home's AUR update into it.
return function(key)
    on("term_restart", function()
        fact.term_wanted = false
        after(120, function() fact.term_wanted = true end)
    end)
    -- Home's AUR card: the update typed into the shell and Enter pressed, as you would (the helper asks for your password and what to do).
    -- A terminal that is not running yet is started first, and given a moment for its prompt.
    on("aur_update", function()
        local cmd = desk_aur_cmd and desk_aur_cmd() or "paru -Sua"
        local fresh = fact.term_wanted ~= true or fact["term.alive"] == 0
        if fresh then fact.term_wanted = true end
        after(fresh and 900 or 0, function() sys.call("terminal.write", "term", cmd .. "\r") end)
    end)
end
