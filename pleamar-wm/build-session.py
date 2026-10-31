#!/usr/bin/env python3
"""Builds wm/session.plm: pleamar-wm's own scene, with what Vitreus changes in it.

    ./build-session.py [OUT_DIR]        (default: ./wm)

Nothing is kept by hand: the scene that comes with the installed pleamar-wm (`pleamar-wm scene DIR`) is read and the changes below are
made to it, each one asserting that the text it replaces is there exactly as often as expected. When pleamar-wm changes the lines a patch
stands on, this stops and says which one, so a new version is rebased by fixing that patch and running it again.

What it adds to pleamar-wm's scene:
  * the facts Vitreus's Settings > Pleamar-WM sets: gap, tb, bw, ba, rad, shd, tbo, wo_a, wo_i, wfr, wst, tbt, vit;
  * the room the shell's frame keeps round each monitor (fr.MONITOR.EDGE), added wherever the scene reads `win.reserved`;
  * the window styles (wst): 0 Vitreus glass, 1 Water, 2 Borderless, 3 Glow; and their corners, border, shadow, opacity and frost;
  * title bars on tiled windows (tbt), which pleamar-wm only gives to free ones;
  * focus_slot and close_slot, which the shell's task list emits to bring up or close a window by its slot;
  * a right press on the bare desktop, counted for Vitreus (desk_n, desk_x, desk_y, desk_mon), which opens the desktop menu.
"""
import os, re, subprocess, shutil, sys, tempfile

out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "wm"))
tmp = tempfile.mkdtemp(prefix="stock-")
subprocess.run(["pleamar-wm", "scene", tmp], check=True, stdout=subprocess.DEVNULL)
s = open(os.path.join(tmp, "session.plm")).read()


def once(old, new, n=1):
    global s
    c = s.count(old)
    if c != n:
        sys.exit("build-session: expected %d of this, found %d:\n%s" % (n, c, old[:300]))
    s = s.replace(old, new)


def between(start, end, fn):
    """Applies fn to the text from `start` up to `end` (both must be there once)."""
    global s
    i = s.index(start)
    assert s.count(start) == 1, "start is not unique: " + start[:80]
    j = s.index(end, i)
    s = s[:i] + fn(s[i:j]) + s[j:]


# ── header, facts ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
once("language 0.1\nscene Session {\n", 'language 0.1\nimport "../../wm-palette.plm"\nscene Session {\n')
once("    let gap = 12\n    let tb = 30                          // each window's title bar\n", """    // What Vitreus's Settings > Pleamar-WM sets, live (vitreus.luau puts them back when the scene is read in again):
    fact gap = 12                        // the space between windows
    fact tb = 22                         // each window's title bar
    fact bw = 1.5                        // the border: its width,
    fact ba = 70                         // its strength (%),
    fact rad = 12                        // the windows' corners,
    fact shd = 100                       // the shadow's strength (%),
    fact tbo = 72                        // how opaque the title bar's glass is (%),
    fact wo_a = 100                      // how opaque a window is (%), with the keyboard
    fact wo_i = 100                      // and without it,
    fact wfr = 80                        // how frosted the backing of a translucent window is (%),
    fact wst = 0                         // and the style: 0 Vitreus glass, 1 Water, 2 Borderless, 3 Glow
    fact tbt = 1                         // title bars on tiled windows too (pleamar-wm gives one only to free windows)
    fact vit = 0                         // Vitreus sets it to 1 once it has told the scene all of this: 0 means the scene was read in again
""")

