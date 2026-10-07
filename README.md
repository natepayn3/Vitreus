<div align="center">

  <img src="assets/banner.jpeg" alt="VITREUS: a glass-themed desktop shell" width="100%" />

  <p><strong>A liquid-glass desktop shell: a bar, and panels that flow out of it.</strong></p>

  <p>
    <a href="https://github.com/k4ditano/pleamar"><img src="https://img.shields.io/badge/pleamar-required-9ed6bd?style=for-the-badge" alt="pleamar" /></a>
    <a href="https://hyprland.org"><img src="https://img.shields.io/badge/Hyprland-33CCFF?style=for-the-badge&logo=hyprland&logoColor=white" alt="Hyprland" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge" alt="MIT License" /></a>
  </p>

  <img src="assets/screenshots/demo.webp" alt="Vitreus: panels flowing out of the bar" height="340" />
  <img src="assets/screenshots/wallpaper-demo.webp" alt="The wallpaper picker: a honeycomb of glass hexagons, the one under the pointer swelling and tilting toward it" height="340" />
  <br /><sub>Panels flowing out of the bar &nbsp;·&nbsp; the wallpaper picker (<code>SUPER + B</code>)</sub>

</div>

---

> [!WARNING]
> **Vitreus is in active development.** Features, settings and behaviour can change at any time, and things may break
> between updates.

> **vit·re·us** _(Latin)_ — *of glass; glassy, transparent.*

