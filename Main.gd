extends Node

# Main scene script to initialize and hold primary nodes/managers

const World = preload("res://ecs/World.gd")
const MoveSystem = preload("res://ecs/systems/MoveSystem.gd")
const Position = preload("res://ecs/components/Position.gd")
const Velocity = preload("res://ecs/components/Velocity.gd")
const Terrain = preload("res://ecs/components/Terrain.gd")
const NPC = preload("res://ecs/components/NPC.gd")
const ResourceRenderSystem3D = preload("res://ecs/systems/ResourceRenderSystem3D.gd")
const PathfindingSystem = preload("res://ecs/systems/PathfindingSystem.gd")
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
		# Move camera closer and lower
		cam.transform.origin = Vector3(center_x, 80, center_z + 60)
		cam.look_at(Vector3(center_x, 0, center_z), Vector3.UP)
		cam.make_current()


	# Initialize ECS world
	var world = World.new()
	add_child(world)
	# Register systems
	world.add_system(MoveSystem.new())
	world.add_system(PathfindingSystem.new())
	world.add_system(preload("res://ecs/systems/NPCRenderSystem3D.gd").new())
	world.add_system(ResourceRenderSystem3D.new())
	world.add_system(TerrainRenderSystem3D.new())
	# Create sample entity with Position and Velocity
	var entity = world.create_entity()
	world.add_component(entity, Position.new())
	world.add_component(entity, Velocity.new())
	# Create terrain entity
	var terrain_entity = world.create_entity()
	world.add_component(terrain_entity, Terrain.new(160, 160))

	# Create NPC entity
	# Terrain noise setup (match NPCRenderSystem3D)
	var cell_size = 2.0
	var noise = FastNoiseLite.new()
	noise.seed = 0
	noise.frequency = 1.0 / 32.0
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	# NPC position
	var npc_x = 10
	var npc_y = 10
	var n_npc = noise.get_noise_2d(npc_x, npc_y)
	var h_npc = lerp(0.2, 8.0, (n_npc + 1.0) / 2.0)

	var npc_entity = world.create_entity()
	var npc_position = Position.new()
	npc_position.position = Vector2(npc_x, npc_y)
	world.add_component(npc_entity, npc_position)
	world.add_component(npc_entity, NPC.new())
	# Add Velocity and Pathfinding to NPC
	var npc_velocity = Velocity.new()
	world.add_component(npc_entity, npc_velocity)
	var npc_pathfinding = Pathfinding.new()
	npc_pathfinding.path = [Vector2(20, 20)] # Path to food
	world.add_component(npc_entity, npc_pathfinding)
	print("[MAIN DEBUG] Created NPC entity with id:", npc_entity.id)
	print("[MAIN DEBUG] World components after NPC creation:", world.components)

	# Food position
	var food_x = 20
	var food_y = 20
	var n_food = noise.get_noise_2d(food_x, food_y)
	var h_food = lerp(0.2, 8.0, (n_food + 1.0) / 2.0)

	# Spawn a food entity at (20, 20)
	var food_entity = world.create_entity()
	var food_pos = Position.new()
	food_pos.position = Vector2(food_x, food_y)
	var food = ResourceComponent.new()
	food.resource_type = "food"
	food.amount = 5
	world.add_component(food_entity, food_pos)
	world.add_component(food_entity, food)

	# Initialization logic can go here
	# Example: Connect camera movement to terrain manager for region updates
	# if camera and terrain_manager:
	#	 camera.position_changed.connect(terrain_manager.update_active_regions) # Assuming camera emits a signal

	# Example: Connect weather changes to terrain visualization (when implemented)
	# if weather_manager and terrain_manager:
	#	 weather_manager.weather_state_changed.connect(terrain_manager.on_weather_changed) # Assuming terrain manager has this method

func _on_day_passed() -> void:
	print("A new day has dawned!")
