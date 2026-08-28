extends Camera3D

## RTS-style god camera: angled top-down view over the world.
##
## Controls (every axis has an invert toggle in the Inspector):
## - WASD / arrows: pan
## - Mouse wheel: UP moves the camera in, DOWN pulls it out
## - Hold RIGHT mouse + move: orbit (left/right) and tilt (down = top-down)
## - Hold LEFT or MIDDLE mouse + move: drag-pan (ground follows cursor)
## - Q / E: orbit without the mouse
## - Shift: double pan speed
##
## Motion is smoothed (the camera eases toward its targets), and the camera
## shortens its boom when terrain would block the view. The focus point
## feeds SharedWorld.camera_world_pos so chunk streaming, ECS tiers, and
## AI threats all follow the camera.


## Input actions, defined in Project Settings > Input Map. Rebind there —
## no keycode is hardcoded in this rig.
const ACTION_PAN_FORWARD := &"world_pan_forward"
const ACTION_PAN_BACK := &"world_pan_back"
const ACTION_PAN_LEFT := &"world_pan_left"
const ACTION_PAN_RIGHT := &"world_pan_right"
const ACTION_PAN_FAST := &"world_pan_fast"
const ACTION_ORBIT_LEFT := &"world_orbit_left"
const ACTION_ORBIT_RIGHT := &"world_orbit_right"
const ACTION_ZOOM_IN := &"world_zoom_in"
const ACTION_ZOOM_OUT := &"world_zoom_out"
const ACTION_ORBIT_DRAG := &"world_orbit_drag"
const ACTION_DRAG_PAN := &"world_drag_pan"


@export var focus := Vector3(0, 0, 8)
@export var yaw := 0.0
@export var pitch := deg_to_rad(52.0)
## Opening boom length. Close enough to read individual creatures on the
## ground rather than surveying the whole island.
@export var distance := 12.0

## Low enough to get right down among the critters.
@export var min_distance := 6.0
@export var max_distance := 220.0

@export_group("Invert Axes")
## Every axis below is individually invertible. The defaults flip all four
## relative to the original mapping — notably the wheel, which used to
## push the camera AWAY on scroll-up.
## Wheel up zooms in when false, out when true.
@export var invert_zoom := false
## W drives the view forward when false.
@export var invert_pan_vertical := false
## D drives the view right when false.
@export var invert_pan_horizontal := false
## Right-drag / Q-E orbit follows the mouse when false.
@export var invert_rotate := false
## Right-drag down tilts toward top-down when false.
@export var invert_tilt := false
## Middle/left-drag grabs the ground and drags it when false.
@export var invert_drag_pan := false

## Vertical half of the drag-pan, invertible on its own — pushing the mouse
## away from you moves the view away when false.
@export var invert_drag_vertical := true
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
		# Positive accumulator lengthens the boom, so wheel up has to push it
		# negative to move the camera in.
		var zoom_dir := 1.0 if invert_zoom else -1.0
		if event.is_action(ACTION_ZOOM_IN):
			_zoom_accumulator += zoom_dir
		elif event.is_action(ACTION_ZOOM_OUT):
			_zoom_accumulator -= zoom_dir
	elif event is InputEventMouseMotion:
		if Input.is_action_pressed(ACTION_ORBIT_DRAG):
			# Hold-and-drag rotate — the standard RTS camera grip.
			var yaw_dir := 1.0 if invert_rotate else -1.0
			var tilt_dir := -1.0 if invert_tilt else 1.0
			_target_yaw += event.relative.x * rotate_speed * 0.01 * yaw_dir
			_target_pitch = clampf(
				_target_pitch + event.relative.y * rotate_speed * 0.01 * tilt_dir,
				min_pitch, max_pitch)
		elif Input.is_action_pressed(ACTION_DRAG_PAN):
			# Grab-the-ground drag: the world follows the cursor. Bound to
			# the LEFT button as well as the middle one — "click and drag"
			# means the primary button to most people, and it was previously
			# unbound, so left-dragging did nothing at all.
			var drag_dir := 1.0 if invert_drag_pan else -1.0
			var drag_v := -1.0 if invert_drag_vertical else 1.0
			var drag := Vector2(event.relative.x, event.relative.y * drag_v) \
				* 0.014 * drag_dir
			_pan_target(drag)


func _process(delta: float) -> void:
	# The camera runs on UNSCALED time. Engine.time_scale slows the world on
	# purpose, but a camera that pans and zooms at half speed just feels
	# broken, so undo the scaling for the rig only.
	delta /= maxf(Engine.time_scale, 0.001)

	# Zoom accumulates per event; apply smoothly each frame.
	if absf(_zoom_accumulator) > 0.001:
		_target_distance = clampf(
			_target_distance * pow(zoom_step, _zoom_accumulator),
			min_distance, max_distance)
		_zoom_accumulator = 0.0

	var pan := Vector2.ZERO
	var pan_x := -1.0 if invert_pan_horizontal else 1.0
	var pan_y := -1.0 if invert_pan_vertical else 1.0
	# get_axis reads the Project Settings actions, so rebinding the rig is a
	# Project Settings edit rather than a code change.
	pan.x -= Input.get_axis(ACTION_PAN_LEFT, ACTION_PAN_RIGHT) * pan_x
	pan.y -= Input.get_axis(ACTION_PAN_BACK, ACTION_PAN_FORWARD) * pan_y
	# Q/E orbit matches the right-drag direction.
	var key_yaw := 1.0 if invert_rotate else -1.0
	var orbit := Input.get_axis(ACTION_ORBIT_LEFT, ACTION_ORBIT_RIGHT)
	if orbit != 0.0:
		_target_yaw += orbit * rotate_speed * delta * key_yaw
	if pan != Vector2.ZERO:
		if Input.is_action_pressed(ACTION_PAN_FAST):
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
