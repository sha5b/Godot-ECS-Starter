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
	for entity_id in world.query(["Terrain"]):
		var terrain = world.get_components("Terrain")[entity_id]
		for y in range(terrain.height):
			for x in range(terrain.width):
				var mesh_instance = MeshInstance3D.new()
				var mesh = BoxMesh.new()
				mesh.size = Vector3(cell_size, 0.2, cell_size)
				mesh_instance.mesh = mesh
				var mat = StandardMaterial3D.new()
				mat.albedo_color = colors[terrain.data[y][x]]
				mesh_instance.material_override = mat
				mesh_instance.position = Vector3(x * cell_size, 0, y * cell_size)
				terrain_node.add_child(mesh_instance)
