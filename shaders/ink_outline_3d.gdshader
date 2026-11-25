shader_type spatial;
render_mode unshaded, cull_front;

// Inverted-hull concept-art ink line. Every silhouette-bearing GLB surface
// gets this as a next_pass; the front faces are discarded and the back faces
// are pushed out along the view-space normal. The extrusion grows very
// slightly with camera depth so a distant tank still reads as a drawn shape
// instead of dissolving into a one-pixel fringe.
uniform vec4 ink_color : source_color = vec4(0.078431, 0.050980, 0.031373, 1.0);
uniform float ink_width = 0.0125;
uniform float distance_growth = 0.020;
uniform float max_depth = 70.0;

void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_normal = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);
	float depth = clamp(-view.z, 0.0, max_depth);
	view.xyz += view_normal * ink_width * (1.0 + depth * distance_growth);
	// Writing POSITION keeps the extrusion entirely in view space, so the
	// same shared material works for every model scale without per-unit
	// uniforms or CPU updates.
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	ALBEDO = ink_color.rgb;
}
