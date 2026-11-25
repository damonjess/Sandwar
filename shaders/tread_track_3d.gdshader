shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

// Pooled ground decal for tracked vehicles. A MultiMesh holds flat quads and
// each instance stores the stamp time in INSTANCE_CUSTOM.r. The fade is
// computed on the GPU from TIME, so the CPU only writes a transform when a
// vehicle lays down a fresh print.
uniform float lifetime = 25.0;
uniform vec3 tread_color : source_color = vec3(0.185, 0.118, 0.068);
uniform float rib_count = 9.0;

varying float v_fade;

void vertex() {
	float born = INSTANCE_CUSTOM.r;
	float age = max(TIME - born, 0.0);
	v_fade = clamp(1.0 - age / lifetime, 0.0, 1.0);
}

void fragment() {
	// Two crisp parallel bands across the quad, leaving clean sand between
	// the tracks. Soft shoulders keep the edges from looking like stickers.
	float left = smoothstep(0.10, 0.17, UV.x) * (1.0 - smoothstep(0.33, 0.40, UV.x));
	float right = smoothstep(0.60, 0.67, UV.x) * (1.0 - smoothstep(0.83, 0.90, UV.x));
	float bands = max(left, right);

	// Individual grouser bars. The pattern runs across the direction of
	// travel, so a passing column reads as ribbed tread, not a smear.
	float saw = abs(fract(UV.y * rib_count) - 0.5);
	float rib = smoothstep(0.31, 0.48, saw);
	float groove = 1.0 - smoothstep(0.08, 0.20, saw);

	vec3 col = tread_color * (0.82 + 0.30 * rib) + vec3(0.018, 0.009, 0.0) * groove;
	ALBEDO = col;
	ALPHA = bands * v_fade * (0.24 + 0.58 * rib);
}
