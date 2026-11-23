shader_type canvas_item;

// House colour remap for the pre-rendered Dune 2000 style sheets.
//
// All faction paint is baked in the magenta key palette (light / mid / dark
// trim). This shader keys those pixels only, then rebuilds them from a three
// tone ramp of the selected house colour so the painted volume, rivets and
// dither survive. Everything else - rust, sand, amber furnace light, cyan
// vents, warning reds - is left untouched.
//
// faction_color: blue (Atreides), red (Harkonnen) or green (Ordos).
// HUD icons use the same material, with icon_blue_trim enabled for their blue
// house paint, so every build tile matches the battlefield.

uniform vec4 faction_color : source_color = vec4(0.25, 0.58, 0.95, 1.0);
uniform vec4 damage_tint : source_color = vec4(1.0);
uniform float remap_strength : hint_range(0.0, 1.0) = 1.0;
// HUD portraits use baked blue trim rather than the world sheets' magenta key.
// Enable this only on sidebar/briefing materials so world art stays untouched.
uniform float icon_blue_trim : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 base = COLOR;
	vec3 c = base.rgb;

	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float sat = mx > 0.001 ? (mx - mn) / mx : 0.0;

	// Magenta key: red and blue both clearly above green, saturated, not red
	// or amber (those have almost no blue). Weathered magenta is included.
	float key = step(c.g * 1.24, c.r)
			* step(c.g * 1.06, c.b)
			* smoothstep(0.18, 0.42, sat)
			* step(0.10, c.b);

	// The 64px build portraits were baked with blue house paint. Key it
	// separately, but exclude cyan instrument glows (blue and green near equal).
	float blue_key = step(c.r * 1.20, c.b)
			* step(c.g * 1.18, c.b)
			* smoothstep(0.24, 0.50, sat)
			* step(0.12, c.b)
			* icon_blue_trim;
	key = max(key, blue_key);

	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	float shade = clamp((lum - 0.08) / 0.55, 0.0, 1.5);

	// Weathered house paint: dust and old rust knock the saturation back.
	vec3 house = mix(faction_color.rgb, vec3(0.34, 0.30, 0.25), 0.16);
	vec3 deep = house * 0.38;
	vec3 mid = house * 0.92;
	vec3 lit = mix(house, vec3(0.96, 0.92, 0.82), 0.30);

	vec3 tint = mix(deep, mid, smoothstep(0.0, 0.62, shade));
	tint = mix(tint, lit, smoothstep(0.62, 1.18, shade));
	tint = mix(tint, vec3(0.98, 0.95, 0.86), smoothstep(1.18, 1.50, shade) * 0.40);

	// Keep the baked wear/dither readable instead of a flat house colour.
	tint *= 0.92 + 0.16 * clamp((c.r + c.b) * 0.5 / 0.70, 0.0, 1.0);

	COLOR = vec4(mix(c, tint, key * remap_strength), base.a) * damage_tint;
}
