extends "res://ecs/System.gd"
class_name MoveSystem

func update(world, delta: float) -> void:
    var ids = world.query(["Position", "Velocity"])
    var pos_map = world.get_components("Position")
    var vel_map = world.get_components("Velocity")
    for id in ids:
        pos_map[id].position += vel_map[id].velocity * delta
