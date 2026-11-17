#!/bin/sh
# install.sh [IMAGE] [--set | --no-set] [--yes]: installs the Vitreus login screen, a theme for SDDM, and (asking, when there already is one) makes it the one in use.
#   IMAGE     a picture or video for the login screen, kept as your choice (as Settings > Greeter does); the theme itself carries assets/greeter.jpeg (.mp4, .mkv, .webm, .mov), played on a loop, muted
#   --set     make it the theme in use without asking          --no-set   only install it: leave the theme in use as it is
#   --yes     answer yes to the question (the same as --set)    --remove   take it away and put the theme that was in use back
# It uses sudo for /usr/share/sddm/themes and for SDDM's configuration. Try it first, with nothing installed:  ./build-assets.sh /tmp/vitreus-greeter  and
#   QT_QPA_PLATFORM=xcb sddm-greeter-qt6 --test-mode --theme /tmp/vitreus-greeter
set -e
here=$(cd "$(dirname "$0")" && pwd)
themes=/usr/share/sddm/themes
# Your face and the old theme setting are kept here. The old setting must not stay in /etc/sddm.conf.d: SDDM reads every file in it, whatever its name, and a later name wins.
shared=/usr/local/share/vitreus-greeter
setmode=ask
action=install
image=""
for a in "$@"; do
    case "$a" in
        --set|--yes|-y) setmode=yes ;;
        --no-set) setmode=no ;;
        --remove) action=remove ;;
        -*) echo "I do not know $a" >&2; exit 1 ;;
        *) image=$a ;;
    esac
done

