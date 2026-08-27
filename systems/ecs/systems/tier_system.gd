class_name TierSystem
extends RefCounted

## Distance-based processing tier assignment, BotW A/B/C profile style.
##
## Near actors simulate every frame, mid-range every 4th, far every 12th,
## out-of-range go dormant. Rechecked on a coarse timer and staggered by the
## scheduler's per-entity offsets, which is how BotW keeps hundreds of
## actors alive without frame spikes.
##
## The pass is SLICED across frames. Reassigning every actor in one tick
## cost 35 ms to gather plus 14 ms to apply at world population — a visible
## hitch four times a second, every second, even when nothing had moved.
## Walking a fixed-size slice per frame spreads that into a flat cost and
## still revisits every actor several times a second.

var near_distance := 40.0
var mid_distance := 120.0
var far_distance := 300.0
## Retained for compatibility; the slice walk supersedes the timer.
var recheck_frames := 15

## How many entities to reconsider per tick. The whole population is swept
## every ceil(count / slice) frames.
var slice_size := 512

var _cache: EcsWorld.QueryCache = null
var _cursor := 0


func tick(world: EcsWorld, _delta: float, _frame: int) -> void:
	if _cache == null:
		_cache = world.query([&"CTransform"])
	var entities := world.all_entities_scratch(_cache)
	var total := entities.size()
	if total == 0:
		return

	var focus := world.focus_position
	var near_sq := near_distance * near_distance
	var mid_sq := mid_distance * mid_distance
	var far_sq := far_distance * far_distance

	var budget := mini(slice_size, total)
	if _cursor >= total:
		_cursor = 0
	for step in budget:
		var i := (_cursor + step) % total
		var entity := entities[i]
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if transform == null:
			continue
		# Tier inline instead of accumulating a Dictionary of every actor's
		# distance and handing it back — that dictionary was itself one of
		# the larger per-tick allocations in the runtime.
		var dist_sq := transform.position.distance_squared_to(focus)
		var tier := 3
		if dist_sq < near_sq:
			tier = 0
		elif dist_sq < mid_sq:
			tier = 1
		elif dist_sq < far_sq:
			tier = 2
		world.set_tier(entity, tier)
	_cursor = (_cursor + budget) % total
