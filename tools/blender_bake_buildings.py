"""Headless Blender Cycles building baker for Sandwar.

Run with:

    blender --background --python tools/blender_bake_buildings.py

Optional selection / speed (after the double dash):

    blender --background --python tools/blender_bake_buildings.py -- cy,windtrap
    BAKE_SAMPLES=16 blender --background --python tools/blender_bake_buildings.py

Outputs exactly the files scripts/building_art.gd expects:

    assets/sprites/buildings/cy.png          4x2 sheet, 264 px cells (1056x528)
    assets/sprites/buildings/cy_icon.png     64x64 sidebar portrait
    assets/sprites/buildings/windtrap.png    4x2 sheet, 224 px cells (896x448)
    assets/sprites/buildings/windtrap_icon.png

The camera mirrors tools/bake_buildings_3d.gd: orthographic, exactly south of
the model with zero yaw, pitched 50 degrees down, vertical ortho size
span * 1.38 + 1.30. Footprint edges therefore stay parallel to the screen
axes and the 3x3 / 2x2 placement grids keep working unchanged.

World sheets bake magenta house trim for shaders/faction_remap.gdshader.
Sidebar portraits bake the blue trim that the HUD material keys with
icon_blue_trim, matching BuildingArt.hud_material().

Render: Cycles on the fastest available GPU (OptiX, then CUDA, then CPU),
transparent film, 64 samples with OpenImageDenoise when the build provides it,
Standard view transform so the PNG colour matches what the game draws. Frames
render at 2x and are downscaled with premultiplied alpha to keep edges clean.
"""
from __future__ import annotations

import math
import os
import sys
from pathlib import Path

import bpy
import numpy as np
from PIL import Image, ImageFilter
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets" / "sprites" / "buildings"
FRAME_DIR = ROOT / "build" / "blender_frames"
TILE = 40
MARGIN = 72
FRAMES = 4
ICON_SIZE = 64
REQUESTED_SAMPLES = os.environ.get("BAKE_SAMPLES")
SAMPLES = int(REQUESTED_SAMPLES or "64")
RES_SCALE = 2

def group_root(objs, angle=0.0):
    root = bpy.data.objects.new("Group", None)
    root["sandwar_model"] = True
    link(root)
    for obj in objs:
        obj.parent = root
        obj.matrix_parent_inverse = root.matrix_world.inverted()
    root.rotation_euler.z = angle
    return root


def fire_and_scorch(x, y, scale=1.0):
    add_deck_crater(x, y, 0.34 * scale, True)
    box((0.7 * scale, 0.5 * scale, 0.03), (x, y, 0.34), MATS["scorch"], bevel=0.0)
    fire = sphere(0.13 * scale, (x, y, 0.45), MATS["fire"], segments=12, rings=8)
    return {"obj": fire, "kind": "fire", "phase": 1.7}


def build_refinery(damaged: bool):
    add_foundation(3, damaged)
    box((2.52, 1.86, 0.12), (0.0, 0.0, 0.30), MATS["pad_light"], bevel=0.018)
    box((2.30, 0.74, 0.028), (0.0, 0.92, 0.365), MATS["black"], bevel=0.006)
    for side in (-1.0, 1.0):
        box((0.06, 0.68, 0.030), (side * 1.08, 0.92, 0.382), MATS["trim"], bevel=0.004)
    for x in (-0.92, 0.92):
        for y in (0.66, 1.12):
            cyl(0.045, 0.045, (x, y, 0.405), MATS["amber"], verts=8)
    for i in range(6):
        box((0.16, 0.022, 0.032), (-0.55 + i * 0.22, 0.98, 0.39), MATS["steel_light"], bevel=0.0)
    # Processing house with louvered vents and a maintenance catwalk.
    box((0.94, 0.94, 0.82), (0.66, -0.34, 0.76), MATS["steel"], bevel=0.014)
    box((1.00, 1.00, 0.07), (0.66, -0.34, 1.20), MATS["steel_light"], bevel=0.012)
    louver_bank((0.66, 0.145, 0.92), 0.58, 0.30, 4, MATS["steel"], MATS["grill"])
    box((1.52, 0.10, 0.09), (0.0, -0.04, 1.30), MATS["steel_light"], bevel=0.006)
    for x in (-0.6, -0.2, 0.2, 0.6):
        box((0.04, 0.10, 0.16), (x, -0.04, 1.20), MATS["steel"], bevel=0.0)
    # Twin riveted spice silos and their narrow exhaust stacks.
    for x in (-0.86, 0.28):
        cyl(0.40, 1.44, (x, -0.46, 1.06), MATS["armor"], verts=28, bevel=0.012)
        cyl(0.42, 0.055, (x, -0.46, 1.52), MATS["trim"], verts=28, bevel=0.004)
        cyl(0.42, 0.055, (x, -0.46, 1.04), MATS["steel_light"], verts=28, bevel=0.004)
        sphere(0.405, (x, -0.46, 1.79), MATS["steel_light"], scale=(1.0, 1.0, 0.34))
        cyl(0.092, 0.62, (x, -0.46, 2.06), MATS["steel"], verts=12, bevel=0.004)
        cyl(0.118, 0.05, (x, -0.46, 2.38), MATS["steel_light"], verts=12, bevel=0.003)
        cyl(0.045, 0.035, (x, -0.46, 2.41), MATS["amber"], verts=8)
        for k in range(7):
            bolt((x - 0.36 + k * 0.12, -0.46, 0.70), MATS["steel_light"], axis="Y")
        box((0.12, 0.05, 0.11), (x, 0.10, 0.66), MATS["trim"], bevel=0.004)
    pipe((-0.45, -0.46, 1.82), (0.45, -0.46, 1.82), 0.06, MATS["steel_light"])
    pipe((-0.45, -0.20, 0.62), (0.45, -0.20, 0.62), 0.045, MATS["rust"])
    for x in (-0.86, 0.28):
        pipe((x, -0.05, 1.25), (x, 0.55, 1.25), 0.035, MATS["steel"])
    box((0.46, 0.06, 0.14), (-0.32, 1.05, 0.38), MATS["trim"], bevel=0.004)
    for i in range(4):
        box((0.30, 0.26, 0.08), (-1.0 + i * 0.34, -1.18, 0.40), MATS["sand"], bevel=0.0)
    sand_drift((1.25, 1.10, 0.38), 0.34, MATS["sand"])
    sand_drift((-1.18, 1.16, 0.38), 0.30, MATS["sand"])
    anims = []
    if damaged:
        anims.append(fire_and_scorch(0.66, 0.26, 1.0))
        box((0.55, 0.40, 0.02), (0.40, -0.42, 1.53), MATS["scorch"], bevel=0.0)
    return anims


def build_barracks(damaged: bool):
    add_foundation(2, damaged)
    box((1.76, 1.68, 0.30), (0.0, 0.0, 0.35), MATS["pad_light"], bevel=0.018)
    box((1.54, 1.36, 0.62), (0.0, -0.04, 0.68), MATS["armor"], bevel=0.016)
    box((1.44, 1.26, 0.06), (0.0, -0.04, 1.02), MATS["steel_light"], bevel=0.008)
    # Low ribbed dome roof: a full barrel would hide the whole south facade.
    sphere(1.0, (0.0, -0.04, 0.98), MATS["armor"], scale=(0.78, 0.66, 0.40))
    for i in range(-2, 3):
        box((0.05, 0.92, 0.035), (i * 0.28, -0.04, 1.24), MATS["steel_light"],
            rot=(0.0, 0.0, 0.0), bevel=0.0)
    box((1.12, 0.06, 0.06), (0.0, -0.04, 1.40), MATS["trim"], bevel=0.003)
    box((0.90, 0.08, 0.04), (0.0, 0.36, 1.18), MATS["steel_light"], bevel=0.002)
    for side in (-1.0, 1.0):
        box((0.28, 0.10, 1.00), (side * 0.78, 0.0, 1.06), MATS["armor"],
            rot=(0.0, math.radians(side * 13.0), 0.0), bevel=0.012)
        box((0.08, 0.045, 0.86), (side * 0.92, 0.0, 1.02), MATS["trim"],
            rot=(0.0, math.radians(side * 13.0), 0.0), bevel=0.003)
        box((0.06, 0.30, 0.28), (side * 0.86, -0.56, 0.66), MATS["steel"], bevel=0.006)
        add_window(side * 0.56, 0.63, 0.70, 0.20, MATS["cyan"])
    # Projecting entry porch so the door reads in front of the dome.
    box((1.04, 0.12, 0.74), (0.0, 0.73, 0.61), MATS["steel_light"], bevel=0.008)
    box((0.76, 0.05, 0.56), (0.0, 0.795, 0.56), MATS["black"], bevel=0.0)
    box((0.60, 0.03, 0.44), (0.0, 0.825, 0.51), MATS["grill"], bevel=0.0)
    for side in (-1.0, 1.0):
        box((0.11, 0.14, 0.74), (side * 0.46, 0.65, 0.64), MATS["steel_light"], bevel=0.006)
        box((0.06, 0.03, 0.46), (side * 0.34, 0.73, 0.55), MATS["trim"], bevel=0.0)
    box((0.94, 0.12, 0.09), (0.0, 0.66, 1.02), MATS["trim"], bevel=0.004)
    box((0.50, 0.22, 0.02), (0.0, 0.82, 0.36), MATS["pad_light"], bevel=0.0)
    cyl(0.29, 0.07, (-0.22, -0.02, 1.94), MATS["steel"], verts=16, bevel=0.004)
    cyl(0.22, 0.06, (-0.22, -0.02, 1.99), MATS["grill"], verts=16, bevel=0.004)
    box((0.24, 0.24, 0.09), (0.34, -0.06, 1.94), MATS["grill"], bevel=0.004)
    pipe((0.52, -0.54, 1.90), (0.52, -0.54, 2.35), 0.018, MATS["steel_light"])
    cyl(0.028, 0.03, (-0.44, 0.72, 1.03), MATS["amber"], verts=8)
    sand_drift((1.20, 1.20, 0.36), 0.32, MATS["sand"])
    sand_drift((-1.18, 1.14, 0.36), 0.28, MATS["sand"])
    anims = []
    if damaged:
        anims.append(fire_and_scorch(0.0, 0.62, 0.9))
        box((0.50, 0.40, 0.02), (-0.35, -0.50, 1.98), MATS["scorch"], bevel=0.0)
    return anims


