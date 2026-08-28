class_name EcsActorIndex
extends RefCounted

## Shared spatial index over living actors, rebuilt on a coarse timer.
##
## Predation and flocking both need the same question answered — "which
## animals are near this one, and what species are they?" — and both would
## otherwise build and refill their own uniform grid every tick. One index,
## rebuilt once per refresh window, is what keeps a herd of a few hundred
## animals off the frame budget.
##
## Positions are a snapshot. Animals move between refreshes, so callers must
## re-read a candidate's CTransform before acting on it rather than trusting
## the position that was indexed.

## Cell size of the grid. Should be a little larger than the widest query
## radius any consumer uses, or queries walk many cells.
var cell_size := 12.0:
	set(value):
		cell_size = value
		_grid.cell_size = value

## Seconds between rebuilds.
var refresh_interval := 0.25

var _grid := EcsSpatialGrid.new()
var _cache: EcsWorld.QueryCache = null
var _timer := 999.0

## entity -> species id, so a consumer can filter candidates without a
## component lookup per neighbour.
var _species_of: Dictionary = {}


func _init() -> void:
	_grid.cell_size = cell_size


## Rebuild if the refresh window has elapsed. Safe to call every tick.
func update(world: EcsWorld, delta: float) -> void:
	_timer += delta
	if _timer < refresh_interval:
		return
	_timer = 0.0
	if _cache == null:
		_cache = world.query([&"CTransform", &"CAgent", &"CSpecies"])
	_grid.clear()
	_species_of.clear()
	for entity in world.all_entities_scratch(_cache):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		var species := world.get_component(entity, &"CSpecies") as CSpecies
		if transform == null or species == null:
			continue
		_grid.insert(entity, transform.position)
		_species_of[entity] = species.species_id


## Candidate actors near a position. Distance filtering is the caller's job —
## the grid only guarantees the neighbourhood.
func query_radius(position: Vector3, radius: float) -> PackedInt64Array:
	return _grid.query_radius(position, radius)


func species_of(entity: int) -> StringName:
	return _species_of.get(entity, &"")


func indexed_count() -> int:
	return _species_of.size()
