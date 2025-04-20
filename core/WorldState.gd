extends Node

# Manages global time and environmental state
# Dispatches events to all subscribed systems
# Tracks regional information and transitions

# Global time (e.g., in game seconds)
var current_time: float = 0.0
var time_scale: float = 1.0 # Speed multiplier for time progression

# Environmental state (example)
var global_temperature: float = 20.0 # Celsius

# Regional information (placeholder)
var active_region: String = "default"

# Signal for time updates
signal time_updated(delta_time: float, current_time: float)
# Signal for environmental changes (example)
signal temperature_changed(new_temperature: float)


func _process(delta: float) -> void:
	var scaled_delta = delta * time_scale
	current_time += scaled_delta
	emit_signal("time_updated", scaled_delta, current_time)

	# Example: Update temperature based on time (simple placeholder)
	# In a real scenario, this would be driven by more complex logic or events
	# var new_temp = 20.0 + 5.0 * sin(current_time / 100.0) 
	# if abs(new_temp - global_temperature) > 0.1:
	# 	global_temperature = new_temp
	# 	emit_signal("temperature_changed", global_temperature)


func set_time_scale(scale: float) -> void:
	time_scale = max(0.0, scale) # Ensure time scale is non-negative


func get_current_time() -> float:
	return current_time


func get_global_temperature() -> float:
	return global_temperature


func set_active_region(region_name: String) -> void:
	if active_region != region_name:
		print("Transitioning to region: ", region_name)
		active_region = region_name
		# Emit a signal for region change if needed
		# emit_signal("region_changed", active_region)

func get_active_region() -> String:
	return active_region
