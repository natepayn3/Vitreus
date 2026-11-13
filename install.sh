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
#   ./install.sh --no-login        don't install the login screen (the SDDM theme)
#   ./install.sh --refresh         what Settings > About runs after it has pulled: no questions, no sudo, nothing downloaded but the bundled add-ons' newest releases; it
#                                  links the new helpers, adds the new autostart lines and binds, and lists the packages that are missing
#   ./install.sh --force           install even when another Quickshell desktop shell is in use
#   ./install.sh --test            try it next to another shell (Quickshell): no autostart, key binds or pleamar-wm; stops that
#                                  shell and starts Vitreus now
#   ./install.sh --stop            end a --test: stop Vitreus and start the other shell again
#   ./install.sh --uninstall       take the shell away (your data in ~/.local/share stays)
#
# What it does, in order:
#   1. the packages Vitreus uses      (Arch and its relatives: pacman, and yay/paru for the AUR;
#                                      on any other distribution it lists what to install by hand).
#                                      hyprsunset is required on Hyprland (Night mode): without it, this stops
#   2. pleamar, the runtime           (its own installer, into your home; a few minutes to build)
#   3. the fonts                      (Space Grotesk, and the five the Retro, UwU, Cyber, Milkbox and Proxy themes are drawn in: Audiowide, Mochiy Pop One, Orbitron, Zen Kurenaido and Titan One;
#                                      into ~/.local/share/fonts, no sudo)
#   4. the shell                      (into ~/.config/pleamar/shells/vitreus: cloned, or updated)
#   5. your palette, autostart entry  (made once and never written over)
#   5b. the helpers                  (bin/vitreus-clipimg, vitreus-polkit-agent, vitreus-sysmon, vitreus-battery, vitreus-greeter, vitreus-term, vitreus-files, vitreus-edit, vitreus-report and vitreus-btnwait, linked into ~/.local/bin; vitreus-inhibit, built there)
#   5c. Files, as a program            (its icon and entry in ~/.local/share; asked: the file manager for folders and «Show in folder», files/integrate.sh)
#   5d. View, as a program             (its icon and entry in ~/.local/share; asked: what opens pictures and videos, view/integrate.sh)
#   6. its Hyprland key binds         (hypr_vitreus.lua linked into ~/.config/hypr, and loaded from hyprland.lua)
#   6b. the daemons                   (awww, hypridle and the clipboard history: lines in ~/.config/pleamar/autostart, run on any compositor)
#   6c. niri                        (config.kdl includes vitreus.kdl, the room round the windows the shell writes, and niri_vitreus.kdl, its key binds; with niri installed)
#   7. pleamar-wm, as a session       (pleamar-wm/: its keys, window scene, hyprctl shim, and, with sudo,
#                                      its entry in the login screen; only if pleamar-wm is installed)
#   8. the login screen               (sddm/: the lock screen's look as an SDDM theme, with sudo, asked for; where SDDM already has a theme it asks
#                                      before it is replaced. ./sddm/install.sh [IMAGE] does it again with another picture)
#
# It never installs a compositor: Vitreus is developed on Hyprland, and needs one that has layer-shell.
set -eu

repo="${VITREUS_REPO:-https://github.com/natepayn3/Vitreus.git}"
pleamar_installer="${PLEAMAR_INSTALLER:-https://raw.githubusercontent.com/k4ditano/pleamar/main/install.sh}"
font_url="https://github.com/google/fonts/raw/main/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf"
# The Retro theme's typeface, Audiowide (a rounded sci-fi face), and the UwU theme's (both Google Fonts, OFL).
# Both are optional: without one, that theme keeps Space Grotesk.
dot_url="https://github.com/google/fonts/raw/main/ofl/audiowide/Audiowide-Regular.ttf"
dot_licence_url="https://github.com/google/fonts/raw/main/ofl/audiowide/OFL.txt"
mochiy_url="https://github.com/google/fonts/raw/main/ofl/mochiypopone/MochiyPopOne-Regular.ttf"
# The Cyber theme's typeface, Orbitron (a squared techno face; Google Fonts, OFL).
orbitron_url="https://github.com/google/fonts/raw/main/ofl/orbitron/Orbitron%5Bwght%5D.ttf"
orbitron_licence_url="https://github.com/google/fonts/raw/main/ofl/orbitron/OFL.txt"
# The Milkbox theme's typeface, Zen Kurenaido (a soft hand-drawn face; Google Fonts, OFL).
kurenaido_url="https://github.com/google/fonts/raw/main/ofl/zenkurenaido/ZenKurenaido-Regular.ttf"
kurenaido_licence_url="https://github.com/google/fonts/raw/main/ofl/zenkurenaido/OFL.txt"
# The Proxy theme's typeface, Titan One (a chunky rounded display face; Google Fonts, OFL).
titan_url="https://github.com/google/fonts/raw/main/ofl/titanone/TitanOne-Regular.ttf"
titan_licence_url="https://github.com/google/fonts/raw/main/ofl/titanone/OFL.txt"
# The Paper theme's typeface, Fuzzy Bubbles (a bubbly marker handwriting; Google Fonts, OFL).
fuzzy_url="https://github.com/google/fonts/raw/main/ofl/fuzzybubbles/FuzzyBubbles-Regular.ttf"
fuzzy_bold_url="https://github.com/google/fonts/raw/main/ofl/fuzzybubbles/FuzzyBubbles-Bold.ttf"
fuzzy_licence_url="https://github.com/google/fonts/raw/main/ofl/fuzzybubbles/OFL.txt"
# The Doodle theme's typeface, Kalam (a marker handwriting face in Light, Regular and Bold; Google Fonts, OFL).
kalam_url="https://github.com/google/fonts/raw/main/ofl/kalam"

conf="${XDG_CONFIG_HOME:-$HOME/.config}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
dest="$conf/pleamar/shells/vitreus"
autostart="$conf/pleamar/autostart"
fonts="$data/fonts/SpaceGrotesk"
fonts_dot="$data/fonts/Audiowide"
fonts_mochiy="$data/fonts/MochiyPopOne"
fonts_orbitron="$data/fonts/Orbitron"
fonts_kurenaido="$data/fonts/ZenKurenaido"
fonts_titan="$data/fonts/TitanOne"
fonts_fuzzy="$data/fonts/FuzzyBubbles"
fonts_kalam="$data/fonts/Kalam"

# Official-repo packages, then AUR ones: what each is for is in the README.
pacman_pkgs="gcc pkgconf wayland wayland-protocols git curl jq python fontconfig socat glib2 file imagemagick cava playerctl networkmanager bluez bluez-utils brightnessctl hypridle libnotify xdg-user-dirs xdg-utils wl-clipboard cliphist awww ffmpeg xdg-desktop-portal-gtk grim slurp wf-recorder power-profiles-daemon polkit python-gobject python-pyte ttf-space-mono-nerd pipewire-audio sound-theme-freedesktop tesseract tesseract-data-eng"
aur_pkgs="iris-colors mpvpaper"
# Debian and Ubuntu: the same list by their names. UNTESTED (written without a Debian machine to try it on), and some of these are
# not in every release (hypridle, cliphist, wf-recorder...): each is looked up and installed on its own, and a missing one is only said.
# Not here, because Debian has no package: awww, mpvpaper, hyprsunset, iris, the Space Mono Nerd Font (listed below for hand install).
apt_pkgs="gcc pkgconf libwayland-dev wayland-protocols git curl jq python3 fontconfig socat libglib2.0-bin file imagemagick cava playerctl network-manager bluez brightnessctl hypridle libnotify-bin xdg-user-dirs xdg-utils wl-clipboard cliphist ffmpeg xdg-desktop-portal-gtk grim slurp wf-recorder power-profiles-daemon polkitd python3-gi python3-pyte pipewire-bin sound-theme-freedesktop tesseract-ocr tesseract-ocr-eng"

# Night mode is hyprsunset on Hyprland, and wlsunset everywhere else (niri, pleamar-wm): each is only wanted where its compositor is,
# and wlsunset also where there is no Hyprland at all. A machine with Hyprland and pleamar-wm gets both. (Here `have` is not defined yet.)
# Debian has no hyprsunset package: it is in the hand-install list below.
on_hypr=false
{ command -v Hyprland > /dev/null 2>&1 || command -v hyprland > /dev/null 2>&1; } && on_hypr=true
$on_hypr && pacman_pkgs="$pacman_pkgs hyprsunset"
if command -v niri > /dev/null 2>&1 || command -v pleamar-wm > /dev/null 2>&1 || ! $on_hypr; then
    pacman_pkgs="$pacman_pkgs wlsunset"
    apt_pkgs="$apt_pkgs wlsunset"
fi

assume_yes=false
dry=false
deps=true
do_autostart=true
do_binds=true
do_wm=true
do_login=true
force=false
refresh=false
trial=false
action=install
for a in "$@"; do
    case "$a" in
        --yes|-y) assume_yes=true ;;
        --dry-run) dry=true ;;
        --no-deps) deps=false ;;
        --no-autostart) do_autostart=false ;;
        --no-binds) do_binds=false ;;
        --no-wm) do_wm=false ;;
        --no-login) do_login=false ;;
        --refresh) refresh=true ;;
        --force) force=true ;;
        --test) trial=true; force=true; do_autostart=false; do_binds=false; do_wm=false; do_login=false ;;
        --stop) action=stop ;;
        --uninstall) action=uninstall ;;
        --help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'vitreus · I do not know "%s" (try --help)\n' "$a" >&2; exit 1 ;;
    esac
done

# What this run said and what failed, kept short in ~/.local/state/vitreus/install.log: `vitreus-report` reads it, so a person whose
# install stopped half way can send it without knowing what to look for. (Nothing is written with --dry-run.)
installlog="${XDG_STATE_HOME:-$HOME/.local/state}/vitreus/install.log"
log() { $dry || printf '%s\n' "$*" >> "$installlog" 2> /dev/null || true; }
if ! $dry; then
    {
        mkdir -p "$(dirname "$installlog")"
        if [ -f "$installlog" ]; then tail -n 300 "$installlog" > "$installlog.tmp" && mv "$installlog.tmp" "$installlog"; fi
        printf '\n=== %s · install.sh %s ===\n' "$(date)" "$*" >> "$installlog"
    } 2> /dev/null || true
fi

