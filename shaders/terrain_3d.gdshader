shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Low-resolution simulation map sampled across the continuous 3D terrain.
// R = rock plateau, G = spice richness, B = concrete slab, A = shroud/fog.
uniform sampler2D sim_map : filter_linear, repeat_disable;
uniform float map_size = 56.0;

// Real seamless CC0 PBR sets (ambientCG 1K, NormalGL convention). Albedo and
// detail maps are tiled in world space, never in the terrain mesh's UV space,
// so the 56x56 simulation grid cannot print its own texture lattice.
uniform sampler2D sand_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_rough : filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_rough : filter_linear_mipmap, repeat_enable;
uniform sampler2D concrete_color : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D concrete_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D concrete_rough : filter_linear_mipmap, repeat_enable;

// One world tile per unit. A sand tile repeats roughly every three tiles; the
// second, rotated sample covers a much larger area to hide the seam.
uniform float sand_scale = 0.34;
uniform float rock_scale = 0.42;
uniform float concrete_scale = 0.31;
uniform float detail_strength = 0.55;

varying vec3 v_world;
varying vec3 v_world_normal;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec2 rot2(vec2 p, float a) {
	float s = sin(a);
	float c = cos(a);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Small two-octave warp used to bend the otherwise low-resolution simulation
// mask into rounded desert contours. This is colour/normal only; the mesh
// carries the matching broad geometric warp.
vec2 domain_warp(vec2 p) {
	vec2 q = vec2(
		noise2(p * 0.83 + vec2(1.7, 4.2)),
		noise2(p * 0.91 + vec2(8.1, 2.4)));
	vec2 r = vec2(
		noise2(p * 2.17 + q * 3.1 + vec2(5.3, 1.9)),
		noise2(p * 2.03 - q * 2.7 + vec2(2.1, 9.4)));
	return (q - 0.5) * 0.14 + (r - 0.5) * 0.045;
}

// Height-field projection. Flat ground projects straight down (XZ); a steep
// cliff rotates onto a vertical plane so its strata do not smear into long
// streaks when the camera looks along the plateau wall.
vec2 project_world(vec3 w, vec3 wn) {
	float cliff = clamp(1.0 - abs(wn.y), 0.0, 1.0);
	cliff = smoothstep(0.20, 0.78, cliff);
	vec2 ground = w.xz;
	vec2 wall = vec2((w.x + w.z) * 0.7071, w.y);
	return mix(ground, wall, cliff);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = clamp(UV, vec2(0.0), vec2(1.0));
	vec2 tile = uv * map_size;
	// Warp the mask lookup in tile space. Combined with linear filtering this
	// rounds off the four-corner stair steps of the 56 x 56 simulation map.
	vec2 wuv = clamp(uv + domain_warp(tile) / map_size, vec2(0.0), vec2(1.0));
	vec4 sim = texture(sim_map, wuv);
	float rock = sim.r;
	float spice = sim.g;
	float concrete = sim.b;
	float shroud = sim.a;
	// Broad dune bands, mid-scale grain and a fine wind speckle. Frequencies
	// are deliberately low in tile space: one world unit is a whole map tile,
	// so this keeps the dunes sweeping instead of looking like woven cloth.
	float broad = noise2(tile * 0.34);
	float fine = noise2(tile * 2.60);
	float grit = noise2(tile * 9.0);
	float grit_fine = noise2(tile * 23.0 + vec2(17.0, 5.0));
	float grit_hash = hash(floor(tile * 43.0) + vec2(31.0, 19.0));
	float grain = mix(grit_fine, grit_hash, 0.44);
	float granule = smoothstep(0.56, 0.87, grain);
	float crevice = 1.0 - smoothstep(0.08, 0.32, grain);
	vec2 texel = vec2(1.0 / map_size, 1.0 / map_size);

	// Near taps drive the plateau lip. Far taps feather the spice field over
	// several tiles so a raw 1-bit sim-map patch cannot show square corners.
	vec4 tap_n = texture(sim_map, wuv + vec2(0.0, -texel.y));
	vec4 tap_s = texture(sim_map, wuv + vec2(0.0, texel.y));
	vec4 tap_e = texture(sim_map, wuv + vec2(texel.x, 0.0));
	vec4 tap_w = texture(sim_map, wuv + vec2(-texel.x, 0.0));
	vec4 far_n = texture(sim_map, wuv + vec2(0.0, -texel.y * 2.4));
	vec4 far_s = texture(sim_map, wuv + vec2(0.0, texel.y * 2.4));
	vec4 far_e = texture(sim_map, wuv + vec2(texel.x * 2.4, 0.0));
	vec4 far_w = texture(sim_map, wuv + vec2(-texel.x * 2.4, 0.0));

	// Rock and concrete arrive as hard 1-bit tiles. Feather both with neighbour
	// taps and noise so mesa rims and paving slabs do not print a checkerboard
	// across the whole map; the height mesh still supplies the actual cliff.
	float rock_near = (rock * 2.0 + tap_n.r + tap_s.r + tap_e.r + tap_w.r
			+ far_n.r + far_s.r + far_e.r + far_w.r) / 10.0;
	rock_near += (noise2(tile * 3.7 + vec2(2.0, 9.0)) - 0.5) * 0.26;
	rock_near += (noise2(tile * 7.3 + vec2(12.0, 4.0)) - 0.5) * 0.07;
	rock = smoothstep(0.27, 0.73, rock_near);
	float conc_near = (concrete * 2.0 + tap_n.b + tap_s.b + tap_e.b + tap_w.b
			+ far_n.b + far_s.b + far_e.b + far_w.b) / 10.0;
	conc_near += (noise2(tile * 4.5 + vec2(6.0, 1.0)) - 0.5) * 0.16;
	concrete = smoothstep(0.26, 0.74, conc_near);

	// ------------------------------------------------------- PBR world tiling
	// Each material gets a primary tiling and a rotated, off-phase second
	// scale. Blending them with a low-frequency field breaks the repeat
	// without the cost of full three-axis triplanar sampling on Android.
	vec3 wpos = v_world;
	vec3 wnorm = normalize(v_world_normal);
	vec2 pbase = project_world(wpos, wnorm);
	float phase = clamp(noise2(pbase * 0.26 + vec2(9.0, 3.0)) * 0.72 + 0.14, 0.0, 1.0);

	vec2 sand_a = pbase * sand_scale;
	vec2 sand_b = rot2(pbase, 2.399) * sand_scale * 0.43 + vec2(0.37, 0.71);
	vec2 rock_a = pbase * rock_scale + vec2(0.11, 0.53);
	vec2 rock_b = rot2(pbase, 1.973) * rock_scale * 0.41 + vec2(0.61, 0.19);
	vec2 conc_a = pbase * concrete_scale + vec2(0.43, 0.07);
	vec2 conc_b = rot2(pbase, 2.711) * concrete_scale * 0.45 + vec2(0.23, 0.87);

	vec3 sand_tex = mix(texture(sand_color, sand_a).rgb,
			texture(sand_color, sand_b).rgb, phase);
	vec3 rock_tex = mix(texture(rock_color, rock_a).rgb,
			texture(rock_color, rock_b).rgb, phase);
	vec3 conc_tex = mix(texture(concrete_color, conc_a).rgb,
			texture(concrete_color, conc_b).rgb, phase);

	vec3 sand_n_a = texture(sand_normal, sand_a).xyz * 2.0 - 1.0;
	vec3 sand_n_b = texture(sand_normal, sand_b).xyz * 2.0 - 1.0;
	vec3 sand_n = normalize(mix(sand_n_a, sand_n_b, phase));
	vec3 rock_n = texture(rock_normal, rock_a).xyz * 2.0 - 1.0;
	vec3 conc_n = texture(concrete_normal, conc_a).xyz * 2.0 - 1.0;

	// Warm Arrakis golden sand against weathered terracotta plateau rock. The
	// tint is deliberately gentle: the CC0 albedo must stay readable under the
	// low sun instead of being repainted into flat cartoon colour.
	vec3 sand = sand_tex * vec3(1.10, 0.965, 0.790);
	sand *= 0.88 + 0.22 * (broad * 0.62 + fine * 0.38);
	sand += vec3(0.018, 0.012, 0.006) * (grit - 0.5);
	sand += vec3(0.014, 0.010, 0.005) * (grain - 0.5);

	// Weathered terracotta sandstone, darker in fissures and bleached on top.
	vec3 stone = rock_tex * vec3(1.20, 0.840, 0.590);
	stone *= 0.86 + 0.24 * (broad * 0.44 + fine * 0.56);
	stone = mix(stone, stone * vec3(0.50, 0.34, 0.24), pow(1.0 - fine, 4.0) * 0.42);
	// Flat-topped mesas need surface archaeology at RTS distance: horizontal
	// strata and a few deep wind cracks stop them reading as blank polygons.
	float strata = sin(tile.x * 1.7 + broad * 4.0) * sin(tile.y * 1.3 + 0.6);
	stone *= 1.0 + strata * 0.060;
	float crack = smoothstep(0.86, 0.98, noise2(tile * 1.5 + vec2(13.0, 7.0)));
	stone = mix(stone, stone * 0.62, crack * 0.55);
	vec3 col = mix(sand, stone, rock * 0.80);

	// A darker, noisy lip marks the drop from plateau to sand, so the mesh's
	// one-tile cliff slope reads as layered rock rather than a soft hill.
	float lip = clamp((1.0 - min(min(tap_n.r, tap_s.r), min(tap_e.r, tap_w.r))) * rock, 0.0, 1.0);
	col = mix(col, col * vec3(0.58, 0.47, 0.39), lip * (0.70 + fine * 0.30));

	// Paved concrete keeps the same sun-baked family as the buildings.
	vec3 slab = conc_tex * vec3(1.04, 0.955, 0.830);
	slab *= 0.90 + 0.18 * fine;
	float seam = step(0.97, fract(tile.x / 3.0)) + step(0.97, fract(tile.y / 3.0));
	slab *= 1.0 - min(seam, 1.0) * 0.10;
	col = mix(col, slab, concrete * 0.55);

	// ------------------------------------------------- wind-swept dune ripples
	// One dominant diagonal train with noise-warped phase, plus a much weaker
	// parallel train at double frequency. Keeping both trains on nearly the
	// same bearing is what produces long wind-combed ridges instead of a
	// crosshatch. Crests are sharpened and troughs broadened like real sand.
	vec2 wind_a = normalize(vec2(0.88, 0.475));
	float warp = (broad - 0.5) * 8.0 + (fine - 0.5) * 2.2;
	float phase_a = dot(tile, wind_a) * 11.5 + warp;
	float sin_a = sin(phase_a);
	float cos_a = cos(phase_a);
	float crest_a = pow(max(sin_a, 0.0), 2.2);
	float trough_a = pow(max(-sin_a, 0.0), 1.5);
	float slope_a = (2.2 * pow(max(sin_a, 0.0), 1.2) * cos_a
			- 1.5 * pow(max(-sin_a, 0.0), 0.5) * cos_a) * 0.095;

	// A parallel second harmonic combs finer ridges into the dominant train.
	// Angling it produced a 1-tile moiré diamond lattice across the whole map.
	vec2 wind_b = wind_a;
	float phase_b = dot(tile, wind_b) * 18.0 + broad * 4.0;
	float sin_b = sin(phase_b);
	float slope_b = 2.0 * max(sin_b, 0.0) * cos(phase_b) * 0.018;
	// A shallow, higher-frequency train gives close-ups the crisp wind-combed
	// grain that the old broad sine lost at 1.5x zoom.
	float phase_c = dot(tile, wind_a) * 27.0 - broad * 2.0 + fine * 0.8;
	float sin_c = sin(phase_c);
	float slope_c = cos(phase_c) * 0.026;
	float crest_c = pow(max(sin_c, 0.0), 3.0);

	float sand_mask = (1.0 - rock) * (1.0 - concrete);
	vec2 ripple_grad = (wind_a * (slope_a + slope_b + slope_c)) * sand_mask;

	// --------------------------------------------------- clustered spice dunes
	// A wide blurred mask feathers the tile edge, then ragged noise breaks the
	// boundary into organic tongues. Clustered value noise shapes the mounds.
	float spice_blur = (far_n.g + far_s.g + far_e.g + far_w.g + spice * 2.0) / 6.0;
	spice_blur += (noise2(tile * 4.4 + vec2(21.0, 7.0)) - 0.5) * 0.10;
	float patch = smoothstep(0.015, 0.58, spice_blur * 0.70 + spice * 0.30);
	patch = clamp(patch + (noise2(tile * 5.1 + vec2(3.0, 4.0)) - 0.5) * 0.16, 0.0, 1.0);
	float ragged = noise2(tile * 3.6 + vec2(7.0, 3.0));
	float cluster = broad * 0.54 + fine * 0.46;
	float mounds = smoothstep(0.30, 0.82, cluster * 0.64 + patch * 0.26 + ragged * 0.20);
	float ragged_edge = smoothstep(0.08, 0.45, ragged * 0.55 + patch * 0.58);
	// Keep the field cohesive: extra large-scale patchiness turned a full spice
	// field into a diamond quilt. Granularity comes from the colour and bump.
	float spice_mask = smoothstep(0.015, 0.38, patch) * ragged_edge * (0.72 + 0.30 * mounds);

	// Fine burnt-orange/rust gravel. Hard hash grains read as individual spice
	// crystals at harvester zoom instead of the old smooth orange lava blotch.
	vec3 spice_dark = vec3(0.285, 0.135, 0.038);
	vec3 spice_mid = vec3(0.545, 0.275, 0.072);
	vec3 spice_hot = vec3(0.790, 0.425, 0.115);
	vec3 spice_col = mix(spice_dark, spice_mid, cluster);
	spice_col = mix(spice_col, spice_hot, granule * 0.46);
	spice_col *= 0.78 + 0.36 * grit_fine;
	spice_col += vec3(0.085, 0.033, 0.004) * granule;
	spice_col = mix(spice_col, spice_dark * 0.72, crevice * 0.34);
	col = mix(col, spice_col, clamp(spice_mask, 0.0, 1.0) * 0.90);
	// Keep sparse bright flakes without blowing the whole field into a crust.
	float flakes = smoothstep(0.82, 0.97, grain);
	col += vec3(0.095, 0.042, 0.005) * flakes * spice_mask * 0.50;
	col = mix(col, col * 0.84, crevice * spice_mask * 0.16);
	col = mix(col, col * vec3(1.16, 1.07, 0.92),
			smoothstep(0.60, 0.92, mounds) * spice_mask * 0.28);

	// Aerial-perspective ripples catch the low NW sun: the windward face is
	// bleached, the lee face drops into warm umber.
	col = mix(col, col * vec3(1.18, 1.11, 0.99), sand_mask * crest_a * 0.37);
	col = mix(col, col * vec3(1.08, 1.04, 0.97), sand_mask * crest_c * 0.12);
	col *= mix(vec3(1.0), vec3(0.80, 0.715, 0.585), sand_mask * trough_a * 0.38);

	// Remembered but currently unlit ground is dim; never-seen ground is shroud.
	// Nine taps blur the 1-bit fog tile into a soft illustrated vignette instead
	// of huge hard-edged squares, while ragged noise breaks the contour.
	float shroud_soft = (shroud * 2.0 + tap_n.a + tap_s.a + tap_e.a + tap_w.a
			+ far_n.a + far_s.a + far_e.a + far_w.a) / 10.0;
	float rough = (noise2(tile * 2.3 + vec2(11.0, 4.0)) - 0.5) * 0.18;
	float edge = smoothstep(0.015, 0.20, shroud_soft) * (1.0 - smoothstep(0.78, 0.98, shroud_soft));
	float sh = clamp(shroud_soft + rough * edge, 0.0, 1.0);
	float seen = smoothstep(0.015, 0.35, sh);
	float unseen = smoothstep(0.50, 0.95, sh);
	// Keep the fog readable without stamping visible tile-shaped light/dark
	// squares over the dunes; the 2D Classic shroud is untouched.
	float darkness = mix(1.0, 0.88, seen) * mix(1.0, 0.68, unseen);
	col *= darkness;
	col = mix(col, vec3(0.10, 0.078, 0.055), unseen * 0.15);

	// World-space detail normal: real PBR normal maps supply the grain, while
	// the procedural ripples and spice clumps keep the large dunes readable.
	// A tangent-space NORMAL_MAP flipped on alternate triangles (inconsistent
	// generated tangents), printing a big checkerboard across the dunes. The
	// terrain is a height field in XZ, so perturbing the world normal directly
	// is both cheaper and perfectly continuous.
	vec2 micro_bump = vec2(
		noise2(tile * 29.0 + vec2(2.0, 8.0)) - 0.5,
		noise2(tile * 31.0 + vec2(7.0, 3.0)) - 0.5);
	vec2 spice_bump = vec2(ragged - 0.5, fine - 0.5) * spice_mask * 2.0
			+ micro_bump * spice_mask * 1.1;
	vec2 sand_bump = micro_bump * sand_mask * 0.22;
	vec2 pbr_bump = sand_n.xy * (1.0 - rock) * (1.0 - concrete)
			+ rock_n.xy * rock + conc_n.xy * concrete;
	vec3 n_world = normalize(vec3(
		-ripple_grad.x - spice_bump.x - sand_bump.x - pbr_bump.x * detail_strength,
		1.0,
		-ripple_grad.y - spice_bump.y - sand_bump.y - pbr_bump.y * detail_strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// Roughness comes from the scanned material itself, so wet shaded rock and
	// dry sand reflect the low sun differently instead of sharing one flat
	// toon value. Spice crust stays matte.
	float rough_sand = texture(sand_rough, sand_a).g;
	float rough_rock = texture(rock_rough, rock_a).g;
	float rough_conc = texture(concrete_rough, conc_a).g;
	float rough_tex = mix(mix(rough_sand, rough_rock, rock), rough_conc, concrete);
	ROUGHNESS = clamp(mix(rough_tex, 0.97, spice_mask * 0.35), 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.18;

	ALBEDO = col * 0.92;
}
