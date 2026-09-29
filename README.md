<div align="center">

  <h1>VITREUS</h1>

  <p><strong>A liquid-glass desktop shell: a bar, and panels that drip out of it.</strong></p>

  <p>
    <a href="https://github.com/k4ditano/pleamar"><img src="https://img.shields.io/badge/pleamar-0.1-9ed6bd?style=for-the-badge" alt="pleamar" /></a>
    <a href="https://hyprland.org"><img src="https://img.shields.io/badge/Hyprland-33CCFF?style=for-the-badge&logo=hyprland&logoColor=white" alt="Hyprland" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge" alt="MIT License" /></a>
  </p>

  <!-- Add a screenshot or a short capture here: assets/screenshots/... -->

</div>

---

> **vit·re·us** _(Latin)_ — *of glass; glassy, transparent.*

**Vitreus** is a desktop shell for Wayland, written for [pleamar](https://github.com/k4ditano/pleamar). It is a single
floating pill of frosted glass at the top of the screen. Everything else — the calendar, the quick controls, the
player, the settings, the volume indicator, an incoming notification — is a drawer that drips out of the bar in the
same glass, with the same spring, and folds back into it.

It is built to be *not boring*: a shell that morphs rather than pops. On pleamar the animation, the springs and the
layout all run in the renderer, and the logic only reports facts.

---

## ✨ Features

**The bar**
* Workspace indicator whose dots morph into capsules and a wide accent pill.
* The focused window's app and title, mini media controls, and a clock with an oversized hour, accent-coloured
  minutes and the weekday stacked over the am/pm.
* Text and icons are drawn outside the bar's bass-wave shader with a soft shadow, so they stay sharp and legible on
  light wallpapers.

**Panels** — each one is a drawer from the bar, centred, with its content fading in after the glass has settled
* **Calendar** — a clock card, a month grid, reminders you can write in plain words (`3:30pm Call mom`) that fire a
  desktop notification when due, and a weather strip: now, and the next seven days.
* **Controls** — Wi-Fi and Bluetooth tiles that each open their own window (scan, connect, forget, password entry),
  a **Notifications** module (Do Not Disturb with a timer, and a notification history), Caffeine, brightness, volume
  with an output picker.
* **Player** — a media card with cover art and a live spectrum from `cava`, plus the running windows (focus or close
  them) and background apps from the tray.
* **Settings** — a sidebar and pages of cards; the wallpaper picker is the first: a gallery of your wallpaper folder
  with a preview, Random, and paging.
* **Volume** — a small face and a wave whose curves stretch out as the volume rises.
* **Notifications** — Vitreus is the notification server. Banners grow to fit their title, body and buttons; critical
  ones stay until dismissed; everything lands in the history, including what Do Not Disturb held back.

**Theming** — [Iris](#-theming-with-iris) reads your wallpaper and Vitreus recolours itself, with a legibility floor on
the text. It takes about half a second after a wallpaper change.

---

## 📦 Requirements

* [**pleamar**](https://github.com/k4ditano/pleamar) 0.1 — the runtime Vitreus is written for.
* A Wayland compositor with layer-shell. It is developed on **Hyprland**; the running-windows list uses `hyprctl`,
  so that part is Hyprland-only.
* The **Space Grotesk** font.

Optional, each enabling one thing (Vitreus runs without them and that part stays quiet):

| Tool | Used for |
| --- | --- |
| `cava` | the bass pulse in the bar and the equalizer in the player |
| `playerctl` | cover art for the player |
| `awww` | the wallpaper picker, and Iris following your wallpaper |
| `iris` | theming from the wallpaper |
| `imagemagick` | wallpaper thumbnails (cropped once, cached) |
| `curl` | weather and remote cover art |
| NetworkManager (`nmcli`) | Wi-Fi scanning |
| BlueZ (`bluetoothctl`) | Bluetooth scanning |
| `brightnessctl` | the brightness slider |
| `hypridle` + systemd | Caffeine |
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
`exec-once = pleamar --autostart` in your config. The scene reloads itself whenever a file in the folder is saved.

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
| `calendar.json` | your reminders |
| `notification-history.json` | the notification history |

The wallpaper picker reads `<Pictures>/Wallpapers`. Thumbnails are cached in `$XDG_CACHE_HOME/pleamar/vitreus/wp`.

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
| `vitreus.luau` | the logic: services, scanning, weather, Iris, history — it only reports facts |
| `palette.default.plm` | the stock palette (copy to `palette.plm`) |
| `wave.wgsl` | the shader that bends the bar's glass on the beat |

---

## Known limits

* The wallpaper chosen in Settings is not restored after a restart (awww forgets it).
* Bluetooth and Wi-Fi scans go through `bluetoothctl` and `nmcli`: pleamar's own scan calls answer without error but
  nothing scans.
* Wi-Fi rescans within about 15 seconds of the previous one are ignored by NetworkManager.
* Do Not Disturb has a timer, but no quiet-hours schedule and no "silence while a window is fullscreen" trigger yet.

---

## 📄 License

Vitreus is released under the [MIT License](LICENSE). It runs on [pleamar](https://github.com/k4ditano/pleamar), which
is BSD-3-Clause and is not part of this repository.
