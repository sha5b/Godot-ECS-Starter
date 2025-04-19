extends Node

# Main game controller that manages all game systems

# System references
var world_generator = null
var entity_manager = null
var environment_system = null
var ui_system = null

# Debug flags
var debug_mode: bool = true
var show_collision: bool = true
var show_navigation: bool = true
var show_spawn_points: bool = true

func _ready():
	print("Game Manager initialized")
	
	# Initialize systems
	_initialize_systems()
	
func _initialize_systems():
	print("Initializing game systems...")
	
	# Connect signals
	
func get_debug_status(debug_type: String) -> bool:
	match debug_type:
		"collision":
			return show_collision
		"navigation":
			return show_navigation
		"spawn_points":
			return show_spawn_points
		_:
			return debug_mode