def build_factory(damaged: bool):
    add_foundation(3, damaged)
    box((2.58, 1.86, 0.28), (0.0, 0.0, 0.34), MATS["pad_light"], bevel=0.018)
    box((2.38, 1.48, 0.62), (0.0, -0.10, 0.66), MATS["armor"], bevel=0.016)
    box((2.26, 1.42, 0.06), (0.0, -0.10, 1.00), MATS["steel_light"], bevel=0.008)
    sphere(1.0, (0.0, -0.10, 1.00), MATS["armor"], scale=(1.24, 0.76, 0.42))
    for i in range(-3, 4):
        box((0.055, 1.04, 0.035), (i * 0.30, -0.10, 1.27), MATS["steel_light"], bevel=0.0)
    box((1.55, 0.06, 0.06), (0.0, -0.10, 1.44), MATS["trim"], bevel=0.003)
    box((1.24, 0.08, 0.04), (0.0, 0.44, 1.18), MATS["steel_light"], bevel=0.002)
    for side in (-1.0, 1.0):
        box((0.22, 1.10, 0.18), (side * 1.12, -0.28, 0.78), MATS["pad_light"], bevel=0.010)
        box((0.04, 0.10, 0.95), (side * 1.23, -0.18, 0.80), MATS["trim"], bevel=0.003)
        box((0.24, 0.16, 0.90), (side * 1.12, 0.52, 0.80), MATS["pad_light"], bevel=0.010)
        cyl(0.16, 0.46, (side * 1.02, -0.36, 1.78), MATS["steel"], axis="X", verts=14, bevel=0.006)
        cyl(0.19, 0.05, (side * 1.28, -0.36, 1.78), MATS["grill"], axis="X", verts=14, bevel=0.003)
        add_window(side * 0.90, 0.66, 0.72, 0.20, MATS["cyan"])
    # Projecting roll-out bay with a segmented shutter.
    box((1.86, 0.12, 0.78), (0.0, 0.78, 0.60), MATS["steel"], bevel=0.008)
    box((1.52, 0.05, 0.62), (0.0, 0.845, 0.57), MATS["black"], bevel=0.0)
    box((1.34, 0.03, 0.52), (0.0, 0.875, 0.53), MATS["grill"], bevel=0.0)
    for i in range(4):
        box((1.34, 0.02, 0.012), (0.0, 0.73, 0.36 + i * 0.10), MATS["steel_light"], bevel=0.0)
    for side in (-1.0, 1.0):
        box((0.16, 0.18, 0.82), (side * 0.88, 0.64, 0.66), MATS["steel_light"], bevel=0.008)
        box((0.07, 0.03, 0.56), (side * 0.82, 0.73, 0.56), MATS["trim"], bevel=0.0)
    box((1.58, 0.14, 0.08), (0.0, 0.64, 1.06), MATS["trim"], bevel=0.004)
    box((1.82, 0.32, 0.025), (0.0, 0.88, 0.40), MATS["pad_light"], bevel=0.0)
    for side in (-1.0, 1.0):
        cyl(0.06, 0.05, (side * 0.78, 0.98, 0.43), MATS["amber"], verts=8)
    box((1.48, 0.10, 0.07), (0.0, -0.10, 2.11), MATS["trim"], bevel=0.004)
    box((0.34, 0.30, 0.12), (-0.54, -0.38, 1.95), MATS["grill"], bevel=0.004)
    box((0.26, 0.24, 0.11), (0.58, -0.54, 1.93), MATS["grill"], bevel=0.004)
    pipe((0.86, -0.70, 1.94), (0.86, -0.70, 2.55), 0.018, MATS["steel_light"])
    for x in (-0.72, 0.72):
        cyl(0.20, 0.10, (x, 0.12, 1.98), MATS["steel_light"], axis="Y", verts=16, bevel=0.006)
        cyl(0.13, 0.05, (x, 0.19, 1.98), MATS["cyan"], axis="Y", verts=16, bevel=0.003)
    sand_drift((1.30, 1.20, 0.36), 0.36, MATS["sand"])
    sand_drift((-1.30, 1.18, 0.36), 0.32, MATS["sand"])
    anims = []
    if damaged:
        anims.append(fire_and_scorch(-0.55, 0.45, 1.1))
        box((0.70, 0.35, 0.02), (0.55, -0.30, 2.12), MATS["scorch"], bevel=0.0)
    return anims


def build_turret_base(damaged: bool):
    add_foundation(1, damaged)
    box((0.96, 0.96, 0.14), (0.0, 0.0, 0.20), MATS["pad_light"], bevel=0.010)
    cyl(0.55, 0.20, (0.0, 0.0, 0.28), MATS["armor"], verts=8, bevel=0.008)
    cyl(0.47, 0.16, (0.0, 0.0, 0.44), MATS["steel"], verts=8, bevel=0.006)
    cyl(0.40, 0.055, (0.0, 0.0, 0.54), MATS["steel_light"], verts=8, bevel=0.004)
    cyl(0.29, 0.045, (0.0, 0.0, 0.58), MATS["grill"], verts=8, bevel=0.002)
    for i in range(8):
        a = math.tau * i / 8.0
        box((0.16, 0.10, 0.19), (math.cos(a) * 0.44, math.sin(a) * 0.44, 0.31),
            MATS["steel"], rot=(0.0, 0.0, a), bevel=0.006)
    for side in (-1.0, 1.0):
        box((0.045, 0.34, 0.045), (side * 0.45, 0.0, 0.45), MATS["trim"], bevel=0.0)
        box((0.32, 0.045, 0.045), (0.0, side * 0.45, 0.45), MATS["trim"], bevel=0.0)
    cyl(0.034, 0.03, (0.33, 0.26, 0.55), MATS["amber"], verts=8)
    sand_drift((0.48, 0.48, 0.18), 0.22, MATS["sand"])
    anims = []
    if damaged:
        anims.append(fire_and_scorch(0.0, 0.25, 0.55))
    return anims


def build_rocket_base(damaged: bool):
    add_foundation(1, damaged)
    box((0.97, 0.97, 0.15), (0.0, 0.0, 0.20), MATS["pad_light"], bevel=0.010)
    cyl(0.57, 0.19, (0.0, 0.0, 0.28), MATS["armor"], verts=8, bevel=0.008)
    cyl(0.48, 0.15, (0.0, 0.0, 0.45), MATS["steel"], verts=8, bevel=0.006)
    cyl(0.41, 0.055, (0.0, 0.0, 0.55), MATS["steel_light"], verts=8, bevel=0.004)
    cyl(0.30, 0.045, (0.0, 0.0, 0.59), MATS["grill"], verts=8, bevel=0.002)
    for i in range(8):
        a = math.tau * i / 8.0
        box((0.18, 0.10, 0.18), (math.cos(a) * 0.45, math.sin(a) * 0.45, 0.31),
            MATS["steel"], rot=(0.0, 0.0, a), bevel=0.006)
    for side in (-1.0, 1.0):
        box((0.05, 0.32, 0.05), (side * 0.45, 0.0, 0.46), MATS["trim"], bevel=0.0)
        box((0.28, 0.06, 0.05), (0.0, side * 0.45, 0.46), MATS["trim"], bevel=0.0)
    cyl(0.036, 0.03, (-0.34, 0.25, 0.56), MATS["amber"], verts=8)
    sand_drift((-0.48, 0.48, 0.18), 0.22, MATS["sand"])
    anims = []
    if damaged:
        anims.append(fire_and_scorch(0.0, -0.25, 0.55))
    return anims


def build_wall(damaged: bool):
    box((0.94, 0.78, 0.16), (0.0, 0.0, 0.11), MATS["steel"], bevel=0.010)
    box((0.76, 0.48, 0.60), (0.0, 0.0, 0.47), MATS["armor"], bevel=0.010)
    box((0.90, 0.58, 0.12), (0.0, 0.0, 0.80), MATS["steel"], bevel=0.008)
    for side in (-1.0, 1.0):
        box((0.12, 0.24, 0.24), (side * 0.39, 0.0, 0.85), MATS["steel_light"], bevel=0.006)
        box((0.20, 0.58, 0.18), (side * 0.40, 0.0, 0.32), MATS["steel"], bevel=0.006)
        pipe((side * 0.34, 0.28, 0.22), (side * 0.34, 0.28, 0.70), 0.035, MATS["rust"])
    for i in range(4):
        box((0.18, 0.035, 0.04), (-0.26 + i * 0.17, 0.26, 0.54), MATS["grill"], bevel=0.0)
    box((0.44, 0.15, 0.12), (0.0, 0.30, 0.40), MATS["trim"], bevel=0.004)
    box((0.24, 0.18, 0.06), (-0.30, -0.20, 0.90), MATS["steel_light"], bevel=0.003)
    cyl(0.045, 0.04, (0.23, -0.18, 0.88), MATS["amber"], verts=8)
    anims = []
    if damaged:
        box((0.30, 0.20, 0.08), (0.18, 0.12, 0.82), MATS["scorch"], bevel=0.0)
        anims.append(fire_and_scorch(-0.10, 0.0, 0.35))
    return anims


