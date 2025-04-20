extends Node

# Main scene script to initialize and hold primary nodes/managers

# @onready var camera: IsometricCamera = $IsometricCamera
# @onready var terrain_manager: TerrainManager = $TerrainManager
# @onready var weather_manager: WeatherManager = $WeatherManager

func _ready() -> void:
	print("Main Scene Ready.")
	# Initialization logic can go here
	# Example: Connect camera movement to terrain manager for region updates
	# if camera and terrain_manager:
	#	 camera.position_changed.connect(terrain_manager.update_active_regions) # Assuming camera emits a signal

	# Example: Connect weather changes to terrain visualization (when implemented)
	# if weather_manager and terrain_manager:
	#	 weather_manager.weather_state_changed.connect(terrain_manager.on_weather_changed) # Assuming terrain manager has this method

	# Access autoloads directly
	print("Current Game Time: ", WorldState.get_current_time())
	EventBus.connect("day_passed", _on_day_passed) # Example connection


func _on_day_passed() -> void:
	print("A new day has dawned!")
