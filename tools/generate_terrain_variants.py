#!/usr/bin/env python3
"""Bake deterministic, seamless terrain variants without touching the source sheets.

Outputs:
  assets/sprites/d2/terrain_rock_clean.png      640 px seamless base
  assets/sprites/d2/terrain_sand_clean.png      640 px seamless base
  assets/sprites/d2/terrain_rock_variants.png   8 x 40px cells
  assets/sprites/d2/terrain_sand_variants.png   4 x 40px cells

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
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets/sprites/d2"
BUILD_DIR = ROOT / "build"
TILE = 40

ROCK_PAL = [(201, 129, 82), (186, 109, 62), (153, 85, 49), (108, 60, 37)]
SAND_PAL = [(230, 204, 163), (216, 184, 136), (190, 154, 105), (158, 122, 79)]
CLEAN_ROCK = OUT_DIR / "terrain_rock_clean.png"
CLEAN_SAND = OUT_DIR / "terrain_sand_clean.png"


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
    specs = [(0.00, 1, 0, 0.55), (0.35, 2, 1, 0.72), (0.00, 1, 0, 0.55),
             (0.00, 0, 0, 0.00), (0.20, 1, 0, 0.50), (0.55, 3, 2, 0.76),
             (0.00, 1, 0, 0.48), (0.30, 2, 0, 0.62)]
    return [
        finish_variant(base, spec[0], spec[1], spec[2], 1000 + i * 37, spec[3])
        for i, spec in enumerate(specs)
    ]


def make_sand_variants() -> list[np.ndarray]:
    base = make_sand_base()
    specs = [(0.00, 0, 0, 0.00), (0.20, 1, 0, 0.35),
             (0.00, 1, 0, 0.30), (0.18, 2, 0, 0.38)]
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
    """Seamful dust and pebbles, drawn with wrapped duplicates at the edges."""
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
    d = ImageDraw.Draw(base)
    for _ in range(pebble_count):
        x, y = rng.uniform(0, W), rng.uniform(0, W)
        rr = rng.uniform(1.3, 3.0)
        for ox in (-W, 0, W):
            for oy in (-W, 0, W):
                X, Y = x + ox, y + oy
                d.ellipse([X - rr, Y - rr * 0.7, X + rr, Y + rr * 0.7],
                          fill=(108, 69, 43))
                d.arc([X - rr, Y - rr * 0.7, X + rr, Y + rr * 0.7],
                      190, 330, fill=(205, 158, 104))
    return base


def make_clean_rock() -> Image.Image:
    """A new seamless terracotta sheet without the legacy 40 px tint cells."""
    W = 640
    rng = np.random.default_rng(20261122)
    sites = np.stack([rng.uniform(0, W, 68), rng.uniform(0, W, 68)], axis=1)
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    d1 = np.full((W, W), 1.0e9, dtype=np.float32)
    d2 = np.full((W, W), 1.0e9, dtype=np.float32)
    idx = np.zeros((W, W), dtype=np.int32)
    for i, (sx, sy) in enumerate(sites):
        dx = np.abs(xx - sx)
        dx = np.minimum(dx, W - dx)
        dy = np.abs(yy - sy)
        dy = np.minimum(dy, W - dy)
        d = np.sqrt(dx * dx + dy * dy)
        closer = d < d1
        d2 = np.where(closer, d1, np.minimum(d2, d))
        d1 = np.where(closer, d, d1)
        idx = np.where(closer, i, idx)
    wave = (0.45 * np.sin(2 * np.pi * (xx / W) + 0.4)
            + 0.25 * np.sin(2 * np.pi * (yy / W) + 2.1)
            + 0.15 * np.sin(2 * np.pi * (2 * xx / W + yy / W) + 0.8)
            + 0.10 * np.sin(2 * np.pi * (xx / W - 2 * yy / W) + 1.4))
    wave = (wave - wave.min()) / (wave.max() - wave.min())
    light = np.array([207.0, 139.0, 88.0], dtype=np.float32)
    dark = np.array([166.0, 94.0, 55.0], dtype=np.float32)
    base = dark[None, None, :] + (light - dark)[None, None, :] * wave[..., None]
    # Warm-only plate variation: never let a plate drift green in the desert.
    warm = np.random.default_rng(99).normal(0.0, 1.0, 68)
    base = base * (1.0 + warm[idx, None] * 0.025)
    base = base + warm[idx, None] * np.array([2.8, 1.3, 0.0])
    grain = (np.sin(xx * 2.7 + yy * 1.3) * 0.5
             + np.sin(xx * 5.1 - yy * 3.7) * 0.3
             + np.sin(yy * 7.3) * 0.2)
    base = base + grain[..., None] * 2.4
    base = base + np.random.default_rng(707).normal(0.0, 4.0, (W, W, 3))
    edge = d2 - d1
    crack = np.clip((4.0 - edge) / 3.0, 0.0, 1.0)[..., None]
    crack_col = np.array([116.0, 70.0, 43.0], dtype=np.float32)
    img = base * (1.0 - crack * 0.72) + crack_col[None, None, :] * (crack * 0.72)
    lip = (np.clip((edge - 3.5) / 1.5, 0.0, 1.0)
           * np.clip((4.0 - edge) / 1.2, 0.0, 1.0))
    img = img + lip[..., None] * np.array([14.0, 9.0, 4.0])
    clean = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")
    clean = _add_hairlines(clean, 606, 74)
    return _wrap_dust_and_pebbles(clean, 404, 24, 58, (226, 190, 142), 14)


def make_clean_sand() -> Image.Image:
    """A new seamless dune sheet with no legacy vertical seam or tint cells."""
    W = 640
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float32)
    dune = (0.55 + 0.16 * np.sin(2 * np.pi * (xx + 2 * yy) / W + 0.6)
            + 0.09 * np.sin(2 * np.pi * (2 * xx - yy) / W + 2.0)
            + 0.04 * np.sin(2 * np.pi * (4 * xx + 3 * yy) / W + 1.2))
    dune = np.clip(dune, 0.0, 1.0)
    light = np.array([233.0, 211.0, 174.0], dtype=np.float32)
    dark = np.array([207.0, 174.0, 126.0], dtype=np.float32)
    base = dark[None, None, :] + (light - dark)[None, None, :] * dune[..., None]
    grain = (np.sin(xx * 3.7 + yy * 1.9) * 0.5
             + np.sin(xx * 7.1 - yy * 4.3) * 0.3
             + np.sin(yy * 9.1) * 0.2)
    base = base + grain[..., None] * 2.2
    base = base + np.random.default_rng(808).normal(0.0, 2.2, (W, W, 3))
    phase = (2 * np.pi * (yy * 6 + xx * 2 + 8 * np.sin(2 * np.pi * xx / W)) / W
             + dune * 2.6)
    ripple = np.sin(phase)
    crest = np.clip((ripple - 0.55) / 0.45, 0.0, 1.0)
    trough = np.clip((-ripple - 0.55) / 0.45, 0.0, 1.0)
    base = (base + crest[..., None] * np.array([9.0, 7.0, 4.0])
            - trough[..., None] * np.array([7.0, 6.0, 4.0]))
    return _wrap_dust_and_pebbles(
        Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB"),
        505, 20, 44, (245, 225, 191), 14)


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
    verify_clean_wrap("rock", clean_rock)
    verify_clean_wrap("sand", clean_sand)
    clean_rock.save(CLEAN_ROCK)
    clean_sand.save(CLEAN_SAND)
    write_strip(rock, OUT_DIR / "terrain_rock_variants.png")
    write_strip(sand, OUT_DIR / "terrain_sand_variants.png")
    preview(rock, sand)
    print("wrote", CLEAN_ROCK, "seamless clean base")
    print("wrote", CLEAN_SAND, "seamless clean base")
    print("wrote", OUT_DIR / "terrain_rock_variants.png", len(rock), "variants")
    print("wrote", OUT_DIR / "terrain_sand_variants.png", len(sand), "variants")


if __name__ == "__main__":
    main()
