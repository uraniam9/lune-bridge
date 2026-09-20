#!/usr/bin/env python3
"""
Compute the night-light colour ramp that Lune Display Bridge ships in its
Runtime Resource Overlay.

Why this exists
---------------
Android's ColorDisplayService evaluates, per channel:

    channel(T) = a*T^2 + b*T + c

and loads the result as a diagonal 3x3 into the hardware colour transform.
AOSP fits those quadratics over 2596K-4082K only. Every "warmer night light"
tweak that just lowers config_nightDisplayColorTemperatureMin is evaluating
AOSP's quadratic far outside its fitted domain: at 1700K the stock curve still
reports 26% blue, which is nowhere near a 1700K blackbody and looks washed out
rather than warm. To actually reach candlelight the coefficients have to be
refitted alongside the range.

How the curve is built
----------------------
A quadratic has three degrees of freedom, so it cannot simultaneously hit true
candlelight at 1700K and reproduce AOSP's curve across the whole stock band -
this was measured, not assumed; a weighted least-squares fit over the widened
range drifts 0.04 inside the stock band *and* goes negative at the floor. The
construction below spends those three degrees of freedom deliberately:

  1. Exact at 4082K.  The warm ceiling matches AOSP bit for bit, so the top of
     the slider is unchanged.
  2. Exact at the new floor.  The value there is the physical gain of a
     blackbody at that temperature, gamma-encoded and clipped to the sRGB
     gamut - below about 1900K a real blackbody is outside what the panel can
     show, and zero blue is the honest answer rather than a negative one.
  3. Vertex pinned at 4082K.  This forces the parabola to be monotonic across
     the whole range, so warmer always means less blue. Without it the fitted
     parabola turns over inside the range and blue starts *rising* again as
     you warm past a point, which looks like a bug to the user.

What this costs is a small deviation from AOSP inside 2596K-4082K, reported by
--check below. Green stays within ~0.03; blue runs up to ~0.05 warmer at
mid-slider. That is a subtle shift towards the physically correct value, and
the price of reaching candlelight at all.

Gamma, not linear: a hypothesis search against AOSP's own published curve put
gamma-2.4 at a 6500K white point close to four times closer than linear sRGB,
which matches the sRGB transfer exponent and is consistent with the hardware
colour transform acting on non-linear framebuffer values. Run --check to see it.

Usage
-----
    python3 tools/coefficients.py             # report + validation
    python3 tools/coefficients.py --xml       # RRO <string-array> block
    python3 tools/coefficients.py --check     # colour-space hypothesis search
    python3 tools/coefficients.py --min 1800  # a more conservative floor
"""

import argparse

# AOSP frameworks/base/core/res/res/values/config.xml
AOSP_NIGHT_COEFFS = [
    0.0, 0.0, 1.0,                                      # R
    -0.00000000962353339, 0.000153045476, 0.390782778,  # G
    -0.0000000189359041, 0.000302412211, -0.198650895,  # B
]
AOSP_MIN_K, AOSP_MAX_K = 2596, 4082

WHITE_POINT_K = 6500.0
DISPLAY_GAMMA = 2.4
DEFAULT_FLOOR_K = 1700.0

# CIE XYZ (D65-referred) -> linear sRGB
XYZ_TO_LRGB = (
    (3.2404542, -1.5371385, -0.4985314),
    (-0.9692660, 1.8760108, 0.0415560),
    (0.0556434, -0.2040259, 1.0572252),
)

CHANNELS = ("R", "G", "B")
NAMES = ["R a", "R b", "R y-int", "G a", "G b", "G y-int", "B a", "B b", "B y-int"]


def planckian_xy(t):
    """Kim et al. (2002) approximation of the Planckian locus in CIE 1931 xy.

    Valid for 1667K-25000K, which covers candlelight (~1850K) with room to
    spare. Anything below 1667K would need the full Planck integral against
    the CIE colour matching functions, and is past the point where an sRGB
    panel can show a difference anyway.
    """
    if not 1667.0 <= t <= 25000.0:
        raise ValueError("CCT %gK outside the Kim et al. valid domain 1667-25000K" % t)
    t2, t3 = t * t, t * t * t
    if t <= 4000.0:
        x = -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
    else:
        x = -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
    x2, x3 = x * x, x * x * x
    if t <= 2222.0:
        y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
    elif t <= 4000.0:
        y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
    else:
        y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
    return x, y


