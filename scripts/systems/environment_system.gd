extends Node2D

# Environment system that handles weather, time, and other environmental effects

# Get reference to autoloaded GameManager
@onready var game_manager = get_node("/root/GameManager")

# Weather settings
var current_weather: String = "clear"
var weather_intensity: float = 0.5
var weather_transition_time: float = 3.0
var is_transitioning: bool = false

# Weather particles
var rain_particles: GPUParticles2D
var snow_particles: GPUParticles2D
var fog_particles: GPUParticles2D

# Time settings
var game_time: float = 0.0  # In hours
var day_length: float = 24.0  # Minutes in real-time for a full day
var time_scale: float = 1.0  # Time multiplier
var current_hour: int = 12  # Start at noon

# Day/night cycle
var environment_tint: Color = Color(1, 1, 1)
var night_tint: Color = Color(0.2, 0.2, 0.4, 0.7)
var day_tint: Color = Color(1, 1, 1)
var canvas_modulate: CanvasModulate

func _ready():
	print("Environment system initialized")
	
	# Initialize components
	_setup_weather_particles()
	_setup_day_night_cycle()
	
	# Set initial state
	set_weather("clear", 0.5)

func _process(delta):
	# Update time
	_update_time(delta)
	
	# Update weather particles if transitioning
	if is_transitioning:
		_update_weather_transition(delta)

func _setup_weather_particles():
	# Rain particles
	rain_particles = GPUParticles2D.new()
	rain_particles.name = "RainParticles"
	
	var rain_material = ParticleProcessMaterial.new()
	rain_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	rain_material.emission_box_extents = Vector3(1280, 10, 1)
	rain_material.direction = Vector3(0.3, 1, 0)
	rain_material.spread = 5.0
	rain_material.gravity = Vector3(0, 980, 0)
	rain_material.initial_velocity_min = 400.0
	rain_material.initial_velocity_max = 600.0
	rain_material.scale_min = 0.3
	rain_material.scale_max = 0.6
	rain_material.color = Color(0.7, 0.8, 1.0, 0.7)
	
	rain_particles.process_material = rain_material
	rain_particles.lifetime = 1.2
	rain_particles.preprocess = 0.6
	rain_particles.randomness = 1.0
	rain_particles.fixed_fps = 30
	rain_particles.amount = 1000
	rain_particles.position = Vector2(640, -100)
	rain_particles.emitting = false
	
	# Snow particles
	snow_particles = GPUParticles2D.new()
	snow_particles.name = "SnowParticles"
	
	var snow_material = ParticleProcessMaterial.new()
	snow_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	snow_material.emission_box_extents = Vector3(1280, 10, 1)
	snow_material.direction = Vector3(0.1, 1, 0)
	snow_material.spread = 15.0
	snow_material.gravity = Vector3(0, 30, 0)
	snow_material.initial_velocity_min = 50.0
	snow_material.initial_velocity_max = 100.0
	snow_material.scale_min = 1.0
	snow_material.scale_max = 3.0
	snow_material.color = Color(1, 1, 1, 0.8)
	snow_material.hue_variation_min = -0.1
	snow_material.hue_variation_max = 0.1
	
	snow_particles.process_material = snow_material
	snow_particles.lifetime = 20.0
	snow_particles.preprocess = 10.0
	snow_particles.randomness = 1.0
	snow_particles.fixed_fps = 30
	snow_particles.amount = 500
	snow_particles.position = Vector2(640, -100)
	snow_particles.emitting = false
	
	# Fog particles
	fog_particles = GPUParticles2D.new()
	fog_particles.name = "FogParticles"
	
	var fog_material = ParticleProcessMaterial.new()
	fog_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	fog_material.emission_box_extents = Vector3(1280, 720, 1)
	fog_material.direction = Vector3(1, 0, 0)
	fog_material.spread = 30.0
	fog_material.gravity = Vector3(0, 0, 0)
	fog_material.initial_velocity_min = 2.0
	fog_material.initial_velocity_max = 5.0
	fog_material.scale_min = 50.0
	fog_material.scale_max = 100.0
	fog_material.color = Color(0.8, 0.8, 0.9, 0.1)
	
	fog_particles.process_material = fog_material
	fog_particles.lifetime = 30.0
	fog_particles.preprocess = 15.0
	fog_particles.randomness = 1.0
	fog_particles.fixed_fps = 30
	fog_particles.amount = 30
	fog_particles.position = Vector2(640, 360)
	fog_particles.emitting = false
	
	# Add particles to scene
	add_child(rain_particles)
	add_child(snow_particles)
	add_child(fog_particles)
	
	print("Weather particles initialized")

