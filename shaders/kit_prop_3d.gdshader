shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Batched CC0 kit props (Kenney/Quaternius). Their source materials are flat
// palette atlases, so this shader keeps the atlas colour but ties every prop
// into the same desert lighting and shroud falloff as the procedural scatter.
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_disable;
uniform sampler2D sim_map : filter_linear, repeat_disable;
uniform float map_size = 56.0;
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float prop_roughness = 0.78;
uniform float prop_metallic = 0.16;
uniform float dust = 0.16;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	vec2 uv = clamp(v_world.xz / map_size, vec2(0.0), vec2(1.0));
	float shroud = texture(sim_map, uv).a;
	float seen = smoothstep(0.04, 0.30, shroud);
	float unseen = smoothstep(0.48, 0.92, shroud);
	float darkness = mix(1.0, 0.82, seen) * mix(1.0, 0.58, unseen);
	// A veil of desert dust settles on every prop so the kit palette does not
	// read as freshly painted plastic beside the weathered hand-authored GLBs.
	// Kenney kits use flat per-material colours instead of an atlas; those are
	// baked into vertex colours by renderer_3d.gd. Quaternius meshes carry an
	// albedo atlas. Multiplying both by the same sampler keeps one shader.
	vec3 col = tex.rgb * COLOR.rgb * tint;
	col = mix(col, col * vec3(0.83, 0.72, 0.58) + vec3(0.055, 0.039, 0.022), dust);
	ALBEDO = col * darkness;
	ROUGHNESS = prop_roughness;
	METALLIC = prop_metallic;
	SPECULAR = 0.20;
}
