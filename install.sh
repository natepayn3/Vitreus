#!/bin/sh
# Vitreus: install it, keep it up to date, take it away. One script for all.
#
#   curl -fsSL https://raw.githubusercontent.com/natepayn3/Vitreus/main/install.sh | sh
#   ./install.sh                   install (or, if it is there, update)
#   ./install.sh --yes             don't ask anything: answer yes to everything
#   ./install.sh --dry-run         say what it would do, and do nothing
#   ./install.sh --no-deps         only the shell itself: no packages, no font, no pleamar
#   ./install.sh --no-autostart    don't touch ~/.config/pleamar/autostart
#   ./install.sh --no-binds        don't touch ~/.config/hypr (the key binds, and what Settings saves there)
#   ./install.sh --no-wm           don't set up pleamar-wm (its login-screen entry, keys, window scene and autostart lines)
#   ./install.sh --uninstall       take the shell away (your data in ~/.local/share stays)
#
# What it does, in order:
#   1. the packages Vitreus uses      (Arch and its relatives: pacman, and yay/paru for the AUR;
#                                      on any other distribution it lists what to install by hand).
#                                      hyprsunset is required on Hyprland (Night mode): without it, this stops
#   2. pleamar, the runtime           (its own installer, into your home; a few minutes to build)
#   3. the Space Grotesk font         (into ~/.local/share/fonts, no sudo)
#   4. the shell                      (into ~/.config/pleamar/shells/vitreus: cloned, or updated)
#   5. your palette, autostart entry  (made once and never written over)
#   5b. the helpers                  (bin/vitreus-clipimg, vitreus-polkit-agent, vitreus-sysmon and vitreus-term, linked into ~/.local/bin)
#   6. its Hyprland key binds         (hypr_vitreus.lua linked into ~/.config/hypr, and loaded from hyprland.lua)
#   6b. the daemons                   (awww, hypridle and the clipboard history: lines in ~/.config/pleamar/autostart, run on any compositor)
#   7. pleamar-wm, as a session       (pleamar-wm/: its keys, window scene, hyprctl shim, and, with sudo,
#                                      its entry in the login screen; only if pleamar-wm is installed)
#
# It never installs a compositor: Vitreus is developed on Hyprland, and needs one that has layer-shell.
set -eu

repo="${VITREUS_REPO:-https://github.com/natepayn3/Vitreus.git}"
pleamar_installer="${PLEAMAR_INSTALLER:-https://raw.githubusercontent.com/k4ditano/pleamar/main/install.sh}"
font_url="https://github.com/google/fonts/raw/main/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf"

conf="${XDG_CONFIG_HOME:-$HOME/.config}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
dest="$conf/pleamar/shells/vitreus"
autostart="$conf/pleamar/autostart"
fonts="$data/fonts/SpaceGrotesk"

# Official-repo packages, then AUR ones: what each is for is in the README.
pacman_pkgs="git curl fontconfig imagemagick cava playerctl networkmanager bluez bluez-utils brightnessctl hypridle hyprsunset libnotify xdg-user-dirs xdg-utils wl-clipboard cliphist awww grim slurp wf-recorder power-profiles-daemon polkit python-gobject python-pyte ttf-space-mono-nerd pipewire-audio sound-theme-freedesktop"
aur_pkgs="iris-colors"

assume_yes=false
dry=false
deps=true
do_autostart=true
do_binds=true
do_wm=true
action=install
for a in "$@"; do
    case "$a" in
        --yes|-y) assume_yes=true ;;
        --dry-run) dry=true ;;
        --no-deps) deps=false ;;
        --no-autostart) do_autostart=false ;;
        --no-binds) do_binds=false ;;
        --no-wm) do_wm=false ;;
        --uninstall) action=uninstall ;;
        --help|-h) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'vitreus · I do not know "%s" (try --help)\n' "$a" >&2; exit 1 ;;
    esac
done

say()  { printf '\033[1;36mvitreus ·\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mvitreus ·\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mvitreus ·\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

# Do a command, or, with --dry-run, only say it.
run() {
    if $dry; then printf '    would run: %s\n' "$*"; else "$@"; fi
}

# ask "question": yes/no, default yes. Reads the keyboard even when the script itself was piped in.
# ask_no "question": the same, default no, for what cannot be undone; with no keyboard (and no --yes) it is a no.
tty_ok() { [ -r /dev/tty ] && ( exec < /dev/tty ) 2> /dev/null; }
ask() {
    $assume_yes && return 0
    if tty_ok; then
        printf '\033[1;36mvitreus ·\033[0m %s [Y/n] ' "$1" > /dev/tty
        read -r answer < /dev/tty || answer=y
        case "$answer" in n|N|no|No) return 1 ;; *) return 0 ;; esac
    fi
    warn "no keyboard to ask on: $1 (answering yes; use --yes to skip questions)"
    return 0
}
ask_no() {
    $assume_yes && return 0
    if tty_ok; then
        printf '\033[1;36mvitreus ·\033[0m %s [y/N] ' "$1" > /dev/tty
        read -r answer < /dev/tty || answer=n
        case "$answer" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
    fi
    warn "no keyboard to ask on: $1 (answering no; --yes says yes)"
    return 1
}

