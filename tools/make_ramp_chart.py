#!/usr/bin/env python3
"""
Draw the blue channel of the stock ramp against the refitted one.

This is the whole argument in one picture. AOSP fits its quadratic over
2596-4082K; the tweaks that merely lower the minimum keep evaluating that same
curve below its fitted domain, where it still reports around a quarter blue.
Plotting both against the physical blackbody target shows the gap immediately,
which a paragraph of prose does not.

Drawn with PIL rather than matplotlib: one less dependency, and the palette has
to match the module's UI anyway.
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import coefficients as C

W, H = 1200, 675
PAD_L, PAD_R, PAD_T, PAD_B = 96, 40, 96, 84
OUT = os.path.join(os.path.dirname(__file__), "..", "dist", "ramp-chart.png")

BG = (18, 16, 14)
PANEL = (28, 25, 23)
LINE = (46, 41, 38)
TEXT = (239, 230, 220)
MUTED = (162, 150, 138)
WARM = (232, 163, 85)
BLUE = (110, 160, 220)
BAD = (217, 128, 112)

FONT_DIR = "C:/Windows/Fonts"
def font(name, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)

T_LO, T_HI = 1700, 4082


def build():
    stock = C.AOSP_NIGHT_COEFFS
    fitted = C.build(C.DEFAULT_FLOOR_K)

    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = PAD_L, PAD_T, W - PAD_R, H - PAD_B
    d.rectangle([x0, y0, x1, y1], fill=PANEL)

    def px(t):  return x0 + (t - T_LO) / (T_HI - T_LO) * (x1 - x0)
    def py(v):  return y1 - max(0.0, min(1.0, v)) * (y1 - y0)

    # Grid and axis labels.
    for frac in range(0, 6):
        v = frac / 5.0
        y = py(v)
        d.line([x0, y, x1, y], fill=LINE)
        d.text((x0 - 52, y - 10), "%d%%" % (v * 100), font=font("segoeui.ttf", 17), fill=MUTED)
    # 2500 is dropped: it collides with 2596, which is the one that matters.
    for t in (1700, 2000, 2596, 3000, 3500, 4082):
        x = px(t)
        d.line([x, y0, x, y1], fill=LINE)
        d.text((x - 20, y1 + 12), str(t), font=font("segoeui.ttf", 17), fill=MUTED)

    # The band AOSP actually fitted.
    d.rectangle([px(2596), y0, px(4082), y1], fill=(34, 31, 28))
    d.line([px(2596), y0, px(2596), y1], fill=WARM, width=2)
    d.text((px(2596) + 10, y0 + 10), "AOSP fits its quadratic only to the right of here",
           font=font("segoeui.ttf", 18), fill=WARM)

    def curve(fn, colour, width=3, dash=False):
        pts = []
        t = T_LO
        while t <= T_HI:
            pts.append((px(t), py(fn(t))))
            t += 4
        for i in range(len(pts) - 1):
            if dash and (i // 6) % 2:
                continue
            d.line([pts[i], pts[i + 1]], fill=colour, width=width)

    curve(lambda t: C.physical_floor(t)[2], MUTED, 2, dash=True)
    curve(lambda t: C.evaluate(stock, t)[2], BAD)
    curve(lambda t: C.evaluate(fitted, t)[2], BLUE)

    # The number the whole argument turns on.
    sb = C.evaluate(stock, 1700)[2]
    fb = C.evaluate(fitted, 1700)[2]
    d.ellipse([px(1700) - 6, py(sb) - 6, px(1700) + 6, py(sb) + 6], fill=BAD)
    d.ellipse([px(1700) - 6, py(fb) - 6, px(1700) + 6, py(fb) + 6], fill=BLUE)
    # Both annotations live in the empty block above the curves, colour-matched
    # to the lines instead of joined by leaders. Leaders looked tidy in the
    # abstract and crossed three curves in practice.
    f22 = font("segoeuib.ttf", 22)
    ax = px(1700) + 60
    d.text((ax, y0 + 104), "stock curve at 1700K", font=f22, fill=BAD)
    d.text((ax, y0 + 132), "still %.0f%% blue" % (sb * 100), font=f22, fill=BAD)
    d.text((ax, y0 + 196), "refitted", font=f22, fill=BLUE)
    d.text((ax, y0 + 224), "%.0f%% blue, real candlelight" % (fb * 100), font=f22, fill=BLUE)

    d.text((PAD_L, 26), "Blue channel, asked for candlelight",
           font=font("segoeui.ttf", 34), fill=TEXT)
    d.text((PAD_L + 2, 66), "What Night Light sends to the panel at each colour temperature",
           font=font("segoeuil.ttf", 20), fill=MUTED)

    ly, lx2, f18 = H - 44, PAD_L, font("segoeui.ttf", 18)
    for colour, label in ((BAD, "stock AOSP curve"), (BLUE, "refitted"),
                          (MUTED, "true blackbody")):
        d.line([lx2, ly + 9, lx2 + 30, ly + 9], fill=colour, width=3)
        d.text((lx2 + 40, ly), label, font=f18, fill=MUTED)
        lx2 += 40 + int(d.textlength(label, font=f18)) + 34

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, "PNG")
    print(OUT, "%dx%d" % img.size)
    print("stock blue at 1700K: %.1f%%   refitted: %.1f%%" % (sb * 100, fb * 100))


if __name__ == "__main__":
    build()
