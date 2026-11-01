#!/bin/sh
# integrate.sh [--set | --no-set] [--yes] [--remove]: puts Files (vitreus-files) among the desktop's programs, and, when asked, makes it the file manager.
#   always      the icon (~/.local/share/icons/hicolor/scalable/apps/vitreus-files.svg) and the entry (~/.local/share/applications/vitreus-files.desktop, with the
#               path of this copy in its Exec: the programs that start it do not have ~/.local/bin on their PATH). Without --set the entry does not say it opens
#               folders (no MimeType): the desktop picks the opener of a folder from the entries that say so, and one that does would be chosen over the person's own
#   --set       also make it the one that opens folders (the entry's MimeType, and xdg-mime) and the one that answers «Show in folder» in other programs
#               (org.freedesktop.FileManager1, over D-Bus: a service file of the person's own, which comes before Nautilus's or Dolphin's), without asking
#   --no-set    only the icon and the entry; what the person uses now stays
#   (neither)   ask, when there is a keyboard to ask on
#   --yes       the same as --set
#   --remove    take all of it away, and put the folder opener that was in use back
# What opened folders before is kept in ~/.local/share/pleamar/vitreus/files-previous-handler, the first time it is changed: «explicit <entry>» when the person had chosen
# one (~/.config/mimeapps.list), «fallback» when it was only the order of the desktop's own list (then --remove deletes the line this wrote, and that order rules again).
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest=$(cd "$here/.." && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}
conf=${XDG_CONFIG_HOME:-$HOME/.config}
state=$data/pleamar/vitreus
mimeapps=$conf/mimeapps.list
mode=ask
action=install
for a in "$@"; do
    case "$a" in
        --set|--yes|-y) mode=yes ;;
        --no-set) mode=no ;;
        --remove) action=remove ;;
        *) echo "integrate.sh: I do not know $a" >&2; exit 1 ;;
    esac
done
icon=$data/icons/hicolor/scalable/apps/vitreus-files.svg
entry=$data/applications/vitreus-files.desktop
service=$data/dbus-1/services/org.freedesktop.FileManager1.service
prev=$state/files-previous-handler
say() { printf '\033[1;36mvitreus ·\033[0m %s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
current() { xdg-mime query default inode/directory 2> /dev/null || true; }
# What the person has chosen for folders (the line in mimeapps.list), not what the desktop's list would give.
explicit() { sed -n 's/^inode\/directory=\([^;]*\).*/\1/p' "$mimeapps" 2> /dev/null | head -n 1; }
refresh_caches() {
    have update-desktop-database && update-desktop-database "$data/applications" 2> /dev/null || true
    have gtk-update-icon-cache && [ -f "$data/icons/hicolor/index.theme" ] && gtk-update-icon-cache -q -t -f "$data/icons/hicolor" 2> /dev/null || true
}
# The line in mimeapps.list taken out, in place (a copy over the file: it may be a link into someone's dotfiles, which `sed -i` would turn into a file).
drop_explicit() {
    [ -f "$mimeapps" ] || return 0
    tmp=$(mktemp)
    grep -v '^inode/directory=vitreus-files.desktop' "$mimeapps" > "$tmp" || true
    cat "$tmp" > "$mimeapps"
    rm -f "$tmp"
}

if [ "$action" = remove ]; then
    if [ "$(explicit)" = vitreus-files.desktop ]; then
        case "$(cat "$prev" 2> /dev/null || true)" in
            "explicit "*) old=$(cat "$prev"); old=${old#explicit }; xdg-mime default "$old" inode/directory && say "folders open in $old again" ;;
            *) drop_explicit; say "folders open as the desktop's own list says again" ;;
        esac
    fi
    rm -f "$prev" "$service" "$entry" "$icon"
    refresh_caches
    say "Files is no longer registered with the desktop"
    exit 0
fi

# What the person has now, read before anything is installed.
had=$(explicit)
now=$(current)

mkdir -p "$(dirname "$icon")" "$(dirname "$entry")"
cp "$here/vitreus-files.svg" "$icon"

if [ "$mode" = ask ]; then
    mode=no
    if [ -r /dev/tty ] && ( exec < /dev/tty ) 2> /dev/null; then
        printf '\033[1;36mvitreus ·\033[0m make Files the file manager (folders open in it, and «Show in folder» in other programs)? [Y/n] ' > /dev/tty
        read -r answer < /dev/tty || answer=y
        case "$answer" in n|N|no|No) mode=no ;; *) mode=yes ;; esac
    fi
fi

# The entry: it claims folders only for someone who chose it (now, or before: a refresh keeps that).
if [ "$mode" = yes ] || [ "$had" = vitreus-files.desktop ]; then
    sed "s|@BIN@|$dest/bin/vitreus-files|" "$here/vitreus-files.desktop" > "$entry"
else
    sed -e "s|@BIN@|$dest/bin/vitreus-files|" -e '/^MimeType=/d' "$here/vitreus-files.desktop" > "$entry"
fi
refresh_caches
say "Files has its icon and its entry ($entry)"

[ "$mode" = yes ] || { say "left as it was: what opens folders is still ${now:-nothing in particular}"; exit 0; }

# What opened folders is remembered once, to put it back (--remove).
mkdir -p "$state"
if [ "$had" != vitreus-files.desktop ] && [ ! -f "$prev" ]; then
    if [ -n "$had" ]; then printf 'explicit %s\n' "$had" > "$prev"; else printf 'fallback\n' > "$prev"; fi
fi
xdg-mime default vitreus-files.desktop inode/directory
say "folders open in Files (they opened in ${now:-nothing in particular})"

# «Show in folder» in other programs: org.freedesktop.FileManager1. D-Bus starts the service by itself when one asks. It is a few lines of Python with Gio (python-gobject): without
# that it would fail every time someone asks, and keep Nautilus's own from answering, so it is not put in.
if python3 -c 'import gi; gi.require_version("Gio", "2.0")' 2> /dev/null; then
    mkdir -p "$(dirname "$service")"
    cat > "$service" <<EOF
[D-BUS Service]
Name=org.freedesktop.FileManager1
Exec=$dest/bin/vitreus-filemanager
EOF
    say "«Show in folder» opens Files ($service)"
    if have busctl && busctl --user status org.freedesktop.FileManager1 > /dev/null 2>&1; then
        say "another file manager is running and answers it now: it takes effect once that one has quit"
    fi
else
    say "«Show in folder» in other programs is left to the file manager that answers it: Files' service needs Python with Gio (python-gobject, python3-gi)"
fi
