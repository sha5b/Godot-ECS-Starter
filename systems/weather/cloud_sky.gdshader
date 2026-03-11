shader_type sky;

// ── Sky colors (driven by WeatherSystem) ─────────────────────────────────────
uniform vec3 sky_top_color : source_color = vec3(0.25, 0.47, 0.85);
uniform vec3 sky_horizon_color : source_color = vec3(0.55, 0.70, 0.90);
uniform vec3 ground_color : source_color = vec3(0.15, 0.12, 0.10);

// ── Sun ──────────────────────────────────────────────────────────────────────
uniform vec3 sun_direction = vec3(0.0, 0.4, -1.0);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float sun_size : hint_range(0.001, 0.1) = 0.02;

// ── Entry point ──────────────────────────────────────────────────────────────

void sky() {
	vec3 eye_dir = normalize(EYEDIR);

	// Vertical gradient
	float horizon_blend = clamp(eye_dir.y, 0.0, 1.0);
	vec3 sky = mix(sky_horizon_color, sky_top_color, pow(horizon_blend, 0.6));

	// Ground
	if (eye_dir.y < 0.0) {
		float ground_blend = clamp(-eye_dir.y * 4.0, 0.0, 1.0);
		sky = mix(sky_horizon_color, ground_color, ground_blend);
	}

	// Sun disc
	vec3 sun_dir = normalize(sun_direction);
	float sun_dot = dot(eye_dir, sun_dir);
	float sun_disc = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.3, sun_dot);
	sky += sun_color * sun_disc * 3.0;

	// Sun glow
	float sun_glow = max(sun_dot, 0.0);
	sky += sun_color * pow(sun_glow, 8.0) * 0.15;
	sky += sun_color * pow(sun_glow, 64.0) * 0.4;

	COLOR = sky;
}
