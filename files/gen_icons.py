#!/usr/bin/env python3
"""Writes the pencil icons of files.plm: PFile (a file's or a folder's picture), PPlace (a sidebar place) and PGlyph (a toolbar button).

Each stroke is drawn twice, a hair off and fainter, and with `a` (hover) the points tremble and are redrawn about five times a second (`fr`), as the shell's own pencil icons do.
The drawings are lists of points in a box about 52 across, centred on 0, 0. Run `python3 gen_icons.py` after changing them: it replaces what lies between the two marker lines of files.plm.
"""
import os, random, math

rng = random.Random(2026)
here = os.path.dirname(os.path.abspath(__file__))
BEGIN = "    // >>> icons (written by gen_icons.py: edit that, not this)"
END = "    // <<< icons"

FOLDER = [(-26, -12), (-26, -22), (-10, -22), (-4, -15), (26, -15), (26, 22), (-26, 22), (-26, -13), (-26, -8)]
F_FRONT = [(-26, -5), (26, -5)]
def hatch(x0=-17, n=5, y0=18, y1=6, step=9, dx=8):
    return [[(x0 + i * step, y0), (x0 + i * step + dx, y1)] for i in range(n)]
PAGE = [(-17, -26), (7, -26), (17, -16), (17, 26), (-17, 26), (-17, -27), (-17, -20)]
FOLD = [(7, -26), (7, -16), (17, -16)]
def page(extra): return [(PAGE, 'ink', 'm'), (FOLD, 'ink', 'm')] + extra
def folder(extra): return [(FOLDER, 'fold', 'm'), (F_FRONT, 'fold', 'm')] + extra

