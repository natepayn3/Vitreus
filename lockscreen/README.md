# Lock screen

A lock screen for Vitreus, the wallpaper arrives sharp and blurs into place under a ring of
liquid that leaves the centre (`lockwave.wgsl`), then the clock, avatar and password bar rise in one after another.
Typed characters become random shapes (`shapes.svg`); the password itself is never drawn. It checks the password with
PAM (`auth.check`) and opens when it is right.

**It needs pleamar 0.2.2 or newer.** Before that, `kind: lock` made the compositor end pleamar with
`ext_session_lock_surface_v1: error 1: Null buffer attached` and left the session locked with no locker, and a picture
drawn on the lock only appeared on the first lock after the scene was read. Both were fixed upstream in 0.2.2.

## Turning it on

1. Start it with the desktop: add
   `pleamar --scene ~/.config/pleamar/shells/vitreus/lockscreen/lockscreen.plm --no-hud` to `~/.config/pleamar/autostart`.
2. Lock with `pleamar --say lockscreen "fact locked true"`. For idle and sleep, point hypridle's `lock_cmd`,
   `before_sleep_cmd` and idle listener at that same command, and bind a key to it. Something like
   `pleamar --say lockscreen "fact locked true" || <your old locker>` keeps a lock working if the scene is not running.
3. Try it first with `fact safe = true` in `lockscreen.plm`: then Esc on an empty box, or a minute of nothing, opens
   the lock, so a lock that does not behave cannot keep you out. It is `false` as shipped: only the password opens it.
   Have a TTY (Ctrl+Alt+F3) ready the first time either way.

Two things about the wallpaper: the pictures are cached 16:9 (an `image` is a fixed-shape cell, and the renderer will
not hold a bigger one), and they are made once, in the background, each time the wallpaper changes.

## What it needs

`awww` (to find the wallpaper), `magick` (it makes a sharp and a pre-blurred copy in `~/.cache/pleamar/lockscreen`),
the Space Grotesk and Material Symbols Outlined fonts, and PAM through pleamar's `auth.check`.

## A note on security

The lock is the compositor's (`ext-session-lock`), so nothing else on screen can be seen or touched while it lasts. But
the scene's `locked` fact can be changed from outside: any program running as you can open it with
`pleamar --say lockscreen "fact locked false"`, without the password. That is fine against someone at your keyboard
and no defence against a program already running as you.
