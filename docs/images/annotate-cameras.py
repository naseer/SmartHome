#!/usr/bin/env python3
"""Annotate the top-down map of 50 Westacott with PoE camera placements.

Footprint corners were extracted by flood-filling the Google Maps building
polygon, so the FOV cones line up with the real walls rather than eyeballed
positions. House is rotated ~39 deg, hence corners fall on compass N/E/S/W.
"""
import math
from PIL import Image, ImageDraw, ImageFont

SRC = "/Users/naseer/.claude/uploads/836784c4-0e7e-4b33-84f7-66a67dbd904f/f0bb9562-89043.png"
OUT = "/private/tmp/claude-501/-Users-naseer/836784c4-0e7e-4b33-84f7-66a67dbd904f/scratchpad/camera-placement.png"

# Footprint corners in ORIGINAL image coords (from flood fill).
CNR = {"W": (422, 978), "N": (714, 740), "E": (895, 969), "S": (605, 1206)}
CENTRE = (659, 973)

CROP = (0, 470, 1080, 1470)          # strip phone UI chrome + empty ground below
SCALE = 1.45
LEGEND_H = 430

COL = {
    "trackmix": (232, 138, 30),
    "good": (22, 163, 74),
    "bad": (220, 38, 38),
    "duo": (124, 58, 237),
    "ink": (17, 24, 39),
    "muted": (75, 85, 99),
}


def font(size, bold=False):
    paths = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold
        else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for p in paths:
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def tx(p):
    """Original image coords -> annotated canvas coords."""
    return ((p[0] - CROP[0]) * SCALE, (p[1] - CROP[1]) * SCALE)


def unit(v):
    m = math.hypot(*v)
    return (v[0] / m, v[1] / m)


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def cone(draw, apex, direction, half_deg, radius, colour, alpha=70, steps=48):
    """Filled field-of-view wedge."""
    base = math.atan2(direction[1], direction[0])
    pts = [apex]
    for i in range(steps + 1):
        ang = base - math.radians(half_deg) + math.radians(2 * half_deg) * i / steps
        pts.append((apex[0] + radius * math.cos(ang), apex[1] + radius * math.sin(ang)))
    draw.polygon(pts, fill=colour + (alpha,), outline=colour + (200,))


def marker(draw, pos, label, colour, r=21):
    draw.ellipse([pos[0] - r, pos[1] - r, pos[0] + r, pos[1] + r],
                 fill=colour + (255,), outline=(255, 255, 255, 255), width=4)
    f = font(24, True)
    box = draw.textbbox((0, 0), label, font=f)
    draw.text((pos[0] - (box[2] - box[0]) / 2, pos[1] - (box[3] - box[1]) / 2 - 2),
              label, font=f, fill=(255, 255, 255, 255))


def tag(draw, xy, text, colour, size=25, anchor="lt", pad=7):
    f = font(size, True)
    box = draw.textbbox(xy, text, font=f, anchor=anchor)
    draw.rounded_rectangle([box[0] - pad, box[1] - pad, box[2] + pad, box[3] + pad],
                           radius=7, fill=(255, 255, 255, 236), outline=colour + (255,), width=2)
    draw.text(xy, text, font=f, fill=colour + (255,), anchor=anchor)


