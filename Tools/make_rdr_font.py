#!/usr/bin/env python3
"""Builds Fonts/ChineseRocksPlus-Regular.ttf for the Red Dead Redemption 2 theme.

Chinese Rocks (the game's lettering) draws "&" like a plus, "(" ")" "{" "}" like square brackets and has no check
marks, bullets, arrows or shapes. This script copies the font and
  1. redraws & ( ) { } with the matching glyphs of Staatliches (SIL OFL), scaled to Chinese Rocks' cap height and
     widened a little to match its heavier strokes,
  2. adds simple geometric symbols (check marks, circles, squares, triangles, arrows, chevrons, cross) drawn with
     the same stroke weight,
so those characters look like the rest of the text instead of falling back to the system font.

    pip install fonttools
    python3 Tools/make_rdr_font.py            # reads Tools/source, writes Fonts/ChineseRocksPlus-Regular.ttf
"""
import math, os, sys
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source", "ChineseRocksRg-Regular.ttf")
DONOR = os.path.join(HERE, "source", "Staatliches-Regular.ttf")
OUT = os.path.join(HERE, "..", "Fonts", "ChineseRocksPlus-Regular.ttf")
FAMILY, PSNAME = "Chinese Rocks Plus", "ChineseRocksPlus-Regular"

font = TTFont(SRC)
donor = TTFont(DONOR)
dcmap, dset = donor.getBestCmap(), donor.getGlyphSet()
cmap_main = font.getBestCmap()
glyf, hmtx = font["glyf"], font["hmtx"]

# ---- metrics of Chinese Rocks: cap height, stroke weight
CAP = 744                       # top of "H"
STEM = 98                       # stroke weight of the letters
BASE = 5                        # "H" starts 5 units above the baseline

# ---- 1. letters borrowed from Staatliches
SY = CAP / 696.0                # Staatliches caps are 696 tall
SX = SY * 1.14                  # a little wider: Chinese Rocks' strokes are heavier
def borrow(ch):
    name = cmap_main[ord(ch)]
    pen = TTGlyphPen(None)
    tp = TransformPen(pen, (SX, 0, 0, SY, 0, BASE))
    dset[dcmap[ord(ch)]].draw(tp)
    glyf[name] = pen.glyph()
    adv = round(donor["hmtx"][dcmap[ord(ch)]][0] * SX)
    hmtx[name] = (adv, 0)
    glyf[name].recalcBounds(glyf)
    hmtx[name] = (adv, glyf[name].xMin if hasattr(glyf[name], "xMin") else 0)
for ch in "&(){}":
    borrow(ch)

# ---- 2. new geometric glyphs
def poly(pen, pts, ccw=False):
    # TrueType: outer contours clockwise, holes counter-clockwise
    area = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    if (area > 0) != ccw:
        pts = pts[::-1]
    pen.moveTo(pts[0])
    for p in pts[1:]:
        pen.lineTo(p)
    pen.closePath()

def circle(cx, cy, r, n=28):
    return [(round(cx + r * math.cos(2 * math.pi * i / n)), round(cy + r * math.sin(2 * math.pi * i / n))) for i in range(n)]

def seg(a, b, w):   # a thick line segment as a rectangle
    dx, dy = b[0] - a[0], b[1] - a[1]
    l = math.hypot(dx, dy); nx, ny = -dy / l * w / 2, dx / l * w / 2
    return [(round(a[0] + nx), round(a[1] + ny)), (round(b[0] + nx), round(b[1] + ny)),
            (round(b[0] - nx), round(b[1] - ny)), (round(a[0] - nx), round(a[1] - ny))]

def add(code, name, adv, contours):
    pen = TTGlyphPen(None)
    for pts, hole in contours:
        poly(pen, pts, ccw=hole)
    g = pen.glyph()
    glyf[name] = g
    g.recalcBounds(glyf)
    hmtx[name] = (adv, g.xMin)
    order = font.getGlyphOrder()
    if name not in order:
        order.append(name); font.setGlyphOrder(order)
    for t in font["cmap"].tables:
        if t.isUnicode():
            t.cmap[code] = name

W, M = STEM, 0
mid = BASE + CAP / 2
# check marks
add(0x2713, "uni2713", 520, [(seg((40, 330), (180, 190), W), False), (seg((160, 190), (470, 640), W), False)])
add(0x2714, "uni2714", 520, [(seg((40, 330), (180, 190), W * 1.3), False), (seg((160, 190), (470, 640), W * 1.3), False)])
# cross
add(0x2715, "uni2715", 500, [(seg((60, 150), (440, 600), W), False), (seg((60, 600), (440, 150), W), False)])
# circles and squares
add(0x25CF, "uni25CF", 560, [(circle(280, mid, 230), False)])
add(0x25CB, "uni25CB", 560, [(circle(280, mid, 230), False), (circle(280, mid, 230 - W), True)])
add(0x25A0, "uni25A0", 560, [([(50, BASE + 60), (510, BASE + 60), (510, BASE + 520), (50, BASE + 520)], False)])
add(0x25A1, "uni25A1", 560, [([(50, BASE + 60), (510, BASE + 60), (510, BASE + 520), (50, BASE + 520)], False),
                             ([(50 + W, BASE + 60 + W), (510 - W, BASE + 60 + W), (510 - W, BASE + 520 - W), (50 + W, BASE + 520 - W)], True)])
# triangles
add(0x25B2, "uni25B2", 560, [([(50, BASE + 80), (510, BASE + 80), (280, BASE + 540)], False)])
add(0x25BC, "uni25BC", 560, [([(50, BASE + 540), (510, BASE + 540), (280, BASE + 80)], False)])
add(0x25B6, "uni25B6", 520, [([(80, BASE + 40), (80, BASE + 600), (480, BASE + 320)], False)])
add(0x25C0, "uni25C0", 520, [([(440, BASE + 40), (440, BASE + 600), (40, BASE + 320)], False)])
# chevrons
add(0x2039, "uni2039", 360, [(seg((290, 600), (70, mid), W), False), (seg((70, mid), (290, 90), W), False)])
add(0x203A, "uni203A", 360, [(seg((70, 600), (290, mid), W), False), (seg((290, mid), (70, 90), W), False)])
# arrows up / down
add(0x2191, "uni2191", 520, [(seg((260, 60), (260, 640), W), False), (seg((60, 440), (260, 650), W), False),
                             (seg((460, 440), (260, 650), W), False)])
add(0x2193, "uni2193", 520, [(seg((260, 60), (260, 640), W), False), (seg((60, 260), (260, 50), W), False),
                             (seg((460, 260), (260, 50), W), False)])

# ---- names
for rec in font["name"].names:
    if rec.nameID in (1, 16):
        rec.string = FAMILY
    elif rec.nameID == 4:
        rec.string = FAMILY + " Regular"
    elif rec.nameID == 6:
        rec.string = PSNAME
    elif rec.nameID == 3:
        rec.string = PSNAME + "-patched"
if "VDMX" in font:      # per-size height table: could clip the new glyphs
    del font["VDMX"]
font.save(OUT)
print("wrote", os.path.normpath(OUT))
