# Vitreus add-ons

An add-on is a small pleamar scene of your own (a widget or a panel) that Vitreus starts when you turn its switch on in
**Settings > Add-ons**, and starts again if it stops.

## Add-ons that ship with Vitreus

| Add-on | What it does |
| --- | --- |
| **News & Weather** (`news-weather/`) | An RSS/Atom reader and an Open-Meteo forecast (48-hour graphs, 16 days, saved places). From jaslrobinson's drawer, issue #22. |
| **Home Assistant** (`homeassistant/`) | Your Home Assistant lights, switches, 3D printer and Apple TV, as tiles you can resize. From datingesp-hash's repository; see its README for the address and token. |
| **TV Remote** (`tvremote/`) | Control a Google TV or Android TV over the network. |
| **VPN** (`vpn/`) | Switch your VPN profiles on and off. |
| **EQ** (`eq/`) | A ten-band system equalizer with presets. |

Each one is listed in Settings > Add-ons. Turn it on and its icon shows up on the add-on pill.

## Writing your own

An add-on lives in its own folder, outside Vitreus's, so updating Vitreus never touches it.

1. Copy the `addons/_template/` folder to `~/.config/pleamar/vitreus-addons/<id>/` (the id is the folder's name: lowercase letters, digits and
   dashes) and change `addon.toml` and the scene it names.
2. Open **Settings > Add-ons**: your add-on is a card there, with the title and description from `addon.toml` and its own switch. Turn it on.