# the room the shell's frame keeps round a monitor, beyond what other programs' bars reserve
frame = "".join("    fact fr.%d.%s = 0\n" % (m, e) for m in range(4) for e in ("top", "right", "bottom", "left"))
once("    windows win max 16 placement manual\n", """    windows win max 16 placement manual

    // The shell's task list picks a window by its slot: a click brings it up, its close button closes it (nothing else in the scene names a slot).
    event focus_slot
    event close_slot
    on focus_slot(v) { focus win(v) }
    on close_slot(v) { close win(v) }

    // The room Vitreus's glass frame keeps round each monitor, beyond what programs' bars reserve (Vitreus sets it).
""" + frame + """
    // A right press on the bare desktop asks for Vitreus's desktop menu (desktopmenu/): where, on which monitor, and a count that goes up each
    // time. Vitreus reads these and opens the menu there (a surface under the windows never hears the mouse here). The zone comes before
    // anything that is drawn over the desktop, so a window, its title bar or a dock takes the press first.
    fact desk_n = 0
    fact desk_x = 0
    fact desk_y = 0
    fact desk_mon = 0
    // The desktop is not one zone but a set of rectangles round the desktop widgets (Vitreus tells them: `dz.K.*`, logic/desk_holes.luau): a zone of this scene over
    // a widget on the bottom layer takes every click meant for it. Slot 0 starts as the whole desktop of every monitor (m = -1) until Vitreus says better.
    fact dz.0.m = -1
    fact dz.0.x = 0
    fact dz.0.y = 0
    fact dz.0.w = 4096
    fact dz.0.h = 4096
""" + "".join("    fact dz.%d.m = -9\n    fact dz.%d.x = 0\n    fact dz.%d.y = 0\n    fact dz.%d.w = 0\n    fact dz.%d.h = 0\n" % (k, k, k, k, k) for k in range(1, 32)) + """    repeat dzk in 0..32 {
        zone box desk.$dzk { from: dz.$dzk.x, dz.$dzk.y; size: dz.$dzk.w, dz.$dzk.h; active: dz.$dzk.w > 0.5 and (dz.$dzk.m < -0.5 and dz.$dzk.m > -1.5 or dz.$dzk.m == screen.index) }
        on press right desk.$dzk { desk_x = pointer.x; desk_y = pointer.y; desk_mon = screen.index; desk_n = desk_n + 1 }
    }
""")
s, k = re.subn(r"win\.reserved(\.\w+|\.\$\w+|\[[^\]]+\])\.(top|right|bottom|left)", r"(win.reserved\1.\2 + fr\1.\2)", s)
assert k > 10, "win.reserved was read %d times" % k

# ── the title bars setting (tbt) is for every window: a free one has its bar only while it is on (a program that draws its own frame keeps its own handle) ──────────────────────────────────────────────────────────────────────────────────────────────────
once("        let ours = F > 0.5 and win.$i.framed\n", "        let ours = tbt > 0.5 and win.$i.framed\n")
once("            zone box title.$i { from: ", "            let tbz = (F > 0.5 and not win.$i.framed) or ours\n            zone box title.$i { from: ")
once("from: x.$i + if(whole or F > 0.5, 0, 12) + if(not whole and fr and ours, 32, 0), y.$i - if(whole or F > 0.5, 0, gap - 1); size: if(whole, w, if(F > 0.5, w - 76, w - 24)) - if(not whole and fr and ours, 32, 0), if(whole, h, if(F > 0.5, tb, gap - 2));",
     "from: x.$i + if(whole or tbz, 0, 12) + if(not whole and fr and ours, 32, 0), y.$i - if(whole or tbz, 0, gap - 1); size: if(whole, w, if(tbz, w - 76, w - 24)) - if(not whole and fr and ours, 32, 0), if(whole, h, if(tbz, tb, gap - 2));")

# ── the corners where a window is not the one drawn in full ────────────────────────────────────────────────────────────────────────────
once("box { from: hx + 4, hy + 4; size: hw - 8, hh - 8; corner: 12;", "box { from: hx + 4, hy + 4; size: hw - 8, hh - 8; corner: rad;", 2)

# ── the window ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
once("""            body {
                color: #0c0e10
                shadow: 0, 14 + 8 * lit.$i + 10 * lift.$i, 34 + 18 * lift.$i, 45% + 20% * lit.$i + 10% * lift.$i
                show: water >= 0.999
                box { from: x, y; size: w, h; corner: 12 }
            }
""", """            let wop = (wo_i + (wo_a - wo_i) * lit.$i) / 100
            let wfrost = if(wfr > 0 and wop < 0.995, 1, 0)
            let wglass = if(wst == 1, 0, 1)
            body {
                color: #0c0e10
                opacity: wop
                shadow: 0, 14 + 8 * lit.$i + 10 * lift.$i, 34 + 18 * lift.$i, (45% + 20% * lit.$i + 10% * lift.$i) * shd / 100
                show: water >= 0.999 and wfrost < 0.5
                box { from: x, y; size: w, h; corner: rad }
            }
            // Translucent: the backing is frosted glass (it only goes solid as the window does).
            body {
                glass: wfr * 1%
                lens: false
                rim: 10%
                color: #0c0e10
                opacity: 60% + 40% * wop * wop * wop * wop * wop * wop
                shadow: 0, 14 + 8 * lit.$i + 10 * lift.$i, 34 + 18 * lift.$i, (45% + 20% * lit.$i + 10% * lift.$i) * shd / 100
                show: water >= 0.999 and wfrost > 0.5
                box { from: x, y; size: w, h; corner: rad }
            }
""")
once("""                body {
                    color: #0c0e10
                    shadow: 0, 14 + 8 * lit.$i + 10 * lift.$i, 34 + 18 * lift.$i, 45% + 20% * lit.$i + 10% * lift.$i
                    box { from: x, y; size: w, h; corner: 12 }
                }
""", """                body {
                    color: #0c0e10
                    shadow: 0, 14 + 8 * lit.$i + 10 * lift.$i, 34 + 18 * lift.$i, (45% + 20% * lit.$i + 10% * lift.$i) * shd / 100
                    box { from: x, y; size: w, h; corner: rad }
                }
""")