func _setup_day_night_cycle():
	# Create canvas modulate for day/night cycle
	canvas_modulate = CanvasModulate.new()
	canvas_modulate.name = "DayNightCycle"
	canvas_modulate.color = environment_tint
	
	add_child(canvas_modulate)
	
	print("Day/night cycle initialized")

func _update_time(delta):
	# Update game time
	var real_seconds_per_day = day_length * 60.0
	var time_increment = (delta * time_scale * 24.0) / real_seconds_per_day
	
	game_time += time_increment
	if game_time >= 24.0:
		game_time -= 24.0
	
	current_hour = int(game_time)
	
	# Update environment based on time
	_update_day_night_cycle()

func _update_day_night_cycle():
	# Calculate the daylight factor (0 = midnight, 1 = noon)
	var daylight_factor = 0.0
	
	if game_time < 6.0:  # Midnight to dawn
		daylight_factor = game_time / 6.0 * 0.25  # 0 to 0.25
	elif game_time < 12.0:  # Dawn to noon
		daylight_factor = 0.25 + (game_time - 6.0) / 6.0 * 0.75  # 0.25 to 1
	elif game_time < 18.0:  # Noon to dusk
		daylight_factor = 1.0 - (game_time - 12.0) / 6.0 * 0.75  # 1 to 0.25
	else:  # Dusk to midnight
		daylight_factor = 0.25 - (game_time - 18.0) / 6.0 * 0.25  # 0.25 to 0
	
	# Interpolate between night and day tints
	environment_tint = day_tint.lerp(night_tint, 1.0 - daylight_factor)
	
	# Apply to the canvas modulate
	canvas_modulate.color = environment_tint

func set_weather(weather_type: String, intensity: float = 0.5):
	print("Changing weather to: ", weather_type, " at intensity: ", intensity)
	
	# Validate parameters
	weather_type = weather_type.to_lower()
	intensity = clamp(intensity, 0.0, 1.0)
	
	# Store settings
	current_weather = weather_type
	weather_intensity = intensity
	
	# Set particle emission
	_update_weather_particles(weather_type, intensity)

func _update_weather_particles(weather_type: String, intensity: float):
	# Update particle settings based on weather type and intensity
	match weather_type:
		"rain":
			rain_particles.emitting = true
			snow_particles.emitting = false
			fog_particles.emitting = false
			rain_particles.amount = int(1000 * intensity)
		"snow":
			rain_particles.emitting = false
			snow_particles.emitting = true
			fog_particles.emitting = false
			snow_particles.amount = int(500 * intensity)
		"fog":
			rain_particles.emitting = false
			snow_particles.emitting = false
			fog_particles.emitting = true
			fog_particles.amount = int(30 * intensity)
			
			# Adjust fog opacity based on intensity
			var material = fog_particles.process_material
			material.color = Color(0.8, 0.8, 0.9, 0.1 * intensity)
		_:  # Clear weather
			rain_particles.emitting = false
			snow_particles.emitting = false
			fog_particles.emitting = false

func transition_weather(weather_type: String, intensity: float = 0.5, transition_time: float = 3.0):
	# Start a transition between weather states
	print("Starting weather transition to: ", weather_type)
	
	# Set up transition parameters
	weather_transition_time = transition_time
	is_transitioning = true
	
	# Set up target state
	current_weather = weather_type
	weather_intensity = intensity
	
	# Begin transition (the actual transition happens in _update_weather_transition)

func _update_weather_transition(delta):
	# Handle weather transition over time
	# This would gradually fade between weather types
	# For this simple version, just set the weather directly
	_update_weather_particles(current_weather, weather_intensity)
	is_transitioning = false

func get_time_string() -> String:
	# Return a formatted time string (HH:MM)
	var hour = int(game_time)
	var minute = int((game_time - hour) * 60)
	
	return "%02d:%02d" % [hour, minute]

func get_weather_description() -> String:
	# Return a description of the current weather
	var intensity_text = ""
	
	if weather_intensity < 0.3:
		intensity_text = "Light "
	elif weather_intensity > 0.7:
		intensity_text = "Heavy "
	
	match current_weather:
		"rain":
			return intensity_text + "Rain"
		"snow":
			return intensity_text + "Snow"
		"fog":
			return intensity_text + "Fog"
		_:
			return "Clear Skies"
