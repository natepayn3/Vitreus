#!/bin/sh
# integrate.sh [--set | --no-set] [--remove]: puts View (vitreus-view) among the desktop's programs, and, when asked, makes it what opens pictures.
#   always      the icon (~/.local/share/icons/hicolor/scalable/apps/vitreus-view.svg) and the entry (~/.local/share/applications/vitreus-view.desktop, with the path of
#               this copy in its Exec: the programs that start it do not have ~/.local/bin on their PATH). It says which pictures it opens (MimeType), so «Open with»
#               lists it; what opens them by default is left alone
#   --set       also make it the default for every kind of picture it lists (xdg-mime, in ~/.config/mimeapps.list)
#   --no-set    only the icon and the entry (the same as no option)
#   --remove    take all of it away, and put back what opened each kind of picture before
# What opened each kind before is kept in ~/.local/share/pleamar/vitreus/view-previous-handlers, one line a kind, the first time it is changed: «<type> <entry>» when the
# person had chosen one, «<type> -» when it was only the desktop's own order (then --remove takes out the line this wrote, and that order rules again).
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest=$(cd "$here/.." && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
conf=${XDG_CONFIG_HOME:-$HOME/.config}
state=$data/pleamar/vitreus
mimeapps=$conf/mimeapps.list
mode=no
action=install
for a in "$@"; do
    case "$a" in
        --set|--yes|-y) mode=yes ;;
        --no-set) mode=no ;;
        --remove) action=remove ;;
        *) echo "integrate.sh: I do not know $a" >&2; exit 1 ;;
    esac
done
icon=$data/icons/hicolor/scalable/apps/vitreus-view.svg
entry=$data/applications/vitreus-view.desktop
prev=$state/view-previous-handlers
say() { printf 'vitreus · %s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
types=$(sed -n 's/^MimeType=//p' "$here/vitreus-view.desktop" | tr ';' ' ')
# What the person chose for a kind (its line in the [Default Applications] part of mimeapps.list), not what the desktop's order would give.
explicit() { awk -v t="$1" '/^\[/ { d = ($0 == "[Default Applications]") } d && index($0, t "=") == 1 { sub(/^[^=]*=/, ""); sub(/;.*/, ""); print; exit }' "$mimeapps" 2> /dev/null; }
refresh_caches() {
    have update-desktop-database && update-desktop-database "$data/applications" 2> /dev/null || true
    have gtk-update-icon-cache && [ -f "$data/icons/hicolor/index.theme" ] && gtk-update-icon-cache -q -t -f "$data/icons/hicolor" 2> /dev/null || true
}
# A line of mimeapps.list taken out, in place (a copy over the file: it may be a link into someone's dotfiles, which `sed -i` would turn into a file).
drop_line() {
    [ -f "$mimeapps" ] || return 0
    tmp=$(mktemp)
    grep -v -x -F "$1=vitreus-view.desktop" "$mimeapps" | grep -v -x -F "$1=vitreus-view.desktop;" > "$tmp" || true
    cat "$tmp" > "$mimeapps"
    rm -f "$tmp"
}

if [ "$action" = remove ]; then
    for t in $types; do
        [ "$(explicit "$t")" = vitreus-view.desktop ] || continue
        old=$(awk -v t="$t" '$1 == t { print $2; exit }' "$prev" 2> /dev/null)
        if [ -n "$old" ] && [ "$old" != - ]; then xdg-mime default "$old" "$t"; else drop_line "$t"; fi
    done
    rm -f "$prev" "$entry" "$icon"
    refresh_caches
    say "View is no longer registered with the desktop; pictures open as they did before"
    exit 0
fi

before=$(xdg-mime query default image/png 2> /dev/null || true)      # read before the entry is there, which the desktop's order could pick
mkdir -p "$(dirname "$icon")" "$(dirname "$entry")"
cp "$here/vitreus-view.svg" "$icon"
sed "s|@BIN@|$dest/bin/vitreus-view|" "$here/vitreus-view.desktop" > "$entry"
refresh_caches
say "View has its icon and its entry ($entry)"

[ "$mode" = yes ] || { say "left as it was: pictures still open in ${before:-what they opened in}"; exit 0; }

mkdir -p "$state"
for t in $types; do
    had=$(explicit "$t")
    [ "$had" = vitreus-view.desktop ] && continue
    if ! awk -v t="$t" '$1 == t { f = 1 } END { exit !f }' "$prev" 2> /dev/null; then
        printf '%s %s\n' "$t" "${had:--}" >> "$prev"
    fi
    xdg-mime default vitreus-view.desktop "$t"
done
say "pictures open in View (PNG opened in ${before:-nothing in particular}); integrate.sh --remove puts that back"