[ "$(id -u)" -ne 0 ] || fail "run this as yourself, not as root: it installs into your home (and asks for sudo only for packages)"
[ "$(uname -s)" = Linux ] || fail "Vitreus is a Linux (Wayland) shell"

# ── uninstall ──────────────────────────────────────────────────────────────
if [ "$action" = uninstall ]; then
    say "taking Vitreus away"
    if [ -f "$autostart" ] && grep -q 'vitreus.plm' "$autostart"; then
        run sed -i '/vitreus\.plm/d' "$autostart"
        say "removed its line from $autostart"
    fi
    # The lock screen, the wallpaper transition and the desktop clock are scenes of their own, each with its line.
    if [ -f "$autostart" ] && grep -q 'vitreus/lockscreen/lockscreen.plm' "$autostart"; then
        run sed -i '/vitreus\/lockscreen\/lockscreen\.plm/d' "$autostart"
        say "removed the lock screen's line from $autostart (hypridle and any key binding that lock with it are yours to change)"
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus/wptrans/wptrans.plm' "$autostart"; then
        run sed -i '/vitreus\/wptrans\/wptrans\.plm/d' "$autostart"
        say "removed the wallpaper transition's line from $autostart"
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus/desktopclock/desktopclock.plm' "$autostart"; then
        run sed -i '/vitreus\/desktopclock\/desktopclock\.plm/d' "$autostart"
        say "removed the desktop clock's line from $autostart"
    fi
    hyprlua="$conf/hypr/hyprland.lua"
    if [ -f "$hyprlua" ] && grep -q '^-- >>> vitreus' "$hyprlua"; then
        run sed -i '/^-- >>> vitreus/,/^-- <<< vitreus/d' "$hyprlua"
        say "removed Vitreus's lines from $hyprlua (SUPER + L and SUPER + Space go back to what hypr_style.lua binds)"
    fi
    if [ -f "$autostart" ] && grep -q -E '^# >>> vitreus \((pleamar-wm|session)\)' "$autostart"; then
        run sed -i -E '/^# >>> vitreus \((pleamar-wm|session)\)/,/^# <<< vitreus/d' "$autostart"
        say "removed its daemon lines from $autostart"
    fi
    # Marea and swaybg, which the pleamar-wm step turned off, are turned back on.
    if [ -f "$autostart" ] && grep -q '  (turned off by Vitreus: it is the bar now)$' "$autostart"; then
        run sed -i 's/^# \(.*\)  (turned off by Vitreus: it is the bar now)$/\1/' "$autostart"
        say "turned Marea (and swaybg) back on in $autostart"
    fi
    if [ -f "$autostart" ] && grep -q '^# wm: swaybg' "$autostart"; then
        say "an older install commented out «wm: swaybg» in $autostart without a mark: uncomment it if you want it back"
    fi
    for l in "$conf/pleamar/keys.conf" "$conf/pleamar/wm" "$HOME/.local/bin/hyprctl"; do
        case "$(readlink -f "$l" 2> /dev/null)" in "$(readlink -f "$dest")"/*) run rm -f "$l"; say "removed the link $l" ;; esac
    done
    if [ -f /usr/share/wayland-sessions/pleamar-wm.desktop ]; then
        say "pleamar-wm's login-screen entry is left in place; to take it away: sudo sh $dest/pleamar-wm/install-session.sh --remove"
    fi
    if [ -L "$HOME/.local/bin/vitreus-clipimg" ]; then run rm -f "$HOME/.local/bin/vitreus-clipimg"; fi
    if [ -L "$HOME/.local/bin/vitreus-polkit-agent" ]; then run rm -f "$HOME/.local/bin/vitreus-polkit-agent"; fi
    if [ -L "$HOME/.local/bin/vitreus-sysmon" ]; then run rm -f "$HOME/.local/bin/vitreus-sysmon"; fi
    if [ -L "$HOME/.local/bin/vitreus-term" ]; then run rm -f "$HOME/.local/bin/vitreus-term"; fi
    if [ -L "$HOME/.local/bin/vitreus-keep" ]; then run rm -f "$HOME/.local/bin/vitreus-keep"; fi
    if [ -L "$conf/hypr/hypr_vitreus.lua" ]; then run rm -f "$conf/hypr/hypr_vitreus.lua"; fi
    run rm -f "$conf/hypr/vitreus_monitors.lua" "$conf/hypr/vitreus_hypr.lua" "$conf/hypr/vitreus_colors.lua"
    if [ -d "$dest" ] && ask_no "delete $dest?"; then run rm -rf "$dest"; fi
    say "left as they were: your data in $data/pleamar/vitreus, the caches in ${XDG_CACHE_HOME:-$HOME/.cache}/pleamar/vitreus"
    say "and .../pleamar/lockscreen, and pleamar and the packages. To remove the data too: rm -rf $data/pleamar/vitreus"
    exit 0
fi

# ── 1. packages ────────────────────────────────────────────────────────────
if $deps; then
    if have pacman; then
        missing=""
        for p in $pacman_pkgs; do pacman -Qi "$p" > /dev/null 2>&1 || missing="$missing $p"; done
        if [ -n "$missing" ]; then
            say "packages to install:$missing"
            if ask "install them with sudo pacman?"; then
                run sudo pacman -S --needed --noconfirm $missing
            else
                warn "skipped: parts of Vitreus will stay quiet without them"
            fi
        else
            say "the packages are all there"
        fi
        aur_missing=""
        for p in $aur_pkgs; do pacman -Qi "$p" > /dev/null 2>&1 || aur_missing="$aur_missing $p"; done
        if [ -n "$aur_missing" ]; then
            helper=""
            have yay && helper=yay
            [ -z "$helper" ] && have paru && helper=paru
            if [ -n "$helper" ]; then
                say "from the AUR (with $helper):$aur_missing"
                if ask "install them?"; then
                    run "$helper" -S --needed --noconfirm $aur_missing
                fi
            else
                warn "from the AUR, and no helper (yay, paru) was found:$aur_missing"
                for p in $aur_missing; do
                    echo "    git clone https://aur.archlinux.org/$p.git && cd $p && makepkg -si"
                done
            fi
        fi
    else
        say "this is not an Arch-family system, so nothing is installed for you. Vitreus uses these programs"
        say "(all optional except pleamar, and hyprsunset on Hyprland: each of the others only enables one feature):"
        cat <<'LIST'
    cava            the bass pulse and the equalizer
    playerctl       cover art
    awww            the wallpaper picker
    iris            theming from the wallpaper (https://aur.archlinux.org/packages/iris-colors)
    imagemagick     wallpaper thumbnails, the launcher's picture previews
    wl-clipboard    the launcher copying (wl-copy), and Capture copying a screenshot
    polkit, python-gobject  the authentication dialog (Vitreus asks for your password when something wants admin rights)
    python-pyte, SpaceMono Nerd Font  the Desk's terminal (pyte keeps its screen; the font is Space Grotesk's monospaced sibling)
    pipewire (pw-play), sound-theme-freedesktop  the sounds notifications make
    grim, slurp     Capture's screenshots (slurp picks the region)
    wf-recorder     Capture's screen recording (slurp picks the region)
    power-profiles-daemon  the power profile in Power (powerprofilesctl)
    cliphist        the launcher's clipboard search (something must run: wl-paste --watch cliphist store)
    xdg-utils       the launcher opening a file (xdg-open)
    curl            weather and remote cover art
    NetworkManager  Wi-Fi (nmcli)
    BlueZ           Bluetooth (bluetoothctl)
    brightnessctl   the brightness slider
    hypridle        Caffeine
    hyprsunset      Night mode (REQUIRED on Hyprland: https://github.com/hyprwm/hyprsunset)
    libnotify       calendar reminders (notify-send)
    xdg-user-dirs   finding your Pictures folder
    git, fontconfig
LIST
    fi
    # On Hyprland hyprsunset is not optional: Night mode is driven by it. Without it the shell would have to fall back to a Hyprland
    # screen shader, which makes Hyprland rebuild its buffers on every change and flicker while a panel is open. Elsewhere Night
    # mode is not there anyway, so it is only a note.
    if ! $dry && ! have hyprsunset; then
        if have Hyprland || have hyprland; then
            fail "hyprsunset is required on Hyprland (it is what Night mode uses) and it is not installed. Install it and run this again: sudo pacman -S hyprsunset (Arch), or your distribution's package (https://github.com/hyprwm/hyprsunset)"
        fi
        warn "hyprsunset is not installed: Night mode (Hyprland only) will not work"
    fi
    have hyprctl || warn "Hyprland was not found. Vitreus needs a Wayland compositor with layer-shell; the list of running windows needs Hyprland."

    # ── 2. pleamar ──
    if have pleamar || [ -x "$HOME/.local/bin/pleamar" ]; then
        pv=$( { pleamar --version 2> /dev/null || "$HOME/.local/bin/pleamar" --version 2> /dev/null; } | sed -n 's/^pleamar \([0-9][0-9.]*\).*/\1/p' | head -1)
        say "pleamar is installed${pv:+ ($pv)}"
        case "$pv" in
            0.0*|0.1*|0.2.[0-8]) warn "Vitreus needs pleamar 0.2.9 or newer (the lock screen's monitor choice, and a crash when a monitor goes away, need it): update it with pleamar-update" ;;
        esac
    else
        say "pleamar, the runtime Vitreus is written for, is not installed"
        if ask "install it now? (it is built from source; the first time takes a few minutes)"; then
            if $dry; then
                echo "    would run: curl -fsSL $pleamar_installer | sh"
            else
                have curl || fail "curl is needed to fetch pleamar's installer"
                curl -fsSL "$pleamar_installer" | sh || fail "pleamar's installer failed (see above); Vitreus needs it"
            fi
        else
            warn "without pleamar Vitreus cannot run. Install it from https://github.com/k4ditano/pleamar"
        fi
    fi

    # ── 3. the font ──
    if have fc-list && fc-list 2> /dev/null | grep -qi 'space grotesk'; then
        say "the Space Grotesk font is installed"
    elif ask "install the Space Grotesk font (into $fonts)?"; then
        if $dry; then
            echo "    would download $font_url"
        else
            mkdir -p "$fonts"
            curl -fsSL "$font_url" -o "$fonts/SpaceGrotesk[wght].ttf" || warn "could not download the font: install Space Grotesk yourself"
            have fc-cache && fc-cache -f "$fonts" > /dev/null 2>&1 || true
        fi
    fi
