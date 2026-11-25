shader_type canvas_item;
render_mode unshaded;

// A battlefield-only finishing pass. It sits above the 3D SubViewport and
// below the HUD health bars, so it cannot tint the sidebar or selection UI.
// The wobble is deliberately sub-pixel: it suggests hot air over the sand
// without smearing the terrain into a liquid.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform float heat_strength = 1.0;
uniform float grain_strength = 0.018;
uniform float vignette_strength = 0.22;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float band = smoothstep(0.24, 0.88, uv.y);
	vec2 shimmer = vec2(
		sin(uv.y * 108.0 + TIME * 2.1 + uv.x * 19.0),
		cos(uv.x * 79.0 - TIME * 1.6 + uv.y * 7.0));
	vec3 col = texture(screen_texture, uv + shimmer * 0.00055 * band * heat_strength).rgb;

	// Dusty tan grade, not a saturated orange wash: hold the pale ochre
	// highlights, pull the mids toward warm umber and desaturate the shadows so
	// they read like the reference's weathered sand instead of molten rust.
	col = mix(col, col * vec3(1.025, 0.985, 0.935), 0.10);
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(lum), col, 0.875);
	col = (col - 0.5) * 1.075 + 0.5;
	col *= 1.045;
	col = mix(col, vec3(0.335, 0.280, 0.220), 0.018);

	// Broad, very soft vignette. Multiplying by a smooth value avoids the
	// hard oval of a simple radial clamp.
	float v = smoothstep(0.84, 0.28, length((UV - 0.5) * vec2(1.08, 1.0)));
	col *= mix(1.0, mix(0.70, 1.0, v), vignette_strength);

	float g = hash21(FRAGCOORD.xy + floor(TIME * 24.0)) - 0.5;
	col += g * grain_strength;
	col = mix(col, vec3(0.470, 0.330, 0.205), 0.026);
	COLOR = vec4(col, 1.0);
}
