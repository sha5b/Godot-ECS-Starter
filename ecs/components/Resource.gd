extends "res://ecs/Component.gd"
class_name ResourceComponent

# Represents a resource type (e.g., food, water) and its amount
var resource_type: String = "food"
var amount: int = 1

func get_type():
	return "ResourceComponent"
