#!/usr/bin/env python3
"""Writes the Files app's icons: vitreus-files.svg, Peek (View's cat) as a folder of glass (the one the desktop entry names), and vitreus-files-pencil.svg, the same folder in boiled pencil, the way the shell draws its own icons.

The same folder as files.plm's (a tab at the top left, a line across the front, hatching), larger and finer. Each stroke is drawn three times, each a little
off the last and fainter, as a hand would redraw it; under them a dark pass (so the white lines read on a light background too) and a misregistered mint wash.
Plain paths only (no filters), so every icon theme loader draws it. Run `python3 gen_app_icon.py` to write it again: the drawing is seeded, so it comes out the same.
"""
import math, os, random

rng = random.Random(2026)
here = os.path.dirname(os.path.abspath(__file__))

INK, MINT, DARK = "#eef7f2", "#9ed6bd", "#0e1a15"
S, CX, CY = 4.15, 128.0, 131.0            # the shell's folder is about 52 across: this scales it to the 256 box


def P(x, y):
    return (CX + x * S, CY + y * S)


def rounded(pts, radii):
    """A polyline with its corners rounded (quadratic), `radii` by vertex (0 keeps it sharp). Points in the folder's own units."""
    out = [pts[0]]
    for i in range(1, len(pts) - 1):
        (ax, ay), (bx, by), (cx, cy) = pts[i - 1], pts[i], pts[i + 1]
        r = radii.get(i, 0)
        if r <= 0:
            out.append((bx, by))
            continue
        d1, d2 = math.hypot(ax - bx, ay - by), math.hypot(cx - bx, cy - by)
        t1, t2 = min(r, d1 / 2) / d1, min(r, d2 / 2) / d2
        p1 = (bx + (ax - bx) * t1, by + (ay - by) * t1)
        p2 = (bx + (cx - bx) * t2, by + (cy - by) * t2)
        for k in range(0, 7):
            u = k / 6
            out.append(((1 - u) ** 2 * p1[0] + 2 * u * (1 - u) * bx + u * u * p2[0],
                        (1 - u) ** 2 * p1[1] + 2 * u * (1 - u) * by + u * u * p2[1]))
    out.append(pts[-1])
    return out


def densify(pts, step):
    out = [pts[0]]
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(bx - ax, by - ay) / step))
        for k in range(1, n + 1):
            out.append((ax + (bx - ax) * k / n, ay + (by - ay) * k / n))
    return out


def wobble(pts, amp, dx=0.0, dy=0.0):
    """Moves every point along its normal by a slow noise (two sines of the length so far, new phases each call), and the whole line by dx, dy: a hand's tremble."""
    f1, f2 = rng.uniform(0, 6.3), rng.uniform(0, 6.3)
    g1, g2 = rng.uniform(55, 80), rng.uniform(17, 27)
    out, t = [], 0.0
    for i, (x, y) in enumerate(pts):
        a, b = pts[max(0, i - 1)], pts[min(len(pts) - 1, i + 1)]
        tx, ty = b[0] - a[0], b[1] - a[1]
        n = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / n, tx / n
        if i:
            t += math.hypot(x - pts[i - 1][0], y - pts[i - 1][1])
        k = amp * (0.62 * math.sin(2 * math.pi * t / g1 + f1) + 0.38 * math.sin(2 * math.pi * t / g2 + f2))
        out.append((x + nx * k + dx, y + ny * k + dy))
    return out


def smooth(pts, closed=False):
    """A Catmull-Rom curve through the points, as cubic Beziers."""
    n = len(pts)
    d = "M%.1f %.1f" % pts[0]
    for i in range(n - 1):
        p0 = pts[i - 1] if i else (pts[0] if not closed else pts[-2])
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < n else pts[-1]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += "C%.1f %.1f %.1f %.1f %.1f %.1f" % (c1 + c2 + p2)
    return d + ("Z" if closed else "")


