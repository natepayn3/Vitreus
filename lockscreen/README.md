# Lock screen

A lock screen for Vitreus, the wallpaper arrives sharp and blurs into place under a ring of
liquid that leaves the centre (`lockwave.wgsl`), then the clock, avatar and password bar rise in one after another.
Typed characters become random shapes (`shapes.svg`); the password itself is never drawn. It checks the password with
PAM (`auth.check`) and opens when it is right.

**It needs pleamar 0.2.9 or newer.** Before 0.2.2, `kind: lock` made the compositor end pleamar with
`ext_session_lock_surface_v1: error 1: Null buffer attached` and left the session locked with no locker, and a picture
drawn on the lock only appeared on the first lock after the scene was read. 0.2.9 added `screens:` on a lock, which the
monitor setting below uses, and fixed a portrait monitor beside a landscape one getting the other's shape.

## Turning it on

1. The installer adds it to `~/.config/pleamar/autostart` for you, so it starts with the desktop. By hand, the line is
   `vitreus-keep ~/.config/pleamar/shells/vitreus/lockscreen/lockscreen.plm` (or `pleamar --scene … --no-hud`, without the
   keeper that starts it again if it stops).
2. Lock with `pleamar --say lockscreen "fact locked true"`. For idle and sleep, point hypridle's `lock_cmd`,
   `before_sleep_cmd` and idle listener at that same command, and bind a key to it. The Vitreus binds (`SUPER + L`) and its
   lock buttons already use it, and do nothing while the scene is not running.
3. Try it first with `fact safe = true` in `lockscreen.plm`: then Esc on an empty box, or a minute of nothing, opens
   the lock, so a lock that does not behave cannot keep you out. It is `false` as shipped: only the password opens it.
   Have a TTY (Ctrl+Alt+F3) ready the first time either way.

Two things about the wallpaper: the pictures are cached 16:9 (an `image` is a fixed-shape cell, and the renderer will
not hold a bigger one), and they are made once, in the background, each time the wallpaper changes.

## Settings

They are on Vitreus's **Settings > System > Lock screen** page, which changes them in the running lock screen at once (it has to be
running). They live in a file, which can also be edited by hand:

`~/.local/share/pleamar/lockscreen/lockscreen.json` (the scene's own folder; it is written with the defaults the first time
the scene starts, and read each time it starts, so restart the lock screen after editing it). A missing or wrong key is the default.

| Key | Default | |
|---|---|---|
| `blur` | `36` | How blurred the wallpaper is, in pixels at 1920 wide: `18` light, `36` medium, `60` heavy, or any number up to 120 |
| `use_12_hour` | `true` | A 12 or a 24 hour clock |
| `show_am_pm` | `true` | The AM/PM pill beside a 12 hour clock |
| `date_format` | `"long"` | `"long"` Wednesday, September 30, 2026 · `"standard"` Wed, Sep 30, 2026 · `"dayFirst"` 30 September 2026 · `"iso"` 2026-09-30 |
| `show_media` | `true` | The player's pill under the password bar |
| `show_seconds` | `false` | Seconds on the clock (`6:40:02`) |
| `clock_size` | `200` | The clock's size in pixels: `100`, `150` or `200` (80 to 240 works); the card under it follows |
| `show_power` | `true` | Sleep, restart and power off, on a pill at the bottom of the screen. Each is **held for a second**, since none of them can be undone |
| `mask_style` | `"shapes"` | What a typed character becomes: `"shapes"`, `"dots"`, `"asterisks"` or `"special"` (a random symbol) |
| `shape_palette` | `"accent"` | The colours of those: `"vibrant"`, `"accent"` (the theme's), `"neon"`, `"pastel"` or `"monochrome"` |
| `monitor` | `"all"` | Which monitor shows the lock: `"all"`, or a monitor's name (`"DP-2"`). The others are covered in black. A monitor that is not plugged in puts it on all of them, so there is always somewhere to type the password |

The monitor is also written into the scene's own `screens:` line, since that is the only place pleamar reads it from:
the Settings page does that when you pick one, and puts it back after an update that reset the file to `all`.

**Test lock** (on the Settings page) locks now in the safe mode below: Esc on an empty bar, or a minute without a key, opens it, and the next lock is a normal one again.

## What it needs

`awww` (to find the wallpaper), `magick` (it makes a sharp and a pre-blurred copy in `~/.cache/pleamar/lockscreen`),
the Space Grotesk and Material Symbols Outlined fonts, and PAM through pleamar's `auth.check`.

## A note on security

The lock is the compositor's (`ext-session-lock`), so nothing else on screen can be seen or touched while it lasts. But
the scene's `locked` fact can be changed from outside: any program running as you can open it with
`pleamar --say lockscreen "fact locked false"`, without the password. That is fine against someone at your keyboard
and no defence against a program already running as you.