def main():
    base = Image.open(SRC).convert("RGB").crop(CROP)
    base = base.resize((int(base.width * SCALE), int(base.height * SCALE)), Image.LANCZOS)

    canvas = Image.new("RGB", (base.width, base.height + LEGEND_H), (255, 255, 255))
    canvas.paste(base, (0, 0))
    ov = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)

    W, N, E, S = (tx(CNR[k]) for k in ("W", "N", "E", "S"))
    centre = tx(CENTRE)

    # ---- house outline ----
    d.polygon([W, N, E, S], fill=(255, 255, 255, 30), outline=COL["ink"] + (255,), width=5)

    # ---- outward directions ----
    n_front = unit((-91, -114))     # NW, toward the street
    n_gate = unit((-146, 119))      # SW, toward #52 / the gate
    along_sw = unit((W[0] - S[0], W[1] - S[1]))   # S -> W, up the side yard

    # ---- 1. TrackMix: front face at the garage, aimed down the driveway ----
    tm = lerp(W, N, 0.66)
    cone(d, tm, n_front, 42, 330, COL["trackmix"])

    # ---- 2a. CX810 RECOMMENDED: rear-right (S) corner, up the side yard ----
    aim_good = unit((along_sw[0] * 0.88 + n_gate[0] * 0.30,
                     along_sw[1] * 0.88 + n_gate[1] * 0.30))
    cone(d, S, aim_good, 34, 470, COL["good"])

    # ---- 2b. CX810 NOT THIS: front-right (W) corner facing the front ----
    cone(d, W, n_front, 34, 300, COL["bad"], alpha=45)

    # ---- 3. Duo 2: rear-left (E) corner, 180 deg over back + left side ----
    cone(d, E, unit((E[0] - centre[0], E[1] - centre[1])), 90, 265, COL["duo"], alpha=60)

    # ---- markers ----
    marker(d, tm, "1", COL["trackmix"])
    marker(d, S, "2", COL["good"])
    marker(d, W, "X", COL["bad"])
    marker(d, E, "3", COL["duo"])

    # doorbell + gate
    db = lerp(W, N, 0.18)
    d.ellipse([db[0] - 12, db[1] - 12, db[0] + 12, db[1] + 12],
              fill=(255, 255, 255, 255), outline=COL["ink"] + (255,), width=4)

    gate = tx((408, 1040))
    d.line([gate[0] - 26, gate[1] - 20, gate[0] + 26, gate[1] + 20],
           fill=COL["good"] + (255,), width=7)
    tag(d, (gate[0] - 44, gate[1] + 30), "GATE to #52", COL["good"], 23, "rt")

    # ---- face labels ----
    tag(d, lerp(tx((568, 859)), tx((568 - 150, 859 - 190)), 1.0), "FRONT  (street)", COL["ink"], 26, "mm")
    tag(d, tx((470, 1180)), "GATE SIDE", COL["ink"], 24, "mm")
    tag(d, tx((828, 1245)), "BACK", COL["ink"], 24, "mm")
    tag(d, tx((1002, 812)), "LEFT SIDE", COL["ink"], 24, "mm")
    tag(d, tx((286, 1300)), "#52", COL["muted"], 26, "mm")
    tag(d, tx((958, 632)), "#48", COL["muted"], 26, "mm")
    tag(d, (db[0] - 30, db[1] - 18), "doorbell", COL["ink"], 21, "rb")

    # ---- compass ----
    cx, cy = canvas.width - 92, 96
    d.ellipse([cx - 46, cy - 46, cx + 46, cy + 46], fill=(255, 255, 255, 235),
              outline=COL["ink"] + (255,), width=3)
    d.polygon([(cx, cy - 34), (cx - 13, cy + 12), (cx, cy + 3), (cx + 13, cy + 12)],
              fill=COL["ink"] + (255,))
    d.text((cx, cy + 16), "N", font=font(21, True), fill=COL["ink"] + (255,), anchor="mm")

    canvas = Image.alpha_composite(canvas.convert("RGBA"), ov).convert("RGB")

    # ---- legend ----
    d2 = ImageDraw.Draw(canvas)
    y = base.height + 26
    d2.line([26, y - 12, canvas.width - 26, y - 12], fill=(209, 213, 219), width=2)
    d2.text((30, y), "PoE camera placement  -  50 Westacott Crescent",
            font=font(31, True), fill=COL["ink"])
    y += 46
    rows = [
        (COL["trackmix"], "1", "TrackMix PoE  -  garage gable, aimed down the driveway (front + garage + street approach)"),
        (COL["good"], "2", "CX810  -  REAR-RIGHT (south) corner, facing FRONT up the side yard  =  RECOMMENDED"),
        (COL["bad"], "X", "CX810 at the FRONT-RIGHT (west) corner facing front  =  avoid: gate sits behind it"),
        (COL["duo"], "3", "Duo 2 PoE  -  rear-left (east) corner, 180 deg over the backyard + left side yard"),
    ]
    for colour, key, text in rows:
        d2.ellipse([32, y + 3, 32 + 30, y + 33], fill=colour, outline=(255, 255, 255), width=3)
        d2.text((47, y + 18), key, font=font(19, True), fill=(255, 255, 255), anchor="mm")
        d2.text((80, y + 5), text, font=font(23), fill=COL["ink"])
        y += 42
    d2.text((30, y + 12),
            "Traffic through the gate walks the length of the side yard straight at camera 2  ->  faces, not backs.",
            font=font(22, True), fill=COL["good"])
    d2.text((30, y + 44),
            "Mask out #52's property in Frigate, or every trip they make to their car triggers detection.",
            font=font(22), fill=COL["muted"])

    canvas.save(OUT)
    print("wrote", OUT, canvas.size)


if __name__ == "__main__":
    main()