# (points, colour, how): 'm' a stroke drawn twice, 'f' a faint single hatch stroke, 'o' an ellipse (x, y, radius)
FILES = {
    0: folder([(h, 'fold', 'f') for h in hatch()]),
    1: page([([(-11, 17), (-4, 4), (2, 11), (7, 5), (12, 17)], 'mint', 'm'), ((6, -8, 3.2), 'mint', 'o')]),
    2: page([([(-9, -9), (9, -9)], 'ink', 'm'), ([(-9, -2), (9, -2)], 'ink', 'm'), ([(-11, 9), (11, 9), (11, 19), (-11, 19), (-11, 9)], 'alert', 'm')]),
    3: page([([(4, -12), (4, 10)], 'mint', 'm'), ([(4, -12), (11, -8), (11, -4)], 'mint', 'm'), ((-1, 12, 4.2), 'mint', 'o')]),
    4: page([([(-6, -8), (9, 2), (-6, 12), (-6, -8)], 'mint', 'm')]),
    5: page([([(-4, -8), (-11, 1), (-4, 10)], 'mint', 'm'), ([(4, -8), (11, 1), (4, 10)], 'mint', 'm'), ([(1.5, -10), (-1.5, 12)], 'ink', 'm')]),
    6: page([([(0, -23), (0, -19)], 'ink', 'm'), ([(-2.5, -14), (2.5, -14)], 'ink', 'm'), ([(0, -9), (0, -5)], 'ink', 'm'), ([(-2.5, 0), (2.5, 0)], 'ink', 'm'),
             ([(-3.5, 8), (3.5, 8), (3.5, 19), (-3.5, 19), (-3.5, 8)], 'mint', 'm')]),
    7: page([([(-9, -8), (9, -8)], 'ink', 'm'), ([(-9, 0), (9, 0)], 'ink', 'm'), ([(-9, 8), (9, 8)], 'ink', 'm'), ([(-9, 16), (2, 16)], 'ink', 'm')]),
    8: page([([(-10, -6), (-3, 1), (-10, 8)], 'mint', 'm'), ([(0, 10), (10, 10)], 'mint', 'm')]),
    9: page([([(-10, -10), (4, -10)], 'mint', 'm'), ([(-10, -3), (10, -3)], 'ink', 'm'), ([(-10, 4), (10, 4)], 'ink', 'm'), ([(-10, 11), (10, 11)], 'ink', 'm'), ([(-10, 18), (1, 18)], 'ink', 'm')]),
}
PLACES = {
    0: FILES[0],
    1: [([(-22, 0), (0, -21), (22, 0)], 'fold', 'm'), ([(-15, -4), (-15, 21), (15, 21), (15, -4)], 'fold', 'm'), ([(-4, 21), (-4, 9), (4, 9), (4, 21)], 'mint', 'm')],
    2: [([(-15, -14), (15, -14)], 'ink', 'm'), ([(-5, -14), (-5, -21), (5, -21), (5, -14)], 'ink', 'm'), ([(-11, -14), (-9, 22), (9, 22), (11, -14)], 'ink', 'm'),
        ([(-3.5, -6), (-3.5, 16)], 'mint', 'm'), ([(3.5, -6), (3.5, 16)], 'mint', 'm')],
    3: [([(-25, -19), (25, -19), (25, 10), (-25, 10), (-25, -20)], 'ink', 'm'), ([(0, 10), (0, 18)], 'ink', 'm'), ([(-10, 19), (10, 19)], 'ink', 'm')],
    4: folder([([(0, 0), (0, 16)], 'mint', 'm'), ([(-6.5, 9), (0, 16), (6.5, 9)], 'mint', 'm')]),
    5: folder([([(-9, 2), (9, 2)], 'mint', 'm'), ([(-9, 9), (9, 9)], 'mint', 'm'), ([(-9, 16), (2, 16)], 'mint', 'm')]),
    6: folder([([(-12, 18), (-4, 6), (2, 13), (8, 8), (14, 18)], 'mint', 'm'), ((9, 2, 2.6), 'mint', 'o')]),
    7: folder([([(5, 2), (5, 16)], 'mint', 'm'), ([(5, 2), (11, 6)], 'mint', 'm'), ((0, 17, 3.6), 'mint', 'o')]),
    8: folder([([(-5, 2), (9, 10), (-5, 18), (-5, 2)], 'mint', 'm')]),
    9: [([(-25, -8), (25, -8), (25, 16), (-25, 16), (-25, -9)], 'ink', 'm'), ([(-25, 2), (25, 2)], 'ink', 'm'), ((16, 9, 2.2), 'mint', 'o'), ([(-18, 9), (-6, 9)], 'mint', 'm')],
    10: [((0, 0, 21), 'ink', 'o'), ([(0, -12), (0, 0), (10, 6)], 'mint', 'm')],
    11: [([(0, -22), (6, -7), (22, -6), (10, 4), (14, 20), (0, 11), (-14, 20), (-10, 4), (-22, -6), (-6, -7), (0, -22)], 'mint', 'm')],
    12: [([(-25, -19), (25, -19), (25, 10), (-25, 10), (-25, -20)], 'ink', 'm'), ([(-25, -10), (25, -10)], 'ink', 'm'), ([(-8, 18), (8, 18)], 'ink', 'm'), ([(0, 10), (0, 18)], 'ink', 'm')],
    13: [((0, 0, 21), 'ink', 'o'), ([(-21, 0), (21, 0)], 'mint', 'm'), ([(0, -21), (-10, -8), (-10, 8), (0, 21)], 'mint', 'm'), ([(0, -21), (10, -8), (10, 8), (0, 21)], 'mint', 'm')],
    14: [([(-22, -6), (22, -6), (22, 12), (-22, 12), (-22, -7)], 'ink', 'm'), ([(-14, 0), (-6, 0)], 'mint', 'm'), ((14, 3, 2.2), 'mint', 'o'), ([(-22, -6), (-14, -18), (14, -18), (22, -6)], 'ink', 'm')],
    15: [((0, 0, 21), 'ink', 'o'), ([(-9, 0), (9, 0)], 'mint', 'm'), ([(0, -9), (0, 9)], 'mint', 'm')],
    16: [((0, 0, 21), 'ink', 'o'), ((0, 0, 5), 'mint', 'o'), ([(-14, -14), (-9, -17)], 'ink', 'm')],
}
# toolbar and menu glyphs, in a box about 24 across
GLYPHS = {
    0: [([(6, -9), (-5, 0), (6, 9)], 'btn', 'm')],
    1: [([(-6, -9), (5, 0), (-6, 9)], 'btn', 'm')],
    2: [([(-9, 5), (0, -6), (9, 5)], 'btn', 'm')],
    3: [([(-10, -10), (-2, -10), (-2, -2), (-10, -2), (-10, -11)], 'btn', 'm'), ([(2, -10), (10, -10), (10, -2), (2, -2), (2, -11)], 'btn', 'm'),
        ([(-10, 2), (-2, 2), (-2, 10), (-10, 10), (-10, 1)], 'btn', 'm'), ([(2, 2), (10, 2), (10, 10), (2, 10), (2, 1)], 'btn', 'm')],
    4: [([(-3, -7), (10, -7)], 'btn', 'm'), ([(-3, 0), (10, 0)], 'btn', 'm'), ([(-3, 7), (10, 7)], 'btn', 'm'),
        ((-9, -7, 1.3), 'btn', 'o'), ((-9, 0, 1.3), 'btn', 'o'), ((-9, 7, 1.3), 'btn', 'o')],
    5: [([(-11, 0), (-6, -5), (0, -7), (6, -5), (11, 0), (6, 5), (0, 7), (-6, 5), (-11, 0)], 'btn', 'm'), ((0, 0, 3), 'btn', 'o')],
    6: [([(-11, -5), (-11, -9), (-4, -9), (-1, -6), (11, -6), (11, 8), (-11, 8), (-11, -4)], 'btn', 'm'), ([(-3, 2), (3, 2)], 'btn', 'm'), ([(0, -1), (0, 5)], 'btn', 'm')],
    7: [([(-6, -6), (6, 6)], 'btn', 'm'), ([(6, -6), (-6, 6)], 'btn', 'm')],
    8: [([(-4, -9), (-9, -9), (-9, 9), (9, 9), (9, 4)], 'btn', 'm'), ([(0, 0), (10, -10)], 'btn', 'm'), ([(3, -10), (10, -10), (10, -3)], 'btn', 'm')],
    9: [([(-10, 10), (-8, 4), (5, -9), (9, -5), (-4, 8), (-10, 10)], 'btn', 'm'), ([(2, -6), (6, -2)], 'btn', 'm')],
    10: [([(-3, -3), (-3, -9), (9, -9), (9, 3), (3, 3)], 'btn', 'm'), ([(-9, -3), (3, -3), (3, 9), (-9, 9), (-9, -4)], 'btn', 'm')],
    11: [((-5, 7, 3.2), 'btn', 'o'), ((5, 7, 3.2), 'btn', 'o'), ([(-5, 4), (4, -10)], 'btn', 'm'), ([(5, 4), (-4, -10)], 'btn', 'm')],
    12: [([(-8, -5), (-8, 10), (8, 10), (8, -5), (4, -5)], 'btn', 'm'), ([(-4, -9), (4, -9), (4, -3), (-4, -3), (-4, -9)], 'btn', 'm'), ([(-4, 2), (4, 2)], 'btn', 'm'), ([(-4, 6), (2, 6)], 'btn', 'm')],
    13: [([(-9, -6), (9, -6)], 'btn', 'm'), ([(-3, -6), (-3, -10), (3, -10), (3, -6)], 'btn', 'm'), ([(-7, -6), (-6, 10), (6, 10), (7, -6)], 'btn', 'm'), ([(-2.5, -2), (-2.5, 6)], 'btn', 'm'), ([(2.5, -2), (2.5, 6)], 'btn', 'm')],
    14: [([(-10, -4), (-10, -10), (-4, -10)], 'btn', 'm'), ([(4, -10), (10, -10), (10, -4)], 'btn', 'm'), ([(10, 4), (10, 10), (4, 10)], 'btn', 'm'), ([(-4, 10), (-10, 10), (-10, 4)], 'btn', 'm'), ([(-4, 0), (-1, 4), (5, -4)], 'btn', 'm')],
    15: [([(5.1, -6.1), (7.5, -2.7), (7.9, 1.4), (6.1, 5.1), (2.7, 7.5), (-1.4, 7.9), (-5.1, 6.1), (-7.5, 2.7), (-7.9, -1.4), (-6.1, -5.1), (-2.7, -7.5)], 'btn', 'm'), ([(-2.7, -7.5), (-7.7, -8.5), (-4.7, -2.5)], 'btn', 'm')],
    16: [((0, 0, 10.5), 'btn', 'o'), ([(0, -5), (0, -4)], 'btn', 'm'), ([(0, -0.5), (0, 6)], 'btn', 'm')],
    17: [([(-11, -8), (11, -8), (11, 9), (-11, 9), (-11, -9)], 'btn', 'm'), ([(-7, -3), (-3, 0), (-7, 3)], 'btn', 'm'), ([(0, 4), (6, 4)], 'btn', 'm')],
    18: [([(-11, -5), (-11, 8), (11, 8), (11, -5)], 'btn', 'm'), ([(-11, -5), (-5, -5), (-3, -9), (5, -9), (7, -5), (11, -5)], 'btn', 'm'), ([(0, -1), (0, 5)], 'btn', 'm'), ([(-3, 2), (3, 2)], 'btn', 'm')],
    19: [([(-11, -7), (5, -7), (5, 5), (-11, 5), (-11, -8)], 'btn', 'm'), ([(-5, 9), (11, 9), (11, -3)], 'btn', 'm')],
    20: [([(-9, -4), (-3, -9)], 'btn', 'm'), ([(-9, -4), (-3, 1)], 'btn', 'm'), ([(-9, -4), (2, -4), (9, -1), (10, 5), (5, 9), (-2, 9)], 'btn', 'm')],
    21: [([(-3, 3), (-9, 3), (-11, 0), (-9, -3), (-3, -3)], 'btn', 'm'), ([(3, -3), (9, -3), (11, 0), (9, 3), (3, 3)], 'btn', 'm'), ([(-5, 0), (5, 0)], 'btn', 'm')],
    22: [([(-9, -10), (9, -10), (9, 10), (-9, 10), (-9, -11)], 'btn', 'm'), ([(0, -10), (0, -5)], 'btn', 'm'), ([(-2, -3), (2, -3)], 'btn', 'm'), ([(0, 0), (0, 3)], 'btn', 'm'), ([(-3, 5), (3, 5), (3, 10), (-3, 10), (-3, 5)], 'btn', 'm')],
    23: [([(-9, -3), (-9, 10), (9, 10), (9, -3)], 'btn', 'm'), ([(0, 4), (0, -10)], 'btn', 'm'), ([(-5, -6), (0, -11), (5, -6)], 'btn', 'm')],
    24: [([(0, -10), (3, -3), (10, -3), (4, 2), (7, 9), (0, 5), (-7, 9), (-4, 2), (-10, -3), (-3, -3), (0, -10)], 'btn', 'm')],
    25: [([(-9, -5), (-9, 9), (9, 9), (9, -5)], 'btn', 'm'), ([(0, 4), (0, -10)], 'btn', 'm'), ([(-5, -5), (0, -10), (5, -5)], 'btn', 'm'), ([(-9, -5), (-5, -5)], 'btn', 'm')],
    26: [([(-6, -9), (-9, -9), (-9, 9), (-6, 9)], 'btn', 'm'), ([(6, -9), (9, -9), (9, 9), (6, 9)], 'btn', 'm'), ([(3, -6), (-3, 6)], 'btn', 'm')],
    27: [([(-6, -2), (-6, -9), (7, -9), (7, 4), (0, 4)], 'btn', 'm'), ([(-11, -2), (0, -2), (0, 10), (-11, 10), (-11, -3)], 'btn', 'm'), ([(-8, 3), (-3, 3)], 'btn', 'm')],
    28: [([(-7, -11), (3, -11), (8, -6), (8, 11), (-7, 11), (-7, -12)], 'btn', 'm'), ([(3, -11), (3, -6), (8, -6)], 'btn', 'm'), ([(-2, 0), (-2, 7)], 'btn', 'm'), ([(-5.5, 3.5), (1.5, 3.5)], 'btn', 'm')],
    29: [([(-11, -7), (11, -7), (11, 8), (-11, 8), (-11, -8)], 'btn', 'm'), ([(-7, 5), (-2, -1), (1, 3), (4, -1), (8, 5)], 'btn', 'm'), ((5, -3, 1.5), 'btn', 'o')],
    30: [([(-4, -4), (-4, -10), (10, -10), (10, 4), (4, 4)], 'btn', 'm'), ([(-10, -4), (4, -4), (4, 10), (-10, 10), (-10, -5)], 'btn', 'm')],
    31: [([(-8, -7), (0, -7)], 'btn', 'm'), ([(-8, 0), (4, 0)], 'btn', 'm'), ([(-8, 7), (8, 7)], 'btn', 'm'), ([(7, -9), (7, 1)], 'btn', 'm'), ([(4, -3), (7, 1), (10, -3)], 'btn', 'm')],
    32: [([(-9, 0), (9, 0)], 'btn', 'm'), ([(0, -9), (0, 9)], 'btn', 'm')],
    33: [([(-9, 0), (9, 0)], 'btn', 'm')],
    34: [([(-9, 6), (9, 6), (0, -7), (-9, 6)], 'btn', 'm'), ([(-9, 10), (9, 10)], 'btn', 'm')],
    35: [([(-9, 0), (-3, 7), (9, -8)], 'btn', 'm')],
    36: [([(-6, -9), (8, -9), (8, 10), (0, 4), (-6, 10), (-6, -10)], 'btn', 'm')],
    37: [((0, 0, 10), 'btn', 'o'), ([(-10, 0), (10, 0)], 'btn', 'm'), ([(0, -10), (-5, -4), (-5, 4), (0, 10)], 'btn', 'm'), ([(0, -10), (5, -4), (5, 4), (0, 10)], 'btn', 'm')],
    38: [([(-10, -6), (-5, -6)], 'btn', 'm'), ([(-5, -6), (-5, 5)], 'btn', 'm'), ([(-5, 5), (10, 5)], 'btn', 'm'), ([(10, 5), (10, -6)], 'btn', 'm'), ([(-10, 9), (-5, 9)], 'btn', 'm')],
    39: [([(-11, 0), (-7, -4), (-3, 0), (-7, 4), (-11, 0)], 'btn', 'm'), ([(-3, 0), (11, 0)], 'btn', 'm'), ([(7, -4), (11, 0), (7, 4)], 'btn', 'm')],
    40: [([(-10, -4), (-4, -10), (4, -10), (10, -4), (10, 4), (4, 10), (-4, 10), (-10, 4), (-10, -4)], 'btn', 'm'), ([(-3, -3), (3, 3)], 'btn', 'm'), ([(3, -3), (-3, 3)], 'btn', 'm')],
}

