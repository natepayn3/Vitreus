<div align="center">

  <h1>VITREUS</h1>

  <p><strong>A liquid-glass desktop shell: a bar, and panels that flow out of it.</strong></p>

  <p>
    <a href="https://github.com/k4ditano/pleamar"><img src="https://img.shields.io/badge/pleamar-0.2-9ed6bd?style=for-the-badge" alt="pleamar" /></a>
    <a href="https://hyprland.org"><img src="https://img.shields.io/badge/Hyprland-33CCFF?style=for-the-badge&logo=hyprland&logoColor=white" alt="Hyprland" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge" alt="MIT License" /></a>
  </p>

  <img src="assets/screenshots/demo.webp" alt="Vitreus: panels flowing out of the bar" width="49%" />
  <img src="assets/screenshots/wallpaper-demo.webp" alt="The wallpaper picker: a honeycomb of glass hexagons, the one under the pointer swelling and tilting toward it" width="49%" />
  <br /><sub>Panels flowing out of the bar &nbsp;·&nbsp; the wallpaper picker (<code>SUPER + B</code>)</sub>

</div>

---

> [!WARNING]
> **Vitreus is in active development.** Features, settings and behaviour can change at any time, and things may break
> between updates.

> **vit·re·us** _(Latin)_ — *of glass; glassy, transparent.*

