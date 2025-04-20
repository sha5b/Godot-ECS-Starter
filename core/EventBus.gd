extends Node

# Custom event bus for system communication

# Define event signals here
# Example: Weather System Events
signal weather_changed(new_weather_state: Resource) # Pass a WeatherState resource
signal precipitation_started(type: String, intensity: float)
signal precipitation_stopped()

# Example: Time System Events (can also be connected directly from WorldState)
signal day_passed()
signal hour_passed()

# Example: Terrain System Events
signal terrain_modified(region_id: String, changes: Dictionary) # Describe changes
signal region_entered(region_id: String)
signal region_exited(region_id: String)

# Example: Camera System Events
signal camera_moved(new_position: Vector2)
signal camera_zoomed(new_zoom: float)

# Add more specific events as needed by different systems

# --- Optional: Helper methods for subscribing/unsubscribing if needed ---
# While direct connection (object.signal_name.connect(callable)) is often preferred in Godot,
# you could add helper methods if you want more centralized control or logging.

# func subscribe(event_name: String, target: Object, method_name: String) -> void:
# 	if has_signal(event_name):
# 		var signal_ref = get_signal_connection_list(event_name) # Check if already connected?
# 		# Basic connection:
# 		var error = connect(event_name, Callable(target, method_name))
# 		if error != OK:
# 			printerr("Failed to connect to event bus signal: ", event_name)
# 	else:
# 		printerr("Attempted to subscribe to non-existent event: ", event_name)

# func unsubscribe(event_name: String, target: Object, method_name: String) -> void:
# 	if has_signal(event_name):
# 		if is_connected(event_name, Callable(target, method_name)):
# 			disconnect(event_name, Callable(target, method_name))
# 	else:
# 		printerr("Attempted to unsubscribe from non-existent event: ", event_name)


# --- Method to emit events (can be called from anywhere with access to the EventBus singleton) ---
# Example: How another system might emit an event
# func emit_weather_change(new_state: Resource) -> void:
# 	emit_signal("weather_changed", new_state)
