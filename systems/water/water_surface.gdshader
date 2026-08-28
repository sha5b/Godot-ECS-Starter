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

// ── Shore break ─────────────────────────────────────────────────────────────
//
// What actually happens when a swell reaches a beach, and what this models:
//
//   SHOALING   The wave slows in shallow water, so it shortens and grows
//              taller. Green's law puts amplitude at roughly depth^(-1/4).
//   BREAKING   It topples when wave height over depth passes about 0.78.
//   FOAM       The broken crest leaves whitewater that LINGERS behind it —
//              a sharp front with a decaying trail, not a band that appears
//              and vanishes with the crest.
//   SWASH      The remains run up the sand and drain back, so the foam line
//              itself moves in and out.
//
// Wavefronts follow the depth contours, which is why breakers arrive parallel
// to any shore whatever its shape. Using depth as the phase variable gets that
// for free — the old shader used a fixed world-space diagonal, which is why
// the surf ran at the same angle across every bay in the world.

/// Metres between successive breakers.
uniform float shore_wave_length : hint_range(2.0, 60.0) = 17.0;

/// Seconds between breakers arriving.
uniform float shore_wave_period : hint_range(1.0, 20.0) = 6.5;

/// Depth at which the incoming swell has its unshoaled height.
uniform float shore_reference_depth : hint_range(0.5, 20.0) = 6.0;

/// Cap on the shoaling gain, so waves do not grow without bound at the water line.
uniform float shore_shoal_max : hint_range(1.0, 6.0) = 2.6;

/// Wave-height-over-depth ratio at which the wave breaks. Real value ~0.78.
uniform float shore_break_ratio : hint_range(0.2, 1.2) = 0.72;

/// Depth over which the swash sheet runs up the sand.
uniform float shore_swash_depth : hint_range(0.05, 3.0) = 0.7;

/// How ragged the breaker line is. 0 = a perfect depth contour.
uniform float shore_line_wobble : hint_range(0.0, 3.0) = 0.9;
uniform float shore_line_wobble_scale = 0.035;

// Distance over which the water edge dissolves into the beach. Without it the
// plane simply ends where it intersects the terrain and the waterline is a
// hard cut, visible as a border around every island.
uniform float shoreline_softness : hint_range(0.02, 3.0) = 0.45;

// Two scales, because water works at two scales: the SWELL moves the surface
// (silhouette, long and low) and the CHOP tilts it (shading, short and steep).
// Driving both from one frequency is why the old shader had to choose between
// invisible waves and a visible lattice.
uniform float swell_wavelength = 110.0;   // metres between swell crests
uniform float chop_wavelength = 6.5;      // metres between wind-chop crests
// Dimensionless wave steepness A*k, NOT an amplitude in metres. Gravity waves
// break near 0.44 and open-water wind chop sits nearer 0.1. This one value
// decides whether the surface reads as water or as crumpled foil.
uniform float chop_steepness : hint_range(0.0, 0.44) = 0.075;

// The far-ocean ring is 8 triangles covering hundreds of metres, so vertex
// displacement there produces enormous flat facets instead of waves. The ring
// sets this to 0 and lets the normals carry the whole look.
uniform float displacement_scale : hint_range(0.0, 1.0) = 1.0;

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



