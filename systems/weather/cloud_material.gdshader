shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_back, diffuse_toon, specular_disabled;

// Astroneer-style puffy cloud material
// Locally-driven: rain darkening, time-of-day tinting, biome-aware

uniform vec3 cloud_color_top : source_color = vec3(1.0, 0.98, 0.96);
uniform vec3 cloud_color_bottom : source_color = vec3(0.65, 0.68, 0.75);
uniform vec3 cloud_color_rain : source_color = vec3(0.40, 0.42, 0.48);
uniform float rain_amount : hint_range(0.0, 1.0) = 0.0;
uniform float alpha_base : hint_range(0.3, 1.0) = 0.92;
uniform float edge_softness : hint_range(0.0, 1.0) = 0.4;
instance uniform float local_rain_amount : hint_range(0.0, 1.0) = 0.0;
instance uniform float cloud_mass : hint_range(0.0, 1.2) = 1.0;

// Time of day: 0.0=midnight, 0.25=sunrise, 0.5=noon, 0.75=sunset
uniform float time_of_day : hint_range(0.0, 1.0) = 0.5;

// Sunrise/sunset warm tint
uniform vec3 sunrise_tint : source_color = vec3(1.0, 0.65, 0.35);
// Night darkening color
uniform vec3 night_tint : source_color = vec3(0.12, 0.12, 0.2);

void vertex() {
}

void fragment() {
	float top_factor = clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0);
	float rain_mix = clamp(max(rain_amount * 0.35, local_rain_amount), 0.0, 1.0);
	float mass_mix = clamp(cloud_mass, 0.0, 1.2);

	vec3 base_top = mix(cloud_color_top, cloud_color_rain, rain_mix);
	vec3 base_bottom = mix(cloud_color_bottom, cloud_color_rain * 0.7, rain_mix);
	vec3 tint = mix(base_bottom, base_top, top_factor);
	vec3 col = COLOR.rgb * tint;
	col *= mix(0.72, 1.08, clamp(mass_mix, 0.0, 1.0));

	// Sun-facing brightening
	float sun_facing = max(dot(NORMAL, VIEW), 0.0);
	col += vec3(0.08) * pow(sun_facing, 2.0) * (1.0 - rain_mix);

	// Time-of-day tinting
	// Sunrise (0.2–0.3) and sunset (0.7–0.8): warm orange/pink tint
	float sunrise_t = 1.0 - clamp(abs(time_of_day - 0.25) * 10.0, 0.0, 1.0);
	float sunset_t = 1.0 - clamp(abs(time_of_day - 0.75) * 10.0, 0.0, 1.0);
	float golden_t = max(sunrise_t, sunset_t);
	col = mix(col, col * sunrise_tint, golden_t * 0.5);

	// Night (0.85–0.15 next day): darken toward night tint
	float night_dist = min(time_of_day, 1.0 - time_of_day) * 2.0; // 0 at midnight, 1 at noon
	float night_t = 1.0 - clamp(night_dist * 2.5, 0.0, 1.0); // dark when < 0.4 from midnight
	col = mix(col, night_tint, night_t * 0.7);

	ALBEDO = col;
	ALPHA = alpha_base * clamp(0.28 + mass_mix * 0.72, 0.18, 1.0);
	ROUGHNESS = 0.95;
	SPECULAR = 0.0;
}
