shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

// River surface. Shares water_common.gdshaderinc with the ocean, so a river
// mouth and the sea it runs into are the same material family — the same wave
// model, the same four depth zones, the same palette uniforms.
//
// On top of that the river adds flow: waves stretched along the channel and
// advected downstream, plus the outlet fade that hands the surface over to
// the ocean instead of z-fighting with it.
#include "res://systems/water/water_common.gdshaderinc"

uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 1.0, 0.9);
uniform float foam_width = 0.7;
uniform float foam_noise_scale = 7.0;
uniform float flow_speed : hint_range(0.0, 5.0) = 1.2;
uniform float wave_amplitude = 0.05;
uniform float wave_frequency = 1.4;
uniform float wave_speed = 0.75;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform float time = 0.0;
uniform vec2 chunk_origin_xz = vec2(0.0);
uniform float chunk_size = 32.0;

// Wavelength of the largest ripple on the channel, in metres. Much shorter
// than the ocean's swell — a river is a confined, fast, choppy surface.
uniform float ripple_wavelength = 7.0;

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D terrain_depth_tex : source_color, filter_linear_mipmap, repeat_disable;

varying vec3 v_world_pos;
varying float v_terrain_depth;
varying float v_outlet;

float ripple_base_freq() {
	return 6.2831853 / max(ripple_wavelength, 0.5);
}

// Channel-aligned chop: the shared wave field, advected along the flow so
// ripples travel downstream instead of standing still in world space.
vec3 river_normal(vec2 pos, float along, float t) {
	vec2 drift = vec2(0.0, along * 4.0 + t * flow_speed * 2.4);
	vec3 wn = water_normal(pos + drift, t, ripple_base_freq(), wave_amplitude * 2.2);
	// Stretch across the channel: real flow lines are long, not round.
	return normalize(vec3(wn.x * 0.55, wn.y, wn.z * 1.45));
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 local_uv = clamp((v_world_pos.xz - chunk_origin_xz) / max(chunk_size, 0.001), vec2(0.0), vec2(1.0));
	v_terrain_depth = texture(terrain_depth_tex, local_uv).r;
	// COLOR.g carries the outlet ramp written by RiverSystem: 0 upstream,
	// 1 where the channel opens into the sea.
	v_outlet = clamp(COLOR.g, 0.0, 1.0);
	float depth_factor = mix(0.35, 1.0, v_terrain_depth);
	float chop = water_height(v_world_pos.xz + vec2(0.0, UV.y * 4.0),
		time * flow_speed, ripple_base_freq(), wave_amplitude);
	// The chop dies out at the mouth so the river surface lies flat against
	// the ocean plane it is fading into.
	VERTEX.y += chop * depth_factor * (1.0 - v_outlet);
}

void fragment() {
	float depth_t = clamp(COLOR.r, 0.0, 1.0);
	vec3 wn = river_normal(v_world_pos.xz, UV.y, time * wave_speed);
	float depth_raw = textureLod(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view_depth = INV_PROJECTION_MATRIX * ndc;
	view_depth.xyz /= view_depth.w;
	float scene_depth = -view_depth.z;
	float water_depth = -VERTEX.z;
	float depth_diff = scene_depth - water_depth;
	float depth_blend = max(clamp(depth_diff / 1.8, 0.0, 1.0), v_terrain_depth);
	vec4 water_col = depth_zone_color(depth_blend);
	float edge_factor = 1.0 - smoothstep(0.08, 0.30, min(UV.x, 1.0 - UV.x));
	float foam_factor = 1.0 - clamp(depth_diff / max(foam_width, 0.001), 0.0, 1.0);
	foam_factor = max(foam_factor, edge_factor * (1.0 - smoothstep(0.12, 0.55, depth_t)));
	float fn1 = sin(v_world_pos.x * foam_noise_scale + time * 2.0) * 0.5 + 0.5;
	float fn2 = sin(v_world_pos.z * foam_noise_scale * 0.75 + time * 1.5) * 0.5 + 0.5;
	float fn3 = sin((v_world_pos.x + v_world_pos.z) * foam_noise_scale * 0.5 - time * 1.8) * 0.5 + 0.5;
	float foam_noise = fn1 * fn2 * 0.7 + fn3 * 0.3;
	foam_factor *= step(0.24, foam_noise + foam_factor * 0.35);
	float crest = pow(1.0 - clamp(wn.y, 0.0, 1.0), 3.0) * 1.5;
	foam_factor = max(foam_factor, crest * depth_blend * 0.45);
	// A real river mouth foams where fresh water meets the swell.
	foam_factor = max(foam_factor, v_outlet * (1.0 - v_outlet) * 2.2 * 0.55);

	vec2 refraction_uv = SCREEN_UV + wn.xz * 0.015 * (1.0 - depth_blend);
	vec3 refracted = textureLod(SCREEN_TEXTURE, refraction_uv, 0.0).rgb;
	vec3 final_color = mix(water_col.rgb, foam_color.rgb, foam_factor * 0.68);
	final_color = mix(refracted, final_color, water_col.a);
	float final_alpha = mix(water_col.a, foam_color.a, foam_factor * 0.45);

	ALBEDO = final_color;
	// Fade out into the sea. The river surface and the ocean plane sit at the
	// same height at the mouth, so without this they z-fight across the whole
	// outlet; letting the ocean win the last metres is both cheaper and the
	// correct read — one body of water, not two stacked sheets.
	ALPHA = clamp(final_alpha + depth_blend * 0.22, 0.0, 1.0) * (1.0 - v_outlet);
	NORMAL = mix(vec3(0.0, 1.0, 0.0), wn, mix(0.4, 1.0, depth_blend));
	ROUGHNESS = mix(0.02, roughness, depth_blend);
	METALLIC = metallic;
	SPECULAR = 0.5;
}
