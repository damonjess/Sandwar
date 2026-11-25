shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

// Dark blasted crater left by artillery, plasma and heavy explosions. Like the
// tread decal it is a pooled flat quad; the birth time rides in INSTANCE_CUSTOM
// so old craters fade out slowly without per-frame CPU work.
uniform float lifetime = 120.0;

varying float v_born;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	v_born = INSTANCE_CUSTOM.r;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p);
	float grain = hash12(floor(UV * 34.0));
	// Ragged dark center, soft burnt rim blown outward by the blast.
	float scorch = smoothstep(0.96, 0.54, radius + (grain - 0.5) * 0.22);
	float core = smoothstep(0.70, 0.12, radius);
	float rim = smoothstep(0.56, 0.74, radius) * (1.0 - smoothstep(0.76, 0.98, radius));
	vec3 ash = mix(vec3(0.165, 0.108, 0.066), vec3(0.315, 0.225, 0.152), grain);
	ash = mix(ash, vec3(0.47, 0.36, 0.25), rim * 0.34);
	float age = max(TIME - v_born, 0.0);
	float fade = clamp(1.0 - age / lifetime, 0.0, 1.0);
	ALBEDO = ash;
	// Scorched earth, not a hole cut in the world. The old 0.58 centre alpha
	// read as a black disc under the bright desert sun.
	ALPHA = scorch * (0.22 + core * 0.17) * fade;
}
