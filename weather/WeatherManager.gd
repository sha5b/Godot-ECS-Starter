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

# --- Signals (or connect to EventBus) ---
signal weather_state_changed(new_state: Resource)


# --- Initialization ---
func _ready() -> void:
	if default_weather_state:
		set_weather_state(default_weather_state)
	else:
		printerr("WeatherManager: Default weather state not set!")
	
	# Connect to relevant events (e.g., time changes from WorldState or EventBus)
	# WorldState.time_updated.connect(_on_time_updated) # Example if WorldState is an autoload
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
	emit_signal("weather_state_changed", current_weather_state)
	# EventBus.emit_signal("weather_changed", current_weather_state) # Notify other systems
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
	current_weather_state = new_state
	next_weather_state = null
	transition_progress = 0.0
	emit_signal("weather_state_changed", current_weather_state)
	# EventBus.emit_signal("weather_changed", current_weather_state) # Notify other systems
	# Update effects
	# if effect_controller: effect_controller.apply_state(current_weather_state)


func get_transition_duration() -> float:
	# TODO: Determine transition duration based on current/next states or config
	return 10.0 # Placeholder duration


# --- Event Handlers ---
# func _on_time_updated(delta_time: float, current_time: float) -> void:
	# TODO: Implement logic for natural weather changes based on time/season etc.
	# Example: Check if conditions are right for a new weather state transition
	# if should_weather_change():
	#	 trigger_weather_transition(select_next_weather_state(), 30.0) # Example

# func _on_hour_passed() -> void:
	# Another potential trigger point for weather logic
	# pass