# ── how it looks ───────────────────────────────────────────────────────────
# On a terminal: the word VITREUS pinned at the top (everything below scrolls under it, in a scroll region), a bar for the step it is on,
# and a mark before each line. Piped, run by Settings (--refresh), not UTF-8, or with NO_COLOR or VITREUS_PLAIN set: plain "vitreus ·" lines.
# A terminal too small for the banner gets the colours and marks without it.
esc=$(printf '\033')
color=false
fancy=false
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) utf=true ;; *) utf=false ;; esac
if [ -t 1 ] && $utf && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ] && [ -z "${VITREUS_PLAIN:-}" ] && ! $refresh; then color=true; fi
if $color; then
    c0="$esc[0m"; c_b="$esc[1m"; c_dim="$esc[2m"
    c_acc="$esc[38;5;45m"; c_ok="$esc[38;5;114m"; c_warn="$esc[38;5;221m"; c_bad="$esc[38;5;203m"; c_q="$esc[38;5;177m"; c_rule="$esc[38;5;238m"
    # The word's colours, one per letter, cyan to violet to pink (24-bit where the terminal says it has it).
    case "${COLORTERM:-}" in
        truecolor|24bit) i=0; for c in "94;234;255" "72;204;255" "96;165;250" "129;140;248" "167;139;250" "200;130;250" "236;121;220"; do
                i=$((i + 1)); eval "g$i=\"\$esc[38;2;\${c}m\""; done ;;
        *) i=0; for c in 51 45 39 33 63 135 171; do i=$((i + 1)); eval "g$i=\"\$esc[38;5;\${c}m\""; done ;;
    esac
    export VITREUS_UI=1        # files/integrate.sh prints its lines the same way
else
    c0=""; c_b=""; c_dim=""; c_acc=""; c_ok=""; c_warn=""; c_bad=""; c_q=""; c_rule=""
fi

# The word, letter by letter (| between letters, so each takes its own colour).
art1='██╗   ██╗|██╗|████████╗|██████╗ |███████╗|██╗   ██╗|███████╗'
art2='██║   ██║|██║|╚══██╔══╝|██╔══██╗|██╔════╝|██║   ██║|██╔════╝'
art3='██║   ██║|██║|   ██║   |██████╔╝|█████╗  |██║   ██║|███████╗'
art4='╚██╗ ██╔╝|██║|   ██║   |██╔══██╗|██╔══╝  |██║   ██║|╚════██║'
art5=' ╚████╔╝ |██║|   ██║   |██║  ██║|███████╗|╚██████╔╝|███████║'
art6='  ╚═══╝  |╚═╝|   ╚═╝   |╚═╝  ╚═╝|╚══════╝|╚═════╝ |╚══════╝'
head_h=11                  # the banner's rows: a blank, the word (6), a blank, the subtitle, the step, a rule

if [ "$action" = uninstall ]; then ui_mode="taking it away"
elif [ "$action" = stop ]; then ui_mode="ending the test"
elif $trial; then ui_mode="trying it out"
elif [ -f "$dest/vitreus.plm" ]; then ui_mode="updating"
else ui_mode="installing"; fi
$dry && ui_mode="$ui_mode (dry run: nothing is changed)"
stage_n=0
stage_total=0
stage_name=""
ui_state=run               # run, done or failed: the colour of the step line

term_size() {
    sz=$(stty size < /dev/tty 2> /dev/null) || sz=""
    rows=${sz% *}; cols=${sz#* }
    case "$rows$cols" in ''|*[!0-9]*) rows=$(tput lines 2> /dev/null); cols=$(tput cols 2> /dev/null) ;; esac
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    case "$cols" in ''|*[!0-9]*) cols=0 ;; esac
}
repeat() { r=""; k=0; while [ "$k" -lt "$2" ]; do r="$r$1"; k=$((k + 1)); done; printf '%s' "$r"; }
draw_word() {
    for n in 1 2 3 4 5 6; do
        eval "row=\$art$n"
        line=""; i=0
        old_ifs=$IFS; IFS='|'; set -- $row; IFS=$old_ifs
        for piece in "$@"; do i=$((i + 1)); eval "line=\"\$line\$g$i\$piece\""; done
        printf '%s[2K  %s%s%s\n' "$esc" "$c_b" "$line" "$c0"
    done
}
# The step line: a bar of the steps done, and the one it is on.
status_line() {
    case "$ui_state" in
        done)   printf '  %s✓ %s%s' "$c_ok$c_b" "$stage_name" "$c0" ;;
        failed) printf '  %s✗ stopped at: %s%s' "$c_bad$c_b" "$stage_name" "$c0" ;;
        *)
            if [ "$stage_total" -gt 0 ]; then
                bw=$((cols - 44)); [ "$bw" -gt 32 ] && bw=32; [ "$bw" -lt 8 ] && bw=8
                full=$((stage_n * bw / stage_total))
                printf '  %s%s%s%s%s  %s%s%s  %s%d/%d%s' "$c_acc" "$(repeat ━ "$full")" "$c_rule" "$(repeat ─ $((bw - full)))" "$c0" \
                    "$c_b" "$stage_name" "$c0" "$c_dim" "$stage_n" "$stage_total" "$c0"
            else
                printf '  %s%s%s' "$c_b" "$stage_name" "$c0"
            fi ;;
    esac
}
banner_status() { $fancy || return 0; printf '%s7%s[10;1H%s[2K%s%s8' "$esc" "$esc" "$esc" "$(status_line)" "$esc"; }
draw_banner() {
    printf '%s[H%s[2K\n' "$esc" "$esc"
    draw_word
    printf '%s[2K\n' "$esc"
    printf '%s[2K  %sa glass desktop shell for pleamar%s  %s·%s  %s\n' "$esc" "$c_dim" "$c0" "$c_acc" "$c0" "$ui_mode"
    printf '%s[2K%s\n' "$esc" "$(status_line)"
    printf '%s[2K%s%s%s' "$esc" "$c_rule" "$(repeat ─ "$cols")" "$c0"
}
ui_start() {
    $color || return 0
    term_size
    if [ "$rows" -ge 24 ] && [ "$cols" -ge 60 ]; then
        fancy=true
        ui_rows=$rows; ui_cols=$cols
        # Push what is on the screen up into the scrollback, draw the banner, and keep the rest of the run below it.
        k=0; while [ "$k" -lt "$rows" ]; do printf '\n'; k=$((k + 1)); done
        draw_banner
        printf '%s[%d;%dr%s[%d;1H' "$esc" $((head_h + 1)) "$rows" "$esc" $((head_h + 1))
    elif [ "$cols" -ge 60 ]; then
        printf '\n'; draw_word
        printf '\n  %sa glass desktop shell for pleamar%s  %s·%s  %s\n' "$c_dim" "$c0" "$c_acc" "$c0" "$ui_mode"
    else
        printf '\n  %sV I T R E U S%s  %s%s%s\n' "$g1$c_b" "$c0" "$c_dim" "$ui_mode" "$c0"
    fi
}
# The window changed size: draw the banner again (the terminal may have dropped the scroll region), or give it up when it no longer fits.
ui_fit() {
    $fancy || return 0
    term_size
    [ "$rows" = "$ui_rows" ] && [ "$cols" = "$ui_cols" ] && return 0
    ui_rows=$rows; ui_cols=$cols
    if [ "$rows" -lt 24 ] || [ "$cols" -lt 60 ]; then ui_end; return 0; fi
    printf '%s7' "$esc"
    draw_banner
    printf '%s[%d;%dr%s8' "$esc" $((head_h + 1)) "$rows" "$esc"
}
# The end of the run: the whole screen scrolls again, the banner stays where it is until the next lines push it up.
ui_end() { $fancy || return 0; fancy=false; printf '%s7%s[r%s8' "$esc" "$esc" "$esc"; }

stage() {
    stage_n=$((stage_n + 1)); stage_name=$1
    log "── $1"
    $color || return 0
    ui_fit
    printf '\n  %s▍%s%s%s\n' "$c_acc" "$c_b" "$1" "$c0"
    banner_status
}
say()  { log "$*"; if $color; then ui_fit; printf '  %s•%s %s\n' "$c_acc" "$c0" "$*"; else printf 'vitreus · %s\n' "$*"; fi; }
warn() { log "warning: $*"; if $color; then ui_fit; printf '  %s! %s%s\n' "$c_warn$c_b" "$c0$c_warn$*" "$c0" >&2; else printf 'vitreus · %s\n' "$*" >&2; fi; }
fail() {
    log "FAILED: $*"
    if $color; then
        printf '\n  %s✗ %s%s\n' "$c_bad$c_b" "$*" "$c0" >&2
        [ -n "$stage_name" ] || stage_name=$ui_mode
        ui_state=failed; banner_status
    else printf 'vitreus · %s\n' "$*" >&2; fi
    exit 1
}
ui_done() {
    if $color; then
        stage_n=$stage_total; stage_name="done"; ui_state=done; banner_status
        if $dry; then printf '\n  %s✓ dry run done: nothing was changed%s\n' "$c_ok$c_b" "$c0"
        else printf '\n  %s✓ Vitreus is ready%s\n' "$c_ok$c_b" "$c0"; fi
        log "done."
    else say "done."; fi
}
# The questions' look (the asking itself is ask and ask_no, below).
prompt() {
    if $color; then printf '  %s?%s %s %s%s%s ' "$c_q$c_b" "$c0" "$1" "$c_dim" "$2" "$c0" > /dev/tty
    else printf 'vitreus · %s %s ' "$1" "$2" > /dev/tty; fi
}
# What --dry-run says it would do, dimmed.
would() { printf '    %swould %s%s\n' "$c_dim" "$*" "$c0"; }
# The list at the end: a label, dimmed, and what it says.
heading() { if $color; then printf '\n  %s%s%s\n' "$c_acc$c_b" "$1" "$c0"; else printf '\n  %s\n' "$1"; fi; }
# On a terminal, $HOME is written ~ and a long line wraps under its own column.
row() {
    if $color; then
        v=$(printf '%s' "$2" | sed "s|$HOME/|~/|g")
        w=$((${cols:-0} - 27))
        if [ "$w" -ge 30 ]; then
            first=true
            printf '%s\n' "$v" | fold -s -w "$w" | while IFS= read -r l; do
                if $first; then printf '  %s%-22s%s %s\n' "$c_dim" "$1" "$c0" "$l"; first=false; else printf '  %-22s %s\n' "" "$l"; fi
            done
            return 0
        fi
        printf '  %s%-22s%s %s\n' "$c_dim" "$1" "$c0" "$v"
    else
        printf '  %-22s %s\n' "$1" "$2"
    fi
}
trap 'rc=$?; ui_end; [ "$rc" -eq 0 ] || log "stopped with status $rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
have() { command -v "$1" > /dev/null 2>&1; }