An add-on with an `icon` in its `addon.toml` (an `.svg` or `.png` in its folder) gets that icon on the **add-on pill**: a pill of icons, like the corner dock, in the corner the dock
is not in. Pull either pill across the middle of the screen and the two swap corners. For an add-on that shows a panel, copy `addons/_template_drawer/` instead: its `addon.toml` has a
`[drawer]` section (a size in pixels, or 0 for about the control centre's), and a click on its icon opens a panel out of the pill, in the same glass as the shell's own. The shell draws
the panel's title bar (the add-on's name, a grip and an X); your scene draws what is below it, in the place the shell tells it (`slot_x`, `slot_y`, `slot_w`, `slot_h`, `slot_open`), on the monitor it names (`slot_mon`, the monitor's name such as DP-1; the template's logic finds the copy of the scene that has it, which tells two monitors of the same size apart; `slot_sw`, `slot_sh` are that monitor's size). Like the
Desk, the panel stays until its X (or its icon) shuts it, and it can be pulled away from the pill and left anywhere. An add-on with an icon and no `[drawer]` gets a button that flips
`slot_open`, so it can show and hide its own window. A panel cannot take text yet, and shows on one monitor. A key can open the first panel with `pleamar --say vitreus "emit ax_toggle"`.
On the Island the icons can live on the bar instead: drag the **add-ons** piece (four small tiles) from the hidden row of Settings > Bar > Island layout onto the bar, anywhere
along it. The pill goes, its icons sit on the bar, and each panel drops from the bar under its icon, melted into it like the bar's own panels. With a frame they go back to the pill.

While it runs, Vitreus tells it, as facts and texts of its scene, the palette (so a theme restyles it at once), the room the bar takes, the theme's shape and the forecast; the template declares them all and says what each is. An add-on is not sandboxed: its scene declares the programs it runs and the services it reads in its own `permissions`, and turning it on lets it
have them, so read someone else's before you do. A folder that cannot be read is named in the line under the rows and left out. `bin/vitreus-addons`
reads the folders and leaves `addons.json` in the data folder; which are on is kept in `addons-state.json` there.

**Logic, data and programs.** A scene's logic is the `.luau` file with the scene's name beside it (`addon.plm` and `addon.luau`; the drawer template has one). It keeps what it must in the
scene's own data folder, `~/.local/share/pleamar/<scene's name>/`, with the `files` and `files.write` services (`sys.ask("files.folder")` is the folder's path, `files.read` and `files.write`
work by file name), and runs programs with `run(...)`: each one has to be named in the scene's `permissions { run: ... }`, and a program that is not on every machine (a helper like
`bin/vitreus-feedfetch`) is linked into `~/.local/bin` by `install.sh`. A panel can have a text field, which the shell takes the keys for (an add-on's scene never asks for
the keyboard: on two monitors Hyprland handed it, and the pointer with it, to the wrong copy): the add-on says where the field is with `pleamar --say vitreus "fact axf_on true"` and its
place (`axf_l`, `axf_t`, `axf_r`, `axf_h`), leaves that spot without a zone of its own, and draws what the shell sends back (`field_q`, `field_kb`, `field_enter`, `field_esc`); the
template has one, and logic/addons.luau has the messages. The shell tells an add-on the forecast as `wx_*` texts and facts when the scene declares them; an add-on that fetches its own weather should not name its
own `wx_*` or they would be overwritten (the News & Weather one uses `nw_*`). Give the scene file a name of its own: two add-ons whose scene files share a name cannot both run.

**Add-ons that frame wallpapers.** An add-on can declare `[wallpaper] frames = true` in its `addon.toml` (see `addons/_template_drawer/addon.toml`). Whenever Vitreus sets a wallpaper (a pick, Random, the slideshow, the picker; not a card's
quick try) it first asks that add-on, the first one that is on, for the picture awww should show, and keeps the old wallpaper on screen while it waits (30 s, again from each `wph_busy`). The shell stays the only one that calls awww, and it
remembers which wallpaper a made picture came from, so Iris and the gallery always read the real wallpaper, never the frame. The messages (`logic/wallpaper_hook.luau`): the shell sends `text wph_path`, `text wph_src` and `emit wph_frame <n>`
(and `text wph_cur`, the wallpaper in use, when it changes and every 10 s: it is the same path again each time, and a text fires its handler on every set, so an add-on acts only when the path differs from the last one it saw); the add-on answers with `pleamar --say vitreus "text wph_out <path>"` and `"emit wph_done <n>"` (the made picture, or `wph_src` itself for none), `"emit wph_busy <n>"`

## Notes on the bundled add-ons

**News & Weather** (`addons/news-weather/`, from jaslrobinson's drawer, issue #22) is a panel add-on built this way: an RSS/Atom reader and an Open-Meteo forecast (48-hour graphs, 16 days, saved places).
To use it, run `./install.sh` once (it links `vitreus-feedfetch`) and turn it on in Settings > Add-ons (it ships with the shell, so it is listed there; a copy of the same name in `~/.config/pleamar/vitreus-addons/` wins over it); its icon
appears on the add-on pill. Every card has a bin: press it twice. For an add-on in your own folder that sends its folder to the trash; for one that ships with the shell it takes the card off the list (a line under the cards brings them back). The add-on's own data, a token or a config, stays. Feeds and places are typed (the feed manager narrows the popular feeds as you write, and finds the feed of an address or `r/subreddit`; the place
search looks places up), or pasted from the clipboard.

**Home Assistant** (`addons/homeassistant/`, from datingesp-hash's repository) is a panel add-on for the lights, switches, a 3D printer and an Apple TV of a Home Assistant: tiles you can resize with the pencil, a card for each light (brightness, colour) and a remote. It ships with the shell and is listed in Settings > Add-ons; its README says where the address and the long-lived token go (`~/.local/share/pleamar/homeassistant/config.json`, which its gear opens).

**TV Remote** (`addons/tvremote/`) is a panel add-on that controls a Google TV or Android TV over the network: a d-pad, back, home, settings, volume, mute, play, a few streaming apps, power, and a field whose text is typed into the TV.
It finds the TVs on the network by itself (mDNS), and the name in its header opens a switcher for several of them (up to five, each paired once: the TV shows a six-character code, which is typed into the panel's field).
It speaks the protocol of the Google TV phone app through `bin/vitreus-tvremote` (Python standard library and `openssl`; `install.sh` links it into `~/.local/bin`). The certificate the TVs remember as paired is kept in the add-on's data
folder (`~/.local/share/pleamar/tvremote/`, mode 600): anyone who can read it can control those TVs. The panel scales with its size. Written with the help of an AI assistant (Claude).
