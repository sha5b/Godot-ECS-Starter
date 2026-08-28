class_name ThirdPersonPlayer
extends CharacterBody3D

const ACTION_MOVE_FORWARD := &"player_move_forward"
const ACTION_MOVE_BACK := &"player_move_back"
const ACTION_MOVE_LEFT := &"player_move_left"
const ACTION_MOVE_RIGHT := &"player_move_right"
const ACTION_JUMP := &"player_jump"
const ACTION_SPRINT := &"player_sprint"
const ACTION_CLIMB := &"player_climb"

# Every action above is declared in Project Settings > Input Map. Rebinding
# is a settings edit, not a code edit.

@export_group("Movement")
@export var walk_speed: float = 6.0
@export var sprint_speed: float = 9.5
@export var jump_velocity: float = 7.2
@export var ground_acceleration: float = 42.0
@export var ground_deceleration: float = 34.0
@export var air_acceleration: float = 14.0
@export var gravity_scale: float = 1.0
@export var ground_snap_length: float = 0.45
@export_range(10.0, 70.0) var max_walkable_slope_degrees: float = 42.0
@export var steep_slide_speed: float = 7.5
@export var steep_slide_acceleration: float = 18.0

@export_group("Camera")
@export var mouse_sensitivity: float = 0.0022
@export var min_pitch_degrees: float = -65.0
@export var max_pitch_degrees: float = 70.0

@export_group("Traversal")
@export var climb_speed: float = 3.8
@export var climb_lateral_speed: float = 3.2
@export var climb_wall_stick_speed: float = 2.0
@export var mantle_min_height: float = 0.7
@export var mantle_max_height: float = 2.2
@export var mantle_forward_probe_distance: float = 0.85
@export var mantle_down_probe_distance: float = 2.8
@export var mantle_landing_offset: float = 0.4
@export var mantle_duration: float = 0.22

@onready var _collision_shape: CollisionShape3D = $CollisionShape3D
@onready var _visual_root: Node3D = $VisualRoot
@onready var _probe_pivot: Node3D = $ProbePivot
@onready var _wall_probe: RayCast3D = $ProbePivot/WallProbe
@onready var _ledge_probe: RayCast3D = $ProbePivot/LedgeProbe
@onready var _ground_probe: RayCast3D = $GroundProbe
@onready var _camera_yaw_pivot: Node3D = $CameraYawPivot
@onready var _camera_pitch_pivot: Node3D = $CameraYawPivot/CameraPitchPivot
@onready var _camera: Camera3D = $CameraYawPivot/CameraPitchPivot/SpringArm3D/Camera3D

var _gravity: float = 0.0
var _mouse_captured: bool = false
var _camera_yaw: float = 0.0
var _camera_pitch: float = 0.0
var _facing_yaw: float = 0.0
var _desired_facing_yaw: float = 0.0
var _wall_normal: Vector3 = Vector3.ZERO
var _is_climbing: bool = false
var _mantle_active: bool = false
var _mantle_start: Vector3 = Vector3.ZERO
var _mantle_target: Vector3 = Vector3.ZERO
var _mantle_timer: float = 0.0


func _ready() -> void:
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * gravity_scale
	floor_snap_length = ground_snap_length
	floor_max_angle = deg_to_rad(max_walkable_slope_degrees)
	_camera.current = true
	_camera_pitch = deg_to_rad(-14.0)
	_apply_camera_rotation()
	if is_inside_tree():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true
	_sync_shared_camera_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if is_inside_tree():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_mouse_captured = false
		velocity = Vector3.ZERO
		_sync_shared_camera_state()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		velocity = Vector3.ZERO
		_sync_shared_camera_state()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_camera_yaw -= event.relative.x * mouse_sensitivity
		_camera_pitch -= event.relative.y * mouse_sensitivity
		_camera_pitch = clampf(
			_camera_pitch,
			deg_to_rad(min_pitch_degrees),
			deg_to_rad(max_pitch_degrees)
		)
		_apply_camera_rotation()

	if event.is_action_pressed(&"world_select") and not _mouse_captured:
		_capture_mouse()

	if event.is_action_pressed(&"ui_cancel"):
		if _mouse_captured:
			_release_mouse()
		else:
			_capture_mouse()


func _physics_process(delta: float) -> void:
	_update_probe_transforms()
	_update_wall_state()

	if _mantle_active:
		_update_mantle(delta)
		_sync_shared_camera_state()
		return

	var input_vector := _get_move_input()
	if _try_start_mantle():
		_sync_shared_camera_state()
		return

	if _should_enter_climb():
		_is_climbing = true

	if _is_climbing:
		_process_climb(input_vector)
	else:
		_process_ground_and_air(input_vector, delta)

	move_and_slide()
	_update_facing(input_vector, delta)
	_sync_shared_camera_state()


