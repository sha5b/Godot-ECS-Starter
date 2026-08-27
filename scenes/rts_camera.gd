extends Camera3D

## RTS-style god camera: angled top-down view over the world.
##
## Standard strategy controls:
## - WASD / arrows: pan (camera-relative)
## - Mouse wheel: smooth zoom toward the focus
## - Hold RIGHT mouse + move: rotate (yaw) and tilt (pitch)
## - Hold MIDDLE mouse + move: fast drag-pan
## - Q / E: rotate without the mouse
## - Shift: double pan speed
##
## Motion is smoothed (the camera eases toward its targets), and the camera
## shortens its boom when terrain would block the view. The focus point
## feeds SharedWorld.camera_world_pos so chunk streaming, ECS tiers, and
## AI threats all follow the camera.


@export var focus := Vector3(0, 0, 8)
@export var yaw := 0.0
@export var pitch := deg_to_rad(52.0)
@export var distance := 42.0

@export var min_distance := 16.0
@export var max_distance := 220.0
@export var pan_speed := 26.0
@export var rotate_speed := 0.22
@export var zoom_step := 1.18
@export var focus_bounds := 900.0
@export var min_pitch := deg_to_rad(22.0)
@export var max_pitch := deg_to_rad(78.0)

## How quickly the camera eases toward its target pose (higher = snappier).
@export var smoothing := 10.0

var _target_focus: Vector3
var _target_yaw := 0.0
var _target_pitch := 0.0
var _target_distance := 42.0
var _current_distance := 42.0
var _zoom_accumulator := 0.0


func _ready() -> void:
	make_current()
	_target_focus = focus
	_target_yaw = yaw
	_target_pitch = pitch
	_target_distance = clampf(distance, min_distance, max_distance)
	_current_distance = _target_distance
	_apply(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_accumulator += 1.0
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_accumulator -= 1.0
	elif event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_RIGHT:
			# Hold-and-drag rotate — the standard RTS camera grip.
			_target_yaw += event.relative.x * rotate_speed * 0.01
			_target_pitch = clampf(
				_target_pitch - event.relative.y * rotate_speed * 0.01,
				min_pitch, max_pitch)
		elif event.button_mask & MOUSE_BUTTON_MIDDLE:
			var drag := Vector2(event.relative.x, event.relative.y) * -0.014
			_pan_target(drag)


func _process(delta: float) -> void:
	# Zoom accumulates per event; apply smoothly each frame.
	if absf(_zoom_accumulator) > 0.001:
		_target_distance = clampf(
			_target_distance * pow(zoom_step, _zoom_accumulator),
			min_distance, max_distance)
		_zoom_accumulator = 0.0

	var pan := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		pan.x += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		pan.x -= 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		pan.y += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		pan.y -= 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		_target_yaw += rotate_speed * delta
	if Input.is_physical_key_pressed(KEY_E):
		_target_yaw -= rotate_speed * delta
	if pan != Vector2.ZERO:
		if Input.is_physical_key_pressed(KEY_SHIFT):
			pan *= 2.0
		_pan_target(pan * delta)

	# Ease toward the target pose.
	var k := 1.0 - exp(-smoothing * delta)
	focus = focus.lerp(_target_focus, k)
	yaw = lerp_angle(yaw, _target_yaw, k)
	pitch = lerpf(pitch, _target_pitch, k)

	# Boom: spring toward the wanted distance, but never through terrain.
	# Shortening snaps fast (the camera must not clip a hill mid-orbit);
	# releasing eases back with the same spring as the rest of the rig.
	# A hard on/off clip here is what made right-drag rotate spasm over
	# ridges — the ray grazes terrain every other frame and the length
	# flickers between full and clipped.
	var wanted := clampf(_target_distance, min_distance, max_distance)
	var limit := _terrain_boom_limit()
	if limit < _current_distance - 0.25:
		var clip_k := 1.0 - exp(-30.0 * delta)
		_current_distance = lerpf(_current_distance, minf(wanted, limit), clip_k)
	else:
		_current_distance = lerpf(_current_distance, wanted, k)
	_apply(false)

	SharedWorld.publish_camera_focus(focus)
	SharedWorld.camera_chunk_pos = SharedWorld.world_to_chunk(focus)


## Pan the target focus in camera-relative ground space
## (x = screen right, y = "up" on the map).
func _pan_target(offset: Vector2) -> void:
	var forward := Vector3(-sin(_target_yaw), 0.0, -cos(_target_yaw))
	var right := Vector3(-forward.z, 0.0, forward.x)
	var speed_scale := pan_speed * (0.3 + 0.7 * _target_distance / max_distance)
	_target_focus += (right * offset.x + forward * offset.y) * speed_scale
	_target_focus.x = clampf(_target_focus.x, -focus_bounds, focus_bounds)
	_target_focus.z = clampf(_target_focus.z, -focus_bounds, focus_bounds)
	# Keep the focus glued to the ground height so zooming feels anchored.
	_target_focus.y = _ground_height(_target_focus.x, _target_focus.z)


## Longest boom length with a clear line from just above the focus to the
## camera (INF when nothing blocks). Back faces are ignored so grazing
## shots through cliff walls don't flicker.
func _terrain_boom_limit() -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return INF
	var cos_p := cos(pitch)
	var sin_p := sin(pitch)
	var offset := Vector3(sin(yaw) * cos_p, sin_p, cos(yaw) * cos_p)
	var from := focus + Vector3.UP * 1.5
	var query := PhysicsRayQueryParameters3D.create(from, from + offset * _current_distance)
	query.hit_back_faces = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return INF
	return maxf((hit["position"] as Vector3).distance_to(from) - 0.8, 4.0)


func _apply(snap: bool) -> void:
	var cos_p := cos(pitch)
	var sin_p := sin(pitch)
	var offset := Vector3(sin(yaw) * cos_p, sin_p, cos(yaw) * cos_p)
	if snap:
		global_position = focus + offset * _target_distance
	else:
		global_position = focus + offset * _current_distance
	look_at(focus, Vector3.UP)


## Ground height under a point (0 where no terrain is loaded).
func _ground_height(x: float, z: float) -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return 0.0
	var from := Vector3(x, 500.0, z)
	var query := PhysicsRayQueryParameters3D.create(from, Vector3(x, -50.0, z))
	query.hit_back_faces = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	return (hit["position"] as Vector3).y
