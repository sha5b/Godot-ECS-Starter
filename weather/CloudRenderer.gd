extends Node2D
class_name CloudRenderer

# Handles the visual representation of clouds based on the current weather state.

# --- Configuration ---
@export var cloud_color: Color = Color(1.0, 1.0, 1.0, 0.7) # Semi-transparent white
@export var cloud_density_factor: float = 50.0 # How many cloud sprites per unit of coverage
@export var cloud_area: Rect2 = Rect2(-500, -300, 1000, 600) # Area over which to spawn clouds (adjust based on camera view)
@export var cloud_sprite_size: Vector2 = Vector2(100, 50) # Base size of a cloud sprite

# --- References ---
# Assuming EventBus is an autoload singleton
# WeatherManager is a sibling node in the Main scene
@onready var event_bus: Node = get_node("/root/EventBus")         # Adjust path if different
@onready var weather_manager: Node = get_node("../WeatherManager") # Get sibling node

# --- State ---
var current_cloud_coverage: float = 0.0
var cloud_nodes: Array[Node2D] = [] # Store references to cloud sprites/nodes

# --- Initialization ---
func _ready() -> void:
	if event_bus:
		if event_bus.has_signal("weather_changed"):
			event_bus.weather_changed.connect(_on_weather_changed)
			print("CloudRenderer connected to EventBus.weather_changed")
			# Get initial state
			if weather_manager:
				var initial_state = weather_manager.get_current_weather()
				if initial_state:
					_update_clouds(initial_state)
				else:
					print("CloudRenderer: No initial weather state found.")
			else:
				printerr("CloudRenderer: WeatherManager not found at ready.")
		else:
			printerr("CloudRenderer: EventBus does not have 'weather_changed' signal.")
	else:
		printerr("CloudRenderer: EventBus not found.")

# --- Event Handlers ---
func _on_weather_changed(new_weather_state: Resource) -> void:
	if new_weather_state is WeatherState:
		print("CloudRenderer received weather change: ", new_weather_state.state_name)
		_update_clouds(new_weather_state)
	else:
		printerr("CloudRenderer: Received invalid weather state resource.")

# --- Internal Logic ---
func _update_clouds(weather_state: WeatherState) -> void:
	current_cloud_coverage = weather_state.cloud_coverage
	print("Updating clouds for coverage: ", current_cloud_coverage)

	# Clear existing clouds
	_clear_clouds()

	# Calculate number of clouds to draw
	var num_clouds = int(current_cloud_coverage * cloud_density_factor)
	print("Drawing %d clouds." % num_clouds)

	# Draw new clouds (simple placeholder: random circles)
	# TODO: Replace with more sophisticated sprites, particles, or shaders
	for i in range(num_clouds):
		var cloud_node = _create_cloud_sprite() # Using a helper function
		
		# Random position within the defined area
		var rand_pos = Vector2(
			randf_range(cloud_area.position.x, cloud_area.position.x + cloud_area.size.x),
			randf_range(cloud_area.position.y, cloud_area.position.y + cloud_area.size.y)
		)
		cloud_node.position = rand_pos
		
		# Add variation in size and transparency?
		cloud_node.scale = Vector2.ONE * randf_range(0.8, 1.5)
		cloud_node.modulate.a = randf_range(0.5, 1.0) * cloud_color.a

		# Add to scene and track
		add_child(cloud_node)
		cloud_nodes.append(cloud_node)

func _create_cloud_sprite() -> Node2D:
	# Placeholder: Use Sprite2D with default icon as a cloud visual
	# TODO: Replace with a proper cloud texture or particle system later
	
	var sprite = Sprite2D.new()
	
	# Load the default Godot icon texture
	var icon_texture = load("res://icon.svg") 
	if icon_texture:
		sprite.texture = icon_texture
	else:
		printerr("CloudRenderer: Could not load default icon.svg!")
		# Fallback: Create a ColorRect if icon fails to load
		var rect = ColorRect.new()
		rect.size = cloud_sprite_size
		rect.color = cloud_color
		rect.pivot_offset = rect.size / 2
		return rect # Return the fallback rect

	# Tint the sprite with the cloud color (including alpha)
	sprite.modulate = cloud_color
	
	# Scale the sprite roughly based on the desired cloud size vs icon size (icon is 128x128)
	var icon_base_size = Vector2(128, 128) 
	sprite.scale = cloud_sprite_size / icon_base_size
	
	# Center the sprite's origin
	sprite.centered = true 
	
	return sprite
	
	# --- Alternative using a specific cloud texture ---
	# if cloud_texture: # Assume cloud_texture = load("res://path/to/cloud.png")
	#	 var sprite = Sprite2D.new()
	#	 sprite.texture = cloud_texture
	#	 sprite.modulate = cloud_color # Apply base color/alpha
	#	 # Set scale based on cloud_sprite_size and texture size if needed
	#	 return sprite
	# else:
	#	 printerr("Cloud texture not loaded!")
	#	 # Fallback to drawing
	#	 var rect = ColorRect.new()
	#	 rect.size = cloud_sprite_size
	#	 rect.color = cloud_color
	#	 rect.pivot_offset = rect.size / 2
	#	 return rect


func _clear_clouds() -> void:
	print("Clearing existing clouds...")
	for node in cloud_nodes:
		if is_instance_valid(node):
			node.queue_free()
	cloud_nodes.clear()

# --- Add movement in _process ---
func _process(delta: float) -> void:
	# Ensure weather_manager is valid and we have a current state
	if not is_instance_valid(weather_manager): return 
	var current_state = weather_manager.get_current_weather()
	if not current_state is WeatherState: return 
		
	var wind_speed = current_state.wind_speed
	# Ensure wind_direction is a valid Vector2 and normalized
	var wind_dir = Vector2.ZERO 
	if current_state.wind_direction is Vector2:
		wind_dir = current_state.wind_direction.normalized() 
		
	# Calculate movement vector (adjust scaling factor as needed)
	# Multiplier (e.g., 10.0) controls how fast clouds move visually relative to wind speed unit
	var move_vector = wind_dir * wind_speed * delta * 10.0 
		
	for cloud in cloud_nodes:
		if is_instance_valid(cloud):
			cloud.position += move_vector
			# Optional: Wrap clouds around the cloud_area to keep them visible
			# Check X bounds
			if cloud.position.x > cloud_area.position.x + cloud_area.size.x + cloud_sprite_size.x: # Add buffer
				cloud.position.x = cloud_area.position.x - cloud_sprite_size.x # Move to other side
			elif cloud.position.x < cloud_area.position.x - cloud_sprite_size.x: # Add buffer
				cloud.position.x = cloud_area.position.x + cloud_area.size.x + cloud_sprite_size.x # Move to other side
				
			# Check Y bounds (optional, depends if you want vertical wrapping)
			if cloud.position.y > cloud_area.position.y + cloud_area.size.y + cloud_sprite_size.y: # Add buffer
				cloud.position.y = cloud_area.position.y - cloud_sprite_size.y # Move to top/bottom
			elif cloud.position.y < cloud_area.position.y - cloud_sprite_size.y: # Add buffer
				cloud.position.y = cloud_area.position.y + cloud_area.size.y + cloud_sprite_size.y # Move to top/bottom
