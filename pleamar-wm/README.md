# Vitreus on pleamar-wm

Vitreus is a pleamar shell, so it runs on any compositor that speaks layer-shell, and [pleamar-wm](https://github.com/k4ditano/pleamar-wm)
is one that can be chosen at a login screen (SDDM, GDM). What is here is what makes the two meet.

| File | Where it goes | What it is |
|---|---|---|
| `keys.conf` | `~/.config/pleamar/keys.conf` | pleamar-wm's own keys (`defaults`), with the ones that were Marea's pointed at Vitreus: `Super+Space` launcher, `Super+Shift+Space` Settings, `Super+L` lock, `Super+B` wallpaper picker, `Print` and `Super+C` capture, volume, brightness and media keys |
| `hypridle.conf` | `~/.config/hypr/hypridle.conf` | locks before sleep and `source`s `idle.conf`, where Settings > Idle writes its times (the installer links it on every desktop, not only pleamar-wm; without that `source` line the sliders do nothing). Screen off on pleamar-wm is also `idle off-after` in `session.conf` |
| `wm/` | `~/.config/pleamar/wm` | the window manager's scene: pleamar-wm's own `session.plm` plus Vitreus's window styles (frosted glass title bars with a pill of line icons, Water, Borderless, Glow), borders, corners, shadows, the glass frame's room and the desktop menu's right-click. **It is generated, not edited**: `build-session.py` takes the scene of the installed pleamar-wm and applies the changes, and stops at the patch that no longer fits when pleamar-wm changes those lines (BSD 3-Clause, from pleamar-wm: `wm/LICENSE-pleamar-wm`) |
| `install-session.sh` | run with `sudo` | puts «pleamar-wm» in the login screen (SDDM, GDM); `--remove` takes it away |
| `hyprctl` | `~/.local/bin/hyprctl` | `hyprctl` for a desktop that is not Hyprland: the real one on Hyprland, and pleamar-wm's `hyprctl monitors` and `activewindow` elsewhere |

The files can be linked into place so that what you tune in a session is what the repo keeps: `ln -s <this folder>/wm ~/.config/pleamar/wm` and
`ln -sf <this folder>/keys.conf ~/.config/pleamar/keys.conf`. Nothing here touches Hyprland's files (`hypr_vitreus.lua`, `~/.config/hypr`).

The `autostart` file is shared: lines without a prefix start on every desktop, and `wm:` lines only in pleamar-wm's session. Vitreus's
daemons (`awww-daemon`, `hypridle` and `wl-paste --watch cliphist store`) are plain lines, guarded so that one already running is not
started twice, so they start on Hyprland and on pleamar-wm alike.

A login session needs `~/.local/bin` on its PATH (`pleamar-session` finds `pleamar-wm` there). A login shell that reads `~/.bashrc` stops
there when it is not interactive, so set the PATH in `~/.bash_profile`, before it sources `.bashrc`.

**What is Hyprland's and does not work on pleamar-wm yet:** the Hyprland and Display settings pages, the workspace overview's window list
(pleamar-wm has its own overview on `Super+Tab`), moving and focusing windows from the bar's title, and Night mode (hyprsunset, which is Hyprland's).
Programs are started directly there, since `hyprctl dispatch exec_cmd` is Hyprland's.

**Updating pleamar-wm:** run `./build-session.py` in this folder after it (all its layouts, such as scrolling, come with it); `wm/session.plm.pre-rebase` is the scene from before the rebase of 2026-10-16. On 2026-10-22 the patches were rebased onto pleamar-wm 0.5.9's scene (repeats, folds and arrays; nine layouts, fractal, phone and wires): the shell's `focus_slot` and `close_slot` events, which its task list emits, are patched in too, so clicking or closing a window from the bar works here.
