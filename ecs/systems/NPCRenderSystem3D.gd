extends "res://ecs/System.gd"
class_name NPCRenderSystem3D

var npc_node: Node3D = null
var npc_mesh: Mesh = null

func update(world, delta):
	if not npc_node:
		npc_node = Node3D.new()
		if world.get_tree() and world.get_tree().current_scene:
			world.get_tree().current_scene.add_child(npc_node)
		_draw_npcs(world)
	else:
		_draw_npcs(world)

func _draw_npcs(world):
	# Remove previous NPC visuals
	for child in npc_node.get_children():
		child.queue_free()
	# Get all entities with Position and NPC
	var ids = world.query(["Position", "NPC"])
	var pos_map = world.get_components("Position")
	for id in ids:
		var mesh_instance = MeshInstance3D.new()
		if not npc_mesh:
			npc_mesh = SphereMesh.new()
			npc_mesh.radius = 0.7
		mesh_instance.mesh = npc_mesh
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(1, 0, 0) # Red NPC
		mesh_instance.material_override = mat
		var pos2d = pos_map[id].position

		# Terrain noise parameters (must match TerrainRenderSystem3D)
		var cell_size = 2.0
		var noise = FastNoiseLite.new()
		noise.seed = 0 # Use a fixed seed for consistency (or match terrain system)
		noise.frequency = 1.0 / 32.0
		noise.fractal_octaves = 4
		noise.fractal_lacunarity = 2.0
		noise.fractal_gain = 0.5

		var x = int(pos2d.x)
		var y = int(pos2d.y)
		var n = noise.get_noise_2d(x, y)
		var h = lerp(0.2, 8.0, (n + 1.0) / 2.0)
		mesh_instance.position = Vector3(pos2d.x * cell_size, h, pos2d.y * cell_size)
		npc_node.add_child(mesh_instance)