def build_slab(damaged: bool):
    box((0.99, 0.99, 0.10), (0.0, 0.0, 0.06), MATS["pad"], bevel=0.008)
    box((0.92, 0.92, 0.07), (0.0, 0.0, 0.13), MATS["pad_light"], bevel=0.006)
    box((0.84, 0.84, 0.03), (0.0, 0.0, 0.18), MATS["pad_light"], bevel=0.0)
    for side in (-1.0, 1.0):
        box((0.84, 0.025, 0.018), (0.0, side * 0.41, 0.20), MATS["steel_light"], bevel=0.0)
        box((0.025, 0.84, 0.018), (side * 0.41, 0.0, 0.20), MATS["steel_light"], bevel=0.0)
    for x in (-0.34, 0.34):
        for y in (-0.34, 0.34):
            bolt((x, y, 0.20), MATS["steel_light"], radius=0.024, depth=0.02)
    sand_drift((-0.28, 0.28, 0.19), 0.16, MATS["sand"], squash=0.08)
    return []


def build_turret_head(kind: str, angle: float, damaged: bool = False):
    pieces = []
    base = box((0.46, 0.46, 0.22), (0.0, 0.0, 0.69), MATS["steel"], bevel=0.008)
    pieces.append(base)
    if kind == "turret":
        pieces.append(box((0.30, 0.32, 0.18), (0.18, 0.0, 0.74), MATS["steel_light"], bevel=0.006))
        pieces.append(box((0.16, 0.06, 0.26), (-0.04, 0.0, 0.86), MATS["trim"], bevel=0.003))
        for side in (-1.0, 1.0):
            pieces.append(cyl(0.060, 0.78, (0.54, side * 0.10, 0.76), MATS["gunmetal"], axis="X", verts=14, bevel=0.004))
            pieces.append(cyl(0.090, 0.14, (0.94, side * 0.10, 0.76), MATS["rust"], axis="X", verts=12, bevel=0.003))
            pieces.append(cyl(0.075, 0.05, (1.015, side * 0.10, 0.76), MATS["grill"], axis="X", verts=12, bevel=0.002))
        pieces.append(cyl(0.085, 0.06, (0.0, 0.0, 0.81), MATS["steel_light"], verts=12, bevel=0.003))
    else:
        pieces.append(box((0.40, 0.40, 0.20), (-0.02, 0.0, 0.76), MATS["steel_light"], bevel=0.006))
        for side in (-1.0, 1.0):
            for row in (-1.0, 1.0):
                pieces.append(cyl(0.065, 0.30, (0.22, side * 0.11, 0.78 + row * 0.09),
                                  MATS["gunmetal"], axis="X", verts=12, bevel=0.003))
                pieces.append(cyl(0.078, 0.045, (0.38, side * 0.11, 0.78 + row * 0.09),
                                  MATS["trim"], axis="X", verts=12, bevel=0.002))
        pieces.append(box((0.22, 0.30, 0.06), (0.02, 0.0, 0.88), MATS["trim"], bevel=0.003))
    root = group_root(pieces, -angle)
    anims = []
    if damaged:
        anims.append({"obj": root, "kind": "lamp"})
    return root, anims


def build_turret_head_model(kind: str, angle: float):
    return build_turret_head(kind, angle)[0]


def build_turret_icon(damaged: bool):
    anims = build_turret_base(damaged)
    build_turret_head("turret", 0.0, damaged)
    return anims


def build_rocket_icon(damaged: bool):
    anims = build_rocket_base(damaged)
    build_turret_head("rocketturret", 0.0, damaged)
    return anims


def aim_head_camera() -> None:
    cam = bpy.context.scene.camera
    cam.data.ortho_scale = 2.20
    target = Vector((0.0, 0.0, 0.56))
    dist = 7.5
    cam.location = target + Vector((0.0, dist, dist * math.tan(math.radians(50.0))))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()


def render_heads(kind: str) -> Path:
    span = 1
    cell = span * TILE + MARGIN * 2
    aim_head_camera()
    scene = bpy.context.scene
    scene.render.resolution_x = cell * RES_SCALE
    scene.render.resolution_y = cell * RES_SCALE
    out_dir = FRAME_DIR / (kind + "_head")
    out_dir.mkdir(parents=True, exist_ok=True)
    for i in range(HEAD_FRAMES):
        purge_model()
        build_turret_head_model(kind, math.tau * i / HEAD_FRAMES)
        path = out_dir / ("f%d.png" % i)
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True)
        print("RENDERED %s head=%d -> %s" % (kind, i, path), flush=True)
    sheet = Image.new("RGBA", (cell * HEAD_FRAMES, cell), (0, 0, 0, 0))
    for i in range(HEAD_FRAMES):
        raw = Image.open(out_dir / ("f%d.png" % i)).convert("RGBA")
        sheet.alpha_composite(premultiplied_resize(raw, (cell, cell)), (i * cell, 0))
    path = OUT_DIR / (kind + "_head.png")
    sheet.save(path)
    print("HEAD %s %dx%d" % (path, sheet.width, sheet.height), flush=True)
    return path


#!/usr/bin/env python3

SPECS = {
    "cy": {"span": 3},
    "refinery": {"span": 3},
    "windtrap": {"span": 2},
    "barracks": {"span": 2},
    "factory": {"span": 3},
    "turret": {"span": 1},
    "rocketturret": {"span": 1},
    "wall": {"span": 1},
    "slab": {"span": 1},
}
HEAD_IDS = ("turret", "rocketturret")
HEAD_FRAMES = 16

# ------------------------------------------------------------------ utilities


def args_after_ddash() -> list[str]:
    if "--" not in sys.argv:
        return []
    return sys.argv[sys.argv.index("--") + 1:]


def configure_cycles_device() -> str:
    """Prefer OptiX, then CUDA, then CPU. Small scenes stay inside 4 GB VRAM."""
    scene = bpy.context.scene
    scene.cycles.device = "CPU"
    addon = bpy.context.preferences.addons.get("cycles")
    if addon is None:
        print("CYCLES DEVICE CPU (no cycles addon preferences)", flush=True)
        return "CPU"
    prefs = addon.preferences
    for device_type in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = device_type
            prefs.get_devices()
            devices = [d for d in prefs.devices if d.type == device_type]
            if not devices:
                continue
            for device in prefs.devices:
                device.use = device.type == device_type
            scene.cycles.device = "GPU"
            print("CYCLES DEVICE %s (%s)" % (device_type, ", ".join(d.name for d in devices)),
                  flush=True)
            return device_type
        except Exception as exc:
            print("CYCLES %s unavailable: %s" % (device_type, exc), flush=True)
    print("CYCLES DEVICE CPU", flush=True)
    return "CPU"


def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    configure_cycles_device()
    scene.cycles.samples = SAMPLES
    scene.cycles.use_adaptive_sampling = True
    scene.cycles.adaptive_threshold = 0.02
    # Some Blender builds ship without OpenImageDenoise; fall back to more
    # samples rather than failing the bake.
    try:
        scene.cycles.denoiser = "OPENIMAGEDENOISE"
        scene.cycles.use_denoising = True
    except TypeError:
        scene.cycles.use_denoising = False
        if not REQUESTED_SAMPLES:
            scene.cycles.samples = max(scene.cycles.samples, 64)
    scene.cycles.max_bounces = 8
    scene.cycles.diffuse_bounces = 4
    scene.cycles.glossy_bounces = 4
    scene.cycles.transmission_bounces = 2
    scene.cycles.transparent_max_bounces = 8
    scene.render.film_transparent = True
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.use_persistent_data = True
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0
    scene.render.fps = 30
    # Slightly wider than default keeps thin bolts from shimmering.
    scene.render.filter_size = 1.35


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def purge_model() -> None:
    for obj in list(bpy.data.objects):
        if obj.get("sandwar_model"):
            bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)


# ----------------------------------------------------------------- materials


def _mix(nodes, links, a, b, fac, blend="MIX"):
    node = nodes.new("ShaderNodeMixRGB")
    node.blend_type = blend
    node.inputs["Fac"].default_value = fac
    if hasattr(a, "default_value") or isinstance(a, tuple):
        node.inputs["Color1"].default_value = (*a, 1.0) if isinstance(a, tuple) else a.default_value
    else:
        links.new(a, node.inputs["Color1"])
    node.inputs["Color2"].default_value = (*b, 1.0) if isinstance(b, tuple) else b.default_value
    return node


def _ramp(nodes, links, fac, stops):
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "EASE"
    elements = ramp.color_ramp.elements
    while len(elements) > len(stops):
        elements.remove(elements[-1])
    while len(elements) < len(stops):
        elements.new(0.5)
    for el, (pos, col) in zip(elements, stops):
        el.position = pos
        el.color = (*col, 1.0)
    links.new(fac, ramp.inputs["Fac"])
    return ramp