# ── the tiles' pictures (PFile), drawn finer: round corners, a soft tone inside, and more of what each thing is ──
# A point is (x, y), or (x, y, cx, cy): a curve to x, y round the corner cx, cy. How: 'm' a stroke drawn twice, 't' one thin stroke, 'f' a faint hatch stroke, 'o' a ring (x, y, radius),
# ('F', opacity) a closed shape filled faintly, ('O', opacity) a disc.
def rnd(pts, r, closed=False):
    """The same line with its corners rounded (radius r); closed, every corner, and it ends a little past where it began, as a hand does."""
    n = len(pts)
    def toward(a, b, d):
        l = math.hypot(b[0] - a[0], b[1] - a[1])
        d = min(d, l / 2)
        return (a[0] + (b[0] - a[0]) * d / l, a[1] + (b[1] - a[1]) * d / l)
    out = []
    idx = range(n) if closed else range(1, n - 1)
    if not closed:
        out.append(pts[0])
    for i in idx:
        a, v, b = pts[i - 1], pts[i], pts[(i + 1) % n]
        p, q = toward(v, a, r), toward(v, b, r)
        out.append(p)
        out.append((q[0], q[1], v[0], v[1]))
    if closed:
        out.append(out[0])
        out.append(toward(out[0], (out[1][0], out[1][1]), 2.5))
    else:
        out.append(pts[-1])
    return out
