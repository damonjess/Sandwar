"""Bake every Sandwar unit sheet and portrait with Blender Cycles.

Run:
    blender --background --python tools/blender_bake_units.py [-- trike,tank]

Layouts match scripts/unit_art.gd exactly:
  vehicles   16 cols x 1 row, cell = UnitArt.CELLS[id] * 2
  infantry   4 pose cols x 8 compass rows, cell = UnitArt.CELLS[id] * 2
  tank       tank_hull.png + tank_turret.png (60 px cells, 16 frames)
  harvester  empty/half/full sheets (62 px cells, 16 frames)

House trim is baked magenta for the faction shader; portraits use blue trim
for BuildingArt/UnitArt.hud_material(). Cycles prefers OptiX, then CUDA, then
CPU. Small 2x cells and 64 samples stay comfortably inside a 4 GB GPU.
"""
from __future__ import annotations

import math
import os
import sys
from pathlib import Path

import bpy
import numpy as np
from PIL import Image, ImageEnhance, ImageFilter
from mathutils import Vector

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
import blender_bake_buildings as bb  # noqa: E402

OUT_DIR = ROOT / "assets" / "sprites" / "units"
ICON_DIR = ROOT / "assets" / "icons" / "units"
FRAME_DIR = ROOT / "build" / "blender_frames" / "units"
RENDER_SCALE = 2
ICON_PX = 64
SAMPLES = int(os.environ.get("BAKE_UNIT_SAMPLES", "64"))

CELLS = {
    "infantry": 36, "rocket": 38, "fremen": 38, "sardaukar": 40, "saboteur": 36,
    "trike": 48, "raider_trike": 48, "quad": 50,
    "tank": 60, "atreides_tank": 60, "harkonnen_tank": 62, "ordos_tank": 58,
    "sonic_tank": 62, "devastator": 66, "deviator": 60,
    "harvester": 62, "carryall": 96,
}
VIEW = {
    "trike": 2.05, "raider_trike": 2.05, "quad": 2.05,
    "atreides_tank": 2.22, "harkonnen_tank": 2.30, "ordos_tank": 2.16,
    "sonic_tank": 2.32, "devastator": 2.50, "deviator": 2.20,
    "carryall": 3.20, "tank": 2.15, "harvester": 2.25,
}
INFANTRY = ("infantry", "rocket", "fremen", "sardaukar", "saboteur")
ICON_IDS = ("infantry", "rocket", "fremen", "sardaukar", "saboteur", "trike",
            "raider_trike", "quad", "atreides_tank", "harkonnen_tank",
            "ordos_tank", "sonic_tank", "devastator", "deviator", "harvester")
M = {}


