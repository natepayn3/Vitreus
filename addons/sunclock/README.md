# Sun Clock

A world map with the night side shaded in pencil, the line where day ends, the sun where it is overhead and a dot where you are. Under the map are the
time and the day's sunrise, sunset and length of daylight.

The idea came from Mezo0n (issue #79), after sentriz's [wlr-sunclock](https://github.com/sentriz/wlr-sunclock). The land is from
[Natural Earth](https://www.naturalearthdata.com/) (public domain), simplified to fit the panel.

## Using it

Turn it on in **Settings > Add-ons**. Its icon shows up on the add-on pill, and a click on the icon opens the map.

- **Where you are** is the place the weather uses (Settings > VPN > Weather), so the two always agree. If the shell has no place to give, the add-on
  looks you up by IP once a day (ipwho.is) and keeps the answer in `~/.local/share/pleamar/sunclock/`. This is the only thing it sends anywhere.
- Times follow the 12- or 24-hour choice in Settings > Clock.
- Times are shown in this computer's time zone.

Night darkens through twilight and is full at 12° below the horizon. The line marks where the sun is on the horizon. The sun's position is the usual
low-precision formula: accurate to about a minute, which is far finer than the map can show.

Written with the help of an AI assistant (Claude).
