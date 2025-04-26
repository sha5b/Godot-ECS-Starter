extends Node

# Main scene script to initialize and hold primary nodes/managers

const World = preload("res://ecs/World.gd")
const MoveSystem = preload("res://ecs/systems/MoveSystem.gd")
const Position = preload("res://ecs/components/Position.gd")
const Velocity = preload("res://ecs/components/Velocity.gd")
const Terrain = preload("res://ecs/components/Terrain.gd")
const NPC = preload("res://ecs/components/NPC.gd")
const TerrainRenderSystem3D = preload("res://ecs/systems/TerrainRenderSystem3D.gd")

# @onready var camera: IsometricCamera = $IsometricCamera
# @onready var terrain_manager: TerrainManager = $TerrainManager
# @onready var weather_manager: WeatherManager = $WeatherManager

func _ready() -> void:
	print("Main Scene Ready.")
	# DEBUG: Force Camera3D position and orientation
	var cam = get_node_or_null("Camera3D")
	if cam:
		var width = 80
		var height = 80
		var cell_size = 2.0
		var center_x = (width * cell_size) / 2.0
		var center_z = (height * cell_size) / 2.0
		cam.transform.origin = Vector3(center_x, 200, center_z + 160)
		cam.look_at(Vector3(center_x, 0, center_z), Vector3.UP)
		cam.make_current()


	# Initialize ECS world
	var world = World.new()
	add_child(world)
	# Register systems
	world.add_system(MoveSystem.new())
	world.add_system(preload("res://ecs/systems/NPCRenderSystem3D.gd").new())
	world.add_system(TerrainRenderSystem3D.new())
	# Create sample entity with Position and Velocity
	var entity = world.create_entity()
	world.add_component(entity, Position.new())
	world.add_component(entity, Velocity.new())
	# Create terrain entity
	var terrain_entity = world.create_entity()
	world.add_component(terrain_entity, Terrain.new(160, 160))

	# Create NPC entity
	var npc_entity = world.create_entity()
	var npc_position = Position.new()
	npc_position.position = Vector2(10, 10)
	world.add_component(npc_entity, npc_position)
	world.add_component(npc_entity, NPC.new())
	# Initialization logic can go here
	# Example: Connect camera movement to terrain manager for region updates
	# if camera and terrain_manager:
	#	 camera.position_changed.connect(terrain_manager.update_active_regions) # Assuming camera emits a signal

	# Example: Connect weather changes to terrain visualization (when implemented)
	# if weather_manager and terrain_manager:
	#	 weather_manager.weather_state_changed.connect(terrain_manager.on_weather_changed) # Assuming terrain manager has this method

func _on_day_passed() -> void:
	print("A new day has dawned!")
