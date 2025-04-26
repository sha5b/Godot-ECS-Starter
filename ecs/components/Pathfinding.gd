extends "res://ecs/Component.gd"
class_name Pathfinding

# Stores a path as a list of Vector2 grid positions
var path: Array = []

func get_type():
	return "Pathfinding"