def rect(x0, y0, x1, y1, r): return rnd([(x0, y1), (x0, y0), (x1, y0), (x1, y1)], r, True)
def inside(pts): return pts[:-2]                # a closed outline without its last stretch (back to the start and a little past it): what is filled

N_BACK = rnd([(-26, -3), (-26, -22), (-9, -22), (-4, -16), (26, -16), (26, -3)], 3.5)
N_FRONT = rect(-26, -6, 26, 22, 4.5)
N_FOLDER = [
    (N_BACK, 'fold', 'm'),
    (rnd([(-20, -7), (-20, -12), (20, -12), (20, -7)], 1.5), 'ink', 't'),             # a sheet showing over the front
    ([(-17, -9), (17, -9)], 'ink', 'f'),
    (inside(N_FRONT), 'fold', ('F', 0.13)),
    (N_FRONT, 'fold', 'm'),
    ([(-19, 1), (-8, 1)], 'fold', 't'),                                                 # its label
    ([(-19, 5), (-13, 5)], 'fold', 'f'),
] + [([(x, 18), (x + 5 + k, 12 - 2 * k)], 'fold', 'f') for k, x in enumerate([2, 7, 12, 17])]   # the shade in its corner
N_PAGE = rnd([(7, -26), (-17, -26), (-17, 26), (17, 26), (17, -16)], 3) + [(7, -26), (4, -26)]
N_FOLD = rnd([(7, -26), (7, -16), (17, -16)], 2.5)
def npage(extra):
    return [(N_PAGE[:-1], 'ink', ('F', 0.06)), ([(7, -26), (7, -16), (17, -16)], 'ink', ('F', 0.16)), (N_PAGE, 'ink', 'm'), (N_FOLD, 'ink', 'm')] + extra
