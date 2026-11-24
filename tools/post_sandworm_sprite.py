"""Cut the generated Sandworm sprites off their magenta key and prepare RGBA
textures for the game.

Run:
    .tools-venv/bin/python tools/post_sandworm_sprite.py

Inputs:
    build/raw_worm_ridge.jpg
    build/raw_worm_maw.jpg

Outputs:
    assets/sprites/sandworm/ridge.png
    assets/sprites/sandworm/maw.png
    build/worm_ridge_cutout.png (sand-coloured review image)
    build/worm_maw_cutout.png
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
OUT = ROOT / "assets" / "sprites" / "sandworm"


def key_magenta(image: Image.Image) -> Image.Image:
    rgb = np.asarray(image.convert("RGB"), dtype=np.float32)
    h, w, _ = rgb.shape
    corners = np.concatenate([
        rgb[:24, :24].reshape(-1, 3), rgb[:24, -24:].reshape(-1, 3),
        rgb[-24:, :24].reshape(-1, 3), rgb[-24:, -24:].reshape(-1, 3),
    ])
    bg = np.median(corners, axis=0)
    dist = np.sqrt(np.sum((rgb - bg) ** 2, axis=2))
    # The key is far from every sand/bone/gum colour. Distance gives a soft edge
    # instead of the stair-step silhouette a hard threshold leaves behind.
    alpha = np.clip((dist - 56.0) / 34.0, 0.0, 1.0)
    # Decontaminate edge pixels: remove the magenta key's contribution from
    # semi-transparent antialiased pixels before they are composited in-game.
    safe = np.maximum(alpha, 1e-4)[..., None]
    cleaned = (rgb - (1.0 - safe) * bg) / safe
    cleaned = np.clip(cleaned, 0.0, 255.0)
    # The generator also paints a soft magenta rim a few pixels inside the
    # silhouette.  Cap the blue channel toward green for every warm pixel: this
    # turns that rim back into sand/brown without touching the red gums.
    rr, gg, bb = cleaned[..., 0], cleaned[..., 1], cleaned[..., 2]
    spill = bb > gg + 2.0
    # Real sand has blue below green.  Pull any surviving key colour toward the
    # green channel and knock down the red as well, otherwise the bright magenta
    # patches turn into pink salmon rather than desert ochre.
    cleaned[..., 2] = np.where(spill, gg * 0.95, bb)
    cleaned[..., 0] = np.where(spill, (rr + gg) * 0.5, rr)
    rgba = np.dstack([cleaned, alpha * 255.0]).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")
    # Shrink the matte two pixels, then feather: this cuts the remaining magenta
    # key fringe without eating into the silhouette at gameplay scale.
    matte = out.getchannel("A").filter(ImageFilter.MinFilter(5))
    out.putalpha(matte.filter(ImageFilter.GaussianBlur(0.55)))
    return out


def premultiplied_resize(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    arr = np.asarray(image.convert("RGBA"), dtype=np.float32)
    alpha = arr[..., 3:4] / 255.0
    premultiplied = np.concatenate([arr[..., :3] * alpha, arr[..., 3:4]], axis=2)
    small = Image.fromarray(premultiplied.astype(np.uint8), "RGBA").resize(
        size, Image.Resampling.LANCZOS)
    small_arr = np.asarray(small, dtype=np.float32)
    small_alpha = np.maximum(small_arr[..., 3:4] / 255.0, 1e-4)
    small_arr[..., :3] = np.clip(small_arr[..., :3] / small_alpha, 0.0, 255.0)
    return Image.fromarray(small_arr.astype(np.uint8), "RGBA")


def grade_sand(image: Image.Image, mix: float = 0.30) -> Image.Image:
    """Lift warm sand toward the game's pale desert without bleaching the plates."""
    arr = np.asarray(image.convert("RGBA")).astype(np.float32)
    rr, gg, bb = arr[..., 0], arr[..., 1], arr[..., 2]
    sand = (rr > 140.0) & (gg > 95.0) & (bb < gg * 0.96) & (arr[..., 3] > 8.0)
    target = np.array([232.0, 205.0, 166.0], dtype=np.float32)
    arr[..., :3] = np.where(sand[..., None], arr[..., :3] * (1.0 - mix) + target * mix, arr[..., :3])
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def mask_ridge_teardrop(image: Image.Image, rx: float = 185.0, ry: float = 390.0) -> Image.Image:
    """Replace the generated leaf-shaped plate edge with a soft organic wake."""
    arr = np.asarray(image.convert("RGBA")).astype(np.float32)
    h, w = arr.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    nx = (xx - w * 0.5) / rx
    ny = (yy - h * 0.5) / ry
    theta = np.arctan2(ny, nx)
    wobble = 1.0 + 0.055 * np.sin(theta * 5.0 + 0.6) + 0.035 * np.sin(theta * 8.0 - 1.3)
    radius = np.sqrt(nx * nx + ny * ny) / wobble
    fade = np.clip((1.0 - radius) / 0.16, 0.0, 1.0)
    arr[..., 3] *= fade
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def feather_edges(image: Image.Image, blur: float, erode: int = 0) -> Image.Image:
    matte = image.getchannel("A")
    if erode > 0:
        matte = matte.filter(ImageFilter.MinFilter(erode * 2 + 1))
    halo = matte.filter(ImageFilter.GaussianBlur(blur))
    feathered = Image.fromarray(
        (np.asarray(matte, dtype=np.float32) * (np.asarray(halo, dtype=np.float32) / 255.0))
        .astype(np.uint8), "L")
    out = image.copy()
    out.putalpha(feathered)
    return out


