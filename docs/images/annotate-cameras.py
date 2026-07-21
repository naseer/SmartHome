#!/usr/bin/env python3
"""Annotate the top-down map of 50 Westacott with PoE camera placements.

Footprint corners were extracted by flood-filling the Google Maps building
polygon, so the FOV cones line up with real walls rather than eyeballed spots.
The house sits ~39 deg off compass north, so its corners fall on N/E/S/W:
  W = front-right   N = front-left   E = rear-left   S = rear-right

FINAL 4-CAMERA LAYOUT: both side yards have gates (to #52 and to #48), so each
gets a dedicated capture camera at the rear corner facing FORWARD -- traffic
through either gate walks the length of the corridor into the lens. That frees
the Duo 2 off the corner to cover the backyard alone.
"""
import math
from PIL import Image, ImageDraw, ImageFont

SRC = "/Users/naseer/.claude/uploads/836784c4-0e7e-4b33-84f7-66a67dbd904f/f0bb9562-89043.png"
OUT = "/private/tmp/claude-501/-Users-naseer/836784c4-0e7e-4b33-84f7-66a67dbd904f/scratchpad/camera-placement.png"

CNR = {"W": (422, 978), "N": (714, 740), "E": (895, 969), "S": (605, 1206)}
CENTRE = (659, 973)

CROP = (0, 470, 1080, 1470)
SCALE = 1.45
LEGEND_H = 430