// Incoming surf at a point. Returns vec2(surface displacement, foam 0..1).
vec2 shore_break(float depth_m, vec2 world_xz, float t) {
	float d = max(depth_m, 0.04);

	// Green's law: energy is conserved as the wave slows, so it grows.
	float shoal = clamp(pow(shore_reference_depth / d, 0.25), 1.0, shore_shoal_max);
	float amp = wave_amplitude * shore_break_strength * shoal;

	// Depth is the phase variable, so crests follow the depth contours and
	// arrive parallel to the shore whatever shape it is. The noise term makes
	// the breaker line ragged instead of a perfect contour.
	float wobble = noised(world_xz * shore_line_wobble_scale).x * shore_line_wobble;
	float k = 6.2831853 / max(shore_wave_length, 1.0);
	float phase = (d + wobble) * k - t * (6.2831853 / max(shore_wave_period, 0.5));
	float sn = sin(phase);

	// Breaking index: wave height over water depth.
	float breaking = smoothstep(shore_break_ratio * 0.55, shore_break_ratio,
		(amp * 2.0) / d);

	// Sharp foaming front, long decaying trail behind it. This asymmetry is
	// what makes surf read as whitewater left BEHIND a wave rather than a
	// stripe travelling with it.
	float front = pow(max(sn, 0.0), 4.0);
	float trail = pow(max(-sn, 0.0), 0.5) * 0.6;
	float foam = breaking * max(front, trail);

	// Swash: the thin sheet running up the sand and draining back.
	float swash = (1.0 - smoothstep(0.0, shore_swash_depth, d)) * (sn * 0.5 + 0.5);
	foam = max(foam, swash);

	// A breaking wave loses height as it collapses.
	return vec2(amp * sn * (1.0 - breaking * 0.55), clamp(foam, 0.0, 1.0));
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
// The depth texture has one texel per heightmap sample, and the outer samples
// sit ON the chunk boundary. Sampling at raw UV 0..1 reads half a texel past
// those centres and clamps, so neighbouring chunks disagree along their shared
// edge — a grid of seams straight through the shoreline.
float sample_terrain_depth(vec2 uv) {
	vec2 res = vec2(textureSize(terrain_depth_tex, 0));
	vec2 inset = (uv * (res - 1.0) + 0.5) / res;
	return texture(terrain_depth_tex, inset).r;
}

void vertex() {
	v_terrain_depth = sample_terrain_depth(UV);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_pos = world_pos;

	float depth_factor = smoothstep(shore_wave_min_depth, shore_wave_max_depth, v_terrain_depth);

	// The open-water displacement is the same non-repeating field the normal
	// uses, so crests in the silhouette line up with crests in the shading.
	// Gerstner: the surface rolls, so the vertex moves sideways as well as up.
	vec3 swell = water_displacement(world_pos.xz, time * wave_speed,
		swell_wavelength, wave_amplitude);
	float depth_m = v_terrain_depth * shore_depth_range;
	vec2 surf = shore_break(depth_m, world_pos.xz, time);

	VERTEX.y += (swell.y * depth_factor + surf.x * (1.0 - depth_factor))
		* displacement_scale;
	// In-plane roll, only in open water — near shore the plane must stay put
	// or it tears away from the coastline it is supposed to meet.
	VERTEX.xz += swell.xz * depth_factor * displacement_scale;
}

void fragment() {
	float depth_factor = smoothstep(shore_wave_min_depth, shore_wave_max_depth, v_terrain_depth);

	// Shading normal comes from the short chop; the long swell contributes
	// almost no slope and would leave the surface looking like glass.
	vec3 wn = water_normal(v_world_pos.xz, time * wave_speed, chop_wavelength,
		chop_steepness);
	// Rain roughens the surface on top of the wind chop.
	vec3 rain_n = rain_ripple_normal(v_world_pos.xz, time);
	wn = normalize(wn + vec3(rain_n.x, 0.0, rain_n.z));
	wn = fade_detail_normal(wn, v_world_pos, CAMERA_POSITION_WORLD);
	wn = fade_detail_normal(wn, v_world_pos, CAMERA_POSITION_WORLD);

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

	// Shore foam — animated, patchy, with noise breakup.
	// Driven by the per-pixel screen-space depth, not by the one-texel-per-
	// metre terrain depth texture, so the foam band follows the real waterline
	// instead of the heightmap grid.
	float foam_factor = 1.0 - clamp(depth_diff / foam_width, 0.0, 1.0);
	foam_factor = max(foam_factor, (1.0 - smoothstep(0.0, foam_width * 1.8, depth_diff)) * 0.9);

	// Multi-frequency foam noise for organic look
	float fn1 = sin(v_world_pos.x * foam_noise_scale + time * 2.0) * 0.5 + 0.5;
	float fn2 = sin(v_world_pos.z * foam_noise_scale * 0.75 + time * 1.5) * 0.5 + 0.5;
	float fn3 = sin((v_world_pos.x + v_world_pos.z) * foam_noise_scale * 0.5 - time * 1.8) * 0.5 + 0.5;
	float foam_noise = fn1 * fn2 * 0.7 + fn3 * 0.3;
	foam_factor *= step(0.25, foam_noise + foam_factor * 0.4);

	// Surf foam from the same break model the vertex pass displaces with, so
	// the whitewater sits on the waves that produced it.
	vec2 surf = shore_break(v_terrain_depth * shore_depth_range, v_world_pos.xz, time);
	foam_factor = max(foam_factor, surf.y * (1.0 - depth_factor));

	// Whitecaps. Real seas only break above roughly force 4, so coverage is
	// driven by the weather rather than being present at every wind speed.
	float crest = pow(1.0 - clamp(wn.y, 0.0, 1.0), 3.0) * 2.0;
	float whitecap = smoothstep(0.35, 0.9, sea_state);
	foam_factor = max(foam_factor, crest * depth_factor * whitecap);

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
	// Feather the last centimetres so the waterline blends into wet sand
	// instead of ending on a hard cut you can see around every island.
	//
	// depth_diff is a VIEW-space distance: at a grazing angle a few
	// centimetres of water stretch over metres of view depth, so the band is
	// scaled by the viewing angle or shallow bays vanish entirely.
	float grazing = max(abs(normalize(VIEW).z), 0.2);
	float shoreline = smoothstep(0.0, shoreline_softness / grazing, depth_diff);
	ALPHA = clamp(final_alpha + depth_blend * 0.26 + fresnel * 0.12, 0.0, 1.0)
		* mix(1.0, shoreline, 0.8);
	NORMAL = mix(vec3(0.0, 1.0, 0.0), wn, depth_factor);
	// Calm water is near mirror, a whipped-up sea scatters. Roughness follows
	// the weather so a storm does not stay glassy.
	ROUGHNESS = mix(mix(0.03, 0.22, sea_state), roughness + sea_state * 0.25, depth_blend);
	METALLIC = metallic;
	SPECULAR = 0.5;
}
