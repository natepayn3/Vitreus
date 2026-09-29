# Lock screen (not active)

A lock screen for Vitreus, drawn after Synoptik's: the wallpaper arrives sharp and blurs into place under a ring of
liquid that leaves the centre (`lockwave.wgsl`), then the clock, avatar and password bar rise in one after another.
Typed characters become random shapes (`shapes.svg`); the password itself is never drawn.

**It is deliberately not wired to anything**: it is not in `autostart` and nothing calls it. The reason is a pleamar
bug, not this scene: `kind: lock` makes the compositor end the client with
`ext_session_lock_surface_v1: error 1: Null buffer attached` (Hyprland 0.56.2, NVIDIA, Vulkan). pleamar's own minimal
lock example from its reference does the same in a fresh nested Hyprland, and the session stays locked with no
client.

The cause is in pleamar's `src/platform/wayland.rs`: `update_input_region` commits the surface right away with no
buffer, which `ext-session-lock` forbids. Skipping that commit for lock surfaces (a `lock: bool` on `WaylandWindow`
and an early return) fixes it: with that change the lock is granted, this scene draws on a live session, and
unlocking works. Until that lands in pleamar, do not lock a live session with the stock binary.

## Turning it on, once pleamar can lock

1. Start it with the desktop: add
   `pleamar --scene ~/.config/pleamar/shells/vitreus/lockscreen/lockscreen.plm --no-hud` to `~/.config/pleamar/autostart`.
2. Lock with `pleamar --say lockscreen "fact locked true"`. For idle and sleep, point hypridle's `lock_cmd`,
   `before_sleep_cmd` and idle listener at that same command.
3. Try it in a **nested compositor first**, with a TTY ready. While `fact safe = true` (the default), Esc on an empty
   box unlocks it, and so does a minute of nothing. Set `safe` to `false` once it is trusted.

Two things about the wallpaper: the pictures are cached 16:9 (an `image` is a fixed-shape cell), and the renderer
draws the wallpaper on the first lock after the scene is read and on no later one (a second pleamar bug, not yet
reported), so the logic reloads the scene (by touching `lockscreen.plm`) whenever it publishes a new wallpaper and
after every unlock.

It needs `awww` (to find the wallpaper), `magick` (it makes a sharp and a pre-blurred copy in
`~/.cache/pleamar/lockscreen`), the Space Grotesk and Material Symbols Outlined fonts, and PAM through
pleamar's `auth.check`.
