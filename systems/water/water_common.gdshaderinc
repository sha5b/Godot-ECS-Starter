// Shared water surface model for the ocean (water_surface.gdshader) and the
// rivers (river_surface.gdshader).
//
// Both bodies of water used to carry their own copy of the wave normal and
// their own depth palette, so a river mouth met the sea as two visibly
// different materials. One include means one look.

// ── Wave field ───────────────────────────────────────────────────────────────
//
// Gerstner waves with noise-bent crests.
//
// Two earlier models failed here and both failures are instructive:
//
//   A sum of plain sine waves is exactly periodic and every component is a
//   straight-crested plane wave, so open water reads as diagonal corduroy.
//
//   Translating a frozen noise field fixes the stripes but reads as a texture
//   sliding sideways, because a real wave does not move the water along with
//   it. The water orbits in place while the PHASE propagates.
//
// Gerstner solves the second problem properly: each component displaces the
// surface vertically by A*sin(theta) and horizontally by -dir*A*cos(theta), so
// a particle traces a circle and the surface rolls. Crests come out narrow and
// troughs broad for free, which is what real gravity waves look like.
//
// The remaining problem is that Gerstner components are still plane waves. The
// fix is to bend each component's phase with a slowly varying noise field:
// crests become long curved ridges that drift and reform instead of ruler
// straight lines, and no two components bend alike.
//
// Angular frequency uses the deep-water dispersion relation omega = sqrt(g*k),
// so long waves outrun short ones and the sea state never repeats in view.

uniform float wave_choppiness : hint_range(0.0, 1.5) = 0.7;
uniform float wave_phase_jitter : hint_range(0.0, 3.0) = 1.6;
uniform float wave_direction_spread : hint_range(0.0, 1.6) = 1.15;
uniform float wave_group_scale = 0.004;
uniform float wave_group_depth : hint_range(0.0, 1.0) = 0.45;
// ── Weather coupling ────────────────────────────────────────────────────────
//
// The sea is downstream of the weather, not a fixed decoration. WaterSystem
// pushes these every frame from SharedWorld, so wind turns the swell, a rising
// wind builds the sea, and rain stipples the surface.
//
// wind_dir used to be a uniform that nothing ever wrote, so every component
// fanned around the same fixed easterly bearing for the whole game.

uniform vec2 wind_dir = vec2(1.0, 0.0);

/// 0 = glassy calm, 1 = full gale. Scales steepness and whitecap coverage.
uniform float sea_state : hint_range(0.0, 1.0) = 0.35;

/// Rain intensity 0..1. Rain flattens swell and stipples the surface.
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;

const int WAVE_COMPONENTS = 5;
const float GOLDEN_ANGLE = 2.39996323;
const float GRAVITY = 9.81;