def scrub_pink(image: Image.Image) -> Image.Image:
    """Replace the last few generator-painted magenta pixels with local sand."""
    arr = np.asarray(image.convert("RGBA")).copy()
    rr, gg, bb = arr[..., 0].astype(np.int16), arr[..., 1].astype(np.int16), arr[..., 2].astype(np.int16)
    mask = (bb > gg + 1) & (rr > gg + 5) & (gg < 235) & (rr < 252) & (bb < 235)
    if mask.any():
        local = np.asarray(image.filter(ImageFilter.MedianFilter(9)).convert("RGBA"))
        arr[mask] = local[mask]
    return Image.fromarray(arr, "RGBA")


def square_trim(image: Image.Image, margin: int = 20) -> Image.Image:
    alpha = np.asarray(image.getchannel("A"))
    ys, xs = np.where(alpha > 6)
    if len(xs) == 0:
        raise RuntimeError("keyed sprite is empty")
    x0, x1 = int(xs.min()), int(xs.max()) + 1
    y0, y1 = int(ys.min()), int(ys.max()) + 1
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    side = max(x1 - x0, y1 - y0) + margin * 2
    half = side // 2
    box = (cx - half, cy - half, cx + half, cy + half)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image.crop((max(box[0], 0), max(box[1], 0),
                             min(box[2], image.width), min(box[3], image.height))),
                 (max(-box[0], 0), max(-box[1], 0)))
    # Keep the texture square and power-of-two friendly for mobile GPUs.
    resized = premultiplied_resize(canvas, (768, 768))
    arr = np.asarray(resized, dtype=np.float32)
    rr, gg, bb = arr[..., 0], arr[..., 1], arr[..., 2]
    spill = bb > gg + 2.0
    arr[..., 2] = np.where(spill, gg * 0.95, bb)
    arr[..., 0] = np.where(spill, (rr + gg) * 0.5, rr)
    cleaned = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")
    return cleaned


def review(image: Image.Image, path: Path) -> None:
    bg = Image.new("RGBA", image.size, (196, 154, 104, 255))
    # A coarse checker helps spot leftover key pixels in the transparent margin.
    arr = np.asarray(bg).copy()
    step = image.width // 16
    for y in range(0, image.height, step):
        for x in range(0, image.width, step):
            if (x + y) // step % 2 == 0:
                arr[y:y + step, x:x + step, :3] = (178, 138, 92)
    bg = Image.fromarray(arr, "RGBA")
    bg.alpha_composite(image)
    bg.convert("RGB").save(path)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    # Ridge 3 is already a narrow vertical trough with the head at the bottom;
    # no rotation is needed before the runtime aligns it with move_dir.
    raw_ridge = Image.open(BUILD / "raw_worm_ridge3.jpg").convert("RGB")
    ridge = key_magenta(raw_ridge)
    ridge = square_trim(ridge)
    ridge = grade_sand(ridge, 0.18)
    ridge = scrub_pink(ridge)
    ridge = feather_edges(ridge, 11.0, erode=3)
    ridge = scrub_pink(ridge)
    ridge.save(OUT / "ridge.png")
    review(ridge, BUILD / "worm_ridge_cutout.png")

    maw = key_magenta(Image.open(BUILD / "raw_worm_maw.jpg"))
    maw = square_trim(maw)
    maw = feather_edges(maw, 8.0, erode=2)
    maw.save(OUT / "maw.png")
    review(maw, BUILD / "worm_maw_cutout.png")
    print("SANDWORM CUTOUTS COMPLETE")


if __name__ == "__main__":
    main()