# Do a command, or, with --dry-run, only say it.
run() {
    if $dry; then would "run: $*"; else
        if "$@"; then :; else rc=$?; log "command failed ($rc): $*"; return "$rc"; fi
    fi
}
# run_kept CMD…: run, and when it fails keep the last of what it printed in the install log too, so that a report says why (a
# step like the login screen's prints its reason and only "command failed (1)" was kept).
run_kept() {
    if $dry; then would "run: $*"; return 0; fi
    out=$(mktemp) || { run "$@"; return; }
    st=$(mktemp) || { rm -f "$out"; run "$@"; return; }
    { "$@"; echo $? > "$st"; } 2>&1 | tee "$out"
    rc=$(cat "$st" 2> /dev/null); rc=${rc:-1}
    if [ "$rc" != 0 ]; then
        log "command failed ($rc): $*"
        tail -n 15 "$out" | sed 's/^/    | /' >> "$installlog" 2> /dev/null || true
    fi
    rm -f "$out" "$st"
    return "$rc"
}

# ask "question": yes/no, default yes. Reads the keyboard even when the script itself was piped in.
# ask_no "question": the same, default no, for what cannot be undone; with no keyboard (and no --yes) it is a no.
tty_ok() { [ -r /dev/tty ] && ( exec < /dev/tty ) 2> /dev/null; }
ask() {
    $refresh && return 1
    $assume_yes && return 0
    if tty_ok; then
        prompt "$1" "[Y/n]"
        read -r answer < /dev/tty || answer=y
        case "$answer" in n|N|no|No) return 1 ;; *) return 0 ;; esac
    fi
    warn "no keyboard to ask on: $1 (answering yes; use --yes to skip questions)"
    return 0
}
ask_no() {
    $refresh && return 1
    $assume_yes && return 0
    if tty_ok; then
        prompt "$1" "[y/N]"
        read -r answer < /dev/tty || answer=n
        case "$answer" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
    fi
    warn "no keyboard to ask on: $1 (answering no; --yes says yes)"
    return 1
}