N_SHARE = 4
HILLS = [(-11, 14), (-5, 4), (-1, 9), (4, 1), (11, 14)]
N_FILES = {
    0: N_FOLDER,
    # a picture: framed, hills and a sun
    1: npage([(rect(-12, -9, 12, 17, 2), 'mint', 'm'), (HILLS, 'mint', ('F', 0.22)), (HILLS, 'mint', 't'), ((-6, -3, 2.3), 'mint', ('O', 0.3)), ((-6, -3, 2.3), 'mint', 'o')]),
    # a PDF: some lines and its red band, lettered
    2: npage([([(-10, -10), (1, -10)], 'ink', 'm'), ([(-10, -4), (10, -4)], 'ink', 't'), ([(-10, 2), (6, 2)], 'ink', 't'),
              (inside(rect(-13, 8, 13, 21, 2.5)), 'alert', ('F', 0.2)), (rect(-13, 8, 13, 21, 2.5), 'alert', 'm'),
              ([(-9, 18.5), (-9, 10.5), (-6, 10.5), (-4.6, 12.5), (-6, 14.5), (-9, 14.5)], 'alert', 't'),
              ([(-1.8, 10.5), (-1.8, 18.5), (0.6, 18.5), (2.6, 16.2), (2.6, 12.8), (0.6, 10.5), (-1.8, 10.5)], 'alert', 't'),
              ([(9.4, 10.5), (5.8, 10.5), (5.8, 18.5)], 'alert', 't'), ([(5.8, 14.5), (8.4, 14.5)], 'alert', 't')]),
    # a sound: two notes under a double beam
    3: npage([([(-5, 13), (-5, -9), (9, -12), (9, 10)], 'mint', 'm'), ([(-5, -4.5), (9, -7.5)], 'mint', 'm'),
              ((-8.4, 13, 3.6), 'mint', ('O', 0.35)), ((-8.4, 13, 3.6), 'mint', 'o'), ((5.6, 10, 3.6), 'mint', ('O', 0.35)), ((5.6, 10, 3.6), 'mint', 'o')]),
    # a video: a strip of film, and play
    4: npage([(rect(-13, -10, 13, 18, 2), 'ink', 'm'), ([(-13, -5), (13, -5)], 'ink', 't'), ([(-13, 13), (13, 13)], 'ink', 't'),
              ([(-7.8, -10), (-7.8, -5)], 'ink', 't'), ([(-2.6, -10), (-2.6, -5)], 'ink', 't'), ([(2.6, -10), (2.6, -5)], 'ink', 't'), ([(7.8, -10), (7.8, -5)], 'ink', 't'),
              ([(-7.8, 13), (-7.8, 18)], 'ink', 't'), ([(-2.6, 13), (-2.6, 18)], 'ink', 't'), ([(2.6, 13), (2.6, 18)], 'ink', 't'), ([(7.8, 13), (7.8, 18)], 'ink', 't'),
              ([(-3.5, -1), (4.5, 4), (-3.5, 9)], 'mint', ('F', 0.3)), ([(-3.5, -1), (4.5, 4), (-3.5, 9), (-3.5, -1), (-1.5, 0.2)], 'mint', 'm')]),
    # code: its brackets, and a line under them
    5: npage([([(-4, -8), (-11, 1), (-4, 10)], 'mint', 'm'), ([(4, -8), (11, 1), (4, 10)], 'mint', 'm'), ([(2, -10), (-2, 12)], 'ink', 'm'),
              ([(-10, 17), (4, 17)], 'ink', 't'), ([(-10, 21), (-3, 21)], 'ink', 'f')]),
    # an archive: a zip down the page, and its pull
    6: npage([([(-3, -23), (0, -23), (0, -19), (3, -19), (0, -19), (0, -15), (-3, -15), (0, -15), (0, -11), (3, -11), (0, -11), (0, -7), (-3, -7), (0, -7), (0, -3), (3, -3), (0, -3), (0, 1), (-3, 1), (0, 1), (0, 5)], 'ink', 't'),
              (inside(rect(-4.5, 5, 4.5, 19, 2.5)), 'mint', ('F', 0.25)), (rect(-4.5, 5, 4.5, 19, 2.5), 'mint', 'm'), ([(0, 10), (0, 14.5)], 'mint', 't')]),
    # any other file: what is written on it
    7: npage([([(-10, -9), (10, -9)], 'ink', 't'), ([(-10, -3), (10, -3)], 'ink', 't'), ([(-10, 3), (7, 3)], 'ink', 't'), ([(-10, 9), (10, 9)], 'ink', 't'), ([(-10, 15), (10, 15)], 'ink', 't'), ([(-10, 21), (-1, 21)], 'ink', 't')]),
    # a script: a prompt, what was typed, and what it said
    8: npage([([(-10, -8), (-4, -2), (-10, 4)], 'mint', 'm'), ([(0, 5), (10, 5)], 'mint', 'm'), ([(-10, 12), (7, 12)], 'ink', 't'), ([(-10, 18), (1, 18)], 'ink', 't')]),
    # a document: a heading, and its paragraphs
    9: npage([([(-10, -10), (4, -10)], 'mint', 'm'), ([(-10, -4), (10, -4)], 'ink', 't'), ([(-10, 1), (10, 1)], 'ink', 't'), ([(-10, 6), (5, 6)], 'ink', 't'),
              ([(-10, 14), (10, 14)], 'ink', 't'), ([(-10, 19), (0, 19)], 'ink', 't')]),
}
COL = {'ink': 'ink', 'mint': 'mint', 'alert': 'alert', 'fold': 'mix(mint, ink, 0.25)', 'btn': 'mix(ink, mint, a)'}

