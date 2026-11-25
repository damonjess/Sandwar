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
from mathutils import Matrix, Vector

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
    # 1.31x the combat tank's visible length: compact industrial rig, not a
    # screen-filling superheavy. (Tank cell 64, visible hull ~52 px; the dozer
    # rig's shorter nose is compensated in the cell and rear bumper.)
    "harvester": 84, "mcv": 88, "carryall": 96,
    "frigate": 150, "ornithopter": 82,
}
VIEW = {
    "trike": 2.05, "raider_trike": 2.05, "quad": 2.30,
    "atreides_tank": 2.58, "harkonnen_tank": 2.68, "ordos_tank": 2.48,
    "sonic_tank": 2.72, "devastator": 3.55, "deviator": 2.68,
    "carryall": 3.78, "tank": 3.35, "harvester": 3.30, "mcv": 4.25,
    "frigate": 6.10, "ornithopter": 4.45,
}
ICON_VIEW = {
    "infantry": 1.85, "rocket": 1.85, "fremen": 1.85, "sardaukar": 1.85,
    "saboteur": 1.85, "trike": 1.62, "raider_trike": 1.76, "quad": 2.38,
    "atreides_tank": 2.68, "harkonnen_tank": 2.76, "ordos_tank": 2.56,
    "sonic_tank": 2.82, "devastator": 3.70, "deviator": 2.76,
    "harvester": 3.40, "tank": 3.60, "mcv": 4.30,
    "carryall": 3.95, "frigate": 6.20, "ornithopter": 4.40,
}
INFANTRY = ("infantry", "rocket", "fremen", "sardaukar", "saboteur")
ICON_IDS = ("infantry", "rocket", "fremen", "sardaukar", "saboteur", "trike",
            "raider_trike", "quad", "tank", "atreides_tank", "harkonnen_tank",
            "ordos_tank", "sonic_tank", "devastator", "deviator", "harvester", "mcv",
            "carryall", "frigate", "ornithopter")
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
    M["steel"] = material("Unit Steel", (0.300, 0.265, 0.205), 0.72, 0.44, rust=0.30, dirt=0.44)
    M["steel_light"] = material("Unit Steel Light", (0.440, 0.370, 0.270), 0.64, 0.38, rust=0.20, dirt=0.38)
    M["gunmetal"] = material("Unit Gunmetal", (0.105, 0.100, 0.085), 0.78, 0.44, rust=0.16, dirt=0.40)
    M["olive"] = material("Unit Olive", (0.370, 0.365, 0.245), 0.34, 0.68, rust=0.18, dirt=0.48)
    M["olive_light"] = material("Unit Olive Light", (0.510, 0.480, 0.330), 0.28, 0.60, rust=0.12, dirt=0.42)
    M["armor"] = material("Unit Armor", (0.560, 0.480, 0.340), 0.30, 0.54, rust=0.10, dirt=0.34)
    M["armor_light"] = material("Unit Armor Light", (0.725, 0.620, 0.455), 0.24, 0.48, rust=0.06, dirt=0.28)
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
    M["white"] = material("Unit Bone", (0.730, 0.660, 0.525), 0.14, 0.62, dirt=0.2)
    # --------------------------------------------------- distinct hull palettes
    # Harvester: weathered industrial ochre, deliberately not tank grey.
    M["ochre"] = material("Harvester Ochre", (0.600, 0.420, 0.135), 0.28, 0.68, rust=0.0, dirt=0.50)
    M["ochre_light"] = material("Harvester Ochre Light", (0.750, 0.555, 0.205), 0.24, 0.60, rust=0.0, dirt=0.44)
    M["ochre_dark"] = material("Harvester Ochre Shadow", (0.430, 0.300, 0.100), 0.32, 0.74, rust=0.0, dirt=0.55)
    # ------------------------------------------------------- Shai-Hulud organics
    M["worm_hide"] = material("Worm Hide", (0.235, 0.148, 0.095), 0.03, 0.86,
                              dirt=0.46, bump=0.54)
    M["worm_plate"] = material("Worm Armour Scale", (0.395, 0.260, 0.150), 0.14, 0.64,
                               dirt=0.42, bump=0.58)
    M["worm_plate_dark"] = material("Worm Armour Shadow", (0.235, 0.145, 0.085), 0.10, 0.72,
                                    dirt=0.47, bump=0.52)
    M["worm_sand"] = material("Worm Sand Crust", (0.680, 0.535, 0.345), 0.02, 0.92,
                              dirt=0.24, bump=0.34)
    M["worm_sand_light"] = material("Worm Sand Light", (0.820, 0.675, 0.470), 0.02, 0.90,
                                    dirt=0.16, bump=0.28)
    M["worm_shadow_sand"] = material("Worm Slip Face", (0.275, 0.180, 0.110), 0.02, 0.94,
                                      dirt=0.22, bump=0.24)
    M["worm_flesh"] = material("Worm Flesh", (0.265, 0.078, 0.058), 0.05, 0.62,
                               dirt=0.12, bump=0.42)
    M["worm_gum"] = material("Worm Gum", (0.060, 0.014, 0.012), 0.03, 0.54,
                             dirt=0.08, bump=0.38)
    M["worm_bone"] = material("Worm Crystal Tooth", (0.885, 0.810, 0.660), 0.06, 0.36,
                              dirt=0.08, bump=0.18)
    M["worm_rock"] = material("Worm Erupted Rock", (0.155, 0.100, 0.065), 0.02, 0.92,
                              dirt=0.26, bump=0.40)
    # The gullet is almost black umber, with only a faint coal-deep ember so
    # the concentric tooth rings stay legible instead of blowing out yellow.
    M["worm_glow_deep"] = material("Worm Gullet Depth", (0.070, 0.014, 0.010), 0.02, 0.60,
                                   dirt=0.04, bump=0.16, emission=(0.25, 0.030, 0.010), strength=0.18)
    # Atreides: pale brushed steel-bone.
    M["bone_steel"] = material("Atreides Bone Steel", (0.635, 0.575, 0.440), 0.58, 0.38, rust=0.0, dirt=0.16)
    M["bone_steel_dark"] = material("Atreides Bone Dark", (0.455, 0.410, 0.305), 0.52, 0.48, rust=0.0, dirt=0.22)
    # Harkonnen: heavy charcoal steel.
    M["charcoal"] = material("Harkonnen Charcoal", (0.085, 0.090, 0.092), 0.76, 0.42, rust=0.0, dirt=0.24)
    M["charcoal_light"] = material("Harkonnen Charcoal Light", (0.175, 0.180, 0.175), 0.70, 0.44, rust=0.0, dirt=0.22)
    # Ordos: low weathered slate-olive.
    M["slate_olive"] = material("Ordos Slate Olive", (0.235, 0.285, 0.220), 0.55, 0.58, rust=0.0, dirt=0.28)
    M["slate_olive_light"] = material("Ordos Slate Light", (0.345, 0.390, 0.300), 0.50, 0.52, rust=0.0, dirt=0.24)
    # Siege artillery: pale sandy-grey.
    M["sand_steel"] = material("Siege Sand Steel", (0.510, 0.445, 0.315), 0.52, 0.50, rust=0.0, dirt=0.30)
    M["sand_steel_light"] = material("Siege Sand Light", (0.645, 0.560, 0.400), 0.44, 0.46, rust=0.0, dirt=0.26)
    # Devastator: near-black obsidian steel with hot reactor accents.
    M["obsidian"] = material("Devastator Obsidian", (0.052, 0.056, 0.062), 0.82, 0.34, rust=0.0, dirt=0.18)
    M["obsidian_light"] = material("Devastator Edge", (0.125, 0.130, 0.138), 0.78, 0.36, rust=0.0, dirt=0.18)
    # Deviator: dark slate tracked chassis.
    M["slate_dark"] = material("Deviator Slate", (0.145, 0.165, 0.185), 0.62, 0.48, rust=0.0, dirt=0.26)
    M["chrome"] = material("Unit Chrome", (0.535, 0.475, 0.365), 0.96, 0.18, rust=0.05, dirt=0.22)
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


def sphere(radius, loc, mat, scale=(1.0, 1.0, 1.0), segments=20, rings=10):
    return bb.sphere(radius, loc, mat, scale=scale, segments=segments, rings=rings)


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


