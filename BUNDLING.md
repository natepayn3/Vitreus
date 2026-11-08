# Getting an add-on included in Vitreus

Anyone can write a Vitreus add-on and share it from their own repository, in any style. Nothing here applies to that: it works from `~/.config/pleamar/vitreus-addons/<id>/` as it is.

This page is for an add-on that is **included natively** (listed in Settings > Add-ons from the first start, off until switched on). You keep hosting it in your own repository; Vitreus keeps a pinned copy (the fallback) and follows your releases: the installer fetches your newest release when someone installs or updates the shell. Being included is by agreement, and either side can start the conversation.

## What I ask of you

1. **Follow the add-on style.** `addons/_template_drawer/STYLE.md` has the rules (switches, sliders, cards, fonts, margins, how things move) and `addon-pencil.plm` has the components. Draw with `PSwitch` and `PSlider`, take colours from `addon-palette.plm`, draw icons in pencil (no icon fonts), and use the Space Grotesk font. A proposal that is nearly there is a conversation, not a rejection.
2. **Publish tagged releases** (a GitHub Release such as `v1.0.0`). Vitreus follows releases, never your main branch, so you decide when an update reaches people.
3. **Fill in `addon.toml`**: `name`, `description`, `author`, `version`, `vitreus_api`, and `repo = "owner/name"` so the card in Settings links to your repository.
4. **Open your config file with `vitreus-edit FILE`** (name it in `permissions { run: … }`), not with an editor of your own choosing: it finds the person's editor the
   same way for every add-on ($VISUAL / $EDITOR, the desktop's text editor, the usual ones). It exits with 3 when there is none: then say so where the button is, for
   a few seconds (install a text editor or set $EDITOR, and where the file is), so that the button never seems to do nothing.
5. **Keep `permissions` honest**: name every program the add-on runs. Say in your README how a token or password is kept, and send nothing anywhere the user did not set up.
6. **Include a licence file** compatible with Vitreus's (MIT), and a README with screenshots. Say in it if an AI assistant helped.

## Check it yourself

Clone Vitreus and run this on your add-on's folder:

    bin/vitreus-sync-addons lint path/to/your-addon

Errors have to be fixed; warnings are for a person to judge. It checks what a program can (the files above, literal colours, fonts, `permissions`, that the scene compiles). It cannot judge how it looks, so I look at that myself.

## What I do in return

- Fetch your newest published release when the shell is installed or updated (`bin/vitreus-sync-addons latest`), so people get what you last released without waiting for me. If that fails (offline, no release), the pinned copy is used.
- Pin your release in `addons/bundled.toml` (repository, tag and exact commit) and copy it into `addons/<id>/`.
- Open a pull request when you publish a newer release, and read the diff before it ships. The style check runs on it, so a release that drifts from the style is caught there.
- Credit you on the card (your name, and a link to your repository) and keep your licence in the folder.
- Drop the add-on, and stay on the last release, if you ever ask me to.

If you would rather I host it, ask, and we agree it first.
