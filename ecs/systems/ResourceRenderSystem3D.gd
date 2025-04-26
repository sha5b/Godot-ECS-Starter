extends "res://ecs/System.gd"
class_name ResourceRenderSystem3D

var resource_node: Node3D = null
var mesh: Mesh = null

func update(world, delta):
	if not resource_node:
		resource_node = Node3D.new()
		if world.get_tree() and world.get_tree().current_scene:
			world.get_tree().current_scene.add_child(resource_node)
		_draw_resources(world)
	else:
		_draw_resources(world)

func _draw_resources(world):
	# Remove previous visuals
	for child in resource_node.get_children():
		child.queue_free()
	# Get all entities with Position and ResourceComponent
	var ids = world.query(["Position", "ResourceComponent"])
	var pos_map = world.get_components("Position")
	var res_map = world.get_components("ResourceComponent")
	for id in ids:
		var mesh_instance = MeshInstance3D.new()
		if not mesh:
			mesh = BoxMesh.new()
			mesh.size = Vector3(1, 1, 1)
		mesh_instance.mesh = mesh
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0, 1, 0) # Green for food
		mesh_instance.material_override = mat
		var pos2d = pos_map[id].position
		mesh_instance.position = Vector3(pos2d.x * 2.0, 0.5, pos2d.y * 2.0)
		resource_node.add_child(mesh_instance)
		# Add a floating label
		var label = Label3D.new()
		label.text = res_map[id].resource_type + " (" + str(res_map[id].amount) + ")"
		label.position = mesh_instance.position + Vector3(0, 1.0, 0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		resource_node.add_child(label)
