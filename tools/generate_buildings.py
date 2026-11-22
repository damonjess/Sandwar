#!/usr/bin/env python3
"""Dune 2000 style pre-rendered art pipeline for Sandwar.

Renders, with no anti-aliasing anywhere:

  assets/sprites/d2/cy.png          Construction Yard  4 idle + 4 damaged frames
  assets/sprites/d2/refinery.png    Spice Refinery     4 idle + 4 damaged frames
  assets/sprites/d2/windtrap.png    Wind Trap          4 idle + 4 damaged frames
  assets/sprites/d2/*_icon.png      HUD miniatures (64 px, nearest downscale)
  assets/sprites/d2/terrain_*.png   Sand / rock / concrete / spice / cliff tiles

Run from the project folder (NumPy is the only extra dependency):

    python3 tools/generate_buildings.py

Every building sheet is FRAMES wide and two rows tall: row 0 is the idle cycle,
row 1 is the battle-damaged cycle. House colours are never baked: faction trim
is painted in the magenta remap palette and recoloured at runtime by
shaders/faction_remap.gdshader. Light is fixed north-west, shadows fall south-
east, and shading is quantised with a 4x4 Bayer dither over a desaturated,
rust-and-sand palette.
"""

from __future__ import annotations

import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets/sprites/d2"

TILE = 40
RISE = 0.95   # screen pixels per world pixel of height
FRAMES = 4
MARGIN = 72   # transparent breathing room around the footprint, per side

# ---------------------------------------------------------------- palette
# Gritty, desaturated 1998 RTS palette: weathered steel, dark rust, dusty sand.
CONCRETE = (158, 150, 132)
CONCRETE_D = (112, 106, 92)
CONCRETE_L = (184, 176, 157)
CONCRETE_SEAM = (66, 62, 53)
SAND = (176, 143, 95)
SAND_D = (135, 106, 66)
SAND_L = (201, 169, 116)
STEEL = (116, 120, 119)
STEEL_D = (70, 74, 74)
STEEL_L = (157, 160, 156)
GUN = (94, 99, 100)
GUN_D = (47, 51, 52)
GUN_L = (134, 139, 139)
RUST = (120, 66, 37)
RUST_D = (63, 32, 18)
RUST_L = (157, 97, 52)
HAZ_Y = (177, 139, 43)
HAZ_K = (29, 27, 23)
CYAN = (96, 226, 210)
CYAN_D = (18, 70, 69)
AMBER = (228, 136, 30)
RED = (194, 51, 35)
MAGENTA = (188, 34, 160)
MAGENTA_D = (102, 8, 82)
MAGENTA_L = (231, 117, 205)
GLASS = (34, 50, 56)
GLASS_L = (94, 136, 140)
SMOKE = (46, 44, 42)
SMOKE_L = (79, 76, 71)
SMOKE_D = (25, 23, 22)
OUTLINE = (19, 17, 15, 255)

BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6],
                  [3, 11, 1, 9], [15, 7, 13, 5]], dtype=np.int16)
BAYER_TILE = np.tile(BAYER, (10, 10)).astype(np.float32)


def clamp8(v: float) -> int:
    return 0 if v < 0 else (255 if v > 255 else int(v))


def mix(a, b, t: float):
    return tuple(clamp8(a[i] + (b[i] - a[i]) * t) for i in range(3))


def mul(c, f: float):
    return tuple(clamp8(c[i] * f) for i in range(3))


def lighten(c, t: float):
    return mix(c, (250, 244, 228), t)


def darken(c, t: float):
    return mix(c, (18, 16, 14), t)


def face_col(c, kind: str):
    """Fixed north-west sun: roofs catch the sky, west walls lit, the rest dark."""
    if kind == "top":
        return lighten(mix(c, (226, 218, 196), 0.30), 0.04)
    if kind == "west":
        return lighten(c, 0.17)
    if kind == "east":
        return mul(mix(c, (42, 48, 52), 0.16), 0.62)
    return mul(mix(c, (50, 41, 34), 0.12), 0.78)