fi

# ── 4. the shell itself ────────────────────────────────────────────────────
have git || fail "git is needed to fetch Vitreus"
if [ -d "$dest/.git" ]; then
    if $dry; then echo "    would run: git -C $dest pull --ff-only (your changes, and the monitors Settings chose, carried across)"; else
        g() { git -C "$dest" -c user.name=vitreus -c user.email=vitreus@localhost "$@"; }
        before=$(g rev-parse HEAD)
        # Settings keeps which monitors show the bar and the lock in the scenes' own `screens:` lines. They are put back to the stock
        # ones for the pull, so that they never stand in its way, and the chosen ones are written again after it.
        bar_sed='/^    surface \{/{s/.*screens: ([^;]*);.*/\1/p;q;}'
        lock_sed='/^        screens: /{s/^        screens: (.*)$/\1/p;q;}'
        set_screens() {
            if [ -n "$1" ] && [ -f "$dest/vitreus.plm" ]; then sed -i -E "/^    surface \{/s/screens: [^;]*;/screens: $1;/" "$dest/vitreus.plm"; fi
            if [ -n "$2" ] && [ -f "$dest/lockscreen/lockscreen.plm" ]; then sed -i -E "/^        screens: /s/screens: .*/screens: $2/" "$dest/lockscreen/lockscreen.plm"; fi
        }
        bar_s=$(sed -n -E "$bar_sed" "$dest/vitreus.plm" 2> /dev/null || true)
        lock_s=$(sed -n -E "$lock_sed" "$dest/lockscreen/lockscreen.plm" 2> /dev/null || true)
        set_screens "$(g show HEAD:vitreus.plm 2> /dev/null | sed -n -E "$bar_sed")" "$(g show HEAD:lockscreen/lockscreen.plm 2> /dev/null | sed -n -E "$lock_sed")"
        # wm-palette.plm was tracked once and is git-ignored now (Vitreus writes it): kept aside, so the pull that takes it out of git
        # does not take it off the disk, or trip over the colours Vitreus wrote into it.
        wmpal=""
        if g ls-files --error-unmatch wm-palette.plm > /dev/null 2>&1; then
            wmpal=$(mktemp)
            cp "$dest/wm-palette.plm" "$wmpal"
            g checkout --quiet -- wm-palette.plm
        fi
        # Anything else of yours (a tuned pleamar-wm scene or keys.conf, which are linked here, or your own edits) is set aside for
        # the pull and put back on top of it. If it no longer fits the new version, nothing is updated and your changes stay.
        stashed=false
        held=false
        if ! { g diff --quiet && g diff --cached --quiet; }; then
            g stash push --quiet -m "install.sh: your changes, set aside for an update" && stashed=true
        fi
        g pull --ff-only --quiet || warn "could not bring it up to date (left as it was)"
        if $stashed && ! g stash pop --quiet > /dev/null 2>&1; then
            warn "your changes in $dest do not fit the new version: it is left as it was, with your changes"
            held=true
            g reset --quiet --hard "$before"
            g stash pop --quiet || warn "your changes are kept in git's stash: git -C $dest stash list"
        fi
        set_screens "$bar_s" "$lock_s"
        if [ -n "$wmpal" ]; then
            cp "$wmpal" "$dest/wm-palette.plm"
            rm -f "$wmpal"
        fi
        after=$(g rev-parse HEAD)
        if [ "$before" != "$after" ]; then
            say "new since last time:"
            g log --oneline --no-decorate "$before..$after" | sed 's/^/    /' | head -20
        elif ! $held; then
            say "Vitreus is up to date"
        fi
    fi
