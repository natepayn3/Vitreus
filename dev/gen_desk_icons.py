#!/usr/bin/env python3
"""Writes pages/desk_icons.plm: the Desk tiles' icons in the shell's boiled pencil (see PCam, PCupK, PMoon in vitreus.plm).

Every icon is drawn as the control center's are: an accent wash, the outline twice (a strong line, then a faint copy a hair off, both crooked a
little), detail strokes, and hatching. At rest they are still; they redraw about five times a second while `hot` (the pointer on them), and grow a
little. Each is a component DG<Name>(cx, cy, hot, k, c, o): `k` pixels to a unit (the glyph spans about 22 units), colour `c`, strength `o`.

    python3 dev/gen_desk_icons.py            # rewrites pages/desk_icons.plm
"""
import math
import os

def n(v):
    s = ("%.3f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s

def star(cx, cy, r, pin=0.13):
    """a four-pointed star with curved sides, as PBSpark draws it"""
    p = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    out = [("m",) + p[0]]
    for i in range(4):
        a, b = p[i], p[(i + 1) % 4]
        # the pull point: toward the middle, off the straight line between the two tips
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        vx, vy = cx - mx, cy - my
        out.append(("c", b[0], b[1], mx + vx * (1 - pin) , my + vy * (1 - pin)))
    out.append(("z",))
    return out

def pol(r, a):
    return (r * math.cos(math.radians(a)), r * math.sin(math.radians(a)))

# ---- the glyphs: ops are ("wash", path, alpha) ("line2", path, w) ("line1", path, w, alpha) ("dot", x, y, r, alpha) ("ring2", x, y, r, w)
# ("ring1", x, y, r, w, alpha) ("washdisc", x, y, r, alpha) ("rbox", x0, y0, x1, y1, corner, w) ("wbox", x0, y0, x1, y1, corner, alpha) -------------
def L(x0, y0, x1, y1):
    return [("m", x0, y0), ("l", x1, y1)]

G = {}

G["Notes"] = [
    ("wbox", -8, -8.5, 8, 10, 3, .24),
    ("rbox", -8, -8.5, 8, 10, 3, 1.8),
    ("line1", L(-4, -11, -4, -7), 1.7, 1), ("line1", L(0, -11, 0, -7), 1.7, 1), ("line1", L(4, -11, 4, -7), 1.7, 1),
    ("line1", [("m", -5.8, -2.4), ("l", -4.5, -0.9), ("l", -2, -4.6)], 1.7, 1),
    ("line1", L(0, -2.6, 5, -2.6), 1.4, .65),
    ("line1", [("m", -5.8, 2.6), ("l", -4.5, 4.1), ("l", -2, 0.4)], 1.7, 1),
    ("line1", L(0, 2.4, 4, 2.4), 1.4, .65),
    ("ring1", -4, 7.2, 1.4, 1.2, .8),
    ("line1", L(0, 7.2, 3, 7.2), 1.4, .65),
    ("line1", L(5.2, 5.5, 6.4, 8.6), 1.0, .5),
]

PEN = [("m", -3, -7.5), ("l", -3, 6), ("l", 0, 11), ("l", 3, 6), ("l", 3, -7.5)]
G["Pad"] = [
    ("rot", 45, [
        ("wash", PEN + [("z",)], .26),
        ("wbox", -3, -11.5, 3, -7.5, 1.4, .5),
        ("line2", PEN, 1.8),
        ("rbox", -3, -11.5, 3, -7.5, 1.4, 1.6),
        ("line1", L(-3, -5.6, 3, -5.6), 1.1, .8),
        ("line1", L(-3, 6, 3, 6), 1.0, .6),
        ("line1", L(0, -4.2, 0, 6), 1.0, .5),
        ("line1", L(-1.8, -2, -1.8, 3), 1.0, .65), ("line1", L(1.7, -1, 1.7, 2.5), 1.0, .5),
        ("wash", [("m", -1.3, 8.7), ("l", 0, 11), ("l", 1.3, 8.7), ("z",)], .95),
    ]),
    ("line1", [("m", -11, 10.2), ("c", -5.5, 10.2, -8.5, 7.4), ("c", 0, 10.2, -2.8, 13)], 1.5, .9),
]

FOLDER = [("m", -10, -3), ("l", -10, -7), ("c", -8.5, -8.6, -10, -8.6), ("l", -4, -8.6), ("c", -2.2, -7, -3, -8.6), ("l", -1.5, -5.6),
          ("l", 8.5, -5.6), ("c", 10, -4.1, 10, -5.6), ("l", 10, 7), ("c", 8.5, 8.6, 10, 8.6), ("l", -8.5, 8.6), ("c", -10, 7, -10, 8.6), ("z",)]
G["Shelf"] = [
    ("wash", FOLDER, .22),
    ("line1", [("m", 1, -5.6), ("l", 1.6, -9.6), ("l", 7, -9.1), ("l", 7.5, -5.6)], 1.3, .8),
    ("line1", L(3, -7.6, 6, -7.4), 1.0, .6),
    ("line2", FOLDER, 1.8),
    ("line1", [("m", -10, -1), ("l", 10, -1.8)], 1.5, .9),
    ("line1", L(-7, 2.2, -6.2, 5.8), 1.1, .6), ("line1", L(-4.8, 2.1, -4, 5.7), 1.1, .6), ("line1", L(-2.6, 2, -1.8, 5.6), 1.1, .6),
]

G["Clip"] = [
    ("wbox", -8, -8, 8, 10, 2.5, .24),
    ("rbox", -8, -8, 8, 10, 2.5, 1.8),
    ("wbox", -3.8, -11.5, 3.8, -6.2, 1.6, .5),
    ("rbox", -3.8, -11.5, 3.8, -6.2, 1.6, 1.6),
    ("ring1", 0, -8.85, 1.0, 1.1, .8),
    ("line1", L(-4, -1, 4, -1), 1.4, .65), ("line1", L(-4, 2.5, 4, 2.5), 1.4, .65), ("line1", L(-4, 6, 1, 6), 1.4, .65),
    ("line1", L(4.6, 5, 6, 8), 1.0, .5),
]

G["Focus"] = [
    ("washdisc", 0, 1.5, 8.5, .2),
    ("ring2", 0, 1.5, 8.5, 1.8),
    ("line1", L(0, -7, 0, -9.4), 1.6, 1), ("line1", L(-2.5, -10.2, 2.5, -10.2), 1.8, 1),
    ("line1", L(6.2, -4.6, 8.4, -6.8), 1.7, 1),
    ("line1", L(0, -4.9, 0, -3.7), 1.2, .8), ("line1", L(6.4, 1.5, 5.2, 1.5), 1.2, .8),
    ("line1", L(0, 7.9, 0, 6.7), 1.2, .8), ("line1", L(-6.4, 1.5, -5.2, 1.5), 1.2, .8),
    ("wash", [("m", 0, 1.5), ("l", 0, -2.6), ("c", 4.1, 1.5, 4.1, -2.6), ("z",)], .4),
    ("line1", L(0, 1.5, 2.8, -1.4), 1.5, 1),
    ("dot", 0, 1.5, 1.0, 1),
]

G["Term"] = [
    ("wbox", -10.5, -8, 10.5, 8.5, 2.6, .22),
    ("rbox", -10.5, -8, 10.5, 8.5, 2.6, 1.8),
    ("line1", L(-10.4, -4.2, 10.4, -4.2), 1.3, .8),
    ("dot", -7.6, -6.1, .8, .9), ("dot", -5.3, -6.1, .8, .9), ("dot", -3, -6.1, .8, .9),
    ("line1", [("m", -6.8, -0.8), ("l", -3.2, 2.1), ("l", -6.8, 5)], 1.8, 1),
    ("line1", L(-1.2, 5.2, 3.6, 5.2), 1.8, 1),
    ("line1", L(-0.6, -0.6, 6, -0.6), 1.2, .55),
    ("line1", L(7.2, 2.4, 8.2, 5.8), 1.0, .5),
]

BIG = star(-2, 2.5, 9)
SMALL = star(6.6, -6.6, 4.2, .1)
G["Ask"] = [
    ("wash", BIG, .26), ("wash", SMALL, .35),
    ("line2", BIG, 1.8), ("line2", SMALL, 1.4),
    ("dot", -9, -7.5, .8, .9), ("dot", 8.6, 6.8, .9, .9), ("dot", 9, -0.5, .6, .7),
    ("line1", L(-5.2, 2.4, -4.7, 5.6), 1.0, .6), ("line1", L(-3.5, 3.4, -3.1, 6.2), 1.0, .5),
]

CAM = [("m", -7, -5), ("l", -4, -5), ("l", -2.5, -8), ("l", 3, -8), ("l", 4.5, -5), ("l", 7, -5), ("c", 10, -2, 10, -5), ("l", 10, 5),
       ("c", 7, 8, 10, 8), ("l", -7, 8), ("c", -10, 5, -10, 8), ("l", -10, -2), ("c", -7, -5, -10, -5), ("z",)]
G["Camera"] = [
    ("wash", CAM, .22),
    ("line2", CAM, 1.8),
    ("ring2", 0, 1.5, 4.8, 1.8),
    ("ring1", 0, 1.5, 2.6, 1.1, .65),
    ("dot", 0, 1.5, 2.1, .45), ("dot", -1, .5, .7, 1),
    ("dot", 7, -2.5, 1.1, 1),
    ("line1", L(-8, -1, -7.5, 4), 1.1, .65), ("line1", L(-6.5, 0.5, -6, 5.5), 1.1, .65),
    ("line1", L(5.5, -6.4, 8, -6.4), 1.1, .6),
]

HOLD = [("m", -7, -3), ("l", -7, 0), ("c", 0, 7.5, -7, 7.5), ("c", 7, 0, 7, 7.5), ("l", 7, -3)]
G["Memos"] = [
    ("wbox", -3.6, -10.5, 3.6, 2, 3.6, .3),
    ("rbox", -3.6, -10.5, 3.6, 2, 3.6, 1.8),
    ("line1", L(-2.2, -6.6, 2.2, -6.6), 1.1, .6), ("line1", L(-2.8, -3.6, 2.8, -3.6), 1.1, .6), ("line1", L(-2.2, -0.6, 2.2, -0.6), 1.1, .6),
    ("line2", HOLD, 1.6),
    ("line1", L(0, 7.5, 0, 10.6), 1.6, 1), ("line1", L(-4, 10.9, 4, 10.9), 1.8, 1),
]

teeth = []
for k in range(8):
    a = k * 45
    p0, p1, p2, p3, p4 = pol(7.2, a - 14), pol(10.2, a - 9.5), pol(10.2, a + 9.5), pol(7.2, a + 14), pol(7.2, a + 31)
    teeth.append(("line2", [("m",) + p0, ("l",) + p1, ("l",) + p2, ("l",) + p3, ("l",) + p4], 1.7))
G["Settings"] = [("washdisc", 0, 0, 8.4, .22)] + teeth + [
    ("ring2", 0, 0, 3.3, 1.7),
    ("line1", L(-5.6, -2.2, -5.1, 1.8), 1.0, .6), ("line1", L(-4.3, -4, -3.8, -0.4), 1.0, .5), ("line1", L(4.4, 2.2, 5, 5), 1.0, .5),
]

HOUSE = [("m", -7, -1.5), ("l", 0, -8.5), ("l", 7, -1.5), ("l", 7, 9.5), ("l", -7, 9.5), ("z",)]
G["Home"] = [
    ("wash", HOUSE, .24),
    ("line2", [("m", -10.5, 0), ("l", 0, -9.6), ("l", 10.5, 0)], 1.8),
    ("line2", [("m", -7, -2), ("l", -7, 9.5), ("l", 7, 9.5), ("l", 7, -2)], 1.7),
    ("line1", [("m", 4.5, -5.6), ("l", 4.5, -9.2), ("l", 7.2, -9.2), ("l", 7.2, -3.6)], 1.4, .9),
    ("line1", [("m", -2.3, 9.5), ("l", -2.3, 4.2), ("c", 2.3, 4.2, 0, 1), ("l", 2.3, 9.5)], 1.4, .9),
    ("rbox", 3.6, -0.2, 6, 2.2, 0.4, 1.1),
    ("line1", L(-5.8, 1.5, -5.2, 5.5), 1.0, .6), ("line1", L(-4.2, 2, -3.6, 6), 1.0, .5),
]

# ---- emitting ---------------------------------------------------------------------------------------------------------------------------------
def coord(x, y, i):
    j = ("bj", "bk") if i % 2 == 0 else ("bk", "bj")
    return "cx + %s * k + %s, cy + %s * k + %s" % (n(x), j[0], n(y), j[1])

def path_body(cmds, jitter=True):
    out, i = [], 0
    for c in cmds:
        if c[0] == "z":
            out.append("close")
            continue
        if c[0] == "c":
            out.append("curve cx + %s * k, cy + %s * k via cx + %s * k, cy + %s * k" % (n(c[1]), n(c[2]), n(c[3]), n(c[4])))
        else:
            word = "move" if c[0] == "m" else "line"
            out.append("%s %s" % (word, coord(c[1], c[2], i) if jitter else "cx + %s * k, cy + %s * k" % (n(c[1]), n(c[2]))))
        i += 1
    return "; ".join(out)

def emit(op, pad, seed, lines):
    """one op as plm lines; ops of the outline kind are emitted inside the two-pass repeat"""
    t = op[0]
    if t == "wash":
        lines.append(pad + "path { at: 0, 0; color: c; opacity: %s * o; %s }" % (n(op[2]), path_body(op[1], False).replace("cx", "cx").replace("cy", "cy")))
    elif t == "wbox":
        x0, y0, x1, y1, r, al = op[1:]
        lines.append(pad + "box { at: cx + %s * k, cy + %s * k; size: %s * k, %s * k; corner: %s * k; color: c; opacity: %s * o }" % (n((x0 + x1) / 2), n((y0 + y1) / 2), n(x1 - x0), n(y1 - y0), n(r), n(al)))
    elif t == "washdisc":
        lines.append(pad + "ellipse { at: cx + %s * k, cy + %s * k; radius: %s * k; color: c; opacity: %s * o }" % (n(op[1]), n(op[2]), n(op[3]), n(op[4])))
    elif t == "line1":
        lines.append(pad + "path { at: 0, 0; stroke: %s * k; color: c; opacity: %s * o; %s }" % (n(op[2]), n(op[3]), path_body(op[1])))
    elif t == "dot":
        lines.append(pad + "ellipse { at: cx + %s * k + bj, cy + %s * k + bk; radius: %s * k; color: c; opacity: %s * o }" % (n(op[1]), n(op[2]), n(op[3]), n(op[4])))
    elif t == "ring1":
        lines.append(pad + "ellipse { at: cx + %s * k + bj, cy + %s * k + bk; radius: %s * k; stroke: %s * k; color: c; opacity: %s * o }" % (n(op[1]), n(op[2]), n(op[3]), n(op[4]), n(op[5])))

def outline_ops(ops):
    return [o for o in ops if o[0] in ("line2", "rbox", "ring2")]

def build(name, ops):
    L_ = []
    L_.append("    component DG%s(cx: number, cy: number, hot: number, k: number, c: color, o: number) {" % name)
    L_.append("        prop a = 0 ~calm")
    L_.append("        follow a = hot")
    L_.append("        let fr = if(a > 0.02, floor(time * 5), 0)")
    L_.append("        group {")
    L_.append("            pivot: cx, cy")
    L_.append("            scale: 1 + 0.08 * a")
    L_.append("            let bj = (0.2 + 0.3 * a) * k * sin(fr * 53 + 23)")
    L_.append("            let bk = (0.2 + 0.3 * a) * k * sin(fr * 61 + 67)")

    def layer(ops_, pad):
        out = []
        # washes first, then the outlines twice, then the details
        for o in ops_:
            if o[0] in ("wash", "wbox", "washdisc"):
                emit(o, pad, 0, out)
        oo = outline_ops(ops_)
        if oo:
            out.append(pad + "repeat bp in 0..2 {")
            p2 = pad + "    "
            out.append(p2 + "let bo = bp * 0.7 * k")
            out.append(p2 + "let bj = (0.2 + 0.3 * a) * k * sin(fr * 53 + bp * 137 + 23)")
            out.append(p2 + "let bk = (0.2 + 0.3 * a) * k * sin(fr * 61 + bp * 71 + 67)")
            for o in oo:
                if o[0] == "line2":
                    out.append(p2 + "path { at: bo, bo * 0.5; stroke: if(bp == 0, 1, 0.72) * %s * k; color: c; opacity: if(bp == 0, 90%%, 34%%) * o; %s }" % (n(o[2]), path_body(o[1])))
                elif o[0] == "rbox":
                    x0, y0, x1, y1, r, w = o[1:]
                    out.append(p2 + "box { at: cx + %s * k + bo + bj, cy + %s * k + bo * 0.5 + bk; size: %s * k, %s * k; corner: %s * k; stroke: if(bp == 0, 1, 0.72) * %s * k; color: c; opacity: if(bp == 0, 90%%, 34%%) * o }" % (n((x0 + x1) / 2), n((y0 + y1) / 2), n(x1 - x0), n(y1 - y0), n(r), n(w)))
                elif o[0] == "ring2":
                    out.append(p2 + "ellipse { at: cx + %s * k + bo + bj, cy + %s * k + bo * 0.5 + bk; radius: %s * k; stroke: if(bp == 0, 1, 0.72) * %s * k; color: c; opacity: if(bp == 0, 90%%, 34%%) * o }" % (n(o[1]), n(o[2]), n(o[3]), n(o[4])))
            out.append(pad + "}")
        for o in ops_:
            if o[0] in ("line1", "dot", "ring1"):
                emit(o, pad, 0, out)
        return out

    rot = [o for o in ops if o[0] == "rot"]
    flat = [o for o in ops if o[0] != "rot"]
    for r in rot:
        L_.append("            group {")
        L_.append("                pivot: cx, cy")
        L_.append("                rotate: %sdeg" % n(r[1]))
        L_.extend(layer(r[2], "                "))
        L_.append("            }")
    L_.extend(layer(flat, "            "))
    L_.append("        }")
    L_.append("    }")
    return L_

def main():
    out = ["//  GENERATED by dev/gen_desk_icons.py: do not edit by hand.",
           "//  The Desk tiles' icons in the shell's boiled pencil, as the control center's camera and mug are drawn (see PCam, PCupK in vitreus.plm): a wash, the outline",
           "//  twice (the second pass fainter and a hair off), detail strokes and hatching. Still at rest; about five redrawings a second while `hot` (the pointer on",
           "//  the tile), and a little bigger then. `k` pixels to a unit (an icon spans about 22 units), `c` the colour, `o` how strong.",
           "part DeskIcons {"]
    for name in ("Notes", "Pad", "Shelf", "Clip", "Focus", "Term", "Ask", "Camera", "Memos", "Settings", "Home"):
        out.extend(build(name, G[name]))
    out.append("}")
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "pages", "desk_icons.plm"), "w") as f:
        f.write("\n".join(out) + "\n")

main()
