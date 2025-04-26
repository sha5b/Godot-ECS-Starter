extends "res://ecs/System.gd"
class_name ResourceCollectionSystem

const Position = preload("res://ecs/components/Position.gd")
const ResourceComponent = preload("res://ecs/components/Resource.gd")

func update(world, delta):
	var npc_ids = world.query(["Position", "NPC"])
	var food_ids = world.query(["Position", "ResourceComponent"])
	var pos_map = world.get_components("Position")

	for npc_id in npc_ids:
		var npc_pos = pos_map[npc_id].position
		for food_id in food_ids:
			var food_pos = pos_map[food_id].position
			if npc_pos.distance_to(food_pos) < 0.5:
				# Remove food entity
				world.remove_entity(food_id)
				# Spawn new food at random location
				var new_food_entity = world.create_entity()
				var new_food_pos = Position.new()
				var food_x = randi() % 40
				var food_y = randi() % 40
				new_food_pos.position = Vector2(food_x, food_y)
				var food = ResourceComponent.new()
				food.resource_type = "food"
				food.amount = 5
				world.add_component(new_food_entity, new_food_pos)
				world.add_component(new_food_entity, food)
