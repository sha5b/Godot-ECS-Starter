class_name FlyCamera
extends Camera3D

## Simple fly camera for testing. Mouse look plus the shared world-camera
## actions from Project Settings > Input Map.

const ACTION_FORWARD := &"world_pan_forward"
const ACTION_BACK := &"world_pan_back"
const ACTION_LEFT := &"world_pan_left"
const ACTION_RIGHT := &"world_pan_right"
const ACTION_UP := &"world_fly_up"
const ACTION_DOWN := &"world_fly_down"
const ACTION_FAST := &"world_pan_fast"

@export var move_speed: float = 20.0
@export var fast_speed: float = 60.0
@export var mouse_sensitivity: float = 0.002

var _velocity: Vector3 = Vector3.ZERO
var _mouse_captured: bool = false


func _ready() -> void:
	if is_inside_tree():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true
	SharedWorld.publish_camera_focus(global_position)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if is_inside_tree():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_mouse_captured = false
		_velocity = Vector3.ZERO
		SharedWorld.publish_camera_focus(global_position)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_velocity = Vector3.ZERO
		SharedWorld.publish_camera_focus(global_position)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		rotation.y -= event.relative.x * mouse_sensitivity
		rotation.x -= event.relative.y * mouse_sensitivity
		rotation.x = clampf(rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))

	if event.is_action_pressed(&"ui_cancel"):
		_mouse_captured = not _mouse_captured
		if is_inside_tree():
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouse_captured \
				else Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	var input_dir := Vector3.ZERO

	input_dir += transform.basis.z * Input.get_axis(
		ACTION_FORWARD, ACTION_BACK)
	input_dir += transform.basis.x * Input.get_axis(
		ACTION_LEFT, ACTION_RIGHT)
	input_dir += Vector3.UP * Input.get_axis(ACTION_DOWN, ACTION_UP)

	var speed := fast_speed if Input.is_action_pressed(ACTION_FAST) else move_speed

	if input_dir.length_squared() > 0.0:
		input_dir = input_dir.normalized()

	_velocity = _velocity.lerp(input_dir * speed, 10.0 * delta)
	position += _velocity * delta

	# Update shared world camera position
	SharedWorld.publish_camera_focus(global_position)
