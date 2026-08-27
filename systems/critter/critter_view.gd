class_name CritterView
extends EntityView

## EntityView for genome-backed critters: builds the procedural body from
## the entity's CGenome and animates it from simulation motion.
##
## Data flows one way, per the view doctrine — ViewSyncSystem pushes the
## genome and a speed ratio in; the view never writes simulation state.
## The genome is only rebuilt when its seed changes, so per-frame cost is
## just the gait evaluation.
##
## demo_speed_ratio overrides simulated motion when >= 0 — the Body Lab
## treadmills use it to show gaits on entities that aren't moving.

## Forced gait intensity for showcase/treadmill use (-1 = follow sim).
@export var demo_speed_ratio := -1.0

var _body_root: Node3D = null
var _gait: CritterGait = null
var _genome_seed_seen := -1
var _motion_ratio := 0.0


## Called by ViewSyncSystem when the entity has a CGenome component.
func apply_genome(source: CritterGenome) -> void:
	if source == null or source.seed_value == _genome_seed_seen:
		return
	_genome_seed_seen = source.seed_value
	if _body_root != null:
		_body_root.queue_free()
	_body_root = CritterBodyBuilder.build(source)
	add_child(_body_root)
	_gait = _body_root.get_node_or_null("Gait") as CritterGait


## Called by ViewSyncSystem with |CVelocity| / move_speed, clamped 0..1.
func apply_motion(speed_ratio: float) -> void:
	_motion_ratio = clampf(speed_ratio, 0.0, 1.0)


func _process(delta: float) -> void:
	super(delta)
	if _gait == null:
		return
	var ratio := _motion_ratio if demo_speed_ratio < 0.0 else clampf(demo_speed_ratio, 0.0, 1.0)
	_gait.tick(delta, ratio)


## Procedural bodies own their materials (genome colors), so the generic
## tint/elemental override on the first mesh is disabled.
func _find_mesh() -> MeshInstance3D:
	return null
