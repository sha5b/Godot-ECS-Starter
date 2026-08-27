class_name CritterView
extends EntityView

## EntityView for genome-backed critters: builds the procedural body from
## the entity's CGenome and animates it from simulation motion.
##
## Data flows one way, per the view doctrine — ViewSyncSystem pushes the
## genome, the entity's processing tier and a speed ratio in; the view never
## writes simulation state.
##
## DISTANCE LOD. The world spawns critters per chunk across the whole
## streamed region, which at the shipped load radius is well over a
## thousand of them. Building a full rig for every one — and ticking its
## gait and re-skinning its torso every frame — is not affordable, and it
## is also pointless for a creature a few hundred metres away. So:
##
##   tier 0 (near)   full body, gait every frame
##   tier 1+ (mid)   no body at all; the rig is freed
## (detail_cutoff_tier moves that line; the gait cadence table below still
## supports a mid tier if a scene wants richer detail.)
##
## Dropping the body is safe precisely because it is a view: the genome is
## the authority and rebuilding from it is deterministic, so a critter that
## walks back into range returns identical to the one that walked out.
##
## demo_speed_ratio overrides simulated motion when >= 0 — the Body Lab
## treadmills use it to show gaits on entities that aren't moving.

## Forced gait intensity for showcase/treadmill use (-1 = follow sim).
@export var demo_speed_ratio := -1.0

## First tier at which the procedural body is dropped entirely.
## 1 = near critters only. Measured on the streamed world, allowing mid
## tier as well put 232 full rigs in the scene at once; near-only holds it
## to a couple of dozen, and tier 0 already reaches 40 m from the focus.
@export var detail_cutoff_tier := 1

## Gait ticks per tier, mirroring EcsWorld.TIER_CADENCE. 0 = never.
const GAIT_CADENCE := [1, 4, 0, 0]

var _body_root: Node3D = null
var _gait: CritterGait = null
var _genome: CritterGenome = null
var _genome_seed_seen := -1
var _motion_ratio := 0.0
var _tier := 0
var _gait_accum := 0.0
var _frames := 0


## Called by ViewSyncSystem when the entity has a CGenome component.
func apply_genome(source: CritterGenome) -> void:
	if source == null:
		return
	_genome = source
	_refresh_body()


## Called by ViewSyncSystem with the entity's ECS processing tier.
func apply_detail(tier: int) -> void:
	if tier == _tier:
		return
	_tier = tier
	_refresh_body()


## Called by ViewSyncSystem with |CVelocity| / move_speed, clamped 0..1.
func apply_motion(speed_ratio: float) -> void:
	_motion_ratio = clampf(speed_ratio, 0.0, 1.0)


## True while a rig exists (tests and tooling ask).
func has_body() -> bool:
	return _body_root != null


## Build, keep or drop the rig to match the current genome and tier.
func _refresh_body() -> void:
	var wanted := _genome != null and _tier < detail_cutoff_tier
	if wanted:
		if _body_root != null and _genome.seed_value == _genome_seed_seen:
			return
		if _body_root != null:
			_body_root.queue_free()
		_genome_seed_seen = _genome.seed_value
		_body_root = CritterBodyBuilder.build(_genome)
		add_child(_body_root)
		_gait = _body_root.get_node_or_null("Gait") as CritterGait
		if _gait != null:
			_gait.ground_sampler = _sample_ground
	elif _body_root != null:
		_body_root.queue_free()
		_body_root = null
		_gait = null
		# Force a rebuild when the critter returns to range.
		_genome_seed_seen = -1


func _process(delta: float) -> void:
	super(delta)
	if _gait == null:
		return
	var cadence: int = GAIT_CADENCE[clampi(_tier, 0, GAIT_CADENCE.size() - 1)]
	if cadence <= 0:
		return
	# Coarse tiers accumulate delta and tick in one larger step, so the
	# gait advances at the same rate it would have at full cadence.
	_gait_accum += delta
	_frames += 1
	if _frames % cadence != 0:
		return
	var ratio := _motion_ratio if demo_speed_ratio < 0.0 else clampf(demo_speed_ratio, 0.0, 1.0)
	_gait.tick(_gait_accum, ratio)
	_gait_accum = 0.0


## Ground height under a world XZ, for the gait's foot IK.
##
## Raycasts the terrain collider. Only near and mid critters have rigs at
## all (see the LOD note above), and the sampler is called once per foot,
## so this stays a small fixed number of rays per frame rather than one
## per critter in the world.
func _sample_ground(x: float, z: float) -> float:
	if not is_inside_tree():
		return INF
	var space := get_world_3d().direct_space_state
	if space == null:
		return INF
	var from := Vector3(x, global_position.y + 6.0, z)
	var query := PhysicsRayQueryParameters3D.create(from, Vector3(x, global_position.y - 12.0, z))
	query.hit_back_faces = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return INF
	return (hit["position"] as Vector3).y


## Procedural bodies own their materials (genome colors), so the generic
## tint/elemental override on the first mesh is disabled.
func _find_mesh() -> MeshInstance3D:
	return null