def surface(name, base, metallic, rough, *, rust=0.0, dirt=0.55, bump=0.24,
            emission=None, emission_strength=0.0, trim=False):
    """Weathered Cycles material: AO in crevices, bevel highlights, noise bump."""
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    nodes.clear()

    out = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    coord = nodes.new("ShaderNodeTexCoord")
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 24.0
    noise.inputs["Detail"].default_value = 8.0
    noise.inputs["Roughness"].default_value = 0.58
    links.new(coord.outputs["Object"], noise.inputs["Vector"])

    broad = nodes.new("ShaderNodeTexNoise")
    broad.inputs["Scale"].default_value = 5.5
    broad.inputs["Detail"].default_value = 4.0
    broad.inputs["Roughness"].default_value = 0.55
    links.new(coord.outputs["Object"], broad.inputs["Vector"])

    vor = nodes.new("ShaderNodeTexVoronoi")
    vor.feature = "DISTANCE_TO_EDGE"
    vor.inputs["Scale"].default_value = 7.0
    links.new(coord.outputs["Object"], vor.inputs["Vector"])

    ao = nodes.new("ShaderNodeAmbientOcclusion")
    ao.inputs["Distance"].default_value = 0.42
    ao.samples = 8
    ao.inside = False

    # Base colour -> AO darkening in corners and crevices.
    base_node = nodes.new("ShaderNodeRGB")
    base_node.outputs[0].default_value = (*base, 1.0)
    dirt_mix = nodes.new("ShaderNodeMixRGB")
    dirt_mix.blend_type = "MULTIPLY"
    dirt_mix.inputs["Fac"].default_value = dirt
    links.new(base_node.outputs[0], dirt_mix.inputs["Color1"])
    links.new(ao.outputs["Color"], dirt_mix.inputs["Color2"])

    albedo = dirt_mix
    if rust > 0.0:
        # Warm corrosion gathers in the noisy recesses; trim paint is exempt.
        rust_mask = _ramp(nodes, links, broad.outputs["Fac"], [
            (0.42, (0.0, 0.0, 0.0)),
            (0.62, (0.65, 0.65, 0.65)),
            (0.86, (1.0, 1.0, 1.0)),
        ])
        mix_rust = nodes.new("ShaderNodeMixRGB")
        mix_rust.blend_type = "MIX"
        mix_rust.inputs["Fac"].default_value = rust
        links.new(dirt_mix.outputs[0], mix_rust.inputs["Color1"])
        mix_rust.inputs["Color2"].default_value = (0.235, 0.095, 0.040, 1.0)
        links.new(rust_mask.outputs["Color"], mix_rust.inputs["Fac"])
        albedo = mix_rust

    if trim:
        # Keep the magenta key saturated even where the AO darkens it.
        keep = nodes.new("ShaderNodeMixRGB")
        keep.blend_type = "MULTIPLY"
        keep.inputs["Fac"].default_value = 0.22
        links.new(base_node.outputs[0], keep.inputs["Color1"])
        links.new(ao.outputs["Color"], keep.inputs["Color2"])
        albedo = keep

    links.new(albedo.outputs[0], bsdf.inputs["Base Color"])
    bsdf.inputs["Metallic"].default_value = metallic

    rough_range = nodes.new("ShaderNodeMapRange")
    rough_range.inputs["From Min"].default_value = 0.0
    rough_range.inputs["From Max"].default_value = 1.0
    rough_range.inputs["To Min"].default_value = max(0.04, rough - 0.10)
    rough_range.inputs["To Max"].default_value = min(0.99, rough + 0.10)
    links.new(noise.outputs["Fac"], rough_range.inputs["Value"])
    links.new(rough_range.outputs["Result"], bsdf.inputs["Roughness"])

    # Bevel normals give crisp metallic edge catch; no extra polys required.
    bevel = nodes.new("ShaderNodeBevel")
    bevel.samples = 4
    bevel.inputs["Radius"].default_value = 0.014
    bump_node = nodes.new("ShaderNodeBump")
    bump_node.inputs["Strength"].default_value = bump
    bump_node.inputs["Distance"].default_value = 0.02
    height = nodes.new("ShaderNodeMath")
    height.operation = "MULTIPLY_ADD"
    height.inputs[1].default_value = 0.35
    links.new(vor.outputs["Distance"], height.inputs[0])
    links.new(noise.outputs["Fac"], height.inputs[2])
    links.new(height.outputs["Value"], bump_node.inputs["Height"])
    links.new(bevel.outputs["Normal"], bump_node.inputs["Normal"])
    links.new(bump_node.outputs["Normal"], bsdf.inputs["Normal"])

    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength

    mat.diffuse_color = (*base, 1.0)
    return mat


MATS = {}


def build_materials() -> None:
    MATS["pad"] = surface("Sunbaked Pad", (0.500, 0.360, 0.245), 0.02, 0.90,
                          dirt=0.55, bump=0.34)
    MATS["pad_light"] = surface("Pad Top", (0.600, 0.455, 0.315), 0.02, 0.86,
                                dirt=0.48, bump=0.30)
    MATS["armor"] = surface("Sun Bleached Armor", (0.755, 0.725, 0.655), 0.06, 0.56,
                            dirt=0.16, bump=0.15)
    MATS["armor_light"] = surface("Bone Plate", (0.850, 0.820, 0.745), 0.04, 0.50,
                                  dirt=0.12, bump=0.13)
    MATS["steel"] = surface("Weathered Steel", (0.285, 0.285, 0.275), 0.70, 0.44,
                            rust=0.46, dirt=0.52, bump=0.22)
    MATS["steel_light"] = surface("Worn Steel Rim", (0.400, 0.400, 0.380), 0.68, 0.40,
                                  rust=0.28, dirt=0.48, bump=0.18)
    MATS["gunmetal"] = surface("Gunmetal", (0.140, 0.150, 0.145), 0.78, 0.42,
                               rust=0.20, dirt=0.44, bump=0.24)
    MATS["black"] = surface("Soot Black", (0.035, 0.036, 0.034), 0.25, 0.78,
                            dirt=0.25, bump=0.20)
    MATS["grill"] = surface("Louver Dark", (0.060, 0.068, 0.066), 0.55, 0.52,
                            rust=0.18, dirt=0.30, bump=0.28)
    MATS["rust"] = surface("Rust", (0.300, 0.135, 0.055), 0.18, 0.86,
                           dirt=0.30, bump=0.30)
    MATS["sand"] = surface("Drifted Sand", (0.640, 0.500, 0.330), 0.0, 0.96,
                           dirt=0.20, bump=0.42)
    MATS["trim"] = surface("Faction Magenta", (0.880, 0.020, 0.560), 0.18, 0.44,
                           dirt=0.22, bump=0.12, trim=True,
                           emission=(0.70, 0.010, 0.430), emission_strength=0.18)
    MATS["trim_blue"] = surface("Faction Blue", (0.150, 0.420, 0.930), 0.18, 0.44,
                                dirt=0.22, bump=0.12, trim=True,
                                emission=(0.10, 0.30, 0.80), emission_strength=0.12)
    MATS["cyan"] = surface("Vent Glow", (0.020, 0.470, 0.430), 0.10, 0.30,
                           dirt=0.10, bump=0.10,
                           emission=(0.030, 1.000, 0.850), emission_strength=2.6)
    MATS["amber"] = surface("Status Lamp", (0.600, 0.230, 0.030), 0.05, 0.35,
                            dirt=0.10, bump=0.10,
                            emission=(1.000, 0.330, 0.030), emission_strength=3.4)
    MATS["fire"] = surface("Burning Wreck", (0.640, 0.190, 0.025), 0.0, 0.70,
                           dirt=0.10, bump=0.10,
                           emission=(1.000, 0.240, 0.015), emission_strength=2.2)
    MATS["scorch"] = surface("Scorched Plate", (0.045, 0.040, 0.036), 0.10, 0.92,
                             dirt=0.20, bump=0.30)


# --------------------------------------------------------------- primitives


def finish(obj, mat, bevel=0.008, smooth=False):
    obj["sandwar_model"] = True
    obj.data.materials.append(mat)
    if smooth:
        for poly in obj.data.polygons:
            poly.use_smooth = True
        try:
            obj.data.use_auto_smooth = True
            obj.data.auto_smooth_angle = math.radians(38.0)
        except AttributeError:
            pass
    if bevel > 0.0:
        mod = obj.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        mod.limit_method = "ANGLE"
        mod.angle_limit = math.radians(40.0)
        mod.harden_normals = False
    return obj


def box(size, loc, mat, rot=(0.0, 0.0, 0.0), bevel=0.008, smooth=False):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc, rotation=rot)
    obj = bpy.context.object
    obj.name = "Box"
    obj.scale = (size[0] * 0.5, size[1] * 0.5, size[2] * 0.5)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(obj, mat, bevel, smooth)


def cyl(radius, depth, loc, mat, *, axis="Z", verts=24, bevel=0.006, smooth=True):
    rot = (0.0, 0.0, 0.0)
    if axis == "Y":
        rot = (math.radians(90.0), 0.0, 0.0)
    elif axis == "X":
        rot = (0.0, math.radians(90.0), 0.0)
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth,
                                        location=loc, rotation=rot)
    obj = bpy.context.object
    obj.name = "Cylinder"
    return finish(obj, mat, bevel, smooth)


def cone(r1, r2, depth, loc, mat, *, verts=8, bevel=0.008, smooth=False):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2,
                                    depth=depth, location=loc)
    obj = bpy.context.object
    obj.name = "Cone"
    return finish(obj, mat, bevel, smooth)


def sphere(radius, loc, mat, scale=(1.0, 1.0, 1.0), segments=24, rings=12):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings,
                                         radius=radius, location=loc)
    obj = bpy.context.object
    obj.name = "Sphere"
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(obj, mat, 0.0, True)


def torus(major, minor, loc, mat, *, axis="Y", segments=32):
    rot = (math.radians(90.0), 0.0, 0.0) if axis == "Y" else (0.0, 0.0, 0.0)
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor,
                                     major_segments=segments, minor_segments=7,
                                     location=loc, rotation=rot)
    obj = bpy.context.object
    obj.name = "Torus"
    return finish(obj, mat, 0.0, True)


