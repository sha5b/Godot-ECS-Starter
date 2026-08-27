class_name BodyLabPortal
extends Control

## Main-scene hook into the Body Lab test environment: press B to swap to
## scenes/body_lab.tscn (ESC there returns). The world keeps running its
## own systems; this portal only listens for one key.

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	print("[BodyLab] press B to open the procedural critter Body Lab")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).physical_keycode == KEY_B:
			get_tree().change_scene_to_file("res://scenes/body_lab.tscn")
