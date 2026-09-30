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
#   ./install.sh --uninstall       take the shell away (your data in ~/.local/share stays)
#
# What it does, in order:
#   1. the packages Vitreus uses      (Arch and its relatives: pacman, and yay/paru for the AUR;
#                                      on any other distribution it lists what to install by hand).
#                                      hyprsunset is required (Night mode): without it, this stops
#   2. pleamar, the runtime           (its own installer, into your home; a few minutes to build)
#   3. the Space Grotesk font         (into ~/.local/share/fonts, no sudo)
#   4. the shell                      (into ~/.config/pleamar/shells/vitreus: cloned, or updated)
#   5. your palette, autostart entry  (made once and never written over)
#   5b. the helpers                  (bin/vitreus-clipimg, vitreus-polkit-agent and vitreus-sysmon, linked into ~/.local/bin)
#   6. its Hyprland key binds         (hypr_vitreus.lua linked into ~/.config/hypr, and loaded from hyprland.lua)
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
pacman_pkgs="git curl fontconfig imagemagick cava playerctl networkmanager bluez bluez-utils brightnessctl hypridle hyprsunset libnotify xdg-user-dirs xdg-utils wl-clipboard cliphist awww grim slurp wf-recorder power-profiles-daemon polkit python-gobject"
aur_pkgs="iris-colors"

assume_yes=false
dry=false
deps=true
do_autostart=true
do_binds=true
action=install
for a in "$@"; do
    case "$a" in
        --yes|-y) assume_yes=true ;;
        --dry-run) dry=true ;;
        --no-deps) deps=false ;;
        --no-autostart) do_autostart=false ;;
        --no-binds) do_binds=false ;;
        --uninstall) action=uninstall ;;
        --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
