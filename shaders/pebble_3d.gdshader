shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// One MultiMesh draws every desert pebble. Each fragment samples the live
// simulation map so pebbles in shroud or remembered fog are dimmed exactly
// like the terrain beneath them instead of floating as bright dots.
uniform sampler2D sim_map : filter_linear, repeat_disable;
uniform float map_size = 56.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = clamp(world_pos.xz / map_size, vec2(0.0), vec2(1.0));
	float shroud = texture(sim_map, uv).a;
	float darkness = mix(1.0, 0.66, step(0.05, shroud) * (1.0 - step(0.85, shroud)));
	darkness *= mix(1.0, 0.22, step(0.85, shroud));

	float tone = 0.5 + 0.5 * sin(world_pos.x * 11.3 + world_pos.z * 8.7);
	// Sun-baked umber gravel, deliberately darker than the sand so the single
	// MultiMesh reads as scattered stone instead of white eggs.
	vec3 rock = mix(vec3(0.245, 0.190, 0.135), vec3(0.435, 0.345, 0.245), tone);
	rock = mix(rock, vec3(0.470, 0.382, 0.272), pow(max(VERTEX.y, 0.0), 2.0) * 0.22);
	ALBEDO = rock * darkness;
	ROUGHNESS = 0.92;
	METALLIC = 0.01;
	SPECULAR = 0.18;
}