def stroke(pts, width, color, opacity, amp, dx=0.0, dy=0.0, step=6.0):
    q = wobble(densify([P(*p) for p in pts], step), amp, dx, dy)
    return '<path d="%s" stroke="%s" stroke-width="%.2f" stroke-opacity="%.2f"/>' % (smooth(q), color, width, opacity)


def fill(pts, color, opacity, dx=0.0, dy=0.0):
    q = wobble(densify([P(*p) for p in pts], 8.0), 0.9, dx, dy)
    return '<path d="%sZ" fill="%s" fill-opacity="%.2f" stroke="none"/>' % (smooth(q), color, opacity)


def three(pts, width=4.8):
    """One stroke, redrawn: a dark pass under it, then it, then two fainter and thinner ones that wander off it."""
    return [stroke(pts, width * 1.3, DARK, 0.28, 0.7, 1.8, 2.4),
            stroke(pts, width, INK, 0.96, 0.8),
            stroke(pts, width * 0.55, INK, 0.52, 1.5, 0.8, 1.0),
            stroke(pts, width * 0.34, INK, 0.30, 2.0, -0.8, 1.3)]


# the folder: the tab at the top left, the back, the front, as files.plm draws it (units about 52 across, centred on 0, 0)
OUTLINE = [(-26, -11), (-26, -22), (-10, -22), (-4, -15), (26, -15), (26, 22), (-26, 22), (-26, -14), (-26, -8)]
OUTLINE_R = {1: 3.4, 2: 2.2, 3: 2.0, 4: 3.6, 5: 4.4, 6: 4.4}
FRONT = [(-26.4, -5), (26.4, -5.4)]
WASH_BACK = rounded([(-26, -22), (-10, -22), (-4, -15), (26, -15), (26, 22), (-26, 22), (-26, -22)], {1: 2.2, 2: 2.0, 3: 3.6, 4: 4.4, 5: 4.4})
WASH_FRONT = rounded([(-26, -5), (26, -5), (26, 22), (-26, 22), (-26, -5)], {2: 4.4, 3: 4.4})


def hatch():
    out = []
    for i in range(8):
        x = -19 + i * 5.4
        out.append([(x + rng.uniform(-0.5, 0.5), 18.5 + rng.uniform(-0.5, 0.5)), (x + 6.5 + rng.uniform(-0.6, 0.6), 5.5 + rng.uniform(-0.6, 0.6))])
    return out


def main():
    parts = []
    # the wash first, a little off the lines, as a pencil's shading is
    parts.append(fill(WASH_BACK, MINT, 0.20, 2.4, 2.0))
    parts.append(fill(WASH_FRONT, MINT, 0.20, 2.8, 2.4))
    parts.append(fill(WASH_FRONT, INK, 0.07, 1.2, 1.0))
    body = []
    body += three(rounded(OUTLINE, OUTLINE_R))
    body += three(FRONT, 4.6)
    for h in hatch():                                  # the hatching: two fine passes, mint, ending where the hand lifted
        body.append(stroke(h, 3.4, MINT, 0.42, 0.8, 0.4, 0.5, 2.5))
        body.append(stroke(h, 2.0, MINT, 0.30, 1.4, -0.5, 0.2, 2.5))
    # a short bright stroke along the top of the front, where the light falls
    body.append(stroke([(-19, -2.0), (-2, -2.2)], 2.2, INK, 0.45, 0.6))
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" fill="none" '
           'stroke-linecap="round" stroke-linejoin="round">\n  <title>Files</title>\n  ' + "\n  ".join(parts) +
           '\n  <g fill="none">\n    ' + "\n    ".join(body) + '\n  </g>\n</svg>\n')
    with open(os.path.join(here, "vitreus-files-pencil.svg"), "w") as f:
        f.write(svg)
    print("wrote vitreus-files-pencil.svg (%d bytes)" % len(svg))