[ "$(id -u)" -ne 0 ] || fail "run this as yourself, not as root: it installs into your home (and asks for sudo only for packages)"
[ "$(uname -s)" = Linux ] || fail "Vitreus is a Linux (Wayland) shell"
# The steps the bar counts (an install or update; --no-deps leaves out the first four after the check).
if [ "$action" = install ]; then if $deps; then stage_total=13; else stage_total=9; fi; fi
ui_start

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
    if [ -f "$autostart" ] && grep -q 'vitreus/desktopsysmon/desktopsysmon.plm' "$autostart"; then
        run sed -i '/vitreus\/desktopsysmon\/desktopsysmon\.plm/d' "$autostart"
        say "removed the desktop system monitor's line from $autostart"
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus/cursortrail/cursortrail.plm' "$autostart"; then
        run sed -i '/vitreus\/cursortrail\/cursortrail\.plm/d' "$autostart"
        say "removed the UwU cursor trail's line from $autostart"
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus/desktopcava/desktopcava.plm' "$autostart"; then
        run sed -i '/vitreus\/desktopcava\/desktopcava\.plm/d' "$autostart"
        say "removed the desktop audio visualiser's line from $autostart"
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus/desktopnotes/desktopnotes.plm' "$autostart"; then
        run sed -i '/vitreus\/desktopnotes\/desktopnotes\.plm/d' "$autostart"
        say "removed the desktop notes' line from $autostart"
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus/desktopmenu/desktopmenu.plm' "$autostart"; then
        run sed -i '/vitreus\/desktopmenu\/desktopmenu\.plm/d' "$autostart"
        say "removed the desktop menu's line from $autostart"
    fi
    hyprlua="$conf/hypr/hyprland.lua"
    if [ -f "$hyprlua" ] && grep -q '^-- >>> vitreus' "$hyprlua"; then
        run sed -i '/^-- >>> vitreus/,/^-- <<< vitreus/d' "$hyprlua"
        say "removed Vitreus's lines from $hyprlua (SUPER + L and SUPER + Space go back to what hypr_style.lua binds)"
    fi
    nirikdl="$conf/niri/config.kdl"
    if [ -f "$nirikdl" ] && grep -q '^// >>> vitreus' "$nirikdl"; then
        tmp=$(mktemp)
        sed '/^\/\/ >>> vitreus/,/^\/\/ <<< vitreus/d' "$nirikdl" > "$tmp" && run sh -c "cat '$tmp' > '$nirikdl'"
        rm -f "$tmp" "$conf/niri/niri_vitreus.kdl" "$conf/niri/vitreus.kdl"
        say "removed Vitreus's lines from $nirikdl"
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
    if [ -f "$conf/pleamar/session.conf" ] && grep -q 'Vitreus Files floats' "$conf/pleamar/session.conf"; then
        run sed -i -e '/^# Vitreus Files floats rather than tiling/d' -e '/^window app=vitreus\.files float$/d' "$conf/pleamar/session.conf"
        say "pleamar-wm no longer floats Files by a rule of ours"
    fi
    for l in "$conf/pleamar/keys.conf" "$conf/pleamar/wm" "$HOME/.local/bin/hyprctl"; do
        case "$(readlink -f "$l" 2> /dev/null)" in "$(readlink -f "$dest")"/*) run rm -f "$l"; say "removed the link $l" ;; esac
    done
    if [ -f /usr/share/wayland-sessions/pleamar-wm.desktop ]; then
        say "pleamar-wm's login-screen entry is left in place; to take it away: sudo sh $dest/pleamar-wm/install-session.sh --remove"
    fi
    if [ -d /usr/share/sddm/themes/vitreus ]; then
        say "the Vitreus login screen is left in place; to take it away (and put the old theme back): sh $dest/sddm/install.sh --remove"
    fi
    if [ -f "$dest/files/integrate.sh" ]; then run sh "$dest/files/integrate.sh" --remove; fi
    if [ -f "$dest/view/integrate.sh" ]; then run sh "$dest/view/integrate.sh" --remove; fi
    if [ -L "$HOME/.local/bin/vitreus-clipimg" ]; then run rm -f "$HOME/.local/bin/vitreus-clipimg"; fi
    if [ -L "$HOME/.local/bin/vitreus-polkit-agent" ]; then run rm -f "$HOME/.local/bin/vitreus-polkit-agent"; fi
    if [ -L "$HOME/.local/bin/vitreus-sysmon" ]; then run rm -f "$HOME/.local/bin/vitreus-sysmon"; fi
    if [ -L "$HOME/.local/bin/vitreus-battery" ]; then run rm -f "$HOME/.local/bin/vitreus-battery"; fi
    if [ -L "$HOME/.local/bin/vitreus-greeter" ]; then run rm -f "$HOME/.local/bin/vitreus-greeter"; fi
    if [ -L "$HOME/.local/bin/vitreus-term" ]; then run rm -f "$HOME/.local/bin/vitreus-term"; fi
    if [ -L "$HOME/.local/bin/vitreus-files" ]; then run rm -f "$HOME/.local/bin/vitreus-files"; fi
    if [ -L "$HOME/.local/bin/vitreus-view" ]; then run rm -f "$HOME/.local/bin/vitreus-view"; fi
    if [ -L "$HOME/.local/bin/vitreus-keep" ]; then run rm -f "$HOME/.local/bin/vitreus-keep"; fi
    if [ -L "$HOME/.local/bin/vitreus-themes" ]; then run rm -f "$HOME/.local/bin/vitreus-themes"; fi
    if [ -L "$HOME/.local/bin/vitreus-wallhaven" ]; then run rm -f "$HOME/.local/bin/vitreus-wallhaven"; fi
    if [ -L "$HOME/.local/bin/vitreus-edit" ]; then run rm -f "$HOME/.local/bin/vitreus-edit"; fi
    if [ -L "$HOME/.local/bin/vitreus-addons" ]; then run rm -f "$HOME/.local/bin/vitreus-addons"; fi
    if [ -L "$HOME/.local/bin/vitreus-sync-addons" ]; then run rm -f "$HOME/.local/bin/vitreus-sync-addons"; fi
    if [ -L "$HOME/.local/bin/vitreus-feedfetch" ]; then run rm -f "$HOME/.local/bin/vitreus-feedfetch"; fi
    if [ -L "$HOME/.local/bin/vitreus-tvremote" ]; then run rm -f "$HOME/.local/bin/vitreus-tvremote"; fi
    if [ -L "$HOME/.local/bin/vitreus-eq" ]; then run rm -f "$HOME/.local/bin/vitreus-eq"; fi
    if [ -L "$HOME/.local/bin/vitreus-report" ]; then run rm -f "$HOME/.local/bin/vitreus-report"; fi
    if [ -L "$HOME/.local/bin/vitreus-btnwait" ]; then run rm -f "$HOME/.local/bin/vitreus-btnwait"; fi
    if [ -f "$HOME/.local/bin/vitreus-inhibit" ]; then run rm -f "$HOME/.local/bin/vitreus-inhibit"; fi
    if [ -L "$conf/hypr/hypr_vitreus.lua" ]; then run rm -f "$conf/hypr/hypr_vitreus.lua"; fi
    run rm -f "$conf/hypr/vitreus_monitors.lua" "$conf/hypr/vitreus_hypr.lua" "$conf/hypr/vitreus_colors.lua"
    if [ -d "$dest" ] && ask_no "delete $dest?"; then run rm -rf "$dest"; fi
    say "left as they were: your data in $data/pleamar/vitreus, the caches in ${XDG_CACHE_HOME:-$HOME/.cache}/pleamar/vitreus"
    say "and .../pleamar/lockscreen, and pleamar and the packages. To remove the data too: rm -rf $data/pleamar/vitreus"
    exit 0
fi

# ── --stop: end a --test and bring the other shell back ───────────────────
trial_file="$data/pleamar/vitreus/test-restore"
if [ "$action" = stop ]; then
    say "stopping Vitreus"
    run pkill -f "vitreus-keep $dest/"
    run pkill -f "pleamar --scene $dest/"
    if [ -f "$trial_file" ] && ! $dry; then
        sleep 1
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            say "starting your other shell again: $cmd"
            setsid sh -c "$cmd" > /dev/null 2>&1 < /dev/null &
        done < "$trial_file"
        rm -f "$trial_file"
    else
        say "(no other shell was stopped by --test, so none is started again)"
    fi
    exit 0
fi

# ── another desktop shell ──────────────────────────────────────────────────
# Vitreus is a whole desktop shell, not an add-on: it starts its own bar, notifications, launcher, lock screen and wallpaper, takes SUPER + Space,
# L, B, D and TAB, and sets Hyprland's gaps, borders, layout and monitors. Next to another shell the two fight over the same jobs (only one can
# own the notifications, the wallpaper or the polkit agent), so this stops before touching anything. Which shell does not matter: Quickshell is
# running (qs or quickshell) and it has a configuration of any kind in ~/.config/quickshell or the system's XDG_CONFIG_DIRS (/etc/xdg).
# --yes does not skip it, since it is not a question of packages: only --force does. An update of Vitreus itself is not stopped.
stage "looking for another shell"
if [ "$action" = install ] && ! $force && ! $refresh && ! { [ -f "$autostart" ] && grep -q 'vitreus.plm' "$autostart"; }; then
    if pgrep -x qs > /dev/null 2>&1 || pgrep -x quickshell > /dev/null 2>&1; then
        # Any configuration at all (a folder, or a shell.qml directly in it), where Quickshell looks: the user's, then the system's (XDG_CONFIG_DIRS).
        qsdir=""
        for d in "$conf" $(printf '%s' "${XDG_CONFIG_DIRS:-/etc/xdg}" | tr ':' ' '); do
            if [ -n "$(find "$d/quickshell" -mindepth 1 -maxdepth 1 2> /dev/null | head -n 1)" ]; then qsdir="$d/quickshell"; break; fi
        done
        if [ -n "$qsdir" ]; then
            warn "Quickshell is running, and $qsdir has a configuration: another desktop shell is in use"
            warn "Vitreus is a whole shell, not an add-on. Installed next to it, both start at login and fight over the notifications, the wallpaper,"
            warn "the lock screen and the polkit agent; it also takes SUPER + Space, L, B, D and TAB from you and sets Hyprland's gaps, borders,"
            warn "layout and monitors. To switch to Vitreus: take the other shell's autostart line out of your hyprland.lua (and its key binds), log out,"
            warn "and run this again. To install anyway: ./install.sh --force"
            if $dry; then
                say "(--dry-run: this is where it would stop)"
            elif ! $assume_yes && tty_ok && ask_no "install Vitreus next to it anyway?"; then
                say "going on, as you said"
            else
                fail "stopped before changing anything. Nothing was installed."
            fi
        fi
    fi
fi

# ── 1. packages ────────────────────────────────────────────────────────────
if $deps; then
    stage "the packages"
    if have pacman; then
        missing=""
        for p in $pacman_pkgs; do pacman -Qi "$p" > /dev/null 2>&1 || missing="$missing $p"; done
        if [ -n "$missing" ] && $refresh; then
            # Settings reads this line: the update itself needs no sudo, so it only says what is missing.
            printf 'vitreus-missing:%s\n' "$missing"
        elif [ -n "$missing" ]; then
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
        if [ -n "$aur_missing" ] && ! $refresh; then
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
        if have apt-get; then
            # Debian, Ubuntu and relatives (best effort, untested): each package on its own, so one that this release lacks costs only itself.
            apt_missing=""
            apt_absent=""
            for p in $apt_pkgs; do
                dpkg -s "$p" > /dev/null 2>&1 && continue
                if apt-cache show "$p" > /dev/null 2>&1; then apt_missing="$apt_missing $p"; else apt_absent="$apt_absent $p"; fi
            done
            if [ -n "$apt_missing" ] && $refresh; then
                printf 'vitreus-missing:%s\n' "$apt_missing"
            elif [ -n "$apt_missing" ]; then
                say "packages to install:$apt_missing"
                if ask "install them with sudo apt?"; then
                    for p in $apt_missing; do
                        run sudo apt-get install -y "$p" || warn "could not install $p: run  sudo apt install $p  yourself"
                    done
                else
                    warn "skipped: parts of Vitreus will stay quiet without them"
                fi
            else
                say "the packages Debian has are all there"
            fi
            [ -z "$apt_absent" ] || warn "this release has no package for:$apt_absent (the feature each is for will be missing; see the list below)"
        fi
        say "Vitreus uses these programs. On a system that is not Arch-based, anything not installed above you add by hand"
        say "(all optional except pleamar, and hyprsunset on Hyprland: each of the others only enables one feature):"
        cat <<'LIST'
    cava            the bass pulse and the equalizer
    playerctl       cover art
    awww            the wallpaper picker
    qt6-multimedia, qt6-multimedia-ffmpeg  a video behind the login screen (Settings > Greeter); without them it shows the video's first frame
    mpvpaper (AUR), ffmpeg  video wallpapers (mp4, webm, mov): mpvpaper plays them, ffmpeg takes the frame the rest of the shell reads; ffmpeg also reads the webcam
    iris            theming from the wallpaper (https://aur.archlinux.org/packages/iris-colors)
    imagemagick     wallpaper thumbnails, the launcher's picture previews, Snap's marked-up picture, and the pictures' own pictures in Files
    wl-clipboard    the launcher copying (wl-copy: results, snippets), and Capture copying a screenshot
    polkit, python-gobject  the authentication dialog (Vitreus asks for your password when something wants admin rights)
    python-pyte, SpaceMono Nerd Font  the Desk's terminal (pyte keeps its screen; the font is Space Grotesk's monospaced sibling)
    pipewire (pw-play), sound-theme-freedesktop  the sounds notifications make
    tesseract       reading the text of a screenshot (Copy text, Ask), on the screenshot card, and in Snap (Copy text, Blur private info)
    grim, slurp     Capture's screenshots (slurp picks the region for a recording; Snap picks a screenshot's)
    jq              Snap finding the focused monitor and its windows (from Hyprland's monitors and clients)
    wf-recorder     Capture's screen recording (slurp picks the region)
    power-profiles-daemon  the power profile in Power (powerprofilesctl)
    cliphist        the launcher's clipboard search (something must run: wl-paste --watch cliphist store)
    xdg-utils       the launcher opening a file or a web search (xdg-open), and Files opening a file
    glib2 (gio)     Files putting things in the Trash and emptying it; file  the kind of file Files shows in Properties
    curl            weather, remote cover art and the launcher's web answers
    NetworkManager  Wi-Fi (nmcli)
    BlueZ           Bluetooth (bluetoothctl)
    brightnessctl   the brightness slider
    hypridle        Caffeine
    hyprsunset      Night mode on Hyprland (REQUIRED there: https://github.com/hyprwm/hyprsunset)
    wlsunset        Night mode on niri and pleamar-wm (https://sr.ht/~kennylevinsen/wlsunset/)
    libnotify       calendar reminders (notify-send)
    xdg-desktop-portal-gtk  the permission prompts for apps' screenshots, screen sharing and camera, and their "choose a file" windows
                    (pleamar-wm hands the portal everything it does not answer itself; Hyprland's and niri's fall back to it too)
    xdg-user-dirs   finding your Pictures folder, and the places in Files' sidebar
    git, fontconfig
    python          the font setup of the Retro and UwU themes and the font picker (bin/vitreus-fonts)
    Audiowide, Mochiy Pop One, Orbitron, Zen Kurenaido, Titan One, Fuzzy Bubbles, Kalam  the typefaces of the Retro, UwU, Cyber, Milkbox, Proxy, Paper and Doodle themes (Space Grotesk's neighbours, installed into ~/.local/share/fonts)
LIST
    fi
    # On Hyprland hyprsunset is not optional: Night mode is driven by it. Without it the shell would have to fall back to a Hyprland
    # screen shader, which makes Hyprland rebuild its buffers on every change and flicker while a panel is open. Without Hyprland it
    # is not used at all, so nothing is said.
    if $on_hypr && ! $dry && ! have hyprsunset; then
        $refresh || fail "hyprsunset is required on Hyprland (it is what Night mode uses) and it is not installed. Install it and run this again: sudo pacman -S hyprsunset (Arch), or your distribution's package (https://github.com/hyprwm/hyprsunset)"
        warn "hyprsunset is not installed: Night mode on Hyprland will not work"
    fi
    # niri and pleamar-wm have no night light of their own: Night mode there is wlsunset (it sets the gamma through the compositor).
    # It is in the package lists above; this is for when those were skipped or the release has none.
    if { have niri || have pleamar-wm; } && ! have wlsunset; then
        warn "wlsunset is not installed: Night mode on niri and pleamar-wm needs it (sudo pacman -S wlsunset on Arch, sudo apt install wlsunset on Debian)"
    fi
    # Without it, the portal has nothing to ask permission with: apps cannot take screenshots or share the screen through it, and some
    # (Flatpaks, Firefox set to use portals) open no file picker. The journal says "the screenshot portal requires an access impl".
    if ! $dry && ! [ -f /usr/share/xdg-desktop-portal/portals/gtk.portal ]; then
        warn "xdg-desktop-portal-gtk is not installed: apps' screenshots, screen sharing and file pickers need it (sudo pacman -S xdg-desktop-portal-gtk on Arch, sudo apt install xdg-desktop-portal-gtk on Debian)"
    fi
    have hyprctl || have niri || warn "Neither Hyprland nor niri was found. Vitreus needs a Wayland compositor with layer-shell; the list of running windows needs Hyprland or niri."

    # ── 1b. a Vulkan driver for the graphics card ──
    # pleamar draws with Vulkan. Its own installer brings the loader (vulkan-icd-loader), but the driver is the card's own package, which a minimal install does not have: with none,
    # pleamar finds no graphics adapter and the shell does not start, with nothing on screen to say why. So each card found is looked up here, and only a missing driver is said or offered.
    stage "the graphics driver"
    if ! $refresh; then
        gpu_vendors=""
        for v in /sys/class/drm/card[0-9]*/device/vendor; do
            [ -r "$v" ] || continue
            case "$(cat "$v" 2> /dev/null)" in
                0x1002) g=amd ;;
                0x8086) g=intel ;;
                0x10de) g=nvidia ;;
                *) continue ;;
            esac
            case " $gpu_vendors " in *" $g "*) ;; *) gpu_vendors="$gpu_vendors $g" ;; esac
        done
        gpu_any_icd=false
        gpu_missing=""
        for g in $gpu_vendors; do
            case "$g" in
                amd) icd='radeon_icd*.json' ;;
                intel) icd='intel_icd*.json' ;;
                nvidia) icd='nvidia_icd*.json' ;;
            esac
            icd_found=false
            for f in /usr/share/vulkan/icd.d/$icd /etc/vulkan/icd.d/$icd; do
                if [ -e "$f" ]; then icd_found=true; break; fi
            done
            if $icd_found; then gpu_any_icd=true; else gpu_missing="$gpu_missing $g"; fi
        done
        for g in $gpu_missing; do
            case "$g" in
                amd|intel)
                    if [ "$g" = amd ]; then gpkg=vulkan-radeon; gname=AMD; else gpkg=vulkan-intel; gname=Intel; fi
                    if have pacman; then
                        warn "an $gname graphics card was found with no Vulkan driver ($gpkg): the shell cannot draw without one"
                        if ask "install $gpkg with sudo pacman?"; then
                            run sudo pacman -S --needed --noconfirm "$gpkg" || warn "could not install $gpkg: run  sudo pacman -S $gpkg  yourself, then start Vitreus again"
                        else
                            warn "skipped: without $gpkg the shell will not start. Install it with: sudo pacman -S $gpkg"
                        fi
                    elif have apt-get; then
                        warn "an $gname graphics card was found with no Vulkan driver (mesa-vulkan-drivers): the shell cannot draw without one"
                        if ask "install mesa-vulkan-drivers with sudo apt?"; then
                            run sudo apt-get install -y mesa-vulkan-drivers || warn "could not install mesa-vulkan-drivers: run  sudo apt install mesa-vulkan-drivers  yourself, then start Vitreus again"
                        else
                            warn "skipped: without mesa-vulkan-drivers the shell will not start. Install it with: sudo apt install mesa-vulkan-drivers"
                        fi
                    else
                        warn "an $gname graphics card was found with no Vulkan driver: install your distribution's Mesa Vulkan driver (Debian, Ubuntu and Fedora: mesa-vulkan-drivers; openSUSE: libvulkan_radeon or libvulkan_intel). Without it the shell will not start."
                    fi
                    ;;
                nvidia)
                    if $gpu_any_icd; then
                        say "an NVIDIA card was found with no Vulkan driver; another card has one, so the shell will draw with that"
                    else
                        warn "an NVIDIA card was found with no Vulkan driver: install NVIDIA's driver for your kernel (Arch: nvidia or nvidia-open, with nvidia-utils). Without it the shell will not start."
                    fi
                    ;;
            esac
        done
    fi

    # ── 2. pleamar ──
    stage "pleamar"
    if $refresh; then :  # pleamar and the fonts are not touched here
    elif have pleamar || [ -x "$HOME/.local/bin/pleamar" ]; then
        pv=$( { pleamar --version 2> /dev/null || "$HOME/.local/bin/pleamar" --version 2> /dev/null; } | sed -n 's/^pleamar \([0-9][0-9.]*\).*/\1/p' | head -1)
        say "pleamar is installed${pv:+ ($pv)}"
        if $do_wm && ! have pleamar-wm && [ ! -x "$HOME/.local/bin/pleamar-wm" ] && have pleamar-update; then
            say "pleamar-wm, pleamar's window manager, is not installed"
            if ask "install it now? (built from source; Vitreus then also runs as a session at the login screen)"; then
                if $dry; then would "run: pleamar-update --all"
                else pleamar-update --all || warn "pleamar-update --all failed: run it yourself to get pleamar-wm"
                fi
            fi
        fi
        # 0.5.0 is where the facts motion.reduced and color.scheme exist; older pleamar stops at "there is nothing called 'motion.reduced'" and the shell does not load.
        pleamar_min="0.5.0"
        if [ -n "$pv" ] && [ "$(printf '%s\n%s\n' "$pleamar_min" "$pv" | sort -V | head -1)" != "$pleamar_min" ]; then
            warn "Vitreus needs pleamar $pleamar_min or newer (this is $pv): older ones fail to load the scene with \"there is nothing called 'motion.reduced'\""
            if have pleamar-update; then
                if ask "update pleamar now? (built from source; a few minutes)"; then
                    if $dry; then would "run: pleamar-update"
                    else
                        pleamar-update || fail "pleamar-update failed (see above); Vitreus needs pleamar $pleamar_min or newer. Run it yourself, then run this again"
                        # Read the version again: a build that ends well can still leave an older pleamar first on the PATH.
                        pv=$( { pleamar --version 2> /dev/null || "$HOME/.local/bin/pleamar" --version 2> /dev/null; } | sed -n 's/^pleamar \([0-9][0-9.]*\).*/\1/p' | head -1)
                        if [ -z "$pv" ] || [ "$(printf '%s\n%s\n' "$pleamar_min" "$pv" | sort -V | head -1)" != "$pleamar_min" ]; then
                            fail "pleamar is still ${pv:-of an unknown version} after the update; Vitreus needs $pleamar_min or newer. Check which pleamar comes first in your PATH ($(command -v pleamar))"
                        fi
                        say "pleamar is now $pv"
                    fi
                elif ! $dry; then
                    fail "Vitreus needs pleamar $pleamar_min or newer and will not load on $pv. Run pleamar-update, then run this again"
                fi
            else
                fail "Vitreus needs pleamar $pleamar_min or newer (this is $pv) and pleamar-update was not found: reinstall pleamar from https://github.com/k4ditano/pleamar"
            fi
        fi
    else
        say "pleamar, the runtime Vitreus is written for, is not installed"
        if ask "install it now? (it is built from source; the first time takes a few minutes)"; then
            # pleamar's installer brings the window manager (pleamar-wm) and Marea too unless told --alone: ask first.
            pleamar_args=""
            if $do_wm && ! ask "install pleamar-wm, the window manager, as well? (otherwise only pleamar, for Hyprland and other compositors)"; then
                pleamar_args="-s -- --alone"
                do_wm=false
            fi
            if $dry; then
                would "run: curl -fsSL $pleamar_installer | sh $pleamar_args"
            else
                have curl || fail "curl is needed to fetch pleamar's installer"
                # shellcheck disable=SC2086
                curl -fsSL "$pleamar_installer" | sh $pleamar_args || fail "pleamar's installer failed (see above); Vitreus needs it"
                pv=$( { pleamar --version 2> /dev/null || "$HOME/.local/bin/pleamar" --version 2> /dev/null; } | sed -n 's/^pleamar \([0-9][0-9.]*\).*/\1/p' | head -1)
                if [ -n "$pv" ]; then say "pleamar is installed now ($pv)"
                else warn "pleamar's installer ended, but no pleamar answers: check that ~/.local/bin is in your PATH"
                fi
            fi
        else
            warn "without pleamar Vitreus cannot run. Install it from https://github.com/k4ditano/pleamar"
        fi
    fi

    # ── 3. the font ──
    # (Settings > About runs this with --refresh, which downloads what a theme draws in without asking: a theme added by an update has its typeface.)
    stage "the fonts"
    ask_font() { $refresh && return 0; ask "$1"; }
    if $deps; then
    if have fc-list && fc-list 2> /dev/null | grep -qi 'space grotesk'; then
        say "the Space Grotesk font is installed"
    elif ask_font "install the Space Grotesk font (into $fonts)?"; then
        if $dry; then
            would "download $font_url"
        else
            mkdir -p "$fonts"
            curl -fsSL -m 120 "$font_url" -o "$fonts/SpaceGrotesk[wght].ttf" || warn "could not download the font: install Space Grotesk yourself"
            have fc-cache && fc-cache -f "$fonts" > /dev/null 2>&1 || true
        fi
    fi
    # The Retro theme's Audiowide and the UwU theme's Mochiy Pop One: what Settings > Theme draws the shell in on those themes (the font picker can
    # choose any other). Without them the theme keeps Space Grotesk.
    if have fc-list && fc-list 2> /dev/null | grep -qi 'audiowide'; then
        say "the Audiowide font is installed"
    elif ask_font "install the Audiowide font, for the Retro theme (into $fonts_dot)?"; then
        if $dry; then
            would "download $dot_url"
        else
            mkdir -p "$fonts_dot"
            curl -fsSL -m 120 "$dot_url" -o "$fonts_dot/Audiowide-Regular.ttf" || warn "could not download Audiowide: the Retro theme will use Space Grotesk until you install it"
            curl -fsSL -m 120 "$dot_licence_url" -o "$fonts_dot/OFL.txt" 2> /dev/null || true
            have fc-cache && fc-cache -f "$fonts_dot" > /dev/null 2>&1 || true
        fi
    fi
    if have fc-list && fc-list 2> /dev/null | grep -qi 'mochiy pop one'; then
        say "the Mochiy Pop One font is installed"
    elif ask_font "install the Mochiy Pop One font, for the UwU theme (into $fonts_mochiy)?"; then
        if $dry; then
            would "download $mochiy_url"
        else
            mkdir -p "$fonts_mochiy"
            curl -fsSL -m 120 "$mochiy_url" -o "$fonts_mochiy/MochiyPopOne-Regular.ttf" || warn "could not download Mochiy Pop One: the UwU theme will use Space Grotesk until you install it"
            have fc-cache && fc-cache -f "$fonts_mochiy" > /dev/null 2>&1 || true
        fi
    fi
    if have fc-list && fc-list 2> /dev/null | grep -qi 'orbitron'; then
        say "the Orbitron font is installed"
    elif ask_font "install the Orbitron font, for the Cyber theme (into $fonts_orbitron)?"; then
        if $dry; then
            would "download $orbitron_url"
        else
            mkdir -p "$fonts_orbitron"
            curl -fsSL -m 120 "$orbitron_url" -o "$fonts_orbitron/Orbitron[wght].ttf" || warn "could not download Orbitron: the Cyber theme will use Space Grotesk until you install it"
            curl -fsSL -m 120 "$orbitron_licence_url" -o "$fonts_orbitron/OFL.txt" 2> /dev/null || true
            have fc-cache && fc-cache -f "$fonts_orbitron" > /dev/null 2>&1 || true
        fi
    fi
    if have fc-list && fc-list 2> /dev/null | grep -qi 'zen kurenaido'; then
        say "the Zen Kurenaido font is installed"
    elif ask_font "install the Zen Kurenaido font, for the Milk theme (into $fonts_kurenaido)?"; then
        if $dry; then
            would "download $kurenaido_url"
        else
            mkdir -p "$fonts_kurenaido"
            curl -fsSL -m 120 "$kurenaido_url" -o "$fonts_kurenaido/ZenKurenaido-Regular.ttf" || warn "could not download Zen Kurenaido: the Milkbox theme will use Space Grotesk until you install it"
            curl -fsSL -m 120 "$kurenaido_licence_url" -o "$fonts_kurenaido/OFL.txt" 2> /dev/null || true
            have fc-cache && fc-cache -f "$fonts_kurenaido" > /dev/null 2>&1 || true
        fi
    fi
    if have fc-list && fc-list 2> /dev/null | grep -qi 'titan one'; then
        say "the Titan One font is installed"
    elif ask_font "install the Titan One font, for the Proxy theme (into $fonts_titan)?"; then
        if $dry; then
            would "download $titan_url"
        else
            mkdir -p "$fonts_titan"
            curl -fsSL -m 120 "$titan_url" -o "$fonts_titan/TitanOne-Regular.ttf" || warn "could not download Titan One: the Proxy theme will use Space Grotesk until you install it"
            curl -fsSL -m 120 "$titan_licence_url" -o "$fonts_titan/OFL.txt" 2> /dev/null || true
            have fc-cache && fc-cache -f "$fonts_titan" > /dev/null 2>&1 || true
        fi
    fi
    if have fc-list && fc-list 2> /dev/null | grep -qi 'fuzzy bubbles'; then
        say "the Fuzzy Bubbles font is installed"
    elif ask_font "install the Fuzzy Bubbles font, for the Paper theme (into $fonts_fuzzy)?"; then
        if $dry; then
            would "download $fuzzy_url"
        else
            mkdir -p "$fonts_fuzzy"
            curl -fsSL -m 120 "$fuzzy_url" -o "$fonts_fuzzy/FuzzyBubbles-Regular.ttf" || warn "could not download Fuzzy Bubbles: the Paper theme will use Space Grotesk until you install it"
            curl -fsSL -m 120 "$fuzzy_bold_url" -o "$fonts_fuzzy/FuzzyBubbles-Bold.ttf" 2> /dev/null || true
            curl -fsSL -m 120 "$fuzzy_licence_url" -o "$fonts_fuzzy/OFL.txt" 2> /dev/null || true
            have fc-cache && fc-cache -f "$fonts_fuzzy" > /dev/null 2>&1 || true
        fi
    fi
    if have fc-list && fc-list 2> /dev/null | grep -qi 'kalam'; then
        say "the Kalam font is installed"
    elif ask_font "install the Kalam font, for the Doodle theme (into $fonts_kalam)?"; then
        if $dry; then
            would "download $kalam_url/Kalam-{Light,Regular,Bold}.ttf"
        else
            mkdir -p "$fonts_kalam"
            for w in Light Regular Bold; do
                curl -fsSL -m 120 "$kalam_url/Kalam-$w.ttf" -o "$fonts_kalam/Kalam-$w.ttf" || warn "could not download Kalam $w: the Doodle theme will use Space Grotesk until you install it"
            done
            curl -fsSL -m 120 "$kalam_url/OFL.txt" -o "$fonts_kalam/OFL.txt" 2> /dev/null || true
            have fc-cache && fc-cache -f "$fonts_kalam" > /dev/null 2>&1 || true
        fi
    fi
    fi