elif [ -e "$dest" ]; then
    fail "$dest exists and is not a copy of Vitreus: move it away and run this again"
else
    say "fetching Vitreus into $dest"
    run mkdir -p "$(dirname "$dest")"
    run git clone --quiet --depth 1 "$repo" "$dest"
fi

# ── 5. the palettes ────────────────────────────────────────────────────────
# Vitreus rewrites both from your wallpaper, so git ignores them: the stock ones are the `.default` copies. palette.plm is the lock
# screen's, wm-palette.plm pleamar-wm's (its window borders).
for pal in palette wm-palette; do
    if [ -f "$dest/$pal.plm" ]; then
        say "$pal.plm is there (Vitreus rewrites it from your wallpaper)"
    elif [ -f "$dest/$pal.default.plm" ] || $dry; then
        say "making $pal.plm from the stock colours"
        run cp "$dest/$pal.default.plm" "$dest/$pal.plm"
    fi
done

# ── the launcher's helper ──────────────────────────────────────────────────
# Clipboard pictures cannot go through the logic (its command output is text), so a small script does the piping.
# It is linked into ~/.local/bin, where pleamar looks for programs.
if [ -x "$dest/bin/vitreus-clipimg" ] || $dry; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sf "$dest/bin/vitreus-clipimg" "$HOME/.local/bin/vitreus-clipimg"
    # The authentication dialog's agent, which the shell starts by itself. Only one polkit agent can hold a session: if another is
    # already running (polkit-gnome, hyprpolkitagent...), it keeps answering and this one says so and ends.
    [ -x "$dest/bin/vitreus-polkit-agent" ] && run ln -sf "$dest/bin/vitreus-polkit-agent" "$HOME/.local/bin/vitreus-polkit-agent"
    # Settings > System monitor's data source: started by the shell while that page is showing, and stopped when it is not.
    [ -x "$dest/bin/vitreus-sysmon" ] && run ln -sf "$dest/bin/vitreus-sysmon" "$HOME/.local/bin/vitreus-sysmon"
    [ -x "$dest/bin/vitreus-term" ] && run ln -sf "$dest/bin/vitreus-term" "$HOME/.local/bin/vitreus-term"
    # The keeper the autostart lines run each scene under: it starts a scene again when it stops (a crash on a monitor's wake).
    [ -x "$dest/bin/vitreus-keep" ] && run ln -sf "$dest/bin/vitreus-keep" "$HOME/.local/bin/vitreus-keep"
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "$HOME/.local/bin is not in your PATH: the launcher's clipboard pictures need it" ;; esac
# Hyprland does not read ~/.bashrc: if ~/.local/bin is only added there, its binds and exec-once lines never find
# `pleamar`. hypr_vitreus.lua adds it to PATH itself; whatever you start from hyprland.lua has to do the same.
fi

