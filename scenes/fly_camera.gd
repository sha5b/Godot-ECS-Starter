class_name FlyCamera
extends Camera3D

## Simple fly camera for testing. WASD + mouse look.

@export var move_speed: float = 20.0
@export var fast_speed: float = 60.0
@export var mouse_sensitivity: float = 0.002

var _velocity: Vector3 = Vector3.ZERO
var _mouse_captured: bool = false


func _ready() -> void:
	if is_inside_tree():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true
	SharedWorld.camera_world_pos = global_position


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if is_inside_tree():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_mouse_captured = false
		_velocity = Vector3.ZERO
		SharedWorld.camera_world_pos = global_position
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_velocity = Vector3.ZERO
		SharedWorld.camera_world_pos = global_position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		rotation.y -= event.relative.x * mouse_sensitivity
		rotation.x -= event.relative.y * mouse_sensitivity
		rotation.x = clampf(rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))

	if event is InputEventKey:
		if event.keycode == KEY_ESCAPE and event.pressed:
			if _mouse_captured:
				if is_inside_tree():
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				_mouse_captured = false
			else:
				if is_inside_tree():
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_mouse_captured = true


func _process(delta: float) -> void:
	var input_dir := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		input_dir -= transform.basis.z
	if Input.is_key_pressed(KEY_S):
		input_dir += transform.basis.z
	if Input.is_key_pressed(KEY_A):
		input_dir -= transform.basis.x
	if Input.is_key_pressed(KEY_D):
		input_dir += transform.basis.x
	if Input.is_key_pressed(KEY_SPACE):
		input_dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		input_dir += Vector3.DOWN

	var speed := fast_speed if Input.is_key_pressed(KEY_SHIFT) else move_speed

	if input_dir.length_squared() > 0.0:
		input_dir = input_dir.normalized()

	_velocity = _velocity.lerp(input_dir * speed, 10.0 * delta)
	position += _velocity * delta

	# Update shared world camera position
	SharedWorld.camera_world_pos = global_position