def pipe(a, b, radius, mat, verts=12):
    a, b = Vector(a), Vector(b)
    mid = (a + b) * 0.5
    direction = b - a
    length = direction.length
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius,
                                        depth=max(length, 0.001), location=mid)
    obj = bpy.context.object
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    return finish(obj, mat, 0.004, True)


def bolt(loc, mat, radius=0.017, depth=0.024, axis="Z"):
    return cyl(radius, depth, loc, mat, axis=axis, verts=6, bevel=0.003)


def bolts_line(a, b, count, mat, radius=0.016):
    a, b = Vector(a), Vector(b)
    for i in range(count):
        t = (i + 0.5) / float(count)
        bolt(a.lerp(b, t), mat, radius)


def sand_drift(loc, radius, mat, squash=0.22):
    return sphere(radius, loc, mat, scale=(1.0, 0.78, squash), segments=20, rings=8)


# -------------------------------------------------------------------- lights


def build_stage() -> None:
    world = bpy.data.worlds.new("Arrakis")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    # Warm dusty ochre sky bounce. Film is transparent, so this only lights.
    bg.inputs["Color"].default_value = (0.330, 0.245, 0.165, 1.0)
    bg.inputs["Strength"].default_value = 0.78
    bpy.context.scene.world = world

    sun_data = bpy.data.lights.new("Desert Sun", "SUN")
    sun_data.energy = 2.4
    sun_data.angle = math.radians(1.2)
    sun_data.color = (1.0, 0.950, 0.860)
    sun = bpy.data.objects.new("Desert Sun", sun_data)
    sun.rotation_euler = Vector((0.40, 0.46, -0.79)).to_track_quat("-Z", "Y").to_euler()
    link(sun)

    fill_data = bpy.data.lights.new("Warm Bounce", "AREA")
    fill_data.energy = 340.0
    fill_data.color = (1.0, 0.945, 0.870)
    fill_data.size = 9.0
    fill_data.use_shadow = False
    fill = bpy.data.objects.new("Warm Bounce", fill_data)
    fill.location = (0.8, 6.8, 3.4)
    fill.rotation_euler = Vector((0.0, 0.0, -1.0)).to_track_quat("-Z", "Y").to_euler()
    # Point the area lamp back at the model origin.
    fill.rotation_euler = (Vector((0.0, 0.0, 0.7)) - fill.location).to_track_quat("-Z", "Y").to_euler()
    link(fill)

    rim_data = bpy.data.lights.new("Cool Rim", "AREA")
    rim_data.energy = 170.0
    rim_data.color = (0.56, 0.66, 0.82)
    rim_data.size = 5.0
    rim_data.use_shadow = False
    rim = bpy.data.objects.new("Cool Rim", rim_data)
    rim.location = (-3.6, -2.4, 4.2)
    rim.rotation_euler = (Vector((0.0, 0.0, 1.0)) - rim.location).to_track_quat("-Z", "Y").to_euler()
    link(rim)

    cam_data = bpy.data.cameras.new("South Camera")
    cam_data.type = "ORTHO"
    cam_data.clip_start = 0.05
    cam_data.clip_end = 80.0
    cam = bpy.data.objects.new("South Camera", cam_data)
    link(cam)
    bpy.context.scene.camera = cam

    # No ground plane: the sprite gets a controlled drop shadow in post so the
    # contact shadow can never bleed past the sprite cell and tile-seam.



def aim_camera(span: int) -> None:
    cam = bpy.context.scene.camera
    size = max(span * 1.38 + 1.30, 2.55)
    cam.data.ortho_scale = size
    target = Vector((0.0, 0.0, 0.70))
    dist = 7.5
    cam.location = target + Vector((0.0, dist, dist * math.tan(math.radians(50.0))))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()


# ---------------------------------------------------------------- construction


def add_foundation(span: int, damaged: bool) -> None:
    sx = sz = float(span)
    box((sx - 0.035, sz - 0.035, 0.11), (0, 0, 0.045), MATS["black"], bevel=0.010)
    box((sx - 0.15, sz - 0.15, 0.17), (0, 0, 0.125), MATS["pad"], bevel=0.020)
    box((sx - 0.27, sz - 0.27, 0.07), (0, 0, 0.235), MATS["pad_light"], bevel=0.012)
    # Guilt-edged hazard plates and expansion joints, square to the grid.
    for side in (-1.0, 1.0):
        box((0.30, 0.14, 0.026), (side * (sx * 0.5 - 0.52), sz * 0.5 - 0.17, 0.272),
            MATS["rust"], bevel=0.004)
    for i in range(3):
        box((0.30, 0.014, 0.006), (-sx * 0.24 + i * sx * 0.24, sz * 0.20 + i * 0.06, 0.2735),
            MATS["black"], bevel=0.001)
    # Wind-piled sand along the northern and eastern skirt.
    for i, x in enumerate((-sx * 0.30, -sx * 0.05, sx * 0.22)):
        sand_drift((x, -sz * 0.47, 0.14), 0.21 - i * 0.025, MATS["sand"], 0.13)
    sand_drift((sx * 0.46, sz * 0.12, 0.13), 0.18, MATS["sand"], 0.12)


def add_deck_crater(x, y, radius, damaged: bool) -> None:
    cyl(radius, 0.006, (x, y, 0.276), MATS["scorch"], verts=20, bevel=0.0)
    cyl(radius * 0.62, 0.005, (x + 0.02, y - 0.01, 0.281), MATS["black"], verts=18, bevel=0.0)
    if damaged:
        for i in range(3):
            ang = i * 2.1 + x * 3.0
            box((0.07, 0.05, 0.045),
                (x + math.cos(ang) * radius * 0.9, y + math.sin(ang) * radius * 0.9, 0.295),
                MATS["rust"], rot=(0.3, 0.2, ang), bevel=0.008)


def add_window(x, y, z, width, mat, facing="S"):
    w = width
    box((w + 0.05, 0.035, 0.10), (x, y, z), MATS["black"], bevel=0.006)
    box((w, 0.012, 0.042), (x, y + 0.024, z), mat, bevel=0.002)
    box((w + 0.07, 0.02, 0.018), (x, y + 0.006, z + 0.068), MATS["steel_light"], bevel=0.003)


def louver_bank(center, width, height, count, mat_frame, mat_slats):
    x, y, z = center
    box((width + 0.06, 0.05, height + 0.05), (x, y + 0.01, z), MATS["black"], bevel=0.006)
    for i in range(count):
        zz = z - height * 0.5 + (i + 0.5) * height / float(count)
        box((width * (0.94 - 0.03 * abs(i - count * 0.5)), 0.018, height / float(count) * 0.52),
            (x, y + 0.040, zz), mat_slats, rot=(math.radians(-26.0), 0.0, 0.0), bevel=0.003)
    for side in (-1.0, 1.0):
        box((0.03, 0.055, height + 0.06), (x + side * width * 0.52, y + 0.012, z),
            mat_frame, bevel=0.004)