def swept_wing(root_chord, tip_chord, span, loc, mat, side=1.0,
               sweep=0.42, thickness=0.13, bevel=0.010):
    """A tapered, swept planform with its root buried inside the hull.

    A rectangular box reads as a detached plank at sprite scale. This four-
    corner airfoil has a broad root chord, a narrower tip and a continuous
    lower/upper skin, so the wing visibly grows out of the fuselage.
    """
    rle, rte = root_chord * 0.5, -root_chord * 0.5
    tle, tte = -sweep + tip_chord * 0.5, -sweep - tip_chord * 0.5
    y0, y1 = 0.0, side * span
    bm = bmesh.new()
    bottom = [bm.verts.new(v) for v in ((rle, y0, -thickness * 0.5),
                                        (rte, y0, -thickness * 0.5),
                                        (tte, y1, -thickness * 0.5),
                                        (tle, y1, -thickness * 0.5))]
    top = [bm.verts.new(v) for v in ((rle, y0, thickness * 0.5),
                                     (rte, y0, thickness * 0.5),
                                     (tte, y1, thickness * 0.5),
                                     (tle, y1, thickness * 0.5))]
    bm.faces.new(tuple(reversed(bottom)))
    bm.faces.new(tuple(top))
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((bottom[i], bottom[j], top[j], top[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("SweptWing")
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new("SweptWing", mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = loc
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
        # Half load: a low bed of separate coarse granules. Spacing is wider
        # than the granule radius so the load reads as ore, not orange sausage.
        parts.append(box((0.78, 0.80, 0.045), (-0.48, 0.0, 0.775), M["spice"], bevel=0.008))
        for i in range(15):
            x = -0.80 + float(i % 5) * 0.155 + 0.02 * math.sin(float(i) * 2.1)
            y = -0.27 + float((i // 5) % 3) * 0.27 + 0.045 * math.sin(float(i) * 2.3)
            z = 0.805 + 0.02 * math.sin(float(i) * 1.7)
            r = 0.052 + 0.014 * (0.5 + 0.5 * math.sin(float(i) * 3.1))
            mat = M["spice_glow"] if i % 6 == 0 else M["spice"]
            parts.append(sphere(r, (x, y, z), mat, (1.15, 1.05, 0.62),
                                segments=12, rings=6))
        for i in range(8):
            parts.append(sphere(0.030, (-0.82 + float(i % 4) * 0.20,
                                        -0.20 + float(i // 4) * 0.36, 0.835),
                                M["spice"], (1.1, 1.0, 0.7), segments=10, rings=5))
        return
    # Full: a granular mound that bulges to the top rails without spilling over.
    parts.append(box((0.82, 0.84, 0.09), (-0.48, 0.0, 0.815), M["spice"], bevel=0.010))
    for i in range(24):
        gx = float(i % 6) / 5.0
        gy = float((i // 6) % 4) / 3.0
        x = -0.82 + gx * 0.68 + 0.02 * math.sin(float(i) * 2.1)
        y = -0.32 + gy * 0.62 + 0.03 * math.sin(float(i) * 1.4)
        # Rounded crown: highest over the hopper centre, tapering to the walls.
        dx = (gx - 0.5) * 2.0
        dy = (gy - 0.5) * 2.0
        crown = max(0.0, 1.0 - dx * dx * 0.70 - dy * dy * 0.48)
        z = 0.865 + crown * 0.085 + 0.016 * math.sin(float(i) * 2.7)
        r = 0.052 + 0.020 * (0.5 + 0.5 * math.sin(float(i) * 1.9))
        mat = M["spice_glow"] if i % 8 == 0 else M["spice"]
        parts.append(sphere(r, (x, y, z), mat, (1.18, 1.10, 0.66), segments=12, rings=6))
    # Bigger clods and hot nuggets breaking up the surface.
    for i in range(7):
        a = math.tau * float(i) / 7.0 + 0.4
        parts.append(sphere(0.070, (-0.48 + math.cos(a) * 0.24,
                                    math.sin(a) * 0.22, 0.945),
                            M["spice_glow"], (1.15, 1.05, 0.62), segments=12, rings=6))
    for i in range(5):
        parts.append(sphere(0.042, (-0.80 + float(i) * 0.18, -0.32 + float(i % 2) * 0.62, 0.915),
                            M["worm_sand"], (1.3, 1.1, 0.55), segments=10, rings=5))


def hazard_strip(parts, size, loc, rot=(0.0, 0.0, 0.0)):
    """Yellow plate cut by black diagonal blocks, for cutter collars and bumpers."""
    parts.append(box(size, loc, M["yellow"], rot=rot, bevel=0.002))
    count = max(2, int(size[1] / 0.075))
    for i in range(count):
        off = -size[1] * 0.5 + (i + 0.5) * size[1] / float(count)
        parts.append(box((size[0] * 0.92, size[1] / float(count) * 0.46, 0.004),
                         (loc[0], loc[1] + off, loc[2] + size[2] * 0.5 + 0.002),
                         M["dark"], rot=rot, bevel=0.0))


def rotary_drum(parts, x, y, z, phase, radius=0.30, harvest=False):
    """Heavy front cutter: a hazard collared drum with hardened picks."""
    parts.append(cyl(radius, 0.36, (x, y, z), M["gunmetal"], axis="Y", verts=20, bevel=0.008))
    # Yellow/black collars on both cheeks.
    for cheek in (-1.0, 1.0):
        parts.append(cyl(radius * 1.045, 0.045, (x, y + cheek * 0.195, z),
                         M["yellow"], axis="Y", verts=20, bevel=0.002))
        for i in range(10):
            a = math.tau * i / 10.0
            parts.append(box((0.075, 0.012, 0.085),
                             (x + math.cos(a) * radius * 1.01,
                              y + cheek * 0.222,
                              z + math.sin(a) * radius * 1.01),
                             M["dark"], rot=(0.0, -a, 0.0), bevel=0.0))
    # Pick teeth around the barrel, plus two spiral flights.
    for i in range(12):
        a = phase + math.tau * i / 12.0
        px = x + math.cos(a) * radius * 1.10
        pz = z + math.sin(a) * radius * 1.10
        parts.append(box((0.15, 0.30, 0.075), (px, y, pz), M["steel_light"],
                         rot=(0.0, -a, 0.0), bevel=0.003))
        parts.append(box((0.06, 0.24, 0.035), (px + math.cos(a) * 0.055, y,
                         pz + math.sin(a) * 0.055), M["dark"],
                         rot=(0.0, -a, 0.0), bevel=0.0))
    for i in range(16):
        a = -phase * 1.6 + math.tau * i / 16.0
        parts.append(box((0.05, 0.34, 0.05),
                         (x + math.cos(a) * radius * 0.72, y,
                          z + math.sin(a) * radius * 0.72),
                         M["steel"], rot=(0.0, -a, 0.0), bevel=0.001))
    # Hub, hydraulic motor and a spray of ore dust baked into the harvest pose.
    parts.append(cyl(radius * 0.40, 0.40, (x, y, z), M["ochre_light"], axis="Y", verts=16, bevel=0.004))
    parts.append(cyl(radius * 0.18, 0.43, (x, y, z), M["dark"], axis="Y", verts=12, bevel=0.002))
    if harvest:
        for i in range(5):
            a = -0.8 + float(i) * 0.42
            parts.append(sphere(0.055, (x + math.cos(a) * (radius + 0.10),
                                        y - 0.08 + float(i % 2) * 0.13,
                                        z + math.sin(a) * (radius + 0.06)),
                                M["spice"], (1.0, 1.2, 0.7)))


def build_harvester(fill, harvesting=False):
    """Dozer-scoop ore crawler: sloped ochre cab, enclosed treads, one tall
    rear stack, an open rear hopper with graded spice loads and a wide toothed
    bulldozer blade wearing diagonal hazard stripes.

    `harvesting` is the second baked row: the blade is dropped into the ore and
    fresh spice clods ride its cutting edge. The continuous motion comes from
    the live dust/spice emitters in Harvester._process, so the two poses never
    look like a slideshow.
    """
    p = []
    # ---------------------------------------------------------- running gear
    tracked_base(p, 2.02, 1.12, 0.30, M["ochre"], track_width=0.34, track_offset=0.60)
    for side in (-1.0, 1.0):
        y = side * 0.615
        # Enclosed armoured track skirt with a bolted lower rail.
        p.append(box((1.66, 0.18, 0.30), (-0.02, y, 0.405), M["ochre"], bevel=0.012))
        p.append(box((1.46, 0.045, 0.075), (-0.02, y + side * 0.105, 0.515),
                     M["steel"], bevel=0.003))
        p.append(box((1.80, 0.10, 0.15), (-0.02, y + side * 0.02, 0.215),
                     M["dark"], bevel=0.008))
        for i in range(6):
            p.append(box((0.17, 0.205, 0.115), (-0.74 + i * 0.285, y, 0.235),
                         M["gunmetal"], bevel=0.004))
        for i in range(6):
            p.append(bb.bolt((-0.66 + i * 0.30, y + side * 0.108, 0.44),
                             M["steel_light"], 0.012, 0.012, axis="Y"))
        p.append(box((1.30, 0.055, 0.15), (-0.02, y + side * 0.108, 0.355),
                     M["ochre_light"], rot=(side * math.radians(-12.0), 0.0, 0.0),
                     bevel=0.004))
        house_plate(p, (0.34, 0.035, 0.075), (0.30, y + side * 0.115, 0.425))
        # Hazard mud flap behind the last road wheel.
        p.append(box((0.13, 0.28, 0.21), (-0.86, y, 0.27), M["dark"], bevel=0.004))
        p.append(box((0.02, 0.23, 0.16), (-0.93, y, 0.27), M["yellow"], bevel=0.0))

    # ------------------------------------------------------------- main hull
    p.append(prism((1.34, 1.00, 0.28), (-0.10, 0.0, 0.58), M["ochre"],
                   chamfer=0.10, bevel=0.020))
    p.append(box((1.10, 0.90, 0.06), (-0.18, 0.0, 0.76), M["ochre_light"], bevel=0.006))
    p.append(box((0.34, 0.98, 0.14), (-0.74, 0.0, 0.73), M["ochre"],
                 rot=(0.0, math.radians(7.0), 0.0), bevel=0.008))
    # Raised engine deck with louvres under the stack.
    p.append(box((0.44, 0.72, 0.09), (-0.55, -0.02, 0.86), M["ochre_dark"], bevel=0.005))
    for i in range(4):
        p.append(box((0.03, 0.60, 0.025), (-0.70 + i * 0.085, -0.02, 0.912),
                     M["grill"], bevel=0.0))

    # ------------------------------------------------------------------- cab
    p.append(box((0.66, 0.94, 0.52), (0.30, 0.0, 0.86), M["ochre_light"], bevel=0.014))
    p.append(box((0.22, 0.80, 0.36), (0.62, 0.0, 0.92), M["glass"],
                 rot=(0.0, math.radians(-24.0), 0.0), bevel=0.006))
    p.append(box((0.62, 0.88, 0.06), (0.28, 0.0, 1.13), M["ochre"], bevel=0.006))
    p.append(box((0.18, 0.96, 0.05), (0.60, 0.0, 1.13), M["steel"],
                 rot=(0.0, math.radians(-12.0), 0.0), bevel=0.003))
    for side in (-1.0, 1.0):
        p.append(box((0.30, 0.025, 0.18), (0.34, side * 0.475, 0.98),
                     M["glass"], bevel=0.002))
        p.append(box((0.05, 0.05, 0.38), (0.02, side * 0.498, 0.88),
                     M["steel"], bevel=0.002))
        p.append(box((0.035, 0.10, 0.05), (0.00, side * 0.52, 1.04),
                     M["trim"], bevel=0.002))
        p.append(cyl(0.045, 0.035, (0.64, side * 0.28, 1.10), M["amber"],
                     axis="X", verts=10))
        # Hydraulic cab tilt ram tucked against the A-pillar.
        p.append(pipe((0.36, side * 0.485, 0.66), (0.50, side * 0.485, 1.02),
                      0.018, M["chrome"]))
    house_plate(p, (0.12, 0.46, 0.06), (0.28, 0.0, 1.16))
    house_plate(p, (0.30, 0.045, 0.10), (0.31, 0.0, 0.78))
    # Riveted cab cheek panels.
    for side in (-1.0, 1.0):
        for i in range(4):
            p.append(bb.bolt((0.10 + i * 0.15, side * 0.485, 0.72),
                             M["steel_light"], 0.010, 0.010, axis="Y"))

    # ------------------------------------------------------- single tall stack
    sx, sy = -0.94, -0.50
    p.append(box((0.24, 0.20, 0.12), (sx, sy, 0.84), M["steel"], bevel=0.006))
    p.append(cyl(0.075, 0.86, (sx, sy, 1.34), M["steel"], verts=16))
    for z in (1.10, 1.42, 1.68):
        p.append(cyl(0.092, 0.042, (sx, sy, z), M["rust"], verts=14, bevel=0.002))
    p.append(cyl(0.100, 0.055, (sx, sy, 1.79), M["dark"], verts=12))
    p.append(cyl(0.132, 0.04, (sx, sy, 1.83), M["rust"], verts=14))
    p.append(box((0.15, 0.10, 0.035), (sx + 0.02, sy, 1.855), M["dark"], bevel=0.0))
    p.append(pipe((sx, sy, 0.92), (sx - 0.22, sy, 0.66), 0.038, M["rust"]))

    # ------------------------------------------------------------ open hopper
    # The fill helper is authored around a bay centred at x=-0.48, z=0.73.
    # Walls rise to the same hazard top rail as before, now with sloped panels.
    p.append(box((0.98, 0.09, 0.34), (-0.48, -0.525, 0.91), M["ochre_light"], bevel=0.006))
    p.append(box((0.98, 0.09, 0.34), (-0.48, 0.525, 0.91), M["ochre_light"], bevel=0.006))
    p.append(box((0.09, 0.96, 0.34), (0.00, 0.0, 0.91), M["ochre"], bevel=0.006))
    p.append(box((0.09, 0.96, 0.34), (-0.96, 0.0, 0.91), M["ochre"], bevel=0.006))
    for x in (-0.94, -0.02):
        for y in (-0.50, 0.50):
            p.append(box((0.075, 0.075, 0.40), (x, y, 0.92), M["steel"], bevel=0.004))
    for x in (-0.78, -0.48, -0.18):
        for y in (-0.565, 0.565):
            p.append(box((0.06, 0.03, 0.31), (x, y, 0.92), M["steel"], bevel=0.003))
    for y in (-0.558, 0.558):
        p.append(box((1.02, 0.055, 0.05), (-0.48, y, 1.095), M["steel_light"], bevel=0.003))
        hazard_strip(p, (0.42, 0.03, 0.022), (-0.48, y * 0.99, 1.12))
    for x in (-0.955, -0.005):
        p.append(box((0.06, 1.01, 0.05), (x, 0.0, 1.095), M["steel_light"], bevel=0.003))
    # Hopper interior ribs and the rear ladder.
    for x in (-0.72, -0.36):
        p.append(box((0.045, 1.02, 0.30), (x, 0.0, 0.90), M["ochre_dark"], bevel=0.002))
    for side in (-1.0, 1.0):
        p.append(box((0.055, 0.05, 0.42), (-0.995, side * 0.32, 0.87),
                     M["gunmetal"], bevel=0.002))
    for i in range(5):
        p.append(box((0.04, 0.55, 0.035), (-0.975, 0.0, 0.68 + i * 0.09),
                     M["steel"], bevel=0.001))
    _harvester_fill(p, fill)

    # ------------------------------------------------ dozer scoop / moldboard
    blade_z = 0.42 if harvesting else 0.47
    tilt = math.radians(-24.0 if harvesting else -19.0)
    # Close-coupled blade: the moldboard sits just off the nose so the rig
    # reads as one machine instead of a blade on a long stick.
    bx = 1.00
    p.append(box((0.11, 1.30, 0.54), (bx, 0.0, blade_z), M["yellow"],
                 rot=(0.0, tilt, 0.0), bevel=0.010))
    # Heavy top spill lip and a bolted reinforcement spine.
    p.append(box((0.18, 1.34, 0.09), (bx - 0.07, 0.0, blade_z + 0.28),
                 M["ochre"], rot=(0.0, tilt, 0.0), bevel=0.005))
    p.append(box((0.15, 1.22, 0.06), (bx - 0.16, 0.0, blade_z - 0.11),
                 M["steel"], rot=(0.0, tilt, 0.0), bevel=0.003))
    for side in (-1.0, 1.0):
        p.append(box((0.32, 0.06, 0.48), (bx - 0.10, side * 0.665, blade_z),
                     M["ochre_light"], rot=(0.0, tilt, 0.0), bevel=0.004))
        p.append(box((0.10, 0.07, 0.32), (bx + 0.04, side * 0.68, blade_z - 0.03),
                     M["steel"], rot=(0.0, tilt, 0.0), bevel=0.002))
    # Replaceable cutting edge and seven hardened teeth.
    p.append(box((0.20, 1.32, 0.11), (bx + 0.11, 0.0, blade_z - 0.28),
                 M["steel_light"], rot=(0.0, tilt, 0.0), bevel=0.004))
    for i in range(7):
        y = -0.47 + i * 0.157
        tooth = bb.cone(0.052, 0.005, 0.15,
                        (bx + 0.20, y, blade_z - 0.30),
                        M["steel_light"], verts=6, bevel=0.002)
        tooth.rotation_euler.y = math.radians(90.0)
        tooth.rotation_euler.x = math.radians(-8.0)
        p.append(tooth)
    # Bold diagonal hazard chevrons across the blade face.
    for i in range(7):
        y = -0.45 + i * 0.15
        p.append(box((0.025, 0.075, 0.30), (bx + 0.062, y, blade_z + 0.02),
                     M["dark"], rot=(math.radians(36.0), tilt, 0.0), bevel=0.0))
    # Two heavy arms, hydraulic rams and pivot bosses tie the blade to the hull.
    for side in (-1.0, 1.0):
        p.append(box((0.34, 0.17, 0.17), (0.74, side * 0.40, blade_z + 0.06),
                     M["steel"], bevel=0.005))
        p.append(box((0.18, 0.18, 0.19), (0.64, side * 0.40, blade_z + 0.02),
                     M["ochre"], bevel=0.004))
        p.append(pipe((0.64, side * 0.42, blade_z + 0.12),
                      (0.84, side * 0.40, blade_z + 0.16), 0.046, M["chrome"]))
        p.append(cyl(0.060, 0.18, (0.79, side * 0.40, blade_z + 0.02),
                     M["gunmetal"], axis="Y", verts=12, bevel=0.003))
    # Fresh ore riding the blade in the harvest pose.
    if harvesting:
        for i in range(7):
            p.append(sphere(0.035 + 0.018 * (0.5 + 0.5 * math.sin(float(i) * 2.3)),
                            (bx + 0.10 + 0.05 * math.sin(float(i) * 1.7),
                             -0.48 + i * 0.16, blade_z + 0.20 + 0.03 * math.sin(float(i))),
                            M["spice_glow"] if i % 3 == 0 else M["spice"],
                            (1.1, 1.0, 0.7), segments=10, rings=5))

    # ------------------------------------------------------- hero detail pass
    # Blade face ribs and two outer teeth break up the big yellow moldboard so
    # it reads as a toothed dozer scoop from the RTS camera, not a flat plate.
    for y in (-0.36, 0.0, 0.36):
        p.append(box((0.045, 0.075, 0.44), (bx + 0.072, y, blade_z + 0.02),
                     M["ochre_light"], rot=(0.0, tilt, 0.0), bevel=0.003))
    for y in (-0.635, 0.635):
        p.append(box((0.28, 0.075, 0.44), (bx - 0.03, y, blade_z + 0.02),
                     M["ochre"], rot=(0.0, tilt, 0.0), bevel=0.004))
        tooth = bb.cone(0.046, 0.005, 0.14, (bx + 0.185, y, blade_z - 0.30),
                        M["steel_light"], verts=6, bevel=0.002)
        tooth.rotation_euler.y = math.radians(90.0)
        tooth.rotation_euler.x = math.radians(-8.0)
        p.append(tooth)
    # Heavy top-run grousers make the enclosed tracks read as tracks.
    for side in (-1.0, 1.0):
        y = side * 0.615
        for i in range(8):
            p.append(box((0.155, 0.050, 0.030), (-0.73 + i * 0.205,
                         y + side * 0.045, 0.558), M["gunmetal"], bevel=0.001))
        # Armoured headlight pod and brush guard on the front idler.
        p.append(box((0.10, 0.22, 0.10), (0.86, side * 0.34, 0.53),
                     M["steel"], bevel=0.003))
        p.append(cyl(0.045, 0.03, (0.92, side * 0.34, 0.53), M["amber"],
                     axis="X", verts=10))
    # -------------------------------------------------------- cab equipment
    # Roof beacon, rotating antenna and mirrors: tiny silhouettes that read as
    # a working industrial cab rather than a block with windows.
    p.append(cyl(0.050, 0.090, (0.40, 0.22, 1.215), M["amber"], verts=10, bevel=0.002))
    p.append(cyl(0.032, 0.030, (0.40, 0.22, 1.270), M["dark"], verts=10))
    p.append(pipe((0.16, -0.34, 1.16), (0.10, -0.40, 1.46), 0.008, M["steel_light"]))
    p.append(box((0.05, 0.24, 0.02), (0.34, 0.30, 1.19), M["yellow"], bevel=0.0))
    for side in (-1.0, 1.0):
        p.append(pipe((0.55, side * 0.50, 1.08), (0.63, side * 0.72, 1.17),
                      0.014, M["steel"]))
        p.append(box((0.045, 0.16, 0.10), (0.64, side * 0.735, 1.18),
                     M["glass"], bevel=0.002))
        # Cab steps and a chunky grab rail.
        p.append(box((0.20, 0.10, 0.035), (0.30, side * 0.53, 0.52),
                     M["steel"], bevel=0.002))
        p.append(box((0.20, 0.10, 0.035), (0.50, side * 0.53, 0.66),
                     M["steel"], bevel=0.002))
    # Front grille and bumper winch.
    p.append(box((0.035, 0.60, 0.19), (0.985, 0.0, 0.665), M["grill"], bevel=0.002))
    for i in range(5):
        p.append(box((0.018, 0.52, 0.022), (1.005, 0.0, 0.600 + i * 0.036),
                     M["dark"], bevel=0.0))
    p.append(cyl(0.065, 0.24, (-1.28, 0.0, 0.62), M["gunmetal"], axis="Y", verts=12, bevel=0.002))
    p.append(pipe((-1.22, 0.10, 0.60), (-1.32, 0.10, 0.42), 0.018, M["steel"]))
    # Side fuel drum and tool locker stay inside the track envelope.
    p.append(cyl(0.105, 0.42, (-0.36, -0.665, 0.68), M["ochre_dark"],
                 axis="X", verts=14, bevel=0.004))
    p.append(cyl(0.112, 0.035, (-0.36, -0.665, 0.68), M["steel"],
                 axis="X", verts=14, bevel=0.001))
    p.append(box((0.36, 0.11, 0.20), (-0.16, 0.665, 0.69), M["steel"], bevel=0.004))
    p.append(box((0.28, 0.02, 0.12), (-0.16, 0.722, 0.70), M["grill"], bevel=0.0))
    # Sloped hopper spill guards and ore-level markings.
    for side in (-1.0, 1.0):
        p.append(box((1.02, 0.045, 0.14), (-0.48, side * 0.585, 1.16),
                     M["ochre_light"], rot=(side * math.radians(26.0), 0.0, 0.0),
                     bevel=0.003))
        for i in range(4):
            p.append(box((0.10, 0.015, 0.035), (-0.86 + i * 0.22, side * 0.612, 0.94),
                         M["yellow"], bevel=0.0))
    # Rear bumper closes the silhouette and carries the tow shackles.
    p.append(box((0.24, 0.66, 0.14), (-1.18, 0.0, 0.42), M["steel"], bevel=0.005))
    for side in (-1.0, 1.0):
        p.append(box((0.12, 0.10, 0.10), (-1.27, side * 0.24, 0.42),
                     M["gunmetal"], bevel=0.003))
    # Rear placard, house flashes and a spare-tooth rack.
    p.append(box((0.22, 0.60, 0.06), (-1.02, 0.0, 0.98), M["yellow"], bevel=0.002))
    p.append(box((0.235, 0.11, 0.022), (-1.045, 0.0, 0.98), M["dark"], bevel=0.0))
    house_plate(p, (0.35, 0.50, 0.045), (-1.035, 0.0, 1.10))
    house_plate(p, (0.22, 0.045, 0.09), (0.60, 0.0, 1.14))
    return group(p, 0.0)


def build_mcv():
    """Mobile Construction Vehicle: a wheeled base rig with a folded crane,
    armoured deck plates and enough industrial clutter to read as a rolling
    Construction Yard rather than another tank."""
    p = []
    # Huge service chassis on eight heavy wheels. The track guards sit low so
    # the folded base equipment owns the silhouette.
    for side in (-1.0, 1.0):
        p.append(box((2.30, 0.26, 0.20), (0.0, side * 0.66, 0.34), M["gunmetal"], bevel=0.010))
        for x in (-0.82, -0.28, 0.28, 0.82):
            p.append(cyl(0.255, 0.20, (x, side * 0.68, 0.255), M["rubber"],
                         axis="Y", verts=20, bevel=0.006))
            p.append(cyl(0.135, 0.215, (x, side * 0.68, 0.255), M["steel_light"],
                         axis="Y", verts=16, bevel=0.004))
            p.append(cyl(0.055, 0.225, (x, side * 0.68, 0.255), M["dark"],
                         axis="Y", verts=12, bevel=0.002))
        p.append(box((2.20, 0.08, 0.18), (0.0, side * 0.80, 0.42), M["sand_steel_light"], bevel=0.006))
        house_plate(p, (1.15, 0.035, 0.065), (0.0, side * 0.845, 0.45))
    p.append(prism((2.12, 1.34, 0.40), (0.0, 0.0, 0.58), M["sand_steel"], chamfer=0.12, bevel=0.022))
    p.append(box((1.74, 1.22, 0.16), (-0.10, 0.0, 0.84), M["sand_steel_light"], bevel=0.012))
    # Forward control cab with a broad armoured glass band.
    p.append(box((0.62, 1.10, 0.52), (0.78, 0.0, 0.86), M["armor"], bevel=0.014))
    p.append(box((0.24, 0.92, 0.35), (1.03, 0.0, 0.95), M["sand_steel_light"],
                 rot=(0.0, math.radians(-14.0), 0.0), bevel=0.010))
    p.append(box((0.16, 0.72, 0.17), (1.12, 0.0, 0.96), M["glass"],
                 rot=(0.0, math.radians(-14.0), 0.0), bevel=0.006))
    p.append(box((0.20, 1.16, 0.14), (1.10, 0.0, 0.66), M["gunmetal"], bevel=0.006))
    p.append(box((0.34, 1.14, 0.08), (0.72, 0.0, 1.14), M["steel"], bevel=0.004))
    # Rear engine deck and the folded lattice crane beams.
    p.append(box((0.58, 1.20, 0.36), (-0.78, 0.0, 0.88), M["gunmetal"], bevel=0.010))
    for i in range(4):
        p.append(box((0.045, 0.88, 0.035), (-0.88 - i * 0.055, 0.0, 0.76 + i * 0.020),
                     M["dark"], bevel=0.001))
    p.append(box((0.18, 0.18, 0.58), (-0.42, -0.38, 1.26), M["steel"], bevel=0.008))
    p.append(box((0.18, 0.18, 0.58), (-0.42, 0.38, 1.26), M["steel"], bevel=0.008))
    p.append(cyl(0.12, 0.22, (-0.42, 0.0, 1.46), M["steel_light"], axis="Y", verts=16, bevel=0.004))
    for side in (-1.0, 1.0):
        p.append(box((1.76, 0.14, 0.14), (0.18, side * 0.38, 1.38), M["yellow"], bevel=0.006))
        p.append(box((1.58, 0.08, 0.05), (0.18, side * 0.38, 1.46), M["dark"], bevel=0.002))
        for i in range(4):
            p.append(box((0.12, 0.18, 0.18), (-0.53 + i * 0.40, side * 0.38, 1.38),
                         M["gunmetal"], bevel=0.004))
        p.append(box((0.44, 0.16, 0.16), (0.88, side * 0.38, 1.40), M["steel_light"], bevel=0.005))
        p.append(box((0.34, 0.12, 0.10), (0.64, side * 0.38, 1.52), M["trim"], bevel=0.003))
    # Folded boom nose, hook block and hoist cable.
    p.append(box((0.16, 0.72, 0.20), (1.00, 0.0, 1.44), M["steel"], bevel=0.006))
    p.append(cyl(0.10, 0.10, (1.08, 0.0, 1.32), M["gunmetal"], axis="Y", verts=14))
    p.append(box((0.10, 0.10, 0.36), (1.08, 0.0, 1.12), M["dark"], bevel=0.002))
    p.append(box((0.18, 0.18, 0.16), (1.08, 0.0, 0.95), M["yellow"], bevel=0.004))
    # Side armour, fuel drums, shovel and house flashes.
    for side in (-1.0, 1.0):
        p.append(box((1.60, 0.10, 0.24), (-0.06, side * 0.70, 0.68), M["sand_steel_light"], bevel=0.006))
        house_plate(p, (1.16, 0.035, 0.070), (-0.06, side * 0.755, 0.72))
        p.append(cyl(0.13, 0.48, (-1.08, side * 0.48, 0.62), M["rust"], axis="X", verts=16))
        p.append(cyl(0.15, 0.05, (-1.32, side * 0.48, 0.62), M["dark"], axis="X", verts=14))
        p.append(box((0.12, 0.18, 0.30), (-1.20, side * 0.20, 0.45), M["steel"], bevel=0.004))
    p.append(box((0.34, 0.94, 0.12), (1.22, 0.0, 0.38), M["steel_light"],
                 rot=(0.0, 0.0, math.radians(-20.0)), bevel=0.005))
    p.append(box((0.24, 0.80, 0.07), (1.30, 0.0, 0.30), M["yellow"],
                 rot=(0.0, 0.0, math.radians(-20.0)), bevel=0.002))
    house_plate(p, (0.28, 0.62, 0.045), (1.14, 0.0, 1.06))
    # Twin exhaust stacks tucked behind the cab.
    for y in (-0.34, 0.34):
        p.append(cyl(0.055, 0.48, (0.66, y, 1.34), M["chrome"], verts=12))
        p.append(cyl(0.070, 0.08, (0.66, y, 1.58), M["dark"], verts=10))
        p.append(box((0.16, 0.14, 0.08), (0.66, y, 1.10), M["steel"], bevel=0.004))
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


def build_frigate():
    """CHOAM heavy frigate: a broad armoured cargo hull with four lift nacelles,
    a forward flight bridge and bright engine bells. It is deliberately much
    larger than a Carryall and reads as a spacecraft, not a ground vehicle."""
    p = []
    # Central cargo spine and armoured belly.
    p.append(prism((3.80, 1.42, 0.58), (0.0, 0.0, 1.00), M["olive"],
                   chamfer=0.18, bevel=0.030))
    p.append(box((2.90, 1.62, 0.22), (-0.10, 0.0, 0.73), M["gunmetal"], bevel=0.014))
    p.append(box((2.56, 1.30, 0.20), (-0.12, 0.0, 0.62), M["dark"], bevel=0.010))
    for x in (-1.02, -0.42, 0.40, 0.98):
        p.append(box((0.13, 1.48, 0.09), (x, 0.0, 0.585), M["steel"], bevel=0.004))
    # Forward prow and bridge canopy.
    p.append(box((0.72, 1.16, 0.46), (1.70, 0.0, 1.02), M["olive_light"],
                 rot=(0.0, math.radians(16.0), 0.0), bevel=0.018))
    p.append(box((0.36, 0.92, 0.25), (2.03, 0.0, 1.12), M["glass"],
                 rot=(0.0, math.radians(18.0), 0.0), bevel=0.008))
    p.append(box((0.26, 1.10, 0.11), (2.12, 0.0, 0.89), M["steel"], bevel=0.006))
    p.append(box((1.06, 1.08, 0.18), (1.09, 0.0, 1.34), M["olive_light"], bevel=0.010))
    p.append(cyl(0.14, 0.30, (1.60, 0.0, 1.35), M["cyan"], axis="X", verts=16))
    # Swept cargo wings with armoured leading edges and lift pods.
    for side in (-1.0, 1.0):
        p.append(box((2.20, 1.26, 0.20), (-0.10, side * 1.12, 1.02), M["olive_light"],
                     rot=(0.0, 0.0, side * math.radians(7.0)), bevel=0.014))
        p.append(box((1.64, 0.14, 0.10), (-0.14, side * 1.69, 1.05), M["trim"],
                     rot=(0.0, 0.0, side * math.radians(7.0)), bevel=0.004))
        p.append(box((0.52, 0.30, 0.38), (0.92, side * 0.97, 1.01), M["steel"], bevel=0.008))
        for ex in (-0.96, 0.28):
            p.append(cyl(0.24, 0.78, (ex, side * 1.28, 0.90), M["steel_light"],
                         axis="X", verts=18, bevel=0.006))
            p.append(cyl(0.30, 0.16, (ex - 0.39, side * 1.28, 0.90), M["gunmetal"],
                         axis="X", verts=18, bevel=0.004))
            p.append(cyl(0.22, 0.05, (ex - 0.49, side * 1.28, 0.90), M["cyan"],
                         axis="X", verts=18, bevel=0.002))
            p.append(cyl(0.11, 0.06, (ex - 0.52, side * 1.28, 0.90), M["amber"],
                         axis="X", verts=12, bevel=0.001))
            p.append(box((0.52, 0.11, 0.10), (ex + 0.20, side * 1.28, 1.14), M["gunmetal"], bevel=0.003))
        p.append(box((0.72, 0.20, 0.14), (-1.58, side * 1.10, 1.06), M["steel"], bevel=0.006))
    # Four cargo clamps and the CHOAM/house identification plates.
    for side in (-1.0, 1.0):
        p.append(box((0.18, 0.16, 0.50), (0.86, side * 0.60, 0.59), M["steel_light"], bevel=0.006))
        p.append(box((0.18, 0.16, 0.50), (-0.92, side * 0.60, 0.59), M["steel_light"], bevel=0.006))
        p.append(box((1.24, 0.045, 0.15), (0.0, side * 0.735, 1.18), M["trim"], bevel=0.003))
        p.append(box((0.38, 0.36, 0.06), (1.36, side * 0.40, 1.20), M["yellow"], bevel=0.003))
        p.append(box((0.16, 0.16, 0.16), (-1.82, side * 0.40, 0.92), M["gunmetal"], bevel=0.004))
    p.append(box((0.86, 0.08, 0.30), (-2.02, 0.0, 1.01), M["steel"], bevel=0.005))
    p.append(box((0.06, 0.60, 0.38), (-2.08, 0.0, 1.03), M["trim"], bevel=0.003))
    p.append(box((1.32, 0.74, 0.12), (-0.22, 0.0, 1.35), M["steel_light"], bevel=0.008))
    p.append(box((0.74, 0.46, 0.08), (-0.22, 0.0, 1.42), M["dark"], bevel=0.004))
    return group(p, 0.0)


def build_ornithopter():
    """Atreides ornithopter: narrow armoured fuselage, one broad continuous
    swept wing per side with a flush articulated aileron, plus under-wing
    missile racks. Keeping each wing as a single silhouette prevents the
    panels from reading as detached plates at sprite scale."""
    p = []
    p.append(prism((2.18, 0.56, 0.38), (0.0, 0.0, 0.78), M["olive"],
                   chamfer=0.10, bevel=0.022))
    p.append(box((0.52, 0.62, 0.34), (1.05, 0.0, 0.80), M["olive_light"], bevel=0.012))
    p.append(box((0.28, 0.50, 0.20), (1.30, 0.0, 0.85), M["glass"],
                 rot=(0.0, math.radians(-12.0), 0.0), bevel=0.006))
    p.append(box((0.90, 0.10, 0.12), (0.18, 0.0, 1.02), M["trim"], bevel=0.003))
    p.append(cyl(0.12, 0.18, (1.45, 0.0, 0.83), M["gunmetal"], axis="X", verts=14))
    p.append(cyl(0.07, 0.05, (1.55, 0.0, 0.83), M["amber"], axis="X", verts=12))
    for side in (-1.0, 1.0):
        # Root chord is buried inside the hull; the tapered swept planform
        # grows directly out of it with no root stalk or separate panels.
        p.append(swept_wing(1.28, 0.56, 1.78, (0.0, side * 0.22, 0.93),
                            M["olive"], side=side, sweep=0.46))
    # One-piece tail surfaces keep the rear silhouette clean at sprite scale.
    p.append(box((0.34, 0.96, 0.065), (-1.10, 0.0, 0.86), M["olive"],
                 rot=(0.0, 0.0, math.radians(0.0)), bevel=0.004))
    p.append(box((0.52, 0.085, 0.34), (-1.00, 0.0, 1.03), M["olive_light"],
                 rot=(0.0, 0.0, math.radians(0.0)), bevel=0.004))
    for y in (-0.18, 0.18):
        p.append(cyl(0.09, 0.32, (-1.22, y, 0.80), M["steel"], axis="X", verts=14))
        p.append(cyl(0.115, 0.06, (-1.40, y, 0.80), M["cyan"], axis="X", verts=14))
    p.append(box((0.38, 0.12, 0.12), (-0.78, 0.0, 1.02), M["trim"], bevel=0.003))
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


WORM_DIR = ROOT / "assets" / "sprites" / "sandworm"


def worm_spike(a, b, radius, mat, verts=7):
    """Tapered bone cone between two points, used for the ringed maw teeth."""
    a, b = Vector(a), Vector(b)
    d = b - a
    obj = bb.cone(radius, 0.004, max(d.length, 0.008), (a + b) * 0.5, mat,
                  verts=verts, bevel=0.002)
    obj.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    return obj


def worm_basis(direction):
    d = Vector(direction).normalized()
    up = Vector((0.0, 0.0, 1.0))
    if abs(d.dot(up)) > 0.94:
        up = Vector((0.0, 1.0, 0.0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()
    return d, u, v


def smooth01(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def worm_collar(parts, radius, phase=0.0, churn=1.0):
    """A churned eruption crater: low sand waves, radial spill lobes, dark
    clods and a central mound that hides the body's buried root."""
    center_y = 1.45
    parts.append(sphere(1.0, (0.0, center_y + 0.12, 0.16), M["worm_shadow_sand"],
                        (radius * 0.64, radius * 0.42, 0.20), segments=26, rings=10))
    parts.append(sphere(1.0, (0.0, center_y, 0.015), M["worm_shadow_sand"],
                        (radius * 0.94, radius * 0.62, 0.055), segments=30, rings=12))
    parts.append(sphere(1.0, (0.0, center_y - 0.08, 0.035), M["worm_sand"],
                        (radius * 0.86, radius * 0.58, 0.13), segments=30, rings=12))
    parts.append(sphere(1.0, (-0.06, center_y - 0.24, 0.105), M["worm_sand"],
                        (radius * 0.62, radius * 0.38, 0.13), segments=26, rings=10))
    parts.append(sphere(1.0, (-0.10, center_y - 0.30, 0.150), M["worm_sand_light"],
                        (radius * 0.30, radius * 0.20, 0.09), segments=22, rings=9))
    parts.append(sphere(1.0, (-0.12, center_y - 0.44, 0.20), M["worm_sand"],
                        (radius * 0.46, radius * 0.30, 0.20), segments=24, rings=10))
    parts.append(sphere(1.0, (-0.18, center_y - 0.52, 0.25), M["worm_sand"],
                        (radius * 0.25, radius * 0.18, 0.11), segments=18, rings=8))
    for i in range(12):
        a = math.tau * float(i) / 12.0 + phase * 0.4
        rr = radius * (0.48 + 0.10 * math.sin(float(i) * 2.1 + phase))
        parts.append(sphere(1.0,
                            (math.cos(a) * rr, center_y + math.sin(a) * rr * 0.66, 0.015),
                            M["worm_sand"],
                            (radius * 0.46, radius * 0.31, 0.055 + 0.025 * math.sin(a * 2.0 + phase)),
                            segments=20, rings=8))
    for i in range(14):
        a = math.tau * i / 14.0 + phase + 0.3
        rr = radius * (0.92 + 0.26 * math.sin(float(i) * 1.3 + phase))
        tongue = sphere(radius * 0.11,
                        (math.cos(a) * rr, center_y + math.sin(a) * rr * 0.70, 0.025),
                        M["worm_sand"], (1.35, 0.72, 0.22), segments=14, rings=7)
        tongue.rotation_euler = (0.0, 0.0, a)
        parts.append(sphere(radius * 0.08, (math.cos(a) * rr * 1.14,
                                           center_y + math.sin(a) * rr * 0.80, 0.03),
                            M["worm_shadow_sand"], (1.4, 0.8, 0.16), segments=12, rings=6))
    # Dark, wind-eaten clods thrown clear of the crater. They sit at different
    # heights so the first breach frames read as active churn, not a flat mat.
    clods = int(8 + 12 * churn)
    for i in range(clods):
        a = math.tau * float(i) / float(max(clods, 1)) + phase * 0.7
        rr = radius * (0.72 + 0.62 * ((i * 7) % 9) / 8.0)
        z = 0.05 + (0.62 * churn) * (0.30 + 0.70 * ((i * 5) % 11) / 10.0)
        size = 0.045 + 0.060 * ((i * 3) % 7) / 6.0
        clod = sphere(size, (math.cos(a) * rr, center_y + math.sin(a) * rr * 0.62, z),
                      M["worm_rock"] if i % 4 else M["worm_sand"],
                      (1.2 + 0.4 * math.sin(i), 0.8, 0.7), segments=10, rings=5)
        clod.rotation_euler = (0.0, 0.0, a + 0.5 * math.sin(i))
        parts.append(clod)


def worm_throat(center, d, u, v, mat, scale=1.0):
    """Open, tapering throat funnel that narrows into a dark reddish-umber
    gullet. Keeping the walls open is what lets the concentric tooth rings
    silhouette against the depths instead of reading as a flat disc."""
    bm = bmesh.new()
    rings = []
    for dist, rad in ((0.0, 1.0), (0.16, 0.86), (0.36, 0.66),
                      (0.58, 0.42), (0.82, 0.16)):
        ring = []
        for k in range(32):
            a = math.tau * float(k) / 32.0
            p = (center - d * (dist * scale)
                 + (u * math.cos(a) + v * math.sin(a)) * (rad * scale))
            ring.append(bm.verts.new(p))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for k in range(32):
            k2 = (k + 1) % 32
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("WormThroat")
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new("WormThroat", mesh)
    bpy.context.scene.collection.objects.link(obj)
    return bb.finish(obj, mat, 0.0, True)


def worm_plate_ring(parts, center, tangent, radius, index, phase):
    """Overlapping scales wrapped around the local body axis. Each plate is a
    rounded slab whose long edge points around the circumference, so the body
    reads as one plated organism rather than a stack of smooth beads."""
    up = Vector((0.0, 0.0, 1.0))
    u = tangent.cross(up)
    if u.length < 0.08:
        u = tangent.cross(Vector((0.0, 1.0, 0.0)))
    u.normalize()
    v = tangent.cross(u).normalized()
    for k in range(5):
        a = math.tau * float(k) / 5.0 + phase * 0.35 + float(index) * 0.17
        radial = (u * math.cos(a) + v * math.sin(a)).normalized()
        around = (-u * math.sin(a) + v * math.cos(a)).normalized()
        pos = center + radial * (radius * 0.99) + tangent * (radius * 0.035)
        mat = M["worm_plate"] if (k + index) % 4 else M["worm_plate_dark"]
        if (k + index) % 7 == 0:
            mat = M["worm_sand"]
        plate = box((radius * 1.34, radius * 0.70, 0.076), pos, mat, bevel=0.007)
        plate.matrix_world = Matrix((
            (around.x, tangent.x, radial.x),
            (around.y, tangent.y, radial.y),
            (around.z, tangent.z, radial.z),
        )).to_4x4()
        plate.matrix_world.translation = pos
        parts.append(plate)
        if (k + index) % 5 == 0:
            crust = sphere(radius * 0.20, pos + radial * (radius * 0.045),
                           M["worm_sand"], (1.55, 0.85, 0.34), segments=12, rings=6)
            crust.rotation_euler = (0.0, 0.0, a)
            parts.append(crust)
    # A staggered second row of smaller scutes fills the seams between the
    # primary plates. From the breach camera this reads as overlapping, layered
    # chitin rather than a segmented tube with five broad panels.
    for k in range(4):
        a = math.tau * (float(k) + 0.5) / 4.0 + phase * 0.23 + float(index) * 0.31
        radial = (u * math.cos(a) + v * math.sin(a)).normalized()
        around = (-u * math.sin(a) + v * math.cos(a)).normalized()
        pos = center + radial * (radius * 0.985) + tangent * (radius * 0.30)
        mat = M["worm_plate_dark"] if (k + index) % 2 else M["worm_sand"]
        scute = box((radius * 0.74, radius * 0.44, 0.055), pos, mat, bevel=0.004)
        scute.matrix_world = Matrix((
            (around.x, tangent.x, radial.x),
            (around.y, tangent.y, radial.y),
            (around.z, tangent.z, radial.z),
        )).to_4x4()
        scute.matrix_world.translation = pos
        parts.append(scute)


def build_sandworm(pose):
    """Shai-Hulud: an upright, arching biological colossus.

    Sixteen tapered body segments climb from a churned crater in a strong
    vertical arc. Every segment carries a dark annular joint and a ring of
    overlapping weathered armour plates, with sand crust on the windward side.
    The head is a huge circular maw with folded umber lips, a dark gullet and
    concentric rings of pale inward-curving crystal teeth. `rise`, `rear`,
    `jaw`, `lunge` and `churn` drive the cinematic breach, bite and burrow.
    """
    rise = max(0.08, float(pose.get("rise", 2.8)))
    jaw = max(0.0, min(1.0, float(pose.get("jaw", 0.8))))
    phase = float(pose.get("phase", 0.0))
    lunge = float(pose.get("lunge", 0.0))
    rear = float(pose.get("rear", 0.0))
    churn = max(0.0, min(1.0, float(pose.get("churn", 0.45))))
    collar = float(pose.get("collar", 1.0))
    body = []
    count = 18
    points = []
    radii = []
    for i in range(count):
        t = float(i) / float(count - 1)
        back = smooth01((t - 0.45) / 0.55)
        forward = smooth01((t - 0.50) / 0.50)
        y = (1.95 - 2.35 * t + 0.48 * math.sin(math.pi * t)
             + rear * 0.58 * back - lunge * 1.15 * forward)
        z = (0.06 + (0.52 + rise * 1.10) * pow(t, 1.72)
             + rear * 0.16 * back - lunge * 0.22 * forward)
        x = (0.68 * math.sin(math.pi * t * 1.02)
             + 0.10 * math.sin(t * 3.7 + phase * 0.8) * smooth01(t * 1.5))
        # A heavy, muscle-thick trunk; the maw should crown a body with real mass
        # rather than a thin tail ending in a giant saw ring.
        radius = 0.84 * (1.0 - 0.06 * t) * (1.0 + 0.045 * math.sin(t * 7.2 + phase))
        points.append(Vector((x, y, z)))
        radii.append(radius)

    tangents = []
    for i in range(count):
        if i == 0:
            tangent = points[1] - points[0]
        elif i == count - 1:
            tangent = points[-1] - points[-2]
        else:
            tangent = points[i + 1] - points[i - 1]
        tangents.append(tangent.normalized())

    worm_collar(body, max(0.95, 1.06 * collar), phase, churn)
    for i in range(count):
        center = points[i]
        tangent = tangents[i]
        radius = radii[i]
        body.append(sphere(radius, center, M["worm_hide"], (1.0, 1.06, 0.98),
                           segments=24, rings=12))
        if i % 2 == 0 or i == count - 1:
            joint = bb.torus(radius * 1.01, 0.050, center - tangent * (radius * 0.16),
                             M["worm_plate_dark"], axis="Z", segments=24)
            joint.rotation_euler = tangent.to_track_quat("Z", "Y").to_euler()
            body.append(joint)
        worm_plate_ring(body, center, tangent, radius, i, phase)
        # Dry sand gathers on the camera-facing flank of every third segment.
        if i % 3 == 1 and i > 1:
            up = Vector((0.0, 0.0, 1.0))
            u = tangent.cross(up)
            if u.length < 0.08:
                u = tangent.cross(Vector((0.0, 1.0, 0.0)))
            u.normalize()
            v = tangent.cross(u).normalized()
            a = -1.65 + 0.35 * math.sin(float(i) * 1.7 + phase)
            radial = u * math.cos(a) + v * math.sin(a)
            body.append(sphere(radius * 0.34, center + radial * (radius * 0.96),
                               M["worm_sand"], (1.55, 1.05, 0.36), segments=14, rings=7))

    head = points[-1]
    head_radius = radii[-1]
    # The maw faces the south bake camera and tips upward as the worm rears
    # back; at the snap it drives forward and down with the lunge.
    d, u, v = worm_basis(Vector((0.30, -0.74 - 0.04 * lunge,
                                 0.60 + 0.10 * rear - 0.12 * lunge)))
    head_scale = max(0.10, smooth01((rise - 0.05) / 1.30))
    gape = (0.62 + 0.64 * jaw) * head_scale
    center = head + d * ((0.31 + 0.12 * jaw) * head_scale)
    neck = bb.torus(head_radius * 1.02, 0.17, head + d * 0.02,
                    M["worm_hide"], axis="Z", segments=30)
    neck.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    body.append(neck)
    cuff = bb.torus(gape * 0.94, 0.155, center - d * 0.10,
                    M["worm_plate_dark"], axis="Z", segments=34)
    cuff.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    body.append(cuff)
    # Folded lip flesh sits outside the hard tooth ring.
    for ring in range(11):
        a = math.tau * float(ring) / 11.0 + 0.22
        radial = u * math.cos(a) + v * math.sin(a)
        fold = sphere(0.145 * gape, center + radial * (gape + 0.035) - d * 0.025,
                      M["worm_flesh"], (1.7, 0.8, 0.9), segments=14, rings=7)
        fold.rotation_euler = (0.0, 0.0, a)
        body.append(fold)
    lip = bb.torus(gape, 0.145, center + d * 0.015,
                   M["worm_flesh"], axis="Z", segments=40)
    lip.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    body.append(lip)
    if jaw < 0.18:
        # A clamped sphincter of lip flesh seals the maw at the end of the snap
        # instead of leaving a small open ring with teeth pointing into it.
        cap = sphere(gape * 0.90, center - d * 0.015, M["worm_flesh"],
                     (1.0, 1.0, 0.34), segments=24, rings=10)
        cap.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
        body.append(cap)
    # Open throat, then a nearly black umber gullet deep behind the teeth.
    body.append(worm_throat(center, d, u, v, M["worm_gum"], scale=gape * 1.04))
    body.append(sphere(gape * 0.58, center - d * (gape * 0.94),
                       M["worm_glow_deep"], (1.0, 0.82, 0.82), segments=20, rings=10))
    # Heavy rim scutes around the maw and a ring of sensory pits.
    for k in range(16):
        a = math.tau * float(k) / 16.0 + 0.12
        radial = u * math.cos(a) + v * math.sin(a)
        pos = center + radial * (gape * 1.13) - d * 0.02
        knob = sphere(gape * 0.105, pos,
                      M["worm_plate"] if k % 3 else M["worm_sand"],
                      (1.5, 0.9, 0.72), segments=12, rings=6)
        knob.rotation_euler = (0.0, 0.0, a)
        body.append(knob)
    for k in range(12):
        a = math.tau * float(k) / 12.0 + 0.4
        radial = u * math.cos(a) + v * math.sin(a)
        body.append(sphere(gape * 0.055, center + radial * (gape * 1.26) - d * 0.12,
                           M["worm_plate_dark"], (1.2, 0.9, 0.6), segments=10, rings=5))
    # Three concentric tooth rings. The outer fangs are long and curve deeply
    # inward; the inner rings shorten as they descend toward the dark gullet.
    ring_specs = (
        (28, 0.96, 0.58, 0.16, 0.098, 0.050),
        (18, 0.66, 0.36, 0.10, 0.074, 0.040),
        (11, 0.37, 0.20, 0.055, 0.054, 0.032),
    )
    # Six oversized crown fangs sit proud of the concentric rings and give the
    # open maw an unmistakable Shai-Hulud silhouette at RTS distance.
    for k in range(6):
        a = math.tau * float(k) / 6.0 + 0.11
        radial = u * math.cos(a) + v * math.sin(a)
        base = center + d * 0.02 + radial * (gape * 1.02)
        mid = center - d * 0.22 + radial * (gape * 0.66)
        tip = center - d * 0.44 + radial * (gape * 0.30)
        worm_spike(base, mid, 0.125, M["worm_bone"], 7)
        worm_spike(mid, tip, 0.060, M["worm_bone"], 6)
    for count_k, base_r, mid_r, tip_r, base_thick, tip_thick in ring_specs:
        for k in range(count_k):
            a = math.tau * float(k) / float(count_k) + (0.06 if count_k == 28 else 0.18)
            radial = u * math.cos(a) + v * math.sin(a)
            wiggle = 0.045 * math.sin(float(k) * 2.7)
            tooth_scale = 0.78 + 0.34 * abs(math.sin(float(k) * 1.7))
            base = center + d * 0.055 + radial * (gape * base_r)
            mid = center - d * 0.10 + radial * (gape * (mid_r + wiggle))
            tip = center - d * 0.30 + radial * (gape * (tip_r + wiggle * 0.5))
            worm_spike(base, mid, base_thick * tooth_scale, M["worm_bone"], 6)
            worm_spike(mid, tip, tip_thick * tooth_scale, M["worm_bone"], 5)
    return group(body, 0.0)


def dune_ridge(length, width, height, phase, mat, segments=48, crest_shift=0.0):
    """Pointed, crested sand ridge built as a proper mesh.

    Overlapping spheres gave a capsule silhouette with no readable crest. This
    cross-section (flat flanks, two shoulders and a sharp crest) throws a clear
    light/shadow split and tapers to points at both ends."""
    bm = bmesh.new()
    rows = []
    for i in range(segments + 1):
        t = float(i) / float(segments)
        x = (t - 0.5) * 2.0 * length
        taper = max(0.015, math.sin(math.pi * t) ** 0.72)
        cy = 0.17 * math.sin(t * 3.6 + phase) + crest_shift
        half = width * taper * (1.0 + 0.09 * math.sin(t * 10.0 + phase * 1.3))
        h = height * taper * (0.85 + 0.15 * math.sin(t * 4.2 + phase))
        rows.append((
            bm.verts.new((x, cy - half, 0.012)),
            bm.verts.new((x, cy - half * 0.55, h * 0.60)),
            bm.verts.new((x, cy, h)),
            bm.verts.new((x, cy + half * 0.55, h * 0.58)),
            bm.verts.new((x, cy + half, 0.012)),
        ))
    for i in range(segments):
        a, b = rows[i], rows[i + 1]
        for k in range(4):
            bm.faces.new((a[k], b[k], b[k + 1], a[k + 1]))
    bm.faces.new(tuple(rows[0]))
    bm.faces.new(tuple(reversed(rows[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("DuneRidge")
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new("DuneRidge", mesh)
    bpy.context.scene.collection.objects.link(obj)
    return bb.finish(obj, mat, 0.012, False)


def build_sandworm_prowl(frame):
    """Top-down wormsign: one continuous sinuous dune, a bright windward crest,
    a shadowed slip face, buried armour plates and sand thrown clear of the
    travelling bulge. Building it from overlapping spheres left visible egg
    ends at the outline, so the body is a single stretched profile instead."""
    p = []
    phase = float(frame) / 8.0 * math.tau
    sway = 0.11 * math.sin(phase)
    # Pointed windward crest: a real crested dune, not a flattened capsule.
    p.append(dune_ridge(2.66, 1.10, 0.44, phase, M["worm_sand"], segments=52,
                        crest_shift=sway))
    # Lower lee ridge overlapping the south flank: the slip face under the crest.
    p.append(dune_ridge(2.42, 0.52, 0.20, phase + 1.9, M["worm_shadow_sand"],
                        segments=44, crest_shift=sway + 0.44))
    # Bright sand shoulder just under the crest line.
    p.append(dune_ridge(2.35, 0.34, 0.26, phase + 0.7, M["worm_sand_light"],
                        segments=44, crest_shift=sway - 0.24))
    # A second, tighter crest catches the high sun and keeps the ridge from
    # reading as a single flat pancake from the top-down camera.
    p.append(dune_ridge(2.05, 0.20, 0.58, phase + 1.2, M["worm_sand"],
                        segments=40, crest_shift=sway - 0.10))
    # Loose slip-face sand tongues sliding off the south side.
    for i in range(9):
        t = -0.86 + 1.72 * float(i) / 8.0
        x = t * 2.30
        tongue = sphere(0.16 + 0.05 * math.sin(float(i) * 1.7),
                        (x, sway + 0.62 + 0.05 * math.sin(phase + t * 2.0), 0.02),
                        M["worm_sand_light"], (1.9, 0.55, 0.16), segments=14, rings=7)
        tongue.rotation_euler = (0.0, 0.0, 0.12 * math.sin(float(i) * 2.1))
        p.append(sphere(0.13, (x + 0.12, sway + 0.74, 0.015), M["worm_shadow_sand"],
                        (1.6, 0.45, 0.10), segments=12, rings=6))
    # Broken segmented back breaking the crest: larger, overlapping plates with
    # sand caps make the ridge read as a buried worm, not a smooth dune.
    for i in range(10):
        t = -0.78 + 1.56 * float(i) / 9.0
        x = t * 2.16
        taper = max(0.10, math.sin(math.pi * (t * 0.5 + 0.5)) ** 0.72)
        crest = 0.44 * taper * (0.85 + 0.15 * math.sin((t * 0.5 + 0.5) * 4.2 + phase))
        y = sway + 0.17 * math.sin((t * 0.5 + 0.5) * 3.6 + phase)
        tilt = 0.18 * math.sin(phase + float(i) * 1.4)
        arc = sphere(0.32, (x, y, crest - 0.012), M["worm_plate"],
                     (1.24, 0.31, 0.24), segments=16, rings=8)
        arc.rotation_euler = (0.0, 0.0, tilt)
        p.append(arc)
        p.append(sphere(0.11, (x + 0.06, y + 0.16, crest + 0.025), M["worm_sand"],
                        (1.8, 0.9, 0.5), segments=12, rings=6))
    # A broad dark head bulge just under the leading crest, topped with a sand
    # cap. At gameplay zoom this is the moment the ridge becomes a worm.
    p.append(sphere(0.44, (2.18, sway + 0.06, 0.12), M["worm_hide"],
                    (1.2, 0.92, 0.48), segments=18, rings=9))
    p.append(sphere(0.30, (2.08, sway - 0.05, 0.30), M["worm_sand_light"],
                    (1.25, 0.72, 0.40), segments=16, rings=8))
    # Sand thrown from the flanks by the travelling bulge.
    for i in range(22):
        t = -0.92 + 1.84 * float(i) / 21.0
        x = t * 2.4
        for side in (-1.0, 1.0):
            a = phase * 0.8 + float(i) * 1.9
            p.append(sphere(0.048 + 0.020 * math.sin(float(i)),
                            (x + math.cos(a) * 0.26,
                             sway + side * (0.92 + 0.16 * math.sin(a)), 0.10),
                            M["worm_sand_light"], (1.7, 1.05, 0.65), segments=10, rings=5))
            p.append(sphere(0.038, (x + math.cos(a * 1.7) * 0.34,
                                    sway + side * (1.04 + 0.10 * math.cos(a)), 0.16),
                            M["worm_sand"], (1.3, 1.0, 0.8), segments=10, rings=5))
    # Leading V of displaced sand.
    for i in range(3):
        for side in (-1.0, 1.0):
            p.append(box((0.72 - float(i) * 0.12, 0.075, 0.06),
                         (3.02 + float(i) * 0.15, sway + side * (0.36 + float(i) * 0.36), 0.06),
                         M["worm_sand_light"],
                         rot=(0.0, 0.0, side * (0.34 + float(i) * 0.10)), bevel=0.002))
    return group(p, 0.0)


def render_worm(path, cell, ortho, topdown=False, target_z=1.7):
    scene = bpy.context.scene
    scene.render.resolution_x = cell
    scene.render.resolution_y = cell
    cam = scene.camera
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = ortho
    if topdown:
        cam.location = (0.0, 0.0, 14.0)
        cam.rotation_euler = (0.0, 0.0, 0.0)
    else:
        target = Vector((0.0, 0.0, target_z))
        cam.location = target + Vector((0.0, -10.8, 7.8))
        cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def bake_worm_sheet(name, frames, builder, cell, ortho, topdown=False, target_z=1.7, target=58.0):
    WORM_DIR.mkdir(parents=True, exist_ok=True)
    raw_dir = FRAME_DIR / ("worm_" + name)
    raw_dir.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (cell * frames, cell), (0, 0, 0, 0))
    for i in range(frames):
        bb.purge_model()
        builder(i)
        path = raw_dir / ("f%02d.png" % i)
        if os.environ.get("BAKE_RESUME") != "1" or not path.exists():
            render_worm(path, cell, ortho, topdown, target_z)
        raw = Image.open(path).convert("RGBA")
        img = downscale(raw, (cell, cell))
        sheet.alpha_composite(img, (i * cell, 0))
    sheet = normalize_rgba(sheet, target, saturation=1.10, contrast=1.05)
    # Warm the whole strip toward the game's orange desert sand. The neutral
    # stage lighting kept drifting the hide and dunes olive-green.
    px = sheet.load()
    for yy in range(sheet.height):
        for xx in range(sheet.width):
            r, g, b, a = px[xx, yy]
            if a == 0:
                continue
            px[xx, yy] = (min(255, int(r * 1.04 + 4)),
                          min(255, int(g * 0.99)),
                          min(255, int(b * 0.90)), a)
    out = WORM_DIR / (name + ".png")
    sheet.save(out)
    print("SANDWORM SHEET %-8s %dx%d frames=%d cell=%d" %
          (name, sheet.width, sheet.height, frames, cell), flush=True)
    return out


def bake_sandworm():
    """Prowl, breach, bite and burrow animation strips for Shai-Hulud."""
    # A tall subject needs its own key and fill aim; the unit studio lights sit
    # low for 1-unit vehicles and leave the maw in shadow.
    sun = bpy.data.objects.get("Portrait Sun")
    if sun is not None:
        sun.data.energy = 3.2
        # Low late-afternoon key: the default nearly-vertical sun flattened the
        # dune crest and the segmented body into pastel cutouts.
        sun.rotation_euler = Vector((0.86, 0.34, -0.38)).to_track_quat("-Z", "Y").to_euler()
        sun.data.color = (1.0, 0.90, 0.74)
    fill = bpy.data.objects.get("Portrait Fill")
    if fill is not None:
        fill.data.energy = 1250.0
        fill.location = (1.6, -6.2, 6.4)
        fill.rotation_euler = (Vector((0.0, 0.0, 2.0)) - fill.location).to_track_quat("-Z", "Y").to_euler()
    warm = bpy.data.objects.get("Warm Bounce")
    if warm is not None:
        warm.data.energy = 520.0
    # High, soft top light separates the crest and the maw from the dark hide.
    top_data = bpy.data.lights.new("Worm Top", "AREA")
    top_data.energy = 900.0
    top_data.color = (1.0, 0.94, 0.84)
    top_data.size = 7.0
    top_data.use_shadow = True
    top = bpy.data.objects.new("Worm Top", top_data)
    top.location = (0.0, 0.4, 8.0)
    top.rotation_euler = (Vector((0.0, 0.0, 1.8)) - top.location).to_track_quat("-Z", "Y").to_euler()
    bb.link(top)
    breach = [
        {"rise": 0.10, "jaw": 0.18, "phase": 0.0, "churn": 1.0, "collar": 1.15},
        {"rise": 0.42, "jaw": 0.30, "phase": 0.25, "churn": 0.95, "collar": 1.12},
        {"rise": 0.94, "jaw": 0.48, "phase": 0.50, "churn": 0.82, "collar": 1.08, "rear": 0.08},
        {"rise": 1.56, "jaw": 0.68, "phase": 0.78, "churn": 0.65, "collar": 1.04, "rear": 0.18},
        {"rise": 2.18, "jaw": 0.84, "phase": 1.08, "churn": 0.48, "collar": 1.02, "rear": 0.30},
        {"rise": 2.76, "jaw": 0.96, "phase": 1.36, "churn": 0.34, "collar": 1.0, "rear": 0.42},
        {"rise": 3.16, "jaw": 1.0, "phase": 1.66, "churn": 0.24, "collar": 1.0, "rear": 0.54},
        {"rise": 3.30, "jaw": 1.0, "phase": 1.96, "churn": 0.18, "collar": 1.0, "rear": 0.62},
    ]
    bite = [
        {"rise": 3.28, "jaw": 1.0, "phase": 0.2, "lunge": 0.0, "rear": 0.60, "churn": 0.16, "collar": 1.0},
        {"rise": 3.30, "jaw": 0.90, "phase": 0.4, "lunge": 0.18, "rear": 0.35, "churn": 0.22, "collar": 1.02},
        {"rise": 3.20, "jaw": 0.64, "phase": 0.6, "lunge": 0.38, "rear": 0.14, "churn": 0.32, "collar": 1.05},
        {"rise": 3.05, "jaw": 0.30, "phase": 0.8, "lunge": 0.56, "rear": 0.03, "churn": 0.42, "collar": 1.08},
        {"rise": 2.96, "jaw": 0.06, "phase": 1.0, "lunge": 0.62, "rear": 0.0, "churn": 0.50, "collar": 1.10},
        {"rise": 2.95, "jaw": 0.04, "phase": 1.2, "lunge": 0.48, "rear": 0.0, "churn": 0.46, "collar": 1.12},
    ]
    burrow = [
        {"rise": 3.05, "jaw": 0.20, "phase": 0.3, "churn": 0.42, "collar": 1.22},
        {"rise": 2.68, "jaw": 0.16, "phase": 0.6, "churn": 0.56, "collar": 1.42},
        {"rise": 2.24, "jaw": 0.13, "phase": 0.9, "churn": 0.68, "collar": 1.62},
        {"rise": 1.74, "jaw": 0.10, "phase": 1.2, "churn": 0.80, "collar": 1.82},
        {"rise": 1.24, "jaw": 0.08, "phase": 1.5, "churn": 0.90, "collar": 1.98},
        {"rise": 0.78, "jaw": 0.06, "phase": 1.8, "churn": 0.96, "collar": 2.08},
        {"rise": 0.38, "jaw": 0.04, "phase": 2.1, "churn": 1.0, "collar": 2.16},
        {"rise": 0.10, "jaw": 0.02, "phase": 2.4, "churn": 1.0, "collar": 2.22},
    ]
    only = os.environ.get("BAKE_WORM_ONLY", "")
    # The attack strips carry the technical-ink outline. The prowl sheet is a
    # top-down dune ridge, so an outline around the sand would read as a flat
    # sticker; its buried armour is distinguished by colour and shadow instead.
    need_attack = not only or any(kind in only for kind in ("breach", "bite", "burrow"))
    if not only or "prowl" in only:
        bpy.context.scene.render.use_freestyle = False
        bake_worm_sheet("prowl", 8, build_sandworm_prowl, 512, 6.6, topdown=True,
                        target_z=0.0, target=76.0)
    if need_attack:
        # The large worm sheets need a finer absolute ink line than the 4x unit
        # sheets, where a 4 px render line becomes one game pixel after downscale.
        bb.enable_freestyle()
        for lineset in bpy.context.view_layer.freestyle_settings.linesets:
            if lineset.linestyle is not None:
                lineset.linestyle.thickness = 1.45
    if not only or "breach" in only:
        bake_worm_sheet("breach", len(breach), lambda i: build_sandworm(breach[i]), 640, 7.6, target_z=1.85)
    if not only or "bite" in only:
        bake_worm_sheet("bite", len(bite), lambda i: build_sandworm(bite[i]), 640, 7.6, target_z=1.85)
    if not only or "burrow" in only:
        bake_worm_sheet("burrow", len(burrow), lambda i: build_sandworm(burrow[i]), 640, 7.6, target_z=1.85)


def bake_harvester():
    """Three fill levels, each a 16-direction sheet with a driving row and a
    harvesting row. The dozer blade drops and fresh ore rides its cutting edge
    in the second row; live dust, exhaust and spice spray come from
    Harvester._process so the rig never looks like a slideshow."""
    cell = CELLS["harvester"]
    px = cell * RENDER_SCALE
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    wanted = os.environ.get("BAKE_FILLS", "empty,half,full").split(",")
    for name, fill in (("empty", 0.0), ("half", 0.5), ("full", 1.0)):
        if name not in wanted:
            continue
        raw_dir = FRAME_DIR / ("harvester_" + name)
        raw_dir.mkdir(parents=True, exist_ok=True)
        sheet = Image.new("RGBA", (px * 16, px * 2), (0, 0, 0, 0))
        for row, harvesting in ((0, False), (1, True)):
            bb.purge_model()
            root = build_harvester(fill, harvesting)
            for i in range(16):
                root.rotation_euler.z = math.tau * i / 16.0
                path = raw_dir / ("%s_%02d.png" % ("harvest" if harvesting else "drive", i))
                # A long bake can outlive its shell. Resume reuses only frames
                # this exact model already rendered.
                if os.environ.get("BAKE_RESUME") != "1" or not path.exists():
                    render_to(path, cell, VIEW["harvester"])
                raw = Image.open(path).convert("RGBA")
                img = drop_shadow(downscale(raw, (px, px)))
                sheet.alpha_composite(img, (i * px, row * px))
        sheet = normalize_rgba(sheet, 54.0, saturation=1.12, contrast=1.03)
        path = OUT_DIR / ("harvester_" + name + ".png")
        sheet.save(path)
        print("UNIT SHEET %-16s %dx%d cell=%d rows=drive,harvest" %
              ("harvester_" + name, sheet.width, sheet.height, px), flush=True)


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
    if kind == "carryall":
        return build_carryall()
    if kind == "frigate":
        return build_frigate()
    if kind == "ornithopter":
        return build_ornithopter()
    if kind in INFANTRY:
        return build_infantry(kind, 0)
    builders = {
        "trike": build_trike, "raider_trike": build_raider,
        "quad": build_quad, "atreides_tank": lambda: build_combat_tank("atreides"),
        "harkonnen_tank": lambda: build_combat_tank("harkonnen"),
        "ordos_tank": lambda: build_combat_tank("ordos"),
        "sonic_tank": build_sonic, "devastator": build_devastator,
        "deviator": build_deviator, "mcv": build_mcv,
        "carryall": build_carryall, "frigate": build_frigate,
        "ornithopter": build_ornithopter,
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
    if "sandworm" in tokens:
        bake_sandworm()
        print("SANDWORM BAKES COMPLETE", flush=True)
        return
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    if icons_only:
        icon_selection = [t for t in tokens if t in ICON_IDS]
        for kind in (icon_selection or list(ICON_IDS)):
            bake_icon(kind)
        print("UNIT ICONS COMPLETE", flush=True)
        return
    order = ["infantry", "rocket", "fremen", "sardaukar", "saboteur",
             "trike", "raider_trike", "quad", "atreides_tank", "harkonnen_tank",
             "ordos_tank", "sonic_tank", "devastator", "deviator", "mcv", "carryall",
             "frigate", "ornithopter"]
    for kind in order:
        if selection and kind not in selection and not (kind == "harvester" and "harvester" in selection):
            continue
        if kind in INFANTRY:
            bake_infantry(kind)
        elif kind in ("carryall", "frigate", "ornithopter"):
            air_builders = {"carryall": build_carryall, "frigate": build_frigate,
                            "ornithopter": build_ornithopter}
            bake_vehicle_boxes(kind, air_builders[kind], CELLS[kind], VIEW[kind])
        else:
            build = {
                "trike": build_trike, "raider_trike": build_raider, "quad": build_quad,
                "atreides_tank": lambda: build_combat_tank("atreides"),
                "harkonnen_tank": lambda: build_combat_tank("harkonnen"),
                "ordos_tank": lambda: build_combat_tank("ordos"),
                "sonic_tank": build_sonic, "devastator": build_devastator,
                "deviator": build_deviator, "mcv": build_mcv,
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