# ── 6. Hyprland key binds ──────────────────────────────────────────────────
# hypr_vitreus.lua (SUPER + L lock, SUPER + Space Settings) is linked into ~/.config/hypr and loaded from hyprland.lua
# after hypr_style.lua. Settings > Display and > Hyprland keep what you choose in vitreus_monitors.lua and
# vitreus_hypr.lua, loaded the same way (they do not exist until something is kept, hence pcall); so does vitreus_colors.lua, the
# window border colours Iris sets.
hyprdir="$conf/hypr"
hyprlua="$hyprdir/hyprland.lua"
if $do_binds; then
    if [ ! -f "$hyprlua" ]; then
        say "no $hyprlua, so no key binds set up (hyprland.conf users: bind a key to  pleamar --say vitreus \"emit settings_toggle\" )"
    elif grep -q 'hypr_vitreus' "$hyprlua"; then
        say "hyprland.lua already loads hypr_vitreus.lua"
        run ln -sf "$dest/hypr_vitreus.lua" "$hyprdir/hypr_vitreus.lua"
        # An install from before a file existed never loaded it (vitreus_colors.lua keeps the room the left bar takes; without
        # it, every reload of the config gives the gaps back): add what is missing, inside the block if it is there.
        for mod in vitreus_monitors vitreus_hypr vitreus_colors; do
            grep -q "$mod" "$hyprlua" && continue
            if $dry; then
                echo "    would add pcall(require, \"$mod\") to $hyprlua"
            else
                line="pcall(require, \"$mod\")"
                if grep -q '^-- <<< vitreus' "$hyprlua"; then
                    tmp=$(mktemp)
                    awk -v l="$line" '/^-- <<< vitreus/ { print l } { print }' "$hyprlua" > "$tmp" && cat "$tmp" > "$hyprlua"
                    rm -f "$tmp"
                else
                    echo "$line" >> "$hyprlua"
                fi
                say "added $line to $hyprlua"
            fi
        done
    elif ask "load Vitreus's key binds (SUPER + L, SUPER + Space) from $hyprlua?"; then
        run ln -sf "$dest/hypr_vitreus.lua" "$hyprdir/hypr_vitreus.lua"
        if $dry; then
            echo "    would back up $hyprlua and add four pcall(require, ...) lines to its end"
        else
            cp "$hyprlua" "$hyprlua.before-vitreus"
            {
                echo ""
                echo "-- >>> vitreus (added by its installer; ./install.sh --uninstall takes it out)"
                echo 'pcall(require, "hypr_vitreus")'
                grep -q 'vitreus_monitors' "$hyprlua" || echo 'pcall(require, "vitreus_monitors")'
                grep -q 'vitreus_hypr' "$hyprlua" || echo 'pcall(require, "vitreus_hypr")'
                grep -q 'vitreus_colors' "$hyprlua" || echo 'pcall(require, "vitreus_colors")'
                echo "-- <<< vitreus"
            } >> "$hyprlua"
            say "added to $hyprlua (the old one is $hyprlua.before-vitreus); Hyprland reloads it by itself"
        fi
    fi
