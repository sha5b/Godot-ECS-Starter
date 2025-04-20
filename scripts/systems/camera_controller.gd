extends Camera2D

class_name CameraController

@export var move_speed: float = 300.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.2
@export var max_zoom: float = 2.0

var is_panning: bool = false
var last_mouse_pos: Vector2

func _ready():
	# Ensure this camera is the current one for the viewport
	make_current()
	print("CameraController initialized and set as current.")

func _input(event: InputEvent): # Changed from _unhandled_input
	# --- Zooming ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: # Removed event.pressed check
			_adjust_zoom(-zoom_speed)
			get_viewport().set_input_as_handled() # Mark event as handled
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: # Removed event.pressed check
			_adjust_zoom(zoom_speed)
			get_viewport().set_input_as_handled() # Mark event as handled

	# --- Panning (Left Mouse Button) ---
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT: # Changed to Left Button
		if event.pressed:
			is_panning = true
			# No need to capture mouse or store last_mouse_pos when using event.relative
			# Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		else:
			is_panning = false
			# Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		# We handle the button press/release itself, so mark as handled
		get_viewport().set_input_as_handled()

	# Handle mouse motion only when panning is active
	if event is InputEventMouseMotion and is_panning:
		# Adjust position based on mouse movement
		# Negative delta because we want the world to move opposite to the mouse drag
		global_position -= event.relative # Removed zoom scaling for simplicity
		get_viewport().set_input_as_handled() # Mark event as handled


func _adjust_zoom(amount: float):
	var new_zoom = zoom + Vector2(amount, amount)
	# Clamp zoom level
	new_zoom.x = clamp(new_zoom.x, min_zoom, max_zoom)
	new_zoom.y = clamp(new_zoom.y, min_zoom, max_zoom)
	zoom = new_zoom
	# print("Zoom adjusted to: ", zoom) # Optional debug print

# Optional: Add keyboard movement if desired
# func _process(delta):
# 	var direction = Vector2.ZERO
# 	if Input.is_action_pressed("ui_right"):
# 		direction.x += 1
# 	if Input.is_action_pressed("ui_left"):
# 		direction.x -= 1
# 	if Input.is_action_pressed("ui_down"):
# 		direction.y += 1
# 	if Input.is_action_pressed("ui_up"):
# 		direction.y -= 1
#
# 	if direction != Vector2.ZERO:
# 		# Normalize and apply speed and delta time
# 		global_position += direction.normalized() * move_speed * delta
