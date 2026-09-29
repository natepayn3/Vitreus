#!/bin/sh
# Vitreus: install it, keep it up to date, take it away. One script for all.
#
#   curl -fsSL https://raw.githubusercontent.com/natepayn3/Vitreus/main/install.sh | sh
#   ./install.sh                   install (or, if it is there, update)
#   ./install.sh --yes             don't ask anything: answer yes to everything
#   ./install.sh --dry-run         say what it would do, and do nothing
#   ./install.sh --no-deps         only the shell itself: no packages, no font, no pleamar
#   ./install.sh --no-autostart    don't touch ~/.config/pleamar/autostart
#   ./install.sh --uninstall       take the shell away (your data in ~/.local/share stays)
#
# What it does, in order:
#   1. the packages Vitreus uses      (Arch and its relatives: pacman, and yay/paru for the AUR;
#                                      on any other distribution it lists what to install by hand)
#   2. pleamar, the runtime           (its own installer, into your home; a few minutes to build)
#   3. the Space Grotesk font         (into ~/.local/share/fonts, no sudo)
#   4. the shell                      (into ~/.config/pleamar/shells/vitreus: cloned, or updated)
#   5. your palette, autostart entry  (made once and never written over)
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
pacman_pkgs="git curl fontconfig imagemagick cava playerctl networkmanager bluez bluez-utils brightnessctl hypridle libnotify xdg-user-dirs awww"
aur_pkgs="iris-colors"

assume_yes=false
dry=false
deps=true
do_autostart=true
action=install
for a in "$@"; do
    case "$a" in
        --yes|-y) assume_yes=true ;;
        --dry-run) dry=true ;;
        --no-deps) deps=false ;;
        --no-autostart) do_autostart=false ;;
        --uninstall) action=uninstall ;;
        --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    if [ -d "$dest" ] && ask "delete $dest?"; then run rm -rf "$dest"; fi
    say "left as they were: your data in $data/pleamar/vitreus, the cache in ${XDG_CACHE_HOME:-$HOME/.cache}/pleamar/vitreus,"
    say "and pleamar and the packages. To remove the data too: rm -rf $data/pleamar/vitreus"
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
        say "(all optional except pleamar: each one only enables one feature):"
        cat <<'LIST'
    cava            the bass pulse and the equalizer
    playerctl       cover art
    awww            the wallpaper picker
    iris            theming from the wallpaper (https://aur.archlinux.org/packages/iris-colors)
    imagemagick     wallpaper thumbnails
    curl            weather and remote cover art
    NetworkManager  Wi-Fi (nmcli)
    BlueZ           Bluetooth (bluetoothctl)
    brightnessctl   the brightness slider
    hypridle        Caffeine
    libnotify       calendar reminders (notify-send)
    xdg-user-dirs   finding your Pictures folder
    git, fontconfig
LIST
    fi
    have hyprctl || warn "Hyprland was not found. Vitreus needs a Wayland compositor with layer-shell; the list of running windows needs Hyprland."

    # ── 2. pleamar ──
    if have pleamar || [ -x "$HOME/.local/bin/pleamar" ]; then
        say "pleamar is installed"
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
fi

say "done."
echo
echo "  Start it now:          $line"
echo "  With the desktop:      autostart is read by pleamar's own session; on Hyprland add"
echo "                         exec-once = pleamar --autostart"
echo "  Update later:          run this script again"
echo "  Its settings:          $data/pleamar/vitreus  (iris.json, weather-config.json, ...)"
echo
echo "  It becomes the desktop's notification server when it starts, and gives that back when it exits."
