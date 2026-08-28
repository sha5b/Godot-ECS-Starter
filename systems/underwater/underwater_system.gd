class_name UnderwaterSystem
extends BaseSystem

## Drives the submerged-camera look: a full-screen shader pass plus an
## Environment fog override, blended in as the camera drops below sea level.
##
## Runs after WeatherSystem so the fog override wins while submerged, and
## restores whatever the weather left behind on the way back up.

const OVERLAY_SHADER := preload("res://systems/underwater/underwater.gdshader")

var _config: UnderwaterConfig

var _layer: CanvasLayer
var _overlay: ColorRect
var _material: ShaderMaterial

var _environment: Environment
## Fog state captured on the frame the camera went under, restored on surfacing.
var _dry_fog_enabled: bool = false
var _dry_fog_color: Color = Color.WHITE
var _dry_fog_density: float = 0.0
var _dry_ambient_energy: float = 1.0
var _dry_state_valid: bool = false

## Blend from dry (0) to fully submerged (1).
var _submersion: float = 0.0


func _initialize() -> void:
	system_name = &"UnderwaterSystem"
	# After WeatherSystem (20) and the weather volumes (22) so the fog
	# override is the last write to the Environment each frame.
	priority = 40

	_config = _find_child_of_type(UnderwaterConfig)
	if not _config:
		push_warning("[UnderwaterSystem] No UnderwaterConfig child found — using defaults")
		_config = UnderwaterConfig.new()

	_build_overlay()


func _build_overlay() -> void:
	_material = ShaderMaterial.new()
	_material.shader = OVERLAY_SHADER

	_overlay = ColorRect.new()
	_overlay.name = "UnderwaterOverlay"
	_overlay.material = _material
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false

	_layer = CanvasLayer.new()
	_layer.name = "UnderwaterLayer"
	# Above the world, below the debug HUD and observer overlays.
	_layer.layer = -1
	_layer.add_child(_overlay)
	add_child(_layer)

	_push_uniforms()


func _push_uniforms() -> void:
	_material.set_shader_parameter(&"tint", _config.water_tint)
	_material.set_shader_parameter(&"wave_speed", _config.wave_speed)
	_material.set_shader_parameter(&"wave_frequency", _config.wave_frequency)
	_material.set_shader_parameter(&"wave_width", _config.wave_width)
	_material.set_shader_parameter(&"blur_radius", _config.blur_radius)
	_material.set_shader_parameter(&"vignette", _config.vignette)


func system_process(delta: float) -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return

	var depth := SharedWorld.sea_level - camera.global_position.y
	var target := clampf(depth / maxf(_config.blend_depth, 0.001), 0.0, 1.0)
	# Ease rather than snap — the surface line jitters with waves and boom clamps.
	_submersion = move_toward(_submersion, target, delta * 4.0)

	SharedWorld.camera_submersion = _submersion

	var submerged := _submersion > 0.001
	if _overlay.visible != submerged:
		_overlay.visible = submerged
	if submerged:
		_material.set_shader_parameter(&"amount", _submersion)

	_apply_fog(submerged)


## Blend the Environment toward underwater fog, and hand it back to the
## weather system once the camera surfaces.
func _apply_fog(submerged: bool) -> void:
	if _environment == null:
		var world_env := _find_world_environment()
		if world_env == null:
			return
		_environment = world_env.environment
		if _environment == null:
			return

	if submerged:
		if not _dry_state_valid:
			_dry_fog_enabled = _environment.fog_enabled
			_dry_fog_color = _environment.fog_light_color
			_dry_fog_density = _environment.fog_density
			_dry_ambient_energy = _environment.ambient_light_energy
			_dry_state_valid = true
		_environment.fog_enabled = true
		_environment.fog_light_color = _environment.fog_light_color.lerp(
			_config.fog_color, _submersion)
		_environment.fog_density = lerpf(
			_environment.fog_density, _config.fog_density, _submersion)
		_environment.ambient_light_energy = lerpf(
			_dry_ambient_energy, _dry_ambient_energy * _config.ambient_dim, _submersion)
	elif _dry_state_valid:
		# WeatherSystem rewrites colour and density every frame, so only the
		# flags it does not own need restoring.
		_environment.fog_enabled = _dry_fog_enabled
		_environment.ambient_light_energy = _dry_ambient_energy
		_dry_state_valid = false


func _find_world_environment() -> WorldEnvironment:
	var root := get_tree().current_scene
	if root == null:
		return null
	for child in root.get_children():
		if child is WorldEnvironment:
			return child as WorldEnvironment
	return null