def srgb(color):
    return tuple(((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92 for c in color)


def material(name, base, metallic, rough, rust=0.0, dirt=0.3, bump=0.3,
             emission=None, strength=0.0, trim=False):
    return bb.surface(name, srgb(base), metallic, rough, rust=rust, dirt=dirt,
                      bump=bump, emission=srgb(emission) if emission else None,
                      emission_strength=strength, trim=trim)


def build_materials() -> None:
    M["trim"] = material("Unit Magenta", (0.880, 0.020, 0.560), 0.18, 0.44,
                         dirt=0.10, emission=(0.70, 0.010, 0.430), strength=0.18, trim=True)
    M["trim_blue"] = material("Unit Blue", (0.150, 0.420, 0.930), 0.18, 0.44,
                              dirt=0.10, emission=(0.10, 0.30, 0.80), strength=0.12, trim=True)
    M["steel"] = material("Unit Steel", (0.310, 0.320, 0.305), 0.72, 0.42, rust=0.30, dirt=0.42)
    M["steel_light"] = material("Unit Steel Light", (0.500, 0.510, 0.485), 0.64, 0.38, rust=0.20, dirt=0.38)
    M["gunmetal"] = material("Unit Gunmetal", (0.135, 0.150, 0.150), 0.78, 0.44, rust=0.16, dirt=0.40)
    M["olive"] = material("Unit Olive", (0.335, 0.375, 0.335), 0.34, 0.68, rust=0.18, dirt=0.48)
    M["olive_light"] = material("Unit Olive Light", (0.490, 0.525, 0.475), 0.28, 0.60, rust=0.12, dirt=0.42)
    M["armor"] = material("Unit Armor", (0.560, 0.600, 0.560), 0.40, 0.54, rust=0.10, dirt=0.34)
    M["armor_light"] = material("Unit Armor Light", (0.730, 0.755, 0.690), 0.30, 0.48, rust=0.06, dirt=0.28)
    M["rubber"] = material("Unit Rubber", (0.045, 0.045, 0.040), 0.02, 0.94, rust=0.0, dirt=0.2)
    M["dark"] = material("Unit Dark", (0.032, 0.034, 0.032), 0.20, 0.82, rust=0.0, dirt=0.2)
    M["rust"] = material("Unit Rust", (0.300, 0.130, 0.050), 0.18, 0.84, dirt=0.24)
    M["glass"] = material("Unit Glass", (0.020, 0.095, 0.105), 0.35, 0.18,
                          dirt=0.04, emission=(0.025, 0.260, 0.240), strength=0.45)
    M["skin"] = material("Unit Skin", (0.430, 0.270, 0.175), 0.02, 0.88, dirt=0.1)
    M["cloth"] = material("Unit Cloth", (0.300, 0.275, 0.225), 0.02, 0.92, dirt=0.3)
    M["cloth_dark"] = material("Unit Cloth Dark", (0.115, 0.125, 0.105), 0.02, 0.94, dirt=0.25)
    M["fremen_suit"] = material("Fremen Stillsuit", (0.165, 0.220, 0.250), 0.04, 0.82, dirt=0.24)
    M["sardaukar"] = material("Sardaukar Armor", (0.245, 0.265, 0.250), 0.58, 0.44, rust=0.08, dirt=0.30)
    M["ordos"] = material("Ordos Green", (0.105, 0.300, 0.160), 0.34, 0.52, rust=0.10, dirt=0.36)
    M["gas"] = material("Deviator Gas", (0.080, 0.360, 0.130), 0.20, 0.40,
                         dirt=0.1, emission=(0.05, 0.60, 0.16), strength=0.9)
    M["sonic"] = material("Sonic Blue", (0.200, 0.390, 0.470), 0.55, 0.32,
                          dirt=0.1, emission=(0.08, 0.42, 0.55), strength=0.8)
    M["cyan"] = material("Unit Cyan", (0.020, 0.470, 0.430), 0.10, 0.28,
                         dirt=0.05, emission=(0.03, 1.0, 0.85), strength=2.0)
    M["amber"] = material("Unit Amber", (0.600, 0.230, 0.030), 0.05, 0.32,
                          dirt=0.05, emission=(1.0, 0.33, 0.03), strength=2.5)
    M["spice"] = material("Unit Spice", (0.700, 0.230, 0.025), 0.08, 0.66,
                          dirt=0.05, emission=(0.95, 0.20, 0.02), strength=0.5)
    M["yellow"] = material("Unit Hazard", (0.840, 0.520, 0.060), 0.22, 0.56, dirt=0.25)
    M["white"] = material("Unit Bone", (0.780, 0.750, 0.660), 0.14, 0.62, dirt=0.2)


# --------------------------------------------------------------- primitives

def box(size, loc, mat, rot=(0.0, 0.0, 0.0), bevel=0.008):
    return bb.box(size, loc, mat, rot=rot, bevel=bevel)


def cyl(radius, depth, loc, mat, axis="Z", verts=20, bevel=0.005):
    return bb.cyl(radius, depth, loc, mat, axis=axis, verts=verts, bevel=bevel)


def sphere(radius, loc, mat, scale=(1.0, 1.0, 1.0)):
    return bb.sphere(radius, loc, mat, scale=scale, segments=20, rings=10)


def pipe(a, b, radius, mat):
    return bb.pipe(a, b, radius, mat)


def group(parts, angle=0.0):
    return bb.group_root(parts, angle)


def wheel(parts, x, y, radius=0.19, width=0.14):
    parts.append(cyl(radius, width, (x, y, radius), M["rubber"], axis="Y", verts=20))
    parts.append(cyl(radius * 0.45, width + 0.02, (x, y, radius), M["steel_light"], axis="Y", verts=14))
    parts.append(cyl(radius * 0.16, width + 0.03, (x, y, radius), M["dark"], axis="Y", verts=10))


def tracks(parts, side, x0=-0.48, x1=0.48, radius=0.19):
    y = side * 0.40
    parts.append(box((abs(x1 - x0) + 0.12, 0.17, 0.15), ((x0 + x1) * 0.5, y, radius), M["rubber"], bevel=0.01))
    for i in range(7):
        t = i / 6.0
        parts.append(box((0.12, 0.19, 0.035), (x0 + (x1 - x0) * t, y, radius * 2.0), M["gunmetal"], bevel=0.004))
    for i in range(4):
        wheel(parts, x0 + (x1 - x0) * i / 3.0, y, radius, 0.16)


def trim_strip(parts, size, loc, rot=(0.0, 0.0, 0.0)):
    parts.append(box(size, loc, M["trim"], rot=rot, bevel=0.003))


# ------------------------------------------------------------------ infantry

def build_infantry(kind, anim=0):
    parts = []
    heavy = kind == "rocket"
    stride = 0.09 if anim == 1 else (-0.09 if anim == 2 else 0.0)
    recoil = 0.045 if anim == 3 else 0.0
    body = M["armor"] if kind not in ("fremen", "saboteur", "sardaukar") else None
    for side in (-1.0, 1.0):
        s = stride * side
        if kind == "fremen":
            parts.append(box((0.12, 0.12, 0.26), (s, side * 0.10, 0.14), M["fremen_suit"]))
            parts.append(box((0.15, 0.14, 0.07), (s + 0.03, side * 0.10, 0.035), M["cloth_dark"]))
        elif kind == "sardaukar":
            parts.append(box((0.17, 0.17, 0.25), (s, side * 0.12, 0.13), M["gunmetal"]))
            parts.append(box((0.20, 0.18, 0.09), (s + 0.03, side * 0.12, 0.04), M["rubber"]))
        elif kind == "saboteur":
            parts.append(box((0.11, 0.11, 0.24), (s, side * 0.10, 0.13), M["cloth_dark"]))
            parts.append(box((0.14, 0.13, 0.07), (s + 0.03, side * 0.10, 0.03), M["rubber"]))
        else:
            parts.append(box((0.13, 0.13, 0.23), (s, side * 0.105, 0.13), M["steel"]))
            parts.append(box((0.16, 0.14, 0.08), (s + 0.035, side * 0.105, 0.035), M["rubber"]))
            parts.append(box((0.11, 0.11, 0.10), (s, side * 0.105, 0.27), body))
    if kind == "fremen":
        parts.append(box((0.30, 0.30, 0.30), (0.0, 0.0, 0.30), M["cloth"]))
        parts.append(box((0.28, 0.26, 0.34), (0.0, 0.0, 0.54), M["fremen_suit"]))
        for i in range(3):
            parts.append(box((0.035, 0.015, 0.22), (-0.07 + i * 0.07, 0.135, 0.54), M["steel_light"], bevel=0.0))
        trim_strip(parts, (0.07, 0.02, 0.32), (0.09, 0.145, 0.52), (0.0, math.radians(-14.0), 0.0))
        trim_strip(parts, (0.20, 0.02, 0.035), (0.0, 0.145, 0.68))
        parts.append(box((0.06, 0.34, 0.55), (-0.18, 0.0, 0.42), M["cloth"], rot=(0.0, math.radians(8.0), 0.0)))
        parts.append(sphere(0.115, (0.005, 0.0, 0.80), M["cloth"], (1.0, 1.0, 1.15)))
        parts.append(box((0.20, 0.21, 0.14), (-0.02, 0.0, 0.84), M["cloth"]))
        parts.append(box((0.10, 0.21, 0.10), (0.075, 0.0, 0.78), M["cloth_dark"]))
        parts.append(box((0.035, 0.16, 0.03), (0.125, 0.0, 0.80), M["sonic"]))
        parts.append(box((0.60, 0.06, 0.055), (0.31 - recoil, 0.12, 0.60), M["gunmetal"]))
        parts.append(cyl(0.032, 0.26, (0.28 - recoil, 0.12, 0.66), M["dark"], axis="X", verts=12))
        parts.append(cyl(0.025, 0.10, (0.64 - recoil, 0.12, 0.60), M["steel_light"], axis="X", verts=10))
        if anim == 3:
            parts.append(sphere(0.04, (0.70 - recoil, 0.12, 0.60), M["amber"], (1.0, 1.0, 1.0)))
        for side in (-1.0, 1.0):
            parts.append(box((0.15, 0.10, 0.10), (0.07 - recoil, side * 0.19, 0.55), M["fremen_suit"]))
    elif kind == "sardaukar":
        parts.append(box((0.40, 0.34, 0.38), (0.0, 0.0, 0.49), M["sardaukar"]))
        parts.append(box((0.28, 0.35, 0.24), (0.10, 0.0, 0.52), M["armor_light"]))
        parts.append(box((0.33, 0.35, 0.075), (0.015, 0.0, 0.32), M["gunmetal"]))
        parts.append(box((0.20, 0.26, 0.30), (-0.23, 0.0, 0.53), M["gunmetal"]))
        for side in (-1.0, 1.0):
            parts.append(box((0.26, 0.16, 0.15), (0.02, side * 0.235, 0.66), M["sardaukar"], rot=(side * 0.1, 0.0, 0.0)))
            trim_strip(parts, (0.20, 0.13, 0.045), (0.03, side * 0.235, 0.735))
        parts.append(sphere(0.11, (0.02, 0.0, 0.80), M["sardaukar"], (1.0, 1.0, 1.1)))
        parts.append(box((0.22, 0.21, 0.13), (0.0, 0.0, 0.885), M["sardaukar"]))
        trim_strip(parts, (0.05, 0.20, 0.17), (0.005, 0.0, 0.985))
        parts.append(box((0.09, 0.19, 0.06), (0.10, 0.0, 0.86), M["glass"]))
        parts.append(box((0.62, 0.09, 0.09), (0.38 - recoil, 0.16, 0.54), M["gunmetal"]))
        parts.append(cyl(0.075, 0.10, (0.30 - recoil, 0.16, 0.45), M["steel_light"], axis="X", verts=14))
        parts.append(cyl(0.030, 0.12, (0.68 - recoil, 0.16, 0.54), M["dark"], axis="X", verts=10))
        if anim == 3:
            parts.append(sphere(0.045, (0.73 - recoil, 0.16, 0.54), M["amber"]))
        for side in (-1.0, 1.0):
            parts.append(box((0.17, 0.12, 0.11), (0.09 - recoil, side * 0.22, 0.55), M["sardaukar"]))
    elif kind == "saboteur":
        parts.append(box((0.26, 0.24, 0.32), (0.0, 0.0, 0.49), M["cloth"]))
        parts.append(box((0.22, 0.26, 0.05), (0.0, 0.0, 0.35), M["gunmetal"]))
        trim_strip(parts, (0.05, 0.02, 0.26), (0.08, 0.125, 0.50), (0.0, math.radians(-18.0), 0.0))
        parts.append(box((0.20, 0.20, 0.28), (-0.19, 0.0, 0.44), M["cloth_dark"]))
        for i in range(3):
            parts.append(cyl(0.045, 0.20, (-0.19, 0.115, 0.35 + i * 0.075), M["amber"], axis="X", verts=10))
        parts.append(box((0.075, 0.05, 0.055), (-0.19, 0.10, 0.60), M["sonic"]))
        parts.append(cyl(0.012, 0.26, (-0.19, 0.10, 0.71), M["steel_light"], verts=6))
        parts.append(sphere(0.105, (0.015, 0.0, 0.76), M["cloth"], (1.0, 1.0, 1.1)))
        parts.append(box((0.19, 0.20, 0.10), (0.0, 0.0, 0.85), M["cloth"]))
        parts.append(box((0.07, 0.17, 0.05), (0.10, 0.0, 0.78), M["glass"]))
        parts.append(box((0.42, 0.06, 0.06), (0.32 - recoil, 0.13, 0.54), M["gunmetal"]))
        parts.append(box((0.12, 0.07, 0.10), (0.10 - recoil, 0.13, 0.52), M["steel"]))
        if anim == 3:
            parts.append(sphere(0.045, (0.56 - recoil, 0.13, 0.54), M["amber"]))
        for side in (-1.0, 1.0):
            parts.append(box((0.14, 0.09, 0.09), (0.06 - recoil, side * 0.17, 0.51), M["cloth"]))
    else:
        parts.append(box((0.32, 0.30, 0.36), (0.0, 0.0, 0.48), M["armor"]))
        parts.append(box((0.21, 0.31, 0.23), (0.10, 0.0, 0.50), M["armor_light"]))
        parts.append(box((0.27, 0.31, 0.075), (0.015, 0.0, 0.33), M["gunmetal"]))
        trim_strip(parts, (0.055, 0.26, 0.06), (0.06, 0.0, 0.68))
        parts.append(box((0.18, 0.24, 0.27), (-0.20, 0.0, 0.52), M["gunmetal"]))
        parts.append(box((0.07, 0.08, 0.15), (-0.225, 0.11, 0.56), M["cyan"]))
        parts.append(sphere(0.105, (0.015, 0.0, 0.79), M["skin"], (1.0, 1.0, 1.1)))
        parts.append(box((0.19, 0.19, 0.11), (0.0, 0.0, 0.885), M["armor"]))
        parts.append(box((0.10, 0.20, 0.075), (0.085, 0.0, 0.84), M["glass"]))
        for side in (-1.0, 1.0):
            parts.append(box((0.21, 0.13, 0.11), (0.02, side * 0.21, 0.65), M["armor_light"]))
            trim_strip(parts, (0.17, 0.12, 0.035), (0.03, side * 0.21, 0.71))
        if heavy:
            parts.append(box((0.18, 0.33, 0.09), (0.12, 0.0, 0.59), M["steel"]))
            for side in (-1.0, 1.0):
                parts.append(cyl(0.065, 0.52, (0.31 - recoil, side * 0.13, 0.70), M["gunmetal"], axis="X", verts=14))
                parts.append(cyl(0.08, 0.08, (0.58 - recoil, side * 0.13, 0.70), M["rust"], axis="X", verts=14))
                parts.append(cyl(0.05, 0.06, (0.64 - recoil, side * 0.13, 0.70), M["dark"], axis="X", verts=12))
                trim_strip(parts, (0.09, 0.11, 0.08), (-0.01, side * 0.21, 0.59))
            parts.append(cyl(0.028, 0.18, (-0.27, 0.0, 0.34), M["amber"], verts=8))
        else:
            parts.append(box((0.54, 0.07, 0.06), (0.40 - recoil, 0.15, 0.54), M["gunmetal"]))
            parts.append(box((0.16, 0.06, 0.12), (0.18 - recoil, 0.15, 0.53), M["steel"]))
            parts.append(box((0.10, 0.08, 0.10), (0.31 - recoil, 0.15, 0.47), M["rust"]))
            parts.append(cyl(0.020, 0.10, (0.64 - recoil, 0.15, 0.54), M["dark"], axis="X", verts=10))
            if anim == 3:
                parts.append(sphere(0.045, (0.69 - recoil, 0.15, 0.54), M["amber"]))
        for side in (-1.0, 1.0):
            parts.append(box((0.16, 0.10, 0.10), (0.10 - recoil, side * 0.20, 0.51), M["armor"],
                             rot=(0.0, 0.0, side * 0.17)))
    return group(parts, 0.0)


# ------------------------------------------------------------------ vehicles

def build_trike():
    p = []
    wheel(p, -0.24, -0.40, 0.21, 0.15)
    wheel(p, -0.24, 0.40, 0.21, 0.15)
    wheel(p, 0.43, 0.0, 0.20, 0.15)
    p.append(box((0.72, 0.48, 0.16), (-0.04, 0.0, 0.30), M["olive"]))
    p.append(box((0.42, 0.42, 0.11), (-0.15, 0.0, 0.42), M["olive_light"]))
    p.append(box((0.32, 0.34, 0.16), (0.40, 0.0, 0.33), M["steel"]))
    trim_strip(p, (0.14, 0.16, 0.035), (0.53, 0.0, 0.39))
    p.append(box((0.08, 0.38, 0.12), (0.52, 0.0, 0.25), M["rust"]))
    for x in (-0.28, 0.18):
        for y in (-0.20, 0.20):
            p.append(box((0.045, 0.045, 0.56), (x, y, 0.59), M["steel_light"]))
    for y in (-0.20, 0.20):
        p.append(box((0.55, 0.045, 0.045), (-0.05, y, 0.87), M["steel_light"]))
    p.append(box((0.045, 0.44, 0.045), (0.20, 0.0, 0.87), M["steel_light"]))
    p.append(box((0.24, 0.40, 0.18), (-0.33, 0.0, 0.43), M["gunmetal"]))
    for y in (-0.14, 0.14):
        p.append(cyl(0.045, 0.32, (-0.47, y, 0.48), M["rust"], axis="X", verts=10))
    p.append(box((0.20, 0.12, 0.08), (0.02, 0.0, 0.88), M["gunmetal"]))
    p.append(cyl(0.024, 0.42, (0.28, 0.0, 0.91), M["dark"], axis="X", verts=10))
    p.append(cyl(0.042, 0.08, (0.48, 0.0, 0.91), M["steel_light"], axis="X", verts=10))
    return group(p, 0.0)


def build_quad():
    p = []
    for x in (-0.32, 0.32):
        for y in (-0.40, 0.40):
            wheel(p, x, y, 0.20, 0.14)
    p.append(box((0.82, 0.62, 0.20), (0.0, 0.0, 0.28), M["olive"]))
    p.append(box((0.56, 0.52, 0.13), (0.10, 0.0, 0.42), M["olive_light"]))
    p.append(box((0.28, 0.54, 0.15), (0.48, 0.0, 0.35), M["steel"]))
    trim_strip(p, (0.13, 0.30, 0.035), (0.56, 0.0, 0.44))
    p.append(box((0.28, 0.54, 0.17), (-0.40, 0.0, 0.42), M["gunmetal"]))
    for y in (-0.18, 0.18):
        p.append(box((0.04, 0.035, 0.12), (-0.50, y, 0.42), M["rubber"]))
    for i in range(3):
        p.append(box((0.035, 0.40, 0.10), (-0.30 + i * 0.06, 0.0, 0.50), M["dark"]))
    p.append(box((0.22, 0.30, 0.17), (0.16, 0.0, 0.55), M["gunmetal"]))
    for y in (-0.10, 0.10):
        p.append(cyl(0.035, 0.56, (0.54, y, 0.57), M["dark"], axis="X", verts=12))
        p.append(cyl(0.052, 0.10, (0.78, y, 0.57), M["steel_light"], axis="X", verts=10))
    trim_strip(p, (0.10, 0.20, 0.07), (0.20, 0.0, 0.67))
    return group(p, 0.0)


def build_raider():
    p = []
    wheel(p, -0.30, -0.44, 0.23, 0.17)
    wheel(p, -0.30, 0.44, 0.23, 0.17)
    wheel(p, 0.47, 0.0, 0.215, 0.16)
    p.append(box((0.82, 0.52, 0.12), (-0.03, 0.0, 0.27), M["olive"]))
    p.append(box((0.44, 0.40, 0.10), (-0.16, 0.0, 0.38), M["olive_light"]))
    p.append(box((0.30, 0.38, 0.12), (0.44, 0.0, 0.30), M["steel"], rot=(0.0, 0.0, -0.1)))
    trim_strip(p, (0.10, 0.24, 0.03), (0.58, 0.0, 0.36))
    for y in (-0.22, 0.22):
        p.append(box((0.05, 0.05, 0.46), (-0.10, y, 0.56), M["steel_light"], rot=(0.0, -0.17, 0.0)))
        p.append(box((0.46, 0.045, 0.045), (0.06, y, 0.80), M["steel_light"]))
    p.append(box((0.34, 0.54, 0.025), (-0.46, 0.0, 0.66), M["trim"]))
    p.append(box((0.22, 0.38, 0.20), (-0.40, 0.0, 0.41), M["gunmetal"]))
    for y in (-0.12, 0.12):
        p.append(cyl(0.045, 0.30, (-0.54, y, 0.48), M["rust"], axis="X", verts=10))
        p.append(box((0.20, 0.07, 0.07), (0.28, y, 0.47), M["gunmetal"]))
        p.append(cyl(0.030, 0.46, (0.58, y, 0.47), M["dark"], axis="X", verts=10))
        p.append(cyl(0.050, 0.07, (0.80, y, 0.47), M["steel_light"], axis="X", verts=10))
    trim_strip(p, (0.12, 0.34, 0.04), (0.24, 0.0, 0.53))
    return group(p, 0.0)


def build_combat_tank(house):
    p = []
    wide = house == "harkonnen"
    tracks(p, -1.0, -0.50, 0.50, 0.19)
    tracks(p, 1.0, -0.50, 0.50, 0.19)
    if wide:
        p.append(box((1.16, 0.80, 0.22), (0.0, 0.0, 0.36), M["olive"]))
        p.append(box((1.16, 0.10, 0.16), (0.0, -0.44, 0.34), M["steel"]))
        p.append(box((1.16, 0.10, 0.16), (0.0, 0.44, 0.34), M["steel"]))
        p.append(box((0.34, 0.72, 0.20), (0.52, 0.0, 0.42), M["steel"], rot=(0.0, 0.0, -0.1)))
        for y in (-0.47, 0.47):
            p.append(box((0.78, 0.06, 0.24), (-0.02, y, 0.40), M["gunmetal"]))
            for i in range(3):
                trim_strip(p, (0.06, 0.075, 0.06), (-0.28 + i * 0.26, y, 0.45))
        p.append(box((0.50, 0.52, 0.24), (-0.02, 0.0, 0.59), M["sardaukar"]))
        p.append(box((0.30, 0.40, 0.20), (0.24, 0.0, 0.61), M["steel"], rot=(0.0, 0.0, -0.14)))
        p.append(cyl(0.085, 0.62, (0.50, 0.0, 0.62), M["gunmetal"], axis="X", verts=14))
        p.append(cyl(0.135, 0.16, (0.83, 0.0, 0.62), M["rust"], axis="X", verts=12))
        p.append(cyl(0.105, 0.06, (0.91, 0.0, 0.62), M["dark"], axis="X", verts=12))
        for y in (-0.30, 0.30):
            trim_strip(p, (0.26, 0.12, 0.035), (0.50, y, 0.56))
            p.append(cyl(0.055, 0.34, (-0.52, y * 0.87, 0.70), M["rust"], verts=10))
            p.append(cyl(0.08, 0.07, (-0.52, y * 0.87, 0.88), M["dark"], verts=10))
    elif house == "ordos":
        p.append(box((1.00, 0.66, 0.16), (0.0, 0.0, 0.34), M["ordos"]))
        p.append(box((0.38, 0.58, 0.14), (0.50, 0.0, 0.39), M["olive_light"], rot=(0.0, 0.0, -0.2)))
        p.append(box((0.56, 0.40, 0.08), (-0.12, 0.0, 0.44), M["gunmetal"]))
        for i in range(4):
            p.append(box((0.035, 0.50, 0.09), (-0.42 + i * 0.06, 0.0, 0.46), M["dark"]))
        p.append(box((0.34, 0.36, 0.16), (0.0, 0.0, 0.54), M["steel"]))
        p.append(box((0.20, 0.28, 0.12), (0.20, 0.0, 0.56), M["steel_light"], rot=(0.0, 0.0, -0.17)))
        for y in (-0.10, 0.10):
            p.append(cyl(0.038, 0.68, (0.56, y, 0.57), M["dark"], axis="X", verts=12))
            p.append(cyl(0.055, 0.07, (0.93, y, 0.57), M["steel_light"], axis="X", verts=10))
        p.append(cyl(0.012, 0.42, (-0.14, 0.10, 0.84), M["steel_light"], verts=6))
        p.append(cyl(0.10, 0.035, (-0.12, 0.12, 0.98), M["ordos"], axis="Y", verts=14))
        for y in (-0.28, 0.28):
            trim_strip(p, (0.22, 0.10, 0.03), (0.48, y, 0.50))
    else:
        p.append(box((1.06, 0.70, 0.18), (0.0, 0.0, 0.36), M["olive"]))
        p.append(box((0.88, 0.56, 0.13), (0.02, 0.0, 0.49), M["olive_light"]))
        p.append(box((0.32, 0.62, 0.16), (0.52, 0.0, 0.42), M["steel"], rot=(0.0, 0.0, -0.16)))
        for y in (-0.38, 0.38):
            p.append(box((0.80, 0.06, 0.10), (0.0, y, 0.34), M["steel"]))
        p.append(box((0.40, 0.42, 0.20), (-0.02, 0.0, 0.55), M["steel"]))
        p.append(box((0.26, 0.32, 0.18), (0.21, 0.0, 0.58), M["steel_light"], rot=(0.0, 0.0, -0.12)))
        p.append(cyl(0.060, 0.72, (0.50, 0.0, 0.60), M["gunmetal"], axis="X", verts=14))
        p.append(cyl(0.095, 0.14, (0.89, 0.0, 0.60), M["rust"], axis="X", verts=12))
        p.append(cyl(0.080, 0.05, (0.955, 0.0, 0.60), M["dark"], axis="X", verts=12))
        trim_strip(p, (0.15, 0.30, 0.035), (-0.08, 0.0, 0.66))
        for y in (-0.30, 0.30):
            trim_strip(p, (0.24, 0.10, 0.035), (0.48, y, 0.51))
        p.append(cyl(0.012, 0.44, (-0.16, 0.13, 0.86), M["steel_light"], verts=6))
        p.append(box((0.06, 0.06, 0.06), (-0.17, 0.13, 1.08), M["cyan"]))
        for y in (-0.23, 0.23):
            p.append(cyl(0.045, 0.26, (-0.55, y, 0.62), M["rust"], axis="X", verts=10))
    return group(p, 0.0)


def build_tank_hull():
    p = []
    tracks(p, -1.0, -0.48, 0.48, 0.19)
    tracks(p, 1.0, -0.48, 0.48, 0.19)
    p.append(box((1.02, 0.72, 0.18), (0.0, 0.0, 0.36), M["olive"]))
    p.append(box((0.88, 0.58, 0.13), (0.02, 0.0, 0.50), M["olive_light"]))
    p.append(box((0.34, 0.66, 0.20), (0.43, 0.0, 0.44), M["steel"], rot=(0.0, 0.0, -0.14)))
    for y in (-0.39, 0.39):
        p.append(box((0.88, 0.085, 0.20), (0.0, y, 0.32), M["steel"]))
    for i in range(4):
        for y in (-0.435, 0.435):
            trim_strip(p, (0.035, 0.065, 0.035), (-0.34 + i * 0.22, y, 0.31))
    p.append(box((0.40, 0.66, 0.20), (-0.44, 0.0, 0.47), M["gunmetal"]))
    for i in range(4):
        p.append(box((0.035, 0.52, 0.10), (-0.55 + i * 0.075, 0.0, 0.54), M["dark"]))
    for y in (-0.24, 0.24):
        p.append(cyl(0.040, 0.28, (-0.58, y, 0.64), M["rust"], axis="X", verts=10))
    for y in (-0.27, 0.27):
        trim_strip(p, (0.26, 0.12, 0.035), (0.46, y, 0.56))
    return group(p, 0.0)


def build_tank_turret():
    p = []
    p.append(box((0.40, 0.42, 0.22), (-0.02, 0.0, 0.76), M["steel"]))
    p.append(box((0.28, 0.34, 0.20), (0.20, 0.0, 0.79), M["steel_light"], rot=(0.0, 0.0, -0.14)))
    trim_strip(p, (0.15, 0.28, 0.035), (-0.09, 0.0, 0.895))
    p.append(cyl(0.065, 0.70, (0.50, 0.0, 0.80), M["gunmetal"], axis="X", verts=14))
    p.append(cyl(0.105, 0.14, (0.88, 0.0, 0.80), M["rust"], axis="X", verts=12))
    p.append(cyl(0.085, 0.05, (0.945, 0.0, 0.80), M["dark"], axis="X", verts=12))
    p.append(cyl(0.085, 0.075, (-0.06, 0.0, 0.90), M["steel_light"], verts=12))
    p.append(cyl(0.030, 0.20, (-0.22, -0.16, 0.92), M["gunmetal"], verts=8))
    trim_strip(p, (0.18, 0.08, 0.035), (0.05, 0.20, 0.92))
    return group(p, 0.0)


def build_tank():
    p = []
    tracks(p, -1.0, -0.48, 0.48, 0.19)
    tracks(p, 1.0, -0.48, 0.48, 0.19)
    p.append(box((1.02, 0.72, 0.18), (0.0, 0.0, 0.36), M["olive"]))
    p.append(box((0.88, 0.58, 0.13), (0.02, 0.0, 0.50), M["olive_light"]))
    p.append(box((0.34, 0.66, 0.20), (0.43, 0.0, 0.44), M["steel"], rot=(0.0, 0.0, -0.14)))
    p.append(box((0.40, 0.42, 0.22), (-0.02, 0.0, 0.76), M["steel"]))
    p.append(box((0.28, 0.34, 0.20), (0.20, 0.0, 0.79), M["steel_light"], rot=(0.0, 0.0, -0.14)))
    p.append(cyl(0.065, 0.70, (0.50, 0.0, 0.80), M["gunmetal"], axis="X", verts=14))
    p.append(cyl(0.105, 0.14, (0.88, 0.0, 0.80), M["rust"], axis="X", verts=12))
    p.append(cyl(0.085, 0.05, (0.945, 0.0, 0.80), M["dark"], axis="X", verts=12))
    for y in (-0.39, 0.39):
        p.append(box((0.88, 0.085, 0.20), (0.0, y, 0.32), M["steel"]))
    for i in range(4):
        for y in (-0.435, 0.435):
            trim_strip(p, (0.035, 0.065, 0.035), (-0.34 + i * 0.22, y, 0.31))
    return group(p, 0.0)


def build_sonic():
    p = []
    tracks(p, -1.0, -0.50, 0.50, 0.19)
    tracks(p, 1.0, -0.50, 0.50, 0.19)
    p.append(box((1.04, 0.70, 0.18), (0.0, 0.0, 0.35), M["olive"]))
    p.append(box((0.40, 0.62, 0.22), (0.40, 0.0, 0.45), M["steel"], rot=(0.0, 0.0, -0.14)))
    p.append(box((0.34, 0.56, 0.34), (-0.38, 0.0, 0.53), M["gunmetal"]))
    for i in range(3):
        p.append(cyl(0.10, 0.08, (-0.44 + i * 0.06, 0.0, 0.58), M["rust"], axis="X", verts=12))
    p.append(box((0.30, 0.30, 0.16), (0.02, 0.0, 0.64), M["steel"]))
    p.append(cyl(0.38, 0.06, (0.18, 0.0, 0.88), M["steel_light"], axis="X", verts=28))
    p.append(cyl(0.33, 0.08, (0.21, 0.0, 0.88), M["sonic"], axis="X", verts=28))
    p.append(cyl(0.23, 0.10, (0.25, 0.0, 0.88), M["dark"], axis="X", verts=24))
    p.append(cyl(0.13, 0.12, (0.30, 0.0, 0.88), M["sonic"], axis="X", verts=20))
    for i in range(12):
        a = math.tau * i / 12.0
        p.append(box((0.055, 0.05, 0.035), (0.19, math.cos(a) * 0.38, 0.88 + math.sin(a) * 0.38),
                     M["trim"], rot=(0.0, 0.0, a), bevel=0.0))
    for i in range(4):
        a = math.tau * i / 4.0 + math.pi * 0.25
        p.append(box((0.26, 0.035, 0.035), (0.28, math.cos(a) * 0.31, 0.88 + math.sin(a) * 0.31),
                     M["steel_light"], rot=(math.radians(14.0), 0.0, a)))
    for y in (-0.30, 0.30):
        p.append(cyl(0.018, 0.34, (0.12, y, 0.79), M["gunmetal"], axis="X", verts=6))
    p.append(cyl(0.022, 0.40, (0.46, 0.0, 0.92), M["sonic"], axis="X", verts=8))
    for y in (-0.31, 0.31):
        trim_strip(p, (0.22, 0.10, 0.03), (0.44, y, 0.53))
    return group(p, 0.0)


def build_devastator():
    p = []
    tracks(p, -1.0, -0.58, 0.58, 0.23)
    tracks(p, 1.0, -0.58, 0.58, 0.23)
    p.append(box((1.34, 0.96, 0.26), (0.0, 0.0, 0.40), M["olive"]))
    p.append(box((1.10, 0.80, 0.18), (0.02, 0.0, 0.56), M["olive_light"]))
    p.append(box((0.28, 0.98, 0.24), (0.68, 0.0, 0.36), M["steel"], rot=(0.0, 0.0, -0.32)))
    for y in (-0.52, 0.52):
        p.append(box((1.02, 0.09, 0.28), (-0.02, y, 0.42), M["gunmetal"]))
        for i in range(4):
            trim_strip(p, (0.05, 0.10, 0.05), (-0.42 + i * 0.26, y, 0.46))
    p.append(box((0.66, 0.72, 0.28), (-0.04, 0.0, 0.68), M["sardaukar"]))
    p.append(box((0.40, 0.58, 0.24), (0.28, 0.0, 0.70), M["steel"], rot=(0.0, 0.0, -0.12)))
    for y in (-0.20, 0.20):
        p.append(cyl(0.085, 0.66, (0.62, y, 0.70), M["gunmetal"], axis="X", verts=14))
        p.append(cyl(0.13, 0.16, (0.98, y, 0.70), M["rust"], axis="X", verts=12))
        p.append(cyl(0.10, 0.06, (1.06, y, 0.70), M["dark"], axis="X", verts=12))
        p.append(cyl(0.06, 0.14, (0.30, y, 0.84), M["steel_light"], verts=10))
    trim_strip(p, (0.22, 0.40, 0.04), (-0.12, 0.0, 0.86))
    p.append(box((0.36, 0.90, 0.28), (-0.58, 0.0, 0.60), M["gunmetal"]))
    for y in (-0.30, -0.10, 0.10, 0.30):
        p.append(cyl(0.045, 0.34, (-0.74, y, 0.80), M["rust"], verts=10))
        p.append(cyl(0.07, 0.08, (-0.74, y, 0.99), M["dark"], verts=10))
    for i in range(4):
        trim_strip(p, (0.04, 0.13, 0.20), (0.80, -0.36 + i * 0.24, 0.36), (0.0, 0.0, 0.32))
    return group(p, 0.0)


def build_deviator():
    p = []
    for x in (-0.36, 0.02, 0.40):
        for y in (-0.38, 0.38):
            wheel(p, x, y, 0.19, 0.14)
    p.append(box((0.94, 0.62, 0.16), (0.0, 0.0, 0.29), M["ordos"]))
    p.append(box((0.34, 0.50, 0.26), (0.34, 0.0, 0.48), M["olive_light"]))
    p.append(box((0.20, 0.42, 0.14), (0.47, 0.0, 0.53), M["glass"], rot=(0.0, 0.0, -0.14)))
    p.append(box((0.08, 0.52, 0.20), (0.56, 0.0, 0.34), M["steel"]))
    p.append(box((0.42, 0.60, 0.30), (-0.27, 0.0, 0.52), M["gunmetal"]))
    for row in (-1.0, 1.0):
        for y in (-0.15, 0.15):
            p.append(cyl(0.075, 0.46, (-0.04, y, 0.54 + row * 0.065), M["gas"], axis="X", verts=14))
            p.append(cyl(0.088, 0.05, (0.18, y, 0.54 + row * 0.065), M["trim"], axis="X", verts=14))
    p.append(box((0.10, 0.46, 0.05), (-0.30, 0.0, 0.70), M["ordos"]))
    for y in (-0.36, 0.36):
        p.append(cyl(0.065, 0.36, (-0.30, y, 0.38), M["gas"], axis="X", verts=12))
    p.append(cyl(0.012, 0.40, (-0.20, 0.18, 0.80), M["steel_light"], verts=6))
    p.append(cyl(0.11, 0.03, (-0.19, 0.20, 0.96), M["ordos"], axis="Y", verts=14))
    for y in (-0.26, 0.26):
        trim_strip(p, (0.20, 0.10, 0.03), (0.46, y, 0.44))
    return group(p, 0.0)


def build_harvester(fill):
    p = []
    tracks(p, -1.0, -0.56, 0.54, 0.20)
    tracks(p, 1.0, -0.56, 0.54, 0.20)
    p.append(box((1.12, 0.82, 0.24), (0.0, 0.0, 0.36), M["olive"]))
    p.append(box((0.50, 0.62, 0.38), (0.42, 0.0, 0.58), M["olive_light"]))
    p.append(box((0.32, 0.50, 0.20), (0.55, 0.0, 0.69), M["glass"]))
    p.append(box((0.05, 0.64, 0.36), (0.69, 0.0, 0.58), M["steel"]))
    trim_strip(p, (0.07, 0.26, 0.05), (0.48, 0.0, 0.88))
    p.append(box((0.58, 0.66, 0.30), (-0.30, 0.0, 0.62), M["gunmetal"]))
    p.append(box((0.48, 0.54, 0.22), (-0.30, 0.0, 0.70), M["dark"]))
    fill_h = 0.035 if fill <= 0.05 else (0.12 if fill < 0.62 else 0.22)
    p.append(box((0.42, 0.48, fill_h), (-0.30, 0.0, 0.60 + fill_h * 0.5), M["spice"]))
    for i in range(3):
        p.append(box((0.52, 0.035, 0.025), (-0.30, -0.20 + i * 0.20, 0.84), M["steel_light"]))
    for y in (-0.20, 0.20):
        trim_strip(p, (0.58, 0.045, 0.035), (-0.30, y, 0.86))
    for y in (-0.34, 0.34):
        p.append(box((0.44, 0.018, 0.13), (-0.30, y, 0.68), M["rust"]))
        if fill > 0.05:
            p.append(box((0.34, 0.022, 0.065), (-0.30, y, 0.72), M["spice"]))
    for y in (-0.23, 0.23):
        p.append(cyl(0.052, 0.48, (-0.56, y, 0.80), M["rust"], verts=10))
        p.append(cyl(0.075, 0.07, (-0.56, y, 1.05), M["dark"], verts=10))
    p.append(box((0.28, 0.76, 0.15), (0.72, 0.0, 0.20), M["steel"], rot=(0.0, 0.0, -0.24)))
    p.append(box((0.24, 0.74, 0.035), (0.74, 0.0, 0.29), M["yellow"]))
    for i in range(5):
        p.append(box((0.10, 0.075, 0.07), (0.88, -0.28 + i * 0.14, 0.12), M["steel_light"], rot=(0.0, 0.0, -0.35)))
    for y in (-0.38, 0.38):
        trim_strip(p, (0.38, 0.15, 0.035), (0.35, y, 0.49))
    return group(p, 0.0)


def build_carryall():
    p = []
    for y in (-1.02, 1.02):
        p.append(box((1.86, 0.20, 0.16), (-0.22, y, 0.78), M["olive"]))
        p.append(box((0.24, 0.06, 0.30), (-1.10, y, 0.92), M["trim"]))
        p.append(box((0.34, 0.26, 0.06), (-1.04, y, 0.79), M["steel"]))
    p.append(box((0.64, 2.18, 0.13), (-0.10, 0.0, 0.80), M["olive_light"]))
    for y in (-0.64, -0.22, 0.22, 0.64):
        p.append(box((0.50, 0.09, 0.05), (-0.10, y, 0.885), M["trim"]))
    p.append(box((1.06, 0.56, 0.42), (0.32, 0.0, 0.74), M["olive"]))
    p.append(box((0.40, 0.50, 0.30), (0.78, 0.0, 0.72), M["olive_light"], rot=(0.0, 0.0, -0.17)))
    p.append(box((0.20, 0.42, 0.19), (0.92, 0.0, 0.80), M["glass"], rot=(0.0, 0.0, -0.24)))
    p.append(box((0.10, 0.58, 0.30), (1.02, 0.0, 0.66), M["steel"], rot=(0.0, 0.0, -0.21)))
    p.append(box((0.26, 0.30, 0.12), (0.72, 0.0, 0.53), M["gunmetal"]))
    p.append(cyl(0.022, 0.46, (1.14, 0.0, 0.62), M["steel_light"], axis="X", verts=8))
    for y in (-0.72, 0.72):
        p.append(cyl(0.20, 0.86, (-0.58, y, 0.80), M["olive"], axis="X", verts=14))
        p.append(cyl(0.155, 0.10, (-1.02, y, 0.80), M["dark"], axis="X", verts=12))
        p.append(cyl(0.115, 0.06, (-1.08, y, 0.80), M["rust"], axis="X", verts=12))
        trim_strip(p, (0.34, 0.24, 0.045), (-0.50, y, 1.01))
        p.append(box((0.09, 0.70, 0.03), (-0.52, y * 1.35, 1.05), M["steel_light"]))
    p.append(box((0.62, 0.46, 0.16), (0.02, 0.0, 0.46), M["gunmetal"]))
    p.append(box((0.54, 0.16, 0.08), (0.02, 0.0, 0.36), M["dark"]))
    for y in (-0.60, 0.0, 0.60):
        p.append(box((0.09, 0.09, 0.10), (0.02, y, 0.35), M["steel"]))
        p.append(box((0.05, 0.05, 0.20), (0.02, y, 0.27), M["steel_light"]))
    trim_strip(p, (0.10, 1.30, 0.035), (0.30, 0.0, 0.90))
    trim_strip(p, (0.18, 0.62, 0.11), (0.52, 0.0, 0.95))
    return group(p, 0.0)


# ------------------------------------------------------------------- baking

def setup_camera(view_size):
    cam = bpy.context.scene.camera
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = view_size
    target = Vector((0.0, 0.0, 0.52))
    # Due south of the model, looking north: screen +X is east and screen up
    # is north, matching the unrotated top-down Camera2D that draws the game.
    # A camera on the +Y (north) side mirrors every heading east-west.
    offset = Vector((0.0, -9.3, 7.7))
    cam.location = target + offset
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()


def render_to(path, cell, view_size):
    scene = bpy.context.scene
    scene.render.resolution_x = cell * RENDER_SCALE
    scene.render.resolution_y = cell * RENDER_SCALE
    setup_camera(view_size)
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def drop_shadow(img):
    return bb.with_drop_shadow(img, offset=(5, 6), blur=4.0, alpha=0.36)


def downscale(img, size):
    return bb.premultiplied_resize(img, size)


def bake_vehicle_boxes(sheet_id, builder, cell, view_size, frames=16):
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    raw_dir = FRAME_DIR / sheet_id
    raw_dir.mkdir(parents=True, exist_ok=True)
    bb.purge_model()
    root = builder()
    sheet = Image.new("RGBA", (cell * RENDER_SCALE * frames, cell * RENDER_SCALE), (0, 0, 0, 0))
    for i in range(frames):
        root.rotation_euler.z = math.tau * i / frames
        path = raw_dir / ("f%d.png" % i)
        render_to(path, cell, view_size)
        raw = Image.open(path).convert("RGBA")
        img = drop_shadow(downscale(raw, (cell * RENDER_SCALE, cell * RENDER_SCALE)))
        sheet.alpha_composite(img, (i * cell * RENDER_SCALE, 0))
    sheet = normalize_rgba(sheet, 54.0, saturation=1.12, contrast=1.03)
    path = OUT_DIR / (sheet_id + ".png")
    sheet.save(path)
    print("UNIT SHEET %-16s %dx%d cell=%d" % (sheet_id, sheet.width, sheet.height, cell * RENDER_SCALE), flush=True)
    return path


def bake_infantry(kind):
    cell = CELLS[kind]
    px = cell * RENDER_SCALE
    raw_dir = FRAME_DIR / kind
    raw_dir.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (px * 4, px * 8), (0, 0, 0, 0))
    for d in range(8):
        angle = math.tau * d / 8.0
        for anim in range(4):
            bb.purge_model()
            root = build_infantry(kind, anim)
            root.rotation_euler.z = angle
            path = raw_dir / ("d%d_a%d.png" % (d, anim))
            render_to(path, cell, 1.65)
            raw = Image.open(path).convert("RGBA")
            img = drop_shadow(downscale(raw, (px, px)))
            sheet.alpha_composite(img, (anim * px, d * px))
    sheet = normalize_rgba(sheet, 55.0, saturation=1.12, contrast=1.03)
    path = OUT_DIR / (kind + ".png")
    sheet.save(path)
    print("UNIT SHEET %-16s %dx%d cell=%d poses=4 dirs=8" % (kind, sheet.width, sheet.height, px), flush=True)
    return path


def bake_tank_parts():
    cell = 60
    px = cell * RENDER_SCALE
    for sheet_id, builder in (("tank_hull", build_tank_hull), ("tank_turret", build_tank_turret)):
        bake_vehicle_boxes(sheet_id, builder, cell, 2.15)


def bake_harvester():
    cell = 62
    for name, fill in (("empty", 0.0), ("half", 0.5), ("full", 1.0)):
        bake_vehicle_boxes("harvester_" + name, lambda f=fill: build_harvester(f), cell, 2.25)


def normalize_rgba(img, target, saturation=1.10, contrast=1.04, gamma=1.0):
    """Match a consistent midtone across procedural units and portraits."""
    arr = np.asarray(img.convert("RGBA"), dtype=np.float32)
    if gamma != 1.0:
        arr[..., :3] = 255.0 * np.power(np.clip(arr[..., :3] / 255.0, 0.0, 1.0), gamma)
    mask = arr[..., 3] > 32
    if mask.any():
        lum = float(arr[..., :3][mask].mean())
        if lum > 1.0:
            factor = max(0.62, min(1.55, target / lum))
            arr[..., :3] = np.clip(arr[..., :3] * factor, 0.0, 255.0)
    out = Image.fromarray(arr.astype(np.uint8), "RGBA")
    out = ImageEnhance.Color(out).enhance(saturation)
    return ImageEnhance.Contrast(out).enhance(contrast)


def outlined(img, color=(14, 11, 8), strength=0.92):
    """One-pixel dark edge so light units read on the tan HUD plate."""
    pad = 2
    canvas = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    canvas.alpha_composite(img, (pad, pad))
    alpha = canvas.getchannel("A").filter(ImageFilter.MaxFilter(3))
    alpha = alpha.point(lambda v: int(v * strength))
    edge = Image.new("RGBA", canvas.size, (*color, 0))
    edge.putalpha(alpha)
    return Image.alpha_composite(edge, canvas)


def icon_backdrop():
    yy, xx = np.mgrid[0:ICON_PX, 0:ICON_PX].astype(np.float32)
    top = np.array([0.56, 0.42, 0.27], dtype=np.float32)
    bottom = np.array([0.24, 0.16, 0.10], dtype=np.float32)
    warm = np.array([0.96, 0.76, 0.48], dtype=np.float32)
    t = (yy / float(ICON_PX - 1))[..., None]
    base = top * (1.0 - t) + bottom * t
    dx = (xx - 30.0) / 34.0
    dy = (yy - 25.0) / 34.0
    glow = np.clip(1.0 - np.sqrt(dx * dx + dy * dy), 0.0, 1.0)[..., None]
    base = base * (1.0 - glow * 0.38) + warm * (glow * 0.38)
    noise = (np.sin(xx * 12.9898 + yy * 78.233) * 43758.5453) % 1.0
    base = base * (0.976 + noise[..., None] * 0.024)
    edge = np.minimum(np.minimum(xx, ICON_PX - 1 - xx), np.minimum(yy, ICON_PX - 1 - yy))
    base[edge < 2.0] *= 0.82
    sx = (xx - 32.0) / 21.0
    sy = (yy - 50.0) / 6.5
    contact = np.clip(1.0 - (sx * sx + sy * sy), 0.0, 1.0) ** 2
    base *= (1.0 - 0.20 * contact[..., None])
    rgba = np.dstack([np.clip(base, 0, 1), np.ones((ICON_PX, ICON_PX), np.float32)])
    return Image.fromarray((rgba * 255).astype(np.uint8), "RGBA")


def icon_model(kind):
    if kind == "tank":
        return build_tank()
    if kind == "harvester":
        return build_harvester(1.0)
    if kind in INFANTRY:
        return build_infantry(kind, 0)
    builders = {
        "trike": build_trike, "raider_trike": build_raider,
        "quad": build_quad, "atreides_tank": lambda: build_combat_tank("atreides"),
        "harkonnen_tank": lambda: build_combat_tank("harkonnen"),
        "ordos_tank": lambda: build_combat_tank("ordos"),
        "sonic_tank": build_sonic, "devastator": build_devastator,
        "deviator": build_deviator,
    }
    return builders[kind]()


def bake_icon(kind):
    bb.purge_model()
    root = icon_model(kind)
    root.rotation_euler.z = 0.0
    if kind == "tank":
        # Tank icon needs hull + turret together; build_tank already does that.
        pass
    for obj in bpy.data.objects:
        if obj.get("sandwar_model") and obj.data and getattr(obj.data, "materials", None):
            for slot in obj.material_slots:
                if slot.material == M["trim"]:
                    slot.material = M["trim_blue"]
    size = 1.22 if kind in INFANTRY else (1.90 if kind == "devastator" else
                                        (1.65 if kind == "harvester" else
                                         (1.72 if kind in ("sonic_tank", "harkonnen_tank", "atreides_tank", "deviator") else 1.55)))
    scene = bpy.context.scene
    scene.render.resolution_x = 192
    scene.render.resolution_y = 192
    # Portraits use a brighter, more contrasty studio pass than map sprites.
    scene.view_settings.exposure = 0.95
    key = bpy.data.lights.get("Portrait Sun")
    if key is not None:
        key.energy = 3.3
    front = bpy.data.lights.get("Portrait Fill")
    if front is not None:
        front.energy = 900.0
    rim = bpy.data.lights.get("Cool Rim")
    if rim is not None:
        rim.energy = 260.0
    setup_camera(size)
    raw_path = FRAME_DIR / (kind + "_icon.png")
    scene.render.filepath = str(raw_path)
    bpy.ops.render.render(write_still=True)
    raw = Image.open(raw_path).convert("RGBA")
    bbox = bb.alpha_bbox(raw)
    if bbox is None:
        bbox = (0, 0, raw.width, raw.height)
    crop = raw.crop(bbox)
    scale = min(54.0 / max(crop.width, 1), 54.0 / max(crop.height, 1))
    w = max(1, int(round(crop.width * scale)))
    h = max(1, int(round(crop.height * scale)))
    crop = downscale(crop, (w, h))
    crop = normalize_rgba(crop, 122.0, saturation=1.28, contrast=1.10, gamma=0.82)
    crop = crop.filter(ImageFilter.UnsharpMask(radius=1.2, percent=95, threshold=2))
    crop = outlined(crop)
    icon = icon_backdrop()
    icon.alpha_composite(crop, ((ICON_PX - crop.width) // 2,
                                max(1, (ICON_PX - crop.height) // 2)))
    path = ICON_DIR / (kind + "_icon.png")
    icon.save(path)
    print("UNIT ICON %-16s 64x64" % kind, flush=True)
    return path


def main() -> None:
    tokens = [part for chunk in bb.args_after_ddash() for part in chunk.split(",") if part]
    icons_only = "icons" in tokens
    selection = [t for t in tokens if t in CELLS]
    bb.reset_scene()
    scene = bpy.context.scene
    scene.cycles.samples = SAMPLES
    scene.render.film_transparent = True
    bb.build_materials()
    build_materials()
    bb.build_stage()
    sun = bpy.data.lights.get("Desert Sun")
    if sun is not None:
        sun.energy = 2.30
    fill = bpy.data.lights.get("Warm Bounce")
    if fill is not None:
        fill.energy = 260.0
    rim = bpy.data.lights.get("Cool Rim")
    if rim is not None:
        rim.energy = 120.0
    if bpy.context.scene.world is not None:
        bpy.context.scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.45
    # Camera-side fill: the desert key is NW while the bake camera looks from
    # the south, so unit fronts would otherwise read as silhouettes.
    front_data = bpy.data.lights.new("Portrait Fill", "AREA")
    front_data.energy = 650.0
    front_data.color = (1.0, 0.90, 0.76)
    front_data.size = 6.0
    front = bpy.data.objects.new("Portrait Fill", front_data)
    front.location = (2.2, -5.8, 3.6)
    front.rotation_euler = (Vector((0.0, 0.0, 0.55)) - front.location).to_track_quat("-Z", "Y").to_euler()
    bb.link(front)
    key_data = bpy.data.lights.new("Portrait Sun", "SUN")
    key_data.energy = 2.6
    key_data.angle = math.radians(4.0)
    key_data.color = (1.0, 0.92, 0.80)
    key = bpy.data.objects.new("Portrait Sun", key_data)
    key.rotation_euler = Vector((-0.55, -0.70, -0.60)).to_track_quat("-Z", "Y").to_euler()
    bb.link(key)
    scene.view_settings.exposure = 0.25
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    if icons_only:
        for kind in (selection or list(ICON_IDS)):
            if kind in ICON_IDS:
                bake_icon(kind)
        print("UNIT ICONS COMPLETE", flush=True)
        return
    order = ["infantry", "rocket", "fremen", "sardaukar", "saboteur",
             "trike", "raider_trike", "quad", "atreides_tank", "harkonnen_tank",
             "ordos_tank", "sonic_tank", "devastator", "deviator", "carryall"]
    for kind in order:
        if selection and kind not in selection and not (kind == "harvester" and "harvester" in selection):
            continue
        if kind in INFANTRY:
            bake_infantry(kind)
        elif kind == "carryall":
            bake_vehicle_boxes("carryall", build_carryall, CELLS[kind], 3.20)
        else:
            build = {
                "trike": build_trike, "raider_trike": build_raider, "quad": build_quad,
                "atreides_tank": lambda: build_combat_tank("atreides"),
                "harkonnen_tank": lambda: build_combat_tank("harkonnen"),
                "ordos_tank": lambda: build_combat_tank("ordos"),
                "sonic_tank": build_sonic, "devastator": build_devastator,
                "deviator": build_deviator,
            }[kind]
            bake_vehicle_boxes(kind, build, CELLS[kind], VIEW[kind])
    if not selection or "tank" in selection:
        bake_tank_parts()
    if not selection or "harvester" in selection:
        bake_harvester()
    if not selection:
        for kind in ICON_IDS:
            bake_icon(kind)
    print("ALL UNIT BAKES COMPLETE", flush=True)


if __name__ == "__main__":
    main()