BAR_FLAT = "box { from: x, y; size: w, tb * hb.$i; color: mix(#1a1e22, #1d2b27, lit.$i); show: hb.$i > 0.01 }"
BAR_NEW = """box { from: x, y; size: w, tb * hb.$i; color: mix(#1a1e22, #1d2b27, lit.$i); show: hb.$i > 0.01 and wglass < 0.5 }
                body {
                    color: mix(#0b1015, #0f1d1a, lit.$i)
                    glass: 85%
                    lens: false
                    rim: 14%
                    opacity: tbo / 100 + 20% * lit.$i
                    show: hb.$i > 0.01 and wglass > 0.5
                    box { from: x, y; size: w, tb * hb.$i }
                }
                box { from: x, y + tb * hb.$i - 1; size: w, 1; color: #ffffff; opacity: 9%; show: hb.$i > 0.99 and wglass > 0.5 }"""
TITLE_OLD = "size: 12; weight: 500; width: max(w - 110 - 24 * cvpt.$i"
TITLE_NEW = 'size: 11.5; weight: 600; family: "Space Grotesk"; width: max(w - 110 - 24 * cvpt.$i'
BUTTONS_OLD = """            group {
                show: hb.$i > 0.01
                opacity: (45% + 55% * max(lit.$i, b.any)) * hb.$i * smooth(0.75, 1, water)
"""
PILL = """            // Vitreus's: a small pill of glass with thin line icons in the ink; the mouse over one, a soft light comes up behind it (the cross, coral).
            group {
                show: hb.$i > 0.01 and wst != 1
                opacity: (55% + 45% * max(lit.$i, b.any)) * hb.$i * smooth(0.75, 1, water)
                body {
                    color: #ffffff
                    opacity: 9%
                    rim: 30%
                    box { at: x + w - 40 - 10 * Fm, by; size: 60 + 20 * Fm, 18; corner: 9 }
                }
                ellipse { at: x + w - 60, by; radius: 9; color: amber; opacity: 28% * mini_zone.$i.hover; show: Fm > 0.5 }
                ellipse { at: x + w - 40, by; radius: 9; color: mint; opacity: 28% * lead_zone.$i.hover }
                ellipse { at: x + w - 20, by; radius: 9; color: coral; opacity: 34% * close_zone.$i.hover }
                box { at: x + w - 60, by + 2; size: 7, 1.4; corner: 0.7; color: ink; opacity: (70% + 30% * mini_zone.$i.hover) * Fm }
                box { at: x + w - 40, by; size: 7, 7; corner: 1.6; stroke: 1.3; color: ink; opacity: (70% + 30% * lead_zone.$i.hover) * (1 - maxed.$i) }
                box { at: x + w - 41.5, by + 1.2; size: 5.5, 5.5; corner: 1.3; stroke: 1.2; color: ink; opacity: (70% + 30% * lead_zone.$i.hover) * maxed.$i }
                box { at: x + w - 38.5, by - 1.2; size: 5.5, 5.5; corner: 1.3; stroke: 1.2; color: ink; opacity: (70% + 30% * lead_zone.$i.hover) * maxed.$i * 0.7 }
                box { at: x + w - 20, by; size: 8, 1.4; corner: 0.7; rotate: 45deg; color: ink; opacity: 70% + 30% * close_zone.$i.hover }
                box { at: x + w - 20, by; size: 8, 1.4; corner: 0.7; rotate: -45deg; color: ink; opacity: 70% + 30% * close_zone.$i.hover }
            }
"""
BORDER_OLD = "            box { from: x, y; size: w, h; corner: 12; stroke: 1.5; color: mint; opacity: lit.$i * 70% * (1 - ov) * smooth(0.75, 1, water) }\n"
BORDER_NEW = """            // The border, by style: Vitreus's thin line in the palette's colour, the Water style's mint one, none at all, or a soft glow for the focused one.
            box { from: x, y; size: w, h; corner: rad; stroke: bw; color: wm_border; opacity: lit.$i * ba / 100 * (1 - ov) * smooth(0.75, 1, water); show: wst == 0 and bw > 0.01 }
            box { from: x, y; size: w, h; corner: rad; stroke: 1.5; color: mint; opacity: lit.$i * 70% * (1 - ov) * smooth(0.75, 1, water); show: wst == 1 }
            group {
                show: wst == 3 and bw > 0.01
                glow: 12, 85%, wm_border
                box { from: x, y; size: w, h; corner: rad; stroke: bw; color: wm_border; opacity: lit.$i * ba / 100 * (1 - ov) * smooth(0.75, 1, water) }
            }
"""


