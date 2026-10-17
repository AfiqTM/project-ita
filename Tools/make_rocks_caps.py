#!/usr/bin/env python3
"""Builds Fonts/ChineseRocksCaps-Regular.ttf: plain Chinese Rocks Rg with only & ( ) { } redrawn.

Chinese Rocks draws "&" like a plus and "(" ")" "{" "}" like square brackets. This copies the font and redraws
just those six glyphs from Staatliches (SIL OFL), scaled to Chinese Rocks' cap height and widened a little to
match its heavier strokes (the same step 1 as Tools/make_rdr_font.py). Letters and digits are untouched.

    pip install fonttools
    python3 Tools/make_rocks_caps.py
"""
import os
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "source", "ChineseRocksRg-Regular.ttf")
DONOR = os.path.join(HERE, "source", "Staatliches-Regular.ttf")
OUT = os.path.join(HERE, "..", "Fonts", "ChineseRocksCaps-Regular.ttf")
FAMILY, PSNAME = "Chinese Rocks Caps", "ChineseRocksCaps-Regular"

font, donor = TTFont(SRC), TTFont(DONOR)
dcmap, dset = donor.getBestCmap(), donor.getGlyphSet()
cmap_main = font.getBestCmap()
glyf, hmtx = font["glyf"], font["hmtx"]

CAP, BASE = 744, 5
SY = CAP / 696.0
SX = SY * 1.14

for ch in "&(){}":
    name = cmap_main[ord(ch)]
    pen = TTGlyphPen(None)
    dset[dcmap[ord(ch)]].draw(TransformPen(pen, (SX, 0, 0, SY, 0, BASE)))
    glyf[name] = pen.glyph()
    adv = round(donor["hmtx"][dcmap[ord(ch)]][0] * SX)
    glyf[name].recalcBounds(glyf)
    hmtx[name] = (adv, getattr(glyf[name], "xMin", 0))

for rec in font["name"].names:
    if rec.nameID in (1, 16):
        rec.string = FAMILY
    elif rec.nameID == 4:
        rec.string = FAMILY + " Regular"
    elif rec.nameID == 6:
        rec.string = PSNAME
    elif rec.nameID == 3:
        rec.string = PSNAME + "-patched"
if "VDMX" in font:   # a fixed-height table could clip the redrawn glyphs; the kerning of the letters stays
    del font["VDMX"]
font.save(OUT)
print("wrote", OUT)