fi

# ── 4. the shell itself ────────────────────────────────────────────────────
stage "the shell itself"
have git || fail "git is needed to fetch Vitreus"
if $refresh; then
    :  # Settings has pulled already
elif [ -d "$dest/.git" ]; then
    if $dry; then would "run: git -C $dest pull --ff-only (your changes, and the monitors Settings chose, carried across)"; else
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
        # The add-ons that live in their own repositories were replaced by their newest release the last time: back to what git has, so
        # that they are not "your changes" and never stand in the pull's way (they are fetched again after it).
        "$dest/bin/vitreus-sync-addons" restore 2> /dev/null || true
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
        # (Not the bar's: it runs one copy per monitor, `screens: each`, and the chosen monitor is in bar.json. A line from before that names
        # one monitor, written into the new file, leaves out the per-monitor `$screen` and the scene does not load.)
        set_screens "" "$lock_s"
        if [ -n "$wmpal" ]; then
            cp "$wmpal" "$dest/wm-palette.plm"
            rm -f "$wmpal"
        fi
        after=$(g rev-parse HEAD)
        if [ "$before" != "$after" ]; then
            say "new since last time:"
            g log --no-decorate --format="    ${c_acc}%h${c0} %s" "$before..$after" | head -20
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

# ── 4b. the add-ons that live in their own repositories ────────────────────
# addons/bundled.toml pins each one, and the pin is what the copy in git holds. Here the newest release of each is fetched instead (BUNDLING.md),
# so a new install starts on what the author last published. Offline, or with no release, the pinned copy stays.
stage "bundled add-ons"
if $dry; then would "run: bin/vitreus-sync-addons latest (each bundled add-on's newest release)"
elif have python3 && [ -x "$dest/bin/vitreus-sync-addons" ]; then
    "$dest/bin/vitreus-sync-addons" latest || warn "some add-ons stayed on the release pinned in addons/bundled.toml"
