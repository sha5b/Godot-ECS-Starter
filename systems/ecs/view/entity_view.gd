class_name EntityView
extends Node3D

## Scene-tree mirror of one ECS entity, driven by ViewSyncSystem.
##
## Visual states come from CElemental data: burning pulses orange, charred
## goes black and shrinks, frozen turns icy blue, wet darkens. The view
## never feeds information back into the simulation.

const BURN_COLOR := Color(1.0, 0.45, 0.1)
const CHAR_COLOR := Color(0.08, 0.07, 0.06)
const FROZEN_COLOR := Color(0.65, 0.85, 1.0)
const WET_DARKEN := 0.65

## The entity this view mirrors (set by ViewSyncSystem.bind).
var entity := 0

## Base albedo tint (species color, prop color).
@export var tint := Color.WHITE

var _mesh: MeshInstance3D
var _material: StandardMaterial3D
var _base_scale := Vector3.ONE
var _time := 0.0


func _ready() -> void:
	_mesh = _find_mesh()
	if _mesh != null:
		_material = StandardMaterial3D.new()
		_material.albedo_color = tint
		_mesh.material_override = _material
	_base_scale = scale


func _process(delta: float) -> void:
	_time += delta
	if _material != null and _material.emission_enabled:
		_material.emission_energy_multiplier = 1.5 + 0.8 * sin(_time * 18.0)


## Apply elemental visual state. Called by ViewSyncSystem when data changes.
func apply_elemental(elemental: CElemental) -> void:
	if _material == null:
		return
	var color := tint
	var scale_factor := 1.0
	_material.emission_enabled = false

	if elemental.charred:
		color = CHAR_COLOR
		scale_factor = 0.55
	elif elemental.frozen:
		color = FROZEN_COLOR
		scale_factor = 0.92
	elif elemental.burning:
		color = BURN_COLOR
		_material.emission_enabled = true
		_material.emission = BURN_COLOR
	elif elemental.wetness > 0.4:
		color = tint.darkened(1.0 - WET_DARKEN)

	if elemental.shock_timer > 0.0:
		_material.emission_enabled = true
		_material.emission = Color.WHITE
		color = color.lerp(Color.WHITE, 0.6)
		# shock_timer counts down in the simulation; views only read it.

	_material.albedo_color = color
	scale = _base_scale * scale_factor


func _find_mesh() -> MeshInstance3D:
	for child in get_children():
		if child is MeshInstance3D:
			return child
	return null
