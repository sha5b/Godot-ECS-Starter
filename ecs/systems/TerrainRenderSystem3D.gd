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
	_draw_terrain(world)

func _draw_terrain(world):
	print("Drawing 3D terrain!")
	for child in terrain_node.get_children():
		child.queue_free()
	# DEBUG: Place a single green plane at the terrain location
	var mesh_instance = MeshInstance3D.new()
	var mesh = PlaneMesh.new()
	mesh.size = Vector2(320, 320) # 160x2 = 320
	mesh_instance.mesh = mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0, 1, 0) # bright green
	mesh_instance.material_override = mat
	mesh_instance.position = Vector3(160, 0, 160) # Centered if terrain is 320x320
	terrain_node.add_child(mesh_instance)
	print("DEBUG: terrain_node children count:", terrain_node.get_child_count())
