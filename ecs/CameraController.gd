extends Node

@export var camera_path: NodePath
var camera: Camera3D = null

@export var zoom_speed: float = 10.0
@export var pan_speed: float = 0.1
@export var min_height: float = 10.0
@export var max_height: float = 200.0

var dragging := false
var last_mouse_pos := Vector2.ZERO

func _ready():
	if camera_path != NodePath(""):
		camera = get_node(camera_path)
		set_process_input(true)

func _input(event):
	if camera == null:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera.transform.origin.y = max(min_height, camera.transform.origin.y - zoom_speed)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera.transform.origin.y = min(max_height, camera.transform.origin.y + zoom_speed)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				dragging = true
				last_mouse_pos = event.position
			else:
				dragging = false
	elif event is InputEventMouseMotion and dragging:
		var delta = event.position - last_mouse_pos
		last_mouse_pos = event.position
		# Pan camera along XY plane
		var right = camera.global_transform.basis.x.normalized()
		var up = camera.global_transform.basis.y.normalized()
		# Move opposite to mouse direction for natural feel
		camera.transform.origin -= right * delta.x * pan_speed
		camera.transform.origin += up * delta.y * pan_speed