**Vitreus** is a desktop shell for Wayland, written for [pleamar](https://github.com/k4ditano/pleamar). It is a single
floating pill of frosted glass at the top of the screen, or a strip down the left edge with a thin glass frame round
the screen. Everything else — the calendar, the quick controls, the player, the settings, the launcher, the volume
indicator, an incoming notification — is a drawer that grows out of the bar, joined to it by a liquid neck, in the same
glass, with the same spring, and folds back into it.

It is built to be *not boring*: a shell that morphs rather than pops. On pleamar the animation, the springs and the
layout all run in the renderer, and the logic only reports facts.

---

## 📸 Screenshots

<table>
  <tr>
    <td align="center"><img src="assets/screenshots/control-center.webp" alt="The controls drawer" /><br /><sub><b>Controls</b> — Wi-Fi, Bluetooth, brightness and volume</sub></td>
    <td align="center"><img src="assets/screenshots/calendar.webp" alt="Calendar, weather and reminders" /><br /><sub><b>Calendar</b> — weather, month, and reminders</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/screenshots/launcher.webp" alt="The launcher" /><br /><sub><b>Launcher</b> — apps, files, commands, emoji, clipboard, wallpapers</sub></td>
    <td align="center"><img src="assets/screenshots/player-and-windows.webp" alt="The player and the running windows" /><br /><sub><b>Player and windows</b> — hangs from the window title</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="assets/screenshots/system-tray.webp" alt="A tray app's menu" /><br /><sub><b>System tray</b> — an app's own menu, drawn in the shell's glass</sub></td>
    <td align="center"><img src="assets/screenshots/settings-about.webp" alt="Settings, About page" /><br /><sub><b>Settings</b> — the About page shows the build and updates the shell</sub></td>
  </tr>
</table>

---

## ✨ Features

* **Two layouts** — an *island* pill along the top, or a *frame*: a strip down the left edge with glass round the screen.
* **Calendar** — month grid, reminders in plain words (`3:30pm Call mom`), and the weather for the week.
* **Controls** — Wi-Fi, Bluetooth, brightness, volume with a per-app mixer, Do Not Disturb, Caffeine, screenshots and
  screen recording, and power (lock, sleep, log out, restart, power off).
* **Player** — cover art, a live spectrum, and your running windows.
* **Launcher** (`SUPER + Space`) — apps, files, commands, emoji, clipboard history and wallpapers, with previews.
* **Settings** (`SUPER + SHIFT + Space`) — wallpaper, glass, display, Hyprland, notifications, clock and a system monitor.
* **Wallpaper picker** (`SUPER + B`) — your wallpapers as a honeycomb of glass hexagons.
* **Workspace overview** (`SUPER + TAB`) — a glass card per workspace; drag a window to move it.
* **Desk** — a panel out of the right edge: Focus timer, Shelf, Pad (tasks and drawing), a terminal and Ask.
* **Notifications** — history, plus rules and sounds for each app.
* **Authentication** — a polkit agent drawn in the same glass.
* **Lock screen**, **Night mode**, and a **desktop clock** drawn as glass.
* **Iris** — Vitreus recolours itself from your wallpaper.

---

## 📦 Requirements

* [**pleamar**](https://github.com/k4ditano/pleamar) — the runtime Vitreus is written for.
* A Wayland compositor with layer-shell, developed on **Hyprland**
* [**hyprsunset**](https://github.com/hyprwm/hyprsunset), on Hyprland — drives Night mode
* The **Space Grotesk** font.

Optional, each enabling one thing:

| Tool | Used for |
| --- | --- |
| `cava` | the bass pulse in the bar and the equalizer in the player |
| `playerctl` | cover art for the player |
| `awww` | the wallpaper picker, and Iris following your wallpaper |
| `mpvpaper` (AUR) + `ffmpeg` | video wallpapers (mp4, webm) in the wallpaper picker: mpvpaper plays the video over awww, and ffmpeg takes the frame (kept in the cache) that Iris, the thumbnails and the lock screen read |
| `iris` | theming from the wallpaper |
| `imagemagick` | wallpaper thumbnails (cropped once, cached), and the launcher's picture previews |
| `wl-clipboard` (`wl-copy`) | the launcher copying an emoji, a sum's answer or a clipboard entry |
| `cliphist` | the launcher's clipboard search (`^`). Something has to fill it: `wl-paste --watch cliphist store` at startup |
| `xdg-utils` (`xdg-open`) | the launcher opening a file |
| `curl` | weather and remote cover art |
| NetworkManager (`nmcli`) | Wi-Fi scanning |
| BlueZ (`bluetoothctl`) | Bluetooth scanning |
| `brightnessctl` | the brightness slider |
| `hypridle` + systemd | Caffeine |
| `grim` + `slurp` + `wl-clipboard` | Capture's screenshots (a region is picked with `slurp`) |
| `wf-recorder` + `slurp` | Capture's screen recording (video only, no audio) |
| `power-profiles-daemon` (`powerprofilesctl`) | the power profile in Power |
| `systemd` (`systemctl`, `loginctl`) | Power's sleep, restart, power off and log out |
| `polkit` + `python-gobject` | the authentication dialog (`bin/vitreus-polkit-agent`, started by the shell; needs no other agent running) |
| `python-pyte` + `ttf-space-mono-nerd` | the Desk's terminal (`bin/vitreus-term`; the font is Space Grotesk's monospaced sibling, with the Nerd Font icons prompts use) |
| `pipewire-audio` (`pw-play`) + `sound-theme-freedesktop` | the sounds notifications make |
| `pactl` (PipeWire or PulseAudio) | the per-app volume mixer |
| `hyprctl` | running windows, Settings > Display and > Hyprland, and the launcher starting apps |
| `notify-send` | calendar reminders |

---

## 🚀 Installation

**The quick way.** One script installs the packages Vitreus uses, pleamar itself, the font and the shell, and offers to
start it with your desktop. On Arch and its relatives it does everything; on other distributions it installs the shell
and lists what to add by hand.

```sh
curl -fsSL https://raw.githubusercontent.com/natepayn3/Vitreus/main/install.sh | sh
```

It asks before each step (`--yes` answers them all, `--dry-run` only says what it would do, `--help` lists the rest),
and running it again updates Vitreus. An update keeps what Settings changed in the shell's own files (which monitors
show the bar and the lock screen) and any edits of yours; if an edit of yours clashes with the new version, nothing is
updated and the script says so. `./install.sh --uninstall` takes it away and leaves your data.

**By hand.** Vitreus must live in pleamar's shells folder under the name `vitreus`: the palette it writes and the data
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

---

## ⚙️ Configuration

Vitreus keeps its data in `~/.local/share/pleamar/vitreus`.

### 🎨 Theming with Iris

Iris reads your wallpaper and Vitreus recolours itself, with a legibility floor on the
text. It takes about half a second after a wallpaper change.

---

## 🧩 Layout

| File | |
| --- | --- |
| `vitreus.plm` | the scene: every shape, panel, spring and rule |
| `pages/*.plm` | the scene's big pieces, each a `part` pulled in with `include` (the bar, the desk, the drawers, the overview, every Settings page): same scene, in more files |
| `vitreus.luau` | the logic: services, scanning, weather, Iris, history, the launcher's searches — it only reports facts |
| `logic/*.luau` | the logic's self-contained features (Term, Pad, Shelf, Focus, tray, night mode, updates…), each loaded with `require` and handed what it shares |
| `hypr_vitreus.lua` | Hyprland key binds: `SUPER + Space` launcher, `SUPER + SHIFT + Space` Settings, `SUPER + L` lock |
| `bin/vitreus-clipimg` | a helper for the launcher's clipboard pictures (thumbnail, copy back) |
| `bin/vitreus-keep` | runs a scene from autostart and starts it again if it stops, while the session lasts |
| `assets/emoji.json` | the emoji the launcher searches |
| `install.sh` | installs, updates and removes Vitreus |
| `palette-live.plm` | the shell's colours, as `rgb()` of the `pal_*` facts the logic sets |
| `palette.default.plm` | the stock palette (copy to `palette.plm`, for the lock screen) |
| `wm-palette.default.plm` | pleamar-wm's stock border colour (copy to `wm-palette.plm`) |
| `wave.wgsl` | the shader that bends the bar's glass on the beat |
| `desktopclock/` | the desktop clock: digits of glass on the bottom layer |
| `lockscreen/` | the lock screen, started with the desktop; see its README |
| `wptrans/` | the wallpaper picker's hexagon dissolve, on the bottom layer |
| `pleamar-wm/` | what makes Vitreus run on pleamar-wm; see its README |

---

## Known limits

* awww forgets nothing it was told to show, but it only restores what it last displayed (`awww restore`, run at startup);
  a wallpaper that was never applied through awww is not brought back.
* The launcher's file search looks five folders deep in your home, skipping hidden folders. Clipboard history is only
  as good as what fills `cliphist`; the launcher's apps come from the desktop files pleamar can see.
* Settings > Hyprland and Display write Lua for Hyprland's Lua config; with a `hyprland.conf` they still change the
  running session, but nothing is kept for the next start.
* Bluetooth and Wi-Fi scans go through `bluetoothctl` and `nmcli`: pleamar's own scan calls answer without error but
  nothing scans.
* Wi-Fi rescans within about 15 seconds of the previous one are ignored by NetworkManager.
* Do Not Disturb has a timer, but no quiet-hours schedule and no "silence while a window is fullscreen" trigger yet.

---

## 📄 License

Vitreus is released under the [MIT License](LICENSE). It runs on [pleamar](https://github.com/k4ditano/pleamar), which
is BSD-3-Clause and is not part of this repository.
