extends Node

# Main scene script to initialize and hold primary nodes/managers

const World = preload("res://ecs/World.gd")
const MoveSystem = preload("res://ecs/systems/MoveSystem.gd")
const Position = preload("res://ecs/components/Position.gd")
const Velocity = preload("res://ecs/components/Velocity.gd")

# @onready var camera: IsometricCamera = $IsometricCamera
# @onready var terrain_manager: TerrainManager = $TerrainManager
# @onready var weather_manager: WeatherManager = $WeatherManager

func _ready() -> void:
	print("Main Scene Ready.")
	# Initialize ECS world
	var world = World.new()
	add_child(world)
	# Register systems
	world.add_system(MoveSystem.new())
	# Create sample entity with Position and Velocity
	var entity = world.create_entity()
	world.add_component(entity, Position.new())
	world.add_component(entity, Velocity.new())
	# Initialization logic can go here
	# Example: Connect camera movement to terrain manager for region updates
	# if camera and terrain_manager:
	#	 camera.position_changed.connect(terrain_manager.update_active_regions) # Assuming camera emits a signal

	# Example: Connect weather changes to terrain visualization (when implemented)
	# if weather_manager and terrain_manager:
	#	 weather_manager.weather_state_changed.connect(terrain_manager.on_weather_changed) # Assuming terrain manager has this method

func _on_day_passed() -> void:
	print("A new day has dawned!")