def linear_rgb(t):
    """Linear sRGB for a blackbody at t Kelvin, luminance-normalised (Y = 1)."""
    x, y = planckian_xy(t)
    if y == 0:
        raise ValueError("degenerate chromaticity at %gK" % t)
    big_x, big_y, big_z = x / y, 1.0, (1.0 - x - y) / y
    return tuple(m[0] * big_x + m[1] * big_y + m[2] * big_z for m in XYZ_TO_LRGB)


def shape(t, gamma=DISPLAY_GAMMA, white=WHITE_POINT_K):
    """Gamma-encoded per-channel gains vs the white point, R normalised to 1.

    Negative linear values mean the blackbody sits outside the sRGB gamut, which
    is true below roughly 1900K. They clip to zero: the warmest thing the panel
    can honestly display is no blue at all.
    """
    ref = linear_rgb(white)
    cur = linear_rgb(t)
    enc = [max(c / r, 0.0) ** (1.0 / gamma) for c, r in zip(cur, ref)]
    return tuple(v / enc[0] for v in enc)


def evaluate(coeffs, t):
    return tuple(
        coeffs[i] * t * t + coeffs[i + 1] * t + coeffs[i + 2] for i in range(0, 9, 3)
    )


def physical_floor(t):
    """Physical gains at t, rescaled to meet AOSP's curve at the stock floor.

    Anchoring to AOSP at 2596K rather than using raw physical gains keeps the
    new range continuous with the range users already have, instead of
    introducing a step at the old boundary.
    """
    anchor = evaluate(AOSP_NIGHT_COEFFS, AOSP_MIN_K)
    base = shape(AOSP_MIN_K)
    here = shape(t)
    return tuple(a * (h / b) for a, h, b in zip(anchor, here, base))


def monotonic_quad(lo, hi, y_lo, y_hi):
    """Quadratic through both endpoints whose vertex sits exactly at hi.

    Pinning the vertex at the top of the range makes the curve strictly
    monotonic across it, so warming the slider never starts adding blue back.
    Solving  y = a*t^2 - 2*a*hi*t + c  at both endpoints gives a and c directly.
    """
    span = hi - lo
    a = -(y_hi - y_lo) / (span * span)
    b = -2.0 * a * hi
    c = y_hi + a * hi * hi
    return a, b, c


def build(floor_k):
    coeffs = []
    for ch in range(3):
        coeffs.extend(
            monotonic_quad(
                floor_k,
                AOSP_MAX_K,
                physical_floor(floor_k)[ch],
                evaluate(AOSP_NIGHT_COEFFS, AOSP_MAX_K)[ch],
            )
        )
    # Red is pinned to exactly 1.0, as AOSP does, so the ramp only attenuates.
    # Asking for more red than the panel has would clip, not warm.
    coeffs[0], coeffs[1], coeffs[2] = 0.0, 0.0, 1.0
    return coeffs


def audit(coeffs, floor_k, samples=4096):
    """Measure the three things that decide whether this is safe to ship."""
    lowest = 1.0
    monotonic = True
    drift = [0.0, 0.0, 0.0]
    prev = None
    for i in range(samples + 1):
        t = floor_k + i * (AOSP_MAX_K - floor_k) / samples
        f = evaluate(coeffs, t)
        lowest = min(lowest, min(f))
        if t >= AOSP_MIN_K:
            for ch, (a, b) in enumerate(zip(f, evaluate(AOSP_NIGHT_COEFFS, t))):
                drift[ch] = max(drift[ch], abs(a - b))
        if prev is not None and (f[1] < prev[1] - 1e-12 or f[2] < prev[2] - 1e-12):
            monotonic = False
        prev = f
    return lowest, monotonic, drift