def glass():
    """Peek as a folder of frosted, smoky glass (neutral greys; only the cat's pink is a colour) (Peek is View's cat, view/view.plm; on the Dashboard it is an envelope, here a folder): a tinted back panel with its
    tab, a paler front one that lets the back show through, a rim that catches the light from the top left, a diagonal sheen and a glow at the foot. The cat:
    ears (pink inside) on the front's top corners, a tail from behind its right side, its paws over the front's lower edge, and on the front a happy face,
    eyes shut in arches, cheeks and a «ω» (no whiskers: drawn as big as it is in a dock, they only blurred). Gradients and clips only (no filters), so every icon loader draws it."""
    back = "M36 64Q36 49 51 49H97Q106 49 111 55L124 71H205Q220 71 220 86V190Q220 205 205 205H51Q36 205 36 190Z"
    front = "M24 104Q24 88 40 88H216Q232 88 232 104V196Q232 214 214 214H42Q24 214 24 196Z"
    ears = ["M30 100L56 32L104 98Z", "M152 98L200 32L226 100Z"]
    inner = ["M45 92L58 54L86 91Z", "M170 91L198 54L211 92Z"]
    tail = "M224 190Q250 204 256 180Q262 158 246 140"
    paws = ""
    for x in (84, 172):
        paws += ('<rect x="%d" y="199" width="44" height="26" rx="13" fill="url(#paw)"/>'
                 '<rect x="%d" y="199" width="44" height="26" rx="13" stroke="#1f2428" stroke-opacity="0.8" stroke-width="6.5"/>'
                 '<path d="M%d 211V219M%d 211V219" stroke="#1f2428" stroke-opacity="0.7" stroke-width="4.5"/>\n  ' % (x - 22, x - 22, x - 7, x + 7))
    face = ""
    for s in (-1, 1):
        ex = 128 + s * 40
        face += ('<path d="M%d 148Q%d 120 %d 148" stroke="#262b30" stroke-width="9"/>'
                 '<ellipse cx="%d" cy="166" rx="17" ry="10" fill="#ff8fc0" fill-opacity="0.6"/>\n  '
                 % (ex - 18, ex, ex + 18, 128 + s * 74))
    svg = """<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" fill="none" stroke-linecap="round" stroke-linejoin="round">
  <title>Files</title>
  <!-- Peek, View's cat, as a folder. Made to sit beside View's icon: the same smoky glass, rim and pink. -->
  <defs>
    <linearGradient id="bk" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#eef1f3" stop-opacity="0.92"/><stop offset="0.55" stop-color="#a7afb6" stop-opacity="0.86"/><stop offset="1" stop-color="#788188" stop-opacity="0.92"/></linearGradient>
    <linearGradient id="bkrim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity="0.85"/><stop offset="0.5" stop-color="#eef1f3" stop-opacity="0.25"/><stop offset="1" stop-color="#ffffff" stop-opacity="0.35"/></linearGradient>
    <linearGradient id="fr" x1="0.1" y1="0" x2="0.8" y2="1"><stop offset="0" stop-color="#fbfcfc" stop-opacity="0.92"/><stop offset="0.45" stop-color="#e6e9ec" stop-opacity="0.78"/><stop offset="1" stop-color="#c3c9ce" stop-opacity="0.72"/></linearGradient>
    <linearGradient id="frrim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity="0.98"/><stop offset="0.35" stop-color="#f2f4f6" stop-opacity="0.5"/><stop offset="0.7" stop-color="#d5dadd" stop-opacity="0.22"/><stop offset="1" stop-color="#ffffff" stop-opacity="0.6"/></linearGradient>
    <linearGradient id="paw" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbfcfc"/><stop offset="1" stop-color="#cfd4d8"/></linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffffff" stop-opacity="0"/><stop offset="0.5" stop-color="#ffffff" stop-opacity="0.34"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>
    <linearGradient id="top" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffffff" stop-opacity="0"/><stop offset="0.18" stop-color="#ffffff" stop-opacity="0.95"/><stop offset="0.75" stop-color="#ffffff" stop-opacity="0.55"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>
    <radialGradient id="glow" cx="0.5" cy="1" r="0.75"><stop offset="0" stop-color="#ffffff" stop-opacity="0.55"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
    <clipPath id="cf"><path d="%(front)s"/></clipPath>
  </defs>
  <g transform="translate(128 128) scale(1.02) translate(-143 -129)">
  <!-- no soft shadow under it: at dock sizes it only blurred the feet -->
  <!-- the tail, from behind its right side, curling up -->
  <path d="%(tail)s" stroke="#1f2428" stroke-opacity="0.85" stroke-width="27"/>
  <path d="%(tail)s" stroke="url(#bk)" stroke-width="19"/>
  <path d="M236 200Q254 204 258 184" stroke="#ffffff" stroke-opacity="0.5" stroke-width="2.2"/>
  <!-- the back, with its tab -->
  <path d="%(back)s" fill="url(#bk)"/>
  <path d="%(back)s" stroke="#1f2428" stroke-opacity="0.8" stroke-width="8"/>
  <path d="%(back)s" stroke="url(#bkrim)" stroke-width="3"/>
  <path d="M43 60Q43 55 49 55H96Q101 55 104 59" stroke="#ffffff" stroke-opacity="0.75" stroke-width="2.2"/>
  <!-- the ears, on the front's top corners, pink inside -->
  <path d="%(e0)s" fill="url(#bk)"/><path d="%(e0)s" stroke="#1f2428" stroke-opacity="0.8" stroke-width="8"/><path d="%(e0)s" stroke="url(#bkrim)" stroke-width="3"/>
  <path d="%(e1)s" fill="url(#bk)"/><path d="%(e1)s" stroke="#1f2428" stroke-opacity="0.8" stroke-width="8"/><path d="%(e1)s" stroke="url(#bkrim)" stroke-width="3"/>
  <path d="%(i0)s" fill="#ff9bb3" fill-opacity="0.7"/><path d="%(i1)s" fill="#ff9bb3" fill-opacity="0.7"/>
  <!-- the front: frosted, the back shows through it -->
  <path d="%(front)s" fill="#20262b" fill-opacity="0.22" transform="translate(0 4)"/>
  <path d="%(front)s" fill="url(#fr)"/>
  <g clip-path="url(#cf)">
    <rect x="0" y="150" width="256" height="80" fill="url(#glow)"/>
    <path d="M-10 230L78 70H122L34 230Z" fill="url(#sheen)"/>
    <path d="M118 230L206 70H226L138 230Z" fill="url(#sheen)" opacity="0.55"/>
  </g>
  <path d="%(front)s" stroke="#1f2428" stroke-opacity="0.8" stroke-width="8"/>
  <path d="%(front)s" stroke="url(#frrim)" stroke-width="2.8"/>
  <path d="M40 94H212" stroke="url(#top)" stroke-width="3.4"/>
  <path d="M36 99Q30 101 30 112V176" stroke="#ffffff" stroke-opacity="0.55" stroke-width="2.2"/>
  <!-- the face: happy, eyes shut in arches, cheeks, a nose and a «ω», bold enough to read at 32 px -->
  %(face)s<path d="M119 155H137L128 165Z" fill="#ff8fab" stroke="#ff8fab" stroke-width="2"/>
  <path d="M112 170Q120 181 128 170Q136 181 144 170" stroke="#262b30" stroke-width="5.5"/>
  <!-- the paws, over the front's lower edge -->
  %(paws)s</g>
</svg>
""" % {"front": front, "back": back, "tail": tail, "e0": ears[0], "e1": ears[1], "i0": inner[0], "i1": inner[1], "face": face, "paws": paws}
    with open(os.path.join(here, "vitreus-files.svg"), "w") as f:
        f.write(svg)
    print("wrote vitreus-files.svg (%d bytes)" % len(svg))


main()
glass()
