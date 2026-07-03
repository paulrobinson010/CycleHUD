# -*- coding: utf-8 -*-
# Generates CycleHUD7Seg.ttf — an original 7-segment "digital clock" display
# font (digits, separators and dashes only; everything else falls back to the
# system font). Authored from scratch for CycleHUD, no third-party outlines.
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPM = 1000
T = 120          # segment thickness (bolder LCD weight)
GAP = 14          # gap between segments at junctions
X0, X1 = 40, 600  # digit body horizontal extent
Y0, Y1 = 0, 720   # digit body vertical extent
MID = (Y0 + Y1) // 2
ADV = 660         # monospaced digit advance

def h_seg(xl, xr, yc):
    """Horizontal hexagonal segment from xl..xr centred on yc."""
    h = T / 2
    return [(xl, yc), (xl + h, yc + h), (xr - h, yc + h),
            (xr, yc), (xr - h, yc - h), (xl + h, yc - h)]

def v_seg(xc, yb, yt):
    """Vertical hexagonal segment from yb..yt centred on xc."""
    h = T / 2
    return [(xc, yb), (xc + h, yb + h), (xc + h, yt - h),
            (xc, yt), (xc - h, yt - h), (xc - h, yb + h)]

# Segment centrelines, pulled in by GAP at each junction so segments read
# separately (the classic LCD look).
SEGS = {
    "a": h_seg(X0 + T/2 + GAP, X1 - T/2 - GAP, Y1 - T/2),
    "g": h_seg(X0 + T/2 + GAP, X1 - T/2 - GAP, MID),
    "d": h_seg(X0 + T/2 + GAP, X1 - T/2 - GAP, Y0 + T/2),
    "f": v_seg(X0 + T/2, MID + GAP, Y1 - T/2 - GAP + T/2 - GAP),
    "b": v_seg(X1 - T/2, MID + GAP, Y1 - T/2 - GAP + T/2 - GAP),
    "e": v_seg(X0 + T/2, Y0 + T/2 + GAP - T/2 + GAP, MID - GAP),
    "c": v_seg(X1 - T/2, Y0 + T/2 + GAP - T/2 + GAP, MID - GAP),
}
# tidy vertical extents: from just past the horizontal segments to the middle
SEGS["f"] = v_seg(X0 + T/2, MID + GAP, Y1 - T/2 - GAP)
SEGS["b"] = v_seg(X1 - T/2, MID + GAP, Y1 - T/2 - GAP)
SEGS["e"] = v_seg(X0 + T/2, Y0 + T/2 + GAP, MID - GAP)
SEGS["c"] = v_seg(X1 - T/2, Y0 + T/2 + GAP, MID - GAP)

DIGITS = {
    "zero": "abcdef", "one": "bc", "two": "abged", "three": "abgcd",
    "four": "fgbc", "five": "afgcd", "six": "afgedc", "seven": "abc",
    "eight": "abcdefg", "nine": "abcdfg",
}

def draw(contours, glyphSet=None):
    pen = TTGlyphPen(glyphSet)
    for pts in contours:
        pen.moveTo(pts[0])
        for p in pts[1:]:
            pen.lineTo(p)
        pen.closePath()
    return pen.glyph()

def square(x, y, s):
    return [(x, y), (x + s, y), (x + s, y + s), (x, y + s)]

glyphs, cmap, advances = {}, {}, {}

def add(name, code, contours, adv):
    glyphs[name] = draw(contours)
    if code is not None:
        cmap[code] = name
    advances[name] = (adv, 0)

add(".notdef", None, [square(150, 0, 300)], 600)
add("space", 0x20, [], 320)
for i, (name, segs) in enumerate(
        [(n, DIGITS[n]) for n in ["zero","one","two","three","four",
                                  "five","six","seven","eight","nine"]]):
    add(name, 0x30 + i, [SEGS[s] for s in segs], ADV)

DOT = 150
add("period", 0x2E, [square(70, 0, DOT)], 260)
add("comma", 0x2C, [square(70, 0, DOT), [(70, 0), (130, 0), (40, -140), (10, -110)]], 260)
add("colon", 0x3A, [square(100, 150, DOT), square(100, 450, DOT)], 320)
dash = [h_seg(X0 + T/2 + GAP, X1 - T/2 - GAP, MID)]
add("hyphen", 0x2D, dash, ADV)
add("emdash", 0x2014, dash, ADV)
add("minus", 0x2212, dash, ADV)

order = [".notdef", "space", "zero", "one", "two", "three", "four", "five",
         "six", "seven", "eight", "nine", "period", "comma", "colon",
         "hyphen", "emdash", "minus"]

fb = FontBuilder(UPM, isTTF=True)
fb.setupGlyphOrder(order)
fb.setupCharacterMap(cmap)
fb.setupGlyf(glyphs)
fb.setupHorizontalMetrics(advances)
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({
    "familyName": "CycleHUD 7-Segment",
    "styleName": "Regular",
    "uniqueFontIdentifier": "CycleHUD7Seg-Regular-1.0",
    "fullName": "CycleHUD 7-Segment Regular",
    "psName": "CycleHUD7Seg",
    "version": "Version 1.0",
    "copyright": "Created for CycleHUD; original outlines.",
})
fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, sTypoLineGap=0,
            usWinAscent=800, usWinDescent=200,
            sxHeight=500, sCapHeight=720)
fb.setupPost()
import os
os.makedirs("CycleHUD/Fonts", exist_ok=True)
fb.save("CycleHUD/Fonts/CycleHUD7Seg.ttf")
print("font written")

# Render a preview so the style can be eyeballed.
from PIL import Image, ImageDraw, ImageFont
img = Image.new("RGB", (1180, 420), (12, 10, 18))
d = ImageDraw.Draw(img)
f96 = ImageFont.truetype("CycleHUD/Fonts/CycleHUD7Seg.ttf", 96)
f64 = ImageFont.truetype("CycleHUD/Fonts/CycleHUD7Seg.ttf", 64)
cyan, text = (37, 227, 238), (243, 240, 250)
d.text((40, 40), "0123456789", font=f96, fill=cyan)
d.text((40, 190), "24.6", font=f96, fill=text)
d.text((330, 190), "1:07:32", font=f96, fill=text)
d.text((800, 190), "-8,2", font=f96, fill=text)
d.text((40, 320), "88:88", font=f64, fill=(45, 38, 66))
d.text((300, 320), "—", font=f64, fill=text)
img.save("/tmp/claude-0/-home-user-CycleHUD/2e129d9f-5cdb-52d9-8da5-e563576640d5/scratchpad/7seg-preview.png")
print("preview written")
