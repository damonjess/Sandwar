"""Bake every Sandwar unit sheet and portrait with Blender Cycles.

Run:
    blender --background --python tools/blender_bake_units.py [-- trike,tank]

Layouts match scripts/unit_art.gd exactly:
  vehicles   16 cols x 1 row, cell = UnitArt.CELLS[id] * 4
  infantry   4 pose cols x 8 compass rows, cell = UnitArt.CELLS[id] * 4
  tank       tank_hull.png + tank_turret.png (60 px cells, 16 frames)
  harvester  empty/half/full sheets (62 px cells, 16 frames)

House trim is baked magenta for the faction shader; portraits use blue trim
for BuildingArt/UnitArt.hud_material(). Cycles prefers OptiX, then CUDA, then
CPU. Cells bake at 4x the logical footprint, while UnitArt draws them into the
same world-sized rectangles, so the doubled texture resolution is 0.5 scale in
effect and every collision footprint stays unchanged. 64 samples stay within
a 4 GB GPU.
"""
from __future__ import annotations

import math
import os
import sys
from pathlib import Path

import bpy
import bmesh
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
RENDER_SCALE = 4
ICON_PX = 64
SAMPLES = int(os.environ.get("BAKE_UNIT_SAMPLES", "64"))

CELLS = {
    "infantry": 36, "rocket": 38, "fremen": 38, "sardaukar": 40, "saboteur": 36,
    "trike": 48, "raider_trike": 48, "quad": 50,
    "tank": 64, "atreides_tank": 60, "harkonnen_tank": 62, "ordos_tank": 58,
    "sonic_tank": 62, "devastator": 84, "deviator": 60,
    "harvester": 70, "carryall": 96,
}
VIEW = {
    "trike": 2.05, "raider_trike": 2.05, "quad": 2.30,
    "atreides_tank": 2.58, "harkonnen_tank": 2.68, "ordos_tank": 2.48,
    "sonic_tank": 2.72, "devastator": 3.55, "deviator": 2.68,
    "carryall": 3.78, "tank": 3.35, "harvester": 3.30,
}
ICON_VIEW = {
    "infantry": 1.85, "rocket": 1.85, "fremen": 1.85, "sardaukar": 1.85,
    "saboteur": 1.85, "trike": 1.62, "raider_trike": 1.76, "quad": 2.38,
    "atreides_tank": 2.68, "harkonnen_tank": 2.76, "ordos_tank": 2.56,
    "sonic_tank": 2.82, "devastator": 3.70, "deviator": 2.76,
    "harvester": 3.40, "tank": 3.60,
}
INFANTRY = ("infantry", "rocket", "fremen", "sardaukar", "saboteur")
ICON_IDS = ("infantry", "rocket", "fremen", "sardaukar", "saboteur", "trike",
            "raider_trike", "quad", "tank", "atreides_tank", "harkonnen_tank",
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
    M["grill"] = material("Unit Grille", (0.070, 0.075, 0.068), 0.42, 0.70, rust=0.10, dirt=0.32)
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
    M["spice_glow"] = material("Unit Spice Glow", (0.780, 0.260, 0.030), 0.06, 0.58,
                               dirt=0.04, emission=(1.0, 0.24, 0.03), strength=1.35)
    M["yellow"] = material("Unit Hazard", (0.840, 0.520, 0.060), 0.22, 0.56, dirt=0.25)
    M["white"] = material("Unit Bone", (0.780, 0.750, 0.660), 0.14, 0.62, dirt=0.2)
    # --------------------------------------------------- distinct hull palettes
    # Harvester: weathered industrial ochre, deliberately not tank grey.
    M["ochre"] = material("Harvester Ochre", (0.560, 0.395, 0.135), 0.32, 0.72, rust=0.0, dirt=0.48)
    M["ochre_light"] = material("Harvester Ochre Light", (0.700, 0.515, 0.195), 0.28, 0.64, rust=0.0, dirt=0.42)
    # Atreides: pale brushed steel-bone.
    M["bone_steel"] = material("Atreides Bone Steel", (0.640, 0.625, 0.520), 0.58, 0.38, rust=0.0, dirt=0.16)
    M["bone_steel_dark"] = material("Atreides Bone Dark", (0.455, 0.445, 0.365), 0.52, 0.48, rust=0.0, dirt=0.22)
    # Harkonnen: heavy charcoal steel.
    M["charcoal"] = material("Harkonnen Charcoal", (0.085, 0.090, 0.092), 0.76, 0.42, rust=0.0, dirt=0.24)
    M["charcoal_light"] = material("Harkonnen Charcoal Light", (0.175, 0.180, 0.175), 0.70, 0.44, rust=0.0, dirt=0.22)
    # Ordos: low weathered slate-olive.
    M["slate_olive"] = material("Ordos Slate Olive", (0.235, 0.285, 0.220), 0.55, 0.58, rust=0.0, dirt=0.28)
    M["slate_olive_light"] = material("Ordos Slate Light", (0.345, 0.390, 0.300), 0.50, 0.52, rust=0.0, dirt=0.24)
    # Siege artillery: pale sandy-grey.
    M["sand_steel"] = material("Siege Sand Steel", (0.505, 0.475, 0.370), 0.52, 0.50, rust=0.0, dirt=0.30)
    M["sand_steel_light"] = material("Siege Sand Light", (0.625, 0.590, 0.465), 0.44, 0.46, rust=0.0, dirt=0.26)
    # Devastator: near-black obsidian steel with hot reactor accents.
    M["obsidian"] = material("Devastator Obsidian", (0.052, 0.056, 0.062), 0.82, 0.34, rust=0.0, dirt=0.18)
    M["obsidian_light"] = material("Devastator Edge", (0.125, 0.130, 0.138), 0.78, 0.36, rust=0.0, dirt=0.18)
    # Deviator: dark slate tracked chassis.
    M["slate_dark"] = material("Deviator Slate", (0.145, 0.165, 0.185), 0.62, 0.48, rust=0.0, dirt=0.26)
    M["chrome"] = material("Unit Chrome", (0.560, 0.570, 0.545), 0.96, 0.16, rust=0.05, dirt=0.22)
    M["emerald"] = material("Deviator Emerald", (0.060, 0.520, 0.180), 0.10, 0.26,
                            dirt=0.04, emission=(0.05, 0.90, 0.26), strength=2.4)
    M["plasma"] = material("Devastator Plasma", (0.640, 0.100, 0.020), 0.10, 0.24,
                           dirt=0.03, emission=(1.0, 0.22, 0.03), strength=4.2)
    M["reactor"] = material("Devastator Reactor", (0.520, 0.080, 0.015), 0.22, 0.38,
                            dirt=0.10, emission=(1.0, 0.26, 0.04), strength=3.2)
    M["sonic_glow"] = material("Sonic Emitter", (0.040, 0.520, 0.600), 0.05, 0.20,
                               dirt=0.03, emission=(0.10, 0.95, 1.0), strength=3.0)


# --------------------------------------------------------------- primitives

def box(size, loc, mat, rot=(0.0, 0.0, 0.0), bevel=0.008):
    return bb.box(size, loc, mat, rot=rot, bevel=bevel)


def cyl(radius, depth, loc, mat, axis="Z", verts=20, bevel=0.005, rot=(0.0, 0.0, 0.0)):
    obj = bb.cyl(radius, depth, loc, mat, axis=axis, verts=verts, bevel=bevel)
    if rot != (0.0, 0.0, 0.0):
        # Extra local-axis tilt (used by the Deviator's raised missile tubes).
        obj.rotation_euler = (obj.rotation_euler.x + rot[0],
                              obj.rotation_euler.y + rot[1],
                              obj.rotation_euler.z + rot[2])
    return obj


def sphere(radius, loc, mat, scale=(1.0, 1.0, 1.0)):
    return bb.sphere(radius, loc, mat, scale=scale, segments=20, rings=10)


def pipe(a, b, radius, mat):
    return bb.pipe(a, b, radius, mat)


def group(parts, angle=0.0):
    return bb.group_root(parts, angle)


def wheel(parts, x, y, radius=0.19, width=0.14):
    parts.append(cyl(radius, width, (x, y, radius), M["rubber"], axis="Y", verts=20))
    # Chunky tread blocks around the desert tyre, not a smooth car wheel.
    for i in range(10):
        a = math.tau * i / 10.0
        parts.append(box((0.055, width * 0.92, 0.045),
                         (x + math.cos(a) * radius * 0.94, y,
                          radius + math.sin(a) * radius * 0.94),
                         M["gunmetal"], rot=(0.0, -a, 0.0), bevel=0.002))
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


def bolts_line(a, b, count, mat, radius=0.016):
    bb.bolts_line(a, b, count, mat, radius)


# ------------------------------------------------------------------ infantry

def _inf_legs(parts, leg_mat, boot_mat, stride, heavy=False):
    for side in (-1.0, 1.0):
        s = stride * side
        parts.append(box((0.24, 0.21, 0.12), (s, side * 0.145, 0.335),
                         M["armor_light"], bevel=0.010))
        parts.append(box((0.23, 0.20, 0.25), (s, side * 0.145, 0.20),
                         leg_mat, bevel=0.013))
        parts.append(box((0.24, 0.19, 0.12), (s + 0.015, side * 0.145, 0.275),
                         M["armor_light"], rot=(0.0, math.radians(-8.0), 0.0), bevel=0.008))
        parts.append(box((0.20, 0.18, 0.085), (s, side * 0.145, 0.135),
                         M["gunmetal"], bevel=0.007))
        parts.append(box((0.25, 0.22, 0.14), (s + 0.035, side * 0.145, 0.075),
                         boot_mat, bevel=0.010))
        parts.append(box((0.26, 0.23, 0.055), (s + 0.055, side * 0.145, 0.027),
                         M["rubber"], bevel=0.006))
        if heavy:
            parts.append(box((0.19, 0.12, 0.17), (s + 0.04, side * 0.275, 0.22),
                             M["steel"], bevel=0.008))


def _inf_torso(parts, body_mat, chest_mat, heavy=False):
    w = 0.52 if heavy else 0.46
    d = 0.44 if heavy else 0.40
    parts.append(box((w, d, 0.38), (0.0, 0.0, 0.52), body_mat, bevel=0.015))
    parts.append(box((w * 0.94, d * 1.03, 0.18), (0.035, 0.0, 0.67),
                     chest_mat, bevel=0.012))
    parts.append(box((w * 0.58, d * 0.78, 0.11), (0.10, 0.0, 0.58),
                     chest_mat, bevel=0.009))
    parts.append(box((0.30, 0.35, 0.12), (0.02, 0.0, 0.405), M["gunmetal"], bevel=0.008))
    parts.append(box((0.22, 0.23, 0.25), (-0.28, 0.0, 0.54), M["gunmetal"], bevel=0.011))
    for i in range(3):
        parts.append(box((0.030, 0.16, 0.038), (-0.405, 0.0, 0.58 + i * 0.065),
                         M["steel_light"], bevel=0.003))
    for side in (-1.0, 1.0):
        # Broad house-colour shoulder pauldrons: a full armoured cap plus a
        # front flash, so team colour is unmistakable at phone zoom.
        parts.append(box((0.25, 0.22, 0.17), (0.015, side * 0.30, 0.63),
                         chest_mat, rot=(0.0, 0.0, side * 0.08), bevel=0.011))
        trim_strip(parts, (0.23, 0.22, 0.06), (0.02, side * 0.30, 0.728))
        trim_strip(parts, (0.075, 0.20, 0.14), (0.145, side * 0.30, 0.655))
        trim_strip(parts, (0.16, 0.065, 0.12), (0.04, side * 0.205, 0.72))
        parts.append(box((0.20, 0.12, 0.11), (0.01, side * 0.31, 0.55),
                         body_mat, bevel=0.008))


def _inf_head(parts, helm_mat, visor_mat, blue_eyes=False):
    parts.append(box((0.25, 0.27, 0.18), (0.015, 0.0, 0.86), helm_mat, bevel=0.014))
    parts.append(sphere(0.105, (0.02, 0.0, 0.865), helm_mat, (1.0, 1.0, 0.72)))
    parts.append(box((0.12, 0.22, 0.085), (0.11, 0.0, 0.835), visor_mat, bevel=0.008))
    parts.append(box((0.035, 0.17, 0.045), (0.17, 0.0, 0.79), M["gunmetal"], bevel=0.004))
    if blue_eyes:
        for side in (-1.0, 1.0):
            parts.append(box((0.030, 0.055, 0.032), (0.165, side * 0.045, 0.845),
                             M["cyan"], bevel=0.002))
    else:
        parts.append(box((0.035, 0.07, 0.055), (0.17, 0.0, 0.815), M["steel_light"], bevel=0.004))
    parts.append(box((0.27, 0.24, 0.045), (0.0, 0.0, 0.955), M["gunmetal"], bevel=0.005))
    parts.append(box((0.16, 0.20, 0.055), (0.05, 0.0, 0.735), M["gunmetal"], bevel=0.004))


def _inf_arms(parts, arm_mat, recoil, side=1.0):
    parts.append(box((0.24, 0.15, 0.15), (0.03, side * 0.28, 0.60),
                     arm_mat, rot=(0.0, 0.0, side * 0.18), bevel=0.011))
    parts.append(box((0.23, 0.13, 0.13), (0.18 - recoil, side * 0.21, 0.54),
                     arm_mat, rot=(0.0, 0.0, side * 0.08), bevel=0.010))
    parts.append(box((0.13, 0.14, 0.14), (0.29 - recoil, side * 0.17, 0.51),
                     M["gunmetal"], bevel=0.008))


def _inf_rifle(parts, recoil, heavy=False):
    r = 0.050 if heavy else 0.042
    # Thick bullpup silhouette: stock, receiver, magazine, handguard and brake.
    parts.append(box((0.22, 0.13, 0.13), (0.14 - recoil, 0.16, 0.55),
                     M["steel"], bevel=0.008))
    parts.append(box((0.34, 0.16, 0.16), (0.36 - recoil, 0.16, 0.56),
                     M["gunmetal"], bevel=0.010))
    parts.append(box((0.18, 0.10, 0.19), (0.31 - recoil, 0.16, 0.45),
                     M["dark"], rot=(0.0, math.radians(-12.0), 0.0), bevel=0.005))
    parts.append(box((0.24, 0.08, 0.09), (0.55 - recoil, 0.16, 0.56),
                     M["dark"], bevel=0.006))
    parts.append(cyl(r, 0.20, (0.68 - recoil, 0.16, 0.56), M["gunmetal"],
                     axis="X", verts=12))
    parts.append(cyl(r * 1.7, 0.075, (0.755 - recoil, 0.16, 0.56), M["steel_light"],
                     axis="X", verts=10))
    parts.append(box((0.08, 0.05, 0.045), (0.44 - recoil, 0.16, 0.655),
                     M["steel_light"], bevel=0.003))
    if heavy:
        parts.append(box((0.22, 0.15, 0.09), (0.30 - recoil, 0.26, 0.63), M["steel_light"],
                         bevel=0.005))


def build_infantry(kind, anim=0):
    parts = []
    sway = 0.018 if anim in (1, 2) else 0.0
    stride = 0.15 if anim == 1 else (-0.15 if anim == 2 else 0.0)
    bob = 0.014 if anim in (1, 2) else 0.0
    recoil = 0.070 if anim == 3 else 0.0
    heavy = kind in ("rocket", "sardaukar")
    body = M["armor"] if kind not in ("fremen", "saboteur") else M["cloth"]
    chest = M["armor_light"] if kind != "sardaukar" else M["sardaukar"]
    if kind == "fremen":
        _inf_legs(parts, M["fremen_suit"], M["cloth_dark"], stride)
        parts.append(box((0.46, 0.42, 0.40), (0.0, 0.0, 0.51), M["fremen_suit"], bevel=0.014))
        parts.append(box((0.37, 0.44, 0.46), (-0.04, 0.0, 0.54), M["cloth"], bevel=0.018))
        parts.append(box((0.16, 0.46, 0.56), (-0.23, 0.0, 0.40), M["cloth"],
                         rot=(0.0, math.radians(7.0), 0.0), bevel=0.012))
        parts.append(box((0.24, 0.34, 0.15), (0.03, 0.0, 0.74), M["fremen_suit"], bevel=0.010))
        # Bulky water pack and belt pouches under the cloak.
        parts.append(box((0.18, 0.25, 0.28), (-0.30, 0.0, 0.54), M["gunmetal"], bevel=0.008))
        for y in (-0.16, 0.16):
            parts.append(cyl(0.055, 0.20, (-0.34, y, 0.58), M["rust"], verts=10))
        # Hood over a wrapped stillsuit head, with bright blue eye lenses.
        parts.append(sphere(0.16, (-0.02, 0.0, 0.88), M["cloth"], (1.0, 1.0, 1.10)))
        parts.append(box((0.25, 0.28, 0.18), (-0.04, 0.0, 0.92), M["cloth"], bevel=0.012))
        parts.append(box((0.09, 0.20, 0.09), (0.12, 0.0, 0.85), M["cloth_dark"], bevel=0.006))
        # Hood cowl and careful face-wrap framing make the blue lenses read.
        for side in (-1.0, 1.0):
            parts.append(box((0.16, 0.07, 0.16), (-0.01, side * 0.125, 0.87),
                             M["cloth"], bevel=0.006))
        parts.append(box((0.20, 0.06, 0.065), (0.0, 0.0, 0.965), M["cloth"], bevel=0.004))
        parts.append(box((0.08, 0.22, 0.17), (0.09, 0.0, 0.84), M["cloth_dark"], bevel=0.006))
        for side in (-1.0, 1.0):
            parts.append(box((0.032, 0.055, 0.032), (0.175, side * 0.045, 0.855),
                             M["cyan"], bevel=0.002))
            parts.append(box((0.20, 0.18, 0.12), (0.03, side * 0.24, 0.67),
                             M["fremen_suit"], bevel=0.008))
            trim_strip(parts, (0.18, 0.19, 0.05), (0.03, side * 0.245, 0.735))
            trim_strip(parts, (0.05, 0.17, 0.10), (0.125, side * 0.245, 0.665))
        _inf_arms(parts, M["fremen_suit"], recoil)
        # Long, heavy sniper rifle across the chest.
        parts.append(box((0.58, 0.075, 0.075), (0.43 - recoil, 0.15, 0.57),
                         M["gunmetal"], bevel=0.006))
        parts.append(cyl(0.030, 0.30, (0.61 - recoil, 0.15, 0.57), M["dark"],
                         axis="X", verts=12))
        parts.append(cyl(0.050, 0.08, (0.75 - recoil, 0.15, 0.57), M["steel_light"],
                         axis="X", verts=10))
        parts.append(box((0.18, 0.10, 0.08), (0.24 - recoil, 0.15, 0.48),
                         M["fremen_suit"], bevel=0.006))
        if anim == 3:
            parts.append(sphere(0.038, (0.84 - recoil, 0.15, 0.57), M["amber"],
                                (1.0, 1.0, 1.0)))
    elif kind == "sardaukar":
        _inf_legs(parts, M["gunmetal"], M["rubber"], stride, heavy=True)
        _inf_torso(parts, M["gunmetal"], M["sardaukar"], heavy=True)
        _inf_head(parts, M["sardaukar"], M["glass"])
        parts.append(box((0.53, 0.43, 0.34), (0.0, 0.0, 0.51), M["gunmetal"], bevel=0.014))
        parts.append(box((0.26, 0.37, 0.15), (0.12, 0.0, 0.70), M["sardaukar"], bevel=0.010))
        for side in (-1.0, 1.0):
            parts.append(box((0.24, 0.18, 0.17), (0.0, side * 0.29, 0.71),
                             M["sardaukar"], rot=(side * 0.08, 0.0, 0.0), bevel=0.010))
            trim_strip(parts, (0.22, 0.15, 0.055), (0.01, side * 0.29, 0.795))
        _inf_arms(parts, M["gunmetal"], recoil)
        # Heavy rotary assault gun with exposed barrel cluster.
        parts.append(box((0.34, 0.18, 0.17), (0.28 - recoil, 0.14, 0.48),
                         M["steel"], bevel=0.008))
        for i in range(3):
            y = 0.14 + (i - 1) * 0.045
            parts.append(cyl(0.028, 0.34, (0.56 - recoil, y, 0.48), M["dark"],
                             axis="X", verts=10))
        parts.append(cyl(0.10, 0.09, (0.72 - recoil, 0.14, 0.48), M["steel_light"],
                         axis="X", verts=12))
        if anim == 3:
            parts.append(sphere(0.045, (0.78 - recoil, 0.14, 0.48), M["amber"]))
    elif kind == "saboteur":
        _inf_legs(parts, M["cloth_dark"], M["rubber"], stride)
        parts.append(box((0.36, 0.32, 0.35), (0.0, 0.0, 0.49), M["cloth"], bevel=0.012))
        parts.append(box((0.22, 0.38, 0.32), (-0.20, 0.0, 0.44), M["cloth_dark"], bevel=0.014))
        parts.append(box((0.10, 0.06, 0.06), (0.05, 0.18, 0.55), M["cyan"], bevel=0.003))
        for side in (-1.0, 1.0):
            parts.append(box((0.18, 0.18, 0.12), (0.01, side * 0.21, 0.62),
                             M["cloth_dark"], bevel=0.006))
            trim_strip(parts, (0.16, 0.18, 0.045), (0.01, side * 0.215, 0.695))
            trim_strip(parts, (0.045, 0.15, 0.09), (0.10, side * 0.215, 0.63))
        for i in range(3):
            parts.append(cyl(0.06, 0.20, (-0.24, 0.15, 0.36 + i * 0.085),
                             M["amber"], axis="X", verts=12))
        parts.append(box((0.17, 0.18, 0.04), (-0.24, 0.15, 0.64), M["steel"], bevel=0.004))
        parts.append(sphere(0.12, (0.0, 0.0, 0.79), M["cloth_dark"], (1.0, 1.0, 1.1)))
        parts.append(box((0.23, 0.24, 0.15), (0.0, 0.0, 0.86), M["cloth"], bevel=0.012))
        parts.append(box((0.09, 0.18, 0.07), (0.11, 0.0, 0.80), M["glass"], bevel=0.006))
        parts.append(box((0.46, 0.08, 0.08), (0.31 - recoil, 0.14, 0.51),
                         M["gunmetal"], bevel=0.006))
        parts.append(cyl(0.022, 0.35, (0.58 - recoil, 0.14, 0.51), M["dark"],
                         axis="X", verts=10))
        _inf_arms(parts, M["cloth"], recoil)
    else:
        _inf_legs(parts, M["armor"] if kind != "rocket" else M["olive"],
                  M["rubber"], stride, heavy=heavy)
        _inf_torso(parts, M["armor"] if kind != "rocket" else M["olive"],
                   M["armor_light"] if kind != "rocket" else M["olive_light"],
                   heavy=heavy)
        _inf_head(parts, M["armor"], M["glass"])
        _inf_arms(parts, M["armor"] if kind != "rocket" else M["olive"], recoil)
        if kind == "rocket":
            # Chunky shoulder tube with a flared exhaust bell and green warhead.
            parts.append(box((0.30, 0.24, 0.19), (0.15 - recoil, 0.13, 0.70),
                             M["steel"], bevel=0.010))
            parts.append(cyl(0.115, 0.56, (0.42 - recoil, 0.13, 0.71),
                             M["gunmetal"], axis="X", verts=16))
            parts.append(cyl(0.165, 0.12, (0.10 - recoil, 0.13, 0.71),
                             M["rust"], axis="X", verts=16))
            parts.append(cyl(0.080, 0.09, (0.745 - recoil, 0.13, 0.71),
                             M["gas"], axis="X", verts=12))
            parts.append(box((0.11, 0.24, 0.065), (0.19 - recoil, 0.13, 0.82),
                             M["steel_light"], bevel=0.004))
        else:
            _inf_rifle(parts, recoil)
            parts.append(box((0.18, 0.15, 0.16), (0.23 - recoil, 0.26, 0.43),
                             M["steel"], bevel=0.006))
            if anim == 3:
                parts.append(sphere(0.040, (0.82 - recoil, 0.16, 0.56), M["amber"]))
    root = group(parts, 0.0)
    root.location.z = bob
    return root


# ------------------------------------------------------------------ vehicles

def prism(size, loc, mat, chamfer=0.08, rot=(0.0, 0.0, 0.0), bevel=0.02):
    length, width, height = size
    c = min(chamfer, length * 0.32, width * 0.32)
    profile = [
        (-length * 0.5 + c, -width * 0.5),
        (length * 0.5 - c, -width * 0.5),
        (length * 0.5, -width * 0.5 + c),
        (length * 0.5, width * 0.5 - c),
        (length * 0.5 - c, width * 0.5),
        (-length * 0.5 + c, width * 0.5),
        (-length * 0.5, width * 0.5 - c),
        (-length * 0.5, -width * 0.5 + c),
    ]
    bm = bmesh.new()
    bottom = [bm.verts.new((x, y, -height * 0.5)) for x, y in profile]
    top = [bm.verts.new((x, y, height * 0.5)) for x, y in profile]
    bm.faces.new(tuple(reversed(bottom)))
    bm.faces.new(tuple(top))
    for i in range(8):
        j = (i + 1) % 8
        bm.faces.new((bottom[i], bottom[j], top[j], top[i]))
    # Keep every chamfered side face outward-facing. A mixed face winding on
    # these custom prisms produces black backfaces in rear/side views.
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("ArmoredPrism")
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new("ArmoredPrism", mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = loc
    obj.rotation_euler = rot
    return bb.finish(obj, mat, bevel, True)


def track_sponson(parts, side, x0=-0.68, x1=0.68, width=0.28, height=0.28,
                  y_center=0.54):
    y = side * y_center
    length = abs(x1 - x0)
    mid = (x0 + x1) * 0.5
    parts.append(prism((length + 0.08, width, height), (mid, y, height * 0.56),
                       M["rubber"], chamfer=0.11, bevel=0.035))
    parts.append(box((length * 0.84, width * 0.72, 0.035), (mid, y, height * 0.94),
                     M["gunmetal"], bevel=0.006))
    for i in range(8):
        x = x0 + length * (i + 0.5) / 8.0
        parts.append(box((0.095, width * 0.86, 0.038), (x, y, 0.070),
                         M["dark"], bevel=0.004))
        parts.append(box((0.095, 0.028, 0.10), (x, y + side * width * 0.51, height * 0.50),
                         M["gunmetal"], bevel=0.004))
        # Exposed tread lugs below the skirt keep the track from reading as a
        # smooth rubber tyre.
        parts.append(box((0.10, 0.035, 0.06), (x, y + side * width * 0.67, height * 0.25),
                         M["steel"], bevel=0.003))
        parts.append(box((0.055, 0.02, 0.028), (x, y + side * width * 0.69, height * 0.25),
                         M["dark"], bevel=0.001))
        parts.append(box((0.11, width * 0.34, 0.025), (x, y, height * 0.98),
                         M["steel"], bevel=0.003))
    for x in (x0, x1):
        parts.append(cyl(0.145, 0.045, (x, y, height * 0.58), M["steel"],
                         axis="Y", verts=18, bevel=0.005))
        parts.append(cyl(0.070, 0.052, (x, y, height * 0.58), M["dark"],
                         axis="Y", verts=12, bevel=0.003))
    # Sloped armored side skirt, bolted along its lower edge.
    parts.append(box((length * 0.90, 0.10, 0.27), (mid, y + side * width * 0.60, height * 0.74),
                     M["steel"], rot=(side * math.radians(-7.0), 0.0, 0.0), bevel=0.008))
    parts.append(box((length * 0.82, 0.035, 0.06), (mid, y + side * width * 0.68, height * 0.58),
                     M["gunmetal"], bevel=0.003))
    parts.append(box((length * 0.72, 0.032, 0.055), (mid, y + side * width * 0.73, height * 0.54),
                     M["trim"], bevel=0.003))
    for i in range(4):
        parts.append(box((0.055, 0.026, 0.026), (x0 + length * (i + 0.5) / 4.0,
                         y + side * width * 0.70, height * 0.83), M["steel_light"], bevel=0.002))


def tracked_base(parts, length=1.58, width=1.02, height=0.34, hull_mat=None,
                 track_width=0.28, track_offset=0.54):
    hull_mat = hull_mat or M["olive"]
    track_height = max(0.30, height * 0.88)
    track_sponson(parts, -1.0, -length * 0.44, length * 0.44, track_width, track_height,
                  y_center=track_offset)
    track_sponson(parts, 1.0, -length * 0.44, length * 0.44, track_width, track_height,
                  y_center=track_offset)
    # Opaque full-width undercarriage closes the middle of the vehicle.
    parts.append(box((length * 0.92, width * 1.02, 0.11), (0.0, 0.0, 0.105),
                     M["dark"], bevel=0.008))
    parts.append(prism((length, width, height), (0.0, 0.0, 0.17 + height * 0.5),
                       hull_mat, chamfer=0.11, bevel=0.030))
    parts.append(box((length * 0.78, width * 0.82, 0.075), (0.0, 0.0, 0.17 + height + 0.005),
                     M["steel_light"], bevel=0.008))
    # Sloped glacis and thick rear engine deck.
    parts.append(box((0.34, width * 0.84, 0.15), (length * 0.38, 0.0, 0.17 + height * 0.82),
                     hull_mat, rot=(0.0, math.radians(-19.0), 0.0), bevel=0.012))
    parts.append(box((0.30, width * 0.80, 0.12), (-length * 0.36, 0.0, 0.17 + height * 0.82),
                     M["gunmetal"], bevel=0.008))
    for y in (-width * 0.31, 0.0, width * 0.31):
        for i in range(3):
            parts.append(box((0.035, width * 0.18, 0.065),
                             (-length * 0.35, y, 0.28 + height + i * 0.055),
                             M["grill"], bevel=0.002))
    # Rear exhaust stacks sit in armoured manifolds on the engine deck.
    for y in (-width * 0.29, width * 0.29):
        base_z = 0.18 + height * 0.78
        parts.append(box((0.17, 0.15, 0.10), (-length * 0.38, y, base_z),
                         M["steel"], bevel=0.006))
        parts.append(cyl(0.045, 0.30, (-length * 0.41, y, base_z + 0.21),
                         M["rust"], verts=10))
        parts.append(cyl(0.062, 0.055, (-length * 0.41, y, base_z + 0.35),
                         M["dark"], verts=10))
    # Front lamps and recovery hooks break up the blunt glacis.
    for y in (-width * 0.28, width * 0.28):
        parts.append(box((0.12, 0.11, 0.09), (length * 0.49, y, 0.17 + height * 0.74),
                         M["steel"], bevel=0.005))
        parts.append(cyl(0.035, 0.025, (length * 0.555, y, 0.17 + height * 0.74),
                         M["amber"], axis="X", verts=10))
        parts.append(box((0.13, 0.05, 0.055), (length * 0.50, y, 0.17 + height * 0.43),
                         M["gunmetal"], bevel=0.004))
    # Bolted armor seams and house-colour side flashes.
    for side in (-1.0, 1.0):
        bolts_line((length * 0.30, side * width * 0.505, 0.20 + height * 0.44),
                   (-length * 0.30, side * width * 0.505, 0.20 + height * 0.44),
                   5, M["steel_light"], 0.011)
        trim_strip(parts, (0.24, 0.05, 0.045),
                   (length * 0.20, side * width * 0.505, 0.20 + height * 0.78))


def add_turret(parts, z, length=0.54, width=0.44, height=0.26, mat=None,
               barrel=0.58, radius=0.060, twin=False, siege=False):
    mat = mat or M["steel"]
    parts.append(cyl(0.25, 0.055, (0.0, 0.0, z), M["gunmetal"], verts=20, bevel=0.006))
    parts.append(prism((length, width, height), (0.025, 0.0, z + 0.09),
                       mat, chamfer=0.075, bevel=0.022))
    parts.append(box((length * 0.58, width * 0.74, 0.065),
                     (0.06, 0.0, z + 0.09 + height * 0.55), M["steel_light"], bevel=0.008))
    parts.append(box((0.24, width * 0.82, 0.115), (length * 0.40, 0.0, z + 0.09 + height * 0.35),
                     M["steel"], rot=(0.0, math.radians(-13.0), 0.0), bevel=0.010))
    turret_top = z + 0.09 + height * 0.5
    barrel_z = z + 0.09 + height * 0.42
    # Rear bustle, side cheeks and a thick mantlet give the turret real mass.
    parts.append(box((length * 0.32, width * 0.72, height * 0.58),
                     (-length * 0.42, 0.0, z + 0.09), mat, bevel=0.010))
    for side in (-1.0, 1.0):
        parts.append(box((length * 0.48, 0.06, height * 0.60),
                         (length * 0.08, side * width * 0.47, z + 0.09),
                         M["gunmetal"], bevel=0.006))
        trim_strip(parts, (length * 0.26, 0.04, 0.04),
                   (0.02, side * width * 0.505, z + 0.09 + height * 0.28))
        for i in range(2):
            parts.append(cyl(0.035, 0.09, (length * 0.20 + i * 0.10,
                         side * width * 0.54, z + 0.09 + height * 0.35),
                         M["steel_light"], axis="X", verts=8))
    parts.append(box((0.16, width * 0.42, height * 0.54),
                     (length * 0.53, 0.0, barrel_z), M["steel"], bevel=0.008))
    parts.append(cyl(radius * 1.9, 0.08, (length * 0.58, 0.0, barrel_z),
                     M["gunmetal"], axis="X", verts=16))
    # Commander cupola and hatch, offset so the silhouette is not a plain box.
    parts.append(cyl(0.115, 0.065, (-length * 0.22, width * 0.18, turret_top + 0.035),
                     M["steel_light"], verts=16, bevel=0.005))
    parts.append(box((0.14, 0.14, 0.035), (-length * 0.22, width * 0.18, turret_top + 0.082),
                     M["gunmetal"], bevel=0.004))
    parts.append(box((0.09, 0.09, 0.07), (-length * 0.22, width * 0.18, turret_top + 0.12),
                     M["amber"], bevel=0.004))
    bolts_line((length * 0.24, -width * 0.40, z + height * 0.75),
               (length * 0.24, width * 0.40, z + height * 0.75), 5,
               M["steel_light"], 0.010)
    barrels = (-0.11, 0.11) if twin else (0.0,)
    for y in barrels:
        parts.append(cyl(radius, barrel, (length * 0.45 + barrel * 0.5, y, barrel_z),
                         M["gunmetal"], axis="X", verts=16))
        parts.append(cyl(radius * 1.45, 0.11, (length * 0.45 + barrel * 0.78, y, barrel_z),
                         M["rust"], axis="X", verts=14))
        parts.append(cyl(radius * 1.20, 0.055, (length * 0.45 + barrel * 0.86, y, barrel_z),
                         M["dark"], axis="X", verts=12))
        parts.append(box((0.09, radius * 2.8, 0.045),
                         (length * 0.45 + barrel * 0.80, y, barrel_z + radius * 0.8),
                         M["steel_light"], bevel=0.002))
        parts.append(box((0.08, radius * 0.55, radius * 1.4),
                         (length * 0.45 + barrel * 0.82, y, barrel_z),
                         M["steel"], bevel=0.002))
    if siege:
        parts.append(box((0.23, width * 0.62, 0.08), (-length * 0.36, 0.0, z + height * 0.45),
                         M["gunmetal"], bevel=0.006))


def wheeled_fender(parts, x, y, radius, side, mat=None):
    mat = mat or M["olive_light"]
    wheel(parts, x, y, radius, 0.18)
    # A deep armoured fender wraps over the tyre and ties into the hull.
    parts.append(box((radius * 1.85, 0.12, 0.13), (x, y + side * 0.025, radius * 1.34),
                     M["steel"], rot=(side * math.radians(-8.0), 0.0, 0.0), bevel=0.009))
    parts.append(box((radius * 1.82, 0.045, 0.07), (x, y + side * 0.075, radius * 1.44),
                     mat, bevel=0.004))
    parts.append(box((radius * 1.62, 0.035, 0.05), (x, y + side * 0.085, radius * 1.50),
                     M["trim"], bevel=0.003))
    parts.append(box((radius * 0.90, 0.06, 0.14), (x, y + side * 0.11, radius * 0.82),
                     M["olive"], bevel=0.004))


def house_plate(parts, size, loc, rot=(0.0, 0.0, 0.0)):
    """Bold magenta remap armour: the faction shader turns these into house
    colour, so every turret, hood and fender carries a readable team flash."""
    parts.append(box(size, loc, M["trim"], rot=rot, bevel=0.003))


def add_gun(parts, x0, y, z, length, radius, mat=None, glow=None, brake=True):
    """Barrel with reinforcing rings and an optional glowing muzzle tip."""
    mat = mat or M["gunmetal"]
    parts.append(cyl(radius, length, (x0 + length * 0.5, y, z), mat, axis="X", verts=18, bevel=0.004))
    for frac in (0.18, 0.46, 0.72):
        parts.append(cyl(radius * 1.12, length * 0.035, (x0 + length * frac, y, z), M["steel"],
                         axis="X", verts=14, bevel=0.003))
    if brake:
        parts.append(cyl(radius * 1.55, length * 0.13, (x0 + length * 0.90, y, z),
                         M["steel_light"], axis="X", verts=16, bevel=0.004))
        parts.append(cyl(radius * 1.05, length * 0.04, (x0 + length * 0.975, y, z),
                         M["dark"], axis="X", verts=14, bevel=0.002))
    if glow is not None:
        parts.append(cyl(radius * 0.62, 0.035, (x0 + length * 0.995, y, z), glow,
                         axis="X", verts=14, bevel=0.0))


def build_trike():
    """Low triangular desert recon buggy: exposed front wheel, wide rear
    desert tyres, tan tubular roll cage and a small top machine gun."""
    p = []
    # 1 exposed front wheel + 2 wide rear tyres.
    wheel(p, -0.30, -0.40, 0.26, 0.20)
    wheel(p, -0.30, 0.40, 0.26, 0.20)
    wheel(p, 0.64, 0.0, 0.235, 0.15)
    p.append(cyl(0.050, 0.86, (-0.30, 0.0, 0.26), M["steel"], axis="Y", verts=12))
    p.append(cyl(0.040, 0.32, (0.64, 0.0, 0.235), M["steel"], axis="Y", verts=10))
    # Low narrow chassis with a pointed nose and open cockpit tub.
    p.append(prism((0.98, 0.56, 0.20), (0.0, 0.0, 0.36), M["ochre_light"], chamfer=0.12, bevel=0.018))
    p.append(box((0.34, 0.46, 0.15), (0.34, 0.0, 0.35), M["ochre"],
                 rot=(0.0, math.radians(14.0), 0.0), bevel=0.010))
    p.append(box((0.44, 0.40, 0.16), (-0.05, 0.0, 0.49), M["ochre"], bevel=0.010))
    p.append(box((0.15, 0.25, 0.16), (-0.20, 0.0, 0.57), M["cloth_dark"], bevel=0.008))
    p.append(box((0.10, 0.36, 0.10), (0.13, 0.0, 0.56), M["gunmetal"], bevel=0.005))
    # Tan tubular roll cage, deliberately open so it stays a buggy.
    for x in (-0.28, 0.15):
        for y in (-0.25, 0.25):
            p.append(box((0.045, 0.045, 0.46), (x, y, 0.70), M["ochre_light"], bevel=0.004))
    for y in (-0.25, 0.25):
        p.append(box((0.52, 0.045, 0.045), (-0.06, y, 0.93), M["ochre_light"], bevel=0.004))
    p.append(box((0.045, 0.50, 0.045), (0.16, 0.0, 0.93), M["ochre_light"], bevel=0.004))
    # Rear engine block, louvres and a stubby exhaust.
    p.append(box((0.26, 0.44, 0.20), (-0.38, 0.0, 0.42), M["gunmetal"], bevel=0.006))
    for i in range(4):
        p.append(box((0.025, 0.32, 0.030), (-0.50, 0.0, 0.36 + i * 0.042), M["dark"], bevel=0.001))
    p.append(cyl(0.042, 0.20, (-0.52, 0.16, 0.47), M["rust"], axis="X", verts=10))
    # Bold house flashes on the nose and both flanks.
    house_plate(p, (0.20, 0.28, 0.05), (0.40, 0.0, 0.44))
    for side in (-1.0, 1.0):
        p.append(box((0.80, 0.07, 0.13), (-0.03, side * 0.33, 0.43), M["ochre_light"], bevel=0.005))
        house_plate(p, (0.44, 0.035, 0.045), (-0.02, side * 0.375, 0.47))
        p.append(box((0.18, 0.08, 0.10), (-0.38, side * 0.33, 0.31), M["steel"], bevel=0.004))
    # Small top-mounted machine gun with shield and ammunition box.
    p.append(box((0.28, 0.14, 0.10), (0.10, 0.0, 0.94), M["gunmetal"], bevel=0.005))
    p.append(box((0.08, 0.20, 0.16), (0.25, 0.0, 0.94), M["steel"],
                 rot=(0.0, math.radians(-18.0), 0.0), bevel=0.005))
    p.append(box((0.10, 0.09, 0.07), (0.02, 0.16, 0.90), M["ochre_light"], bevel=0.003))
    p.append(cyl(0.026, 0.48, (0.40, 0.0, 0.96), M["dark"], axis="X", verts=10))
    p.append(cyl(0.042, 0.07, (0.66, 0.0, 0.96), M["steel_light"], axis="X", verts=10))
    # Front tow bar and sand guards.
    p.append(box((0.10, 0.66, 0.10), (0.82, 0.0, 0.24), M["gunmetal"], bevel=0.004))
    # Open front fork leaves the single front tyre fully exposed.
    for side in (-1.0, 1.0):
        p.append(box((0.16, 0.055, 0.20), (0.64, side * 0.10, 0.37), M["gunmetal"],
                     rot=(0.0, 0.0, math.radians(-18.0)), bevel=0.003))
    return group(p, 0.0)


def build_raider():
    """Raider Trike: the same compact buggy with a stealth nose cowl, spiked
    ram bar and twin side boosters."""
    p = []
    wheel(p, -0.32, -0.42, 0.26, 0.20)
    wheel(p, -0.32, 0.42, 0.26, 0.20)
    wheel(p, 0.70, 0.0, 0.235, 0.15)
    p.append(cyl(0.050, 0.90, (-0.32, 0.0, 0.26), M["steel"], axis="Y", verts=12))
    p.append(prism((1.02, 0.58, 0.20), (0.0, 0.0, 0.36), M["ochre_light"], chamfer=0.12, bevel=0.018))
    # Angled stealth nose cowling over the exposed front wheel.
    p.append(prism((0.56, 0.54, 0.18), (0.40, 0.0, 0.43), M["gunmetal"], chamfer=0.16, bevel=0.014,
                   rot=(0.0, 0.0, math.radians(-3.0))))
    p.append(box((0.30, 0.46, 0.16), (-0.03, 0.0, 0.50), M["ochre"], bevel=0.010))
    p.append(box((0.15, 0.24, 0.15), (-0.19, 0.0, 0.57), M["cloth_dark"], bevel=0.008))
    for x in (-0.28, 0.14):
        for y in (-0.25, 0.25):
            p.append(box((0.045, 0.045, 0.44), (x, y, 0.69), M["ochre_light"], bevel=0.004))
    for y in (-0.25, 0.25):
        p.append(box((0.50, 0.045, 0.045), (-0.07, y, 0.91), M["ochre_light"], bevel=0.004))
    # Spiked ram bar and armoured radiator.
    p.append(box((0.10, 0.86, 0.12), (0.72, 0.0, 0.30), M["gunmetal"], bevel=0.006))
    for y in (-0.34, -0.17, 0.17, 0.34):
        p.append(box((0.15, 0.055, 0.055), (0.82, y, 0.30), M["steel_light"], bevel=0.003))
    p.append(box((0.22, 0.50, 0.26), (-0.42, 0.0, 0.48), M["gunmetal"], bevel=0.008))
    for i in range(4):
        p.append(box((0.025, 0.38, 0.035), (-0.54, 0.0, 0.39 + i * 0.050), M["dark"], bevel=0.001))
    # Twin side boosters: fat pods with dark nozzles and house rings.
    for side in (-1.0, 1.0):
        p.append(cyl(0.080, 0.52, (-0.44, side * 0.46, 0.44), M["gunmetal"], axis="X", verts=14))
        p.append(cyl(0.095, 0.12, (-0.70, side * 0.46, 0.44), M["trim"], axis="X", verts=14))
        p.append(cyl(0.060, 0.05, (-0.77, side * 0.46, 0.44), M["dark"], axis="X", verts=12))
    # Twin roof guns for the raider silhouette.
    p.append(box((0.26, 0.34, 0.10), (0.06, 0.0, 0.95), M["gunmetal"], bevel=0.005))
    for y in (-0.11, 0.11):
        p.append(cyl(0.025, 0.50, (0.36, y, 0.97), M["dark"], axis="X", verts=10))
        p.append(cyl(0.043, 0.07, (0.62, y, 0.97), M["steel_light"], axis="X", verts=10))
    house_plate(p, (0.22, 0.26, 0.05), (0.42, 0.0, 0.53))
    house_plate(p, (0.44, 0.035, 0.045), (0.0, 0.0, 0.44))
    return group(p, 0.0)


def build_quad():
    """Squat four-wheeled armoured car with big arches and a compact angled
    twin-tube rocket pod. No tank turret, no large cannon."""
    p = []
    for x in (-0.38, 0.38):
        for y in (-0.42, 0.42):
            wheel(p, x, y, 0.235, 0.18)
        p.append(cyl(0.055, 0.92, (x, 0.0, 0.235), M["steel"], axis="Y", verts=12))
    # Squat sandy-gunmetal hull with a sloped nose.
    p.append(prism((1.24, 0.94, 0.28), (0.0, 0.0, 0.37), M["sand_steel"], chamfer=0.14, bevel=0.022))
    p.append(box((0.42, 0.82, 0.18), (0.54, 0.0, 0.47), M["sand_steel_light"],
                 rot=(0.0, math.radians(-22.0), 0.0), bevel=0.012))
    p.append(box((0.14, 0.90, 0.20), (0.74, 0.0, 0.34), M["steel"], bevel=0.008))
    # Large armoured wheel arches over all four tyres.
    for side in (-1.0, 1.0):
        for x in (-0.38, 0.38):
            p.append(box((0.34, 0.16, 0.12), (x, side * 0.50, 0.47), M["steel"], bevel=0.006))
        p.append(box((1.10, 0.08, 0.18), (0.0, side * 0.47, 0.40), M["sand_steel_light"], bevel=0.006))
        house_plate(p, (0.46, 0.035, 0.055), (0.04, side * 0.515, 0.46))
    # Rear engine manifold and exhausts.
    p.append(box((0.30, 0.86, 0.24), (-0.55, 0.0, 0.47), M["gunmetal"], bevel=0.010))
    for i in range(4):
        p.append(box((0.035, 0.66, 0.032), (-0.71, 0.0, 0.36 + i * 0.052), M["dark"], bevel=0.001))
    for y in (-0.30, 0.30):
        p.append(cyl(0.050, 0.22, (-0.72, y, 0.38), M["rust"], axis="X", verts=12))
        p.append(cyl(0.070, 0.05, (-0.85, y, 0.38), M["dark"], axis="X", verts=10))
    # Compact angled twin-tube rocket pod on a low ring mount.
    p.append(cyl(0.20, 0.06, (0.04, 0.0, 0.60), M["gunmetal"], verts=18))
    p.append(prism((0.40, 0.52, 0.14), (0.04, 0.0, 0.68), M["sand_steel_light"], chamfer=0.07, bevel=0.010,
                   rot=(0.0, 0.0, math.radians(5.0))))
    for side in (-1.0, 1.0):
        p.append(cyl(0.082, 0.54, (0.26, side * 0.14, 0.76), M["gunmetal"], axis="X", verts=16))
        p.append(cyl(0.092, 0.09, (0.52, side * 0.14, 0.76), M["trim"], axis="X", verts=14))
        p.append(cyl(0.066, 0.035, (0.57, side * 0.14, 0.76), M["dark"], axis="X", verts=12))
        p.append(cyl(0.048, 0.06, (0.575, side * 0.14, 0.76), M["amber"], axis="X", verts=10))
        house_plate(p, (0.22, 0.035, 0.07), (0.08, side * 0.245, 0.70))
    p.append(box((0.20, 0.34, 0.06), (0.02, 0.0, 0.75), M["steel_light"], bevel=0.003))
    house_plate(p, (0.24, 0.40, 0.045), (0.50, 0.0, 0.54))
    return group(p, 0.0)


def _combat_hull(house):
    p = []
    if house == "harkonnen":
        length, width, height = 1.86, 1.22, 0.47
        hull_mat = M["charcoal"]
        tracked_base(p, length, width, height, hull_mat, track_width=0.33, track_offset=0.60)
        # Sharp angular armoured fenders and heavy bolted shoulder pods.
        for side in (-1.0, 1.0):
            p.append(box((length * 0.88, 0.20, 0.18), (0.0, side * 0.60, 0.50),
                         M["charcoal_light"], rot=(side * math.radians(-8.0), 0.0, 0.0), bevel=0.008))
            p.append(box((0.66, 0.16, 0.26), (-0.05, side * 0.66, 0.62), M["charcoal"],
                         rot=(side * math.radians(-12.0), 0.0, 0.0), bevel=0.010))
            house_plate(p, (0.54, 0.045, 0.13), (-0.02, side * 0.735, 0.66))
            bolts_line((0.26, side * 0.665, 0.70), (-0.34, side * 0.665, 0.70), 4, M["steel_light"], 0.012)
        p.append(box((0.30, width * 0.92, 0.28), (length * 0.42, 0.0, 0.55), M["charcoal_light"],
                     rot=(0.0, math.radians(-18.0), 0.0), bevel=0.012))
        p.append(box((0.44, width * 0.80, 0.12), (-length * 0.30, 0.0, 0.82), M["gunmetal"], bevel=0.008))
        for i in range(3):
            p.append(box((0.24, width * 0.64, 0.030), (-length * 0.36, 0.0, 0.88 + i * 0.038),
                         M["dark"], bevel=0.001))
    elif house == "ordos":
        length, width, height = 1.62, 1.00, 0.35
        hull_mat = M["slate_olive"]
        tracked_base(p, length, width, height, hull_mat, track_width=0.27, track_offset=0.50)
        # Low swept wedge: a long sloped glacis and rear stabiliser fins.
        p.append(box((0.52, width * 0.90, 0.16), (length * 0.40, 0.0, 0.48),
                     M["slate_olive_light"], rot=(0.0, math.radians(-24.0), 0.0), bevel=0.012))
        p.append(box((0.25, width * 0.82, 0.10), (length * 0.53, 0.0, 0.38),
                     M["slate_olive"], rot=(0.0, math.radians(-30.0), 0.0), bevel=0.008))
        for side in (-1.0, 1.0):
            p.append(box((0.34, 0.07, 0.13), (-length * 0.45, side * width * 0.42, 0.55),
                         M["steel"], rot=(0.0, math.radians(20.0), 0.0), bevel=0.006))
            p.append(box((length * 0.82, 0.055, 0.13), (0.0, side * width * 0.53, 0.43),
                         M["slate_olive_light"], bevel=0.005))
            house_plate(p, (0.50, 0.030, 0.040), (0.02, side * width * 0.57, 0.47))
        p.append(box((0.46, width * 0.74, 0.10), (-0.22, 0.0, 0.64), M["steel_light"],
                     rot=(0.0, math.radians(6.0), 0.0), bevel=0.006))
    else:
        length, width, height = 1.72, 1.09, 0.41
        hull_mat = M["bone_steel"]
        tracked_base(p, length, width, height, hull_mat, track_width=0.30, track_offset=0.54)
        # Clean pale brushed hull with rounded front shoulders and a smooth deck.
        for side in (-1.0, 1.0):
            p.append(cyl(0.18, 0.22, (length * 0.44, side * width * 0.34, 0.54),
                         M["bone_steel"], verts=20, bevel=0.010))
            p.append(box((length * 0.84, 0.06, 0.14), (0.0, side * width * 0.545, 0.47),
                         M["bone_steel_dark"], bevel=0.005))
            house_plate(p, (0.56, 0.035, 0.050), (-0.02, side * width * 0.575, 0.51))
        p.append(box((0.50, width * 0.82, 0.12), (-length * 0.30, 0.0, 0.64), M["bone_steel_dark"],
                     rot=(0.0, math.radians(8.0), 0.0), bevel=0.008))
        p.append(box((0.44, width * 0.68, 0.08), (-0.30, 0.0, 0.73), M["steel_light"], bevel=0.006))
        house_plate(p, (0.28, width * 0.58, 0.045), (length * 0.34, 0.0, 0.60))
    return p, length, width


def _turret_atreides(parts):
    z = 0.74
    parts.append(cyl(0.27, 0.07, (0.0, 0.0, z), M["gunmetal"], verts=24, bevel=0.004))
    parts.append(cyl(0.285, 0.20, (0.02, 0.0, z + 0.12), M["bone_steel"], verts=28, bevel=0.012))
    parts.append(sphere(0.26, (0.07, 0.0, z + 0.28), M["bone_steel"], (1.18, 1.0, 0.50)))
    parts.append(box((0.28, 0.40, 0.17), (-0.28, 0.0, z + 0.16), M["bone_steel_dark"], bevel=0.010))
    parts.append(box((0.16, 0.30, 0.12), (-0.40, 0.0, z + 0.25), M["steel_light"], bevel=0.006))
    for side in (-1.0, 1.0):
        house_plate(parts, (0.30, 0.045, 0.070), (0.03, side * 0.265, z + 0.21))
        house_plate(parts, (0.05, 0.16, 0.055), (-0.20, side * 0.245, z + 0.19))
    parts.append(cyl(0.115, 0.065, (-0.16, 0.16, z + 0.38), M["steel_light"], verts=16, bevel=0.004))
    parts.append(box((0.10, 0.10, 0.055), (-0.16, 0.16, z + 0.43), M["amber"], bevel=0.003))
    add_gun(parts, 0.20, 0.0, z + 0.17, 0.80, 0.056, M["gunmetal"], M["amber"])


def _turret_harkonnen(parts):
    z = 0.76
    parts.append(cyl(0.31, 0.07, (0.0, 0.0, z), M["gunmetal"], verts=22, bevel=0.004))
    parts.append(prism((0.70, 0.74, 0.36), (-0.02, 0.0, z + 0.21), M["charcoal"], chamfer=0.075, bevel=0.018))
    parts.append(box((0.74, 0.84, 0.14), (-0.04, 0.0, z + 0.40), M["charcoal_light"], bevel=0.010))
    parts.append(box((0.30, 0.70, 0.24), (-0.42, 0.0, z + 0.20), M["charcoal"], bevel=0.012))
    for side in (-1.0, 1.0):
        # Heavy bolted shoulder plates: the Harkonnen house flash is huge.
        parts.append(box((0.46, 0.10, 0.24), (0.02, side * 0.43, z + 0.20),
                         M["charcoal_light"], bevel=0.008))
        house_plate(parts, (0.40, 0.045, 0.15), (0.02, side * 0.495, z + 0.23))
        bolts_line((0.22, side * 0.54, z + 0.27), (-0.16, side * 0.54, z + 0.27), 3,
                   M["steel_light"], 0.011)
    parts.append(box((0.18, 0.52, 0.24), (0.35, 0.0, z + 0.24), M["gunmetal"], bevel=0.008))
    parts.append(cyl(0.13, 0.07, (-0.20, 0.18, z + 0.47), M["steel_light"], verts=16, bevel=0.004))
    parts.append(box((0.12, 0.12, 0.05), (-0.20, 0.18, z + 0.52), M["amber"], bevel=0.003))
    add_gun(parts, 0.24, 0.0, z + 0.25, 0.82, 0.088, M["gunmetal"])


def _turret_ordos(parts):
    z = 0.70
    parts.append(cyl(0.25, 0.06, (0.10, 0.0, z), M["gunmetal"], verts=22, bevel=0.004))
    # Forward-set, angular turret skewed off the centreline.
    parts.append(prism((0.60, 0.60, 0.27), (0.14, 0.0, z + 0.16), M["slate_olive"],
                       chamfer=0.12, bevel=0.014, rot=(0.0, 0.0, math.radians(-7.0))))
    parts.append(box((0.30, 0.62, 0.10), (0.34, 0.0, z + 0.36), M["slate_olive_light"],
                     rot=(0.0, math.radians(-16.0), 0.0), bevel=0.006))
    parts.append(box((0.22, 0.44, 0.16), (-0.20, 0.0, z + 0.14), M["slate_olive_light"],
                     rot=(0.0, 0.0, math.radians(-10.0)), bevel=0.008))
    for side in (-1.0, 1.0):
        house_plate(parts, (0.34, 0.040, 0.060), (0.12, side * 0.265, z + 0.22),
                    rot=(0.0, 0.0, math.radians(-7.0)))
    parts.append(cyl(0.10, 0.055, (-0.12, 0.13, z + 0.38), M["steel_light"], verts=14, bevel=0.004))
    add_gun(parts, 0.30, 0.0, z + 0.22, 0.72, 0.060, M["gunmetal"], M["amber"])


def build_combat_tank(house):
    p, length, width = _combat_hull(house)
    if house == "harkonnen":
        _turret_harkonnen(p)
    elif house == "ordos":
        _turret_ordos(p)
    else:
        _turret_atreides(p)
    return group(p, 0.0)


def _siege_hull_parts():
    """Long, heavy pale sandy-grey artillery chassis with rear stabiliser
    spades. The separate casemate turret carries the extra-long gun."""
    p = []
    tracked_base(p, 2.12, 1.14, 0.42, M["sand_steel"], track_width=0.32, track_offset=0.58)
    # Extended rear engine deck and ammunition lockers.
    p.append(box((0.52, 1.02, 0.30), (-0.98, 0.0, 0.64), M["sand_steel"], bevel=0.012))
    p.append(box((0.36, 0.44, 0.18), (-0.92, -0.34, 0.79), M["steel"], bevel=0.008))
    p.append(box((0.36, 0.44, 0.18), (-0.92, 0.34, 0.79), M["steel"], bevel=0.008))
    for side in (-1.0, 1.0):
        # Twin rear stabiliser spades digging into the sand.
        p.append(box((0.12, 0.16, 0.44), (-1.00, side * 0.42, 0.34), M["steel"],
                     rot=(side * math.radians(-3.0), 0.0, 0.0), bevel=0.006))
        p.append(box((0.40, 0.24, 0.09), (-1.18, side * 0.42, 0.15), M["steel_light"],
                     rot=(0.0, math.radians(24.0), 0.0), bevel=0.006))
        p.append(box((0.22, 0.06, 0.10), (-1.32, side * 0.42, 0.10), M["gunmetal"], bevel=0.004))
        # Armoured side skirt and a long, bold house stripe.
        p.append(box((1.55, 0.08, 0.18), (0.02, side * 0.615, 0.47), M["sand_steel_light"], bevel=0.006))
        house_plate(p, (1.15, 0.035, 0.075), (0.02, side * 0.662, 0.52))
        p.append(box((0.44, 0.10, 0.06), (0.60, side * 0.60, 0.62), M["gunmetal"], bevel=0.004))
    p.append(box((0.58, 0.94, 0.08), (0.58, 0.0, 0.66), M["sand_steel_light"], bevel=0.006))
    house_plate(p, (0.24, 0.60, 0.045), (0.86, 0.0, 0.70))
    p.append(cyl(0.30, 0.05, (-0.10, 0.0, 0.66), M["gunmetal"], verts=24))
    return p


def _siege_turret_parts():
    p = []
    z = 0.70
    p.append(cyl(0.31, 0.06, (-0.10, 0.0, z), M["gunmetal"], verts=24, bevel=0.004))
    # Wide boxy casemate set toward the rear of the hull.
    p.append(prism((0.98, 0.84, 0.36), (-0.20, 0.0, z + 0.20), M["sand_steel"],
                   chamfer=0.10, bevel=0.018))
    p.append(box((0.30, 0.72, 0.28), (-0.66, 0.0, z + 0.18), M["sand_steel_light"], bevel=0.010))
    p.append(box((0.72, 0.88, 0.10), (-0.24, 0.0, z + 0.39), M["sand_steel_light"], bevel=0.008))
    for side in (-1.0, 1.0):
        p.append(box((0.62, 0.07, 0.22), (-0.18, side * 0.44, z + 0.20),
                     M["sand_steel_light"], bevel=0.006))
        house_plate(p, (0.56, 0.040, 0.11), (-0.18, side * 0.485, z + 0.24))
        bolts_line((0.10, side * 0.48, z + 0.34), (-0.50, side * 0.48, z + 0.34), 4,
                   M["steel_light"], 0.011)
        p.append(box((0.26, 0.10, 0.10), (0.24, side * 0.38, z + 0.38), M["gunmetal"], bevel=0.004))
    # Extra-long, thick artillery barrel with a huge double-baffle brake.
    add_gun(p, -0.12, 0.0, z + 0.24, 1.66, 0.100, M["gunmetal"])
    p.append(cyl(0.155, 0.10, (1.24, 0.0, z + 0.24), M["steel_light"], axis="X", verts=18, bevel=0.004))
    p.append(cyl(0.128, 0.08, (1.37, 0.0, z + 0.24), M["dark"], axis="X", verts=16, bevel=0.003))
    p.append(box((0.16, 0.06, 0.06), (0.30, 0.30, z + 0.40), M["steel_light"], bevel=0.003))
    p.append(cyl(0.11, 0.055, (-0.42, 0.18, z + 0.45), M["steel_light"], verts=14, bevel=0.003))
    p.append(box((0.09, 0.09, 0.045), (-0.42, 0.18, z + 0.49), M["amber"], bevel=0.002))
    return p


def build_tank_hull():
    return group(_siege_hull_parts(), 0.0)


def build_tank_turret():
    return group(_siege_turret_parts(), 0.0)


def build_tank():
    p = _siege_hull_parts()
    p.extend(_siege_turret_parts())
    return group(p, 0.0)


def build_sonic():
    """Pale armoured acoustic tank carrying a huge glowing cyan parabolic
    dish on a heavy yoke. No gun barrel at all."""
    p = []
    tracked_base(p, 1.74, 1.06, 0.36, M["bone_steel"], track_width=0.29, track_offset=0.54)
    # Armoured cradle and two heavy yoke arms.
    p.append(box((0.56, 0.76, 0.20), (0.0, 0.0, 0.64), M["bone_steel_dark"], bevel=0.012))
    p.append(box((0.40, 0.56, 0.14), (0.18, 0.0, 0.74), M["steel"], bevel=0.008))
    for side in (-1.0, 1.0):
        p.append(box((0.18, 0.16, 0.46), (0.10, side * 0.36, 0.91), M["steel_light"],
                     rot=(side * math.radians(-7.0), 0.0, 0.0), bevel=0.008))
        p.append(cyl(0.10, 0.10, (0.16, side * 0.42, 1.02), M["gunmetal"], axis="Y", verts=14))
        house_plate(p, (0.22, 0.10, 0.07), (-0.02, side * 0.49, 0.57))
    # Large unmistakable parabolic dish facing forward.
    p.append(cyl(0.54, 0.10, (0.16, 0.0, 1.02), M["steel_light"], axis="X", verts=36, bevel=0.006))
    p.append(cyl(0.47, 0.12, (0.23, 0.0, 1.02), M["sonic"], axis="X", verts=36))
    p.append(cyl(0.35, 0.14, (0.29, 0.0, 1.02), M["dark"], axis="X", verts=30))
    p.append(cyl(0.18, 0.16, (0.36, 0.0, 1.02), M["sonic_glow"], axis="X", verts=24))
    p.append(cyl(0.08, 0.18, (0.42, 0.0, 1.02), M["dark"], axis="X", verts=18))
    # Glowing concentric rings and bold house tabs around the rim.
    for radius in (0.44, 0.30):
        p.append(cyl(radius, 0.018, (0.14, 0.0, 1.02), M["sonic_glow"], axis="X", verts=32, bevel=0.0))
    for i in range(10):
        a = math.tau * i / 10.0
        p.append(box((0.055, 0.10, 0.045), (0.11, math.cos(a) * 0.51, 1.02 + math.sin(a) * 0.51),
                     M["trim"], rot=(a, 0.0, 0.0), bevel=0.0))
    for i in range(3):
        p.append(box((0.02, 0.62, 0.022), (0.115, 0.0, 1.02 + (float(i) - 1.0) * 0.17),
                     M["sonic_glow"], bevel=0.0))
    # Rear heat exchangers behind the dish.
    for side in (-1.0, 1.0):
        p.append(box((0.24, 0.18, 0.14), (-0.56, side * 0.30, 0.52), M["gunmetal"], bevel=0.006))
        p.append(box((0.03, 0.13, 0.03), (-0.69, side * 0.30, 0.52), M["cyan"], bevel=0.0))
    house_plate(p, (0.28, 0.56, 0.045), (-0.64, 0.0, 0.48))
    return group(p, 0.0)


def build_devastator():
    """Wide octagonal super-heavy dreadnought: split track pods, obsidian
    armour, hot reactor vents and a broad twin plasma turret."""
    p = []
    # Split track pods: two short, thick sponons per side with a visible gap,
    # outboard of every other chassis.
    for side in (-1.0, 1.0):
        for x0, x1 in ((-0.98, -0.34), (0.34, 0.98)):
            track_sponson(p, side, x0, x1, width=0.36, height=0.38, y_center=0.74)
    p.append(box((1.94, 1.18, 0.16), (0.0, 0.0, 0.13), M["dark"], bevel=0.008))
    # Hulking octagonal armoured hull.
    p.append(prism((2.20, 1.58, 0.48), (0.0, 0.0, 0.44), M["obsidian"], chamfer=0.28, bevel=0.028))
    p.append(box((1.72, 1.30, 0.10), (0.0, 0.0, 0.70), M["obsidian_light"], bevel=0.008))
    p.append(box((1.50, 0.12, 0.06), (0.0, 0.0, 0.76), M["steel"], bevel=0.004))
    for side in (-1.0, 1.0):
        # Heavy angled side armour pods with house flashes.
        p.append(box((1.16, 0.20, 0.32), (0.0, side * 0.84, 0.55), M["obsidian_light"],
                     rot=(side * math.radians(-9.0), 0.0, 0.0), bevel=0.012))
        p.append(box((0.54, 0.28, 0.26), (0.62, side * 0.78, 0.44), M["obsidian"],
                     rot=(0.0, 0.0, math.radians(-12.0)), bevel=0.010))
        house_plate(p, (0.92, 0.045, 0.12), (0.0, side * 0.955, 0.61))
        house_plate(p, (0.34, 0.045, 0.10), (0.62, side * 0.915, 0.50))
        p.append(box((0.18, 0.10, 0.16), (1.04, side * 0.55, 0.44), M["steel"], bevel=0.005))
    # Rear reactor radiator bank: four glowing orange-red vent stacks.
    p.append(box((0.26, 1.28, 0.34), (-1.02, 0.0, 0.70), M["obsidian_light"], bevel=0.010))
    for y in (-0.48, -0.16, 0.16, 0.48):
        p.append(box((0.20, 0.22, 0.20), (-1.08, y, 0.70), M["reactor"], bevel=0.006))
        for i in range(3):
            p.append(box((0.035, 0.16, 0.022), (-1.19, y, 0.60 + i * 0.075), M["dark"], bevel=0.0))
        p.append(cyl(0.07, 0.12, (-1.15, y, 0.88), M["reactor"], verts=12))
    # Broad twin-plasma turret.
    p.append(cyl(0.46, 0.07, (0.06, 0.0, 0.82), M["gunmetal"], verts=28, bevel=0.004))
    p.append(prism((1.04, 1.02, 0.42), (0.06, 0.0, 1.00), M["obsidian"], chamfer=0.18, bevel=0.022))
    p.append(box((0.82, 0.90, 0.10), (0.06, 0.0, 1.23), M["obsidian_light"], bevel=0.008))
    p.append(box((0.34, 0.96, 0.24), (-0.48, 0.0, 1.02), M["obsidian"], bevel=0.012))
    for side in (-1.0, 1.0):
        house_plate(p, (0.52, 0.050, 0.15), (0.02, side * 0.545, 1.05))
        p.append(box((0.26, 0.10, 0.12), (0.30, side * 0.44, 1.16), M["steel_light"], bevel=0.004))
    # Two thick parallel barrels with white-hot plasma tips.
    for y in (-0.23, 0.23):
        add_gun(p, 0.34, y, 1.04, 1.02, 0.105, M["gunmetal"], M["plasma"])
        p.append(cyl(0.155, 0.10, (0.92, y, 1.04), M["steel_light"], axis="X", verts=18, bevel=0.004))
        p.append(box((0.14, 0.20, 0.13), (0.28, y, 1.16), M["steel"], bevel=0.004))
    p.append(cyl(0.15, 0.07, (-0.34, 0.20, 1.38), M["steel_light"], verts=16, bevel=0.004))
    p.append(box((0.13, 0.13, 0.05), (-0.34, 0.20, 1.43), M["reactor"], bevel=0.003))
    return group(p, 0.0)


def build_deviator():
    """Sloped dark-slate tracked chassis carrying a large angled six-tube
    missile battery with bright emerald warheads."""
    p = []
    tracked_base(p, 1.78, 1.06, 0.34, M["slate_dark"], track_width=0.28, track_offset=0.55)
    p.append(box((0.56, 0.92, 0.16), (0.58, 0.0, 0.48), M["slate_dark"],
                 rot=(0.0, math.radians(-22.0), 0.0), bevel=0.010))
    p.append(box((0.72, 0.90, 0.22), (-0.28, 0.0, 0.65), M["slate_dark"], bevel=0.010))
    # Launcher erector frame, angled up toward the front.
    p.append(box((0.92, 1.00, 0.10), (-0.22, 0.0, 0.74), M["steel"],
                 rot=(0.0, math.radians(-10.0), 0.0), bevel=0.006))
    for zlev in (0.86, 1.01):
        for y in (-0.28, 0.0, 0.28):
            tilt = math.radians(-14.0)
            p.append(cyl(0.078, 0.78, (-0.22, y, zlev), M["gunmetal"],
                         axis="X", verts=16, bevel=0.004, rot=(0.0, tilt, 0.0)))
            # Emerald warhead at the raised front tip of each tube.
            tip_x = -0.22 + math.cos(-tilt) * 0.42
            tip_z = zlev - math.sin(tilt) * 0.42
            p.append(cyl(0.088, 0.11, (tip_x, y, tip_z), M["emerald"],
                         axis="X", verts=14, bevel=0.003, rot=(0.0, tilt, 0.0)))
            p.append(cyl(0.050, 0.05, (tip_x + 0.055, y, tip_z + 0.012), M["yellow"],
                         axis="X", verts=10, bevel=0.002, rot=(0.0, tilt, 0.0)))
    for side in (-1.0, 1.0):
        p.append(box((0.84, 0.06, 0.22), (-0.22, side * 0.54, 0.86), M["slate_dark"],
                     rot=(0.0, math.radians(-10.0), 0.0), bevel=0.006))
        house_plate(p, (0.58, 0.040, 0.11), (-0.22, side * 0.585, 0.90))
        p.append(box((0.30, 0.10, 0.10), (0.36, side * 0.44, 0.62), M["steel"], bevel=0.004))
    # Rear exhaust and hazard placard.
    for y in (-0.30, 0.30):
        p.append(cyl(0.05, 0.20, (-0.84, y, 0.46), M["rust"], axis="X", verts=10))
        p.append(cyl(0.07, 0.05, (-0.96, y, 0.46), M["dark"], axis="X", verts=10))
    p.append(box((0.30, 0.48, 0.06), (-0.70, 0.0, 0.60), M["yellow"], bevel=0.003))
    p.append(box((0.24, 0.10, 0.02), (-0.865, 0.0, 0.60), M["dark"], bevel=0.0))
    house_plate(p, (0.34, 0.52, 0.045), (0.42, 0.0, 0.60))
    return group(p, 0.0)


def _harvester_fill(parts, fill):
    """Open grated hopper with a visible spice pile: dark bay when empty, a low
    orange pile at half, a mounded glowing load when full."""
    # Recessed dark metal bay floor.
    parts.append(box((0.90, 0.92, 0.05), (-0.48, 0.0, 0.73), M["dark"], bevel=0.004))
    for i in range(5):
        parts.append(box((0.86, 0.035, 0.025), (-0.48, -0.36 + i * 0.18, 0.985), M["grill"], bevel=0.0))
    if fill <= 0.05:
        # Empty bay: grating and shadowed ribs only.
        for i in range(4):
            parts.append(box((0.035, 0.86, 0.03), (-0.82 + i * 0.22, 0.0, 0.77), M["steel"], bevel=0.0))
        return
    if fill < 0.62:
        for i in range(5):
            x = -0.78 + i * 0.14
            parts.append(sphere(0.16, (x, -0.14 + (i % 2) * 0.26, 0.80), M["spice"], (1.15, 1.05, 0.42)))
        parts.append(box((0.72, 0.72, 0.055), (-0.48, 0.0, 0.79), M["spice"], bevel=0.010))
        return
    # Full: a proper mounded load with brighter, lumpy spice.
    parts.append(box((0.80, 0.82, 0.13), (-0.48, 0.0, 0.82), M["spice"], bevel=0.012))
    for i in range(7):
        x = -0.80 + (i % 3) * 0.20 + (i // 3) * 0.07
        y = -0.24 + (i % 2) * 0.48
        parts.append(sphere(0.18, (x, y, 0.91 + (i % 3) * 0.018), M["spice_glow"],
                            (1.15, 1.10, 0.48)))
    parts.append(sphere(0.22, (-0.48, 0.0, 0.94), M["spice_glow"], (1.02, 1.02, 0.42)))
    parts.append(sphere(0.15, (-0.35, 0.15, 0.96), M["spice_glow"], (1.0, 1.0, 0.40)))


def build_harvester(fill):
    """Long industrial mining rig in weathered ochre, with a wide hazard-\n    striped toothed scoop, an open grated spice hopper and twin tall stacks."""
    p = []
    tracked_base(p, 2.04, 1.16, 0.36, M["ochre"], track_width=0.32, track_offset=0.58)
    # Forward sloped cab with a broad armoured glass cockpit.
    p.append(box((0.66, 0.88, 0.46), (0.42, 0.0, 0.68), M["ochre_light"], bevel=0.014))
    p.append(box((0.34, 0.84, 0.26), (0.72, 0.0, 0.76), M["ochre"],
                 rot=(0.0, math.radians(-20.0), 0.0), bevel=0.010))
    p.append(box((0.20, 0.66, 0.16), (0.84, 0.0, 0.78), M["glass"],
                 rot=(0.0, math.radians(-18.0), 0.0), bevel=0.006))
    p.append(box((0.52, 0.74, 0.07), (0.40, 0.0, 0.93), M["ochre"], bevel=0.006))
    p.append(box((0.14, 0.68, 0.16), (0.98, 0.0, 0.64), M["steel"], bevel=0.006))
    house_plate(p, (0.20, 0.44, 0.055), (0.62, 0.0, 0.90))
    house_plate(p, (0.10, 0.30, 0.075), (0.90, 0.0, 0.68))
    # Open hopper: four tall ochre walls, top rails and exposed grating.
    p.append(box((0.96, 0.08, 0.30), (-0.48, -0.51, 0.87), M["ochre_light"], bevel=0.006))
    p.append(box((0.96, 0.08, 0.30), (-0.48, 0.51, 0.87), M["ochre_light"], bevel=0.006))
    p.append(box((0.08, 0.94, 0.30), (0.00, 0.0, 0.87), M["ochre_light"], bevel=0.006))
    p.append(box((0.08, 0.94, 0.30), (-0.96, 0.0, 0.87), M["ochre"], bevel=0.006))
    for y in (-0.53, 0.53):
        p.append(box((0.98, 0.06, 0.05), (-0.48, y, 1.035), M["steel_light"], bevel=0.003))
        house_plate(p, (0.44, 0.030, 0.06), (-0.48, y * 1.02, 0.90))
    for x in (-0.94, -0.02):
        p.append(box((0.06, 0.98, 0.05), (x, 0.0, 1.035), M["steel_light"], bevel=0.003))
    _harvester_fill(p, fill)
    # Twin tall chrome/soot exhaust stacks behind the hopper.
    for y in (-0.32, 0.32):
        p.append(box((0.18, 0.18, 0.10), (-1.02, y, 0.88), M["steel"], bevel=0.006))
        p.append(cyl(0.058, 0.62, (-1.02, y, 1.22), M["chrome"], verts=14))
        p.append(cyl(0.070, 0.10, (-1.02, y, 1.42), M["dark"], verts=12))
        p.append(cyl(0.082, 0.08, (-1.02, y, 1.48), M["rust"], verts=12))
        p.append(cyl(0.058, 0.06, (-1.02, y, 1.54), M["dark"], verts=10))
    # Wide front toothed scoop with alternating yellow/black hazard stripes.
    p.append(box((0.48, 1.22, 0.24), (1.10, 0.0, 0.27), M["steel"],
                 rot=(0.0, 0.0, -0.14), bevel=0.010))
    p.append(box((0.22, 1.14, 0.18), (1.32, 0.0, 0.20), M["gunmetal"],
                 rot=(0.0, 0.0, -0.20), bevel=0.008))
    p.append(box((0.40, 0.78, 0.06), (1.12, -0.18, 0.41), M["yellow"],
                 rot=(0.0, 0.0, -0.14), bevel=0.003))
    p.append(box((0.40, 0.30, 0.065), (1.12, 0.44, 0.41), M["dark"],
                 rot=(0.0, 0.0, -0.14), bevel=0.003))
    for i in range(6):
        y = -0.56 + i * 0.225
        p.append(box((0.16, 0.11, 0.035), (1.17, y, 0.43), M["dark"],
                     rot=(0.0, 0.0, math.radians(52.0)), bevel=0.0))
        p.append(box((0.16, 0.11, 0.035), (1.17, y + 0.11, 0.43), M["yellow"],
                     rot=(0.0, 0.0, math.radians(52.0)), bevel=0.0))
    for i in range(8):
        p.append(box((0.15, 0.09, 0.12), (1.42, -0.50 + i * 0.143, 0.14),
                     M["steel_light"], rot=(0.0, 0.0, -0.38), bevel=0.003))
    p.append(box((0.14, 1.20, 0.10), (1.36, 0.0, 0.30), M["ochre_light"], bevel=0.004))
    house_plate(p, (0.30, 0.66, 0.045), (1.03, 0.0, 0.44))
    house_plate(p, (0.42, 0.20, 0.05), (0.93, 0.0, 0.50))
    return group(p, 0.0)


def build_carryall():
    p = []
    # Wide armored lifter with two solid wing pods and guarded lift ducts.
    p.append(prism((1.55, 1.40, 0.34), (0.0, 0.0, 0.78), M["olive"],
                   chamfer=0.16, bevel=0.026))
    for side in (-1.0, 1.0):
        p.append(box((1.34, 0.70, 0.24), (-0.16, side * 1.02, 0.78), M["olive_light"], bevel=0.014))
        p.append(box((1.10, 0.10, 0.08), (-0.12, side * 1.30, 0.86), M["trim"], bevel=0.004))
        p.append(box((0.80, 0.12, 0.16), (-0.05, side * 0.74, 0.99), M["steel"], bevel=0.008))
        for x in (-0.48, 0.42):
            p.append(cyl(0.28, 0.15, (x, side * 1.10, 0.92), M["gunmetal"],
                         axis="Z", verts=20, bevel=0.006))
            p.append(cyl(0.20, 0.045, (x, side * 1.10, 1.02), M["dark"],
                         axis="Z", verts=18, bevel=0.004))
            for i in range(4):
                p.append(box((0.07, 0.20, 0.022), (x - 0.19 + i * 0.13,
                         side * 1.10, 1.07), M["steel_light"], bevel=0.002))
    p.append(box((0.72, 0.70, 0.30), (0.62, 0.0, 0.78), M["olive"], bevel=0.012))
    p.append(box((0.28, 0.50, 0.16), (0.86, 0.0, 0.84), M["glass"],
                 rot=(0.0, 0.0, -0.15), bevel=0.008))
    p.append(box((0.20, 0.58, 0.10), (0.94, 0.0, 0.73), M["steel"], bevel=0.006))
    for y in (-0.24, 0.24):
        p.append(cyl(0.10, 0.50, (-0.72, y, 0.80), M["steel"], axis="Y", verts=14))
        p.append(cyl(0.14, 0.10, (-0.96, y, 0.80), M["dark"], axis="Y", verts=12))
    for i in range(4):
        p.append(box((0.22, 0.66, 0.06), (-0.52, 0.0, 0.53 + i * 0.045), M["gunmetal"], bevel=0.004))
    trim_strip(p, (0.43, 0.28, 0.04), (0.10, 0.0, 1.00))
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
    # The sheet doubled in pixel density, so scale the contact shadow with it.
    return bb.with_drop_shadow(img, offset=(10, 12), blur=8.0, alpha=0.36)


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
            render_to(path, cell, 1.80)
            raw = Image.open(path).convert("RGBA")
            img = drop_shadow(downscale(raw, (px, px)))
            sheet.alpha_composite(img, (anim * px, d * px))
    sheet = normalize_rgba(sheet, 55.0, saturation=1.12, contrast=1.03)
    path = OUT_DIR / (kind + ".png")
    sheet.save(path)
    print("UNIT SHEET %-16s %dx%d cell=%d poses=4 dirs=8" % (kind, sheet.width, sheet.height, px), flush=True)
    return path


def bake_tank_parts():
    cell = CELLS["tank"]
    px = cell * RENDER_SCALE
    for sheet_id, builder in (("tank_hull", build_tank_hull), ("tank_turret", build_tank_turret)):
        bake_vehicle_boxes(sheet_id, builder, cell, VIEW["tank"])


def bake_harvester():
    cell = CELLS["harvester"]
    for name, fill in (("empty", 0.0), ("half", 0.5), ("full", 1.0)):
        bake_vehicle_boxes("harvester_" + name, lambda f=fill: build_harvester(f), cell, VIEW["harvester"])


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
    size = ICON_VIEW.get(kind, 1.70)
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
            bake_vehicle_boxes("carryall", build_carryall, CELLS[kind], VIEW["carryall"])
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
