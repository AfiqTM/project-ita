#!/usr/bin/env python3
"""Builds Fonts/RoyalKnight-Regular.ttf for the Vintage theme.

The Royal Knight demo file (Almarkha Studio, "personal use only") draws its watermark logo in place of
"!", "#" and "$". Those three glyphs are redrawn here from Courier Prime Bold (SIL OFL, the theme's body
font), scaled to Royal Knight's capital height, so they show as real symbols. Everything else is untouched.

    python3 Tools/make_royal_knight.py
Needs fontTools (pip install fonttools).
"""
import os
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.transformPen import TransformPen

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = TTFont(os.path.join(root, "Tools/source/RoyalKnight-Regular-original.ttf"))
sym = TTFont(os.path.join(root, "Fonts/CourierPrime-Bold.ttf"))

scale = 740 / 1187          # Courier Prime capital height -> Royal Knight capital height
sym_cmap, src_cmap = sym.getBestCmap(), src.getBestCmap()
sym_gs = sym.getGlyphSet()

for ch in "!#$":
    s_name, d_name = sym_cmap[ord(ch)], src_cmap[ord(ch)]
    pen = TTGlyphPen(None)
    sym_gs[s_name].draw(TransformPen(pen, (scale, 0, 0, scale, 0, 0)))
    glyph = pen.glyph()
    adv = round(sym["hmtx"][s_name][0] * scale)
    src["glyf"][d_name] = glyph
    glyph.recalcBounds(src["glyf"])
    src["hmtx"][d_name] = (adv, glyph.xMin if hasattr(glyph, "xMin") else 0)

src.save(os.path.join(root, "Fonts/RoyalKnight-Regular.ttf"))
print("wrote Fonts/RoyalKnight-Regular.ttf")