else
    warn "python3 is needed to fetch the add-ons' newest releases: the pinned ones are used"
fi

# ── 5. the palettes ────────────────────────────────────────────────────────
# Vitreus rewrites both from your wallpaper, so git ignores them: the stock ones are the `.default` copies. palette.plm is the lock
# screen's, wm-palette.plm pleamar-wm's (its window borders).
stage "the palettes"
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
stage "the helpers"
if [ -x "$dest/bin/vitreus-clipimg" ] || $dry; then
    run mkdir -p "$HOME/.local/bin"
    run ln -sf "$dest/bin/vitreus-clipimg" "$HOME/.local/bin/vitreus-clipimg"
    # The authentication dialog's agent, which the shell starts by itself. Only one polkit agent can hold a session: if another is
    # already running (polkit-gnome, hyprpolkitagent...), it keeps answering and this one says so and ends.
    [ -x "$dest/bin/vitreus-polkit-agent" ] && run ln -sf "$dest/bin/vitreus-polkit-agent" "$HOME/.local/bin/vitreus-polkit-agent"
    # Settings > System monitor's data source: started by the shell while that page is showing, and stopped when it is not.
    [ -x "$dest/bin/vitreus-sysmon" ] && run ln -sf "$dest/bin/vitreus-sysmon" "$HOME/.local/bin/vitreus-sysmon"
    [ -x "$dest/bin/vitreus-battery" ] && run ln -sf "$dest/bin/vitreus-battery" "$HOME/.local/bin/vitreus-battery"       # the battery card: health, charge mode and limits
    [ -x "$dest/bin/vitreus-greeter" ] && run ln -sf "$dest/bin/vitreus-greeter" "$HOME/.local/bin/vitreus-greeter"       # Settings > Greeter: the login screen's picture or video, and its clock
    [ -x "$dest/bin/vitreus-term" ] && run ln -sf "$dest/bin/vitreus-term" "$HOME/.local/bin/vitreus-term"
    # The keeper the autostart lines run each scene under: it starts a scene again when it stops (a crash on a monitor's wake).
    [ -x "$dest/bin/vitreus-files" ] && run ln -sf "$dest/bin/vitreus-files" "$HOME/.local/bin/vitreus-files"
    [ -x "$dest/bin/vitreus-view" ] && run ln -sf "$dest/bin/vitreus-view" "$HOME/.local/bin/vitreus-view"             # View, the picture viewer (view/view.plm)
    [ -x "$dest/bin/vitreus-keep" ] && run ln -sf "$dest/bin/vitreus-keep" "$HOME/.local/bin/vitreus-keep"
    [ -x "$dest/bin/vitreus-themes" ] && run ln -sf "$dest/bin/vitreus-themes" "$HOME/.local/bin/vitreus-themes"       # the shell reads the theme files through it
    [ -x "$dest/bin/vitreus-wallhaven" ] && run ln -sf "$dest/bin/vitreus-wallhaven" "$HOME/.local/bin/vitreus-wallhaven"       # Settings > Wallpaper > Wallhaven fetches through it
    [ -x "$dest/bin/vitreus-edit" ] && run ln -sf "$dest/bin/vitreus-edit" "$HOME/.local/bin/vitreus-edit"             # opens a file in the person's editor (add-ons' settings gears)
    [ -x "$dest/bin/vitreus-addons" ] && run ln -sf "$dest/bin/vitreus-addons" "$HOME/.local/bin/vitreus-addons"       # and the add-ons in ~/.config/pleamar/vitreus-addons (never touched here)
    [ -x "$dest/bin/vitreus-sync-addons" ] && run ln -sf "$dest/bin/vitreus-sync-addons" "$HOME/.local/bin/vitreus-sync-addons"
    [ -x "$dest/bin/vitreus-feedfetch" ] && run ln -sf "$dest/bin/vitreus-feedfetch" "$HOME/.local/bin/vitreus-feedfetch"       # the News & Weather add-on (addons/news-weather) reads its feeds through it
    [ -x "$dest/bin/vitreus-tvremote" ] && run ln -sf "$dest/bin/vitreus-tvremote" "$HOME/.local/bin/vitreus-tvremote"       # the TV Remote add-on (addons/tvremote) talks to the TV through it
    [ -x "$dest/bin/vitreus-eq" ] && run ln -sf "$dest/bin/vitreus-eq" "$HOME/.local/bin/vitreus-eq"       # the Equalizer add-on (addons/eq) filters the sound through it
    # For a problem report that does not need the shell to be running: `vitreus-report` writes one text file to read and send.
    [ -x "$dest/bin/vitreus-report" ] && run ln -sf "$dest/bin/vitreus-report" "$HOME/.local/bin/vitreus-report"
    # A desktop widget carried over to another monitor hears the mouse button come up through this (the compositor stops telling it at the edge).
    [ -x "$dest/bin/vitreus-btnwait" ] && run ln -sf "$dest/bin/vitreus-btnwait" "$HOME/.local/bin/vitreus-btnwait"
    # Files among the desktop's programs: its icon and its entry always, and, when asked, the file manager (folders open in it, and «Show in folder» in other programs answer with it): files/integrate.sh
    # (--uninstall and `sh files/integrate.sh --remove` take it away and put the old folder opener back). Not on a trial next to another shell, and not on --refresh, which asks nothing.
    if [ -f "$dest/files/integrate.sh" ]; then
        files_flag=--no-set
        if ! $trial && ! $refresh && ask "make Files the file manager (folders open in it, and «Show in folder» in other programs)?"; then files_flag=--set; fi
        run sh "$dest/files/integrate.sh" $files_flag || warn "could not: run  sh $dest/files/integrate.sh  yourself"
    fi
    # View among the desktop's programs: its icon and its entry always («Open with» lists it), and, when asked, what opens pictures: view/integrate.sh (it keeps what
    # opened each kind of picture before; --uninstall and `sh view/integrate.sh --remove` put that back). Not on a trial next to another shell, and not on --refresh.
    if [ -f "$dest/view/integrate.sh" ]; then
        view_flag=--no-set
        if ! $trial && ! $refresh && ask "make View what opens pictures and videos?"; then view_flag=--set; fi
        run sh "$dest/view/integrate.sh" $view_flag || warn "could not: run  sh $dest/view/integrate.sh  yourself"
    fi
    # Caffeine's idle inhibitor (a few lines of C: the compositor's own idle timer, pleamar-wm's, only listens to a Wayland client). Built here.
    if [ -f "$dest/bin/vitreus-inhibit.c" ]; then
        if $dry; then
            would "build: vitreus-inhibit into $HOME/.local/bin"
        elif command -v gcc > /dev/null 2>&1 && command -v wayland-scanner > /dev/null 2>&1 && pkg-config --exists wayland-client 2> /dev/null; then
            inhibit_proto=/usr/share/wayland-protocols/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml
            inhibit_tmp=$(mktemp -d)
            if wayland-scanner client-header "$inhibit_proto" "$inhibit_tmp/idle-inhibit.h" \
                && wayland-scanner private-code "$inhibit_proto" "$inhibit_tmp/idle-inhibit.c" \
                && gcc -O2 -I"$inhibit_tmp" -o "$HOME/.local/bin/vitreus-inhibit" "$dest/bin/vitreus-inhibit.c" "$inhibit_tmp/idle-inhibit.c" $(pkg-config --cflags --libs wayland-client); then
                :
            else
                log "vitreus-inhibit did not build: Caffeine will not keep pleamar-wm's screens on"
            fi
            rm -rf "$inhibit_tmp"
        else
            log "vitreus-inhibit not built (needs gcc, wayland-scanner and the wayland headers): Caffeine will not keep pleamar-wm's screens on"
        fi
    fi
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "$HOME/.local/bin is not in your PATH: the launcher's clipboard pictures need it" ;; esac
# Hyprland does not read ~/.bashrc: if ~/.local/bin is only added there, its binds and exec-once lines never find
# `pleamar`. hypr_vitreus.lua adds it to PATH itself; whatever you start from hyprland.lua has to do the same.
fi

