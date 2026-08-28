shader_type canvas_item;
render_mode unshaded;

// Full-screen underwater pass. It reads the rendered frame, pushes it around
// with two crossed sine waves, softens it, tints it, and darkens the corners.
// `amount` is the submersion blend (0 = dry, 1 = fully under), so the whole
// effect fades in as the camera crosses the surface instead of snapping on.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

uniform vec4 tint : source_color = vec4(0.32, 0.68, 0.80, 1.0);
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float wave_speed = 1.6;
uniform float wave_frequency = 9.0;
uniform float wave_width = 0.006;
uniform float blur_radius = 0.0022;
uniform float vignette : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	vec2 uv = SCREEN_UV;

	vec2 wave;
	wave.x = cos(TIME * wave_speed + uv.y * wave_frequency) * wave_width;
	wave.y = sin(TIME * wave_speed * 0.83 + uv.x * wave_frequency * 1.3) * wave_width;
	uv += wave * amount;

	// Four extra taps stand in for scattering. Water is not a sharp lens.
	float r = blur_radius * amount;
	vec3 color = texture(screen_tex, uv).rgb;
	color += texture(screen_tex, uv + vec2(r, 0.0)).rgb;
	color += texture(screen_tex, uv - vec2(r, 0.0)).rgb;
	color += texture(screen_tex, uv + vec2(0.0, r)).rgb;
	color += texture(screen_tex, uv - vec2(0.0, r)).rgb;
	color /= 5.0;

	color = mix(color, color * tint.rgb, amount);

	float edge = distance(uv, vec2(0.5)) * 1.42;
	color *= 1.0 - vignette * amount * smoothstep(0.35, 1.0, edge);

	COLOR = vec4(color, 1.0);
}