trng = random.Random(99)       # the tremble of a hovered drawing has numbers of its own, so the ones above (what is drawn at rest) stay what they were

def jt(x, y):
    """A point at rest: the hand-drawn wobble is a fixed number (what `j * sin(fr * f + p)` is with `fr` 0, as it is at rest), written into the point, so the scene does not work out two sines for every
    point of every drawing in every copy of it. `j` is 0.3 * (0.5 + s): so x * s + j * sin(p) is (x + 0.3 sin(p)) * s + 0.15 sin(p)."""
    f1, p1, f2, p2 = rng.randint(40, 76), rng.randint(100, 5000), rng.randint(40, 76), rng.randint(100, 5000)
    sx, sy = math.sin(p1), math.sin(p2)
    return f"{x + 0.3 * sx:.2f} * s + {0.15 * sx:.2f}", f"{y + 0.3 * sy:.2f} * s + {0.15 * sy:.2f}"

def tremble(boil):
    """While the pointer is on it a drawing's strokes shake and are redrawn about five times a second (`fr`): each stroke as a whole, by a different amount (`jb`), not every point of it."""
    if not boil:
        return "", ""
    return (f" + jb * sin(fr * {trng.randint(40, 76)} + {trng.randint(100, 5000)})", f" + jb * sin(fr * {trng.randint(40, 76)} + {trng.randint(100, 5000)})")

