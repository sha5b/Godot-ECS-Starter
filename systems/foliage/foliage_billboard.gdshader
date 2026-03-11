shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform bool billboard = true;
uniform sampler2D shape_texture : source_color;
uniform sampler2D shape_atlas : source_color;
uniform bool use_atlas = true;
uniform sampler2D noise_texture : source_color;
uniform sampler2D color_gradient : source_color;
uniform sampler2D wind_texture : source_color;
uniform vec2 wind_velocity = vec2(0.0);
uniform float random_variation = 0.12;
uniform float alpha_cut_start = 0.14;
uniform float alpha_cut_end = 0.72;
uniform float bend_strength = 0.42;

varying flat int id;
varying vec3 world_pos;
varying vec4 instance_data;
varying vec3 ground_tint;

vec2 atlas_uv(vec2 uv, int index, int size) {
	int tile_count = size * size;
	int i = index % tile_count;
	float x = float(i % size);
	float y = float(i / size);
	vec2 tile_size = 1.0 / vec2(float(size));
	return uv * tile_size + (vec2(x, y) * tile_size);
}

float randomf(int index, int seed) {
	return sin(float(index + seed)) * 0.5 + 0.5;
}

float wind_noise(vec3 sample_pos) {
	return texture(wind_texture, sample_pos.xz * 0.03 - (TIME * 0.01) * wind_velocity).r;
}

vec3 wind_offset(vec2 uv, vec3 sample_pos) {
	float noise = wind_noise(sample_pos);
	float affect = pow(clamp(uv.y, 0.0, 1.0), 1.6);
	vec3 offset = vec3(noise * wind_velocity.x, 0.0, noise * wind_velocity.y);
	offset *= bend_strength * affect;
	return offset;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	id = INSTANCE_ID;
	instance_data = INSTANCE_CUSTOM;
	ground_tint = COLOR.rgb;
	if (billboard) {
		vec3 model_origin = MODEL_MATRIX[3].xyz;
		vec3 model_up = normalize(MODEL_MATRIX[1].xyz);
		vec3 view_dir = normalize(CAMERA_POSITION_WORLD - model_origin);
		vec3 billboard_right = cross(model_up, view_dir);
		if (length(billboard_right) < 0.0001) {
			billboard_right = normalize(MODEL_MATRIX[0].xyz);
		} else {
			billboard_right = normalize(billboard_right);
		}
		vec3 billboard_forward = normalize(cross(billboard_right, model_up));
		vec3 scaled_right = billboard_right * length(MODEL_MATRIX[0].xyz);
		vec3 scaled_up = model_up * length(MODEL_MATRIX[1].xyz);
		vec3 scaled_forward = billboard_forward * length(MODEL_MATRIX[2].xyz);
		mat4 billboard_matrix = mat4(
			vec4(scaled_right, 0.0),
			vec4(scaled_up, 0.0),
			vec4(scaled_forward, 0.0),
			MODEL_MATRIX[3]
		);
		MODELVIEW_MATRIX = VIEW_MATRIX * billboard_matrix;
		VERTEX += (VIEW_MATRIX * vec4(wind_offset(UV, world_pos), 0.0)).xyz;
	} else {
		VERTEX += wind_offset(UV, world_pos);
	}
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	float shape_value = texture(shape_texture, UV).r;
	if (use_atlas) {
		int sprite_index = int(floor(clamp(instance_data.r, 0.0, 0.999) * 4.0));
		shape_value = texture(shape_atlas, atlas_uv(UV, sprite_index, 2)).r;
	}
	shape_value = smoothstep(0.03, 0.94, shape_value);
	float noise_value = texture(noise_texture, world_pos.xz * 0.08).r;
	float lushness = clamp(instance_data.g, 0.0, 1.0);
	float dryness = clamp(instance_data.b, 0.0, 1.0);
	float height_bias = clamp(instance_data.a, 0.0, 1.0);
	if (randomf(id, 1) < random_variation) {
		noise_value = min(noise_value + 0.18, 1.0);
	}
	vec3 color = texture(color_gradient, vec2(noise_value, 0.0)).rgb;
	color = mix(color, ground_tint, 0.58);
	color = mix(color, color * vec3(0.95, 1.14, 0.94), lushness * 0.28);
	color = mix(color, color * vec3(1.08, 1.0, 0.84), dryness * 0.14);
	color = mix(color, color * vec3(0.9, 0.97, 1.02), height_bias * 0.08);
	color *= mix(0.88, 1.18, UV.y);
	color *= mix(vec3(0.96, 0.92, 0.86), vec3(1.0, 1.0, 1.0), clamp(noise_value * 1.2, 0.0, 1.0));
	float alpha = clamp((shape_value - alpha_cut_start) / max(alpha_cut_end - alpha_cut_start, 0.001), 0.0, 1.0);
	if (alpha < 0.1) {
		discard;
	}
	ALBEDO = color * 1.04;
	ALPHA = alpha;
	ROUGHNESS = 0.91;
	SPECULAR = 0.04;
}