def rect_pts(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


class Face:
    """A projected quad addressed in (u, v) face coordinates."""

    def __init__(self, tl, tr, br, bl):
        self.tl, self.tr, self.br, self.bl = tl, tr, br, bl

    def pt(self, u: float, v: float):
        top = (self.tl[0] + (self.tr[0] - self.tl[0]) * u,
               self.tl[1] + (self.tr[1] - self.tl[1]) * u)
        bot = (self.bl[0] + (self.br[0] - self.bl[0]) * u,
               self.bl[1] + (self.br[1] - self.bl[1]) * u)
        return (top[0] + (bot[0] - top[0]) * v,
                top[1] + (bot[1] - top[1]) * v)

    def quad(self, u0, v0, u1, v1):
        return [self.pt(u0, v0), self.pt(u1, v0), self.pt(u1, v1), self.pt(u0, v1)]

    def pixel_width(self) -> float:
        return max(1.0, math.dist(self.tl, self.tr))


class Frame:
    def __init__(self, width: int, height: int, t: float, damaged: bool, rng: random.Random):
        self.w, self.h = width, height
        self.cx = width // 2
        self.cy = height // 2
        self.t = t
        self.damaged = damaged
        self.rng = rng
        self.base = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        self.bd = ImageDraw.Draw(self.base)
        self.s = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        self.sd = ImageDraw.Draw(self.s)

    def p(self, x: float, y: float, z: float = 0.0):
        return (self.cx + x, self.cy + y - z * RISE)

    def b_poly(self, pts, col):
        self.bd.polygon(pts, fill=col)

    def b_line(self, pts, col, width=1):
        self.bd.line(pts, fill=col, width=width)

    def b_overlay(self, draw_fn):
        layer = Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))
        draw_fn(ImageDraw.Draw(layer))
        self.base = Image.alpha_composite(self.base, layer)
        self.bd = ImageDraw.Draw(self.base)

    def poly(self, pts, col):
        self.sd.polygon(pts, fill=col)

    def line(self, pts, col, width=1):
        self.sd.line(pts, fill=col, width=width)

    def mask_of(self, pts) -> Image.Image:
        mask = Image.new("L", (self.w, self.h), 0)
        ImageDraw.Draw(mask).polygon(pts, fill=255)
        return mask

    def poly_clipped(self, pts, col):
        mask = self.mask_of(pts)
        layer = Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(pts, fill=col)
        layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
        self.s = Image.alpha_composite(self.s, layer)
        self.sd = ImageDraw.Draw(self.s)

    def dither_poly(self, pts, c1, c2, amount=0.5, ground=False):
        """Hard-edged Bayer dither between two colours inside a polygon."""
        mask = np.array(self.mask_of(pts)) > 0
        layer = Image.new("RGBA", (self.w, self.h), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(pts, fill=c1)
        arr = np.array(layer)
        ys, xs = np.where(mask)
        if len(xs):
            sel = (BAYER[ys % 4, xs % 4] / 16.0) < amount
            arr[ys[sel], xs[sel], :3] = c2
        layer = Image.fromarray(arr)
        if ground:
            self.base = Image.alpha_composite(self.base, layer)
            self.bd = ImageDraw.Draw(self.base)
        else:
            self.s = Image.alpha_composite(self.s, layer)
            self.sd = ImageDraw.Draw(self.s)

    def structure_alpha(self) -> Image.Image:
        return self.s.getchannel("A")


# ---------------------------------------------------------------- ground
def contact_shadow(f: Frame, x, y, w, d, spread=5, alpha=76):
    """Hard south-east drop shadow baked into the concrete."""
    def paint(draw):
        off = 5
        pts = [f.p(x + off - spread * 0.4, y + off - spread * 0.3),
               f.p(x + w + off + spread * 0.6, y + off - spread * 0.3),
               f.p(x + w + off + spread * 0.6, y + d + off + spread * 0.5),
               f.p(x + off - spread * 0.4, y + d + off + spread * 0.5)]
        draw.polygon(pts, fill=(24, 19, 14, alpha))
        draw.polygon([pts[0], f.p(x + w + off, y + off), f.p(x + w + off, y + d + off),
                      (pts[3][0], pts[3][1])], fill=(18, 14, 10, alpha // 2))
    f.b_overlay(paint)


def draw_pad(f: Frame, wt: int, ht: int, rng: random.Random):
    """Beveled, cracked concrete foundation with sand drifting over the rim."""
    W, H = wt * TILE, ht * TILE
    x0, y0 = -W / 2, -H / 2
    x1, y1 = x0 + W, y0 + H
    sx0, sy0 = f.cx + x0, f.cy + y0
    sx1, sy1 = f.cx + x1, f.cy + y1
    f.b_poly(rect_pts(sx0, sy0, sx1, sy1), CONCRETE_SEAM)

    for ty in range(ht):
        for tx in range(wt):
            tx0 = sx0 + 2 + tx * TILE
            ty0 = sy0 + 2 + ty * TILE
            tx1 = min(sx1 - 2, tx0 + TILE)
            ty1 = min(sy1 - 2, ty0 + TILE)
            tone = mix(CONCRETE, CONCRETE_D, rng.uniform(0.02, 0.16))
            f.bd.rectangle([tx0, ty0, tx1 - 1, ty1 - 1], fill=tone)
            # coarse aggregate and stains, all 1-2 px hard pixels
            for _ in range(22):
                px = rng.uniform(tx0 + 2, tx1 - 3)
                py = rng.uniform(ty0 + 2, ty1 - 3)
                c = mix(tone, CONCRETE_D, rng.uniform(0.25, 0.7)) if rng.random() < 0.65 else \
                    mix(tone, CONCRETE_L, rng.uniform(0.2, 0.55))
                f.bd.rectangle([px, py, px + rng.choice([0, 1]), py + rng.choice([0, 1])], fill=c)
            if rng.random() < 0.6:
                px = rng.uniform(tx0 + 4, tx1 - 10)
                py = rng.uniform(ty0 + 4, ty1 - 9)
                f.bd.ellipse([px, py, px + rng.uniform(5, 12), py + rng.uniform(4, 8)],
                             fill=mix(tone, CONCRETE_D, 0.30))

    # grid seams: dark joint plus a chipped lit lip on the north-west side
    for k in range(1, wt):
        x = sx0 + k * TILE
        f.b_line([(x, sy0 + 2), (x, sy1 - 2)], CONCRETE_SEAM)
        f.b_line([(x + 1, sy0 + 2), (x + 1, sy1 - 2)], (161, 153, 136))
    for k in range(1, ht):
        y = sy0 + k * TILE
        f.b_line([(sx0 + 2, y), (sx1 - 2, y)], CONCRETE_SEAM)
        f.b_line([(sx0 + 2, y + 1), (sx1 - 2, y + 1)], (161, 153, 136))

    # chunky bevel: NW lit, SE in shade
    f.b_line([(sx0, sy0), (sx1, sy0)], (196, 187, 166), 2)
    f.b_line([(sx0, sy0), (sx0, sy1)], (184, 175, 155), 2)
    f.b_line([(sx0, sy1), (sx1, sy1)], (70, 66, 57), 3)
    f.b_line([(sx1, sy0), (sx1, sy1)], (76, 72, 62), 3)
    f.bd.rectangle([sx0, sy0, sx1 - 1, sy1 - 1], outline=(45, 42, 36))
    f.b_line([(sx0 + 3, sy0 + 4), (sx1 - 4, sy0 + 4)], (180, 172, 154))
    f.b_line([(sx0 + 4, sy0 + 3), (sx0 + 4, sy1 - 4)], (173, 165, 148))

    # long cracks, with a lighter chipped edge offset south-east
    for _ in range(4 + (4 if f.damaged else 0)):
        px = rng.uniform(sx0 + 12, sx1 - 12)
        py = rng.uniform(sy0 + 12, sy1 - 12)
        ang = rng.uniform(0, math.tau)
        pts = [(px, py)]
        for _ in range(rng.randint(3, 7)):
            ang += rng.uniform(-0.9, 0.9)
            ln = rng.uniform(3, 10)
            px += math.cos(ang) * ln
            py += math.sin(ang) * ln
            pts.append((px, py))
        f.b_line(pts, (84, 79, 69))
        f.b_line([(x + 1, y + 1) for x, y in pts], (168, 160, 142))

    # sand drifted into the corners and along the south/east rim
    for cx_, cy_, rw, rh in ((x0 + 7, y1 - 7, 22, 8), (x1 - 12, y1 - 5, 26, 7),
                             (x0 + 4, y0 + 10, 11, 5), (x1 - 6, y0 + 7, 10, 4),
                             (x0 + 2, y0 + H * 0.55, 7, 12)):
        def sand_paint(d, cx_=cx_, cy_=cy_, rw=rw, rh=rh):
            for _ in range(7):
                ex = f.cx + cx_ + rng.uniform(-rw * 0.45, rw * 0.45)
                ey = f.cy + cy_ + rng.uniform(-rh * 0.45, rh * 0.45)
                rr = rng.uniform(1.6, 4.4)
                d.polygon([(max(sx0 + 2, min(sx1 - 2, ex + math.cos(a) * rr)),
                            max(sy0 + 2, min(sy1 - 2, ey + math.sin(a) * rr * 0.45)))
                           for a in np.linspace(0, math.tau, 9)],
                          fill=(SAND[0], SAND[1], SAND[2], rng.randint(70, 130)))
        f.b_overlay(sand_paint)

    # rust blooms creeping out of the pour joints
    for _ in range(6 if f.damaged else 4):
        px = rng.uniform(sx0 + 4, sx1 - 8)
        py = rng.uniform(sy0 + 4, sy1 - 8)
        c = mix(RUST, CONCRETE_D, rng.uniform(0.2, 0.55)) + (rng.randint(40, 90),)
        f.bd.rectangle([px, py, px + rng.uniform(2, 7), py + rng.uniform(1, 4)], fill=c)

    # chipped paint and bolt heads on the rim
    for _ in range(12 if f.damaged else 7):
        px = rng.uniform(sx0 + 3, sx1 - 4)
        py = rng.uniform(sy0 + 3, sy1 - 4)
        f.bd.rectangle([px, py, px + 1, py + 1], fill=darken(CONCRETE, 0.24))
    for px in (sx0 + 8, sx1 - 9):
        for py in (sy0 + 8, sy1 - 9):
            f.bd.rectangle([px, py, px + 1, py + 1], fill=(58, 54, 46))
            f.bd.point((px, py), fill=(186, 178, 158))


# ---------------------------------------------------------------- structures
def box(f: Frame, x, y, z, w, d, h, col, taper=3.0, seams=True, rivets=True, faces=True):
    """One extruded volume with an inset roof, the classic 2.5D RTS read."""
    t = min(taper, w * 0.25, d * 0.25)
    A, B = f.p(x, y, z), f.p(x + w, y, z)
    C, D = f.p(x + w, y + d, z), f.p(x, y + d, z)
    A2 = f.p(x + t, y + t, z + h)
    B2 = f.p(x + w - t, y + t, z + h)
    C2 = f.p(x + w - t, y + d - t, z + h)
    D2 = f.p(x + t, y + d - t, z + h)

    south = Face(D2, C2, C, D)
    west = Face(A2, D2, D, A)
    east = Face(C2, B2, B, C)
    top = Face(A2, B2, C2, D2)

    f.poly([A2, B2, B, C, D, A], mul(col, 0.32))
    f.poly([C2, B2, B, C], face_col(col, "east"))
    f.poly([D2, C2, C, D], face_col(col, "south"))
    f.poly([A2, D2, D, A], face_col(col, "west"))
    f.poly([A2, B2, C2, D2], face_col(col, "top"))

    if faces:
        f.line([D2, C2], (24, 21, 18))
        f.line([C2, B2], (22, 20, 18))
        f.line([A2, D2], (22, 20, 18))
        f.line([A2, B2], (222, 211, 187))
        f.line([A2, A], (204, 193, 171))
    if seams:
        wall_seams(f, south, col, max(1, int(w // 20)), darken(col, 0.42), lighten(col, 0.10))
        wall_seams(f, west, col, max(1, int(d // 20)), darken(col, 0.38), lighten(col, 0.12))
    if rivets:
        rivet_row(f, south, 0.07, w)
        rivet_row(f, south, 0.93, w)
        rivet_row(f, west, 0.08, d)
    return south, west, top, east


def wall_seams(f: Frame, face: Face, col, n, dark, light):
    for i in range(1, n):
        u = i / n
        f.line([face.pt(u, 0.06), face.pt(u, 0.94)], dark)
        f.line([face.pt(u + 0.014, 0.06), face.pt(u + 0.014, 0.94)], light)
    # ambient occlusion where the wall meets the ground
    f.poly_clipped(face.quad(0.0, 0.82, 1.0, 1.0), (16, 13, 11, 92))
    f.line([face.pt(0.0, 0.02), face.pt(1.0, 0.02)], lighten(light, 0.16))


def rivet_row(f: Frame, face: Face, v: float, span_px: float):
    n = max(2, int(span_px // 11))
    for i in range(n + 1):
        u = 0.04 + 0.92 * i / n
        px, py = face.pt(u, v)
        f.line([(px, py), (px, py)], (20, 18, 15))
        f.line([(px - 1, py - 1), (px - 1, py - 1)], (206, 197, 178))


def roof_plate(f: Frame, z, x, y, w, d, col, inset=2.5):
    x0, y0, x1, y1 = x + inset, y + inset, x + w - inset, y + d - inset
    f.poly([f.p(x0, y0, z), f.p(x1, y0, z), f.p(x1, y1, z), f.p(x0, y1, z)],
           face_col(lighten(col, 0.03), "top"))
    f.line([f.p(x0, y0, z), f.p(x1, y0, z)], (238, 228, 201))
    f.line([f.p(x0, y1, z), f.p(x1, y1, z)], (74, 69, 58))
    f.line([f.p(x0, y0, z), f.p(x0, y1, z)], (218, 208, 186))
    f.line([f.p(x1, y0, z), f.p(x1, y1, z)], (78, 73, 62))
    nx = max(1, int(w // 22))
    ny = max(1, int(d // 22))
    for i in range(1, nx):
        xx = x0 + (x1 - x0) * i / nx
        f.line([f.p(xx, y0, z), f.p(xx, y1, z)], darken(col, 0.55))
        f.line([f.p(xx + 1.2, y0, z), f.p(xx + 1.2, y1, z)], lighten(col, 0.12))
    for i in range(1, ny):
        yy = y0 + (y1 - y0) * i / ny
        f.line([f.p(x0, yy, z), f.p(x1, yy, z)], darken(col, 0.55))
        f.line([f.p(x0, yy + 1.2, z), f.p(x1, yy + 1.2, z)], lighten(col, 0.12))
    for i in range(0, int(w), 12):
        f.line([f.p(x0 + i + 2, y0 + 1.5, z)] * 2, (192, 183, 163))
        f.line([f.p(x0 + i + 2, y1 - 1.5, z)] * 2, (82, 76, 64))


def hazard_face(f: Frame, face: Face, u0, v0, u1, v1, stripe_px=8, slant=0.06):
    band = face.quad(u0, v0, u1, v1)
    f.poly(band, HAZ_Y)
    mask = f.mask_of(band)
    layer = Image.new("RGBA", (f.w, f.h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    step = max(0.02, stripe_px / face.pixel_width())
    u = u0 - 0.2
    while u < u1 + 0.2:
        d.polygon([face.pt(u, v0), face.pt(u + step, v0),
                   face.pt(u + step + slant, v1), face.pt(u + slant, v1)], fill=HAZ_K)
        u += step * 2.0
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
    f.s = Image.alpha_composite(f.s, layer)
    f.sd = ImageDraw.Draw(f.s)
    f.line([face.pt(u0, v0), face.pt(u1, v0)], (246, 214, 128))
    f.line([face.pt(u0, v1), face.pt(u1, v1)], (40, 35, 26))


def banner(f: Frame, face: Face, u0, u1, v0, v1, emblem=True, torn=False):
    top = [face.pt(u0, v0), face.pt(u1, v0)]
    bot = [face.pt(u1, v1), face.pt(u0, v1)]
    wave = abs(bot[0][1] - top[0][1]) * 0.10
    pts = [top[0], top[1],
           (bot[0][0], bot[0][1] - (wave if torn else 0.0)),
           ((bot[0][0] + bot[1][0]) * 0.5, (bot[0][1] + bot[1][1]) * 0.5 + wave * 0.7),
           (bot[1][0], bot[1][1])]
    f.poly(pts, MAGENTA)
    f.poly([pts[1], (pts[1][0] + (pts[2][0] - pts[1][0]) * 0.30, pts[1][1]),
            (pts[3][0] + (pts[4][0] - pts[3][0]) * 0.22, pts[3][1]), pts[4]], MAGENTA_D)
    f.line([pts[0], pts[1]], (42, 6, 34), 2)
    if emblem:
        ex = (pts[0][0] + pts[1][0]) * 0.5
        ey = (pts[0][1] + pts[4][1]) * 0.5
        r = max(2.0, abs(pts[1][0] - pts[0][0]) * 0.22)
        f.poly([(ex, ey - r), (ex + r * 0.8, ey), (ex, ey + r), (ex - r * 0.8, ey)], MAGENTA_L)
        f.poly([(ex, ey - r * 0.45), (ex + r * 0.38, ey), (ex, ey + r * 0.5),
                (ex - r * 0.38, ey)], (48, 6, 38))
    # weather-stained cloth: frayed holes and sun-bleached streaks
    for _ in range(3):
        hx = f.rng.uniform(pts[0][0] + 1, pts[1][0] - 1)
        hy = f.rng.uniform(pts[0][1] + 2, pts[4][1] - 2)
        f.line([(hx, hy), (hx, hy + f.rng.randint(1, 4))], (61, 9, 47))
    f.line([(pts[0][0] + 1, pts[0][1] + 3), (pts[1][0] - 1, pts[0][1] + 3)],
           mix(MAGENTA_L, MAGENTA, 0.4))


def pipe(f: Frame, pts, col, r=1):
    screen = [f.p(*p) for p in pts]
    f.line(screen, darken(col, 0.66), r * 2 + 2)
    f.line(screen, col, r * 2)
    f.line([(x - 1, y - 1) for x, y in screen], lighten(col, 0.32), 1)


def grating(f: Frame, x, y, w, d, col=GUN_D, slats=5):
    f.poly([f.p(x, y), f.p(x + w, y), f.p(x + w, y + d), f.p(x, y + d)], col)
    for i in range(1, slats):
        yy = y + d * i / slats
        f.line([f.p(x + 1, yy), f.p(x + w - 1, yy)], (14, 15, 16))
        f.line([f.p(x + 1, yy + 1), f.p(x + w - 1, yy + 1)], (86, 91, 93))
    f.line([f.p(x, y), f.p(x + w, y)], (132, 137, 138))
    f.line([f.p(x, y), f.p(x, y + d)], (118, 123, 124))


def beacon(f: Frame, x, y, z, col, on=True, r=2):
    p = f.p(x, y, z)
    f.line([(p[0], p[1] + 2), (p[0], p[1] + 5)], (36, 32, 28))
    f.poly([(p[0] + math.cos(a) * r, p[1] + math.sin(a) * r)
            for a in np.linspace(0, math.tau, 10)], darken(col, 0.5))
    if on:
        f.poly([(p[0] + math.cos(a) * (r - 1), p[1] + math.sin(a) * (r - 1))
                for a in np.linspace(0, math.tau, 10)], col)
        f.line([(p[0] - 1, p[1] - 1), (p[0] - 1, p[1] - 1)], lighten(col, 0.6))


def armor_plate(f: Frame, face: Face, u0, v0, u1, v1, bolts=True):
    """Bolted house-coloured armour panel, chipped down to dark primer."""
    q = face.quad(u0, v0, u1, v1)
    f.poly(q, MAGENTA_D)
    inner = face.quad(u0 + 0.018, v0 + 0.018, u1 - 0.018, v1 - 0.018)
    f.dither_poly(inner, MAGENTA, MAGENTA_D, 0.30)
    f.line([inner[0], inner[1]], MAGENTA_L)
    f.line([inner[0], inner[3]], MAGENTA_L)
    f.line([inner[3], inner[2]], (64, 6, 50))
    f.line([inner[1], inner[2]], (70, 8, 54))
    # horizontal ribs break up the flat paint and catch the light
    for k in (0.34, 0.66):
        vv = v0 + (v1 - v0) * k
        f.line([face.pt(u0 + 0.03, vv), face.pt(u1 - 0.03, vv)], (78, 10, 60))
        f.line([face.pt(u0 + 0.03, vv + 0.025), face.pt(u1 - 0.03, vv + 0.025)],
               mix(MAGENTA_L, MAGENTA, 0.35))
    if bolts:
        for u, v in ((u0 + 0.03, v0 + 0.06), (u1 - 0.03, v0 + 0.06),
                     (u0 + 0.03, v1 - 0.06), (u1 - 0.03, v1 - 0.06)):
            px, py = face.pt(u, v)
            f.line([(px, py), (px, py)], (28, 4, 22))
            f.line([(px - 1, py - 1), (px - 1, py - 1)], MAGENTA_L)
    for _ in range(3):
        sx = f.rng.uniform(u0 + 0.05, u1 - 0.08)
        sy = f.rng.uniform(v0 + 0.08, v1 - 0.08)
        f.line([face.pt(sx, sy), face.pt(sx + 0.05, sy + 0.04)], (74, 10, 58))


def rust_streak(f: Frame, x, y, length, width=2, rng=None):
    """Vertical bleed of rust, clipped to the current structure silhouette."""
    rng = rng or f.rng
    overlay = Image.new("RGBA", (f.w, f.h), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for i in range(width):
        px = int(x + i)
        yy = int(y)
        while yy < int(y + length):
            seg = rng.randint(2, 7)
            a = rng.randint(38, 104)
            d.line([(px, yy), (px, yy + seg)], fill=RUST_D + (a,))
            if rng.random() < 0.5:
                d.line([(px, yy), (px, yy + min(seg, 2))], fill=RUST + (a // 2,))
            yy += seg + rng.randint(0, 3)
    overlay.putalpha(ImageChops.multiply(overlay.getchannel("A"), f.structure_alpha()))
    f.s = Image.alpha_composite(f.s, overlay)
    f.sd = ImageDraw.Draw(f.s)


def cog(f: Frame, cx, cy, r, phase=0.0, col=STEEL):
    teeth = 8
    for i in range(teeth):
        a = phase + math.tau * i / teeth
        tx, ty = cx + math.cos(a) * r, cy + math.sin(a) * r * 0.84
        f.poly([(tx - 2, ty - 2), (tx + 2, ty - 2), (tx + 2, ty + 2), (tx - 2, ty + 2)],
               darken(col, 0.34))
    f.poly([(cx + math.cos(a) * r, cy + math.sin(a) * r * 0.84)
            for a in np.linspace(0, math.tau, 14)], col)
    f.poly([(cx + math.cos(a) * r * 0.62, cy + math.sin(a) * r * 0.54)
            for a in np.linspace(0, math.tau, 12)], darken(col, 0.46))
    f.poly([(cx + math.cos(a) * r * 0.20, cy + math.sin(a) * r * 0.18)
            for a in np.linspace(0, math.tau, 8)], lighten(col, 0.22))
    f.line([(cx - r * 0.62, cy - r * 0.30), (cx + r * 0.62, cy - r * 0.30)], darken(col, 0.2))


def cable(f: Frame, a, b, sag=8.0, col=(40, 37, 32)):
    """Sagging hoist cable between two screen points, with a lit edge."""
    pts = []
    for i in range(9):
        t = i / 8.0
        x = a[0] + (b[0] - a[0]) * t
        y = a[1] + (b[1] - a[1]) * t + math.sin(t * math.pi) * sag
        pts.append((x, y))
    f.line(pts, col, 2)
    f.line([(x - 0.6, y - 0.6) for x, y in pts], lighten(col, 0.22), 1)


def ladder(f: Frame, x, y, z0, z1, col=STEEL):
    a, b = f.p(x, y, z0), f.p(x, y, z1)
    f.line([a, b], darken(col, 0.55), 1)
    f.line([(a[0] + 3, a[1]), (b[0] + 3, b[1])], darken(col, 0.42), 1)
    n = max(2, int(abs(a[1] - b[1]) // 3.2))
    for i in range(n):
        y0 = a[1] + (b[1] - a[1]) * (i + 0.5) / n
        f.line([(a[0], y0), (a[0] + 3, y0)], lighten(col, 0.18), 1)


def smoke_puff(f: Frame, x, y, r, alpha=110, rng=None):
    rng = rng or f.rng
    pts = []
    for i in range(9):
        a = math.tau * i / 9
        rr = r * (0.66 + rng.random() * 0.44)
        pts.append((x + math.cos(a) * rr, y + math.sin(a) * rr * 0.78))
    f.poly(pts, SMOKE_D + (clamp8(alpha),))
    f.poly([(x - r * 0.5, y - r * 0.2), (x - r * 0.1, y - r * 0.6),
            (x + r * 0.4, y - r * 0.4), (x + r * 0.2, y + r * 0.2)],
           SMOKE + (clamp8(alpha * 0.65),))
    f.line([(x - r * 0.4, y - r * 0.35), (x - r * 0.1, y - r * 0.5)],
           SMOKE_L + (clamp8(alpha * 0.55),), 2)


def rounded_pts(x0, y0, x1, y1, cut):
    cut = min(cut, (x1 - x0) * 0.4, (y1 - y0) * 0.4)
    return [(x0 + cut, y0), (x1 - cut, y0), (x1, y0 + cut), (x1, y1 - cut),
            (x1 - cut, y1), (x0 + cut, y1), (x0, y1 - cut), (x0, y0 + cut)]


def silo(f: Frame, cx, cy, r, z0, z1, col=STEEL, house_band=True, damaged=False):
    """Tall steel silo with vertical straps, weld seams and a riveted dome."""
    sx = f.cx + cx
    x0, x1 = sx - r, sx + r
    yb = f.cy + cy - z0 * RISE
    yt = f.cy + cy - z1 * RISE

    mask = Image.new("L", (f.w, f.h), 0)
    md = ImageDraw.Draw(mask)
    md.rectangle([x0, yt, x1, yb], fill=255)
    md.ellipse([x0, yt - r * 0.55, x1, yt + r * 0.5], fill=255)

    layer = Image.new("RGBA", (f.w, f.h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    deep, bright = darken(col, 0.58), lighten(col, 0.24)
    for px in range(int(x0), int(x1) + 1):
        tt = (px - x0) / max(1.0, x1 - x0)
        lit = math.cos((tt - 0.28) * math.pi * 1.06)
        c = mix(deep, bright, max(0.0, min(1.0, (lit + 0.65) / 1.65)))
        if 0.20 < tt < 0.30:
            c = mix(c, (246, 238, 214), 0.20)
        d.line([(px, yt - r * 0.5), (px, yb)], fill=c)

    # vertical steel straps, with a lit edge and rivets
    step = max(6, int(r * 0.42))
    for px in range(int(x0) + step, int(x1), step):
        d.line([(px, yt - r * 0.35), (px, yb)], fill=darken(col, 0.62))
        d.line([(px + 1, yt - r * 0.35), (px + 1, yb)], fill=lighten(col, 0.16))
        for yy in range(int(yt) + 4, int(yb) - 2, 9):
            d.rectangle([px + 3, yy, px + 3, yy + 1], fill=(210, 201, 181))
            d.point((px + 3, yy + 1), fill=(44, 40, 34))

    # horizontal weld seams
    for k in range(1, 5):
        yy = yt + (yb - yt) * k / 5.0
        d.line([(x0, yy), (x1, yy)], fill=(46, 43, 38))
        d.line([(x0, yy - 1), (x1, yy - 1)], fill=(148, 142, 127))

    # soot under the dome and house band near the shoulder
    d.polygon([(x0, yt), (x1, yt), (x1, yt + r * 0.30), (x0, yt + r * 0.30)],
              fill=(38, 34, 30, 70))
    if house_band:
        by0 = yt + (yb - yt) * 0.16
        by1 = yt + (yb - yt) * 0.30
        d.rectangle([x0, by0, x1, by1], fill=MAGENTA)
        d.rectangle([x0, by1 - 2, x1, by1], fill=MAGENTA_D)
        d.line([(x0, by0), (x1, by0)], fill=MAGENTA_L)
        d.line([(x0, by0 + 2), (x1, by0 + 2)], fill=mix(MAGENTA, MAGENTA_L, 0.35))
        xx = x0 + 3
        while xx < x1 - 2:
            if f.rng.random() < 0.55:
                d.line([(xx, by0 + 1), (xx, by1 - 1)], fill=MAGENTA_D)
            xx += f.rng.randint(2, 7)
        for px in range(int(x0) + 4, int(x1) - 2, 8):
            d.point((px, by0 + 3), fill=(54, 6, 40))
            d.point((px, by1 - 4), fill=(54, 6, 40))
    layer.putalpha(mask)
    f.s = Image.alpha_composite(f.s, layer)
    f.sd = ImageDraw.Draw(f.s)

    # riveted dome cap, stacked in hard ellipse steps
    steps = 6
    for i in range(steps):
        k = 1.0 - i / float(steps)
        yy = yt - i * 1.8 - r * 0.10
        rr = r * math.sqrt(max(0.0, 1.0 - (i / float(steps)) ** 2)) * 1.02
        f.poly([(sx + math.cos(a) * rr, yy + math.sin(a) * rr * 0.26)
                for a in np.linspace(0, math.tau, 20)],
               mix(lighten(col, 0.18), darken(col, 0.42), i / (steps + 1.0)))
    f.line([(x0 + 2, yt - r * 0.18), (x1 - 3, yt - r * 0.18)], (22, 20, 17))
    f.line([(x0 + 3, yt - r * 0.18 - 1), (x1 - 4, yt - r * 0.18 - 1)], lighten(col, 0.30))
    f.poly([(sx - 4, yt - r * 0.30), (sx + 3, yt - r * 0.34),
            (sx + 5, yt - r * 0.24), (sx - 3, yt - r * 0.20)], (52, 56, 58))
    f.line([(sx - 3, yt - r * 0.30), (sx + 3, yt - r * 0.32)], (152, 156, 158))

    # grime bleeding from the dome and the house band
    for px in (sx - r * 0.55, sx - r * 0.05, sx + r * 0.45):
        rust_streak(f, px, yt + 2, (yb - yt) * 0.33, 1 if not damaged else 2)
    ladder(f, cx + r * 0.62, cy, z0, z1 - 4)
    if damaged:
        hx, hy = sx - r * 0.10, yb - (yb - yt) * 0.52
        f.poly([(hx - 7, hy - 5), (hx + 2, hy - 9), (hx + 8, hy - 2),
                (hx + 4, hy + 7), (hx - 5, hy + 5)], (24, 21, 18))
        f.poly([(hx - 4, hy - 3), (hx + 1, hy - 6), (hx + 5, hy - 1),
                (hx + 2, hy + 4), (hx - 3, hy + 3)], (11, 10, 9))
        for i in range(3):
            f.line([(hx + f.rng.randint(-6, 6), hy + f.rng.randint(-5, 5)),
                    (hx + f.rng.randint(-16, 16), hy + f.rng.randint(-12, 12))], (30, 26, 21))


def chimney(f: Frame, cx, cy, r, z0, z1, col=STEEL_D, damaged=False):
    """Tapered, banded smokestack. Returns the top-centre screen point."""
    sx = f.cx + cx
    x0, x1 = sx - r, sx + r
    yb = f.cy + cy - z0 * RISE
    yt = f.cy + cy - z1 * RISE
    top_r = r * 0.80
    mask_pts = [(x0, yb), (x0 + r - top_r, yt), (x1 - r + top_r, yt), (x1, yb)]
    mask = f.mask_of(mask_pts)
    layer = Image.new("RGBA", (f.w, f.h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for px in range(int(x0), int(x1) + 1):
        tt = (px - x0) / max(1.0, x1 - x0)
        lit = math.cos((tt - 0.30) * math.pi)
        d.line([(px, yt), (px, yb)], fill=mix(darken(col, 0.52), lighten(col, 0.22),
                                             max(0.0, lit)))
    for k in range(5):
        yy = yt + (yb - yt) * (k + 0.5) / 5.0
        d.line([(x0, yy), (x1, yy)], fill=(40, 37, 32))
        d.line([(x0, yy - 1), (x1, yy - 1)], fill=(156, 148, 130))
        for px in range(int(x0) + 3, int(x1) - 2, 7):
            d.point((px, yy + 1), fill=(28, 26, 23))
    layer.putalpha(mask)
    f.s = Image.alpha_composite(f.s, layer)
    f.sd = ImageDraw.Draw(f.s)
    f.poly([(x0 + 1, yt), (x1 - 1, yt), (x1 - 2, yt + 2), (x0 + 2, yt + 2)], (22, 20, 18))
    f.poly([(x0 + 2, yt + 2), (x1 - 2, yt + 2), (x1 - 3, yt + 4), (x0 + 3, yt + 4)], (56, 52, 45))
    f.poly([(x0 + 3, yt), (x1 - 3, yt), (x1 - 6, yt + 1), (x0 + 6, yt + 1)], (96, 90, 78))
    ladder(f, cx - r * 0.55, cy, z0, z1 - 3)
    rust_streak(f, sx - r * 0.2, yt + 2, (yb - yt) * 0.6, 2)
    if damaged:
        f.poly([(x0 + 2, yt + (yb - yt) * 0.55), (x1 - 3, yt + (yb - yt) * 0.50),
                (x1 - 5, yt + (yb - yt) * 0.68), (x0 + 5, yt + (yb - yt) * 0.72)], (34, 30, 25))
    return (sx, yt)


def intake(f: Frame, cx, cy, r, z0, z1, phase, glow, damaged=False):
    """One giant curved air-intake turbine: domed shell, dark vent grille, fan."""
    sx = f.cx + cx
    x0, x1 = sx - r, sx + r
    yb = f.cy + cy - z0 * RISE
    yt = f.cy + cy - z1 * RISE

    # scoop silhouette: barrel body flaring into a big domed shoulder
    shell = []
    for i in range(9):
        t = i / 8.0
        shell.append((sx + r * (0.80 + 0.20 * t), yb + (yt - yb) * t))
    for a in np.linspace(0.0, math.pi, 13):
        shell.append((sx + math.cos(a) * r, yt - math.sin(a) * r * 0.62))
    for i in range(9):
        t = 1.0 - i / 8.0
        shell.append((sx - r * (0.80 + 0.20 * t), yb + (yt - yb) * t))
    mask = Image.new("L", (f.w, f.h), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(shell, fill=255)
    md.rectangle([sx - r * 0.80, yb - 3, sx + r * 0.80, yb], fill=255)

    layer = Image.new("RGBA", (f.w, f.h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    deep, bright = darken(STEEL, 0.62), lighten(STEEL, 0.30)
    for px in range(int(x0), int(x1) + 1):
        tt = (px - x0) / max(1.0, x1 - x0)
        lit = math.cos((tt - 0.26) * math.pi * 1.10)
        c = mix(deep, bright, max(0.0, min(1.0, (lit + 0.60) / 1.60)))
        if 0.16 < tt < 0.26:
            c = mix(c, (240, 232, 208), 0.24)
        d.line([(px, yt - r * 0.45), (px, yb)], fill=c)

    # curved shell ribs
    for frac in (0.18, 0.40, 0.62, 0.84):
        px = int(x0 + (x1 - x0) * frac)
        d.line([(px, yt - r * 0.20), (px + 2, yb - 3)], fill=darken(STEEL, 0.48))
        d.line([(px + 1, yt - r * 0.20), (px + 3, yb - 3)], fill=lighten(STEEL, 0.10))
    for yy in (yt + r * 0.35, yt + r * 0.9):
        d.line([(x0 + 1, yy), (x1 - 1, yy)], fill=(34, 31, 27))
        d.line([(x0 + 1, yy - 1), (x1 - 2, yy - 1)], fill=(142, 136, 122))

    # painted house sash around the dome shoulder, clipped to the shell
    sash = [(x0 + 4, yt + r * 0.10), (x1 - 4, yt + r * 0.04),
            (x1 - 6, yt + r * 0.26), (x0 + 6, yt + r * 0.30)]
    d.polygon(sash, fill=MAGENTA)
    d.line([sash[0], sash[1]], fill=MAGENTA_L)
    for i in range(4):
        hx = x0 + 8 + i * (x1 - x0 - 16) * f.rng.random()
        d.line([(hx, sash[0][1] + 1), (hx, sash[0][1] + 6)], fill=MAGENTA_D)
    layer.putalpha(mask)
    f.s = Image.alpha_composite(f.s, layer)
    f.sd = ImageDraw.Draw(f.s)

    # dome cap with ribs converging on a bolted hatch
    steps = 6
    for i in range(steps):
        yy = yt - i * 2.2 - r * 0.08
        rr = r * math.sqrt(max(0.0, 1.0 - (i / float(steps)) ** 2)) * 1.01
        f.poly([(sx + math.cos(a) * rr, yy + math.sin(a) * rr * 0.24)
                for a in np.linspace(0, math.tau, 18)],
               mix(lighten(STEEL, 0.20), darken(STEEL, 0.44), i / (steps + 1.0)))
    f.line([(sx - r * 0.55, yt - r * 0.30), (sx, yt - r * 0.62)], (30, 27, 23))
    f.line([(sx + r * 0.55, yt - r * 0.30), (sx, yt - r * 0.62)], (30, 27, 23))
    f.poly(rounded_pts(sx - 4, yt - r * 0.58, sx + 4, yt - r * 0.44, 2), (54, 58, 60))
    f.line([(sx - 3, yt - r * 0.55), (sx + 2, yt - r * 0.55)], (154, 158, 160))

    # recessed front grille facing the camera
    gw, gh = r * 1.48, (yb - yt) * 0.46
    gx, gy = sx, yt + (yb - yt) * 0.56
    gx0, gy0, gx1, gy1 = gx - gw * 0.5, gy - gh * 0.5, gx + gw * 0.5, gy + gh * 0.5
    f.poly(rounded_pts(gx0 - 3, gy0 - 3, gx1 + 3, gy1 + 3, 4), darken(STEEL, 0.55))
    f.poly(rounded_pts(gx0, gy0, gx1, gy1, 3), (8, 14, 15))
    fan_r = gh * 0.42
    ang0 = phase * math.tau
    for b in range(5):
        aa = ang0 + math.tau * b / 5
        tip = (gx + math.cos(aa) * fan_r, gy + math.sin(aa) * fan_r * 0.92)
        side = (gx + math.cos(aa + 0.85) * fan_r * 0.32, gy + math.sin(aa + 0.85) * fan_r * 0.30)
        other = (gx + math.cos(aa - 0.85) * fan_r * 0.32, gy + math.sin(aa - 0.85) * fan_r * 0.30)
        f.poly([(gx, gy), side, tip, other], (40, 62, 61) if not damaged else (46, 43, 38))
    f.poly([(gx + math.cos(a) * 3.5, gy + math.sin(a) * 3.5) for a in np.linspace(0, math.tau, 8)],
           (96, 100, 96))
    # louvres in front of the fan, glowing with the pulse
    for i in range(6):
        yy = gy0 + (i + 0.5) * gh / 6.0
        f.line([(gx0 + 2, yy), (gx1 - 2, yy)], (22, 30, 30))
        f.line([(gx0 + 2, yy + 1), (gx1 - 2, yy + 1)], mix(CYAN_D, CYAN, glow * 0.85))
    f.line([(gx0, gy1), (gx1, gy1)], (60, 64, 60))
    for a in np.linspace(0, math.tau, 13)[:-1]:
        f.line([(gx + math.cos(a) * (gw * 0.55), gy + math.sin(a) * (gh * 0.58)),
                (gx + math.cos(a) * (gw * 0.59), gy + math.sin(a) * (gh * 0.63))], (154, 158, 156))

    # indicator lamp and grime
    beacon(f, cx + r * 0.70, cy, z1 - 10, CYAN, on=glow > 0.55, r=2)
    rust_streak(f, x0 + 3, yt + 4, (yb - yt) * 0.55, 2)
    rust_streak(f, x1 - 5, yt + 6, (yb - yt) * 0.40, 1)
    if damaged:
        f.poly([(x0 + 3, yb - (yb - yt) * 0.62), (x0 + r * 0.6, yb - (yb - yt) * 0.70),
                (x0 + r * 0.7, yb - (yb - yt) * 0.42), (x0 + 5, yb - (yb - yt) * 0.38)],
               (32, 28, 23))
        f.line([(x0 + 4, yb - (yb - yt) * 0.60), (x0 + r * 0.6, yb - (yb - yt) * 0.68)], (84, 74, 58))


# ---------------------------------------------------------------- yard
def render_cy(f: Frame):
    draw_pad(f, 3, 3, f.rng)
    step = int(round(f.t * FRAMES)) % FRAMES
    sway = math.sin(f.t * math.tau) * 2.0

    contact_shadow(f, -56, -54, 74, 58, 6)
    contact_shadow(f, 4, 6, 50, 48, 5)
    contact_shadow(f, 32, -50, 14, 14, 4)

    # --- main assembly bunker: two heavy tiers plus a command cupola
    sb, wb, tb, eb = box(f, -56, -54, 0, 74, 56, 38, GUN)
    roof_plate(f, 38, -52, -50, 68, 48, GUN, inset=3)
    for i in range(3):
        rx = -46 + i * 22
        box(f, rx, -46, 38, 8, 26, 4, (50, 55, 58), taper=1.2, seams=False, rivets=False)
        for k in range(4):
            f.line([f.p(rx + 1, -44 + k * 6, 42), f.p(rx + 7, -44 + k * 6, 42)],
                   (134, 140, 141) if k % 2 == 0 else (64, 69, 72))
    box(f, -48, -22, 38, 16, 12, 7, STEEL, taper=1.4, seams=False, rivets=False)
    grating(f, -46, -20, 12, 6, (30, 33, 35), slats=3)
    pipe(f, [(6, -48, 38), (6, -48, 45), (16, -48, 45), (16, -48, 38)], (126, 121, 111), 1)
    for i in range(3):
        f.poly([f.p(-48 + i * 24, -9, 38.3), f.p(-36 + i * 24, -9, 38.3),
                f.p(-36 + i * 24, -7, 38.3), f.p(-48 + i * 24, -7, 38.3)],
               HAZ_Y if i % 2 == 0 else HAZ_K)
    # grimy lower skirt and utility doors on the south face
    f.poly(sb.quad(0.04, 0.62, 0.34, 0.96), (42, 40, 36))
    f.poly(sb.quad(0.06, 0.64, 0.32, 0.92), (74, 72, 64))
    for i in range(4):
        f.line([sb.pt(0.08, 0.70 + i * 0.05), sb.pt(0.30, 0.70 + i * 0.05)], (46, 45, 41))
    f.poly(sb.quad(0.42, 0.74, 0.60, 0.96), (18, 17, 15))
    f.line([sb.pt(0.42, 0.74), sb.pt(0.60, 0.74)], (156, 148, 130), 2)
    hazard_face(f, sb, 0.66, 0.82, 0.96, 0.92, stripe_px=6)

    # --- upper tier with bolted house armour plates
    s2, w2, t2, e2 = box(f, -48, -46, 38, 54, 40, 20, STEEL_D)
    roof_plate(f, 58, -45, -43, 48, 34, STEEL_D, inset=2.5)
    armor_plate(f, s2, 0.06, 0.14, 0.46, 0.62)
    armor_plate(f, s2, 0.56, 0.14, 0.94, 0.62)
    banner(f, s2, 0.22, 0.34, 0.68, 0.98, torn=True)
    banner(f, s2, 0.66, 0.78, 0.68, 0.98, torn=True)
    f.line([s2.pt(0.50, 0.10), s2.pt(0.50, 0.66)], (34, 31, 27))
    for i in range(3):
        box(f, -40 + i * 15, -40, 58, 7, 9, 4, STEEL, taper=1.1, seams=False, rivets=False)

    # --- command cupola, third tier, glass slit and antenna
    sc, wc, tc, ec = box(f, -34, -38, 58, 24, 22, 16, GUN)
    roof_plate(f, 74, -32, -36, 20, 18, GUN, inset=2)
    f.poly(sc.quad(0.18, 0.26, 0.82, 0.44), GLASS)
    f.line([sc.pt(0.20, 0.28), sc.pt(0.78, 0.28)], GLASS_L, 2)
    f.line([sc.pt(0.30, 0.26), sc.pt(0.30, 0.44)], (24, 26, 27))
    f.line([sc.pt(0.62, 0.26), sc.pt(0.62, 0.44)], (24, 26, 27))
    f.line([f.p(-22, -26, 74), f.p(-22, -26, 92)], (52, 50, 44), 1)
    f.line([f.p(-23, -26, 90), f.p(-18, -26, 92)], (52, 50, 44), 1)
    beacon(f, -22, -26, 94, RED, on=step in (0, 2), r=2)

    # --- crane tower: hazard-striped gantry leg with visible gears
    ts, tw, tt, te = box(f, 34, -46, 0, 12, 12, 70, GUN, taper=1.0, seams=False)
    for i in range(5):
        z = 4 + i * 6
        f.poly([f.p(34, -34, z), f.p(46, -34, z), f.p(46, -34, z + 3.5), f.p(34, -34, z + 3.5)],
               HAZ_Y if i % 2 == 0 else HAZ_K)
    for i in range(5):
        z = 38 + i * 6
        f.line([f.p(34, -34, z), f.p(46, -34, z + 6)], (40, 34, 22))
        f.line([f.p(46, -34, z), f.p(34, -34, z + 6)], (40, 34, 22))
    for i in range(6):
        f.line([f.p(34.5, -34, 2 + i * 4.6), f.p(45.5, -34, 2 + i * 4.6)], (152, 146, 130))
    cog(f, f.cx + 43, f.cy - 46 - 62 * RISE, 5, phase=f.t * math.tau * 0.25, col=STEEL_L)
    cog(f, f.cx + 43, f.cy - 46 - 53 * RISE, 4, phase=-f.t * math.tau * 0.35, col=STEEL)
    cable(f, f.p(43, -40, 58), f.p(43, -40, 66), sag=0.0, col=(32, 30, 26))

    # cab and counterweight at the top of the leg
    cs, cw, ct, ce = box(f, 30, -50, 70, 17, 15, 10, STEEL_D, taper=1.2, seams=False)
    f.poly(cs.quad(0.10, 0.22, 0.90, 0.74), GLASS)
    f.line([cs.pt(0.12, 0.24), cs.pt(0.86, 0.24)], GLASS_L, 2)
    f.poly(cs.quad(0.10, 0.80, 0.90, 0.94), HAZ_Y)
    box(f, 47, -50, 62, 10, 12, 12, GUN, taper=1.2, seams=False, rivets=False)

    # --- jib truss reaching over the assembly bay, on a second light leg
    box(f, -24, -42, 58, 4, 4, 12, STEEL, taper=0.5, seams=False, rivets=False)
    cable(f, f.p(-22, -40, 70), f.p(-22, -40, 58), sag=0.0, col=(34, 31, 26))
    jy, jz = -40, 64
    js, jw, jt, je = box(f, -34, jy, jz, 82, 8, 8, GUN, taper=0.8, seams=False)
    n = 8
    for i in range(n):
        u0, u1 = i / n, (i + 1) / n
        f.line([js.pt(u0, 0.12), js.pt(u1, 0.88)], (38, 34, 24))
        f.line([js.pt(u0, 0.88), js.pt(u1, 0.12)], (38, 34, 24))
    f.line([js.pt(0, 0.04), js.pt(1, 0.04)], (240, 208, 126))
    hazard_face(f, Face(f.p(-34, jy + 8, jz + 4), f.p(48, jy + 8, jz + 4),
                        f.p(48, jy + 8, jz + 1), f.p(-34, jy + 8, jz + 1)),
                0, 0, 1, 1, stripe_px=6)
    for x in (-26, 12):
        f.line([f.p(x, jy + 4, jz + 8), f.p(x, jy + 4, jz + 14)], (38, 35, 30), 1)
    cable(f, f.p(38, -44, 82), f.p(-30, -36, jz + 8), sag=7.0)
    cable(f, f.p(38, -44, 82), f.p(-4, -36, jz + 8), sag=5.0)
    # dangling house banner from the jib
    bx = -24
    bpts = [(bx, f.cy - 36 - (jz - 8) * RISE), (bx + 12, f.cy - 36 - (jz - 8) * RISE),
            (bx + 12, f.cy - 36 - (jz - 30) * RISE), (bx + 6, f.cy - 36 - (jz - 34) * RISE),
            (bx, f.cy - 36 - (jz - 30) * RISE)]
    f.poly(bpts, MAGENTA)
    f.poly([bpts[1], (bpts[2][0] - 3, bpts[2][1]), (bpts[4][0] + 5, bpts[4][1]), bpts[4]], MAGENTA_D)
    f.line([bpts[0], bpts[1]], (44, 7, 35), 2)
    f.poly([(bx + 4, bpts[0][1] + 8), (bx + 8, bpts[0][1] + 12),
            (bx + 4, bpts[0][1] + 16), (bx, bpts[0][1] + 12)], MAGENTA_L)

    # --- assembly bay, front-right
    bb, bw, bt, be = box(f, 4, 6, 0, 50, 48, 26, STEEL)
    roof_plate(f, 26, 7, 9, 44, 42, STEEL, inset=3)
    grating(f, 12, 14, 20, 9, (30, 33, 35), slats=4)
    box(f, 32, 10, 26, 8, 8, 4, STEEL_D, taper=1.2, seams=False, rivets=False)
    # ribbed shutter with a worn hazard frame and house header
    f.poly(bb.quad(0.10, 0.22, 0.90, 0.94), (12, 12, 11))
    f.poly(bb.quad(0.13, 0.27, 0.87, 0.91), (45, 47, 47))
    for i in range(8):
        v = 0.27 + i * 0.080
        f.line([bb.pt(0.13, v), bb.pt(0.87, v)], (76, 79, 79))
        f.line([bb.pt(0.13, v + 0.012), bb.pt(0.87, v + 0.012)], (24, 25, 25))
    hazard_face(f, bb, 0.08, 0.10, 0.92, 0.19, stripe_px=7)
    hazard_face(f, bb, 0.08, 0.945, 0.92, 0.985, stripe_px=7)
    armor_plate(f, bb, 0.015, 0.26, 0.085, 0.92, bolts=False)
    armor_plate(f, bb, 0.915, 0.26, 0.985, 0.92, bolts=False)
    banner(f, bb, 0.32, 0.68, 0.005, 0.09, emblem=True)
    f.line([bb.pt(0.10, 0.22), bb.pt(0.90, 0.22)], (150, 144, 130), 2)
    box(f, 0, 38, 0, 6, 16, 13, CONCRETE, taper=1.2, seams=False, rivets=False)
    box(f, 52, 38, 0, 6, 16, 13, CONCRETE, taper=1.2, seams=False, rivets=False)
    ladder(f, 49, 30, 2, 24)

    # hoist cable and hook above the bay, swaying between frames
    hx = -4 + sway
    cable(f, f.p(hx, jy + 4, jz - 2), f.p(hx + sway * 0.4, jy + 4, 30), sag=1.0)
    hxp, hyp = f.p(hx + sway * 0.4, jy + 4, 30)
    f.poly([(hxp - 3, hyp - 2), (hxp + 3, hyp - 2), (hxp + 2, hyp + 3), (hxp - 2, hyp + 3)],
           (58, 54, 47))
    f.line([(hxp, hyp + 3), (hxp, hyp + 7)], (28, 26, 22), 2)
    f.poly([(hxp - 4, hyp + 8), (hxp + 4, hyp + 8), (hxp + 2, hyp + 11), (hxp - 2, hyp + 11)],
           (74, 68, 58))

    # auxiliary generator house fills the south-west bay of the pad
    gs, gw_, gt, ge = box(f, -52, 8, 0, 22, 24, 15, GUN, taper=1.4, seams=False)
    roof_plate(f, 15, -50, 10, 18, 20, GUN, inset=2)
    grating(f, -48, 13, 11, 7, (28, 31, 33), slats=3)
    f.poly(gs.quad(0.10, 0.24, 0.62, 0.78), (30, 30, 27))
    for i in range(4):
        f.line([gs.pt(0.14, 0.30 + i * 0.11), gs.pt(0.58, 0.30 + i * 0.11)], (88, 84, 70))
    hazard_face(f, gs, 0.72, 0.20, 0.96, 0.30, stripe_px=5)
    pipe(f, [(-36, 14, 15), (-36, 14, 24), (-20, 14, 24), (-20, 14, 30)], (118, 110, 94), 1)
    for i in range(3):
        f.line([f.p(-44 + i * 5, 8, 3), f.p(-44 + i * 5, 8, 13)], (58, 54, 46))

    # supplies in the south-west corner, still inside the pad
    contact_shadow(f, -56, 30, 24, 22, 3, 50)
    box(f, -54, 36, 0, 15, 12, 9, RUST, taper=1.6, seams=False)
    f.line([f.p(-54, 48, 5), f.p(-39, 48, 5)], (148, 92, 50))
    box(f, -36, 40, 0, 11, 10, 6, (104, 96, 76), taper=1.2, seams=False, rivets=False)
    for i in range(2):
        f.poly([(f.cx - 30 + i * 9, f.cy + 30), (f.cx - 24 + i * 9, f.cy + 30),
                (f.cx - 24 + i * 9, f.cy + 41), (f.cx - 30 + i * 9, f.cy + 41)], RUST_D)
        f.line([(f.cx - 30 + i * 9, f.cy + 33), (f.cx - 24 + i * 9, f.cy + 33)], (156, 98, 55))
        f.line([(f.cx - 30 + i * 9, f.cy + 38), (f.cx - 24 + i * 9, f.cy + 38)], (156, 98, 55))

    # grime under every eave and around the crane foot
    for px in (-50, -32, -12, 8, 34):
        rust_streak(f, f.cx + px, f.cy - 8, 18 + (px % 7), 1)
    rust_streak(f, f.cx + 36, f.cy - 10, 22, 2)

    # --- battle damage
    if f.damaged:
        hx0, hy0 = bb.pt(0.36, 0.52)
        f.poly([(hx0 - 9, hy0 - 6), (hx0 + 4, hy0 - 10), (hx0 + 11, hy0 - 2),
                (hx0 + 7, hy0 + 8), (hx0 - 6, hy0 + 6)], (23, 20, 17))
        f.poly([(hx0 - 5, hy0 - 2), (hx0 + 3, hy0 - 5), (hx0 + 7, hy0 + 1),
                (hx0 + 2, hy0 + 5), (hx0 - 4, hy0 + 3)], (9, 8, 7))
        f.poly([f.p(-30, -40, 58.3), f.p(-14, -40, 58.3), f.p(-18, -40, 48), f.p(-30, -40, 50)],
               (52, 48, 42))
        for i in range(5):
            f.line([f.p(-46 + i * 9, -46, 57), f.p(-46 + i * 9, -46, 42)], (20, 18, 16, 70))
        # snapped hoist cable whipping off the jib
        cable(f, f.p(-12, jy + 4, jz - 2), f.p(-30, jy + 6, 44), sag=5.0, col=(30, 28, 24))
        for i in range(4):
            f.line([(f.cx - 10 + f.rng.randint(-6, 10), f.cy + 18 + f.rng.randint(-8, 8)),
                    (f.cx - 24 + f.rng.randint(-10, 18), f.cy + 26 + f.rng.randint(-12, 10))],
                   (32, 27, 22))


# ---------------------------------------------------------------- refinery
def render_refinery(f: Frame):
    draw_pad(f, 3, 3, f.rng)
    step = int(round(f.t * FRAMES)) % FRAMES

    # --- worn harvester apron baked into the pad
    ax0, ay0, ax1, ay1 = -52, 26, 52, 56
    f.b_poly([f.p(ax0, ay0), f.p(ax1, ay0), f.p(ax1, ay1), f.p(ax0, ay1)], (112, 106, 92))
    f.b_poly([f.p(ax0 + 2, ay0 + 2), f.p(ax1 - 2, ay0 + 2),
              f.p(ax1 - 2, ay1 - 2), f.p(ax0 + 2, ay1 - 2)], (101, 96, 83))
    for _ in range(30):
        px = f.cx + ax0 + 3 + f.rng.uniform(0, ax1 - ax0 - 6)
        py = f.cy + ay0 + 2 + f.rng.uniform(0, ay1 - ay0 - 4)
        f.bd.point((px, py), fill=(62, 59, 51))
        if f.rng.random() < 0.4:
            f.bd.rectangle([px, py, px + 2, py + 1], fill=(53, 50, 43))
    # tread marks curving into the bay
    for sx in (-14, 14):
        for i in range(5):
            yy = 30 + i * 5
            f.b_line([f.p(sx + i * 0.6 - 3, yy), f.p(sx + i * 0.6 - 3, yy + 3)], (65, 61, 52))
            f.b_line([f.p(sx + i * 0.6 + 4, yy), f.p(sx + i * 0.6 + 4, yy + 3)], (65, 61, 52))
    # faded chevrons aimed at the dock
    for k in range(3):
        cy_ = 31 + k * 7
        for sx in (-1, 1):
            pts = [f.p(-2 + sx * 18, cy_ + 4), f.p(-2 + sx * 18, cy_),
                   f.p(-2, cy_ - 3), f.p(-2, cy_ + 1)]
            f.b_poly(pts, (156, 128, 50))
            f.b_line(pts, (96, 77, 31))
            f.b_poly([pts[0], pts[1], (pts[1][0], pts[1][1] + 1), (pts[0][0], pts[0][1] + 1)],
                     (104, 84, 36))
    # rusted hazard lip along the loading edge
    for i in range(9):
        x = ax0 + 2 + i * 11
        f.b_poly([f.p(x, ay0), f.p(x + 6, ay0), f.p(x + 6, ay0 + 3), f.p(x, ay0 + 3)],
                 HAZ_Y if i % 2 == 0 else HAZ_K)
    for _ in range(4):
        px = f.cx + f.rng.uniform(ax0 + 4, ax1 - 10)
        py = f.cy + f.rng.uniform(ay0 + 5, ay1 - 5)
        f.bd.rectangle([px, py, px + f.rng.uniform(3, 9), py + f.rng.uniform(2, 5)],
                       fill=(38, 34, 28) + (70,))
    f.b_line([f.p(ax0, ay1), f.p(ax1, ay1)], (40, 37, 31), 2)

    contact_shadow(f, -52, -48, 42, 46, 6)
    contact_shadow(f, 4, -52, 50, 46, 6)
    contact_shadow(f, -50, 14, 40, 26, 5)

    # --- rear silo, then the processor block behind it
    silo(f, -30, -30, 20, 0, 82, STEEL, damaged=f.damaged)
    ps, pw, pt, pe = box(f, 6, -52, 0, 46, 44, 34, STEEL_D)
    roof_plate(f, 34, 9, -49, 40, 38, STEEL_D, inset=2.5)
    for i in range(3):
        box(f, 12 + i * 12, -48, 34, 8, 10, 5, (68, 72, 72), taper=1.2, seams=False, rivets=False)
        grating(f, 13 + i * 12, -46, 6, 5, (28, 31, 33), slats=3)
    f.poly(ps.quad(0.08, 0.28, 0.48, 0.90), (14, 13, 12))
    for i in range(6):
        v = 0.31 + i * 0.095
        f.line([ps.pt(0.10, v), ps.pt(0.46, v)], (66, 65, 60))
        f.line([ps.pt(0.10, v + 0.012), ps.pt(0.46, v + 0.012)], (26, 25, 22))
    f.line([ps.pt(0.08, 0.28), ps.pt(0.48, 0.28)], (146, 139, 124), 2)
    # furnace glow behind a heavy grille
    f.poly(ps.quad(0.56, 0.42, 0.94, 0.88), (35, 26, 18))
    for i in range(4):
        yy = ps.pt(0.0, 0.48 + i * 0.10)
        f.line([ps.pt(0.58, 0.48 + i * 0.10), ps.pt(0.92, 0.48 + i * 0.10)],
               (86, 54, 26))
        f.line([ps.pt(0.58, 0.49 + i * 0.10), ps.pt(0.92, 0.49 + i * 0.10)],
               mix(AMBER, (255, 226, 150), 0.35))
    hazard_face(f, ps, 0.55, 0.31, 0.95, 0.40, stripe_px=6)
    banner(f, ps, 0.10, 0.28, 0.06, 0.24, emblem=True)

    # chimney rising off the processor roof, with pixel smoke
    top = chimney(f, 40, -38, 7, 34, 76, STEEL_D, damaged=f.damaged)
    for i in range(6):
        ph = (f.t + i * 0.18) % 1.0
        sx = top[0] + 2 + ph * 17 + math.sin((f.t + i * 0.3) * math.tau) * 3.0
        sy = top[1] - 4 - ph * 26.0
        smoke_puff(f, sx, sy, 3.0 + ph * 6.5, alpha=int(150 * (1.0 - ph)) + 34)

    # --- front silo and the loading dock
    silo(f, -32, 14, 18, 0, 68, STEEL, damaged=False)
    ds_, dw, dt, de = box(f, 8, -4, 0, 42, 28, 18, STEEL_D)
    roof_plate(f, 18, 10, -2, 38, 24, STEEL_D, inset=2)
    grating(f, 16, 2, 14, 7, (28, 31, 33), slats=3)
    # half-raised shutter and dark bay mouth
    f.poly(ds_.quad(0.12, 0.20, 0.84, 0.86), (15, 14, 12))
    f.poly(ds_.quad(0.16, 0.20, 0.80, 0.52), (43, 45, 44))
    for i in range(5):
        v = 0.23 + i * 0.055
        f.line([ds_.pt(0.16, v), ds_.pt(0.80, v)], (76, 79, 78))
        f.line([ds_.pt(0.16, v + 0.014), ds_.pt(0.80, v + 0.014)], (26, 27, 25))
    f.line([ds_.pt(0.12, 0.20), ds_.pt(0.84, 0.20)], (146, 139, 123), 2)
    hazard_face(f, ds_, 0.10, 0.09, 0.86, 0.18, stripe_px=6)
    armor_plate(f, ds_, 0.86, 0.22, 0.97, 0.84, bolts=False)
    banner(f, ds_, 0.30, 0.66, 0.005, 0.08, emblem=True)
    # docking lamps
    for i in range(4):
        on = (i + step) % 3 == 0
        px, py = ds_.pt(0.18 + i * 0.20, 0.94)
        f.poly([(px - 1, py - 1), (px + 2, py - 1), (px + 2, py + 1), (px - 1, py + 1)],
               (238, 190, 70) if on else (88, 74, 36))

    # --- pipe bridge from both silos into the processor
    pipe(f, [(-40, -24, 54), (-18, -24, 62), (2, -24, 54), (10, -24, 44)], (116, 108, 92), 1)
    pipe(f, [(-44, 6, 32), (-18, 6, 40), (0, 6, 30), (12, 0, 26)], (112, 104, 88), 1)
    box(f, -12, -30, 0, 10, 12, 22, GUN, taper=1.4, seams=False, rivets=False)
    grating(f, -10, -28, 6, 7, (30, 33, 35), slats=3)
    for i in range(3):
        f.line([f.p(-9 + i * 3, -30, 22), f.p(-9 + i * 3, -30, 30)], (74, 68, 56))

    # --- spill and scorch on the apron
    f.b_overlay(lambda d: d.polygon(
        [f.p(-4, 44), f.p(4, 42), f.p(10, 48), f.p(3, 53), f.p(-6, 50)],
        fill=(150, 82, 24, 120)))
    for _ in range(5):
        px = f.cx + f.rng.uniform(-6, 12)
        py = f.cy + f.rng.uniform(44, 54)
        f.bd.rectangle([px, py, px + 1, py + 1], fill=(216, 152, 54))

    beacon(f, 34, 2, 24, AMBER, on=step in (0, 1), r=1)

    # --- battle damage
    if f.damaged:
        hx0, hy0 = ps.pt(0.66, 0.42)
        f.poly([(hx0 - 8, hy0 - 5), (hx0 + 5, hy0 - 9), (hx0 + 10, hy0 - 1),
                (hx0 + 5, hy0 + 7), (hx0 - 6, hy0 + 5)], (24, 21, 18))
        f.poly([(hx0 - 4, hy0 - 2), (hx0 + 3, hy0 - 5), (hx0 + 6, hy0 + 1),
                (hx0 + 2, hy0 + 4), (hx0 - 3, hy0 + 2)], (10, 9, 8))
        f.poly([f.p(30, -6, 18.4), f.p(44, -6, 18.4), f.p(40, -6, 9), f.p(28, -6, 12)],
               (54, 50, 43))
        for i in range(5):
            f.line([f.p(10 + i * 7, -4, 18.2), f.p(10 + i * 7, -4, 6)], (20, 18, 16, 80))
        for i in range(4):
            f.line([(f.cx - 12 + f.rng.randint(-8, 8), f.cy + 42 + f.rng.randint(-6, 6)),
                    (f.cx - 26 + f.rng.randint(-10, 16), f.cy + 48 + f.rng.randint(-8, 8))],
                   (34, 29, 23))


# ---------------------------------------------------------------- wind trap
def render_windtrap(f: Frame):
    draw_pad(f, 2, 3, f.rng)
    pulse = 0.38 + 0.62 * (0.5 + 0.5 * math.cos(f.t * math.tau))
    if f.damaged:
        pulse *= 0.35
    step = int(round(f.t * FRAMES)) % FRAMES

    contact_shadow(f, -28, -52, 56, 26, 5)
    contact_shadow(f, -36, -20, 72, 62, 6)

    # --- service deck the turbines stand on
    ds, dw, dt, de = box(f, -36, -54, 0, 72, 76, 8, GUN, taper=2.0)
    roof_plate(f, 8, -34, -52, 68, 72, GUN, inset=2.0)
    hazard_face(f, ds, 0.03, 0.10, 0.97, 0.17, stripe_px=6)
    for i in range(3):
        f.line([f.p(-28 + i * 22, -40, 8.4), f.p(-28 + i * 22, -12, 8.4)], (32, 36, 38))
    grating(f, -30, 24, 18, 9, (26, 29, 31), slats=4)
    grating(f, 12, 24, 18, 9, (26, 29, 31), slats=4)

    # --- rear exhaust shroud
    ss, sw, st, se = box(f, -28, -52, 0, 56, 24, 36, STEEL_D)
    roof_plate(f, 36, -26, -50, 52, 20, STEEL_D, inset=2)
    grating(f, -22, -50, 44, 15, (28, 31, 33), slats=5)
    f.poly(ss.quad(0.05, 0.58, 0.95, 0.66), MAGENTA)
    f.poly(ss.quad(0.05, 0.66, 0.95, 0.70), MAGENTA_D)
    hazard_face(f, ss, 0.06, 0.76, 0.94, 0.90, stripe_px=7)
    banner(f, ss, 0.36, 0.64, 0.10, 0.54, emblem=True)
    box(f, -34, -44, 36, 8, 8, 8, (70, 75, 77), taper=1.2, seams=False, rivets=False)
    box(f, 26, -44, 36, 8, 8, 8, (70, 75, 77), taper=1.2, seams=False, rivets=False)

    # --- central transformer mast and insulators
    box(f, -6, -34, 8, 12, 12, 38, GUN, taper=1.2, seams=False)
    for i in range(3):
        for j in range(2):
            px = -5 + j * 9 + i * 1
            f.poly([f.p(px, -34, 46 + i * 4), f.p(px + 2, -34, 46 + i * 4),
                    f.p(px + 2, -34, 48 + i * 4), f.p(px, -34, 48 + i * 4)],
                   (132, 124, 106) if (i + j) % 2 else (76, 72, 62))
    f.line([f.p(-1, -34, 58), f.p(-1, -34, 70)], (48, 44, 36), 1)
    beacon(f, -1, -34, 72, RED, on=step in (0, 2), r=2)

    # --- twin giant domed intake turbines
    intake(f, -20, -6, 18, 6, 88, f.t, pulse, damaged=f.damaged)
    intake(f, 20, 8, 17, 6, 82, f.t + 0.5, pulse, damaged=False)

    # --- heavy wiring draped from the mast to each turbine hub
    cable(f, f.p(-2, -34, 52), f.p(-34, -6, 54), sag=7.0, col=(28, 26, 23))
    cable(f, f.p(2, -34, 52), f.p(34, 8, 48), sag=6.0, col=(28, 26, 23))
    cable(f, f.p(-2, -34, 44), f.p(-30, -6, 40), sag=8.0, col=(34, 31, 27))
    cable(f, f.p(2, -34, 44), f.p(30, 8, 36), sag=7.0, col=(34, 31, 27))
    cable(f, f.p(-2, -34, 30), f.p(-34, -6, 22), sag=9.0, col=(36, 33, 28))
    cable(f, f.p(2, -34, 30), f.p(34, 8, 20), sag=8.0, col=(36, 33, 28))
    for hx, hy in (f.p(-34, -6, 54), f.p(34, 8, 48)):
        f.poly([(hx - 2, hy - 2), (hx + 2, hy - 2), (hx + 2, hy + 2), (hx - 2, hy + 2)],
               (92, 84, 68))
        f.line([(hx - 1, hy - 1), (hx + 1, hy - 1)], (170, 160, 136))

    # --- control box at the south edge, blinking indicators
    cs, cw, ct, ce = box(f, -26, 30, 0, 52, 20, 10, GUN, taper=1.6)
    f.poly(cs.quad(0.05, 0.16, 0.42, 0.80), (18, 22, 22))
    for i in range(3):
        on = (step + i) % 3 == 0
        px, py = cs.pt(0.11 + i * 0.10, 0.30)
        f.poly([(px - 1, py - 1), (px + 2, py - 1), (px + 2, py + 2), (px - 1, py + 2)],
               (112, 238, 224) if on else (26, 62, 60))
        if on:
            f.line([(px - 1, py - 1), (px - 1, py - 1)], (206, 255, 248))
    f.poly(cs.quad(0.50, 0.22, 0.92, 0.76), (28, 26, 22))
    for i in range(4):
        f.line([cs.pt(0.52, 0.28 + i * 0.12), cs.pt(0.90, 0.28 + i * 0.12)], (68, 64, 54))
    f.poly([cs.pt(0.58, 0.58), cs.pt(0.66, 0.56), cs.pt(0.66, 0.64), cs.pt(0.58, 0.66)],
           (146, 38, 30))
    hazard_face(f, cs, 0.04, 0.02, 0.96, 0.09, stripe_px=6)
    hazard_face(f, cs, 0.44, 0.82, 0.56, 0.98, stripe_px=4)

    # --- grime and battle damage
    for px in (-34, -12, 14, 32):
        rust_streak(f, f.cx + px, f.cy - 16, 24 + (px % 9), 1)
    rust_streak(f, f.cx - 2, f.cy - 26, 30, 2)
    if f.damaged:
        f.poly([f.p(16, 14, 34), f.p(26, 14, 32), f.p(24, 14, 18), f.p(14, 14, 22)],
               (48, 44, 38))
        f.poly([f.p(18, 14, 30), f.p(24, 14, 28), f.p(22, 14, 22), f.p(16, 14, 24)],
               (16, 14, 12))
        f.poly([f.p(-14, 40, 10.4), f.p(-2, 40, 10.4), f.p(-6, 40, 3), f.p(-16, 40, 5)],
               (30, 27, 23))
        for i in range(4):
            f.line([(f.cx - 4 + f.rng.randint(-10, 10), f.cy + 4 + f.rng.randint(-8, 8)),
                    (f.cx - 18 + f.rng.randint(-10, 14), f.cy + 16 + f.rng.randint(-10, 8))],
                   (34, 29, 23))


# ---------------------------------------------------------------- terrain tiles
SAND_PAL = [(230, 204, 163), (216, 184, 136), (190, 154, 105), (158, 122, 79)]
ROCK_PAL = [(201, 129, 82), (186, 109, 62), (153, 85, 49), (108, 60, 37)]
CONC_PAL = [(226, 187, 151), (201, 154, 116), (173, 129, 94), (132, 97, 69)]
SPICE_PAL = [(224, 121, 33), (190, 84, 22), (143, 55, 12), (243, 174, 73)]


def _quantise(v, pal, amount=0.0):
    """Bayer-thresholded palette pick: hard pixels, no smoothing."""
    v = v + (BAYER_TILE - 7.5) / 55.0 + amount
    idx = np.digitize(v, [0.40, 0.56, 0.72])
    arr = np.zeros((TILE, TILE, 3), dtype=np.uint8)
    for i, c in enumerate(pal):
        arr[idx == i] = c
    return arr


def _value_noise(rng, cells):
    g = rng.random((cells, cells)).astype(np.float32)
    img = Image.fromarray((g * 255).astype(np.uint8))
    img = img.resize((TILE, TILE), Image.Resampling.BILINEAR)
    return np.asarray(img, dtype=np.float32) / 255.0 - 0.5


def concrete_tile(mask, tone, seed):
    """mask bits: 1=N, 2=E, 4=S, 8=W concrete neighbour."""
    rng = np.random.default_rng(seed)
    n = _value_noise(rng, 3) * 0.16 + _value_noise(rng, 8) * 0.06
    base = 0.56 if tone == 0 else 0.49
    v = base + n + rng.normal(0.0, 0.030, (TILE, TILE))
    arr = _quantise(v, CONC_PAL)
    img = Image.fromarray(np.dstack([arr, np.full((TILE, TILE), 255, np.uint8)]), "RGBA")
    d = ImageDraw.Draw(img)
    joints = (mask & 1, mask & 2, mask & 4, mask & 8)
    seam = (112, 79, 56)
    lip = (234, 198, 160)
    if joints[0]:
        d.line([(0, 0), (TILE - 1, 0)], fill=seam)
        d.line([(0, 1), (TILE - 1, 1)], fill=lip)
    if joints[2]:
        d.line([(0, TILE - 1), (TILE - 1, TILE - 1)], fill=seam)
        d.line([(0, TILE - 2), (TILE - 1, TILE - 2)], fill=(184, 141, 103))
    if joints[3]:
        d.line([(0, 0), (0, TILE - 1)], fill=seam)
        d.line([(1, 0), (1, TILE - 1)], fill=lip)
    if joints[1]:
        d.line([(TILE - 1, 0), (TILE - 1, TILE - 1)], fill=seam)
        d.line([(TILE - 2, 0), (TILE - 2, TILE - 1)], fill=(172, 130, 94))

    # exposed rims: NW catches light, SE drops into a hard shadow
    if not joints[0]:
        d.line([(0, 0), (TILE - 1, 0)], fill=(236, 202, 166))
        d.line([(0, 1), (TILE - 1, 1)], fill=(214, 178, 140))
    if not joints[3]:
        d.line([(0, 0), (0, TILE - 1)], fill=(230, 195, 158))
        d.line([(1, 0), (1, TILE - 1)], fill=(208, 172, 135))
    if not joints[2]:
        d.rectangle([0, TILE - 2, TILE - 1, TILE - 1], fill=(105, 74, 52))
        d.line([(0, TILE - 2), (TILE - 1, TILE - 2)], fill=(132, 94, 67))
    if not joints[1]:
        d.rectangle([TILE - 2, 0, TILE - 1, TILE - 1], fill=(109, 77, 55))
        d.line([(TILE - 2, 0), (TILE - 2, TILE - 1)], fill=(136, 98, 70))

    # wind-blown sand piled over the exposed edges
    for side in range(4):
        if joints[side]:
            continue
        count = 26 if side in (2, 1) else 15
        for _ in range(count):
            depth = int(rng.integers(0, 5 if side in (2, 1) else 3))
            along = int(rng.integers(0, TILE))
            if side == 0:
                x, y = along, depth
            elif side == 2:
                x, y = along, TILE - 1 - depth
            elif side == 3:
                x, y = depth, along
            else:
                x, y = TILE - 1 - depth, along
            c = SAND_PAL[int(rng.integers(1, 4))]
            d.point((x, y), fill=c)
            if rng.random() < 0.35:
                d.rectangle([x, y, x + 1, y + 1], fill=SAND_PAL[1])
                d.point((x, y), fill=SAND_PAL[0])

    # cracks, spalled corners, rust blooms
    for _ in range(1 + tone):
        x, y = int(rng.integers(5, TILE - 10)), int(rng.integers(5, TILE - 10))
        pts = [(x, y)]
        for _ in range(rng.integers(2, 5)):
            x += int(rng.integers(-2, 7))
            y += int(rng.integers(-3, 6))
            pts.append((x, y))
        d.line(pts, fill=(88, 82, 70))
        d.line([(p[0] + 1, p[1] + 1) for p in pts], fill=(160, 151, 132))
    for _ in range(rng.integers(0, 3)):
        x, y = int(rng.integers(3, TILE - 4)), int(rng.integers(3, TILE - 4))
        d.rectangle([x, y, x + 1, y + 1], fill=(78, 73, 62))
        d.point((x, y), fill=(172, 163, 143))
    for _ in range(rng.integers(0, 3)):
        x, y = int(rng.integers(2, TILE - 6)), int(rng.integers(2, TILE - 6))
        d.rectangle([x, y, x + int(rng.integers(1, 4)), y + int(rng.integers(1, 2))],
                    fill=(116, 70, 42))
    return img


def spice_tile(seed, sparse=False):
    rng = np.random.default_rng(seed)
    arr = np.zeros((TILE, TILE, 4), dtype=np.uint8)
    n = _value_noise(rng, 3) + _value_noise(rng, 7) * 0.35
    cover = n > (-0.22 if sparse else -0.34)
    arr[..., 0] = SPICE_PAL[1][0]
    arr[..., 1] = SPICE_PAL[1][1]
    arr[..., 2] = SPICE_PAL[1][2]
    arr[..., 3] = np.where(cover, (34 if sparse else 62), 0).astype(np.uint8)
    img = Image.fromarray(arr, "RGBA")
    d = ImageDraw.Draw(img)
    clusters = rng.integers(3, 6) if sparse else rng.integers(11, 17)
    for _ in range(clusters):
        cx, cy = int(rng.integers(3, TILE - 3)), int(rng.integers(3, TILE - 3))
        for _ in range(rng.integers(4, 10)):
            x = cx + int(rng.integers(-5, 6))
            y = cy + int(rng.integers(-3, 4))
            if 0 <= x < TILE - 1 and 0 <= y < TILE - 1:
                d.point((x + 1, y + 1), fill=SPICE_PAL[2])
                d.rectangle([x, y, x + 1, y + 1], fill=SPICE_PAL[int(rng.integers(0, 3))])
                if rng.random() < 0.40:
                    d.point((x, y), fill=SPICE_PAL[3])
    return img


def cliff_tile(seed):
    rng = np.random.default_rng(seed)
    h = 22
    img = Image.new("RGBA", (TILE, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, TILE - 1, h - 1], fill=ROCK_PAL[3])
    d.line([(0, 0), (TILE - 1, 0)], fill=(186, 172, 146))
    d.line([(0, 1), (TILE - 1, 1)], fill=(138, 126, 105))
    d.rectangle([0, 2, TILE - 1, 4], fill=ROCK_PAL[2])
    # stratified face, mostly in shadow under the rim
    for y in range(5, h - 4, 3):
        col = ROCK_PAL[3] if (y // 3) % 2 else ROCK_PAL[2]
        d.rectangle([0, y, TILE - 1, y + 1], fill=col)
        d.line([(0, y + 2), (TILE - 1, y + 2)], fill=(58, 52, 42))
    for _ in range(7):
        x = int(rng.integers(1, TILE - 2))
        y0 = int(rng.integers(4, 9))
        d.line([(x, y0), (x + int(rng.integers(-2, 3)), h - 5)], fill=(70, 63, 51))
        d.line([(x + 1, y0), (x + 1 + int(rng.integers(-1, 3)), h - 6)], fill=(134, 123, 102))
    # rubble chunks at the foot, lit on top
    for _ in range(7):
        x = int(rng.integers(0, TILE - 4))
        w = int(rng.integers(2, 6))
        d.rectangle([x, h - 5, x + w, h - 2], fill=ROCK_PAL[2])
        d.line([(x, h - 5), (x + w, h - 5)], fill=ROCK_PAL[0])
        d.point((x, h - 4), fill=(196, 184, 158))
    d.rectangle([0, h - 2, TILE - 1, h - 1], fill=(62, 56, 45))
    return img


def _periodic(size, rng, terms):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    v = np.zeros((size, size), dtype=np.float32)
    for kx, ky, amp in terms:
        v += amp * np.sin(math.tau * (kx * xx + ky * yy) / float(size) + rng.uniform(0, math.tau))
    return v


def _quantise_n(v, pal, size, rng=None):
    if rng is not None:
        # grain, not a woven ordered-dither grid
        v = v + rng.uniform(-0.042, 0.042, (size, size))
    else:
        bayer = np.tile(BAYER, (size // 4 + 1, size // 4 + 1))[:size, :size]
        v = v + (bayer.astype(np.float32) - 7.5) / 55.0
    idx = np.digitize(v, [0.40, 0.56, 0.72])
    arr = np.zeros((size, size, 3), dtype=np.uint8)
    for i, c in enumerate(pal):
        arr[idx == i] = c
    return arr


def _stamp_wrapped(d, size, x, y, w, h, body, top, shadow):
    for dx in (-size, 0, size):
        for dy in (-size, 0, size):
            xx, yy = int(x + dx), int(y + dy)
            d.rectangle([xx, yy, xx + w, yy + h], fill=body)
            d.line([(xx, yy), (xx + w, yy)], fill=top)
            d.line([(xx, yy + h + 1), (xx + w + 1, yy + h + 1)], fill=shadow)


def _blob_wrapped(d, size, x, y, rx, ry, body, lit, shade):
    """Soft boulder / pebble stamp with a lit NW rim and SE contact shadow."""
    for dx in (-size, 0, size):
        for dy in (-size, 0, size):
            xx, yy = int(x + dx), int(y + dy)
            d.ellipse([xx - rx, yy - ry, xx + rx, yy + ry], fill=body)
            d.arc([xx - rx, yy - ry, xx + rx, yy + ry], 190, 330, fill=lit)
            d.arc([xx - rx, yy - ry, xx + rx, yy + ry], 10, 155, fill=shade)


def _periodic_voronoi(size, cells, rng):
    """Seamless jittered-cell plate map for the fractured rock surface."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    pts = []
    for gy in range(cells):
        for gx in range(cells):
            pts.append(((float(gx) + 0.18 + 0.64 * rng.random()) * size / cells,
                        (float(gy) + 0.18 + 0.64 * rng.random()) * size / cells))
    d1 = np.full((size, size), 1e9, dtype=np.float32)
    d2 = np.full((size, size), 1e9, dtype=np.float32)
    cell = np.zeros((size, size), dtype=np.int32)
    for i, (cx, cy) in enumerate(pts):
        dx = np.abs(xx - cx)
        dx = np.minimum(dx, size - dx)
        dy = np.abs(yy - cy)
        dy = np.minimum(dy, size - dy)
        dist = np.sqrt(dx * dx + dy * dy)
        closer = dist < d1
        d2 = np.where(closer, d1, np.minimum(d2, dist))
        d1 = np.where(closer, dist, d1)
        cell = np.where(closer, i, cell)
    edge = (d2 - d1) < 1.45
    return edge, cell, d1


def cliff_autotile(mask, seed=0):
    """One 40x40 cliff overlay for an orthogonal rock-neighbour mask.

    Bits: 1=N, 2=E, 4=S, 8=W. Missing bits are exposed mesa edges. The south
    face is the dominant jagged rock wall; east/west receive narrow shadowed
    rims and the north lip catches the NW sun.
    """
    rng = np.random.default_rng(seed + mask * 97)
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    face = (112, 65, 40, 255)
    face_mid = (143, 84, 51, 255)
    face_lit = (174, 106, 65, 255)
    deep = (64, 35, 22, 255)
    lip = (211, 138, 84, 255)
    sun = (236, 176, 116, 255)
    shadow = (52, 29, 18, 255)
    # North lip: sunlit top edge with a dark undercut.
    if not (mask & 1):
        for x in range(TILE):
            yy = 2 + int(round(1.2 * math.sin(x * 0.47) + 0.5 * math.sin(x * 1.1)))
            d.point((x, max(0, yy - 1)), fill=sun)
            d.point((x, yy), fill=lip)
            d.line([(x, yy + 1), (x, min(TILE - 1, yy + 3))], fill=face_lit)
            d.point((x, min(TILE - 1, yy + 4)), fill=deep)
        for _ in range(3):
            x = int(rng.integers(2, TILE - 3))
            d.line([(x, 2), (x + int(rng.integers(-2, 3)), int(rng.integers(4, 8)))], fill=deep)
    # West rim: bright edge and narrow rock shoulder stepping into the tile.
    if not (mask & 8):
        for y in range(TILE):
            xx = 2 + int(round(1.8 * math.sin(y * 0.31 + 1.7) + 0.8 * math.sin(y * 0.93)))
            d.point((max(0, xx - 1), y), fill=sun)
            d.point((xx, y), fill=lip)
            d.line([(xx + 1, y), (xx + 4, y)], fill=face_lit)
            d.point((min(TILE - 1, xx + 5), y), fill=face_mid)
        for _ in range(4):
            y = int(rng.integers(1, TILE - 2))
            d.line([(2, y), (int(rng.integers(4, 9)), y + int(rng.integers(-3, 4)))], fill=face_mid)
    # East wall: strong shadow and a rugged inner silhouette.
    if not (mask & 2):
        for y in range(TILE):
            xx = TILE - 3 - int(round(1.8 * math.sin(y * 0.37 + 0.4) + 0.7 * math.sin(y * 0.89)))
            d.point((min(TILE - 1, xx + 2), y), fill=face_lit)
            d.point((min(TILE - 1, xx + 1), y), fill=face_mid)
            d.line([(xx, y), (max(0, xx - 3), y)], fill=face)
            d.point((max(0, xx - 4), y), fill=deep)
        for _ in range(4):
            y = int(rng.integers(1, TILE - 2))
            d.line([(TILE - 3, y), (TILE - int(rng.integers(6, 12)), y + int(rng.integers(-3, 4)))], fill=shadow)
    # South face: a jagged, stratified rock wall occupying the lower band.
    if not (mask & 4):
        tops = []
        for x in range(TILE):
            yy = 21 + 2.8 * math.sin(x * 0.38 + 0.6) + 1.5 * math.sin(x * 0.91 + 2.1)
            yy += float(rng.integers(-1, 2))
            tops.append(max(18, min(27, int(round(yy)))))
        # Solid face under the overhanging lip.
        d.polygon([(0, tops[0])] + [(x, tops[x]) for x in range(1, TILE)] + [(TILE - 1, TILE), (0, TILE)], fill=face)
        for x in range(TILE):
            top = tops[x]
            d.point((x, max(0, top - 2)), fill=sun)
            d.point((x, max(0, top - 1)), fill=lip)
            d.line([(x, top), (x, TILE - 1)], fill=face_mid if (x // 3) % 2 else face)
            if x % 4 == (seed % 4):
                d.point((x, min(TILE - 1, top + 3)), fill=deep)
        # Stratified ledges and vertical cracks break up the wall face.
        for band_y in range(29, TILE, 4):
            for x in range(TILE):
                if tops[x] + 2 < band_y:
                    d.point((x, band_y + (x % 3 == 0)), fill=deep if band_y % 8 else face_lit)
        for _ in range(7):
            x0 = int(rng.integers(2, TILE - 3))
            y0 = tops[x0] + 1
            pts = [(x0, y0)]
            y = y0
            x = x0
            for _ in range(int(rng.integers(2, 5))):
                x = max(1, min(TILE - 2, x + int(rng.integers(-3, 4))))
                y = min(TILE - 1, y + int(rng.integers(2, 6)))
                pts.append((x, y))
            d.line(pts, fill=shadow)
            d.line([(min(TILE - 1, p[0] + 1), p[1]) for p in pts], fill=face_lit)
        # Loose blocks and rubble on the lower lip.
        for _ in range(5):
            x = int(rng.integers(1, TILE - 6))
            w = int(rng.integers(2, 6))
            y = int(rng.integers(31, 37))
            d.rectangle([x, y, x + w, min(TILE - 1, y + 2)], fill=face_mid)
            d.line([(x, y), (x + w, y)], fill=lip)
            d.point((x + 1, y + 1), fill=deep)
        d.rectangle([0, TILE - 2, TILE - 1, TILE - 1], fill=shadow)
    return img


def sand_big(seed, size=640):
    """One continuous pale desert sheet with soft wind ripples and pebbles."""
    rng = np.random.default_rng(seed)
    broad = _periodic(size, rng, [(1, 0, 0.50), (0, 1, 0.34), (2, 1, 0.26),
                                  (1, 3, 0.18), (5, 2, 0.10)])
    fine = _periodic(size, rng, [(9, 0, 0.010), (6, 2, 0.006), (13, 1, 0.004)])
    # Keep the field in the two light palette grades: cream and warm tan.
    v = 0.455 + broad * 0.055 + fine + rng.normal(0.0, 0.020, (size, size))
    arr = _quantise_n(v, SAND_PAL, size, rng)
    img = Image.fromarray(np.dstack([arr, np.full((size, size), 255, np.uint8)]), "RGBA")
    # Soft translucent dune crests: a warm shadow and a pale sunlit edge.
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for _ in range(13):
        y0 = float(rng.integers(0, size))
        freq = int(rng.integers(1, 4))
        amp = float(rng.integers(7, 20))
        ph = rng.uniform(0, math.tau)
        pts = []
        for x in range(size):
            y = (y0 + amp * math.sin(math.tau * freq * x / size + ph)
                 + 2.4 * math.sin(math.tau * 7 * x / size + ph * 0.7)) % size
            pts.append((x, int(y)))
        d.line(pts, fill=(151, 111, 69, 40), width=1)
        d.line([(x, (y + 2) % size) for x, y in pts], fill=(250, 231, 198, 34))
        d.line([(x, (y + 3) % size) for x, y in pts], fill=(199, 165, 119, 20))
    # Fine wind streaks.
    for _ in range(55):
        x0 = int(rng.integers(0, size))
        y0 = int(rng.integers(0, size))
        length = int(rng.integers(5, 19))
        amp = rng.uniform(0.4, 1.9)
        pts = []
        for k in range(length):
            x = (x0 + k) % size
            y = (y0 + int(round(amp * math.sin(k * 0.55 + x0))) + (k // 9)) % size
            pts.append((x, y))
        d.line(pts, fill=(159, 119, 77, 20))
    img = Image.alpha_composite(img, overlay)
    # Scattered dark pebbles, rock chips and tiny grit.
    d = ImageDraw.Draw(img)
    for _ in range(78):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        r = int(rng.integers(1, 3))
        _blob_wrapped(d, size, x, y, r, max(1, r - 1), (105, 81, 54), (183, 152, 109), (72, 54, 35))
    for _ in range(17):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        w, h = int(rng.integers(2, 5)), int(rng.integers(1, 3))
        _blob_wrapped(d, size, x, y, w, h, ROCK_PAL[1], ROCK_PAL[0], (74, 52, 34))
    for _ in range(210):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        c = SAND_PAL[2] if rng.random() < 0.55 else SAND_PAL[0]
        d.point((x, y), fill=c)
    return img


def rock_big(seed, size=640):
    """Continuous terracotta mesa rock with a seamless fracture-plate network."""
    rng = np.random.default_rng(seed)
    field = _periodic(size, rng, [(1, 1, 0.38), (2, 0, 0.24), (0, 3, 0.18), (4, 1, 0.10)])
    grain = _periodic(size, rng, [(11, 2, 0.014), (7, 5, 0.009)])
    edge, cell, _ = _periodic_voronoi(size, 20, rng)
    plate_tint = rng.uniform(-0.026, 0.020, (cell.max() + 1,)).astype(np.float32)
    v = 0.515 + field * 0.185 + grain + plate_tint[cell] + rng.normal(0.0, 0.024, (size, size))
    arr = _quantise_n(v, ROCK_PAL, size, rng)
    # Dark fracture valleys with a sunlit NW shoulder on the upthrown plate.
    arr[edge] = (151, 89, 55)
    edge_hi = np.roll(np.roll(edge, 2, axis=0), 2, axis=1) & (~edge)
    arr[edge_hi] = (192, 120, 75)
    img = Image.fromarray(np.dstack([arr, np.full((size, size), 255, np.uint8)]), "RGBA")
    d = ImageDraw.Draw(img)
    # Wind-scoured hollows and raised shelves, all soft edged.
    for _ in range(14):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        rx, ry = int(rng.integers(4, 10)), int(rng.integers(2, 4))
        _blob_wrapped(d, size, x, y, rx, ry, ROCK_PAL[2], ROCK_PAL[1], (82, 47, 30))
    for _ in range(18):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        rx, ry = int(rng.integers(4, 9)), int(rng.integers(2, 5))
        _blob_wrapped(d, size, x, y, rx, ry, ROCK_PAL[1], ROCK_PAL[0], ROCK_PAL[2])
    # A few branching spall cracks enrich the main cell boundaries.
    for _ in range(16):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        pts = [(x, y)]
        for _ in range(int(rng.integers(3, 6))):
            x = (x + int(rng.integers(-7, 17))) % size
            y = (y + int(rng.integers(-9, 15))) % size
            pts.append((x, y))
        d.line(pts, fill=(116, 68, 43), width=1)
        d.line([((p[0] + 1) % size, (p[1] + 1) % size) for p in pts], fill=(193, 125, 78))
    # Boulders and sand pockets gathered in the low spots.
    for _ in range(80):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        rx, ry = int(rng.integers(1, 4)), int(rng.integers(1, 3))
        _blob_wrapped(d, size, x, y, rx, ry, ROCK_PAL[2], ROCK_PAL[0], (66, 40, 26))
    for _ in range(22):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        rx, ry = int(rng.integers(1, 4)), int(rng.integers(1, 3))
        _blob_wrapped(d, size, x, y, rx, ry, SAND_PAL[1], SAND_PAL[0], (112, 82, 52))
    for _ in range(110):
        x, y = int(rng.integers(0, size)), int(rng.integers(0, size))
        d.point((x, y), fill=ROCK_PAL[3])
        if rng.random() < 0.25:
            d.point((x + 1, y), fill=ROCK_PAL[0])
    return img


def make_terrain() -> None:
    sand = sand_big(100)
    rock = rock_big(200)
    concrete = []
    for tone in (0, 1):
        for mask in range(16):
            concrete.append(concrete_tile(mask, tone, 300 + mask + tone * 100))
    spice = [spice_tile(400 + i) for i in range(4)]
    cliffs = [cliff_autotile(mask, 500) for mask in range(16)]

    sand.save(OUT_DIR / "terrain_sand.png")
    rock.save(OUT_DIR / "terrain_rock.png")

    def strip(tiles, name):
        out = Image.new("RGBA", (TILE * len(tiles), tiles[0].height), (0, 0, 0, 0))
        for i, t in enumerate(tiles):
            out.alpha_composite(t, (i * TILE, 0))
        out.save(OUT_DIR / name)

    strip(spice, "terrain_spice.png")
    strip(cliffs, "terrain_cliff.png")
    out = Image.new("RGBA", (TILE * 8, TILE * 4), (0, 0, 0, 0))
    for i, t in enumerate(concrete):
        out.alpha_composite(t, ((i % 8) * TILE, (i // 8) * TILE))
    out.save(OUT_DIR / "terrain_concrete.png")

    # preview patch: continuous sand, a rock shelf, a 3x3 slab, spice, cliff
    pw, ph = TILE * 9, TILE * 5
    prev = Image.new("RGBA", (pw, ph), (0, 0, 0, 255))
    prev.alpha_composite(sand.crop((0, 0, pw, ph)), (0, 0))
    prev.alpha_composite(rock.crop((0, 0, TILE * 3, TILE * 2)), (0, 0))
    for y in range(3):
        for x in range(3):
            mask = 0
            if y > 0:
                mask |= 1
            if x < 2:
                mask |= 2
            if y < 2:
                mask |= 4
            if x > 0:
                mask |= 8
            prev.alpha_composite(concrete_tile(mask, 0, 700 + y * 3 + x), ((4 + x) * TILE, (1 + y) * TILE))
    prev.alpha_composite(spice[0], (7 * TILE, 4 * TILE))
    prev.alpha_composite(cliff_autotile(11, 900), (2 * TILE, 4 * TILE))
    prev = prev.resize((pw * 3, ph * 3), Image.Resampling.NEAREST)
    (ROOT / "build").mkdir(exist_ok=True)
    prev.save(ROOT / "build/d2_terrain_preview.png")
    print("terrain: seamless sand 640  rock 640  concrete x32  spice x4  cliff x16")


# ---------------------------------------------------------------- finishing
def outline(img: Image.Image) -> Image.Image:
    """One-pixel hard outline so the silhouette reads at RTS zoom."""
    alpha = img.getchannel("A")
    grown = alpha.filter(ImageFilter.MaxFilter(3))
    ring = Image.new("RGBA", img.size, OUTLINE)
    ring.putalpha(grown)
    return Image.alpha_composite(ring, img)


def condition(img: Image.Image, damage: bool) -> Image.Image:
    """Quantise, desaturate and warm-grade: weathered 1998 pre-render."""
    arr = np.asarray(img).astype(np.int16)
    rgb, alpha = arr[..., :3], arr[..., 3]
    h, w = alpha.shape
    yy, xx = np.mgrid[0:h, 0:w]
    dither = BAYER[yy % 4, xx % 4]
    step = 7
    rgb = (rgb // step) * step + (dither[..., None] * step) // 16 - 2
    grain = np.random.default_rng(7).integers(-2, 3, size=(h, w, 1))
    rgb = np.clip(rgb + grain, 0, 255).astype(np.float32)
    # low-frequency grime field (a luminance mask, not an edge filter)
    blotch = np.random.default_rng(3).random((h // 9 + 2, w // 9 + 2)).astype(np.float32)
    blotch = np.array(Image.fromarray((blotch * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR),
                      dtype=np.float32) / 255.0
    rgb *= 0.94 + 0.13 * blotch[..., None]
    # desaturate then push contrast around a warm midpoint, lifting the shadows
    lum = rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114
    rgb = lum[..., None] * 0.07 + rgb * 0.93
    rgb = (rgb.astype(np.float32) - 118.0) * 1.09 + 117.0 + 5.0
    rgb *= np.array([1.035, 1.0, 0.945])
    if damage:
        rgb *= 0.93
    rgb = np.clip(rgb, 0, 255)
    return Image.fromarray(np.dstack([rgb.astype(np.uint8), alpha.astype(np.uint8)]), "RGBA")


def render_frame(spec, index: int):
    span = spec["span"]
    cw = span[0] * TILE + MARGIN * 2
    ch = span[1] * TILE + MARGIN * 2
    # Same wear on every frame: animation comes from f.t (beacons, fans, smoke,
    # crane sway), never from re-rolled rust and cracks that would shimmer.
    rng = random.Random(spec["seed"] * 31)
    f = Frame(cw, ch, index / FRAMES, spec["damage"], rng)
    spec["fn"](f)
    struct_box = f.s.getbbox()

    if spec["damage"]:
        bbox = f.s.getbbox()
        if bbox:
            layer = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            for _ in range(7):
                px = rng.uniform(bbox[0], bbox[2])
                py = rng.uniform(bbox[1], bbox[3])
                rr = rng.uniform(4, 11)
                d.ellipse([px - rr, py - rr * 0.7, px + rr, py + rr * 0.7],
                          fill=(18, 15, 12, rng.randint(36, 74)))
            layer.putalpha(ImageChops.multiply(layer.getchannel("A"), f.s.getchannel("A")))
            f.s = Image.alpha_composite(f.s, layer)

    img = Image.alpha_composite(f.base, outline(f.s))
    return condition(img, spec["damage"]), struct_box


def build(spec):
    span = spec["span"]
    cw = span[0] * TILE + MARGIN * 2
    ch = span[1] * TILE + MARGIN * 2
    sheet = Image.new("RGBA", (cw * FRAMES, ch * 2), (0, 0, 0, 0))
    icon_box = None
    for row in (0, 1):
        spec["damage"] = bool(row)
        for i in range(FRAMES):
            frame, sbox = render_frame(spec, i)
            sheet.alpha_composite(frame, (i * cw, row * ch))
            if row == 0 and i == 0:
                icon_box = sbox
    return sheet, (cw, ch), icon_box


def make_icon(sheet: Image.Image, cell: tuple[int, int], sbox, pad=4, size=64) -> Image.Image:
    cw, ch = cell
    frame = sheet.crop((0, 0, cw, ch))
    if not sbox:
        return frame.resize((size, size), Image.Resampling.NEAREST)
    x0 = max(0, sbox[0] - pad)
    y0 = max(0, sbox[1] - pad)
    x1 = min(cw, sbox[2] + pad)
    y1 = min(ch, sbox[3] + pad)
    crop = frame.crop((x0, y0, x1, y1))
    w, h = crop.size
    k = min(1.0, float(size) / float(max(w, h)))
    art = crop.resize((max(1, int(w * k)), max(1, int(h * k))), Image.Resampling.NEAREST)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.alpha_composite(art, ((size - art.width) // 2, (size - art.height) // 2))
    return icon


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    make_terrain()
    previews = []
    for name, spec in SPECS.items():
        sheet, (cw, ch), sbox = build(spec)
        sheet.save(OUT_DIR / f"{name}.png")
        icon = make_icon(sheet, (cw, ch), sbox)
        icon.save(OUT_DIR / f"{name}_icon.png")
        previews.append(sheet.crop((0, 0, cw, ch)))
        print(f"{name}: {sheet.width}x{sheet.height}  cell {cw}x{ch}  icon {icon.width}x{icon.height}")

    pw = sum(p.width for p in previews) + 20 * (len(previews) + 1)
    ph = max(p.height for p in previews) + 40
    preview = Image.new("RGB", (pw, ph), (168, 138, 92))
    x = 20
    for p in previews:
        preview.paste(p, (x, 20), p)
        x += p.width + 20
    preview = preview.resize((pw * 2, ph * 2), Image.Resampling.NEAREST)
    (ROOT / "build").mkdir(exist_ok=True)
    preview.save(ROOT / "build/d2_buildings_preview.png")
    print("preview: build/d2_buildings_preview.png")


SPECS = {
    "cy": {"span": (3, 3), "seed": 11, "fn": render_cy, "damage": False},
    "windtrap": {"span": (2, 3), "seed": 23, "fn": render_windtrap, "damage": False},
    "refinery": {"span": (3, 3), "seed": 37, "fn": render_refinery, "damage": False},
}


if __name__ == "__main__":
    main()