mat2 rot2(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(vec2(c, -s), vec2(s, c));
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Value noise plus its analytic gradient: vec3(value, d/dx, d/dy) in [-1, 1].
vec3 noised(vec2 x) {
	vec2 p = floor(x);
	vec2 w = fract(x);
	vec2 u = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * w * w * (w * (w - 2.0) + 1.0);

	float a = hash12(p);
	float b = hash12(p + vec2(1.0, 0.0));
	float c = hash12(p + vec2(0.0, 1.0));
	float d = hash12(p + vec2(1.0, 1.0));

	float k1 = b - a;
	float k2 = c - a;
	float k3 = a - b - c + d;

	return vec3(
		-1.0 + 2.0 * (a + k1 * u.x + k2 * u.y + k3 * u.x * u.y),
		2.0 * du.x * (k1 + k3 * u.y),
		2.0 * du.y * (k2 + k3 * u.x));
}

// Swell groups: broad patches of calmer and rougher water, so open sea is not
// uniformly textured from horizon to horizon.
float wave_group_envelope(vec2 pos, float t) {
	float g = noised(pos * wave_group_scale + vec2(t * 0.015, -t * 0.011)).x;
	return mix(1.0 - wave_group_depth, 1.0, g * 0.5 + 0.5);
}

struct WaveSample {
	float height;      // vertical displacement
	vec2 horizontal;   // Gerstner in-plane displacement (the rolling)
	vec2 gradient;     // d(height)/d(x, z), for the normal
};

// `steepness` is the DIMENSIONLESS wave steepness A*k of the first component,
// not an amplitude in metres.
//
// This distinction is the whole difference between water and tinfoil. Surface
// slope is A*k, so passing a fixed amplitude makes short waves arbitrarily
// steep: a 0.55 m amplitude on a 6.5 m wave is a slope of 0.53, a surface
// tilted 28 degrees at every crest, and five of those summed gave the
// interference pattern this shader used to draw. Real wind chop sits near
// 0.05-0.15 and breaks around 0.44.
//
// `components` lets the vertex pass run a cheap 2-component version:
// displacement only needs the long swell, and it runs per vertex.
WaveSample gerstner_waves(vec2 pos, float t, float base_length, float steepness,
		int components) {
	WaveSample o;
	o.height = 0.0;
	o.horizontal = vec2(0.0);
	o.gradient = vec2(0.0);

	vec2 wind = normalize(wind_dir + vec2(1e-5, 0.0));
	float wind_angle = atan(wind.y, wind.x);

	float wavelength = max(base_length, 0.25);
	// A calm sea is not a small copy of a rough one: it is the same waves with
	// far less slope. Steepness is the dial the weather turns.
	float steep = steepness * mix(0.35, 1.55, clamp(sea_state, 0.0, 1.0));

	for (int i = 0; i < components; i++) {
		float fi = float(i);
		// Fan the components around the wind instead of stacking them on one
		// bearing. A single bearing is what turns any wave sum into stripes.
		float offset = (hash12(vec2(fi, 17.3)) * 2.0 - 1.0) * wave_direction_spread;
		vec2 dir = rot2(wind_angle + offset) * vec2(1.0, 0.0);

		float k = 6.2831853 / wavelength;
		float omega = sqrt(GRAVITY * k);
		// Amplitude follows from steepness, so every component keeps the same
		// slope budget no matter how short it is.
		float amp = steep / k;

		// Phase jitter varies over a few wavelengths, so it bends the crest
		// line without destroying the wave.
		float jitter_scale = 0.22 / wavelength;
		vec3 jitter = noised(pos * jitter_scale + vec2(fi * 31.7, fi * 11.3));
		float theta = dot(dir, pos) * k - omega * t + jitter.x * wave_phase_jitter;
		vec2 dtheta = dir * k + vec2(jitter.y, jitter.z) * jitter_scale * wave_phase_jitter;

		float st = sin(theta);
		float ct = cos(theta);

		o.height += amp * st;
		o.gradient += amp * ct * dtheta;
		// Negative sign: water piles INTO the crest, which is what narrows it.
		o.horizontal -= dir * (amp * wave_choppiness * ct);

		// Deliberately not 0.5. Halving makes the components harmonics of one
		// another, and harmonics beat into the regular moire that reads as a
		// woven fabric rather than water.
		wavelength *= 0.593;
		steep *= 0.66;
	}
	return o;
}

vec3 water_normal(vec2 pos, float t, float base_length, float steepness) {
	WaveSample w = gerstner_waves(pos, t, base_length,
		steepness * wave_group_envelope(pos, t), WAVE_COMPONENTS);
	return normalize(vec3(-w.gradient.x, 1.0, -w.gradient.y));
}


// Detail normals must fade with distance.
//
// Chop a few metres long is smaller than a pixel once the surface is far
// away, especially at the grazing angles an overhead camera looks at water
// from. Keeping it at full strength aliases into shimmering moire; flattening
// it toward straight up is what real distant water looks like anyway.
uniform float chop_fade_start = 40.0;
uniform float chop_fade_end = 220.0;

// Rain ripples: short, isotropic, and gone the moment the rain stops.
vec3 rain_ripple_normal(vec2 pos, float t) {
	if (rain_intensity <= 0.001) {
		return vec3(0.0, 1.0, 0.0);
	}
	vec3 a = noised(pos * 1.7 + vec2(t * 1.9, -t * 2.3));
	vec3 b = noised(pos * 3.1 - vec2(t * 2.7, t * 1.5));
	vec2 g = (vec2(a.y, a.z) * 1.7 + vec2(b.y, b.z) * 3.1) * 0.02 * rain_intensity;
	return normalize(vec3(-g.x, 1.0, -g.y));
}


vec3 fade_detail_normal(vec3 n, vec3 world_pos, vec3 camera_pos) {
	float d = length(world_pos - camera_pos);
	float keep = 1.0 - smoothstep(chop_fade_start, chop_fade_end, d);
	return normalize(mix(vec3(0.0, 1.0, 0.0), n, keep));
}

// Vertical + horizontal displacement for the vertex pass. Two components:
// a swell silhouette needs the long waves and nothing else.
// `amplitude` here IS in metres — the caller knows the swell wavelength, so it
// converts to steepness for us.
vec3 water_displacement(vec2 pos, float t, float base_length, float amplitude) {
	float steepness = amplitude * 6.2831853 / max(base_length, 0.25);
	WaveSample w = gerstner_waves(pos, t, base_length,
		steepness * wave_group_envelope(pos, t), 2);
	return vec3(w.horizontal.x, w.height, w.horizontal.y);
}

// ── Shared depth palette ─────────────────────────────────────────────────────
//
// River and ocean read the same four zones, so water is one material family
// no matter which system drew the surface.
uniform vec4 shore_color : source_color = vec4(0.30, 0.65, 0.60, 0.35);
uniform vec4 shallow_color : source_color = vec4(0.15, 0.45, 0.55, 0.6);
uniform vec4 mid_color : source_color = vec4(0.08, 0.28, 0.42, 0.75);
uniform vec4 deep_color : source_color = vec4(0.03, 0.08, 0.20, 0.92);
uniform float mid_depth_start = 0.25;
uniform float deep_depth_start = 0.6;

vec4 depth_zone_color(float d) {
	if (d < mid_depth_start) {
		return mix(shore_color, shallow_color, smoothstep(0.0, 1.0, d / max(mid_depth_start, 0.001)));
	} else if (d < deep_depth_start) {
		float t = (d - mid_depth_start) / max(deep_depth_start - mid_depth_start, 0.001);
		return mix(shallow_color, mid_color, smoothstep(0.0, 1.0, t));
	}
	float t = (d - deep_depth_start) / max(1.0 - deep_depth_start, 0.001);
	return mix(mid_color, deep_color, smoothstep(0.0, 1.0, min(t, 1.0)));
}
