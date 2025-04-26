extends "res://ecs/Component.gd"
class_name Terrain

var width: int
var height: int
var data: Array = []

func get_type():
	return "Terrain"

func _init(_width: int = 160, _height: int = 160):
	width = _width
	height = _height
	data = []
	for y in range(height):
		var row = []
		for x in range(width):
			row.append(0) # 0 = grass, 1 = water, etc.
		data.append(row)
