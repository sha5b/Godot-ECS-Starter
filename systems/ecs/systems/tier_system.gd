class_name TierSystem
extends RefCounted

## Distance-based processing tier assignment, BotW A/B/C profile style.
##
## Near actors simulate every frame, mid-range every 4th, far every 12th,
## out-of-range go dormant. Rechecked on a coarse timer and staggered by the
## scheduler's per-entity offsets, which is how BotW keeps hundreds of
## actors alive without frame spikes.

var near_distance := 40.0
var mid_distance := 120.0
var far_distance := 300.0
var recheck_frames := 15

var _cache: EcsWorld.QueryCache = null
var _frames := 0


func tick(world: EcsWorld, delta: float, _frame: int) -> void:
	if _cache == null:
		_cache = world.query([&"CTransform"])
	_frames += 1
	if _frames % recheck_frames != 0:
		return
	var focus := world.focus_position
	var distances := {}
	for entity in world.all_entities(_cache):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if transform != null:
			distances[entity] = transform.position.distance_squared_to(focus)
	world.assign_tiers_by_distance(distances, near_distance, mid_distance, far_distance)