def build_cy(damaged: bool):
    mats = MATS
    anim = []
    add_foundation(3, damaged)

    # Recessed assembly square with rails and a magenta edge on the front deck.
    box((1.22, 0.80, 0.055), (0.0, 0.60, 0.282), mats["black"], bevel=0.010)
    box((1.04, 0.64, 0.035), (0.0, 0.60, 0.302), mats["grill"], bevel=0.006)
    for i in range(4):
        box((0.92, 0.014, 0.014), (0.0, 0.385 + i * 0.145, 0.318), mats["steel_light"], bevel=0.002)
    for sx in (-1.0, 1.0):
        box((0.035, 0.62, 0.020), (sx * 0.45, 0.60, 0.320), mats["trim"], bevel=0.003)

    # Four chamfered armour towers with steel caps and magenta ID straps.
    for cx, cy in ((-1.02, -0.90), (1.02, -0.90), (-1.02, 0.90), (1.02, 0.90)):
        box((0.44, 0.44, 0.16), (cx, cy, 0.355), mats["steel"], bevel=0.020)
        box((0.345, 0.345, 0.78), (cx, cy, 0.80), mats["armor"], bevel=0.026)
        box((0.405, 0.405, 0.065), (cx, cy, 1.215), mats["steel_light"], bevel=0.010)
        box((0.19, 0.020, 0.065), (cx, cy + 0.178, 1.055), mats["black"], bevel=0.003)
        if not damaged:
            cyl(0.024, 0.035, (cx, cy + 0.20, 1.30), mats["amber"], verts=8, bevel=0.0)
        else:
            box((0.10, 0.10, 0.06), (cx + 0.18, cy + 0.14, 0.30), mats["rust"],
                rot=(0.3, 0.1, 0.6), bevel=0.01)

    # Central command keep: chamfered plinth, tall bone-coloured drum.
    box((1.58, 1.46, 0.30), (0.0, -0.18, 0.66), mats["pad_light"], bevel=0.022)
    # Rectangular armoured keep with a stepped command deck.
    box((1.44, 1.32, 0.92), (0.0, -0.18, 1.24), mats["armor"], bevel=0.026)
    for i in range(4):
        box((0.032, 0.030, 0.86), (-0.51 + i * 0.34, 0.492, 1.24),
            mats["steel_light"], bevel=0.003)
    box((1.50, 1.38, 0.090), (0.0, -0.18, 1.740), mats["steel_light"], bevel=0.008)
    box((1.52, 1.40, 0.028), (0.0, -0.18, 1.690), mats["trim"], bevel=0.002)
    box((1.02, 0.96, 0.380), (0.0, -0.18, 1.945), mats["armor_light"], bevel=0.020)
    box((1.08, 1.02, 0.060), (0.0, -0.18, 2.155), mats["steel_light"], bevel=0.006)
    box((0.54, 0.46, 0.300), (0.0, -0.22, 2.315), mats["armor"], bevel=0.014)
    box((0.58, 0.50, 0.045), (0.0, -0.22, 2.480), mats["trim"], bevel=0.004)
    # Keep windows and the magenta command plaque.
    add_window(-0.30, 0.492, 1.32, 0.28, mats["cyan"])
    add_window(0.10, 0.492, 1.32, 0.22, mats["cyan"])
    add_window(-0.12, 0.022, 2.33, 0.24, mats["cyan"])
    box((1.30, 0.030, 0.095), (0.0, 0.500, 0.845), mats["trim"], bevel=0.004)
    box((0.46, 0.030, 0.30), (0.0, 0.500, 1.02), mats["trim"], bevel=0.004)
    box((0.20, 0.014, 0.09), (0.0, 0.518, 1.02), mats["steel_light"], bevel=0.002)
    # Roof machinery: vents, pipes, radar and a catwalk rail.
    louver_bank((-0.30, -0.40, 2.185), 0.28, 0.14, 4, mats["steel_light"], mats["black"])
    louver_bank((0.30, -0.10, 2.185), 0.24, 0.12, 4, mats["steel_light"], mats["black"])
    for i in range(3):
        pipe((-0.46, 0.06 + i * 0.11, 2.185), (0.12, 0.06 + i * 0.11, 2.185), 0.020,
             mats["rust" if i == 1 else "steel_light"])
    cyl(0.150, 0.060, (0.36, 0.22, 2.185), mats["steel_light"], verts=16, bevel=0.005)
    pipe((0.36, 0.22, 2.185), (0.36, 0.22, 2.350), 0.018, mats["steel"])
    cyl(0.220, 0.025, (0.36, 0.22, 2.365), mats["steel_light"], verts=16, bevel=0.003)
    for i, (x, y) in enumerate(((-0.44, 0.28), (0.44, -0.30), (0.06, 0.34))):
        box((0.15, 0.13, 0.10), (x, y, 2.195), mats["steel"], rot=(0.0, 0.0, 0.3 * i),
            bevel=0.007)
    # Roof antenna and beacon.
    cyl(0.020, 0.62, (0.20, -0.32, 2.760), mats["steel_light"], verts=8, bevel=0.002)
    for i in range(2):
        box((0.26 - i * 0.08, 0.014, 0.014), (0.20, -0.32, 2.80 + i * 0.10),
            mats["rust"], bevel=0.002)
    cyl(0.030, 0.028, (0.20, -0.32, 3.080), mats["amber"], verts=8, bevel=0.0)
    bolts_line((-0.70, 0.512, 1.62), (0.70, 0.512, 1.62), 8, mats["steel_light"], 0.014)
    # Armoured buttresses tie the keep to the plinth.
    for side in (-1.0, 1.0):
        box((0.16, 0.50, 0.44), (side * 0.58, 0.10, 0.80), mats["armor"],
            rot=(0.0, 0.0, side * 10.0), bevel=0.012)

    # Side turbine pods with recessed grilles and magenta guard bands.
    for sx in (-1.0, 1.0):
        cyl(0.245, 0.54, (sx * 0.83, 0.26, 0.70), mats["steel"], axis="Y", verts=20, bevel=0.010)
        cyl(0.180, 0.045, (sx * 0.83, 0.555, 0.70), mats["grill"], axis="Y", verts=20, bevel=0.005)
        louver_bank((sx * 0.83, 0.575, 0.70), 0.28, 0.26, 4, mats["steel_light"], mats["black"])
        torus(0.245, 0.016, (sx * 0.83, 0.44, 0.70), mats["steel_light"])
        torus(0.245, 0.016, (sx * 0.83, 0.12, 0.70), mats["steel_light"])
        box((0.20, 0.56, 0.07), (sx * 0.83, 0.26, 0.955), mats["steel_light"], bevel=0.006)
        for i in range(4):
            bolt((sx * 0.83, 0.555, 0.70 + (i - 1.5) * 0.09), mats["steel_light"],
                 0.012, 0.015, axis="Y")

    # Service crane on the east edge: a tall mast and a jib that reaches south
    # over the front deck, deliberately clear of the keep roof.
    box((0.155, 0.155, 2.48), (1.00, -0.68, 1.82), mats["steel_light"], bevel=0.008)
    for zz in (1.05, 1.72, 2.39):
        box((0.26, 0.26, 0.045), (1.00, -0.68, zz), mats["steel"], bevel=0.004)
    box((0.26, 0.26, 0.11), (1.00, -0.68, 3.075), mats["steel_light"], bevel=0.008)
    pivot = bpy.data.objects.new("CranePivot", None)
    pivot.location = (1.00, -0.68, 3.06)
    link(pivot)
    pivot["sandwar_model"] = True
    jib = box((1.70, 0.170, 0.150), (0.18, -0.68, 3.06), mats["steel_light"], bevel=0.008)
    jib.parent = pivot
    jib.matrix_parent_inverse = pivot.matrix_world.inverted()
    trim_jib = box((1.20, 0.030, 0.028), (0.22, -0.68, 3.145), mats["steel_light"], bevel=0.004)
    trim_jib.parent = pivot
    trim_jib.matrix_parent_inverse = pivot.matrix_world.inverted()
    cable = pipe((-0.55, -0.68, 3.06), (-0.55, -0.68, 1.42), 0.009, mats["black"])
    cable.parent = pivot
    cable.matrix_parent_inverse = pivot.matrix_world.inverted()
    hook = box((0.14, 0.13, 0.16), (-0.55, -0.68, 1.34), mats["trim"], bevel=0.008)
    hook.parent = pivot
    hook.matrix_parent_inverse = pivot.matrix_world.inverted()
    box((0.09, 0.09, 0.11), (-0.55, -0.68, 1.23), mats["black"], bevel=0.006)
    box((0.28, 0.30, 0.20), (1.28, -0.68, 3.00), mats["steel"], bevel=0.010)
    for i in range(4):
        box((0.46, 0.020, 0.020), (0.62 - i * 0.28, -0.68, 3.06),
            mats["steel"], rot=(0.0, 0.0, 0.35), bevel=0.002)
    box((0.010, 0.010, 0.44), (0.86, -0.68, 2.55), mats["steel"], bevel=0.002)
    anim.append({"obj": pivot, "kind": "crane"})
    if damaged:
        pivot.rotation_euler = (math.radians(26.0), 0.0, math.radians(-6.0))

    # Roof vents, radar drum and antenna.
    louver_bank((-0.46, -0.03, 1.90), 0.30, 0.13, 4, mats["steel_light"], mats["black"])
    cyl(0.170, 0.060, (-0.22, -0.30, 1.93), mats["steel_light"], verts=20, bevel=0.006)
    pipe((-0.22, -0.30, 1.93), (-0.22, -0.30, 2.04), 0.020, mats["steel"])
    cyl(0.22, 0.028, (-0.22, -0.30, 2.05), mats["steel_light"], verts=20, bevel=0.004)
    cyl(0.020, 0.62, (-0.52, -0.62, 2.22), mats["steel_light"], verts=8, bevel=0.002)
    for i in range(2):
        box((0.30 - i * 0.09, 0.016, 0.016), (-0.52, -0.62, 2.26 + i * 0.10),
            mats["rust"], bevel=0.002)
    cyl(0.034, 0.030, (-0.52, -0.62, 2.55), mats["amber"], verts=8, bevel=0.0)

    # Front trim banner and guard rail.
    box((0.50, 0.030, 0.30), (0.0, 0.965, 0.70), mats["trim"], bevel=0.006)
    box((0.56, 0.045, 0.035), (0.0, 0.965, 0.86), mats["steel_light"], bevel=0.004)

    # Bolted seams on the deck front and sides.
    bolts_line((-1.02, 1.02, 0.29), (1.02, 1.02, 0.29), 9, mats["steel_light"])
    bolts_line((-1.16, -1.0, 0.29), (-1.16, 1.0, 0.29), 7, mats["steel_light"])
    bolts_line((1.16, -1.0, 0.29), (1.16, 1.0, 0.29), 7, mats["steel_light"])

    if damaged:
        box((1.18, 0.74, 0.008), (0.0, 0.60, 0.286), mats["scorch"], bevel=0.002)
        cyl(0.34, 0.008, (-0.14, -0.30, 2.165), mats["scorch"], verts=18, bevel=0.0)
        box((0.22, 0.16, 0.09), (0.24, -0.52, 2.09), mats["rust"], rot=(0.2, 0.3, 0.6), bevel=0.008)
        add_deck_crater(-1.06, 0.94, 0.22, True)
        add_deck_crater(1.04, 0.42, 0.18, True)
        add_deck_crater(-0.62, 1.12, 0.15, True)
        add_deck_crater(0.28, 0.28, 0.12, False)
        # Burnt scoring down the south face of the keep.
        for i, (x, z) in enumerate(((-0.30, 1.30), (0.06, 1.05), (0.30, 1.62))):
            box((0.26 - i * 0.03, 0.020, 0.54 - i * 0.08), (x, 0.498, z),
                mats["scorch"], bevel=0.003)
        for i, (x, y) in enumerate(((-0.92, 0.62), (0.72, 0.98), (0.30, 0.92), (-0.72, 0.14))):
            box((0.16 + i * 0.02, 0.12, 0.10 + i * 0.015), (x, y, 0.34),
                mats["rust"], rot=(0.2 * i, 0.15, 0.7 * i), bevel=0.010)
            box((0.11, 0.09, 0.07), (x + 0.13, y + 0.05, 0.31),
                mats["steel"], rot=(0.1, 0.4, -0.4 - i), bevel=0.008)
        # A broken pylon cap and a bent guard rail.
        box((0.34, 0.30, 0.10), (-1.02, 0.72, 1.19), mats["rust"], rot=(0.3, 0.0, 0.5), bevel=0.008)
        box((0.30, 0.09, 0.07), (-0.35, 0.80, 0.35), mats["steel"],
            rot=(0.1, 0.0, 0.9), bevel=0.006)
        for k in range(3):
            fire = sphere(0.075 + 0.018 * k, (0.14 - k * 0.33, 0.66 + k * 0.10, 0.40 + k * 0.05),
                          mats["fire"], segments=14, rings=8)
            anim.append({"obj": fire, "kind": "fire", "phase": k * 1.7})
    else:
        anim.append({"obj": cyl(0.030, 0.028, (0.0, 1.02, 0.34), mats["amber"], verts=8, bevel=0.0),
                     "kind": "lamp"})
    return anim


