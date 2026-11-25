#!/usr/bin/env python3
"""Bake deterministic, seamless terrain variants without touching the source sheets.

Outputs:
  assets/sprites/d2/terrain_rock_clean.png      640 px seamless base
  assets/sprites/d2/terrain_sand_clean.png      640 px seamless base
  assets/sprites/d2/terrain_rock_variants.png   8 x 40px cells
  assets/sprites/d2/terrain_sand_variants.png   4 x 40px cells
  assets/sprites/d2/terrain_spice_blooms.png    8 x 96px organic bloom cells

The clean base sheets are new, procedurally generated seamless plates with no
legacy 40 px tint cells. The original terrain_rock/sand source files are never
overwritten. Each variant cell is a soft-edged overlay that shares identical transparent edge
noise and is composited over the continuous 640px sheet at runtime. Because the
feather reaches zero at the cell border, adjacent variants can meet in any
order without a seam or tile grid. Interiors vary cracks, sandstone hues, dust,
pebbles and hairline fractures. Two variants are busier; the rest stay quiet.
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets/sprites/d2"
BUILD_DIR = ROOT / "build"
TILE = 40

ROCK_PAL = [(223, 160, 108), (203, 137, 88), (163, 98, 60), (112, 61, 38)]
SAND_PAL = [(246, 211, 166), (229, 190, 142), (201, 156, 105), (166, 121, 76)]
CLEAN_ROCK = OUT_DIR / "terrain_rock_clean.png"
CLEAN_SAND = OUT_DIR / "terrain_sand_clean.png"
SPICE_BLOOMS = OUT_DIR / "terrain_spice_blooms.png"
SPICE_BLOOM = 96
SPICE_DUST = [(235, 158, 84), (216, 126, 58), (247, 182, 111), (198, 104, 43)]
SPICE_MID = [(188, 76, 22), (211, 101, 31), (165, 57, 15), (228, 126, 45)]
SPICE_DEEP = [(103, 33, 9), (134, 44, 12), (82, 25, 7), (152, 51, 15)]

# A warm, stratified cliff atlas: pale sunlit NW lips, crisp near-black
# undercuts and a dark south face keep rock readable against open sand.
CLIFF_FACE = (104, 59, 38)
CLIFF_FACE_MID = (138, 80, 48)
CLIFF_FACE_LIT = (178, 106, 64)
CLIFF_DEEP = (57, 30, 18)
CLIFF_LIP = (219, 145, 88)
CLIFF_SUN = (248, 188, 126)
CLIFF_SHADOW = (39, 21, 13)


def periodic(rng, terms):
    yy, xx = np.mgrid[0:TILE, 0:TILE].astype(np.float32)
    v = np.zeros((TILE, TILE), dtype=np.float32)
    for kx, ky, amp in terms:
        v += amp * np.sin(math.tau * (kx * xx + ky * yy) / TILE + rng.uniform(0.0, math.tau))
    return v


def quantise(v, pal, rng):
    v = v + rng.uniform(-0.035, 0.035, (TILE, TILE))
    idx = np.digitize(v, [0.40, 0.56, 0.72])
    arr = np.zeros((TILE, TILE, 3), dtype=np.uint8)
    for i, col in enumerate(pal):
        arr[idx == i] = col
    return arr


def smoothstep(lo: float, hi: float, value: np.ndarray) -> np.ndarray:
    t = np.clip((value - lo) / (hi - lo), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def make_rock_base() -> np.ndarray:
    """A quiet, seamless plate of terracotta with no strong edge features."""
    rng = np.random.default_rng(811)
    broad = periodic(rng, [(1, 0, 0.34), (0, 1, 0.28), (1, 1, 0.19), (2, 1, 0.12), (1, 3, 0.07)])
    grain = periodic(rng, [(9, 4, 0.018), (5, 11, 0.012), (13, 2, 0.009)])
    sand = periodic(rng, [(2, 2, 0.09), (3, 1, 0.05)])
    v = 0.52 + broad * 0.105 + grain + rng.normal(0.0, 0.018, (TILE, TILE))
    arr = quantise(v, ROCK_PAL, rng)
    # A few soft warm/cool plate shifts, constrained away from the exact border.
    yy, xx = np.mgrid[0:TILE, 0:TILE].astype(np.float32)
    edge = np.minimum.reduce([xx, yy, TILE - 1 - xx, TILE - 1 - yy])
    interior = smoothstep(2.0, 9.0, edge)
    warm = (np.clip(sand * 0.5 + 0.5, 0.0, 1.0) * interior)[..., None]
    arr = np.clip(arr.astype(np.float32) + (12.0 * warm), 0, 255).astype(np.uint8)
    return arr


def make_sand_base() -> np.ndarray:
    """A quiet seamless sand base for the shared edge band."""
    rng = np.random.default_rng(912)
    broad = periodic(rng, [(1, 0, 0.42), (0, 1, 0.30), (2, 1, 0.12), (1, 3, 0.08)])
    ripple = periodic(rng, [(2, 0, 0.016), (0, 4, 0.012), (7, 2, 0.008)])
    v = 0.45 + broad * 0.035 + ripple + rng.normal(0.0, 0.014, (TILE, TILE))
    return quantise(v, SAND_PAL, rng)


def dust_layer(seed: int, strength: float) -> Image.Image:
    """Very soft sandstone dust patches, as a transparent overlay."""
    rng = np.random.default_rng(seed)
    layer = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(2):
        x, y = int(rng.integers(13, TILE - 13)), int(rng.integers(12, TILE - 12))
        rx, ry = int(rng.integers(4, 8)), int(rng.integers(2, 5))
        d.ellipse([x - rx, y - ry, x + rx, y + ry],
                  fill=(209, 174, 123, int(15 * strength)))
    return layer


def pebbles_layer(seed: int, count: int) -> Image.Image:
    rng = np.random.default_rng(seed)
    layer = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(count):
        x, y = int(rng.integers(10, TILE - 10)), int(rng.integers(10, TILE - 10))
        rx, ry = int(rng.integers(1, 3)), int(rng.integers(1, 2))
        d.ellipse([x - rx, y - ry, x + rx, y + ry], fill=(104, 68, 44, 255))
        d.arc([x - rx, y - ry, x + rx, y + ry], 190, 330, fill=(202, 156, 102, 255))
        d.point((x - 1, y + ry), fill=(57, 35, 24, 255))
        d.point((x + rx, y + 1), fill=(45, 28, 19, 255))
    return layer


def cracks_layer(seed: int, count: int) -> Image.Image:
    rng = np.random.default_rng(seed)
    layer = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(count):
        x, y = int(rng.integers(12, TILE - 12)), int(rng.integers(12, TILE - 12))
        pts = [(x, y)]
        for _ in range(int(rng.integers(2, 4))):
            x = max(6, min(TILE - 7, x + int(rng.integers(-6, 7))))
            y = max(6, min(TILE - 7, y + int(rng.integers(-5, 8))))
            pts.append((x, y))
        d.line(pts, fill=(106, 61, 38, 255), width=1)
        d.line([(min(TILE - 2, px + 1), py) for px, py in pts], fill=(207, 145, 95, 255), width=1)
    return layer

def finish_variant(base: np.ndarray, dust: float, pebbles: int, cracks: int,
                   seed: int, alpha_max: float) -> np.ndarray:
    # Feature-only overlay: a tile-sized sampled patch would show as a soft
    # square, so only local dust, cracks and pebbles are composited.
    overlay = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    overlay = Image.alpha_composite(overlay, dust_layer(seed + 11, dust))
    if pebbles:
        overlay = Image.alpha_composite(overlay, pebbles_layer(seed + 29, pebbles))
    if cracks:
        overlay = Image.alpha_composite(overlay, cracks_layer(seed + 47, cracks))
    arr = np.asarray(overlay, dtype=np.float32)
    yy, xx = np.mgrid[0:TILE, 0:TILE].astype(np.float32)
    edge = np.minimum.reduce([xx, yy, TILE - 1 - xx, TILE - 1 - yy])
    feather = smoothstep(2.0, 9.0, edge) * alpha_max
    arr[..., 3] = np.clip(arr[..., 3] * feather, 0, 255)
    out = arr.astype(np.uint8)
    # Shared RGB edge pixels, though alpha is zero there; this keeps the
    # tile-edge noise identical if a future renderer wants an opaque variant.
    out[:2, :, :3] = base[:2, :, :]
    out[-2:, :, :3] = base[-2:, :, :]
    out[:, :2, :3] = base[:, :2, :]
    out[:, -2:, :3] = base[:, -2:, :]
    out[:2, :, 3] = 0
    out[-2:, :, 3] = 0
    out[:, :2, 3] = 0
    out[:, -2:, 3] = 0
    return out

def make_rock_variants() -> list[np.ndarray]:
    base = make_rock_base()
    # Two variants are deliberately busier; the rest stay quiet under units.
    # The deterministic 40 px assignment only adds sparse local features.
    # Pebbles and hairline cracks live in the seamless base sheet. Keeping
    # them out of the 40 px cells avoids a visible feature lattice.
    specs = [(0.00, 0, 0, 0.55), (0.35, 0, 0, 0.72), (0.00, 0, 0, 0.55),
             (0.00, 0, 0, 0.00), (0.20, 0, 0, 0.50), (0.55, 1, 0, 0.76),
             (0.00, 0, 0, 0.48), (0.30, 0, 0, 0.62)]
    return [
        finish_variant(base, spec[0], spec[1], spec[2], 1000 + i * 37, spec[3])
        for i, spec in enumerate(specs)
    ]


def make_sand_variants() -> list[np.ndarray]:
    base = make_sand_base()
    specs = [(0.00, 0, 0, 0.00), (0.20, 0, 0, 0.35),
             (0.00, 0, 0, 0.30), (0.18, 1, 0, 0.38)]
    return [
        finish_variant(base, spec[0], spec[1], 0, 2000 + i * 41, spec[3])
        for i, spec in enumerate(specs)
    ]


def _add_hairlines(img: Image.Image, seed: int, count: int) -> Image.Image:
    """Fine, non-repeating fractures, wrapped across every sheet edge."""
    W = img.width
    rng = np.random.default_rng(seed)
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x, y = rng.uniform(0, W), rng.uniform(0, W)
        pts = [(x, y)]
        for _ in range(int(rng.integers(2, 4))):
            x += rng.uniform(-8, 8)
            y += rng.uniform(-4, 8)
            pts.append((x, y))
        # Draw the same fracture at every wrapped offset; Pillow clips the
        # off-sheet portions, so both halves survive when the sheet is tiled.
        for ox in (-W, 0, W):
            for oy in (-W, 0, W):
                d.line([(px + ox, py + oy) for px, py in pts],
                       fill=(137, 85, 54), width=1)
    return img


def _wrap_dust_and_pebbles(base: Image.Image, seed: int, dust_count: int,
                           pebble_count: int, dust_col: tuple[int, int, int],
                           dust_alpha: int) -> Image.Image:
    """Seamful dust and sparse dark pebbles with soft contact shadows.

    Every feature is stamped at all nine wrapped offsets, so a pebble can sit
    on the sheet border without producing a seam when the 640 px plate tiles.
    Shadows are collected on their own layer first, keeping every stone visually
    above its neighbour's drop shadow.
    """
    W = base.width
    rng = np.random.default_rng(seed)
    dust = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dust)
    for _ in range(dust_count):
        x, y = rng.uniform(0, W), rng.uniform(0, W)
        rx, ry = rng.uniform(10, 26), rng.uniform(5, 13)
        for ox in (-W, 0, W):
            for oy in (-W, 0, W):
                dd.ellipse([x + ox - rx, y + oy - ry, x + ox + rx, y + oy + ry],
                           fill=(*dust_col, dust_alpha))
    base = Image.alpha_composite(base.convert("RGBA"), dust).convert("RGB")
    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    stones = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    d = ImageDraw.Draw(stones)
    for _ in range(pebble_count):
        x, y = rng.uniform(0, W), rng.uniform(0, W)
        rr = rng.uniform(1.15, 3.15)
        ry = rr * rng.uniform(0.55, 0.76)
        for ox in (-W, 0, W):
            for oy in (-W, 0, W):
                X, Y = x + ox, y + oy
                # A tight SE contact shadow anchors the pebble to the sand.
                sd.ellipse([X - rr * 0.95 + 1.15, Y - ry * 0.82 + 1.05,
                            X + rr * 1.05 + 1.15, Y + ry * 0.92 + 1.05],
                           fill=(58, 35, 20, 104))
                d.ellipse([X - rr, Y - ry, X + rr, Y + ry],
                          fill=(88, 55, 33, 255))
                d.arc([X - rr, Y - ry, X + rr, Y + ry], 188, 330,
                      fill=(170, 118, 73, 255))
                d.arc([X - rr, Y - ry, X + rr, Y + ry], 12, 158,
                      fill=(58, 35, 22, 255))
                d.point((X - rr * 0.28, Y - ry * 0.42), fill=(208, 162, 107, 255))
    base = Image.alpha_composite(base.convert("RGBA"), shadow)
    base = Image.alpha_composite(base, stones)
    return base.convert("RGB")


def _tile_noise(seed: int, cells: int, octaves: int = 4) -> np.ndarray:
    """Seamless value noise on the 640 px sheet (wrapped lattice)."""
    W = 640
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    total = np.zeros((W, W), dtype=np.float32)
    norm = 0.0
    amp = 1.0
    for o in range(octaves):
        n = max(2, cells * (2 ** o))
        lattice = rng.random((n, n)).astype(np.float32)
        fx = xx / W * n
        fy = yy / W * n
        x0 = np.floor(fx).astype(np.int32) % n
        y0 = np.floor(fy).astype(np.int32) % n
        tx = fx - np.floor(fx)
        ty = fy - np.floor(fy)
        tx = tx * tx * (3.0 - 2.0 * tx)
        ty = ty * ty * (3.0 - 2.0 * ty)
        x1 = (x0 + 1) % n
        y1 = (y0 + 1) % n
        v = (lattice[y0, x0] * (1.0 - tx) * (1.0 - ty)
             + lattice[y0, x1] * tx * (1.0 - ty)
             + lattice[y1, x0] * (1.0 - tx) * ty
             + lattice[y1, x1] * tx * ty)
        total += v * amp
        norm += amp
        amp *= 0.5
    return total / norm


def _nw_light(height: np.ndarray, strength: float) -> np.ndarray:
    """Fake directional lighting: NW neighbours higher means a lit NW slope."""
    shade = (np.roll(height, 1, axis=0) + np.roll(height, 1, axis=1)
             - 2.0 * height)
    return np.clip(shade * strength, -1.0, 1.0)


def _hairline_cracks(img: Image.Image, seed: int, count: int) -> Image.Image:
    """Faint 1 px fractures, wrapped at every sheet edge."""
    W = img.width
    rng = np.random.default_rng(seed)
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(count):
        x, y = rng.uniform(4, W - 4), rng.uniform(4, W - 4)
        pts = [(x, y)]
        for _ in range(int(rng.integers(2, 4))):
            x = max(2, min(W - 3, x + rng.uniform(-7, 7)))
            y = max(2, min(W - 3, y + rng.uniform(-5, 8)))
            pts.append((x, y))
        alpha = int(rng.integers(42, 74))
        for ox in (-W, 0, W):
            for oy in (-W, 0, W):
                d.line([(px + ox, py + oy) for px, py in pts],
                       fill=(118, 76, 48, alpha), width=1)
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def _sparkle(img: Image.Image, seed: int, count: int, tint) -> Image.Image:
    """Sparse crystalline highlights, kept away from the tiled edges."""
    W = img.width
    arr = np.asarray(img.convert("RGB")).astype(np.int16)
    rng = np.random.default_rng(seed)
    xs = rng.integers(3, W - 3, count)
    ys = rng.integers(3, W - 3, count)
    arr[ys, xs] = np.clip(arr[ys, xs] + np.array(tint, dtype=np.int16), 0, 255)
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def make_clean_rock() -> Image.Image:
    """Warm weathered terracotta-sandstone with crisp sediment grain."""
    W = 640
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    height = (0.47 * _tile_noise(311, 3, 4)
              + 0.27 * _tile_noise(312, 8, 3)
              + 0.26 * _tile_noise(313, 20, 2))
    height += (0.045 * np.sin(2 * np.pi * (xx + 2 * yy) / W + 0.7)
               + 0.028 * np.sin(2 * np.pi * (3 * xx - yy) / W + 2.1))
    h = (height - height.min()) / max(float(height.max() - height.min()), 1.0e-6)
    light = np.array([224.0, 160.0, 108.0], dtype=np.float32)
    dark = np.array([160.0, 96.0, 58.0], dtype=np.float32)
    img = dark[None, None, :] + (light - dark)[None, None, :] * h[..., None]
    patches = _tile_noise(314, 2, 3) - 0.5
    img += patches[..., None] * np.array([18.0, 10.0, 3.0])
    # Broad sediment strata, warmed by the same ochre light as the dunes.
    strata = 0.5 + 0.5 * np.sin(2 * np.pi * (5 * xx + 11 * yy) / W + height * 2.1)
    img += (strata - 0.5)[..., None] * np.array([9.0, 5.0, 1.5])
    # Fine granular rock: two high-frequency layers, not a polygon web.
    grit = _tile_noise(315, 130, 2)
    img += (grit - 0.5)[..., None] * 11.0
    img += (_tile_noise(316, 300, 1) - 0.5)[..., None] * 5.0
    # Sparse granular speckle: light quartz and dark iron grains.
    speck = _tile_noise(319, 360, 1)
    img += np.clip((speck - 0.76) * 90.0, 0.0, 1.0)[..., None] * np.array([16.0, 13.0, 9.0])
    img -= np.clip((0.24 - speck) * 90.0, 0.0, 1.0)[..., None] * np.array([14.0, 13.0, 11.0])
    shade = _nw_light(height, 125.0)
    img += np.clip(shade, 0.0, 1.0)[..., None] * np.array([38.0, 28.0, 18.0])
    img -= np.clip(-shade, 0.0, 1.0)[..., None] * np.array([19.0, 17.0, 15.0])
    rng = np.random.default_rng(317)
    img += rng.integers(-3, 4, (W, W, 1)).astype(np.float32)
    rock = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    rock = _hairline_cracks(rock, 410, 36)
    rock = _wrap_dust_and_pebbles(rock, 404, 12, 60, (242, 205, 154), 10)
    return _sparkle(rock, 318, 280, (13, 9, 6))


def make_clean_sand() -> Image.Image:
    """Golden-peach dunes with continuous diagonal wind bands and pebbles.

    Every wave phase uses an integer wave vector, so the light/shadow bands
    flow straight across sheet borders when adjacent tiles are drawn. A slow
    noise warp bends the crests by only a few pixels; it never breaks a band
    into a square patch or a tile-local streak.
    """
    W = 640
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    broad = (0.60 * _tile_noise(511, 2, 3) + 0.40 * _tile_noise(512, 7, 2))
    medium = 0.64 * _tile_noise(517, 4, 3) + 0.36 * _tile_noise(518, 11, 2)
    # Main wind bands run NW -> SE. The secondary and micro trains share that
    # direction, so they read as fine ribbing inside continuous dune waves.
    phase = (2 * np.pi * (yy * 5.0 + xx * 7.0) / W + broad * 2.6)
    fine_phase = (2 * np.pi * (yy * 13.0 + xx * 19.0) / W
                  + broad * 3.4 + medium * 1.2)
    micro_phase = (2 * np.pi * (yy * 23.0 + xx * 33.0) / W
                   + broad * 1.9 + medium * 0.8)
    band = 0.5 + 0.5 * np.sin(phase)
    fine = 0.5 + 0.5 * np.sin(fine_phase)
    micro = 0.5 + 0.5 * np.sin(micro_phase)
    crest = smoothstep(0.42, 0.96, band)
    trough = smoothstep(0.42, 0.96, 1.0 - band)
    h = 0.47 + 0.19 * (band - 0.5) + 0.055 * (fine - 0.5) + 0.022 * (micro - 0.5) + 0.05 * (broad - 0.5)
    light = np.array([247.0, 212.0, 168.0], dtype=np.float32)
    dark = np.array([193.0, 146.0, 96.0], dtype=np.float32)
    img = dark[None, None, :] + (light - dark)[None, None, :] * h[..., None]
    # Sunlit crest and warm slip-face shadow create the illustrated wave read.
    img += crest[..., None] * np.array([25.0, 18.0, 8.0])
    img -= trough[..., None] * np.array([19.0, 16.0, 12.0])
    img += (medium - 0.5)[..., None] * np.array([7.0, 4.0, 0.5])
    img += (fine - 0.5)[..., None] * np.array([4.0, 3.0, 1.8])
    img += (micro - 0.5)[..., None] * np.array([2.0, 1.5, 0.9])
    shade = _nw_light(band * 0.68 + fine * 0.18 + broad * 0.14, 64.0)
    img += np.clip(shade, 0.0, 1.0)[..., None] * np.array([14.0, 10.0, 5.0])
    img -= np.clip(-shade, 0.0, 1.0)[..., None] * np.array([10.0, 8.0, 5.0])
    img += (_tile_noise(513, 120, 2) - 0.5)[..., None] * 5.0
    img += (_tile_noise(516, 300, 1) - 0.5)[..., None] * 2.4
    img += (_tile_noise(521, 210, 2) - 0.5)[..., None] * 2.8
    rng = np.random.default_rng(514)
    img += rng.integers(-3, 4, (W, W, 1)).astype(np.float32)
    sand = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    sand = _wrap_dust_and_pebbles(sand, 505, 10, 34, (251, 229, 195), 8)
    return _sparkle(sand, 515, 240, (13, 10, 7))


def make_cliff_atlas() -> Image.Image:
    """16-frame warm sandstone cliff overlay with crisp dark rims."""
    frames = []
    for mask in range(16):
        rng = np.random.default_rng(500 + mask * 97)
        img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        # North lip: sunlit sandstone edge over a hard, dark undercut.
        if not (mask & 1):
            for x in range(TILE):
                yy = 3 + int(round(1.2 * math.sin(x * 0.47) + 0.5 * math.sin(x * 1.1)))
                d.point((x, max(0, yy - 1)), fill=CLIFF_SUN)
                d.point((x, yy), fill=CLIFF_LIP)
                d.point((x, min(TILE - 1, yy + 1)), fill=CLIFF_DEEP)
                d.point((x, min(TILE - 1, yy + 2)), fill=CLIFF_SHADOW)
            for _ in range(3):
                x = int(rng.integers(2, TILE - 3))
                d.line([(x, 2), (x + int(rng.integers(-2, 3)), int(rng.integers(4, 8)))],
                       fill=CLIFF_SHADOW)
        # West rim: bright windward shoulder stepping into the plateau.
        if not (mask & 8):
            for y in range(TILE):
                xx = 3 + int(round(1.8 * math.sin(y * 0.31 + 1.7) + 0.8 * math.sin(y * 0.93)))
                d.point((max(0, xx - 1), y), fill=CLIFF_SUN)
                d.point((xx, y), fill=CLIFF_LIP)
                d.line([(xx + 1, y), (min(TILE - 1, xx + 3), y)], fill=CLIFF_FACE_LIT)
                d.point((min(TILE - 1, xx + 4), y), fill=CLIFF_DEEP)
        # East wall: a crisp near-black rim against the open sand.
        if not (mask & 2):
            for y in range(TILE):
                xx = TILE - 3 - int(round(1.8 * math.sin(y * 0.37 + 0.4) + 0.7 * math.sin(y * 0.89)))
                d.point((min(TILE - 1, xx + 2), y), fill=CLIFF_FACE_LIT)
                d.point((min(TILE - 1, xx + 1), y), fill=CLIFF_FACE_MID)
                d.line([(max(0, xx - 2), y), (xx, y)], fill=CLIFF_DEEP)
                d.point((max(0, xx - 3), y), fill=CLIFF_SHADOW)
            for _ in range(4):
                y = int(rng.integers(1, TILE - 2))
                d.line([(TILE - 3, y), (TILE - int(rng.integers(6, 12)), y + int(rng.integers(-3, 4)))],
                       fill=CLIFF_SHADOW)
        # South face: jagged stratified wall with a dark overhanging sill.
        if not (mask & 4):
            tops = []
            for x in range(TILE):
                yy = 20 + 2.8 * math.sin(x * 0.38 + 0.6) + 1.5 * math.sin(x * 0.91 + 2.1)
                yy += float(rng.integers(-1, 2))
                tops.append(max(17, min(27, int(round(yy)))))
            d.polygon([(0, tops[0])] + [(x, tops[x]) for x in range(1, TILE)] + [(TILE - 1, TILE), (0, TILE)],
                      fill=CLIFF_FACE)
            for x in range(TILE):
                top = tops[x]
                d.point((x, max(0, top - 2)), fill=CLIFF_SUN)
                d.point((x, max(0, top - 1)), fill=CLIFF_LIP)
                d.point((x, top), fill=CLIFF_SHADOW)
                d.line([(x, min(TILE - 1, top + 1)), (x, TILE - 1)],
                       fill=CLIFF_FACE_MID if (x // 3) % 2 else CLIFF_FACE)
                if x % 4 == (mask % 4):
                    d.point((x, min(TILE - 1, top + 3)), fill=CLIFF_DEEP)
            for band_y in range(29, TILE, 4):
                for x in range(TILE):
                    if tops[x] + 2 < band_y:
                        d.point((x, band_y + (x % 3 == 0)),
                                fill=CLIFF_DEEP if band_y % 8 else CLIFF_FACE_LIT)
            for _ in range(6):
                x0 = int(rng.integers(2, TILE - 3))
                y0 = tops[x0] + 1
                pts = [(x0, y0)]
                y, x = y0, x0
                for _ in range(int(rng.integers(2, 5))):
                    x = max(1, min(TILE - 2, x + int(rng.integers(-3, 4))))
                    y = min(TILE - 1, y + int(rng.integers(2, 6)))
                    pts.append((x, y))
                d.line(pts, fill=CLIFF_SHADOW)
                d.line([(min(TILE - 1, p[0] + 1), p[1]) for p in pts], fill=CLIFF_FACE_LIT)
            for _ in range(5):
                x = int(rng.integers(1, TILE - 6))
                w = int(rng.integers(2, 6))
                y = int(rng.integers(31, 37))
                d.rectangle([x, y, x + w, min(TILE - 1, y + 2)], fill=CLIFF_FACE_MID)
                d.line([(x, y), (x + w, y)], fill=CLIFF_LIP)
                d.point((x + 1, y + 1), fill=CLIFF_DEEP)
            d.rectangle([0, TILE - 2, TILE - 1, TILE - 1], fill=CLIFF_SHADOW)
        frames.append(img)
    strip = Image.new("RGBA", (TILE * 16, TILE), (0, 0, 0, 0))
    for mask, frame in enumerate(frames):
        strip.alpha_composite(frame, (mask * TILE, 0))
    return strip


def spice_bloom(seed: int, dense: bool) -> np.ndarray:
    """One feathered, granular spice bloom with no tile-shaped boundary."""
    rng = np.random.default_rng(seed)
    W = SPICE_BLOOM
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    center = (W - 1) * 0.5
    dx = (xx - center) / (W * 0.5)
    dy = (yy - center) / (W * 0.5)
    radius = np.sqrt(dx * dx + dy * dy)
    angle = np.arctan2(dy, dx)
    phase = rng.uniform(0.0, math.tau)
    # A softly broken, wind-eaten perimeter. The stamp never touches its cell
    # border, so overlapping stamps cannot create a 40 px square grid.
    wobble = (1.0 + 0.065 * np.sin(3.0 * angle + phase)
              + 0.035 * np.sin(7.0 * angle - phase * 1.7)
              + 0.018 * np.sin(11.0 * angle + phase * 0.6))
    warped = radius * wobble
    edge = 1.0 - smoothstep(0.32, 1.02, warped)
    lattice = (rng.random((11, 11)) * 255.0).astype(np.uint8)
    noise_img = Image.fromarray(lattice, "L").resize((W, W), Image.Resampling.BICUBIC)
    noise_img = noise_img.filter(ImageFilter.GaussianBlur(5.0))
    variation = np.asarray(noise_img, dtype=np.float32) / 255.0
    density = np.clip(edge * (0.56 + 0.44 * variation), 0.0, 1.0)

    halo_col = np.array((188.0, 92.0, 35.0) if dense else (216.0, 139.0, 76.0))
    arr = np.zeros((W, W, 4), dtype=np.float32)
    arr[..., :3] = halo_col[None, None, :]
    arr[..., 3] = density * (0.43 if dense else 0.40) * 255.0
    if dense:
        core = np.clip((1.0 - smoothstep(0.04, 0.76, warped)) * edge, 0.0, 1.0)
        core_col = np.array((112.0, 34.0, 10.0), dtype=np.float32)
        arr[..., :3] = arr[..., :3] * (1.0 - core[..., None]) + core_col * core[..., None]
        arr[..., 3] = np.maximum(arr[..., 3], core * 255.0 * 0.52)
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
    draw = ImageDraw.Draw(img)

    cluster_count = 16 if dense else 12
    clusters = []
    for _ in range(cluster_count):
        a = rng.uniform(0.0, math.tau)
        r = math.sqrt(rng.uniform(0.0, 0.72)) * W * 0.5
        clusters.append((W * 0.5 + math.cos(a) * r, W * 0.5 + math.sin(a) * r * 0.92))

    # Burnt-orange gravel clusters: each clump gets a dark undershadow, a
    # saturated mid-body and a tiny sunlit NW facet. These are deliberately
    # clustered around the same irregular islands as the fine grit so the
    # bloom reads as granular rock rather than an airbrushed orange cloud.
    for _ in range(46 if dense else 22):
        cx, cy = clusters[int(rng.integers(0, len(clusters)))]
        x = rng.normal(cx, rng.uniform(1.5, 6.0))
        y = rng.normal(cy, rng.uniform(1.0, 4.2))
        rr = rng.uniform(1.1, 3.2) * (1.15 if dense else 0.85)
        ry = rr * rng.uniform(0.55, 0.82)
        ix, iy = int(x), int(y)
        if ix < 2 or iy < 2 or ix >= W - 2 or iy >= W - 2:
            continue
        if rng.random() > float(density[iy, ix]) * 0.88:
            continue
        draw.ellipse([x - rr + 0.8, y - ry + 0.9, x + rr + 0.8, y + ry + 0.9],
                     fill=(73, 28, 8, 76))
        col = SPICE_DEEP[int(rng.integers(0, len(SPICE_DEEP)))] if dense else SPICE_MID[0]
        draw.ellipse([x - rr, y - ry, x + rr, y + ry],
                     fill=(*col, int(rng.integers(150, 224))))
        draw.point((ix - 1, iy - 1), fill=(*SPICE_DUST[2], int(rng.integers(120, 205))))

    # A few larger translucent clumps fuse the gravel islands at RTS zoom.
    for _ in range(18 if dense else 7):
        a = rng.uniform(0.0, math.tau)
        r = math.sqrt(rng.uniform(0.0, 0.58 if dense else 0.68)) * W * 0.5
        x = W * 0.5 + math.cos(a) * r
        y = W * 0.5 + math.sin(a) * r * 0.92
        rr = rng.uniform(2.4, 6.0)
        col = SPICE_MID[int(rng.integers(0, len(SPICE_MID)))] if dense else SPICE_DUST[2]
        draw.ellipse([x - rr, y - rr * 0.70, x + rr, y + rr * 0.70],
                     fill=(*col, int(rng.integers(54, 92)) if dense else int(rng.integers(36, 62))))

    grain_count = 1250 if dense else 780
    for _ in range(grain_count):
        if rng.random() < 0.72:
            cx, cy = clusters[int(rng.integers(0, len(clusters)))]
            x = rng.normal(cx, rng.uniform(2.0, 7.0))
            y = rng.normal(cy, rng.uniform(1.5, 5.0))
        else:
            a = rng.uniform(0.0, math.tau)
            r = math.sqrt(rng.uniform(0.0, 0.84)) * W * 0.5
            x = W * 0.5 + math.cos(a) * r
            y = W * 0.5 + math.sin(a) * r * 0.92
        ix, iy = int(x), int(y)
        if ix < 2 or iy < 2 or ix >= W - 2 or iy >= W - 2:
            continue
        if rng.random() > float(density[iy, ix]) * 0.94 + 0.04:
            continue
        r = math.hypot(x - W * 0.5, y - W * 0.5) / (W * 0.5)
        if dense:
            if r < 0.26 and rng.random() < 0.70:
                col = SPICE_DEEP[int(rng.integers(0, len(SPICE_DEEP)))]
            elif r < 0.60 and rng.random() < 0.64:
                col = SPICE_MID[int(rng.integers(0, len(SPICE_MID)))]
            else:
                col = SPICE_DUST[int(rng.integers(0, len(SPICE_DUST)))]
        else:
            col = SPICE_DUST[int(rng.integers(0, len(SPICE_DUST)))] if rng.random() < 0.76 else SPICE_MID[0]
        rr = rng.uniform(0.5, 1.55)
        alpha = int(rng.integers(132, 246))
        draw.ellipse([x - rr, y - rr * 0.72, x + rr, y + rr * 0.72], fill=(*col, alpha))
        if alpha > 165 and rng.random() < 0.28:
            draw.point((ix + 1, iy + 1), fill=(66, 24, 7, min(255, alpha + 8)))
        if alpha > 165 and rng.random() < 0.38:
            draw.point((ix - 1, iy - 1), fill=(*SPICE_DUST[0], min(255, alpha + 16)))

    out = np.asarray(img, dtype=np.uint8).copy()
    # Guaranteed transparent margin: runtime draws these stamps larger than a
    # tile and lets their halos overlap in every direction.
    out[:2, :, 3] = 0
    out[-2:, :, 3] = 0
    out[:, :2, 3] = 0
    out[:, -2:, 3] = 0
    return out


def make_spice_blooms() -> list[np.ndarray]:
    # Four dusty stamps carry low-density fields, four dense stamps add the
    # deep rust cores. Both sets keep the same soft outer feather.
    dusty = [spice_bloom(6101 + i * 43, False) for i in range(4)]
    dense = [spice_bloom(7101 + i * 59, True) for i in range(4)]
    return dusty + dense


def verify_spice_blooms(blooms: list[np.ndarray]) -> None:
    for i, arr in enumerate(blooms):
        assert arr.shape == (SPICE_BLOOM, SPICE_BLOOM, 4), f"bloom cell {i} shape"
        assert np.all(arr[:2, :, 3] == 0) and np.all(arr[-2:, :, 3] == 0), f"bloom cell {i} vertical edge"
        assert np.all(arr[:, :2, 3] == 0) and np.all(arr[:, -2:, 3] == 0), f"bloom cell {i} horizontal edge"
    print("spice blooms: 4 dusty + 4 dense, transparent 2 px edges")


def verify_clean_wrap(name: str, img: Image.Image) -> None:
    """Fail if a 2x2 tiling would show a brighter/darker edge seam."""
    a = np.asarray(img.convert("RGB"), dtype=np.int16)
    for axis, label in ((1, "horizontal"), (0, "vertical")):
        wrap = np.abs(a[:, 0] - a[:, -1]).mean() if axis == 1 else np.abs(a[0, :] - a[-1, :]).mean()
        interior = (np.abs(np.diff(a, axis=1)).mean() if axis == 1
                    else np.abs(np.diff(a, axis=0)).mean())
        ratio = wrap / max(interior, 1.0e-6)
        print(f"seam check {name} {label}: wrap={wrap:.2f} interior={interior:.2f} ratio={ratio:.2f}")
        assert ratio < 1.35, f"{name} {label} wrap seam ratio {ratio:.2f}"


def write_strip(variants: list[np.ndarray], path: Path) -> None:
    strip = Image.new("RGBA", (TILE * len(variants), TILE), (0, 0, 0, 0))
    for i, arr in enumerate(variants):
        strip.alpha_composite(Image.fromarray(arr, "RGBA"), (i * TILE, 0))
    strip.save(path)


def write_bloom_strip(blooms: list[np.ndarray], path: Path) -> None:
    strip = Image.new("RGBA", (SPICE_BLOOM * len(blooms), SPICE_BLOOM), (0, 0, 0, 0))
    for i, arr in enumerate(blooms):
        strip.alpha_composite(Image.fromarray(arr, "RGBA"), (i * SPICE_BLOOM, 0))
    strip.save(path)


def verify_edges(variants: list[np.ndarray]) -> None:
    first = variants[0]
    for i, arr in enumerate(variants[1:], 1):
        assert np.array_equal(arr[:2], first[:2]), f"top edge {i}"
        assert np.array_equal(arr[-2:], first[-2:]), f"bottom edge {i}"
        assert np.array_equal(arr[:, :2], first[:, :2]), f"left edge {i}"
        assert np.array_equal(arr[:, -2:], first[:, -2:]), f"right edge {i}"
        assert np.all(arr[:2, :, 3] == 0) and np.all(arr[-2:, :, 3] == 0)
        assert np.all(arr[:, :2, 3] == 0) and np.all(arr[:, -2:, 3] == 0)
    print("edge check: all variants share identical RGB edge noise and feathered alpha=0 borders")


def preview(rock: list[np.ndarray], sand: list[np.ndarray]) -> None:
    # Show how the runtime will composite: continuous sheet, then deterministic
    # soft variants per cell. A clean preview here means no visible tile grid.
    cols, rows = 14, 10
    rock_src = Image.open(CLEAN_ROCK if CLEAN_ROCK.exists() else OUT_DIR / "terrain_rock.png").convert("RGBA")
    base = Image.new("RGBA", (TILE * cols, TILE * rows), (0, 0, 0, 255))
    for y in range(rows):
        for x in range(cols):
            base.alpha_composite(rock_src.crop((x * TILE, y * TILE, (x + 1) * TILE, (y + 1) * TILE)), (x * TILE, y * TILE))
    sheet = base.copy()
    for y in range(rows):
        for x in range(cols):
            h = (x * 73856093) ^ (y * 19349663)
            h = abs(h ^ (h >> 13))
            v = h % len(rock)
            sheet.alpha_composite(Image.fromarray(rock[v], "RGBA"), (x * TILE, y * TILE))
    sheet.resize((sheet.width * 4, sheet.height * 4), Image.Resampling.NEAREST).save(BUILD_DIR / "terrain_variants_preview.png")
    atlas = Image.new("RGBA", (TILE * 4 * (len(rock) + len(sand)), TILE * 4), (0, 0, 0, 255))
    for i, arr in enumerate(rock + sand):
        atlas.alpha_composite(Image.fromarray(arr, "RGBA").resize((TILE * 4, TILE * 4), Image.Resampling.NEAREST), (i * TILE * 4, 0))
    atlas.save(BUILD_DIR / "terrain_variants_atlas_preview.png")
    # Sand stress view over the original seamless sand.
    sand_sheet = Image.new("RGBA", (TILE * cols, TILE * rows), (0, 0, 0, 255))
    sand_src = Image.open(CLEAN_SAND if CLEAN_SAND.exists() else OUT_DIR / "terrain_sand.png").convert("RGBA")
    for y in range(rows):
        for x in range(cols):
            sand_sheet.alpha_composite(sand_src.crop((x * TILE, y * TILE, (x + 1) * TILE, (y + 1) * TILE)), (x * TILE, y * TILE))
            h = (x * 374761393) ^ (y * 668265263)
            h = abs(h ^ (h >> 13))
            sand_sheet.alpha_composite(Image.fromarray(sand[h % len(sand)], "RGBA"), (x * TILE, y * TILE))
    sand_sheet.resize((sand_sheet.width * 4, sand_sheet.height * 4), Image.Resampling.NEAREST).save(BUILD_DIR / "terrain_sand_variants_preview.png")

def main() -> None:
    rock = make_rock_variants()
    sand = make_sand_variants()
    verify_edges(rock)
    verify_edges(sand)
    clean_rock = make_clean_rock()
    clean_sand = make_clean_sand()
    cliffs = make_cliff_atlas()
    blooms = make_spice_blooms()
    verify_clean_wrap("rock", clean_rock)
    verify_clean_wrap("sand", clean_sand)
    verify_spice_blooms(blooms)
    clean_rock.save(CLEAN_ROCK)
    clean_sand.save(CLEAN_SAND)
    cliffs.save(OUT_DIR / "terrain_cliff.png")
    write_strip(rock, OUT_DIR / "terrain_rock_variants.png")
    write_strip(sand, OUT_DIR / "terrain_sand_variants.png")
    write_bloom_strip(blooms, SPICE_BLOOMS)
    preview(rock, sand)
    print("wrote", CLEAN_ROCK, "seamless clean base")
    print("wrote", CLEAN_SAND, "seamless clean base")
    print("wrote", OUT_DIR / "terrain_cliff.png", "16 warm cliff masks")
    print("wrote", OUT_DIR / "terrain_rock_variants.png", len(rock), "variants")
    print("wrote", OUT_DIR / "terrain_sand_variants.png", len(sand), "variants")
    print("wrote", SPICE_BLOOMS, len(blooms), "organic bloom cells")


if __name__ == "__main__":
    main()
