extends "res://ecs/System.gd"
class_name PathfindingSystem

# This system moves entities along their Pathfinding.path by updating their Velocity
# and Position components.

@export var move_speed: float = 3.0

func update(world, delta):
	var ids = world.query(["Position", "Velocity", "Pathfinding"])
	var pos_map = world.get_components("Position")
	var vel_map = world.get_components("Velocity")
	var path_map = world.get_components("Pathfinding")
	for id in ids:
		var path = path_map[id].path
		if path.size() > 0:
			var target = path[0]
			var pos = pos_map[id].position
			var to_target = target - pos
			if to_target.length() < 0.1:
				# Reached this waypoint, remove it
				path.pop_front()
				vel_map[id].velocity = Vector2.ZERO
			else:
				# Move towards target
				vel_map[id].velocity = to_target.normalized() * move_speed
		else:
			vel_map[id].velocity = Vector2.ZERO