def build_windtrap(damaged: bool):
    mats = MATS
    anim = []
    add_foundation(2, damaged)
    box((1.80, 1.82, 0.36), (0.0, 0.0, 0.40), mats["pad_light"], bevel=0.028)
    box((1.64, 1.68, 0.08), (0.0, 0.0, 0.60), mats["steel_light"], bevel=0.012)
    box((1.10, 0.035, 0.05), (0.0, 0.885, 0.63), mats["trim"], bevel=0.004)
    for sx in (-0.43, 0.43):
        box((0.20, 0.024, 0.30), (sx, 0.835, 0.50), mats["trim"], bevel=0.004)

    for index, sx in enumerate((-0.43, 0.43)):
        # Curved nacelle shell, rounded condenser cap and intake cowl.
        cyl(0.385, 1.36, (sx, 0.02, 1.08), mats["armor"], axis="Y", verts=32, bevel=0.012)
        sphere(0.380, (sx, -0.66, 1.08), mats["armor"], scale=(1.0, 0.72, 1.0))
        cyl(0.405, 0.085, (sx, 0.715, 1.08), mats["steel_light"], axis="Y", verts=32, bevel=0.008)
        cyl(0.345, 0.045, (sx, 0.760, 1.08), mats["black"], axis="Y", verts=32, bevel=0.004)
        cyl(0.300, 0.030, (sx, 0.735, 1.08), mats["grill"], axis="Y", verts=32, bevel=0.003)
        torus(0.340, 0.014, (sx, 0.782, 1.08), mats["steel_light"], segments=36)
        # Spinning fan disk behind a cyan louver bank.
        fan = bpy.data.objects.new("FanPivot", None)
        fan.location = (sx, 0.755, 1.08)
        link(fan)
        fan["sandwar_model"] = True
        for blade in range(6):
            ang = math.tau * blade / 6.0
            b = box((0.055, 0.012, 0.255),
                    (sx + math.sin(ang) * 0.145, 0.755, 1.08 + math.cos(ang) * 0.145),
                    mats["steel"], rot=(0.0, ang, 0.0), bevel=0.004)
            b.parent = fan
            b.matrix_parent_inverse = fan.matrix_world.inverted()
        cyl(0.045, 0.030, (sx, 0.760, 1.08), mats["steel_light"], axis="Y", verts=12, bevel=0.003)
        if not (damaged and index == 1):
            for k in range(5):
                width = 0.53 - abs(k - 2) * 0.085
                box((width, 0.035, 0.036), (sx, 0.790, 0.875 + k * 0.102), mats["cyan"],
                    rot=(math.radians(-18.0), 0.0, 0.0), bevel=0.004)
        else:
            box((0.52, 0.045, 0.34), (sx, 0.775, 1.05), mats["black"], bevel=0.004)
            box((0.20, 0.060, 0.16), (sx + 0.12, 0.800, 1.18), mats["rust"],
                rot=(0.2, 0.4, 0.7), bevel=0.006)
            box((0.13, 0.050, 0.28), (sx - 0.16, 0.795, 0.90), mats["steel"],
                rot=(0.4, 0.2, -0.5), bevel=0.005)
        for side in (-1.0, 1.0):
            box((0.035, 0.060, 0.52), (sx + side * 0.305, 0.775, 1.08),
                mats["steel_light"], bevel=0.004)
        # Ribbed service collars and dorsal fin.
        cyl(0.398, 0.050, (sx, 0.24, 1.08), mats["steel_light"], axis="Y", verts=32, bevel=0.006)
        cyl(0.398, 0.035, (sx, -0.28, 1.08), mats["steel"], axis="Y", verts=32, bevel=0.005)
        box((0.026, 0.52, 0.135), (sx, -0.14, 1.425), mats["steel_light"],
            rot=(math.radians(-8.0), 0.0, 0.0), bevel=0.005)
        box((0.032, 0.20, 0.052), (sx, -0.32, 1.49), mats["trim"],
            rot=(math.radians(-8.0), 0.0, 0.0), bevel=0.004)
        box((0.30, 0.36, 0.10), (sx, 0.34, 0.79), mats["steel"], bevel=0.008)
        for zz in (-0.22, 0.34):
            box((0.10, 0.17, 0.27), (sx + (0.34 if sx > 0 else -0.34), zz, 0.64),
                mats["steel_light"], bevel=0.008)
        bolt((sx + 0.19, 0.50, 1.40), mats["amber"], 0.024, 0.028)
        bolts_line((sx - 0.22, 0.72, 0.885), (sx + 0.22, 0.72, 0.885), 4,
                   mats["steel_light"], 0.012)
        anim.append({"obj": fan, "kind": "fan", "speed": 1.0 + index * 0.18})
        if damaged and index == 1:
            # Shattered intake: exposed dark cavity and torn trim.
            cyl(0.30, 0.022, (sx, 0.800, 1.08), mats["black"], axis="Y", verts=20, bevel=0.0)
            box((0.16, 0.05, 0.22), (sx - 0.10, 0.815, 1.02), mats["rust"],
                rot=(0.2, 0.3, 0.5), bevel=0.008)

    # Central spine, condenser and pipework.
    box((0.50, 1.36, 0.20), (0.0, -0.10, 0.66), mats["steel"], bevel=0.010)
    box((0.40, 0.05, 0.045), (0.0, 0.48, 0.60), mats["trim"], bevel=0.004)
    for i in range(3):
        box((0.40, 0.035, 0.035), (0.0, 0.47, 0.52 + i * 0.10), mats["steel_light"], bevel=0.004)
    cyl(0.175, 0.16, (0.0, -0.82, 1.30), mats["steel_light"], verts=20, bevel=0.008)
    pipe((0.0, -0.80, 0.55), (0.0, -0.80, 1.18), 0.075, mats["steel_light"])
    pipe((0.0, -0.80, 1.18), (0.0, -0.30, 1.18), 0.062, mats["rust"])
    cyl(0.115, 0.045, (0.0, -0.80, 1.42), mats["cyan"], verts=16, bevel=0.004)
    box((1.42, 0.11, 0.055), (0.0, 0.87, 0.56), mats["steel"], bevel=0.006)
    box((0.38, 0.035, 0.085), (0.0, 0.90, 0.61), mats["trim"], bevel=0.005)
    box((0.92, 0.22, 0.045), (0.0, -0.92, 0.545), mats["pad"], bevel=0.006)
    louver_bank((0.60, -0.86, 0.66), 0.22, 0.16, 4, mats["steel_light"], mats["black"])
    for x in (-0.22, 0.22):
        pipe((x, -0.72, 0.58), (x, -0.72, 1.00), 0.028, mats["steel_light"])
        bolt((x, -0.72, 1.03), mats["steel_light"], 0.020, 0.018)
    bolts_line((-0.72, 0.995, 0.565), (0.72, 0.995, 0.565), 10, mats["steel_light"], 0.013)
    for sx in (-1.0, 1.0):
        sand_drift((sx * 0.78, 0.62, 0.22), 0.26, mats["sand"])
        sand_drift((sx * 0.55, -0.86, 0.20), 0.20, mats["sand"])
    sand_drift((0.0, 0.98, 0.22), 0.30, mats["sand"])

    if damaged:
        add_deck_crater(-1.02, 0.70, 0.22, True)
        add_deck_crater(1.00, 0.72, 0.18, True)
        add_deck_crater(0.02, -0.92, 0.16, True)
        cyl(0.20, 0.006, (-0.43, 0.15, 1.475), mats["scorch"], verts=16, bevel=0.0)
        cyl(0.13, 0.006, (-0.10, -0.30, 0.62), mats["scorch"], verts=14, bevel=0.0)
        box((0.34, 0.05, 0.14), (0.43, -0.10, 1.52), mats["steel"],
            rot=(0.6, 0.0, 0.35), bevel=0.006)
        for i, (x, y) in enumerate(((-0.90, 0.62), (0.86, 0.02), (-0.10, 0.84))):
            box((0.15, 0.12, 0.09), (x, y, 0.335), mats["rust"],
            rot=(0.3 * i, 0.2, 0.5 * i), bevel=0.008)
        for k in range(2):
            fire = sphere(0.060 + 0.014 * k, (0.43, 0.80, 0.98 - k * 0.22),
                          mats["fire"], segments=12, rings=6)
            anim.append({"obj": fire, "kind": "fire", "phase": k * 2.1})
    else:
        anim.append({"obj": cyl(0.032, 0.030, (0.0, 0.995, 0.335), mats["amber"], verts=8, bevel=0.0),
                     "kind": "lamp"})
    return anim