ask() {
    $assume_yes && return 0
    if [ -r /dev/tty ]; then
        printf '\033[1;36mvitreus ·\033[0m %s [Y/n] ' "$1" > /dev/tty
        read -r answer < /dev/tty || answer=y
        case "$answer" in n|N|no|No) return 1 ;; *) return 0 ;; esac
    fi
    warn "no keyboard to ask on: $1 (answering yes; use --yes to skip questions)"
    return 0
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
    # The lock screen is not started by this script, but whoever turned it on has a line for it (see lockscreen/README.md).
    if [ -f "$autostart" ] && grep -q 'vitreus/lockscreen/lockscreen.plm' "$autostart"; then
        run sed -i '/vitreus\/lockscreen\/lockscreen\.plm/d' "$autostart"
        say "removed the lock screen's line from $autostart (hypridle and any key binding that lock with it are yours to change)"
    fi
    hyprlua="$conf/hypr/hyprland.lua"
    if [ -f "$hyprlua" ] && grep -q '^-- >>> vitreus' "$hyprlua"; then
        run sed -i '/^-- >>> vitreus/,/^-- <<< vitreus/d' "$hyprlua"
        say "removed Vitreus's lines from $hyprlua (SUPER + L and SUPER + Space go back to what hypr_style.lua binds)"
    fi
    if [ -L "$HOME/.local/bin/vitreus-clipimg" ]; then run rm -f "$HOME/.local/bin/vitreus-clipimg"; fi
    if [ -L "$HOME/.local/bin/vitreus-polkit-agent" ]; then run rm -f "$HOME/.local/bin/vitreus-polkit-agent"; fi
    if [ -L "$HOME/.local/bin/vitreus-sysmon" ]; then run rm -f "$HOME/.local/bin/vitreus-sysmon"; fi
    if [ -L "$conf/hypr/hypr_vitreus.lua" ]; then run rm -f "$conf/hypr/hypr_vitreus.lua"; fi
    run rm -f "$conf/hypr/vitreus_monitors.lua" "$conf/hypr/vitreus_hypr.lua"
    if [ -d "$dest" ] && ask "delete $dest?"; then run rm -rf "$dest"; fi
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
        say "(all optional except pleamar and hyprsunset: each of the others only enables one feature):"
        cat <<'LIST'
    cava            the bass pulse and the equalizer
    playerctl       cover art
    awww            the wallpaper picker
    iris            theming from the wallpaper (https://aur.archlinux.org/packages/iris-colors)
    imagemagick     wallpaper thumbnails, the launcher's picture previews
    wl-clipboard    the launcher copying (wl-copy), and Capture copying a screenshot
    polkit, python-gobject  the authentication dialog (Vitreus asks for your password when something wants admin rights)
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
    hyprsunset      Night mode (REQUIRED: https://github.com/hyprwm/hyprsunset)
    libnotify       calendar reminders (notify-send)
    xdg-user-dirs   finding your Pictures folder
    git, fontconfig
LIST
    fi
    # hyprsunset is not optional: Night mode is driven by it. Without it the shell would have to fall back to a Hyprland
    # screen shader, which makes Hyprland rebuild its buffers on every change and flicker while a panel is open.
    if ! $dry && ! have hyprsunset; then
        fail "hyprsunset is required (it is what Night mode uses) and it is not installed. Install it and run this again: sudo pacman -S hyprsunset (Arch), or your distribution's package (https://github.com/hyprwm/hyprsunset)"
    fi
    have hyprctl || warn "Hyprland was not found. Vitreus needs a Wayland compositor with layer-shell; the list of running windows needs Hyprland."

    # ── 2. pleamar ──
    if have pleamar || [ -x "$HOME/.local/bin/pleamar" ]; then
        pv=$( { pleamar --version 2> /dev/null || "$HOME/.local/bin/pleamar" --version 2> /dev/null; } | sed -n 's/^pleamar \([0-9][0-9.]*\).*/\1/p' | head -1)
        say "pleamar is installed${pv:+ ($pv)}"
        case "$pv" in
            0.0*|0.1*|0.2.0*|0.2.1*) warn "Vitreus needs pleamar 0.2.2 or newer (the lock screen crashes the session on older ones): update it" ;;
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
    if git -C "$dest" diff --quiet && git -C "$dest" diff --cached --quiet; then
        before=$(git -C "$dest" rev-parse HEAD)
        if $dry; then echo "    would run: git -C $dest pull --ff-only"; else
            git -C "$dest" pull --ff-only --quiet || warn "could not bring it up to date (left as it was)"
            after=$(git -C "$dest" rev-parse HEAD)
            if [ "$before" != "$after" ]; then
                say "new since last time:"
                git -C "$dest" log --oneline --no-decorate "$before..$after" | sed 's/^/    /' | head -20
            else
                say "Vitreus is up to date"
            fi
        fi
    else
        warn "$dest has changes of yours: not updated"
    fi
elif [ -e "$dest" ]; then
    fail "$dest exists and is not a copy of Vitreus: move it away and run this again"
else
    say "fetching Vitreus into $dest"
    run mkdir -p "$(dirname "$dest")"
    run git clone --quiet "$repo" "$dest"
fi

# ── 5. the palette ─────────────────────────────────────────────────────────
if [ -f "$dest/palette.plm" ]; then
    say "the palette is there (Vitreus rewrites it from your wallpaper)"
elif [ -f "$dest/palette.default.plm" ] || $dry; then
    say "making your palette from the stock colours"
    run cp "$dest/palette.default.plm" "$dest/palette.plm"
fi

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
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "$HOME/.local/bin is not in your PATH: the launcher's clipboard pictures need it" ;; esac
# Hyprland does not read ~/.bashrc: if ~/.local/bin is only added there, its binds and exec-once lines never find
# `pleamar`. hypr_vitreus.lua adds it to PATH itself; whatever you start from hyprland.lua has to do the same.
fi

# ── 6. Hyprland key binds ──────────────────────────────────────────────────
# hypr_vitreus.lua (SUPER + L lock, SUPER + Space Settings) is linked into ~/.config/hypr and loaded from hyprland.lua
# after hypr_style.lua. Settings > Display and > Hyprland keep what you choose in vitreus_monitors.lua and
# vitreus_hypr.lua, loaded the same way (they do not exist until something is kept, hence pcall).
hyprdir="$conf/hypr"
hyprlua="$hyprdir/hyprland.lua"
if $do_binds; then
    if [ ! -f "$hyprlua" ]; then
        say "no $hyprlua, so no key binds set up (hyprland.conf users: bind a key to  pleamar --say vitreus \"emit settings_toggle\" )"
    elif grep -q 'hypr_vitreus' "$hyprlua"; then
        say "hyprland.lua already loads hypr_vitreus.lua"
        run ln -sf "$dest/hypr_vitreus.lua" "$hyprdir/hypr_vitreus.lua"
    elif ask "load Vitreus's key binds (SUPER + L, SUPER + Space) from $hyprlua?"; then
        run ln -sf "$dest/hypr_vitreus.lua" "$hyprdir/hypr_vitreus.lua"
        if $dry; then
            echo "    would back up $hyprlua and add three pcall(require, ...) lines to its end"
        else
            cp "$hyprlua" "$hyprlua.before-vitreus"
            {
                echo ""
                echo "-- >>> vitreus (added by its installer; ./install.sh --uninstall takes it out)"
                echo 'pcall(require, "hypr_vitreus")'
                grep -q 'vitreus_monitors' "$hyprlua" || echo 'pcall(require, "vitreus_monitors")'
                grep -q 'vitreus_hypr' "$hyprlua" || echo 'pcall(require, "vitreus_hypr")'
                echo "-- <<< vitreus"
            } >> "$hyprlua"
            say "added to $hyprlua (the old one is $hyprlua.before-vitreus); Hyprland reloads it by itself"
        fi
    fi
fi

# ── start with the desktop ─────────────────────────────────────────────────
line="pleamar --scene $dest/vitreus.plm --no-hud"
if $do_autostart; then
    if [ -f "$autostart" ] && grep -q 'vitreus.plm' "$autostart"; then
        say "it is already in $autostart"
    elif ask "start Vitreus with the desktop (add a line to $autostart)?"; then
        run mkdir -p "$(dirname "$autostart")"
        if $dry; then echo "    would add to $autostart: $line"; else printf '%s\n' "$line" >> "$autostart"; fi
    fi
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
echo "  With the desktop:      autostart is read by pleamar's own session; on Hyprland run \`pleamar --autostart\`:"
echo "                         hyprland.lua:   hl.on(\"hyprland.start\", function () hl.exec_cmd(\"PATH=\\\"\$HOME/.local/bin:\$PATH\\\" pleamar --autostart\") end)"
echo "                         hyprland.conf:  exec-once = ~/.local/bin/pleamar --autostart   (Hyprland's PATH may lack ~/.local/bin)"
echo "  Keys (with the binds): SUPER + Space launcher, SUPER + SHIFT + Space settings, SUPER + B wallpaper picker, SUPER + L lock (see lockscreen/README.md)"
echo "  Clipboard search:      needs  wl-paste --watch cliphist store  running at startup, or ^ has nothing to show"
echo "  Update later:          run this script again"
echo "  Its settings:          $data/pleamar/vitreus  (iris.json, weather-config.json, ...)"
echo
echo "  It becomes the desktop's notification server when it starts, and gives that back when it exits."