# ── 6. Hyprland key binds ──────────────────────────────────────────────────
# hypr_vitreus.lua (SUPER + L lock, SUPER + Space Settings) is linked into ~/.config/hypr and loaded from hyprland.lua
# after hypr_style.lua. Settings > Display and > Hyprland keep what you choose in vitreus_monitors.lua and
# vitreus_hypr.lua, loaded the same way (they do not exist until something is kept, hence pcall); so does vitreus_colors.lua, the
# window border colours Iris sets.
stage "the key binds"
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
                would "add pcall(require, \"$mod\") to $hyprlua"
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
            would "back up $hyprlua and add four pcall(require, ...) lines to its end"
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
            if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
                say "added to $hyprlua (the old one is $hyprlua.before-vitreus); Hyprland reloads it by itself"
            else
                say "added to $hyprlua (the old one is $hyprlua.before-vitreus), for when you log in to Hyprland; this session is not Hyprland, so it changes nothing now"
            fi
        fi
    fi
fi

# ── 6c. niri ───────────────────────────────────────────────────────────────
# On niri the shell asks `hyprctl` (pleamar-wm/hyprctl, which hands over to hyprctl-niri) for the monitors, windows and workspaces, and keeps the room round the
# windows (the frame, the docks) and the focus ring in vitreus.kdl, which it writes next to config.kdl. So config.kdl includes that file and the key binds, and starts
# the shell with the desktop. It is the end of the file: a strut or a key set there is the shell's.
niridir="$conf/niri"
nirikdl="$niridir/config.kdl"
if have niri && $do_binds; then
    if [ ! -f "$nirikdl" ]; then
        say "niri is installed but there is no $nirikdl yet: run niri once (it writes one), then ./install.sh again to add Vitreus's lines"
    elif grep -q 'include "vitreus.kdl"' "$nirikdl"; then
        say "niri's config already includes vitreus.kdl"
        run ln -sf "$dest/niri_vitreus.kdl" "$niridir/niri_vitreus.kdl"
    elif ask "add Vitreus's lines to $nirikdl (start with niri, the room round the windows, its key binds)?"; then
        run mkdir -p "$HOME/.local/bin"
        if [ ! -e "$HOME/.local/bin/hyprctl" ] || [ -L "$HOME/.local/bin/hyprctl" ] || grep -q 'hyprctl. for a desktop that is not Hyprland' "$HOME/.local/bin/hyprctl" 2> /dev/null; then
            run ln -sf "$dest/pleamar-wm/hyprctl" "$HOME/.local/bin/hyprctl"
        fi
        run ln -sf "$dest/niri_vitreus.kdl" "$niridir/niri_vitreus.kdl"
        if $dry; then
            would "back up $nirikdl and add the include lines (and a spawn-at-startup for pleamar --autostart) to its end"
        else
            : >> "$niridir/vitreus.kdl"
            cp "$nirikdl" "$nirikdl.before-vitreus"
            {
                echo ""
                echo "// >>> vitreus (added by its installer; ./install.sh --uninstall takes it out)"
                grep -q 'pleamar.*--autostart' "$nirikdl" || echo 'spawn-at-startup "pleamar" "--autostart"'
                echo 'include "niri_vitreus.kdl"'
                echo 'include "vitreus.kdl"'
                echo "// <<< vitreus"
            } >> "$nirikdl"
            say "added to $nirikdl (the old one is $nirikdl.before-vitreus); niri reloads it by itself"
        fi
    fi
fi

# ── start with the desktop ─────────────────────────────────────────────────
# Each scene runs under bin/vitreus-keep, which starts it again if it stops while the session lasts.
stage "starting with the desktop"
$dry || mkdir -p "$data/pleamar/vitreus"
line="vitreus-keep $dest/vitreus.plm \"\$HOME/.local/share/pleamar/vitreus/vitreus.log\""
# PLEAMAR_SWAPCHAIN=1: pleamar 0.4's own frames let the lock commit its region before its first frame, and Hyprland kills a lock
# surface for that ("Null buffer attached"): the lock screen died the moment it showed. Take it out once pleamar fixes it.
lockline="PLEAMAR_SWAPCHAIN=1 vitreus-keep $dest/lockscreen/lockscreen.plm"
transline="vitreus-keep $dest/wptrans/wptrans.plm"
clockline="vitreus-keep $dest/desktopclock/desktopclock.plm"
sysmonline="vitreus-keep $dest/desktopsysmon/desktopsysmon.plm"
if $do_autostart; then
    # Lines from before the keeper started the scenes straight, once: they go through it now (with or without VAR=value words in front: a line that
    # keeps the shell outside the keeper is one that nothing starts again when Settings stops it to apply a theme's font).
    envp='([A-Za-z_][A-Za-z0-9_]*=[^ ]+ )*'
    if [ -f "$autostart" ] && grep -qE "^${envp}pleamar --scene $dest/.*\.plm --no-hud\$" "$autostart"; then
        if $dry; then would "put the scenes in $autostart under vitreus-keep"; else
            sed -i -E "s|^(${envp})pleamar --scene ($dest/vitreus\.plm) --no-hud\$|\1vitreus-keep \3 \"\$HOME/.local/share/pleamar/vitreus/vitreus.log\"|; s|^(${envp})pleamar --scene ($dest/[^ ]*\.plm) --no-hud\$|\1vitreus-keep \3|" "$autostart"
            say "the scenes in $autostart now run under vitreus-keep, which starts them again if they stop"
        fi
    fi
    if [ -f "$autostart" ] && grep -q 'vitreus.plm' "$autostart"; then
        say "it is already in $autostart"
    elif ask "start Vitreus with the desktop (add a line to $autostart)?"; then
        run mkdir -p "$(dirname "$autostart")"
        if $dry; then would "add to $autostart: $line"; else printf '%s\n' "$line" >> "$autostart"; fi
    fi
    # The lock screen is a scene of its own (a session lock has to be its own program, so that restarting the shell cannot unlock
    # the session), and the lock buttons and SUPER + L only work while it runs: it always starts with the desktop.
    if [ -f "$autostart" ] && grep -q "^vitreus-keep $dest/lockscreen/lockscreen\.plm" "$autostart"; then
        if $dry; then would "start the lock screen in $autostart with PLEAMAR_SWAPCHAIN=1"; else
            sed -i "s|^vitreus-keep \($dest/lockscreen/lockscreen\.plm\)|PLEAMAR_SWAPCHAIN=1 vitreus-keep \1|" "$autostart"
            say "the lock screen in $autostart now starts with PLEAMAR_SWAPCHAIN=1 (pleamar 0.4 otherwise crashes it on lock)"
        fi
    elif [ -f "$autostart" ] && grep -q 'lockscreen/lockscreen.plm' "$autostart"; then
        say "the lock screen is already in $autostart"
    else
        run mkdir -p "$(dirname "$autostart")"
        if $dry; then would "add to $autostart: $lockline"; else printf '%s\n' "$lockline" >> "$autostart"; fi
        say "the lock screen starts with the desktop too (a line in $autostart): the lock buttons and SUPER + L need it"
    fi
    # The wallpaper picker's hexagon dissolve is a scene of its own as well; without it a pick uses awww's own transition.
    if [ -f "$autostart" ] && grep -q 'wptrans/wptrans.plm' "$autostart"; then
        say "the wallpaper transition is already in $autostart"
    else
        if $dry; then would "add to $autostart: $transline"; else printf '%s\n' "$transline" >> "$autostart"; fi
        say "the wallpaper picker's hexagon dissolve starts with the desktop too (a line in $autostart)"
    fi
    # The desktop clock (digits of glass on the bottom layer) is a scene of its own as well; it starts shown, and turns off from the launcher.
    if [ -f "$autostart" ] && grep -q 'desktopclock/desktopclock.plm' "$autostart"; then
        say "the desktop clock is already in $autostart"
    else
        if $dry; then would "add to $autostart: $clockline"; else printf '%s\n' "$clockline" >> "$autostart"; fi
        say "the desktop clock starts with the desktop too (a line in $autostart); \"Desktop clock: toggle\" in the launcher turns it off"
    fi
    # The desktop system monitor (a small glass card on the bottom layer) is a scene of its own too; it starts hidden, and "Desktop system monitor: toggle" in the launcher shows it.
    if [ -f "$autostart" ] && grep -q 'desktopsysmon/desktopsysmon.plm' "$autostart"; then
        say "the desktop system monitor is already in $autostart"
    else
        if $dry; then would "add to $autostart: $sysmonline"; else printf '%s\n' "$sysmonline" >> "$autostart"; fi
        say "the desktop system monitor starts with the desktop too, hidden (a line in $autostart); \"Desktop system monitor: toggle\" in the launcher shows it"
    fi
    # The UwU cursor trail: a scene of its own that only draws while the theme is UwU. The shell starts it when UwU is chosen and stops it on any
    # other theme (see push_look in vitreus.luau), so it no longer starts with the desktop: a line from before is taken out.
    if [ -f "$autostart" ] && grep -q 'cursortrail/cursortrail.plm' "$autostart"; then
        if $dry; then would "take the UwU cursor trail's line out of $autostart"; else sed -i '/cursortrail\/cursortrail\.plm/d' "$autostart"; fi
        say "the UwU cursor trail no longer starts with the desktop: Vitreus starts it while the theme is UwU"
    fi
    # (The audio visualiser is part of the shell itself now, the bottom edge rising into the music: no scene of its own, no line here.)
    # The desktop stickers and the desktop's right-click menu are scenes of their own too, but Vitreus starts them itself (see vitreus.luau), so they have no line here.
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
        if $dry; then would "add to $autostart: awww-daemon, awww restore, hypridle, wl-paste --watch cliphist store"; else
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