def strokes(items, boil):
    out = []
    for pts, col, how in items:
        c = COL[col]
        if isinstance(how, tuple) and how[0] == 'O':
            x, y, r = pts
            jx, jy = jt(x, y)
            tx, ty = tremble(boil)
            out.append(f"            ellipse {{ at: cx + {jx}{tx}, cy + {jy}{ty}; radius: {r} * s; color: {c}; opacity: (o) * {how[1]} }}")
            continue
        if how == 'o':
            x, y, r = pts
            jx, jy = jt(x, y)
            rr = r * (1 + 0.05 * math.sin(rng.randint(1000, 2000)))
            tx, ty = tremble(boil)
            out.append(f"            ellipse {{ at: cx + {jx}{tx}, cy + {jy}{ty}; radius: {rr:.2f} * s; stroke: w1; color: {c}; opacity: (o) }}")
            jx, jy = jt(x, y)
            tx, ty = tremble(boil)
            out.append(f"            ellipse {{ at: cx + {jx} + off{tx}, cy + {jy} + off{ty}; radius: {r} * s; stroke: w2; color: {c}; opacity: (o) * 0.28 }}")
            continue
        for second in ([False, True] if how == 'm' else [False]):
            steps = []
            for k, pt in enumerate(pts):
                jx, jy = jt(pt[0], pt[1])
                if len(pt) == 4:
                    vx, vy = jt(pt[2], pt[3])
                    steps.append(f"curve {jx}, {jy} via {vx}, {vy}")
                else:
                    steps.append(("move " if k == 0 else "line ") + f"{jx}, {jy}")
            tx, ty = tremble(boil)
            if isinstance(how, tuple):
                out.append(f"            path {{ at: cx{tx}, cy{ty}; color: {c}; opacity: (o) * {how[1]}; " + "; ".join(steps) + "; close }")
            elif how == 't':
                out.append(f"            path {{ at: cx{tx}, cy{ty}; stroke: w2; color: {c}; opacity: (o) * 0.85; " + "; ".join(steps) + " }")
            elif how == 'f':
                out.append(f"            path {{ at: cx{tx}, cy{ty}; stroke: w2; color: {c}; opacity: (o) * 0.24; " + "; ".join(steps) + " }")
            elif not second:
                out.append(f"            path {{ at: cx{tx}, cy{ty}; stroke: w1; color: {c}; opacity: (o); " + "; ".join(steps) + " }")
            else:
                out.append(f"            path {{ at: cx + off{tx}, cy + off{ty}; stroke: w2; color: {c}; opacity: (o) * 0.28; " + "; ".join(steps) + " }")
    return out