fi

# ── start with the desktop ─────────────────────────────────────────────────
# Each scene runs under bin/vitreus-keep, which starts it again if it stops while the session lasts.
line="vitreus-keep $dest/vitreus.plm \"\$HOME/.local/share/pleamar/vitreus/vitreus.log\""
lockline="vitreus-keep $dest/lockscreen/lockscreen.plm"
transline="vitreus-keep $dest/wptrans/wptrans.plm"
clockline="vitreus-keep $dest/desktopclock/desktopclock.plm"
if $do_autostart; then
    # Lines from before the keeper started the scenes straight, once: they go through it now.
    if [ -f "$autostart" ] && grep -q "^pleamar --scene $dest/.*\.plm --no-hud\$" "$autostart"; then
        if $dry; then echo "    would put the scenes in $autostart under vitreus-keep"; else
            sed -i "s|^pleamar --scene \($dest/vitreus\.plm\) --no-hud\$|vitreus-keep \1 \"\$HOME/.local/share/pleamar/vitreus/vitreus.log\"|; s|^pleamar --scene \($dest/[^ ]*\.plm\) --no-hud\$|vitreus-keep \1|" "$autostart"
            say "the scenes in $autostart now run under vitreus-keep, which starts them again if they stop"
        fi
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus.plm' "$autostart"; then
        say "it is already in $autostart"
    elif ask "start Vitreus with the desktop (add a line to $autostart)?"; then
        run mkdir -p "$(dirname "$autostart")"
        if $dry; then echo "    would add to $autostart: $line"; else printf '%s\n' "$line" >> "$autostart"; fi
    fi
    # The lock screen is a scene of its own (a session lock has to be its own program, so that restarting the shell cannot unlock
    # the session), and the lock buttons and SUPER + L only work while it runs: it always starts with the desktop.
    if [ -f "$autostart" ] && grep -q 'lockscreen/lockscreen.plm' "$autostart"; then
        say "the lock screen is already in $autostart"
    else
        run mkdir -p "$(dirname "$autostart")"
        if $dry; then echo "    would add to $autostart: $lockline"; else printf '%s\n' "$lockline" >> "$autostart"; fi
        say "the lock screen starts with the desktop too (a line in $autostart): the lock buttons and SUPER + L need it"
    fi
    # The wallpaper picker's hexagon dissolve is a scene of its own as well; without it a pick uses awww's own transition.
    if [ -f "$autostart" ] && grep -q 'wptrans/wptrans.plm' "$autostart"; then
        say "the wallpaper transition is already in $autostart"
    else
        if $dry; then echo "    would add to $autostart: $transline"; else printf '%s\n' "$transline" >> "$autostart"; fi
        say "the wallpaper picker's hexagon dissolve starts with the desktop too (a line in $autostart)"
    fi
    # The desktop clock (digits of glass on the bottom layer) is a scene of its own as well; it starts shown, and turns off from the launcher.
    if [ -f "$autostart" ] && grep -q 'desktopclock/desktopclock.plm' "$autostart"; then
        say "the desktop clock is already in $autostart"
    else
        if $dry; then echo "    would add to $autostart: $clockline"; else printf '%s\n' "$clockline" >> "$autostart"; fi
        say "the desktop clock starts with the desktop too (a line in $autostart); \"Desktop clock: toggle\" in the launcher turns it off"
    fi