COL = {
    "trackmix": (232, 138, 30),
    "cx": (22, 163, 74),
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
    return ((p[0] - CROP[0]) * SCALE, (p[1] - CROP[1]) * SCALE)


def unit(v):
    m = math.hypot(*v)
    return (v[0] / m, v[1] / m)


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def blend(a, b, wa, wb):
    return unit((a[0] * wa + b[0] * wb, a[1] * wa + b[1] * wb))


def cone(draw, apex, direction, half_deg, radius, colour, alpha=70, steps=48):
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


def gate_mark(draw, pos, label, side):
    draw.line([pos[0] - 26, pos[1] - 20, pos[0] + 26, pos[1] + 20],
              fill=COL["cx"] + (255,), width=7)
    dx, anchor = (-44, "rt") if side == "left" else (44, "lt")
    tag(draw, (pos[0] + dx, pos[1] + 26), label, COL["cx"], 23, anchor)


def main():
    base = Image.open(SRC).convert("RGB").crop(CROP)
    base = base.resize((int(base.width * SCALE), int(base.height * SCALE)), Image.LANCZOS)

    canvas = Image.new("RGB", (base.width, base.height + LEGEND_H), (255, 255, 255))
    canvas.paste(base, (0, 0))
    ov = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)

    W, N, E, S = (tx(CNR[k]) for k in ("W", "N", "E", "S"))
    centre = tx(CENTRE)

    d.polygon([W, N, E, S], fill=(255, 255, 255, 30), outline=COL["ink"] + (255,), width=5)

    n_front = unit((-91, -114))     # NW, to the street
    n_gate52 = unit((-146, 119))    # SW, to #52
    n_gate48 = unit((145, -119))    # NE, to #48
    n_back = unit((91, 114))        # SE, backyard

    along_sw = unit((W[0] - S[0], W[1] - S[1]))   # S -> W, up the #52 side yard
    along_ne = unit((N[0] - E[0], N[1] - E[1]))   # E -> N, up the #48 side yard

    # 1 TrackMix -- front face at the garage, down the driveway
    tm = lerp(W, N, 0.66)
    cone(d, tm, n_front, 42, 330, COL["trackmix"])

    # 2 CX810 -- rear-RIGHT (S) corner, forward up the #52 side yard
    cone(d, S, blend(along_sw, n_gate52, 0.88, 0.30), 34, 450, COL["cx"])

    # 3 CX810 -- rear-LEFT (E) corner, forward up the #48 side yard
    cone(d, E, blend(along_ne, n_gate48, 0.88, 0.30), 34, 450, COL["cx"])

    # 4 Duo 2 -- mid BACK wall, 180 deg over the backyard only
    duo = lerp(E, S, 0.5)
    cone(d, duo, n_back, 90, 285, COL["duo"], alpha=60)

    marker(d, tm, "1", COL["trackmix"])
    marker(d, S, "2", COL["cx"])
    marker(d, E, "3", COL["cx"])
    marker(d, duo, "4", COL["duo"])

    db = lerp(W, N, 0.18)
    d.ellipse([db[0] - 12, db[1] - 12, db[0] + 12, db[1] + 12],
              fill=(255, 255, 255, 255), outline=COL["ink"] + (255,), width=4)

    gate_mark(d, tx((408, 1040)), "GATE to #52", "left")
    gate_mark(d, tx((800, 762)), "GATE to #48", "right")

    tag(d, tx((418, 669)), "FRONT  (street)", COL["ink"], 26, "mm")
    tag(d, tx((455, 1195)), "GATE SIDE", COL["ink"], 24, "mm")
    tag(d, tx((955, 1215)), "BACKYARD", COL["ink"], 24, "mm")
    tag(d, tx((1000, 852)), "LEFT SIDE", COL["ink"], 24, "mm")
    tag(d, tx((286, 1300)), "#52", COL["muted"], 26, "mm")
    tag(d, tx((962, 618)), "#48", COL["muted"], 26, "mm")
    tag(d, (db[0] - 30, db[1] - 18), "doorbell", COL["ink"], 21, "rb")

    cx, cy = canvas.width - 92, 96
    d.ellipse([cx - 46, cy - 46, cx + 46, cy + 46], fill=(255, 255, 255, 235),
              outline=COL["ink"] + (255,), width=3)
    d.polygon([(cx, cy - 34), (cx - 13, cy + 12), (cx, cy + 3), (cx + 13, cy + 12)],
              fill=COL["ink"] + (255,))
    d.text((cx, cy + 16), "N", font=font(21, True), fill=COL["ink"] + (255,), anchor="mm")

    canvas = Image.alpha_composite(canvas.convert("RGBA"), ov).convert("RGB")

    d2 = ImageDraw.Draw(canvas)
    y = base.height + 26
    d2.line([26, y - 12, canvas.width - 26, y - 12], fill=(209, 213, 219), width=2)
    d2.text((30, y), "PoE camera placement  -  50 Westacott Crescent",
            font=font(31, True), fill=COL["ink"])
    y += 46
    rows = [
        (COL["trackmix"], "1", "TrackMix PoE  -  garage gable, aimed down the driveway (front + garage + street)"),
        (COL["cx"], "2", "CX810  -  rear-RIGHT (south) corner, facing forward up the #52 side yard"),
        (COL["cx"], "3", "CX810  -  rear-LEFT (east) corner, facing forward up the #48 side yard"),
        (COL["duo"], "4", "Duo 2 PoE  -  mid back wall, 180 deg over the backyard only"),
    ]
    for colour, key, text in rows:
        d2.ellipse([32, y + 3, 32 + 30, y + 33], fill=colour, outline=(255, 255, 255), width=3)
        d2.text((47, y + 18), key, font=font(19, True), fill=(255, 255, 255), anchor="mm")
        d2.text((80, y + 5), text, font=font(23), fill=COL["ink"])
        y += 42
    d2.text((30, y + 12),
            "Both gates are now watched by a camera the intruder walks TOWARD  ->  faces, not backs.",
            font=font(22, True), fill=COL["cx"])
    d2.text((30, y + 44),
            "Mask #52 and #48 property in Frigate. Soffit-shade 2 and 3: facing NW puts evening sun in the lens.",
            font=font(22), fill=COL["muted"])

    canvas.save(OUT)
    print("wrote", OUT, canvas.size)


if __name__ == "__main__":
    main()