**Vitreus** is a desktop shell for Wayland, written for [pleamar](https://github.com/k4ditano/pleamar). It is a single
floating pill of frosted glass at the top of the screen. Everything else — the calendar, the quick controls, the
player, the settings, the launcher, the volume indicator, an incoming notification — is a drawer that grows out of the bar, joined to it by a liquid neck, in the
same glass, with the same spring, and folds back into it.

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

**The bar**
* Workspace indicator whose dots morph into capsules and a wide accent pill.
* The focused window's app and title, mini media controls, and a clock with an oversized hour, accent-coloured
  minutes and the weekday stacked over the am/pm.
* Buttons for Settings, the launcher (a magnifying glass) and the controls, left of the clock.
* Text and icons are drawn outside the bar's bass-wave shader with a soft shadow, so they stay sharp and legible on
  light wallpapers.

**Panels** — each one is a drawer from the bar, centred, that swells out of the bar on a spring, stays joined to it by a liquid neck, and settles with a little wobble,
with its content fading in after the glass has settled
* **Calendar** — a clock card, a month grid, reminders you can write in plain words (`3:30pm Call mom`) that fire a
  desktop notification when due, and a weather strip: now, and the next seven days.
* **Controls** — Wi-Fi and Bluetooth tiles that each open their own window (scan, connect, forget, password entry),
  a **Notifications** module (Do Not Disturb with a timer, and a notification history), Caffeine (with timers),
  brightness, volume with an output picker and a per-app mixer (right-click the volume card, or press its dots: one
  slider and mute button for each app playing sound; needs `pactl`).
* **Player** — a media card with cover art and a live spectrum from `cava`, plus the running windows (focus or close
  them) and background apps from the tray.
* **Launcher** (`SUPER + Space`) — a search field over its results; the first character picks the search: apps (with
  their descriptions, most-used first, and a sum is answered as you type), `#` files, `>` commands, `:` emoji, `^` the
  clipboard history, `~` wallpapers. Files, wallpapers and the clipboard have a preview beside the rows: the picture
  or the text, and the file's size, date and type. Arrows and Enter, or the mouse.
* **Settings** (`SUPER + SHIFT + Space`) — a sidebar and pages of cards.
  *Visuals:* **Wallpaper** (a gallery of your wallpaper folder with a preview, Random, paging, a slideshow, and a
  colour filter), **Glass** (how frosted and how solid the panels are), **Display** (a canvas to arrange your
  monitors, mode, refresh rate, scale, rotation, SDR levels, saved profiles; a change is on trial for 15 seconds and
  goes back unless you keep it). *System:* **Hyprland** (layout, gaps, resize from border, tearing, animations,
  pointer sensitivity, focus following, natural scroll).
* **Wallpaper picker** (`SUPER + B`) — every wallpaper as a glass hexagon in a honeycomb centred on the screen, ordered
  round the colour wheel. How many wallpapers you have sets how big the hexagons are. The one under the pointer swells
  with a slight bounce and tilts in 3D toward the pointer while the tiles round it make room; click one and it blooms
  out of the tile as the new wallpaper. The first time it opens it reads your wallpapers once (thumbnails are cached);
  `Esc` or a click outside closes it.
* **Volume** — a small face and a wave whose curves stretch out as the volume rises.
* **Notifications** — Vitreus is the notification server. Banners grow to fit their title, body and buttons; critical
  ones stay until dismissed; everything lands in the history, including what Do Not Disturb held back.

**Lock screen** — a lock screen after Synoptik's, in [`lockscreen/`](lockscreen/README.md). It is a scene of its own
and is not started unless you turn it on.

**Theming** — [Iris](#-theming-with-iris) reads your wallpaper and Vitreus recolours itself, with a legibility floor on
the text. It takes about half a second after a wallpaper change.

---

## 📦 Requirements

* [**pleamar**](https://github.com/k4ditano/pleamar) 0.2.2 or newer — the runtime Vitreus is written for. (The lock
  screen needs 0.2.2: earlier versions crash the session on `kind: lock`.)
* A Wayland compositor with layer-shell. It is developed on **Hyprland**; the running-windows list uses `hyprctl`,
  so that part is Hyprland-only.
* [**hyprsunset**](https://github.com/hyprwm/hyprsunset) — Hyprland's blue-light filter, which Night mode drives (the installer
  requires it). It tints the screen by handing the compositor a colour transform, so nothing is re-rendered.
* The **Space Grotesk** font.

Optional, each enabling one thing (Vitreus runs without them and that part stays quiet):

| Tool | Used for |
| --- | --- |
| `cava` | the bass pulse in the bar and the equalizer in the player |
| `playerctl` | cover art for the player |
| `awww` | the wallpaper picker, and Iris following your wallpaper |
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
and running it again updates Vitreus. `./install.sh --uninstall` takes it away and leaves your data.

**By hand.** Vitreus must live in pleamar's shells folder under the name `vitreus`: the palette it writes and the data
it keeps are found from there.

```sh
git clone https://github.com/natepayn3/Vitreus.git ~/.config/pleamar/shells/vitreus
cd ~/.config/pleamar/shells/vitreus
cp palette.default.plm palette.plm          # the colours; Vitreus rewrites this file from your wallpaper
pleamar --scene ~/.config/pleamar/shells/vitreus/vitreus.plm --no-hud
```

To start it with the desktop, add that last line to `~/.config/pleamar/autostart`, and on Hyprland put
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

Vitreus keeps its data in `$XDG_DATA_HOME/pleamar/vitreus` (`~/.local/share/pleamar/vitreus`). The settings panel is
still growing, so a few settings are plain files there:

| File | What it holds |
| --- | --- |
| `iris.json` | `{ "enabled": true, "intensity": "medium" }` — `subtle`, `medium` or `bold` |
| `weather-config.json` | `{ "location": "", "units": "fahrenheit" }` — a place name, or empty for IP-based; or `celsius` |
| `dnd.json` | Do Not Disturb: by hand, and any timer still running |
| `caffeine.json` | Caffeine: the timer still running |
| `glass.json` | the Glass page: how frosted and how solid |
| `wallpaper.json`, `wallpaper-colors.json` | the wallpaper slideshow, and the colours found in each picture |
| `display.json`, `display-profiles.json` | the Display page: what was kept, and the saved profiles |
| `launcher.json` | how often each app was started from the launcher |
| `calendar.json` | your reminders |
| `notification-history.json` | the notification history |

The wallpaper picker reads `<Pictures>/Wallpapers`. Thumbnails are cached in `$XDG_CACHE_HOME/pleamar/vitreus/wp`.

Two files Settings writes are Lua, for Hyprland to load at start: `~/.config/hypr/vitreus_monitors.lua` (Display) and
`~/.config/hypr/vitreus_hypr.lua` (Hyprland). Changes are also sent to the running Hyprland at once.

### 🎨 Theming with Iris

pleamar cannot take a colour from its logic at runtime, so the palette lives in `palette.plm`, a small library of
named colours the scene imports. When the wallpaper changes, Vitreus runs `iris --json-only`, applies a contrast
floor and your chosen intensity, rewrites `palette.plm`, and the scene reloads in the new colours. `palette.plm` is
git-ignored; the stock colours are tracked as `palette.default.plm`.

---

## 🧩 Layout

| File | |
| --- | --- |
| `vitreus.plm` | the scene: every shape, panel, spring and rule |
| `vitreus.luau` | the logic: services, scanning, weather, Iris, history, the launcher's searches — it only reports facts |
| `hypr_vitreus.lua` | Hyprland key binds: `SUPER + Space` launcher, `SUPER + SHIFT + Space` Settings, `SUPER + L` lock |
| `bin/vitreus-clipimg` | a helper for the launcher's clipboard pictures (thumbnail, copy back) |
| `assets/emoji.json` | the emoji the launcher searches |
| `install.sh` | installs, updates and removes Vitreus |
| `palette.default.plm` | the stock palette (copy to `palette.plm`) |
| `wave.wgsl` | the shader that bends the bar's glass on the beat |
| `lockscreen/` | a lock screen, **off** until you start it (pleamar 0.2.2 or newer); see its README |

---

## Known limits

* The wallpaper chosen in Settings is not restored after a restart (awww forgets it).
* The launcher's file search looks five folders deep in your home, skipping hidden folders. Clipboard history is only
  as good as what fills `cliphist`; the launcher's apps come from the desktop files pleamar can see.
* Settings > Hyprland and Display write Lua for Hyprland's Lua config; with a `hyprland.conf` they still change the
  running session, but nothing is kept for the next start.
* Settings > Display has only been tried with one monitor: arranging several is untested.
* Bluetooth and Wi-Fi scans go through `bluetoothctl` and `nmcli`: pleamar's own scan calls answer without error but
  nothing scans.
* Wi-Fi rescans within about 15 seconds of the previous one are ignored by NetworkManager.
* Do Not Disturb has a timer, but no quiet-hours schedule and no "silence while a window is fullscreen" trigger yet.

---

## 📄 License

Vitreus is released under the [MIT License](LICENSE). It runs on [pleamar](https://github.com/k4ditano/pleamar), which
is BSD-3-Clause and is not part of this repository.
