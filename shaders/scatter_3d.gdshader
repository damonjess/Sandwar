shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// One shader drives every batched piece of environmental clutter. The
// MultiMesh instance custom data carries a deterministic tone and a material
// kind (rock, scrap, shrub, crate, canister), while the live simulation map
// keeps objects inside shroud/remembered fog in the same lighting family as
// the terrain beneath them.
uniform sampler2D sim_map : filter_linear, repeat_disable;
uniform float map_size = 56.0;

varying vec4 v_custom;
varying vec3 v_world;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float kind = floor(v_custom.g * 4.0 + 0.5);
	float tone = clamp(v_custom.r, 0.0, 1.0);
	vec2 uv = clamp(v_world.xz / map_size, vec2(0.0), vec2(1.0));
	vec4 sim = texture(sim_map, uv);
	float spice = sim.g;
	float shroud = sim.a;

	float grain = hash21(floor(v_world.xz * 180.0) + vec2(11.0, 7.0));
	float macro = hash21(floor(v_world.xz * 23.0) + vec2(3.0, 17.0));
	vec3 col;
	float rough = 0.92;
	if (kind < 0.5) {
		// Wind-scoured umber gravel and broken sandstone.
		col = mix(vec3(0.185, 0.135, 0.085), vec3(0.465, 0.345, 0.225),
			tone * 0.72 + grain * 0.28);
		col *= 0.82 + 0.30 * grain;
		col = mix(col, vec3(0.610, 0.385, 0.175), spice * 0.24);
		rough = 0.95;
	} else if (kind < 1.5) {
		// Rusted plate and structural scrap.
		col = mix(vec3(0.245, 0.165, 0.085), vec3(0.480, 0.285, 0.125),
			tone * 0.75 + grain * 0.25);
		col *= 0.74 + 0.44 * grain;
		col = mix(col, vec3(0.135, 0.095, 0.065), step(0.73, grain) * 0.34);
		rough = 0.60;
	} else if (kind < 2.5) {
		// Dry scrub: dark olive stems with dusty bleached tips.
		col = mix(vec3(0.160, 0.140, 0.075), vec3(0.365, 0.300, 0.145),
			tone * 0.65 + grain * 0.35);
		col *= 0.82 + 0.30 * grain;
		rough = 0.94;
	} else if (kind < 3.5) {
		// Weathered supply crates and their dark strapping.
		col = mix(vec3(0.300, 0.235, 0.135), vec3(0.700, 0.510, 0.215),
			tone * 0.72 + grain * 0.28);
		float strap = step(0.46, fract(v_world.y * 6.0 + v_world.x * 1.8));
		col = mix(col, vec3(0.155, 0.120, 0.078), strap * 0.32);
		rough = 0.80;
	} else {
		// Rusted fuel drums / canisters with darker rolled hoops.
		col = mix(vec3(0.220, 0.145, 0.075), vec3(0.515, 0.310, 0.135),
			tone * 0.72 + grain * 0.28);
		float hoop = smoothstep(0.72, 0.92, abs(sin(v_world.y * 26.0)));
		col = mix(col, vec3(0.135, 0.105, 0.075), hoop * 0.38);
		col *= 0.80 + 0.34 * macro;
		rough = 0.66;
	}

	// A veil of desert dust settles on every object. It also keeps the
	// scatter from reading as clean, freshly placed props on the sand.
	col = mix(col, vec3(0.570, 0.445, 0.285), 0.045 + 0.055 * macro);
	float seen = smoothstep(0.04, 0.30, shroud);
	float unseen = smoothstep(0.48, 0.92, shroud);
	float darkness = mix(1.0, 0.82, seen) * mix(1.0, 0.58, unseen);
	col *= darkness;
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = 0.16;
}
