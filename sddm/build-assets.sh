#!/bin/sh
# build-assets.sh OUTDIR [IMAGE]: makes everything the theme needs that is not in the repository, in OUTDIR (a copy of vitreus/ with the pictures, the font, your face and the colours).
# IMAGE is the login screen's picture (default assets/greeter.jpeg in the repository), or a video (.mp4, .mkv, .webm, .mov), which plays on a loop, muted, behind it all.
# Needs ImageMagick (and ffmpeg for a video). Does not touch the system.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-assets.sh OUTDIR [IMAGE]}
img=${2:-$here/../assets/greeter.jpeg}
[ -f "$img" ] || { echo "no picture at $img" >&2; exit 1; }
stock=false; [ "$(readlink -f "$img")" = "$(readlink -f "$here/../assets/greeter.jpeg")" ] && stock=true
rm -rf "$out"
mkdir -p "$out/fonts"
cp -r "$here/vitreus/." "$out/"
# A video: kept without its sound (made to start at once), and its first frame is the picture, shown until it plays (and instead of it, if the greeter cannot play videos).
case $(printf '%s' "$img" | tr 'A-Z' 'a-z') in
    *.mp4|*.m4v|*.mkv|*.webm|*.mov)
        command -v ffmpeg > /dev/null 2>&1 || { echo "a video needs ffmpeg" >&2; exit 1; }
        ext=${img##*.}; ext=$(printf '%s' "$ext" | tr 'A-Z' 'a-z')
        ffmpeg -v error -y -i "$img" -map 0:v:0 -c:v copy -an -movflags +faststart "$out/background.$ext" ||
            ffmpeg -v error -y -i "$img" -map 0:v:0 -c:v copy -an "$out/background.$ext"
        ffmpeg -v error -y -i "$img" -frames:v 1 "$out/first-frame.png"
        sed -i "s|^video=.*|video=background.$ext|" "$out/theme.conf"
        img=$out/first-frame.png ;;
esac
sed -i "s|^stock=.*|stock=$stock|" "$out/theme.conf"
# the picture, sharp, and blurred the way the lock screen blurs the wallpaper (36 px at 1920 wide)
magick "$img[0]" -auto-orient -resize 1920x1080^ -gravity center -extent 1920x1080 -quality 92 "$out/background.jpg"
magick "$out/background.jpg" -resize 960x540 -blur 0x18 -resize 1920x1080 -quality 92 "$out/background-blur.jpg"
rm -f "$out/first-frame.png"
# the font, in the three weights the greeter uses (a greeter runs as another user, which does not see yours)
font=$(fc-match -f '%{file}' "Space Grotesk")
fdir=$(dirname "$font")
for w in Regular Medium Bold; do
    if [ -f "$fdir/static/SpaceGrotesk-$w.ttf" ]; then cp "$fdir/static/SpaceGrotesk-$w.ttf" "$out/fonts/"
    elif [ -f "$fdir/SpaceGrotesk-$w.ttf" ]; then cp "$fdir/SpaceGrotesk-$w.ttf" "$out/fonts/"
    elif [ -f "$font" ]; then   # one file for every weight (SpaceGrotesk[wght].ttf from the installer, SpaceGrotesk.ttf from Google Fonts' zip)
        # the one file the installer downloads holds every weight, but a greeter loading it three times would draw them all at its default weight: cut one static weight per file
        case $w in Regular) wt=400 ;; Medium) wt=500 ;; *) wt=700 ;; esac
        if python3 -m fontTools.varLib.instancer "$font" "wght=$wt" --update-name-table -o "$out/fonts/SpaceGrotesk-$w.ttf" > /dev/null 2>&1; then :
        else
            echo "Space Grotesk $w: cutting it from the variable font needs python-fonttools (pacman -S python-fonttools): the greeter will draw every weight the same" >&2
            cp "$font" "$out/fonts/SpaceGrotesk-$w.ttf"
        fi
    else echo "Space Grotesk $w was not found: the greeter will use another font for it" >&2; fi
done
# your face, if you have one (the greeter cannot read your home folder)
if [ -f "$HOME/.face" ]; then magick "$HOME/.face[0]" -resize 512x512 "$out/avatar.png"; fi
# the colours of Vitreus's palette, if it has one
pal="$here/../palette.plm"
if [ -f "$pal" ]; then
    get() { sed -n -E "s/^[[:space:]]*let[[:space:]]+$1[[:space:]]*=[[:space:]]*(#[0-9a-fA-F]{6}).*/\1/p" "$pal" | head -1; }
    for k in accent:mint ink:ink glass:tint; do
        name=${k%%:*}; var=${k##*:}; v=$(get "$var")
        [ -n "$v" ] && sed -i "s|^$name=.*|$name=$v|" "$out/theme.conf"
    done
fi
echo "built $out"
