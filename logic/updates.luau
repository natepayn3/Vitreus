-- The About page of the settings (System): the build this shell runs from, and how to update it. Vitreus is a git
-- checkout in its config folder, so its build is that commit plus pleamar's version. Checking is a `git fetch`,
-- updating is `git pull --ff-only` (it will not merge over changes of yours), and after it the shell is started again
-- the way the Bar page does it: a command left running on its own (`setsid`) that asks this one to quit and opens the
-- scene afresh. ssh is told not to ask for anything, so a fetch that needs a passphrase fails instead of hanging.
return function(key, with_dirs)
    local A = { busy = false, dir = nil, src = nil, shell_behind = 0, pl_behind = 0 }
    local PL_REPOS = { "pleamar", "pleamar-wm", "marea-plm" }
    local RESTART = [[
P="$1"; L="$2"
export PATH="$HOME/.local/bin:$PATH"
pleamar --say vitreus quit >/dev/null 2>&1
i=0
while pgrep -f "^pleamar --scene $P" >/dev/null && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
pkill -f "^pleamar --scene $P"
sleep 0.3
[ "$(stat -c %s "$L" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$L" "$L.1"
# under its keeper when there is one (bin/vitreus-keep): a keeper already looking after it starts it again itself
command -v vitreus-keep >/dev/null 2>&1 && exec vitreus-keep "$P" "$L"
exec pleamar --scene "$P" --no-hud >>"$L" 2>&1
]]
    local SSH = "core.sshCommand=ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

    local function busy(b, msg, patience)
        A.busy = b
        fact.about_busy = b
        if msg then text.about_msg = msg end
        -- A network command that hangs (a connection that stalls instead of failing, on a flaky network) must not leave the page
        -- busy for good, so after a while it lets go of it: the page is usable again, and a late answer only fills in its text.
        A.gen = (A.gen or 0) + 1
        if b then
            local mine = A.gen
            after(patience or 45000, function()
                if A.gen == mine and A.busy then
                    A.busy = false
                    fact.about_busy = false
                    text.about_msg = "That took too long and was given up on. Check the network and try again."
                end
            end)
        end
    end

    local function git(args, cb)
        local full = { "-C", A.dir, "-c", SSH }
        for _, a in ipairs(args) do full[#full + 1] = a end
        run("git", full, cb)
    end

    -- The same, in one of pleamar's source folders (the ones `pleamar-update` keeps).
    local function git_in(repo, args, cb)
        local full = { "-C", A.src .. "/" .. repo, "-c", SSH }
        for _, a in ipairs(args) do full[#full + 1] = a end
        run("git", full, cb)
    end

    local function lines(out)
        local t = {}
        for l in (out or ""):gmatch("[^\n]+") do t[#t + 1] = l end
        return t
    end

    -- This shell's commit, its branch, whether there is anything of yours not committed, and pleamar's version.
    local function read_build()
        git({ "log", "-1", "--format=%h%n%cd%n%s", "--date=format:%b %d, %Y" }, function(out, code)
            local l = lines(out)
            if code ~= 0 or #l < 3 then
                text.about_commit = "not a git checkout"
                text.about_date = ""
                text.about_sub = ""
                return
            end
            text.about_date = l[2]
            text.about_sub = l[3]
            git({ "rev-parse", "--abbrev-ref", "HEAD" }, function(b)
                local branch = lines(b)[1] or ""
                git({ "status", "--porcelain", "--untracked-files=no" }, function(st)
                    local dirty = #lines(st) > 0
                    text.about_commit = l[1] .. (branch ~= "" and (" · " .. branch) or "") .. (dirty and " · local changes" or "")
                end)
            end)
        end)
        run("pleamar", { "--version" }, function(out)
            text.about_pl = lines(out)[1] or "unknown"
        end)
    end

    local function check(after)
        if A.busy then return end
        busy(true, "Checking…")
        git({ "fetch", "--quiet" }, function(_, code)
            if code ~= 0 then
                fact.about_behind = -1
                return busy(false, "Couldn't reach the remote. Is there a network, and an ssh key that needs no passphrase?")
            end
            git({ "rev-list", "--count", "HEAD..@{u}" }, function(behind, c1)
                git({ "rev-list", "--count", "@{u}..HEAD" }, function(ahead, c2)
                    local n = tonumber(lines(behind)[1] or "")
                    local m = tonumber(lines(ahead)[1] or "") or 0
                    if c1 ~= 0 or n == nil then
                        fact.about_behind = -1
                        return busy(false, "This branch doesn't follow a remote one, so there is nothing to check.")
                    end
                    A.shell_behind = n
                    local msg
                    if n == 0 then msg = nil
                    elseif m > 0 then msg = n .. " new upstream, but you have " .. m .. " commit(s) of your own: update by hand."; A.shell_behind = 0
                    else msg = n == 1 and "1 shell update available." or (n .. " shell updates available.") end
                    -- Then pleamar itself: its source folders, fetched and counted the same way.
                    A.pl_behind = 0
                    local function repo(i)
                        local r = PL_REPOS[i]
                        if not r then
                            local total = A.shell_behind + A.pl_behind
                            fact.about_behind = total
                            local parts = {}
                            if msg then parts[#parts + 1] = msg end
                            if A.pl_behind > 0 then parts[#parts + 1] = "pleamar has " .. A.pl_behind .. " update" .. (A.pl_behind == 1 and "" or "s") .. "." end
                            busy(false, #parts > 0 and table.concat(parts, " ") or "Up to date.")
                            if after then after() end
                            return
                        end
                        git_in(r, { "fetch", "--quiet" }, function(_, fc)
                            if fc ~= 0 then return repo(i + 1) end
                            git_in(r, { "rev-list", "--count", "HEAD..@{u}" }, function(o, rc)
                                local k = tonumber(lines(o)[1] or "")
                                if rc == 0 and k then A.pl_behind = A.pl_behind + k end
                                repo(i + 1)
                            end)
                        end)
                    end
                    repo(1)
                end)
            end)
        end)
    end

    local function restart()
        with_dirs(function(d)
            text.about_msg = "Restarting…"
            fact.about_busy = true
            run("setsid", { "-f", "sh", "-c", RESTART, "sh", d.conf .. "/vitreus.plm", d.data .. "/vitreus.log" }, function() end)
        end)
    end

    on("about_check", function() check() end)
    -- Restart does not wait for a check or an update to finish (or to hang): it is the way out of one, and it only guards
    -- against being pressed twice.
    on("about_restart", function()
        if A.restarting then return end
        A.restarting = true
        fact.about_restarting = true
        restart()
    end)
    on("about_update", function()
        if A.busy or (fact.about_behind or 0) <= 0 then return end
        -- Vitreus first, then pleamar (`pleamar-update` pulls its source and builds it, which takes minutes): the shell
        -- is only started again once both are in place.
        local function pleamar_then_restart()
            if A.pl_behind <= 0 then return restart() end
            busy(true, "Updating pleamar: building it, this takes a few minutes…", 1800000)
            run("pleamar-update", {}, function(_, code)
                if code ~= 0 then
                    return busy(false, "Couldn't update pleamar. Try `pleamar-update` in a terminal to see why.")
                end
                A.pl_behind = 0
                restart()
            end)
        end
        busy(true, "Updating…")
        if A.shell_behind <= 0 then return pleamar_then_restart() end
        -- Which monitors show the bar and the lock screen is kept in the `screens:` line of each scene (the Bar and Lock
        -- screen pages write it, and the choice itself is in bar.json / the lock screen's settings). A line changed that way
        -- is a change of the working tree, and git will not pull over a file it finds changed. So the stock lines are put
        -- back for the pull and the chosen ones written again after it, which is what install.sh does too.
        local BAR_FILE, LOCK_FILE = "/vitreus.plm", "/lockscreen/lockscreen.plm"
        local function screens_in(src, which)
            for line in (src or ""):gmatch("[^\n]+") do
                if which == "bar" then
                    if line:match("^    surface {") then return line:match("screens:%s*([^;]*);") end
                else
                    local v = line:match("^        screens:%s*(.-)%s*$")
                    if v then return v end
                end
            end
        end
        local function plausible(v) return type(v) == "string" and v ~= "" and v:match('^[%w%._%-", ]+$') ~= nil end
        local function write_screens(bar, lock, cb)
            local steps = {}
            if plausible(bar) then
                steps[#steps + 1] = { "-i", "-E", "/^    surface \\{/s/screens: [^;]*;/screens: " .. bar .. ";/", A.dir .. BAR_FILE }
            end
            if plausible(lock) then
                steps[#steps + 1] = { "-i", "-E", "/^        screens: /s/screens: .*/screens: " .. lock .. "/", A.dir .. LOCK_FILE }
            end
            local function nxt(i)
                if not steps[i] then return cb() end
                run("sed", steps[i], function() nxt(i + 1) end)
            end
            nxt(1)
        end
        local function read_file(rel, cb) run("grep", { "-s", "", A.dir .. rel }, function(out) cb(out or "") end) end
        read_file(BAR_FILE, function(bar_now)
            read_file(LOCK_FILE, function(lock_now)
                git({ "show", "HEAD:vitreus.plm" }, function(bar_head)
                    git({ "show", "HEAD:lockscreen/lockscreen.plm" }, function(lock_head)
                        local bar_mine, lock_mine = screens_in(bar_now, "bar"), screens_in(lock_now, "lock")
                        local bar_stock, lock_stock = screens_in(bar_head, "bar"), screens_in(lock_head, "lock")
                        local bar_changed = bar_mine ~= nil and bar_stock ~= nil and bar_mine ~= bar_stock
                        local lock_changed = lock_mine ~= nil and lock_stock ~= nil and lock_mine ~= lock_stock
                        write_screens(bar_changed and bar_stock or nil, lock_changed and lock_stock or nil, function()
                            git({ "pull", "--ff-only", "--quiet" }, function(_, code)
                                write_screens(bar_changed and bar_mine or nil, lock_changed and lock_mine or nil, function()
                                    if code ~= 0 then
                                        return busy(false, "Couldn't update: something of yours is in the way. Try `git pull` in the shell's folder.")
                                    end
                                    pleamar_then_restart()
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)

    with_dirs(function(d)
        A.dir = d.conf
        A.src = (d.data:gsub("/vitreus$", "/src"))
        read_build()
    end)
end
