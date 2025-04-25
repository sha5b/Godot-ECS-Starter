extends "res://ecs/System.gd"
class_name TerrainRenderSystem

var terrain_node: Node2D = null
var cell_size: int = 64
var colors := [Color(0,1,0), Color(0,0,1)] # 0=bright green, 1=blue

func update(world, delta):
	if not terrain_node:
		terrain_node = Node2D.new()
		if world.get_tree() and world.get_tree().current_scene:
			world.get_tree().current_scene.add_child(terrain_node)
		_draw_terrain(world)

func _draw_terrain(world):
	print("Drawing terrain!")
	for child in terrain_node.get_children():
		child.queue_free()
	for entity_id in world.query(["Terrain"]):
		var terrain = world.get_components("Terrain")[entity_id]
		for y in range(terrain.height):
			for x in range(terrain.width):
				var rect = ColorRect.new()
				rect.color = colors[terrain.data[y][x]]
				rect.size = Vector2(cell_size, cell_size)
				rect.position = Vector2(x * cell_size, y * cell_size)
				terrain_node.add_child(rect)
