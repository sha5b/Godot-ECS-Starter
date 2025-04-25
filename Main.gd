extends Node

# Main scene script to initialize and hold primary nodes/managers

const World = preload("res://ecs/World.gd")
const MoveSystem = preload("res://ecs/systems/MoveSystem.gd")
const Position = preload("res://ecs/components/Position.gd")
const Velocity = preload("res://ecs/components/Velocity.gd")
const Terrain = preload("res://ecs/components/Terrain.gd")
const TerrainRenderSystem3D = preload("res://ecs/systems/TerrainRenderSystem3D.gd")

# @onready var camera: IsometricCamera = $IsometricCamera
# @onready var terrain_manager: TerrainManager = $TerrainManager
# @onready var weather_manager: WeatherManager = $WeatherManager

func _ready() -> void:
	print("Main Scene Ready.")
	# Automatically add a DirectionalLight3D for 3D visibility
	if not get_node_or_null("DirectionalLight3D"):
		var light = DirectionalLight3D.new()
		light.light_energy = 1.0
		light.rotation_degrees = Vector3(-60, 45, 0)
		add_child(light)
	# Automatically add a Camera3D for isometric view
	if not get_node_or_null("Camera3D"):
		var cam = Camera3D.new()
		# Use hardcoded terrain size and cell size for camera setup
		var terrain_width = 160
		var terrain_height = 160
		var cell_size = 2.0
		var center_x = (terrain_width * cell_size) / 2.0
		var center_z = (terrain_height * cell_size) / 2.0
		# Place camera far enough to see the whole terrain
		cam.transform.origin = Vector3(center_x, 200, center_z + 200)
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = max(terrain_width, terrain_height) * cell_size * 0.7
		add_child(cam)
		cam.look_at_from_position(Vector3(center_x, 200, center_z + 200), Vector3(center_x, 0, center_z), Vector3.UP)
		cam.make_current()
	# Initialize ECS world
	var world = World.new()
	add_child(world)
	# Register systems
	world.add_system(MoveSystem.new())
	world.add_system(TerrainRenderSystem3D.new())
	# Create sample entity with Position and Velocity
	var entity = world.create_entity()
	world.add_component(entity, Position.new())
	world.add_component(entity, Velocity.new())
	# Create terrain entity
	var terrain_entity = world.create_entity()
	world.add_component(terrain_entity, Terrain.new(160, 160))
	# Initialization logic can go here
	# Example: Connect camera movement to terrain manager for region updates
	# if camera and terrain_manager:
	#	 camera.position_changed.connect(terrain_manager.update_active_regions) # Assuming camera emits a signal

	# Example: Connect weather changes to terrain visualization (when implemented)
	# if weather_manager and terrain_manager:
	#	 weather_manager.weather_state_changed.connect(terrain_manager.on_weather_changed) # Assuming terrain manager has this method

func _on_day_passed() -> void:
	print("A new day has dawned!")
