extends Node2D
class_name NPCSpeechBubble

# Speech bubble for NPCs to display text

var bubble_panel: PanelContainer
var label: Label
var timer: Timer
var display_time: float = 4.0  # How long to show the bubble
var hide_on_timeout: bool = true

var current_text: String = ""
var text_animation_speed: float = 0.05  # Seconds per character
var is_animating: bool = false
var animated_text_index: int = 0

signal animation_completed

func _ready():
	_create_bubble()
	visible = false

func _create_bubble():
	# Create panel for bubble background
	bubble_panel = PanelContainer.new()
	bubble_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	
	# Custom stylebox for bubble appearance
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.9)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.2, 0.2, 0.2)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_right = 8
	style.corner_radius_bottom_left = 8
	
	bubble_panel.add_theme_stylebox_override("panel", style)
	
	# Margin container for padding
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	
	# Text label
	label = Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = ""
	label.add_theme_color_override("font_color", Color(0, 0, 0))
	
	# Add the components
	margin.add_child(label)
	bubble_panel.add_child(margin)
	add_child(bubble_panel)
	
	# Position adjustment to center above entity
	bubble_panel.position = Vector2(-75, -80)
	bubble_panel.custom_minimum_size = Vector2(150, 0)
	
	# Timer for automatic hiding
	timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = display_time
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)
	
	# Animation timer
	var anim_timer = Timer.new()
	anim_timer.name = "AnimTimer"
	anim_timer.wait_time = text_animation_speed
	anim_timer.timeout.connect(_on_animation_timer_timeout)
	add_child(anim_timer)

func show_text(text: String, time: float = 4.0, animated: bool = true):
	# Store the full text
	current_text = text
	display_time = time
	
	if animated:
		# Start animation
		is_animating = true
		animated_text_index = 0
		label.text = ""
		get_node("AnimTimer").start()
	else:
		# Show immediately
		label.text = text
		is_animating = false
		animation_completed.emit()
	
	# Make visible
	visible = true
	
	# Reset and start the timer if auto-hide
	if hide_on_timeout:
		timer.wait_time = display_time
		timer.start()
	
	# Add a small pop-up animation
	var tween = create_tween()
	bubble_panel.scale = Vector2(0.1, 0.1)
	tween.tween_property(bubble_panel, "scale", Vector2(1, 1), 0.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_ELASTIC)

func hide_bubble():
	# Animate out
	var tween = create_tween()
	tween.tween_property(bubble_panel, "scale", Vector2(0.1, 0.1), 0.1)
	tween.tween_callback(func(): visible = false)

func _on_timer_timeout():
	if hide_on_timeout:
		hide_bubble()

func _on_animation_timer_timeout():
	if is_animating:
		animated_text_index += 1
		if animated_text_index <= current_text.length():
			label.text = current_text.substr(0, animated_text_index)
			get_node("AnimTimer").start()
		else:
			is_animating = false
			animation_completed.emit()