# ── the idle config (Settings > Idle) ──────────────────────────────────────
# The Idle page only writes idle.conf in the data folder; hypridle waits for those times only if ~/.config/hypr/hypridle.conf `source`s it.
# Without that line the sliders do nothing (an old hard-coded lock still fires, Never or not). So: no file, or the stock one of an earlier
# version, gets Vitreus's (kept in a backup); a file of the user's own is left alone, but the line it needs is said out loud.
if $do_autostart && [ -f "$dest/pleamar-wm/hypridle.conf" ]; then
    idle_src="$dest/pleamar-wm/hypridle.conf"
    idle_dst="$conf/hypr/hypridle.conf"
    if [ -L "$idle_dst" ] && [ "$(readlink -f "$idle_dst")" = "$(readlink -f "$idle_src")" ]; then
        say "hypridle already reads Settings > Idle"
    elif [ -f "$idle_dst" ] && grep -q 'vitreus/idle\.conf' "$idle_dst"; then
        say "hypridle.conf already reads Settings > Idle"
    elif [ ! -e "$idle_dst" ]; then
        run mkdir -p "$conf/hypr"
        run ln -sf "$idle_src" "$idle_dst"
        say "hypridle reads Settings > Idle now ($idle_dst)"
    elif grep -q 'lockscreen' "$idle_dst" && [ "$(grep -c '^[[:space:]]*listener' "$idle_dst")" -le 2 ]; then
        # the stock file of an earlier version: a lock at 5 minutes and the screen off, hard-coded, which would ignore the Idle page
        run cp -p "$idle_dst" "$idle_dst.before-vitreus-idle"
        run ln -sf "$idle_src" "$idle_dst"
        say "hypridle reads Settings > Idle now; your old $idle_dst is kept as $idle_dst.before-vitreus-idle"
    else
        warn "$idle_dst has listeners of yours, so Settings > Idle does nothing yet: add  source = ~/.local/share/pleamar/vitreus/idle.conf  to it and remove your own lock, screen-off and suspend listeners"
    fi
fi

# ── 7. pleamar-wm ──────────────────────────────────────────────────────────
# Vitreus runs on pleamar-wm (a session chosen at the login screen) as well as on Hyprland. Everything below is skipped when
# pleamar-wm is not installed, and each file of yours is only replaced when it is still the stock one.
stage "pleamar-wm"
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
    # Files floats rather than tiling (on Hyprland, hypr_vitreus.lua has the same rule).
    wmconf="$conf/pleamar/session.conf"
    if [ -f "$wmconf" ] && grep -q '^window app=vitreus\.files ' "$wmconf"; then
        say "pleamar-wm already floats Files"
    else
        run mkdir -p "$conf/pleamar"
        if $dry; then would "add to $wmconf: window app=vitreus.files float"; else
            printf '\n# Vitreus Files floats rather than tiling (added by its installer; ./install.sh --uninstall takes it out)\nwindow app=vitreus.files float\n' >> "$wmconf"
            say "pleamar-wm floats Files now (a line in $wmconf)"
        fi
    fi
    # hyprctl for a desktop that is not Hyprland (ahead of /usr/bin; on Hyprland it hands over to the real one).
    # (An older copy of this file, from before it was linked, is replaced by the link: it would never learn the desktops added since, such as niri.)
    if [ ! -e "$HOME/.local/bin/hyprctl" ] || [ -L "$HOME/.local/bin/hyprctl" ] || grep -q 'hyprctl. for a desktop that is not Hyprland' "$HOME/.local/bin/hyprctl" 2> /dev/null; then
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

# ── the login screen ───────────────────────────────────────────────────────
# An SDDM theme in the lock screen's look. It needs root (the theme goes in /usr/share/sddm/themes), so it is asked for, and --refresh leaves it alone. Where SDDM already has
# a theme, its own installer asks before replacing it (--yes says yes); with no keyboard it only installs it.
stage "the login screen"
if $do_login && ! $refresh && [ -x "$dest/sddm/install.sh" ] && { have sddm || [ -d /usr/share/sddm/themes ]; }; then
    if [ -d /usr/share/sddm/themes/vitreus ] && cmp -s "$dest/sddm/vitreus/Main.qml" /usr/share/sddm/themes/vitreus/Main.qml; then
        say "the Vitreus login screen is installed (sh $dest/sddm/install.sh [IMAGE] makes it again, with another picture)"
    elif [ -d /usr/share/sddm/themes/vitreus ]; then
        # An older copy: install it again (with the picture or video it already shows; pass another to sddm/install.sh to change it)
        if ask "update the Vitreus login screen, the SDDM theme (needs sudo)?"; then
            run_kept sh "$dest/sddm/install.sh" --yes || warn "could not: run  sh $dest/sddm/install.sh  yourself"
        fi
    elif ask "install the Vitreus login screen, an SDDM theme (needs sudo)?"; then
        if $assume_yes; then login_flags="--yes"; else login_flags=""; fi
        run_kept sh "$dest/sddm/install.sh" $login_flags || warn "could not: run  sh $dest/sddm/install.sh  yourself"
    fi
fi

# ── services it talks to ───────────────────────────────────────────────────
stage "the services"
if have systemctl; then
    systemctl is-active --quiet bluetooth 2> /dev/null || say "Bluetooth is off: sudo systemctl enable --now bluetooth"
    systemctl is-active --quiet NetworkManager 2> /dev/null || say "NetworkManager is not running: Wi-Fi needs it (sudo systemctl enable --now NetworkManager)"
    have powerprofilesctl && { systemctl is-active --quiet power-profiles-daemon 2> /dev/null || say "power-profiles-daemon is not running: the power profile in Power needs it (sudo systemctl enable --now power-profiles-daemon)"; }
fi

ui_done
$refresh && exit 0
# ── --test: run Vitreus now, in place of the other shell, and nothing else changed ──
if $trial; then
    if $dry; then
        say "(--dry-run: --test would stop Quickshell, if it is running, and start Vitreus)"
    else
        [ -n "${WAYLAND_DISPLAY:-}" ] || fail "--test starts Vitreus on the screen: run it from inside your Wayland session"
        mkdir -p "$data/pleamar/vitreus"
        : > "$trial_file"
        # Remember how each running Quickshell was started (qs -c name ...), so --stop can start it again.
        for pid in $(pgrep -x qs; pgrep -x quickshell); do
            args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null | sed 's/ $//')
            case "$args" in *" ipc "*|*" kill"*|*" list"*|"") continue ;; esac
            grep -qxF "$args" "$trial_file" || echo "$args" >> "$trial_file"
        done
        if [ -s "$trial_file" ]; then
            say "stopping your Quickshell (./install.sh --stop starts it again)"
            pkill -x qs; pkill -x quickshell
            sleep 1
        fi
        export PATH="$HOME/.local/bin:$PATH"
        setsid vitreus-keep "$dest/vitreus.plm" "$data/pleamar/vitreus/vitreus.log" > /dev/null 2>&1 < /dev/null &
        say "Vitreus is starting. Nothing starts at login and no key binds were added."
        say "To go back to your shell: ./install.sh --stop     To keep Vitreus: ./install.sh"
    fi
    exit 0
fi

heading "Start it"
row "now" "$line"
row "the lock screen" "$lockline"
row "hexagon dissolve" "$transline"
row "with the desktop" "autostart is read by pleamar's own session; on Hyprland run \`pleamar --autostart\`:"
row "" "hyprland.lua:   hl.on(\"hyprland.start\", function () hl.exec_cmd(\"PATH=\\\"\$HOME/.local/bin:\$PATH\\\" pleamar --autostart\") end)"
row "" "hyprland.conf:  exec-once = ~/.local/bin/pleamar --autostart   (Hyprland's PATH may lack ~/.local/bin)"
row "pleamar-wm" "log out and choose «pleamar-wm» in the login screen (SDDM: click the session name under the password field)"
heading "Good to know"
row "keys (with the binds)" "SUPER + Space launcher, SUPER + SHIFT + Space settings, SUPER + B wallpaper picker, SUPER + L lock (see lockscreen/README.md)"
row "daemons" "awww, hypridle and the clipboard history start from $autostart (nothing to add to hyprland.lua)"
row "notifications" "it becomes the desktop's notification server when it starts, and gives that back when it exits"
row "its settings" "$data/pleamar/vitreus  (iris.json, weather-config.json, ...)"
row "update later" "run this script again"
echo