def comp(name, doc, param, table, boil, share=0, share_lines=False):
    # `share`: how many leading drawings every kind but 0 has in common (a file's page and its folded corner). They are written once, for all of them, and not again for each kind: the scene
    # takes longer to load for every copy, and Files opens in a window of its own each time. The random numbers are still drawn as before, so what is drawn does not change.
    body = []
    shared = None
    for k, items in table.items():
        lines = strokes(items, boil)
        if share and k >= 1:
            n = len(strokes(items[:share], boil)) if share_lines else 2 * share      # a drawing is two lines (the stroke and its fainter copy), unless it is a fill or a thin one
            if shared is None:
                shared = lines[:n]
            lines = lines[n:]
        body.append(f"            group {{\n                show: {param} == {k}")
        body += ["    " + x for x in lines]
        body.append("            }")
    if shared:
        body[0:0] = [f"            group {{\n                show: {param} >= 1"] + ["    " + x for x in shared] + ["            }"]
    head = f"    component {name}(cx: number, cy: number, s: number, {param}: number, " + ("hot: number, " if boil else "") + "o: number) {\n"
    if boil:
        head += "        prop a = 0 ~calm\n        follow a = hot\n        let fr = if(a > 0.02, floor(time * 5), 0)\n"
        head += "        let jb = 0.7 * a * (0.5 + s)\n"
    else:
        head += "        let a = 0\n"        # the pictures' colour (`mix(ink, mint, a)`): how far it is turned to the accent
    head += "        let w1 = 1.3 + 1.1 * s\n        let w2 = 0.9 + 0.6 * s\n        let off = 0.35 * (0.5 + s)\n"
    head += "        group {\n            pivot: cx, cy\n" + ("            scale: 1 + 0.08 * a\n" if boil else "")
    return "    //  " + doc + "\n" + head + "\n".join(body) + "\n        }\n    }\n"

FIXED = [7, 32, 33, 34, 35, 36, 39]            # the kinds `PGlyphS` is called with as a literal in files.plm; the others (a menu line's `m.ic`, a pick's `k.ic`) are chosen while it runs
block = BEGIN + "\n"
_ = comp("PFile", "A file's or a folder's picture in pencil: a folder, a picture, a PDF, a sound, a video, code, an archive or any other file (`ik`, which the logic sets). `s` is its size (1 is 64 px); `hot` (hover) swells it and redraws it about five times a second. The folder takes the accent and the files the ink, so any palette is theirs.", "ik", FILES, True, share=2) + "\n"       # (drawn, not written: the places' and the glyphs' random numbers stay what they were)
_keep = (rng, trng)
rng, trng = random.Random(4051), random.Random(4052)       # the tiles' new pictures have numbers of their own
block += comp("PFile", "A file's or a folder's picture in pencil: a folder, a picture, a PDF, a sound, a video, code, an archive or any other file (`ik`, which the logic sets). `s` is its size (1 is 64 px); `hot` (hover) swells it and redraws it about five times a second. The folder takes the accent and the files the ink, so any palette is theirs.", "ik", N_FILES, True, N_SHARE, True) + "\n"
PFILE0 = comp("PFile0", "`PFile` for a folder alone (the sidebar's pinned-folder marker).", "ik", {0: N_FILES[0]}, True)
rng, trng = _keep
block += comp("PPlace", "A place's picture in pencil for the sidebar (`pk`): a folder, home, the trash, this computer, downloads, documents, pictures, music, videos, a drive. Still, and a little crooked.", "pk", PLACES, False) + "\n"
# (drawn so that the random numbers of the pictures after it stay what they were, but not written: every call site has a table of its own, below)
_ = comp("PGlyphS", "The same pictures, still (no trembling): for the menus, where a copy of the boiling one for every line would be a long scene to load.", "g", GLYPHS, False)
block += comp("PGlyph", "A toolbar or menu picture (`g`): back, forward, up, tiles, lines, hidden files, new folder, close, then the menu's own. `hot` swells it, turns it to the accent and redraws it, like the shell's own.", "g", {k: GLYPHS[k] for k in range(8)}, True)   # only the eight the toolbar draws (`repeat i in 0..8`): every copy carries all its kinds, so a longer table is a longer scene
# The still pictures that are always the same one (`PGlyphS7(...)`, a literal kind at the call site) are a component each, so that the call carries one drawing and not all of them.
# The pictures chosen while it runs carry only the kinds that can come up: a menu line's (`menu_row`, `add` in files.luau) and a pick's (`ic = ...` in the lists of apps and archive types).
MENU = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 36]
PICK = [8, 22, 28, 30]
block += "\n" + comp("PGlyphSM", "`PGlyphS` for a menu line's picture, which is chosen while it runs: only the kinds the menus use.", "g", {k: GLYPHS[k] for k in MENU}, False)
block += "\n" + comp("PGlyphSP", "`PGlyphS` for a pick list's picture (apps, archive types): only the kinds those lists use.", "g", {k: GLYPHS[k] for k in PICK}, False)
_ = comp("PFile0", "", "ik", {0: FILES[0]}, True)
block += "\n" + PFILE0
for k in FIXED:
    block += "\n" + comp(f"PGlyphS{k}", f"`PGlyphS` for kind {k} alone.", "g", {k: GLYPHS[k]}, False)
block += END + "\n"

path = os.path.join(here, "files.plm")
src = open(path).read()
a, b = src.index(BEGIN), src.index(END) + len(END) + 1
open(path, "w").write(src[:a] + block + src[b:])
print("icons written:", len(block), "bytes")