# The theme in use now: the last Current= of SDDM's files, the ones that win last (the defaults, the drop-ins, then /etc/sddm.conf).
current_theme() {
    cat /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf /etc/sddm.conf 2> /dev/null |
        awk '/^\[/ { sec = $0 } sec == "[Theme]" && /^Current=/ { sub(/^Current=/, ""); v = $0 } END { print v }'
}
# The file that says it (the one that wins), or the drop-in this makes when none does.
theme_file() {
    f=$(grep -l '^Current=' /etc/sddm.conf.d/*.conf /etc/sddm.conf 2> /dev/null | tail -1 || true)
    [ -n "$f" ] && echo "$f" || echo /etc/sddm.conf.d/theme.conf
}

if [ "$action" = remove ]; then
    f=$(theme_file)
    bak=$shared/$(basename "$f").before-vitreus
    # Only the `Current=` line changes, to the theme in use before (its name, from bin/vitreus-greeter's root-owned note, or read out of an older
    # backup), or goes when there is none. (The whole file was copied back from a folder the user can write, as root, or deleted outright
    # when there was no backup, taking any other setting in it along.)
    if [ "$(current_theme)" = vitreus ] && [ -f "$f" ]; then
        prev=$(head -n 1 /var/lib/vitreus-greeter/previous-theme 2> /dev/null)
        [ -n "$prev" ] || prev=$(awk '/^\[/ { sec = $0 } sec == "[Theme]" && /^Current=/ { sub(/^Current=/, ""); v = $0 } END { print v }' "$bak" 2> /dev/null)
        case $prev in *[!A-Za-z0-9._-]*|""|vitreus|.*) prev= ;; esac
        if [ -n "$prev" ] && [ -d "$themes/$prev" ]; then sudo sed -i "s|^Current=vitreus\$|Current=$prev|" "$f"
        else sudo sed -i '/^Current=vitreus$/d' "$f"; fi
    fi
    rm -f "$bak"
    sudo rm -rf "$themes/vitreus" /usr/local/share/vitreus-greeter /var/lib/vitreus-greeter
    echo "taken away; the login screen uses: $(current_theme | sed 's/^$/SDDM'"'"'s own/')"
    exit 0
fi

[ -d "$themes" ] || { echo "SDDM's themes are not in $themes: is SDDM installed?" >&2; exit 1; }
[ -z "$image" ] || [ -f "$image" ] || { echo "no file at $image" >&2; exit 1; }
# The installer downloads Space Grotesk as one variable font; build-assets.sh needs python-fonttools to cut the three weights the greeter uses from it (without it they all look the same).
font=$(fc-match -f '%{file}' "Space Grotesk" 2> /dev/null)
fdir=$(dirname "$font")
if [ -f "$font" ] && [ ! -f "$fdir/static/SpaceGrotesk-Bold.ttf" ] && [ ! -f "$fdir/SpaceGrotesk-Bold.ttf" ] && ! python3 -c 'import fontTools' 2> /dev/null; then
    if command -v pacman > /dev/null 2>&1; then
        answer=n
        printf 'The login screen needs python-fonttools to cut its font weights. Install it with sudo pacman? [Y/n] '
        if [ -r /dev/tty ]; then read -r answer < /dev/tty || answer=n; else echo "(no keyboard to ask on: skipping)"; fi
        case "$answer" in n|N|no|NO) ;; *) sudo pacman -S --needed --noconfirm python-fonttools || echo "could not install python-fonttools: the login screen will draw every weight the same" >&2 ;; esac
    else
        echo "python-fonttools is not installed: the login screen will draw every weight of its font the same" >&2
    fi
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The theme carries the repository's picture (Settings > Greeter's "Use the default"). A picture or video given here, or one an older install carried of its own,
# is kept as your choice in the folder below (bin/vitreus-greeter): before the old copy goes, so it can still be read.
"$here/build-assets.sh" "$tmp/vitreus"
greeter=$here/../bin/vitreus-greeter
[ -d "$shared" ] && [ -w "$shared" ] && [ -x "$greeter" ] && "$greeter" adopt "$tmp/vitreus/background.jpg" || true
sudo rm -rf "$themes/vitreus"
sudo cp -r "$tmp/vitreus" "$themes/vitreus"
sudo chmod -R a+rX "$themes/vitreus"
echo "installed in $themes/vitreus"
# Your face is kept in a folder that is yours (the greeter cannot read your home folder), so that changing your picture needs no sudo: Vitreus's Settings copy it there.
sudo install -d -o "$(id -un)" -m 755 "$shared"
[ -f "$HOME/.face" ] && "$here/refresh-avatar.sh" || true
if [ -n "$image" ]; then
    if [ -x "$greeter" ] && "$greeter" set "$image" > /dev/null; then echo "the login screen shows $(basename "$image") (Settings > Greeter changes it)"
    else echo "could not use $image: choose it in Settings > Greeter" >&2; fi
fi

# Making it the one in use: with none (or already this one) there is nothing to replace; with another one, ask.
now=$(current_theme)
use=false
if [ -z "$now" ] || [ "$now" = vitreus ]; then
    use=true
elif [ "$setmode" = yes ]; then
    use=true
elif [ "$setmode" = ask ]; then
    printf 'SDDM already uses the theme "%s". Use the Vitreus login screen instead? [y/N] ' "$now"
    answer=n
    if [ -r /dev/tty ]; then read -r answer < /dev/tty || answer=n; else echo "(no keyboard to ask on: leaving it)"; fi
    case "$answer" in y|Y|yes|YES) use=true ;; esac
fi
if $use; then
    f=$(theme_file)
    bak=$shared/$(basename "$f").before-vitreus
    sudo install -d -o "$(id -un)" -m 755 "$shared"
    [ -f "$f" ] && [ ! -f "$bak" ] && cp "$f" "$bak"
    # the theme in use before, by name, where only root can write it (what --remove and bin/vitreus-greeter put back)
    prev=$(current_theme)
    if [ -n "$prev" ] && [ "$prev" != vitreus ] && [ ! -s /var/lib/vitreus-greeter/previous-theme ]; then
        sudo install -d -o root -g root -m 755 /var/lib/vitreus-greeter && printf '%s\n' "$prev" | sudo tee /var/lib/vitreus-greeter/previous-theme > /dev/null
    fi
    if [ -f "$f" ] && grep -q '^Current=' "$f"; then
        sudo sed -i 's|^Current=.*|Current=vitreus|' "$f"
    elif [ -f "$f" ] && grep -q '^\[Theme\]' "$f"; then
        sudo sed -i 's|^\[Theme\]|[Theme]\nCurrent=vitreus|' "$f"
    else
        printf '\n[Theme]\nCurrent=vitreus\n' | sudo tee -a "$f" > /dev/null
    fi
    echo "it is the login screen now (SDDM reads its settings only when it starts: reboot, or restart it from a TTY with  sudo systemctl restart sddm  to see it). To see it without that:"
else
    echo "the login screen is still \"$now\". To use this one: $0 --set. To see it first:"
fi
echo "  QT_QPA_PLATFORM=xcb sddm-greeter-qt6 --test-mode --theme $themes/vitreus"