def window(t):
    assert t.count(BAR_FLAT) == 3, t.count(BAR_FLAT)
    t = t.replace(BAR_FLAT, BAR_NEW)
    assert t.count(TITLE_OLD) == 3
    t = t.replace(TITLE_OLD, TITLE_NEW)
    c = t.count("window win.$i { at: x, y + tb * hb.$i;")
    assert c == 3, c
    t = t.replace("window win.$i { at: x, y + tb * hb.$i;", "window win.$i { opacity: wop; at: x, y + tb * hb.$i;")
    t = t.replace("corner: 12 }", "corner: rad }")
    assert t.count(BUTTONS_OLD) == 1
    t = t.replace(BUTTONS_OLD, PILL + """            // Water's: three drops, lit from above; the mouse over one, it swells, a halo spreads round it and it shows what it does.
            group {
                show: hb.$i > 0.01 and wst == 1
                opacity: (45% + 55% * max(lit.$i, b.any)) * hb.$i * smooth(0.75, 1, water)
""")
    assert t.count(BORDER_OLD) == 1
    return t.replace(BORDER_OLD, BORDER_NEW)


# The window runs from its title bars to its border line (the last thing before "// Tiled, where it is taken ...").
i = s.index("            // Without the keyboard, only its title bar steps back: what it shows\n")
j = s.index(BORDER_OLD, i) + len(BORDER_OLD)
s = s[:i] + window(s[i:j]) + s[j:]

# ── the window being carried, and a dialog ─────────────────────────────────────────────────────────────────────────────────────────────
def carried(t):
    t = t.replace("corner: 12 }", "corner: rad }")
    old = "            box { from: x, y; size: w, h; corner: 12; stroke: 1.5; color: mint; opacity: 80% }\n"
    assert t.count(old) == 1
    return t.replace(old, "            box { from: x, y; size: w, h; corner: rad; stroke: if(wst == 1, 1.5, max(bw, 1)); color: if(wst == 1, mint, wm_border); opacity: if(wst == 2, 30%, 80%) }\n")


between("            show: dragging == i or (landing == i and win.$i.open and win.$i.screen != landing.to)\n            opacity: 88%\n",
        "    // ── the layouts strip: while a window is carried",
        carried)


def dialog(t):
    t = t.replace("corner: 12 }", "corner: rad }")
    old = "            box { from: dx, dy; size: dw, dh; corner: 12; stroke: 1.5; color: mint; opacity: 70% * win.$i.focused }\n"
    assert t.count(old) == 1
    return t.replace(old, "            box { from: dx, dy; size: dw, dh; corner: rad; stroke: if(wst == 1, 1.5, max(bw, 1)); color: if(wst == 1, mint, wm_border); opacity: if(wst == 2, 0%, 70%) * win.$i.focused }\n")


between("    repeat i in 0..16 {\n        let dw = max(win.$i.width, 120)\n", "    // The rain itself, in front of everything", dialog)

# Each window's agent basin reads `time` even when no agent is on it (`pick` takes its first branch, a wobble, at 0), and the scene never
# rests: every round is made again, ~165 a second, for a basin that is not shown. Only an agent's own window needs the wobble.
once("let ag.lvl = pick(max(ag.$i - 1, 0), 6 + 1.5 * sin(fxclock * 300), 3.5, 9.5)",
     "let ag.lvl = if(ag.$i > 0.5, pick(max(ag.$i - 1, 0), 6 + 1.5 * sin(fxclock * 300), 3.5, 9.5), 0)")

# (Upstream now keeps its own clock, `fxclock`, spinning only while an agent works: the patch that took `time` out of the scene is gone, 0.6.3.)

os.makedirs(os.path.join(out, "shaders"), exist_ok=True)
for f in os.listdir(os.path.join(tmp, "shaders")):
    shutil.copy(os.path.join(tmp, "shaders", f), os.path.join(out, "shaders", f))
hdr = "// Generated by build-session.py from the pleamar-wm that is installed ($(pleamar-wm --version)): do not edit this file, change the patches there.\n"
ver = subprocess.run(["pleamar-wm", "--version"], capture_output=True, text=True).stdout.strip()
open(os.path.join(out, "session.plm"), "w").write(hdr.replace("$(pleamar-wm --version)", ver) + s)
shutil.rmtree(tmp)
print("build-session · wrote %s/session.plm (%d lines)" % (out, s.count("\n")))