func _process_ground_and_air(input_vector: Vector2, delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif velocity.y < 0.0:
		velocity.y = -0.1

	var move_direction := _get_camera_relative_direction(input_vector)
	var speed := sprint_speed if Input.is_action_pressed(ACTION_SPRINT) else walk_speed
	var target_velocity := move_direction * speed
	var accel := ground_acceleration if move_direction.length_squared() > 0.0 else ground_deceleration
	if not is_on_floor():
		accel = air_acceleration

	velocity.x = move_toward(velocity.x, target_velocity.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, accel * delta)

	if Input.is_action_just_pressed(ACTION_JUMP) and is_on_floor():
		velocity.y = jump_velocity

	_apply_steep_slope_slide(delta)


func _process_climb(input_vector: Vector2) -> void:
	if not Input.is_action_pressed(ACTION_CLIMB) or not _can_climb_surface():
		_is_climbing = false
		return

	if Input.is_action_just_pressed(ACTION_JUMP) and _try_start_mantle():
		return

	var wall_forward := -_wall_normal.slide(Vector3.UP)
	if wall_forward.length_squared() <= 0.0001:
		wall_forward = _forward_vector()
	else:
		wall_forward = wall_forward.normalized()
	var wall_right := Vector3.UP.cross(wall_forward).normalized()
	var climb_velocity := wall_right * input_vector.x * climb_lateral_speed
	climb_velocity += Vector3.UP * input_vector.y * climb_speed
	climb_velocity += -_wall_normal * climb_wall_stick_speed
	velocity = climb_velocity
	_desired_facing_yaw = _yaw_from_direction(wall_forward)


func _update_facing(input_vector: Vector2, delta: float) -> void:
	if _is_climbing and _wall_normal.length_squared() > 0.0:
		_desired_facing_yaw = _yaw_from_direction(-_wall_normal)
	elif input_vector.length_squared() > 0.0:
		var move_direction := _get_camera_relative_direction(input_vector)
		if move_direction.length_squared() > 0.0:
			_desired_facing_yaw = _yaw_from_direction(move_direction)

	_facing_yaw = lerp_angle(_facing_yaw, _desired_facing_yaw, minf(1.0, delta * 12.0))
	_visual_root.rotation.y = _facing_yaw
	_probe_pivot.rotation.y = _facing_yaw


func _apply_steep_slope_slide(delta: float) -> void:
	if not _ground_probe.is_colliding():
		return
	var ground_normal := _ground_probe.get_collision_normal().normalized()
	var slope_angle := rad_to_deg(ground_normal.angle_to(Vector3.UP))
	if slope_angle <= max_walkable_slope_degrees + 0.5:
		return
	var slide_direction := Vector3.DOWN.slide(ground_normal)
	if slide_direction.length_squared() <= 0.0001:
		return
	slide_direction = slide_direction.normalized()
	var slide_target := slide_direction * steep_slide_speed
	velocity.x = move_toward(velocity.x, slide_target.x, steep_slide_acceleration * delta)
	velocity.z = move_toward(velocity.z, slide_target.z, steep_slide_acceleration * delta)


func _should_enter_climb() -> bool:
	if _mantle_active:
		return false
	if not Input.is_action_pressed(ACTION_CLIMB):
		return false
	return _can_climb_surface()


func _can_climb_surface() -> bool:
	if not _wall_probe.is_colliding():
		return false
	if _wall_normal.length_squared() <= 0.0:
		return false
	return absf(_wall_normal.y) < 0.35


func _try_start_mantle() -> bool:
	if not Input.is_action_just_pressed(ACTION_JUMP):
		return false
	var mantle_data := _find_mantle_target()
	if mantle_data.is_empty():
		return false
	_begin_mantle(mantle_data)
	return true


func _find_mantle_target() -> Dictionary:
	var mantle_data: Dictionary = {}
	if not _wall_probe.is_colliding() or _ledge_probe.is_colliding():
		return mantle_data
	var wall_normal := _wall_probe.get_collision_normal().normalized()
	if absf(wall_normal.y) >= 0.35:
		return mantle_data
	var wall_point := _wall_probe.get_collision_point()
	var space_state := get_world_3d().direct_space_state
	var down_from := wall_point + Vector3.UP * mantle_max_height - wall_normal * mantle_forward_probe_distance
	var down_to := down_from + Vector3.DOWN * mantle_down_probe_distance
	var down_query := PhysicsRayQueryParameters3D.create(down_from, down_to)
	down_query.exclude = [self]
	var top_hit := space_state.intersect_ray(down_query)
	if top_hit.is_empty():
		return mantle_data
	var top_normal: Vector3 = top_hit.get("normal", Vector3.UP)
	if rad_to_deg(top_normal.angle_to(Vector3.UP)) > max_walkable_slope_degrees:
		return mantle_data
	var top_point: Vector3 = top_hit.get("position", Vector3.ZERO)
	var height_delta := top_point.y - global_position.y
	if height_delta < mantle_min_height or height_delta > mantle_max_height:
		return mantle_data
	var target_position := top_point - wall_normal * mantle_landing_offset
	target_position.y += 0.05
	if not _is_mantle_destination_clear(space_state, target_position):
		return mantle_data
	mantle_data[&"target_position"] = target_position
	mantle_data[&"wall_normal"] = wall_normal
	return mantle_data


func _is_mantle_destination_clear(space_state: PhysicsDirectSpaceState3D, target_position: Vector3) -> bool:
	var head_from := target_position + Vector3.UP * 0.1
	var head_to := target_position + Vector3.UP * 1.7
	var head_query := PhysicsRayQueryParameters3D.create(head_from, head_to)
	head_query.exclude = [self]
	return space_state.intersect_ray(head_query).is_empty()


func _begin_mantle(mantle_data: Dictionary) -> void:
	_mantle_active = true
	_mantle_timer = 0.0
	_mantle_start = global_position
	_mantle_target = mantle_data.get(&"target_position", global_position)
	_is_climbing = false
	velocity = Vector3.ZERO
	_collision_shape.disabled = true
	var wall_normal: Vector3 = mantle_data.get(&"wall_normal", Vector3.BACK)
	_desired_facing_yaw = _yaw_from_direction(-wall_normal)


func _update_mantle(delta: float) -> void:
	_mantle_timer += delta
	var t := clampf(_mantle_timer / maxf(mantle_duration, 0.01), 0.0, 1.0)
	var smooth_t := t * t * (3.0 - 2.0 * t)
	global_position = _mantle_start.lerp(_mantle_target, smooth_t)
	if t >= 1.0:
		_finish_mantle()


func _finish_mantle() -> void:
	_mantle_active = false
	_collision_shape.disabled = false
	global_position = _mantle_target
	velocity = Vector3.ZERO
	apply_floor_snap()


func _update_probe_transforms() -> void:
	_probe_pivot.rotation.y = _facing_yaw
	_wall_probe.force_raycast_update()
	_ledge_probe.force_raycast_update()
	_ground_probe.force_raycast_update()


func _update_wall_state() -> void:
	_wall_normal = Vector3.ZERO
	if _wall_probe.is_colliding():
		_wall_normal = _wall_probe.get_collision_normal().normalized()


func _get_move_input() -> Vector2:
	var input_vector := Vector2.ZERO
	input_vector.x = Input.get_action_strength(ACTION_MOVE_RIGHT) - Input.get_action_strength(ACTION_MOVE_LEFT)
	input_vector.y = Input.get_action_strength(ACTION_MOVE_FORWARD) - Input.get_action_strength(ACTION_MOVE_BACK)
	if input_vector.length_squared() > 1.0:
		input_vector = input_vector.normalized()
	return input_vector


func _get_camera_relative_direction(input_vector: Vector2) -> Vector3:
	if input_vector.length_squared() <= 0.0:
		return Vector3.ZERO
	var forward := -_camera_yaw_pivot.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := _camera_yaw_pivot.global_basis.x
	right.y = 0.0
	right = right.normalized()
	var move_direction := right * input_vector.x + forward * input_vector.y
	if move_direction.length_squared() <= 0.0:
		return Vector3.ZERO
	return move_direction.normalized()


func _forward_vector() -> Vector3:
	return Vector3(sin(_facing_yaw), 0.0, -cos(_facing_yaw)).normalized()


func _yaw_from_direction(direction: Vector3) -> float:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0:
		return _desired_facing_yaw
	flat_direction = flat_direction.normalized()
	return atan2(-flat_direction.x, -flat_direction.z)


func _apply_camera_rotation() -> void:
	_camera_yaw_pivot.rotation.y = _camera_yaw
	_camera_pitch_pivot.rotation.x = _camera_pitch


func _capture_mouse() -> void:
	if is_inside_tree():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true


func _release_mouse() -> void:
	if is_inside_tree():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false


func _sync_shared_camera_state() -> void:
	if is_instance_valid(_camera):
		SharedWorld.publish_camera_focus(_camera.global_position)
