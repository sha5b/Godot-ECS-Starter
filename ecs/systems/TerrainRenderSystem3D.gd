extends "res://ecs/System.gd"
class_name TerrainRenderSystem3D

var terrain_node: Node3D = null
var cell_size: float = 2.0
var colors := [Color(0,1,0), Color(0,0,1)] # 0=bright green, 1=blue

func update(world, delta):
	if not terrain_node:
		terrain_node = Node3D.new()
		if world.get_tree() and world.get_tree().current_scene:
			world.get_tree().current_scene.add_child(terrain_node)
		generate_terrain()

func generate_terrain():
	print("Generating 3D terrain!")
	for child in terrain_node.get_children():
		child.queue_free()

	# Terrain parameters
	var width = 80
	var height = 80
	var center_x = (width * cell_size) / 2.0
	var center_z = (height * cell_size) / 2.0

	# Noise setup (Godot 4.x: FastNoiseLite)
	var noise = FastNoiseLite.new()
	noise.seed = randi()
	noise.frequency = 1.0 / 32.0
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	for y in range(height):
		for x in range(width):
			var mesh_instance = MeshInstance3D.new()
			var mesh = BoxMesh.new()
			mesh.size = Vector3(cell_size, 0.2, cell_size)
			# Height from noise
			var n = noise.get_noise_2d(x, y)
			var h = lerp(0.2, 8.0, (n + 1.0) / 2.0)
			mesh_instance.mesh = mesh
			mesh_instance.scale.y = h
			# Color by height
			var mat = StandardMaterial3D.new()
			if h < 2.5:
				mat.albedo_color = Color(0.1, 0.7, 0.2) # green
			elif h < 5.5:
				mat.albedo_color = Color(0.6, 0.4, 0.1) # brown
			else:
				mat.albedo_color = Color(1, 1, 1) # white (snow)
			mesh_instance.material_override = mat
			mesh_instance.position = Vector3(x * cell_size, 0, y * cell_size)
			terrain_node.add_child(mesh_instance)