fi

# ── the daemons Vitreus talks to ───────────────────────────────────────────
# awww (the wallpaper picker drives it), hypridle (Caffeine, and the idle lock) and the clipboard history (the launcher's clipboard
# search has nothing without it). No `wm:` prefix: pleamar runs these lines on Hyprland (`pleamar --autostart`) and in pleamar-wm
# alike. Each is guarded, so one that is already running (yours, or one from hyprland.lua) is not started twice; the guard
# matches on the process name, because pgrep -f would find the very `sh -c` that runs the line.
if $do_autostart; then
    if [ -f "$autostart" ] && grep -q '^# >>> vitreus (session)' "$autostart"; then
        say "the daemon lines are already in $autostart"
    else
        if $dry; then echo "    would add to $autostart: awww-daemon, awww restore, hypridle, wl-paste --watch cliphist store"; else
            mkdir -p "$(dirname "$autostart")"
            # older versions wrote these as `wm:` lines, which Hyprland never ran: replace them
            if [ -f "$autostart" ] && grep -q '^# >>> vitreus (pleamar-wm)' "$autostart"; then
                sed -i '/^# >>> vitreus (pleamar-wm)/,/^# <<< vitreus/d' "$autostart"
            fi
            {
                echo "# >>> vitreus (session) (added by its installer; ./install.sh --uninstall takes it out)"
                for l in "pgrep -x awww-daemon > /dev/null || awww-daemon" \
                         "sleep 1; awww restore" \
                         "pgrep -x hypridle > /dev/null || hypridle" \
                         "pgrep -x wl-paste > /dev/null || wl-paste --watch cliphist store"; do
                    echo "$l"
                done
                echo "# <<< vitreus"
            } >> "$autostart"
            say "added the daemons (wallpaper, idle lock, clipboard history) to $autostart"
        fi
    fi
fi

