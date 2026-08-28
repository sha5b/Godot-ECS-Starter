// Shared water surface model for the ocean (water_surface.gdshader) and the
// rivers (river_surface.gdshader).
//
// Both bodies of water used to carry their own copy of the wave normal and
// their own depth palette, so a river mouth met the sea as two visibly
// different materials. One include means one look.

// ── Wave field ───────────────────────────────────────────────────────────────
//
// A short sum of pure sine waves is EXACTLY periodic: the crests line up on a
// lattice and open water reads as corduroy, which is what the old six-sine
// wave_normal() did. Three things break that up here:
//
//   1. Each octave is rotated by the golden angle, so no two octaves share an
//      axis and the sum never lines up into stripes.
//   2. Octave frequencies step by an irrational ratio, so no two octaves beat
//      against each other on a short period.
//   3. Every octave is sampled at a position warped by the octave below it.
//      Domain warping is what turns a regular wave train into a field that
//      never repeats within sight.
//
// Crest sharpening (WAVE_SHARPNESS) then trades the sinusoid's symmetric
// profile for sharp crests over broad troughs, the way real gravity waves
// look, and a very low frequency envelope adds swell groups so open sea has
// calm patches and choppy patches instead of uniform texture everywhere.

const float GOLDEN_ANGLE = 2.39996323;
const float FREQ_RATIO = 1.7548776662;   // silver-ratio-ish, deliberately irrational
const int WAVE_OCTAVES = 7;

uniform float wave_sharpness : hint_range(1.0, 6.0) = 2.4;
uniform float wave_group_scale = 0.0035;
uniform float wave_group_depth : hint_range(0.0, 1.0) = 0.55;
uniform float wave_warp_strength : hint_range(0.0, 3.0) = 1.35;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_alignment : hint_range(0.0, 1.0) = 0.6;

mat2 rot2(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(vec2(c, -s), vec2(s, c));
}

// Swell-group envelope: broad patches of calmer and rougher water.
float wave_group_envelope(vec2 pos, float t) {
	float g = sin(pos.x * wave_group_scale + t * 0.05)
		* sin(pos.y * wave_group_scale * 0.83 - t * 0.037)
		* sin((pos.x + pos.y) * wave_group_scale * 0.61 + t * 0.028);
	return mix(1.0 - wave_group_depth, 1.0, g * 0.5 + 0.5);
}

// Height and analytic XZ gradient of the wave field at `pos`.
// Returns vec3(height, d/dx, d/dz).
vec3 wave_field(vec2 pos, float t, float base_freq, float amplitude) {
	vec3 acc = vec3(0.0);
	float freq = base_freq;
	float amp = amplitude;
	float angle = 0.0;
	vec2 warp = vec2(0.0);
	// Waves travel downwind; wind_alignment 0 keeps the old omnidirectional
	// chop, 1 makes every octave march with the wind.
	vec2 wind = normalize(wind_dir + vec2(1e-5, 0.0));

	for (int i = 0; i < WAVE_OCTAVES; i++) {
		mat2 r = rot2(angle);
		vec2 dir = normalize(mix(r * vec2(1.0, 0.0), wind, wind_alignment * 0.75));
		// Each octave rides on the displacement of the one below it.
		vec2 p = pos + warp * wave_warp_strength / max(freq, 0.0001);
		float phase = dot(p, dir) * freq + t * sqrt(9.81 * freq);

		float s = sin(phase);
		// Sharpened crest profile: (0.5+0.5*sin)^k, remapped back to [-1, 1].
		float c01 = pow(s * 0.5 + 0.5, wave_sharpness);
		float dc = wave_sharpness * pow(s * 0.5 + 0.5, wave_sharpness - 1.0) * 0.5 * cos(phase);

		acc.x += amp * (c01 * 2.0 - 1.0);
		acc.y += amp * 2.0 * dc * dir.x * freq;
		acc.z += amp * 2.0 * dc * dir.y * freq;

		warp += vec2(c01 - 0.5) * amp * dir;
		angle += GOLDEN_ANGLE;
		freq *= FREQ_RATIO;
		amp *= 0.62;
	}
	return acc;
}

vec3 water_normal(vec2 pos, float t, float base_freq, float steepness) {
	float envelope = wave_group_envelope(pos, t);
	vec3 f = wave_field(pos, t, base_freq, steepness * envelope);
	return normalize(vec3(-f.y, 1.0, -f.z));
}

float water_height(vec2 pos, float t, float base_freq, float amplitude) {
	return wave_field(pos, t, base_freq, amplitude * wave_group_envelope(pos, t)).x;
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
