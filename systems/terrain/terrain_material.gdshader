shader_type spatial;

uniform float detail_scale = 0.08;
uniform float detail_strength = 0.12;
uniform float triplanar_sharpness = 3.5;
uniform float macro_detail_scale = 0.028;
uniform float macro_detail_strength = 0.11;
uniform float color_lift_strength = 0.06;
uniform float cliff_strength = 0.45;
uniform float cliff_contrast = 2.0;
uniform vec4 cliff_tint : source_color = vec4(0.48, 0.45, 0.40, 1.0);
uniform float twig_strength = 0.18;
uniform vec4 twig_tint : source_color = vec4(0.35, 0.28, 0.18, 1.0);
uniform float pebble_strength = 0.24;
uniform vec4 pebble_tint : source_color = vec4(0.56, 0.54, 0.50, 1.0);
uniform float sea_level = 0.0;
uniform float height_scale = 35.0;
uniform float rain_amount = 0.0;
uniform float snow_amount = 0.0;
uniform float snow_line = 0.82;
uniform float snow_line_softness = 0.1;
uniform vec4 snow_tint : source_color = vec4(0.93, 0.94, 0.96, 1.0);

varying vec3 v_world_pos;
varying vec3 v_world_normal;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += noise2(p) * amplitude;
		p = p * 2.03 + vec2(17.13, 11.73);
		amplitude *= 0.5;
	}
	return value;
}

vec3 triplanar_weights(vec3 normal) {
	vec3 weights = pow(abs(normal), vec3(triplanar_sharpness));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}


float triplanar_fbm(vec3 world_pos, vec3 weights, float scale) {
	float x_proj = fbm(world_pos.yz * scale);
	float y_proj = fbm(world_pos.xz * scale);
	float z_proj = fbm(world_pos.xy * scale);
	return x_proj * weights.x + y_proj * weights.y + z_proj * weights.z;
}


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 normal = normalize(v_world_normal);
	vec3 tri_weights = triplanar_weights(normal);
	vec3 color = COLOR.rgb;
	float height_t = clamp((v_world_pos.y - sea_level) / max(height_scale, 0.001), 0.0, 1.0);
	float above_water = smoothstep(sea_level + 0.15, sea_level + 1.8, v_world_pos.y);
	float flatness = smoothstep(0.38, 0.92, normal.y);
	float detail = triplanar_fbm(v_world_pos, tri_weights, detail_scale);
	float detail_tint = mix(1.0 - detail_strength, 1.0 + detail_strength, detail);
	color *= detail_tint;
	float macro_detail = triplanar_fbm(v_world_pos + vec3(83.4, 19.1, 47.7), tri_weights, macro_detail_scale);
	float micro_detail = triplanar_fbm(v_world_pos + vec3(14.6, 6.2, 23.8), tri_weights, detail_scale * 15.0);
	vec3 macro_tint = mix(vec3(0.93, 0.98, 0.93), vec3(1.05, 0.98, 0.89), smoothstep(0.28, 0.72, macro_detail));
	color *= mix(vec3(1.0), macro_tint, macro_detail_strength * above_water * (0.45 + flatness * 0.55));
	color = mix(color, color * mix(0.97, 1.045, micro_detail), color_lift_strength * above_water);

	float slope = pow(clamp(1.0 - normal.y, 0.0, 1.0), cliff_contrast);
	color = mix(color, mix(color, cliff_tint.rgb, 0.65), slope * cliff_strength);

	float wetness = rain_amount * smoothstep(0.2, 0.9, normal.y);
	color = mix(color, color * 0.82, wetness * 0.35);

	float twig_noise = triplanar_fbm(v_world_pos + vec3(31.4, 5.8, 11.2), tri_weights, detail_scale * 8.5);
	float pebble_noise = triplanar_fbm(v_world_pos + vec3(47.2, 9.6, 21.5), tri_weights, detail_scale * 6.0);
	float snow_mask = smoothstep(snow_line - snow_line_softness, snow_line + snow_line_softness, height_t);
	float cover_mask = above_water * (1.0 - snow_mask);
	float twig_mask = twig_strength * cover_mask * flatness * smoothstep(0.82, 0.93, twig_noise);
	float pebble_mask = pebble_strength * cover_mask * smoothstep(0.76, 0.92, pebble_noise) * mix(0.35, 1.0, slope + (1.0 - flatness) * 0.4);
	color = mix(color, twig_tint.rgb, twig_mask);
	color = mix(color, pebble_tint.rgb, pebble_mask);
	snow_mask *= snow_amount;
	snow_mask *= smoothstep(0.35, 0.85, normal.y);
	color = mix(color, snow_tint.rgb, snow_mask);

	ALBEDO = color;
	ROUGHNESS = mix(0.95, 0.72, slope * cliff_strength);
	ROUGHNESS = mix(ROUGHNESS, 0.93, twig_mask);
	ROUGHNESS = mix(ROUGHNESS, 0.78, pebble_mask);
	ROUGHNESS = mix(ROUGHNESS, max(0.18, ROUGHNESS * 0.55), wetness);
	SPECULAR = 0.0;
	METALLIC = 0.0;
}
