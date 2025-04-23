extends Resource
class_name WeatherState

# --- Basic Weather Parameters ---
@export var state_name: String = "Clear"
@export var precipitation_type: String = "none" # e.g., "none", "rain", "snow"
@export var precipitation_intensity: float = 0.0 # 0.0 to 1.0
@export var wind_direction: Vector2 = Vector2.RIGHT # Normalized direction
@export var wind_speed: float = 5.0 # In some relevant unit (e.g., m/s)
@export var temperature_modifier: float = 0.0 # Degrees Celsius offset from base
# @export var cloud_coverage: float = 0.1 # 0.0 (clear) to 1.0 (overcast) # Removed cloud coverage
@export var visibility: float = 1.0 # 0.0 (dense fog) to 1.0 (clear)

# --- Visual/Audio Effects (Placeholders - Link to actual effect resources later) ---
# @export var sky_shader_params: Dictionary = {}
# @export var precipitation_particle: PackedScene = null
# @export var ambient_sound: AudioStream = null
# @export var lightning_enabled: bool = false

# --- Transition Info ---
# @export var typical_duration: float = 600.0 # How long this state might last (seconds)
# @export var possible_next_states: Array[Resource] # Array of WeatherState resources

func _init():
	# Default values can also be set here if not using @export or for complex setup
	pass
