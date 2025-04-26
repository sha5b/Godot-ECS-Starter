extends "res://ecs/System.gd"
class_name NPCBehaviorSystem

func update(world, delta):
    var npc_ids = world.query(["Position", "NPC", "Pathfinding"])
    var food_ids = world.query(["Position", "ResourceComponent"])
    var pos_map = world.get_components("Position")
    var path_map = world.get_components("Pathfinding")

    for npc_id in npc_ids:
        var path = path_map[npc_id].path
        if path.size() == 0 and food_ids.size() > 0:
            var npc_pos = pos_map[npc_id].position
            # Find nearest food
            var nearest_food_id = food_ids[0]
            var min_dist = npc_pos.distance_to(pos_map[nearest_food_id].position)
            for food_id in food_ids:
                var dist = npc_pos.distance_to(pos_map[food_id].position)
                if dist < min_dist:
                    min_dist = dist
                    nearest_food_id = food_id
            # Set path to nearest food
            var food_pos = pos_map[nearest_food_id].position
            path_map[npc_id].path = [food_pos]
