#!/bin/sh
# Puts «pleamar-wm» in the login screen (SDDM, GDM). It needs root, so run it with sudo:
#
#   sudo sh ~/.config/pleamar/shells/vitreus/pleamar-wm/install-session.sh            install
#   sudo sh ~/.config/pleamar/shells/vitreus/pleamar-wm/install-session.sh --remove   take it away again
#
# It does what `pleamar-update --session` does for the login screen, and nothing else: that one also updates and rebuilds pleamar from git,
# which this does not. Three files, then. The session entry (/usr/share/wayland-sessions), the program the login screen starts
# (/usr/local/bin/pleamar-wm-session: it sets the desktop's names and PATH and runs your ~/.local/bin/pleamar-session), and pleamar-wm's portals.
# Your other sessions (Hyprland) stay where they are. Try it first from a TTY: pleamar-session --seconds 45
set -eu
[ "$(id -u)" = 0 ] || { echo "needs root: sudo sh $0"; exit 1; }
user=${SUDO_USER:-}
[ -n "$user" ] || { echo "run it with sudo, from your own account, so that it knows whose home it is"; exit 1; }
home=$(getent passwd "$user" | cut -d: -f6)
src="$home/.local/share/pleamar/src/pleamar-wm"
if [ "${1:-}" = "--remove" ]; then
    rm -fv /usr/share/wayland-sessions/pleamar-wm.desktop /usr/local/bin/pleamar-wm-session \
           /usr/share/xdg-desktop-portal/pleamar-portals.conf /usr/share/xdg-desktop-portal/portals/pleamar.portal
    exit 0
fi
for f in pleamar-wm.desktop pleamar-portals.conf pleamar.portal; do
    [ -f "$src/$f" ] || { echo "not there: $src/$f (is pleamar-wm installed in $home?)"; exit 1; }
done
[ -x "$home/.local/bin/pleamar-session" ] || { echo "not there: $home/.local/bin/pleamar-session"; exit 1; }
cat > /usr/local/bin/pleamar-wm-session << 'WRAP'
#!/bin/sh
# pleamar-wm as the login screen starts it (see Vitreus's pleamar-wm/install-session.sh).
export XDG_CURRENT_DESKTOP=pleamar XDG_SESSION_DESKTOP=pleamar XDG_SESSION_TYPE=wayland PLEAMAR_WM_EXPORT=1
export PATH="$HOME/.local/bin:$PATH"
exec "$HOME/.local/bin/pleamar-session" "$@"
WRAP
chmod 755 /usr/local/bin/pleamar-wm-session
install -Dm644 "$src/pleamar-wm.desktop" /usr/share/wayland-sessions/pleamar-wm.desktop
install -Dm644 "$src/pleamar-portals.conf" /usr/share/xdg-desktop-portal/pleamar-portals.conf
install -Dm644 "$src/pleamar.portal" /usr/share/xdg-desktop-portal/portals/pleamar.portal
echo "done: «pleamar-wm» is in the login screen's list of sessions. Log out and choose it, or try it first from a TTY."