# ------------------------------------------------------------------ rendering


def render_frames(building: str, damaged: bool, anim: list) -> None:
    span = SPECS[building]["span"]
    cell = span * TILE + MARGIN * 2
    aim_camera(span)
    scene = bpy.context.scene
    scene.render.resolution_x = cell * RES_SCALE
    scene.render.resolution_y = cell * RES_SCALE
    out_dir = FRAME_DIR / building
    out_dir.mkdir(parents=True, exist_ok=True)
    row = 1 if damaged else 0
    for frame in range(FRAMES):
        phase = frame / float(FRAMES)
        for entry in anim:
            obj = entry["obj"]
            kind = entry["kind"]
            if kind == "crane":
                obj.rotation_euler.z = math.sin(phase * math.tau) * math.radians(2.6)
            elif kind == "fan":
                obj.rotation_euler = (0.0, phase * math.tau + entry.get("speed", 1.0) * math.tau,
                                      0.0)
            elif kind == "fire":
                flick = 0.78 + 0.34 * abs(math.sin(phase * math.tau + entry.get("phase", 0.0)))
                obj.scale = (flick, flick, flick * 0.8)
            elif kind == "lamp":
                pulse = 0.82 + 0.18 * abs(math.sin(phase * math.tau + 0.6))
                obj.scale = (pulse, pulse, pulse)
        path = out_dir / ("r%d_f%d.png" % (row, frame))
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True)
        print("RENDERED %s row=%d frame=%d -> %s" % (building, row, frame, path), flush=True)


def render_icon(building: str) -> Path:
    span = SPECS[building]["span"]
    cell = span * TILE + MARGIN * 2
    scene = bpy.context.scene
    scene.render.resolution_x = cell * RES_SCALE
    scene.render.resolution_y = cell * RES_SCALE
    for obj in bpy.data.objects:
        if not obj.get("sandwar_model") or not obj.data or not obj.data.materials:
            continue
        for slot in obj.material_slots:
            if slot.material == MATS["trim"]:
                slot.material = MATS["trim_blue"]
    scene.render.filepath = str(FRAME_DIR / building / "icon.png")
    bpy.ops.render.render(write_still=True)
    return Path(scene.render.filepath)


# ------------------------------------------------------------- post assembly


def alpha_bbox(img: Image.Image, threshold: int = 8):
    alpha = np.asarray(img.getchannel("A"))
    ys, xs = np.where(alpha > threshold)
    if len(xs) == 0:
        return None
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)


def with_drop_shadow(img: Image.Image, offset=(7, 9), blur=4.0, alpha=0.42) -> Image.Image:
    """Soft NW-key contact shadow, kept inside the cell (no tile-edge bleed)."""
    silhouette = Image.new("L", img.size, 0)
    silhouette.paste(img.getchannel("A"), offset)
    silhouette = silhouette.filter(ImageFilter.GaussianBlur(blur))
    silhouette = silhouette.point(lambda v: int(v * alpha))
    shadow = Image.new("RGBA", img.size, (18, 14, 10, 0))
    shadow.putalpha(silhouette)
    return Image.alpha_composite(shadow, img)


def premultiplied_resize(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Resize RGBA with alpha-aware filtering (no dark fringes)."""
    arr = np.asarray(img.convert("RGBA"), dtype=np.float32)
    alpha = arr[..., 3] / 255.0
    pm = np.empty_like(arr)
    pm[..., :3] = arr[..., :3] * alpha[..., None]
    pm[..., 3] = arr[..., 3]
    small = Image.fromarray(np.clip(pm, 0, 255).astype(np.uint8), "RGBA").resize(
        size, Image.Resampling.LANCZOS)
    out = np.asarray(small, dtype=np.float32)
    a = np.clip(out[..., 3] / 255.0, 0.0, 1.0)
    rgb = np.zeros_like(out[..., :3])
    safe = a > 1.0e-4
    rgb[safe] = out[..., :3][safe] / a[safe][..., None]
    result = np.dstack([np.clip(rgb, 0, 255), out[..., 3]])
    return Image.fromarray(result.astype(np.uint8), "RGBA")


def assemble_sheet(building: str) -> Path:
    span = SPECS[building]["span"]
    cell = span * TILE + MARGIN * 2
    sheet = Image.new("RGBA", (cell * FRAMES, cell * 2), (0, 0, 0, 0))
    frame_dir = FRAME_DIR / building
    used_top = None
    for row in (0, 1):
        for frame in range(FRAMES):
            raw = Image.open(frame_dir / ("r%d_f%d.png" % (row, frame))).convert("RGBA")
            small = premultiplied_resize(raw, (cell, cell))
            if row == 0 and frame == 0:
                bbox = alpha_bbox(small)
                if bbox is not None:
                    used_top = bbox[1]
            sheet.alpha_composite(with_drop_shadow(small), (frame * cell, row * cell))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / ("%s.png" % building)
    sheet.save(path)
    art_top = (used_top - cell * 0.5) if used_top is not None else -cell * 0.5
    print("SHEET %s %dx%d cell=%d art_top=%.1f" %
          (path, sheet.width, sheet.height, cell, art_top), flush=True)
    return path


def assemble_icon(building: str, icon_render: Path) -> Path:
    cell = SPECS[building]["span"] * TILE + MARGIN * 2
    raw = Image.open(icon_render).convert("RGBA")
    small = premultiplied_resize(raw, (cell * 2, cell * 2))
    bbox = alpha_bbox(small)
    if bbox is None:
        bbox = (0, 0, small.width, small.height)
    crop = small.crop(bbox)
    scale = min(60.0 / max(crop.width, 1), 60.0 / max(crop.height, 1))
    w = max(1, int(round(crop.width * scale)))
    h = max(1, int(round(crop.height * scale)))
    crop = premultiplied_resize(crop, (w, h))
    canvas = np.zeros((ICON_SIZE, ICON_SIZE, 4), dtype=np.float32)
    # Faint cool halo so dark barrels read on the HUD well.
    yy, xx = np.mgrid[0:ICON_SIZE, 0:ICON_SIZE].astype(np.float32)
    dx = (xx - 31.5) / 31.0
    dy = (yy - 32.0) / 31.0
    glow = np.clip(1.0 - np.sqrt(dx * dx + dy * dy * 1.25), 0.0, 1.0)
    canvas[..., 0] = 0.10 * 255.0
    canvas[..., 1] = 0.18 * 255.0
    canvas[..., 2] = 0.23 * 255.0
    canvas[..., 3] = glow * 0.20 * 255.0
    ox = (ICON_SIZE - w) // 2
    oy = max(2, (ICON_SIZE - h) // 2)
    src = np.asarray(crop, dtype=np.float32)
    a = src[..., 3:4] / 255.0
    dst = canvas[oy:oy + h, ox:ox + w]
    dst[..., :3] = src[..., :3] * a + dst[..., :3] * (1.0 - a)
    dst[..., 3:4] = src[..., 3:4] + dst[..., 3:4] * (1.0 - a)
    canvas[oy:oy + h, ox:ox + w] = dst
    icon = Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), "RGBA")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / ("%s_icon.png" % building)
    icon.save(path)
    print("ICON %s 64x64" % path, flush=True)
    return path


# ----------------------------------------------------------------------- main


BUILDERS = {
    "cy": build_cy,
    "refinery": build_refinery,
    "windtrap": build_windtrap,
    "barracks": build_barracks,
    "factory": build_factory,
    "turret": build_turret_base,
    "rocketturret": build_rocket_base,
    "wall": build_wall,
    "slab": build_slab,
}
ICON_BUILDERS = {"turret": build_turret_icon, "rocketturret": build_rocket_icon}


def bake(building: str) -> None:
    span = SPECS[building]["span"]
    print("=== BAKING %s (span %d) ===" % (building, span), flush=True)
    for damaged in (False, True):
        purge_model()
        anim = BUILDERS[building](damaged)
        render_frames(building, damaged, anim)
    # Icon pass: the idle model with blue house trim.
    purge_model()
    ICON_BUILDERS.get(building, BUILDERS[building])(False)
    icon_render = render_icon(building)
    sheet = assemble_sheet(building)
    icon = assemble_icon(building, icon_render)
    if building in HEAD_IDS:
        render_heads(building)
    print("DONE %s -> %s | %s" % (building, sheet, icon), flush=True)


def main() -> None:
    tokens = [part for chunk in args_after_ddash() for part in chunk.split(",") if part]
    blend_only = "blend" in tokens
    selection = [t for t in tokens if t in BUILDERS]
    buildings = selection if selection else list(SPECS)
    reset_scene()
    build_materials()
    build_stage()
    FRAME_DIR.mkdir(parents=True, exist_ok=True)
    if blend_only:
        # Build the idle scene, aim the bake camera, and save a .blend the user
        # can open in the Blender app to inspect the model, nodes and lights.
        for building in buildings:
            purge_model()
            BUILDERS[building](False)
            span = SPECS[building]["span"]
            cell = span * TILE + MARGIN * 2
            aim_camera(span)
            scene = bpy.context.scene
            scene.render.resolution_x = cell * RES_SCALE
            scene.render.resolution_y = cell * RES_SCALE
            path = ROOT / "build" / ("%s_bake.blend" % building)
            bpy.ops.wm.save_as_mainfile(filepath=str(path))
            print("SAVED BLEND %s" % path, flush=True)
        print("BLEND SETUPS COMPLETE", flush=True)
        return
    for building in buildings:
        bake(building)
    print("ALL BAKES COMPLETE", flush=True)


if __name__ == "__main__":
    main()
