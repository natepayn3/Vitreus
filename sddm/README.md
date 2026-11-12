# The Vitreus login screen (SDDM)

The lock screen's look, as a theme for SDDM's greeter: your picture stays sharp, and the clock, the date, your face and a glass password bar rise one after another.
A typed character is a random shape (the password itself is never drawn). A wrong password shakes the bar. Sleep, restart and power off are held for a second.
The machine's name is in a corner, and the session badge under the password bar shows the session that will start (click it to go through the list: Hyprland, pleamar-wm...); if there are several users, click the face to change.

An SDDM greeter is a Qt program and a theme is QML, so this one is not a pleamar scene (the lock screen is). It needs `sddm` and `qt6-declarative`, which SDDM already depends on.

## Trying it first (no sudo, nothing installed)

```sh
./sddm/build-assets.sh /tmp/vitreus-greeter && QT_QPA_PLATFORM=xcb sddm-greeter-qt6 --test-mode --theme /tmp/vitreus-greeter
```

It opens the login screen in a window (`QT_QPA_PLATFORM=xcb` runs it through XWayland: without `qt6-wayland` it cannot open natively). Entering a password does not log in. If you see SDDM's blue default screen with
"Main.qml: No such file", the `--theme` path does not hold the theme: it only is in `/usr/share/sddm/themes/vitreus` after `install.sh`.

## Installing

Vitreus's own `install.sh` offers this (it asks, since it needs sudo; `--no-login` skips it), or run it yourself (the main installer also offers to update an older copy):

```sh
./sddm/install.sh                       # the picture it shows now (the first time: assets/greeter.jpeg, in the repository)
./sddm/install.sh ~/Pictures/other.jpg  # or another
./sddm/install.sh ~/Videos/loop.mp4     # or a video (.mp4, .mkv, .webm, .mov): it plays on a loop, muted, behind everything
```

It makes the pictures (sharp and blurred, 1920 x 1080) with ImageMagick, copies the theme to `/usr/share/sddm/themes/vitreus` with Space Grotesk, your `~/.face` and the colours of
Vitreus's palette, and makes it the theme in use. If SDDM has no theme set, that is done at once; **if it already has one it asks first** (`--set` or `--yes` says yes, `--no-set` only installs it, and with no keyboard to answer on it leaves the old one). The file that said which theme is in use is kept as `<file>.before-vitreus` in `/usr/local/share/vitreus-greeter/` (never in `/etc/sddm.conf.d/`: SDDM reads every file there, whatever its name). It asks for your password, as it uses `sudo`. Without a picture given, it keeps the one installed (the first time: `assets/greeter.jpeg` in the repository).
SDDM reads its settings only when it starts, so the new login screen shows after a reboot (or `sudo systemctl restart sddm` from a TTY, which ends your session); logging out is not enough. To see the installed one without logging out: `QT_QPA_PLATFORM=xcb sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/vitreus`.

(In test mode there is no user list, no session list and no power buttons, so the name, the corners and the power pill are left out.)

`./sddm/install.sh --remove` puts the theme that was in use back. If a login screen ever does not appear, Ctrl+Alt+F3 is a text login, and the same command works from there.

## Changing it

`vitreus/theme.conf` holds the colours and the 12 or 24 hour clock (installing writes the colours from `palette.plm`: install again after the palette changes). `vitreus/Main.qml` is the whole screen.
`./sddm/build-assets.sh OUTDIR [IMAGE]` makes a theme folder without installing it, to try with `--test-mode`.

## A video

Given a video, the theme keeps a copy without its sound (`background.mp4`, named in `theme.conf` as `video=`) and makes the picture from its first frame, so the screen is the same before it
starts playing, and stays as that picture if the greeter cannot play videos (it plays them through Qt Multimedia: `qt6-multimedia` and `qt6-multimedia-ffmpeg`, which the main installer lists as optional; Settings > Greeter says when they are missing). Needs `ffmpeg` to install.

## Changing it from Vitreus

Settings > Greeter chooses the login screen's picture or video (Open: a folder browser), goes back to the one installed with it, sets its 12 or 24 hour clock and opens it in a window (Test). Those ask for no password; turning it off (SDDM goes back to the theme it used before) and Apply (installing a newer copy) do, through polkit. Where SDDM is not installed the page is not in the sidebar. The settings:
`bin/vitreus-greeter` keeps them in `/usr/local/share/vitreus-greeter` (the folder `install.sh` makes yours), and the greeter only reads the names of the files there: `background.jpg`, `background.mp4`,
`clock-24` or `clock-12`. Without a `background.jpg` there, it uses the theme's own picture and video.

## Your picture

The greeter cannot read your home folder, so your face (`~/.face`) is kept in `/usr/local/share/vitreus-greeter`, a folder `install.sh` makes and gives to you. Changing your picture in Vitreus's Settings copies it there (no sudo);
for any other way of changing `~/.face`, run `./sddm/refresh-avatar.sh`.

