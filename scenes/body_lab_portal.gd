class_name BodyLabPortal
extends Control

## Input action for the portal, bound in Project Settings > Input Map.
const ACTION_OPEN := &"debug_body_lab_toggle"

## Main-scene hook into the Body Lab test environment: press B to swap to
## scenes/body_lab.tscn (ESC there returns). The world keeps running its
## own systems; this portal only listens for one key.

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	print("[BodyLab] press B to open the procedural critter Body Lab")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_OPEN):
		get_tree().change_scene_to_file("res://scenes/body_lab.tscn")
