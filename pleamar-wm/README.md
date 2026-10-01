# Vitreus on pleamar-wm

Vitreus is a pleamar shell, so it runs on any compositor that speaks layer-shell, and [pleamar-wm](https://github.com/k4ditano/pleamar-wm)
is one that can be chosen at a login screen (SDDM, GDM). What is here is what makes the two meet.

| File | Where it goes | What it is |
|---|---|---|
| `keys.conf` | `~/.config/pleamar/keys.conf` | pleamar-wm's own keys (`defaults`), with the ones that were Marea's pointed at Vitreus: `Super+Space` launcher, `Super+Shift+Space` Settings, `Super+L` lock, `Super+B` wallpaper picker, `Print` and `Super+C` capture, volume, brightness and media keys |
| `hypridle.conf` | `~/.config/hypr/hypridle.conf` | lock after five minutes and before sleep (screen off after seven on Hyprland; on pleamar-wm that is `idle off-after 420` in `session.conf`) |
| `wm/` | `~/.config/pleamar/wm` | the window manager's scene: pleamar-wm's own `session.plm` with slim title bars of frosted glass and a small glass pill of line icons (BSD 3-Clause, from pleamar-wm: `wm/LICENSE-pleamar-wm`) |
| `install-session.sh` | run with `sudo` | puts «pleamar-wm» in the login screen (SDDM, GDM); `--remove` takes it away |
| `hyprctl` | `~/.local/bin/hyprctl` | `hyprctl` for a desktop that is not Hyprland: the real one on Hyprland, and pleamar-wm's `hyprctl monitors` and `activewindow` elsewhere |

The files can be linked into place so that what you tune in a session is what the repo keeps: `ln -s <this folder>/wm ~/.config/pleamar/wm` and
`ln -sf <this folder>/keys.conf ~/.config/pleamar/keys.conf`. Nothing here touches Hyprland's files (`hypr_vitreus.lua`, `~/.config/hypr`).

The `autostart` file is shared: lines without a prefix start on every desktop, and `wm:` lines only in pleamar-wm's session. For this shell
that is `wm: awww-daemon`, `wm: hypridle` and `wm: wl-paste --watch cliphist store`, which Hyprland's config starts by itself.

A login session needs `~/.local/bin` on its PATH (`pleamar-session` finds `pleamar-wm` there). A login shell that reads `~/.bashrc` stops
there when it is not interactive, so set the PATH in `~/.bash_profile`, before it sources `.bashrc`.

**What is Hyprland's and does not work on pleamar-wm yet:** the Hyprland and Display settings pages, the workspace overview's window list
(pleamar-wm has its own overview on `Super+Tab`), moving and focusing windows from the bar's title, and Night mode (Hyprland's screen shader).
Programs are started directly there, since `hyprctl dispatch exec_cmd` is Hyprland's.
