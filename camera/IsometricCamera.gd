extends Camera2D

class_name IsometricCamera

# --- Configuration ---
@export var pan_speed: float = 500.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.5
@export var max_zoom: float = 6.0
@export var smoothing_factor: float = 0.1 # Lower value = smoother/slower follow

# --- State ---
var target_position: Vector2 = Vector2.ZERO
var target_zoom: Vector2 = Vector2.ONE

# --- Initialization ---
func _ready() -> void:
	# Initialize target position and zoom to current state
	target_position = global_position
	target_zoom = zoom
	# Ensure the camera processes input
	set_process_input(true)
	set_physics_process(true) # Use physics process for smooth movement


# --- Input Handling ---
func _input(event: InputEvent) -> void:
	# --- Zooming ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.is_pressed():
			target_zoom = zoom * (1.0 - zoom_speed)
			target_zoom.x = clamp(target_zoom.x, min_zoom, max_zoom)
			target_zoom.y = clamp(target_zoom.y, min_zoom, max_zoom)
			# Optional: Zoom towards mouse cursor
			# zoom_towards_mouse(event.position, 1.0 - zoom_speed)
			get_viewport().set_input_as_handled() # Consume the event

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.is_pressed():
			target_zoom = zoom * (1.0 + zoom_speed)
			target_zoom.x = clamp(target_zoom.x, min_zoom, max_zoom)
			target_zoom.y = clamp(target_zoom.y, min_zoom, max_zoom)
			# Optional: Zoom towards mouse cursor
			# zoom_towards_mouse(event.position, 1.0 + zoom_speed)
			get_viewport().set_input_as_handled() # Consume the event

	# --- Panning (Example: Middle Mouse Button Drag) ---
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		# Adjust target position based on mouse movement, scaled by zoom
		# Note: Relative motion needs to be scaled inversely with zoom
		target_position -= event.relative / zoom
		get_viewport().set_input_as_handled()


# --- Movement Logic ---
func _physics_process(delta: float) -> void:
	# --- Smooth Panning ---
	var move_direction: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("ui_right"):
		move_direction.x += 1
	if Input.is_action_pressed("ui_left"):
		move_direction.x -= 1
	if Input.is_action_pressed("ui_down"):
		move_direction.y += 1
	if Input.is_action_pressed("ui_up"):
		move_direction.y -= 1

	# Normalize diagonal movement and apply speed/delta
	if move_direction != Vector2.ZERO:
		# Normalize if needed, apply speed, delta, and zoom scaling
		# Panning speed should feel consistent regardless of zoom level
		target_position += move_direction.normalized() * pan_speed * delta / zoom.x

	# Interpolate position for smoothness
	global_position = global_position.lerp(target_position, smoothing_factor)

	# --- Smooth Zooming ---
	zoom = zoom.lerp(target_zoom, smoothing_factor)

	# --- Emit Camera Events (Optional - connect to EventBus if needed) ---
	# Could emit signals here if other systems need to react to camera changes
	# EventBus.emit_signal("camera_moved", global_position)
	# EventBus.emit_signal("camera_zoomed", zoom.x)


# --- Helper Functions ---

# Optional: Implement zoom towards mouse cursor logic
# func zoom_towards_mouse(mouse_pos: Vector2, zoom_factor: float) -> void:
# 	var world_mouse_pos = get_global_mouse_position()
# 	var zoom_diff = zoom * (1.0 - zoom_factor)
# 	target_position = world_mouse_pos + (target_position - world_mouse_pos) * zoom_factor
# 	target_zoom = zoom * zoom_factor
# 	target_zoom.x = clamp(target_zoom.x, min_zoom, max_zoom)
# 	target_zoom.y = clamp(target_zoom.y, min_zoom, max_zoom)


# Optional: Add boundary checks
# func apply_boundaries() -> void:
#   pass # Implement logic to keep target_position within defined limits