# ── 7. pleamar-wm ──────────────────────────────────────────────────────────
# Vitreus runs on pleamar-wm (a session chosen at the login screen) as well as on Hyprland. Everything below is skipped when
# pleamar-wm is not installed, and each file of yours is only replaced when it is still the stock one.
wmdir="$dest/pleamar-wm"
if $do_wm && [ -d "$wmdir" ] && { have pleamar-wm || [ -x "$HOME/.local/bin/pleamar-wm" ]; }; then
    # `wm:` lines are read by pleamar-wm's session only. Marea is the shell pleamar-wm comes with: with Vitreus as the bar,
    # she and swaybg (which needs a wallpaper file that is not there) are turned off, not deleted.
    # (The daemons Vitreus needs are started for every compositor, in the section above.)
    if $do_autostart && [ -f "$autostart" ] && ! $dry; then
        sed -i -e 's/^marea start\([[:space:]].*\)\{0,1\}$/# \0  (turned off by Vitreus: it is the bar now)/' \
               -e 's/^wm: swaybg\(.*\)$/# wm: swaybg\1  (turned off by Vitreus: it is the bar now)/' "$autostart"
    fi
    # keys: Vitreus's launcher, Settings, lock, wallpaper picker, capture, volume. Only over the stock file (just `defaults` and comments).
    keys="$conf/pleamar/keys.conf"
    if [ -L "$keys" ] && [ "$(readlink -f "$keys")" = "$(readlink -f "$wmdir/keys.conf")" ]; then
        say "pleamar-wm's keys are already Vitreus's"
    elif [ ! -e "$keys" ] || ! grep -qvE '^[[:space:]]*(#|$|defaults[[:space:]]*$)' "$keys"; then
        run mkdir -p "$conf/pleamar"
        run ln -sf "$wmdir/keys.conf" "$keys"
        say "pleamar-wm's keys are Vitreus's now ($keys)"
    else
        warn "$keys has bindings of yours: left alone (Vitreus's are in $wmdir/keys.conf)"
    fi
    # the window manager's scene (slim glass title bars): only where there is none of yours.
    wmscene="$conf/pleamar/wm"
    if [ -L "$wmscene" ] && [ "$(readlink -f "$wmscene")" = "$(readlink -f "$wmdir/wm")" ]; then
        say "pleamar-wm's window scene is Vitreus's"
    elif [ ! -e "$wmscene" ] || { [ -d "$wmscene" ] && [ -z "$(ls -A "$wmscene" 2> /dev/null)" ]; }; then
        run rm -rf "$wmscene"
        run ln -sfn "$wmdir/wm" "$wmscene"
        say "pleamar-wm's window scene is Vitreus's now ($wmscene)"
    else
        warn "$wmscene has a scene of yours: left alone (Vitreus's is in $wmdir/wm)"
    fi
    # hyprctl for a desktop that is not Hyprland (ahead of /usr/bin; on Hyprland it hands over to the real one).
    if [ ! -e "$HOME/.local/bin/hyprctl" ] || [ -L "$HOME/.local/bin/hyprctl" ]; then
        run mkdir -p "$HOME/.local/bin"
        run ln -sf "$wmdir/hyprctl" "$HOME/.local/bin/hyprctl"
    fi
    # the login-screen entry: needs root, so it is asked for. It installs the session wrapper (/usr/local/bin/pleamar-wm-session), the
    # entry in /usr/share/wayland-sessions and pleamar-wm's portals. The wrapper starts `pleamar-wm session` with the desktop's names and PATH.
    if [ -x /usr/local/bin/pleamar-wm-session ] && grep -q '^Exec=pleamar-wm-session' /usr/share/wayland-sessions/pleamar-wm.desktop 2> /dev/null; then
        say "pleamar-wm is in the login screen's list of sessions"
    elif ask "put pleamar-wm in the login screen's list of sessions (needs sudo)?"; then
        run sudo sh "$wmdir/install-session.sh" || warn "could not: run  sudo sh $wmdir/install-session.sh  yourself"
    fi
elif $do_wm && [ -d "$wmdir" ]; then
    say "pleamar-wm is not installed, so no session for it (pleamar's installer has it: https://github.com/k4ditano/pleamar)"
fi

# ── services it talks to ───────────────────────────────────────────────────
if have systemctl; then
    systemctl is-active --quiet bluetooth 2> /dev/null || say "Bluetooth is off: sudo systemctl enable --now bluetooth"
    systemctl is-active --quiet NetworkManager 2> /dev/null || say "NetworkManager is not running: Wi-Fi needs it (sudo systemctl enable --now NetworkManager)"
    have powerprofilesctl && { systemctl is-active --quiet power-profiles-daemon 2> /dev/null || say "power-profiles-daemon is not running: the power profile in Power needs it (sudo systemctl enable --now power-profiles-daemon)"; }
fi

say "done."
echo
echo "  Start it now:          $line"
echo "  Lock screen, too:      $lockline"
echo "  Hexagon dissolve:      $transline"
echo "  With the desktop:      autostart is read by pleamar's own session; on Hyprland run \`pleamar --autostart\`:"
echo "                         hyprland.lua:   hl.on(\"hyprland.start\", function () hl.exec_cmd(\"PATH=\\\"\$HOME/.local/bin:\$PATH\\\" pleamar --autostart\") end)"
echo "                         hyprland.conf:  exec-once = ~/.local/bin/pleamar --autostart   (Hyprland's PATH may lack ~/.local/bin)"
echo "  Keys (with the binds): SUPER + Space launcher, SUPER + SHIFT + Space settings, SUPER + B wallpaper picker, SUPER + L lock (see lockscreen/README.md)"
echo "  Daemons:               awww, hypridle and the clipboard history start from $autostart (nothing to add to hyprland.lua)"
echo "  pleamar-wm:            log out and choose «pleamar-wm» in the login screen (SDDM: click the session name at the bottom right)"
echo "  Update later:          run this script again"
echo "  Its settings:          $data/pleamar/vitreus  (iris.json, weather-config.json, ...)"
echo
echo "  It becomes the desktop's notification server when it starts, and gives that back when it exits."
