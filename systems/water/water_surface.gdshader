shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

// Ocean surface. Waves and the depth palette come from the shared include, so
// this file only owns what is specific to open water: shore foam, caustics,
// refraction and the shore-break band.
#include "res://systems/water/water_common.gdshaderinc"

// ── Foam ──
uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 1.0, 0.9);
uniform float foam_width = 0.8;
uniform float foam_noise_scale = 8.0;

// ── Waves ──
uniform float wave_amplitude = 0.12;
uniform float wave_frequency = 1.5;
uniform float wave_speed = 0.8;
uniform float shore_depth_range = 4.0;
uniform float shore_wave_min_depth = 0.15;
uniform float shore_wave_max_depth = 0.8;
uniform float shore_break_strength = 0.55;

// Wavelength of the longest swell, in metres. The wave field steps up from
// here; 90 m puts the dominant crest spacing at open-ocean scale instead of
// the ~78 m the old hardcoded sine happened to land on.
uniform float swell_wavelength = 90.0;

// ── Material ──
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float metallic : hint_range(0.0, 1.0) = 0.3;
uniform float time = 0.0;
uniform float refraction_amount = 0.7;
uniform float fresnel_strength = 0.42;

// ── Caustics ──
uniform bool caustics_enabled = true;
uniform float caustics_strength = 0.3;
uniform float caustics_speed = 1.2;

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D terrain_depth_tex : source_color, filter_linear_mipmap, repeat_disable;

varying float v_terrain_depth;
varying vec3 v_world_pos;

float swell_base_freq() {
	return 6.2831853 / max(swell_wavelength, 1.0);
}

// ── Caustics pattern (animated voronoi-like) ──
float caustic_pattern(vec2 uv, float t) {
	vec2 p = uv * 3.0;
	float c = 0.0;
	c += sin(p.x * 5.3 + t * 1.1) * sin(p.y * 4.7 - t * 0.9) * 0.5 + 0.5;
	c *= sin(p.x * 3.1 - t * 0.7) * sin(p.y * 6.2 + t * 1.3) * 0.5 + 0.5;
	c += sin((p.x + p.y) * 4.0 + t * 0.5) * 0.3;
	return clamp(c, 0.0, 1.0);
}

// ── Vertex: broad swell + shore break ──
void vertex() {
	v_terrain_depth = texture(terrain_depth_tex, UV).r;
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_pos = world_pos;

	float depth_factor = smoothstep(shore_wave_min_depth, shore_wave_max_depth, v_terrain_depth);

	// The open-water displacement is the same non-repeating field the normal
	// uses, so crests in the silhouette line up with crests in the shading.
	float swell = water_height(world_pos.xz, time * wave_speed, swell_base_freq(), wave_amplitude);
	float shore_wave = sin((world_pos.x * 0.35 + world_pos.z * 1.1) * wave_frequency * 2.2 - time * wave_speed * 4.0) * wave_amplitude * shore_break_strength;

	VERTEX.y += swell * depth_factor + shore_wave * (1.0 - depth_factor) * v_terrain_depth;
}

void fragment() {
	float depth_factor = smoothstep(shore_wave_min_depth, shore_wave_max_depth, v_terrain_depth);

	vec3 wn = water_normal(v_world_pos.xz, time * wave_speed, swell_base_freq(),
		wave_amplitude * 1.6);

	// Screen-space depth
	float depth_raw = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_depth = INV_PROJECTION_MATRIX * ndc;
	view_depth.xyz /= view_depth.w;
	float scene_depth = -view_depth.z;
	float water_depth = -VERTEX.z;
	float depth_diff = scene_depth - water_depth;

	// 4-zone depth color
	float depth_blend = max(clamp(depth_diff / shore_depth_range, 0.0, 1.0), v_terrain_depth);
	vec4 water_col = depth_zone_color(depth_blend);
	float fresnel = pow(1.0 - clamp(dot(normalize(VIEW), normalize(wn)), 0.0, 1.0), 3.0);

	// Shore foam — animated, patchy, with noise breakup
	float foam_factor = 1.0 - clamp(depth_diff / foam_width, 0.0, 1.0);
	foam_factor = max(foam_factor, (1.0 - smoothstep(0.03, 0.2, v_terrain_depth)) * 0.9);

	// Multi-frequency foam noise for organic look
	float fn1 = sin(v_world_pos.x * foam_noise_scale + time * 2.0) * 0.5 + 0.5;
	float fn2 = sin(v_world_pos.z * foam_noise_scale * 0.75 + time * 1.5) * 0.5 + 0.5;
	float fn3 = sin((v_world_pos.x + v_world_pos.z) * foam_noise_scale * 0.5 - time * 1.8) * 0.5 + 0.5;
	float foam_noise = fn1 * fn2 * 0.7 + fn3 * 0.3;
	foam_factor *= step(0.25, foam_noise + foam_factor * 0.4);

	// Rolling shore break: moves in wave direction
	float shore_break = sin(v_world_pos.z * 1.5 - time * wave_speed * 3.0) * 0.5 + 0.5;
	shore_break *= (1.0 - smoothstep(0.05, 0.25, v_terrain_depth));
	foam_factor = max(foam_factor, shore_break * 0.6);

	// Crest foam from wave steepness. Whitecaps only break on the steepest
	// crests, and only where the swell envelope is actually running high.
	float crest = pow(1.0 - clamp(wn.y, 0.0, 1.0), 3.0) * 2.0;
	foam_factor = max(foam_factor, crest * depth_factor * 0.5);

	vec3 final_color = mix(water_col.rgb, foam_color.rgb, foam_factor * 0.7);
	float final_alpha = mix(water_col.a, foam_color.a, foam_factor * 0.5);

	// Caustics on shallow seafloor
	if (caustics_enabled) {
		float caustic_mask = (1.0 - smoothstep(0.0, 0.4, v_terrain_depth));
		float caustic = caustic_pattern(v_world_pos.xz * 0.15, time * caustics_speed);
		final_color += vec3(caustic * caustics_strength * caustic_mask);
	}

	// Refraction
	vec2 refraction_uv = SCREEN_UV + wn.xz * 0.02 * refraction_amount * (1.0 - depth_blend * 0.65);
	vec3 refracted = textureLod(SCREEN_TEXTURE, refraction_uv, 0.0).rgb;
	final_color = mix(refracted, final_color, clamp(final_alpha + depth_blend * 0.25, 0.0, 1.0));
	final_color += vec3(0.18, 0.22, 0.26) * fresnel * fresnel_strength;
	final_color = mix(final_color, water_col.rgb, clamp(depth_blend * 0.35 + fresnel * 0.15, 0.0, 1.0));

	ALBEDO = final_color;
	ALPHA = clamp(final_alpha + depth_blend * 0.26 + fresnel * 0.12, 0.0, 1.0);
	NORMAL = mix(vec3(0.0, 1.0, 0.0), wn, depth_factor);
	ROUGHNESS = mix(0.02, roughness, depth_blend);
	METALLIC = metallic;
	SPECULAR = 0.5;
}
