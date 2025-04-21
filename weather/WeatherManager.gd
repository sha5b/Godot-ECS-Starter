extends Node

# Control point for the weather system
# Manages weather states, transitions, and effects

# --- Configuration ---
@export var default_weather_state: Resource # Assign a default WeatherState resource

# --- State ---
var current_weather_state: Resource
var transition_progress: float = 0.0 # 0.0 to 1.0 for transitions
var next_weather_state: Resource = null

# --- References ---
# @onready var effect_controller: EffectController = $EffectController # Handles visual/audio
# Assuming WorldState and EventBus are autoload singletons
@onready var world_state: Node = get_node("/root/WorldState") # Adjust path if different
@onready var event_bus: Node = get_node("/root/EventBus")     # Adjust path if different

# --- Signals (Internal - Use EventBus for external communication) ---
# signal weather_state_changed(new_state: Resource) # Keep internal if needed, but prefer EventBus


# --- Initialization ---
func _ready() -> void:
	if default_weather_state:
		set_weather_state(default_weather_state)
	else:
		printerr("WeatherManager: Default weather state not set!")
		# Optionally create a default clear state if none is provided?
		# current_weather_state = WeatherState.new() 
		# emit_signal("weather_state_changed", current_weather_state) # Emit initial state via EventBus too
		# if event_bus: event_bus.emit_signal("weather_changed", current_weather_state)

	# Connect to relevant events
	if world_state:
		if world_state.has_signal("time_updated"):
			world_state.time_updated.connect(_on_time_updated)
		else:
			printerr("WeatherManager: WorldState does not have 'time_updated' signal.")
	else:
		printerr("WeatherManager: Could not find WorldState node.")
		
	# EventBus.hour_passed.connect(_on_hour_passed) # Example if using EventBus

	print("WeatherManager Ready.")


# --- Public API ---
func get_current_weather() -> Resource:
	return current_weather_state


func force_weather_state(new_state: Resource) -> void:
	# Immediately switch state without transition (e.g., for debugging or specific events)
	print("Forcing weather state to: ", new_state.resource_path if new_state else "None")
	current_weather_state = new_state
	next_weather_state = null
	transition_progress = 0.0
	# emit_signal("weather_state_changed", current_weather_state) # Internal signal if needed
	if event_bus: 
		event_bus.emit_signal("weather_changed", current_weather_state) # Notify other systems via EventBus
	else:
		printerr("WeatherManager: EventBus not found, cannot emit weather_changed.")
	# Update effects immediately
	# if effect_controller: effect_controller.apply_state(current_weather_state)


func trigger_weather_transition(target_state: Resource, duration: float = 10.0) -> void:
	# Start a gradual transition to a new state
	if target_state and target_state != current_weather_state:
		print("Starting weather transition to: ", target_state.resource_path)
		next_weather_state = target_state
		# Reset progress, store duration (or calculate based on state properties)
		transition_progress = 0.0 
		# Store duration if needed for _process logic
		# self.transition_duration = duration 


# --- Internal Logic ---
func _process(delta: float) -> void:
	if next_weather_state:
		# Handle gradual transition
		transition_progress += delta / get_transition_duration() # Needs transition duration logic
		transition_progress = clamp(transition_progress, 0.0, 1.0)
		
		# Update effects based on interpolation between current and next state
		# if effect_controller: effect_controller.update_transition(current_weather_state, next_weather_state, transition_progress)

		if transition_progress >= 1.0:
			# Transition complete
			print("Weather transition finished.")
			set_weather_state(next_weather_state)


func set_weather_state(new_state: Resource) -> void:
	# Internal function to finalize state change
	print("Setting final weather state to: ", new_state.resource_path if new_state else "None")
	current_weather_state = new_state
	next_weather_state = null
	transition_progress = 0.0
	# emit_signal("weather_state_changed", current_weather_state) # Internal signal if needed
	if event_bus: 
		event_bus.emit_signal("weather_changed", current_weather_state) # Notify other systems via EventBus
	else:
		printerr("WeatherManager: EventBus not found, cannot emit weather_changed.")
	# Update effects
	# if effect_controller: effect_controller.apply_state(current_weather_state)


func get_transition_duration() -> float:
	# TODO: Determine transition duration based on current/next states or config
	return 10.0 # Placeholder duration

# --- Event Handlers ---
func _on_time_updated(delta_time: float, current_time: float) -> void:
	# Basic placeholder: Trigger a change every N seconds if not already transitioning
	# TODO: Replace with more sophisticated logic based on state properties, time of day, etc.
	var change_interval = 60.0 # Change weather every 60 game seconds (adjust as needed)
	
	if not next_weather_state and current_weather_state: # Only trigger if not already transitioning
		# Use fmod to check intervals based on total time
		# This check is very basic, might trigger repeatedly near the interval boundary
		# A better approach might track time since last change or use probabilities
		if fmod(current_time, change_interval) < delta_time * world_state.time_scale: 
			print("Time interval reached, considering weather change...")
			# Simple logic: Pick a random next state (if available) or toggle default
			var next_state = _select_next_weather_state()
			if next_state and next_state != current_weather_state:
				trigger_weather_transition(next_state, 15.0) # Start a 15s transition


func _select_next_weather_state() -> Resource:
	# TODO: Implement more sophisticated logic (probabilities, state transitions defined in resources, etc.)
	
	# Simple Toggle Logic: Switch between Clear and Cloudy
	print("Selecting next weather state...")
	
	# Load the available states (Consider preloading these in _ready or exporting them for better performance)
	var clear_state = load("res://weather/states/clear.tres")
	var cloudy_state = load("res://weather/states/cloudy.tres")
	
	if not clear_state or not cloudy_state:
		printerr("WeatherManager: Could not load clear or cloudy state resources!")
		return null # Cannot select if states aren't loaded

	if not current_weather_state:
		printerr("WeatherManager: Cannot select next state, current state is null.")
		return default_weather_state # Fallback to default if current is somehow null
		
	# Check the name of the current state and return the other one
	if current_weather_state.state_name == "Clear":
		print("Current state is Clear, selecting Cloudy.")
		return cloudy_state
	elif current_weather_state.state_name == "Cloudy":
		print("Current state is Cloudy, selecting Clear.")
		return clear_state
	else:
		# If current state is neither Clear nor Cloudy (e.g., a future state), default to Clear for now
		print("Current state is unknown ('%s'), defaulting to Clear." % current_weather_state.state_name)
		return clear_state


# func _on_hour_passed() -> void:
	# Another potential trigger point for weather logic
	# pass
