"""Headless Blender exporter for Sandwar's Modern 3D GLB assets.

Run:
    blender --background --python tools/export_models_3d.py

The script reuses the exact mesh builders that produce the 2D concept art, so
the Classic and Modern renderers describe the same vehicles and structures.
Every asset is converted to clean, mobile-sized PBR geometry with a weathered
base-colour texture. A single shared material named ``FactionTrim`` is left
untextured so Godot can replace its albedo with the player's House colour.

Outputs:
    assets/models/buildings/*.glb
    assets/models/units/*.glb
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))
# Blender 5.3 ships Python 3.13 without Pillow. The project vendors a matching
# wheel under .tools-venv/blender_py for the headless bake tools; put it on the
# path before importing the builder modules that use PIL.
BLENDER_PY = ROOT / ".tools-venv" / "blender_py"
if BLENDER_PY.exists():
    sys.path.insert(0, str(BLENDER_PY))

import blender_bake_buildings as bb  # noqa: E402
import blender_bake_units as bu  # noqa: E402

BUILDING_DIR = ROOT / "assets" / "models" / "buildings"
UNIT_DIR = ROOT / "assets" / "models" / "units"
TEX_DIR = ROOT / "build" / "models_3d_tex"

# Mobile budgets. Buildings are allowed the larger silhouette; vehicles and
# infantry stay cheap enough for hundreds of draw calls on a phone GPU.
BUILDING_TRI_BUDGET = 7000
VEHICLE_TRI_BUDGET = 2400
INFANTRY_TRI_BUDGET = 1100
# The dozer harvester is the hero economy unit, so it gets extra relief for
# the blade teeth, cab equipment and track grousers.
HARVESTER_TRI_BUDGET = 3600
# The upright Sandworm is a set-piece with more relief than a vehicle: layered
# scutes, crown fangs and the full concentric tooth rings.
WORM_TRI_BUDGET = 6500

TRIM_NAME = "FactionTrim"


def srgb_channel(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return pow(value, 1.0 / 2.2)


TEX_SIZE = 128


def make_weathered_texture(name: str, base: tuple[float, float, float],
                           rust: float = 0.0, dirt: float = 0.4) -> bpy.types.Image:
    """Tileable base-colour grime/weathering map, embedded in the GLB.

    The reference build uses procedural Cycles materials for stills. GLB cannot
    carry those node graphs, so the same palette is baked into a compact colour
    map: warm dust mottling, dark cavity grime, chipped edge highlights and
    sparse rust flecks. The larger 128px source preserves the fine grain after
    the mesh is decimated for the mobile/GL compatibility budget.
    """
    size = TEX_SIZE
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    # Two cheap periodic fields keep the texture seamless enough to avoid
    # obvious repetition across identical structures.
    n1 = (np.sin(xx * 0.39 + yy * 0.21) * np.cos(yy * 0.33 - xx * 0.17) + 1.0) * 0.5
    n2 = (np.sin(xx * 1.11 - yy * 0.73) * np.cos(xx * 0.27 + yy * 0.89) + 1.0) * 0.5
    n3 = (np.sin(xx * 2.37 + yy * 1.03) * np.cos(yy * 2.81 - xx * 1.47) + 1.0) * 0.5
    grain = n1 * 0.52 + n2 * 0.30 + n3 * 0.18
    # Broad stains and a sharper cavity field. The cavity value is used as a
    # cheap baked micro-occlusion rather than a flat dirt tint, so the grime
    # follows creases and recessed plate seams even without a baked AO pass.
    stain = np.clip((np.sin(xx * 0.11 + 0.7) + np.cos(yy * 0.13 - 0.4)) * 0.25 + 0.5, 0, 1)
    cavity = np.clip((n2 - 0.46) * 2.9 + (1.0 - n3) * 0.20, 0.0, 1.0)
    edge = np.clip((n3 - 0.62) * 3.4, 0.0, 1.0) * np.clip((n1 - 0.34) * 3.0, 0.0, 1.0)
    grime = (1.0 - dirt * (0.20 + 0.34 * cavity)) + dirt * 0.20 * grain
    warm = 1.0 - dirt * 0.12 * (1.0 - stain)
    rgb = np.empty((size, size, 4), dtype=np.float32)
    for i in range(3):
        channel = base[i] * grime * warm
        # Chipped edge wear: a warm bone highlight on the highest micro-ridges,
        # strongest on the steel/armour materials and subtle on sand/concrete.
        chip = edge * (0.26 if rust > 0.0 else 0.10)
        channel = channel * (1.0 - chip) + (0.57 + 0.10 * float(i)) * chip
        # Sparse corrosion on steel-like surfaces, with darker oxide cores.
        if rust > 0.0:
            fleck = np.clip((n2 - 0.73) * 4.5, 0.0, 1.0) * rust
            channel = channel * (1.0 - fleck * 0.62) + 0.225 * fleck * 0.62
            channel = channel * (1.0 - cavity * 0.16 * rust)
        rgb[..., i] = np.power(np.clip(channel, 0.0, 1.0), 1.0 / 2.2)
    rgb[..., 3] = 1.0
    image = bpy.data.images.new("Bake_" + name, width=size, height=size, alpha=True)
    image.colorspace_settings.name = "sRGB"
    image.pixels = rgb.ravel().tolist()
    TEX_DIR.mkdir(parents=True, exist_ok=True)
    path = TEX_DIR / (name.replace(" ", "_").replace("/", "_") + ".png")
    image.filepath_raw = str(path)
    image.file_format = "PNG"
    image.save()
    image.pack()
    return image


def make_normal_texture(name: str, base_image: bpy.types.Image,
                        strength: float = 0.26) -> bpy.types.Image:
    """Derive a subtle tangent-space normal map from the baked grain map.

    GLB cannot carry a procedural bump node, so the same height field that
    drives the colour weathering is converted into a normal texture. Strength
    stays low: this is surface micro-relief, not a noisy embossed pattern.
    """
    size = TEX_SIZE
    pixels = np.asarray(base_image.pixels[:], dtype=np.float32).reshape((size, size, 4))
    height = pixels[..., :3].mean(axis=2)
    dx = np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)
    dy = np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)
    nx = -dx * strength
    ny = -dy * strength
    nz = np.ones_like(nx)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    normal = np.stack([nx / length * 0.5 + 0.5,
                       ny / length * 0.5 + 0.5,
                       nz / length * 0.5 + 0.5], axis=2)
    rgba = np.dstack([normal, np.ones((size, size), dtype=np.float32)])
    image = bpy.data.images.new("BakeN_" + name, width=size, height=size, alpha=True)
    image.colorspace_settings.name = "Non-Color"
    image.pixels = rgba.ravel().tolist()
    path = TEX_DIR / ("N_" + name.replace(" ", "_").replace("/", "_") + ".png")
    image.filepath_raw = str(path)
    image.file_format = "PNG"
    image.save()
    image.pack()
    return image


def pbr_material(source: bpy.types.Material) -> bpy.types.Material:
    """Convert a procedural builder material to a glTF-safe Principled one."""
    base = tuple(float(v) for v in source.diffuse_color[:3])
    is_trim = "magenta" in source.name.lower() or "faction" in source.name.lower()
    if is_trim:
        mat = bpy.data.materials.get(TRIM_NAME)
        if mat is None:
            mat = bpy.data.materials.new(TRIM_NAME)
            mat.use_nodes = True
            nt = mat.node_tree
            nt.nodes.clear()
            out = nt.nodes.new("ShaderNodeOutputMaterial")
            bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
            nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
            bsdf.inputs["Base Color"].default_value = (0.88, 0.02, 0.56, 1.0)
            bsdf.inputs["Metallic"].default_value = 0.18
            bsdf.inputs["Roughness"].default_value = 0.44
            bsdf.inputs["Emission Color"].default_value = (0.70, 0.01, 0.43, 1.0)
            bsdf.inputs["Emission Strength"].default_value = 0.12
            mat.diffuse_color = (0.88, 0.02, 0.56, 1.0)
            mat["sandwar_trim"] = True
        return mat

    cached = bpy.data.materials.get("GLB_" + source.name)
    if cached is not None:
        return cached
    metallic = 0.5
    rough = 0.55
    emission = (0.0, 0.0, 0.0)
    emission_strength = 0.0
    if source.use_nodes:
        for node in source.node_tree.nodes:
            if node.type != "BSDF_PRINCIPLED":
                continue
            if node.inputs["Metallic"].is_linked:
                metallic = 0.55
            else:
                metallic = float(node.inputs["Metallic"].default_value)
            if not node.inputs["Roughness"].is_linked:
                rough = float(node.inputs["Roughness"].default_value)
            emission = tuple(float(v) for v in node.inputs["Emission Color"].default_value[:3])
            emission_strength = float(node.inputs["Emission Strength"].default_value)
            break
    rust = 0.35 if "steel" in source.name.lower() or "rust" in source.name.lower() else 0.12
    dirt = 0.58 if any(w in source.name.lower() for w in ("pad", "sand", "armor")) else 0.42
    image = make_weathered_texture(source.name, base, rust=rust, dirt=dirt)
    normal_image = make_normal_texture(source.name, image, strength=0.30 if rust > 0.2 else 0.18)

    mat = bpy.data.materials.new("GLB_" + source.name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    normal_tex = nt.nodes.new("ShaderNodeTexImage")
    normal_tex.image = normal_image
    normal_map = nt.nodes.new("ShaderNodeNormalMap")
    normal_map.inputs["Strength"].default_value = 0.42 if rust > 0.2 else 0.28
    nt.links.new(normal_tex.outputs["Color"], normal_map.inputs["Color"])
    nt.links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = rough
    if emission_strength > 0.0:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = min(emission_strength, 3.0)
    mat.diffuse_color = (*base, 1.0)
    return mat


def trim_detached_pad_debris(name: str, span: int) -> None:
    """Drop small disconnected assemblies that sit outside the foundation.

    A few builders intentionally place service pipes or brackets past the pad
    edge. At the RTS camera those float above open sand because their support
    legs were separate tiny objects. Large intentional appendages (crane jibs,
    fans, tower caps) are kept; only small off-pad islands are removed.
    """
    if name in ("repair_pad", "starport", "slab", "palace"):
        return
    half = float(span) * 0.5 - 0.05
    for obj in list(all_model_meshes()):
        corners = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
        xs = [v.x for v in corners]
        ys = [v.y for v in corners]
        cx = (min(xs) + max(xs)) * 0.5
        cy = (min(ys) + max(ys)) * 0.5
        if (abs(cx) > half or abs(cy) > half) and max(obj.dimensions) < 0.95:
            bpy.data.objects.remove(obj, do_unlink=True)


def add_site_clutter(name: str, span: int) -> None:
    """Dress the open corners of the larger command pads.

    The hand-built structures already carry dense roof machinery, but their
    outer pad corners read empty in the reference. These low, supported props
    are deliberately inside the foundation footprint so they never float: a
    strapped cargo crate, a hazard-striped fuel canister, a short service pipe
    and a little wind-drifted rubble at each corner. Only the 3x3 command pads
    get this treatment; the smaller structures keep their readable silhouettes.
    """
    if span < 3 or name in ("repair_pad", "starport", "slab"):
        return
    mats = bb.MATS
    edge = float(span) * 0.5 - 0.20
    for cx, cy in ((1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)):
        x = cx * edge
        y = cy * edge
        # Cargo crate with a reinforced lid, corner straps and small stencil.
        bb.box((0.30, 0.24, 0.19), (x, y, 0.36), mats["armor"], bevel=0.006)
        bb.box((0.31, 0.25, 0.025), (x, y, 0.46), mats["steel_light"], bevel=0.003)
        bb.box((0.035, 0.25, 0.21), (x - 0.13, y, 0.36), mats["rust"], bevel=0.002)
        bb.box((0.14, 0.012, 0.045), (x + 0.04, y + 0.125, 0.40), mats["yellow"], bevel=0.001)
        # Fuel canister on a low saddle, with dark hazard bands and a cap.
        can_x = x + cx * 0.25
        bb.cyl(0.105, 0.27, (can_x, y - cy * 0.06, 0.385), mats["steel_light"],
               verts=12, bevel=0.004)
        bb.cyl(0.109, 0.018, (can_x, y - cy * 0.06, 0.525), mats["black"],
               verts=12, bevel=0.001)
        bb.cyl(0.072, 0.020, (can_x, y - cy * 0.06, 0.535), mats["rust"],
               verts=10, bevel=0.001)
        for band_z in (0.33, 0.45):
            bb.cyl(0.108, 0.012, (can_x, y - cy * 0.06, band_z), mats["yellow"],
                   verts=12, bevel=0.0)
        # Cable / service line from the canister back toward the pad structure.
        bb.pipe((can_x, y - cy * 0.10, 0.325), (x - cx * 0.38, y, 0.325), 0.013,
                mats["black"], verts=8)
        # Wind-drifted rubble at the footprint edge, small enough to stay below
        # the catwalk sightline but visible from the RTS camera.
        for i, (ox, oy, scale) in enumerate(((0.19, 0.05, 0.075), (0.25, -0.10, 0.055),
                                             (0.12, -0.16, 0.045))):
            bb.box((scale * 1.4, scale, scale * 0.75),
                   (x + ox, y + oy, 0.315), mats["rust" if i == 0 else "steel"],
                   rot=(0.0, 0.0, 0.35 * i), bevel=0.002)


def all_model_meshes() -> list[bpy.types.Object]:
    return [o for o in bpy.data.objects
            if o.get("sandwar_model") and o.type == "MESH"]


def prepare_mesh(budget: int) -> bpy.types.Object:
    """Apply modifiers, join, ground the origin, UV unwrap and decimate."""
    meshes = all_model_meshes()
    if not meshes:
        raise RuntimeError("builder produced no mesh objects")
    # Bolts, rivets and other sub-centimetre greebles are separate little
    # objects in the builders. Decimation collapses the plates beneath them,
    # which leaves the fasteners visibly floating in the 3D view. They are
    # below one screen pixel at the RTS camera, so drop them before joining
    # rather than exporting detached dust.
    kept = []
    for obj in meshes:
        if max(obj.dimensions) < 0.055:
            bpy.data.objects.remove(obj, do_unlink=True)
            continue
        kept.append(obj)
    meshes = kept
    for obj in bpy.data.objects:
        obj.select_set(False)
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    # Empty group roots are retained by the builders; clear parenting first so
    # group rotations and locations are baked into the final world-space mesh.
    bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.object.convert(target="MESH")
    meshes = all_model_meshes()
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = "Sandwar3D"
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # Ground exactly at z=0 and centre X/Y, so Godot's tile mapping stays true.
    bounds = [obj.matrix_world @ v.co for v in obj.data.vertices]
    if bounds:
        min_z = min(v.z for v in bounds)
        cx = (min(v.x for v in bounds) + max(v.x for v in bounds)) * 0.5
        cy = (min(v.y for v in bounds) + max(v.y for v in bounds)) * 0.5
        for v in obj.data.vertices:
            v.co.x -= cx
            v.co.y -= cy
            v.co.z -= min_z
    # Replace Cycles node trees with embedded glTF PBR materials.
    for slot in obj.material_slots:
        if slot.material is not None:
            slot.material = pbr_material(slot.material)
    # A single UV island set is enough: the baked maps are noise, not decals.
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    try:
        bpy.ops.uv.smart_project(angle_limit=math.radians(66.0), island_margin=0.02)
    except TypeError:
        bpy.ops.uv.smart_project()
    bpy.ops.object.mode_set(mode="OBJECT")
    obj.data.update()

    # Decimation is approximate at material boundaries, so iterate until the
    # hard mobile budget is actually met instead of trusting one ratio.
    for _attempt in range(5):
        tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
        if tris <= budget:
            break
        mod = obj.modifiers.new("MobileBudget", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = max(0.05, (float(budget) / float(tris)) * 0.90)
        bpy.ops.object.modifier_apply(modifier=mod.name)
        obj.data.update()
    # glTF can only compute tangents for triangle faces. The bevel modifiers
    # leave a lot of quads behind, so triangulate after decimation (the normal
    # maps are useless without TANGENT data on import).
    ensure_trim_slot(obj)
    # Do this after ensure_trim_slot: its tiny fallback marker is a cube too, and
    # any remaining quad would make the exporter skip tangents for the whole
    # primitive set.
    if any(len(p.vertices) > 3 for p in obj.data.polygons):
        tri = obj.modifiers.new("ExportTriangulate", "TRIANGULATE")
        tri.quad_method = "BEAUTY"
        tri.ngon_method = "BEAUTY"
        bpy.ops.object.modifier_apply(modifier=tri.name)
        obj.data.update()
    return obj


def ensure_trim_slot(obj: bpy.types.Object) -> None:
    """Guarantee a usable FactionTrim slot even for uncrewed set pieces."""
    trim = bpy.data.materials.get(TRIM_NAME)
    if trim is None:
        return
    for slot in obj.material_slots:
        if slot.material == trim:
            return
    # Slab and Sandworm have no house livery in their 2D art. A tiny recessed
    # marker keeps the runtime material contract without changing silhouettes.
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 0.015))
    marker = bpy.context.object
    marker.scale = (0.04, 0.04, 0.015)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    marker.data.materials.append(trim)
    marker["sandwar_model"] = True
    for other in bpy.data.objects:
        other.select_set(False)
    marker.select_set(True)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.join()
    obj.data.update()


def export_glb(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    obj = bpy.context.view_layer.objects.active
    for other in bpy.data.objects:
        other.select_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=str(path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
        export_normals=True,
        export_tangents=True,
        export_texcoords=True,
    )
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    materials = [slot.material.name for slot in obj.material_slots if slot.material]
    print("GLB %-28s %5d tris  %s" % (path.name, tris, ",".join(materials)), flush=True)


def export_buildings() -> None:
    for building in bb.SPECS:
        bb.purge_model()
        bb.BUILDERS[building](False)
        add_site_clutter(building, int(bb.SPECS[building]["span"]))
        trim_detached_pad_debris(building, int(bb.SPECS[building]["span"]))
        obj = prepare_mesh(BUILDING_TRI_BUDGET)
        export_glb(BUILDING_DIR / (building + ".glb"))
        if building in bb.HEAD_IDS:
            bb.purge_model()
            bb.build_turret_head_model(building, 0.0)
            obj = prepare_mesh(BUILDING_TRI_BUDGET)
            export_glb(BUILDING_DIR / (building + "_head.glb"))


def export_units() -> None:
    units = [
        ("infantry", lambda: bu.build_infantry("infantry", 0), INFANTRY_TRI_BUDGET),
        ("rocket", lambda: bu.build_infantry("rocket", 0), INFANTRY_TRI_BUDGET),
        ("fremen", lambda: bu.build_infantry("fremen", 0), INFANTRY_TRI_BUDGET),
        ("sardaukar", lambda: bu.build_infantry("sardaukar", 0), INFANTRY_TRI_BUDGET),
        ("saboteur", lambda: bu.build_infantry("saboteur", 0), INFANTRY_TRI_BUDGET),
        ("trike", bu.build_trike, VEHICLE_TRI_BUDGET),
        ("raider_trike", bu.build_raider, VEHICLE_TRI_BUDGET),
        ("quad", bu.build_quad, VEHICLE_TRI_BUDGET),
        ("tank", bu.build_tank, VEHICLE_TRI_BUDGET),
        ("atreides_tank", lambda: bu.build_combat_tank("atreides"), VEHICLE_TRI_BUDGET),
        ("harkonnen_tank", lambda: bu.build_combat_tank("harkonnen"), VEHICLE_TRI_BUDGET),
        ("ordos_tank", lambda: bu.build_combat_tank("ordos"), VEHICLE_TRI_BUDGET),
        ("sonic_tank", bu.build_sonic, VEHICLE_TRI_BUDGET),
        ("devastator", bu.build_devastator, VEHICLE_TRI_BUDGET),
        ("deviator", bu.build_deviator, VEHICLE_TRI_BUDGET),
        ("mcv", bu.build_mcv, VEHICLE_TRI_BUDGET),
        # Exported empty: Renderer3D grows a live spice mound from the cargo
        # level so the hopper reads empty -> half -> full during a mining run.
        ("harvester", lambda: bu.build_harvester(0.0), HARVESTER_TRI_BUDGET),
        ("carryall", bu.build_carryall, VEHICLE_TRI_BUDGET),
        ("frigate", bu.build_frigate, VEHICLE_TRI_BUDGET),
        ("ornithopter", bu.build_ornithopter, VEHICLE_TRI_BUDGET),
        # A taller breach pose with a fully open maw. Renderer3D animates the
        # rise, rear-back, lunge and burrow on a pivot between the yaw root and
        # the mesh, so one GLB serves the whole cinematic.
        ("sandworm", lambda: bu.build_sandworm(
            {"rise": 3.15, "jaw": 0.98, "phase": 0.0, "lunge": 0.0,
             "rear": 0.12, "churn": 0.55}), WORM_TRI_BUDGET),
    ]
    for name, builder, budget in units:
        bb.purge_model()
        builder()
        obj = prepare_mesh(budget)
        export_glb(UNIT_DIR / (name + ".glb"))


def main() -> None:
    tokens = [part for chunk in bb.args_after_ddash() for part in chunk.split(",") if part]
    bb.reset_scene()
    bb.build_materials()
    bu.build_materials()
    BUILDING_DIR.mkdir(parents=True, exist_ok=True)
    UNIT_DIR.mkdir(parents=True, exist_ok=True)
    TEX_DIR.mkdir(parents=True, exist_ok=True)
    # Clear only the generated GLBs, never user files.
    for path in list(BUILDING_DIR.glob("*.glb")) + list(UNIT_DIR.glob("*.glb")):
        path.unlink()
    if not tokens or "buildings" in tokens:
        export_buildings()
    if not tokens or "units" in tokens:
        export_units()
    print("ALL 3D MODELS EXPORTED", flush=True)


if __name__ == "__main__":
    main()