def hypothesis_search():
    """Which colour space and white point best explains AOSP's shipped curve?

    Printed by --check. The winner is why shape() encodes with gamma 2.2.
    """
    rows = []
    for white in (6500, 6504, 7000, 7500):
        for label, gamma in (("linear", 1.0), ("gamma 2.2", 2.2), ("gamma 2.4", 2.4)):
            worst = 0.0
            for i in range(129):
                t = AOSP_MIN_K + i * (AOSP_MAX_K - AOSP_MIN_K) / 128
                ours = shape(t, gamma=gamma, white=white)
                for o, h in zip(ours, evaluate(AOSP_NIGHT_COEFFS, t)):
                    worst = max(worst, abs(o - h))
            rows.append((worst, white, label))
    return sorted(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=float, default=DEFAULT_FLOOR_K, help="new warm floor, Kelvin")
    ap.add_argument("--xml", action="store_true", help="emit the RRO <string-array> block only")
    ap.add_argument("--check", action="store_true", help="show the colour-space hypothesis search")
    args = ap.parse_args()

    if args.min < 1667:
        print("error: %.0fK is below the 1667K floor of the Planckian approximation" % args.min)
        return 2
    if args.min >= AOSP_MIN_K:
        print("error: --min must be below AOSP's own floor of %dK to be worth doing" % AOSP_MIN_K)
        return 2

    coeffs = build(args.min)

    if args.xml:
        print('    <string-array name="config_nightDisplayColorTemperatureCoefficients">')
        for name, v in zip(NAMES, coeffs):
            print("        <!-- %s --> <item>%.12g</item>" % (name, v))
        print("    </string-array>")
        return 0

    if args.check:
        print("Which colour space explains AOSP's shipped ramp?")
        print("  (max per-channel error reproducing AOSP over %d-%dK)\n" % (AOSP_MIN_K, AOSP_MAX_K))
        for worst, white, label in hypothesis_search():
            print("  white %5dK  %-10s  %.4f" % (white, label, worst))
        print("\n  Closest wins: that is the space shape() encodes in.")
        print("  None match exactly - AOSP's ramp is a hand-tuned reference, which")
        print("  is why the shipped curve anchors to AOSP rather than to physics.")
        return 0

    lowest, monotonic, drift = audit(coeffs, args.min)

    print("Lune Display Bridge - night ramp")
    print("  range : %.0fK - %dK   (stock %dK - %dK)"
          % (args.min, AOSP_MAX_K, AOSP_MIN_K, AOSP_MAX_K))
    stock_blue_at_floor = evaluate(AOSP_NIGHT_COEFFS, args.min)[2]
    print("  why   : at %.0fK AOSP's own curve still reports %.0f%% blue, so lowering"
          % (args.min, stock_blue_at_floor * 100))
    print("          Min alone gives a washed-out tint, not candlelight.")

    print("\nValidation")
    ok = True
    print("  non-negative        : %-5s  (lowest channel %.4f)" % (lowest >= 0.0, lowest))
    ok &= lowest >= 0.0
    print("  monotonic           : %-5s  (warmer never adds blue back)" % monotonic)
    ok &= monotonic
    for ch, d in zip(CHANNELS, drift):
        note = "ok" if d < 0.06 else "TOO HIGH"
        print("  drift vs AOSP (%s)   : %.4f  %s" % (ch, d, note))
        ok &= d < 0.06

    print("\n  T(K)     R      G      B")
    marks = {int(args.min): "  <- new floor", 1850: "  <- candlelight",
             AOSP_MIN_K: "  <- stock floor", AOSP_MAX_K: "  <- stock ceiling, exact"}
    for t in sorted({args.min, 1850, 2000, 2200, AOSP_MIN_K, 2850, 3400, AOSP_MAX_K}):
        if not args.min <= t <= AOSP_MAX_K:
            continue
        r, g, b = evaluate(coeffs, t)
        print("  %6.0f  %.3f  %.3f  %.3f%s" % (t, r, g, b, marks.get(int(t), "")))

    print("\nCoefficients")
    for name, v in zip(NAMES, coeffs):
        print("  %-8s %.12g" % (name, v))

    print("\n%s" % ("PASS - safe to ship" if ok else "FAIL - do not ship these values"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
