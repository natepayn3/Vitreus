# Installing Vitreus

Most people only need the one-line installer from the [README](../README.md#-install). This page has the details: what it
installs, its options, trying Vitreus next to another shell, and setting it up by hand.

## Requirements

* [**pleamar**](https://github.com/k4ditano/pleamar) — the runtime Vitreus is written for
* **Hyprland**, **niri** or **pleamar-wm**
* **A Vulkan driver for your graphics card** — pleamar draws with Vulkan. On Arch that is `vulkan-radeon` (AMD), `vulkan-intel` (Intel) or NVIDIA's driver with `nvidia-utils`; on Debian, Ubuntu and Fedora, `mesa-vulkan-drivers`. A minimal install often has none, and then nothing starts and nothing says why. `install.sh` checks for it and offers to install the AMD and Intel ones; `vulkaninfo --summary` shows what Vulkan can see.

The packages `install.sh` installs (from pacman; `iris-colors` and `mpvpaper` come from the AUR):

| Package | Used for |
| --- | --- |
| `git`, `curl`, `fontconfig` | fetching Vitreus, weather and cover art, the launcher's web answers, and the fonts |
| `hyprsunset` | Night mode on Hyprland |
| `wlsunset` | Night mode on pleamar-wm and niri |
| `socat` | sending the palette and other changes to the lock screen and desktop widgets, and Hyprland's events (urgent windows, screen-share light) |
| `awww` | the wallpaper picker |
| `iris-colors` (AUR) | theming from the wallpaper |
| `mpvpaper` (AUR), `ffmpeg` | video wallpapers, and the webcam (`ffmpeg` reads the camera) |
| `imagemagick` | wallpaper thumbnails, the launcher's picture previews and the pictures in Files and View |
| `mpv` | videos in View (on Arch it comes with `mpvpaper`; the installer does not add it on its own) |
| `cava` | the bass pulse, the equalizer and the audio visualiser |
| `playerctl` | the player and its cover art |
| `networkmanager` | Wi-Fi |
| `bluez`, `bluez-utils` | Bluetooth |
| `brightnessctl` | the brightness slider |
| `hypridle` | Caffeine |
| `libnotify` | calendar reminders |
| `xdg-user-dirs`, `xdg-utils` | finding your Pictures folder, opening files and web searches |
| `wl-clipboard`, `cliphist` | the launcher's clipboard and copying (results, snippets) |
| `grim`, `slurp`, `wf-recorder` | screenshots and screen recording |
| `jq` | Snap finding the focused monitor and its windows |
| `power-profiles-daemon` | the power profile |
| `polkit`, `python-gobject` | the authentication dialog |
| `python-pyte`, `ttf-space-mono-nerd` | the Desk's terminal |
| `python` 3.11 or newer | reads the theme `.toml` files (`bin/vitreus-themes`) and sets up the font for each theme |
| `pipewire-audio`, `sound-theme-freedesktop` | notification sounds |
| `tesseract`, `tesseract-data-eng` | the text of a screenshot, and Snap's Copy text and Redact private info |

---

## The installer

One script installs the packages Vitreus uses, pleamar itself, the fonts and the shell, and offers to
start it with your desktop. On Arch and its relatives it does everything; on other distributions it installs the shell
and lists what to add by hand.

> **Debian and Ubuntu support is experimental and untested.** The installer has an `apt` path that installs what those releases package, one
> package at a time so a missing one costs only itself, and lists the rest to add by hand: `awww`, `mpvpaper`,
> `hyprsunset` (needed on Hyprland), `iris` and the Space Mono Nerd Font have no Debian package. Hyprland itself needs a
> recent release (Debian 13 or Ubuntu 25.04 or later, or build it). If you try it, `vitreus-report` collects what is
> needed to see what went wrong, and a report is very welcome.

```sh
curl -fsSL https://raw.githubusercontent.com/natepayn3/Vitreus/main/install.sh | sh
```

It asks before each step (`--yes` answers them all, `--dry-run` only says what it would do, `--help` lists the rest),
and running it again updates Vitreus. An update keeps what Settings changed in the shell's own files (which monitors
show the bar and the lock screen) and any edits of yours; if an edit of yours clashes with the new version, nothing is
updated and the script says so. `./install.sh --uninstall` takes it away and leaves your data.

### Trying it next to another shell

Vitreus is a whole desktop shell, not an add-on to another one. If Quickshell is running and has a configuration (in `~/.config/quickshell`,
or in a system folder such as `/etc/xdg/quickshell`), the installer stops before changing anything, because two shells at once fight over
the notifications, the wallpaper, the lock screen and the key binds. Log out of the other shell first, run `./install.sh --force` to go on anyway, or, to try
Vitreus next to yours, without losing it, run `./install.sh --test`: it installs Vitreus but adds nothing to your autostart, your
Hyprland config or the login screen, stops your Quickshell and starts Vitreus. `./install.sh --stop` ends the test and starts
your Quickshell again, the same way it was started. Happy with Vitreus? Run `./install.sh` to make it the desktop. Your Quickshell
config is never touched: it stays in `~/.config/quickshell`.

### By hand

Vitreus must live in pleamar's shells folder under the name `vitreus`: the palette it writes and the data
it keeps are found from there.

```sh
git clone https://github.com/natepayn3/Vitreus.git ~/.config/pleamar/shells/vitreus
cd ~/.config/pleamar/shells/vitreus
cp palette.default.plm palette.plm          # the lock screen's colours; Vitreus rewrites this file from your wallpaper
cp wm-palette.default.plm wm-palette.plm    # pleamar-wm's window borders; the same
pleamar --scene ~/.config/pleamar/shells/vitreus/vitreus.plm --no-hud
```

To start it with the desktop, add `vitreus-keep ~/.config/pleamar/shells/vitreus/vitreus.plm` to `~/.config/pleamar/autostart`
(after linking `bin/vitreus-keep` into `~/.local/bin`: it runs the scene and starts it again if it ever stops, such as a crash
when a monitor wakes; the installer does the same for the lock screen, the wallpaper transition and the desktop clock), and on Hyprland put
`exec-once = pleamar --autostart` in your config (`hl.on("hyprland.start", …)` in a Lua config). The scene reloads
itself whenever a file in the folder is saved.

### On niri

The script adds three lines to the end of `~/.config/niri/config.kdl` (it asks first, keeps a copy as
`config.kdl.before-vitreus`, and takes them out again on `--uninstall`): `spawn-at-startup "pleamar" "--autostart"`, and
`include "niri_vitreus.kdl"` and `include "vitreus.kdl"`. The first of these two files, linked into `~/.config/niri`, has the shell's key binds; the
second is written by the shell: the room the windows keep clear of the bar and docks (as `struts`), the focus ring, and what Settings > niri
changes. Settings > niri takes the place of the Hyprland page there.

### On Hyprland

Two things the script does that you would do by hand: link `bin/vitreus-clipimg` into a folder on your `PATH` (the
launcher's clipboard pictures), and, on Hyprland with a Lua config, load the key binds and what Settings saves:

```lua
require("hypr_vitreus")                 -- SUPER + Space launcher, SUPER + SHIFT + Space settings, SUPER + L lock
pcall(require, "vitreus_monitors")      -- written by Settings > Display
pcall(require, "vitreus_hypr")          -- written by Settings > Hyprland
```

after linking `hypr_vitreus.lua` into `~/.config/hypr`. (The script adds these lines to the end of `hyprland.lua`
after asking, keeps a copy as `hyprland.lua.before-vitreus`, and takes them out again on `--uninstall`.)

Vitreus takes over `org.freedesktop.Notifications` from whatever handled notifications before it, and hands it back
when it exits.


## Your data

Vitreus keeps its data in `~/.local/share/pleamar/vitreus`. Your own themes (`~/.config/pleamar/vitreus-themes/`) and add-ons
(`~/.config/pleamar/vitreus-addons/`) live outside the shell's folder, so updates never touch them.
