class_name EcsWorld
extends RefCounted

## Data-oriented entity world — the runtime behind the BotW-style ECS.
##
## Design mirrors the actor model of modern Nintendo engines:
## - Entities are generational int handles (stale handles fail safely)
## - Components are plain data objects in sparse-set stores
## - Queries are cached and partitioned by processing tier, so systems
##   iterate exactly the entities they owe work for this frame
## - Structural changes go through a command buffer flushed at sync points,
##   so iteration never mutates the structures being iterated
## - Communication happens through named event channels
##
## The world owns no engine objects. It runs headless and is fully testable.

## Processing tiers, BotW "profile" style.
## Tier 0: near focus, every frame. Tier 1: every 4th frame.
## Tier 2: every 12th frame. Tier 3: dormant (out of range).
## (Instance var because packed arrays cannot be const expressions.)
var TIER_CADENCE := PackedInt32Array([1, 4, 12, 0])
const TIER_COUNT := 4

## Where tier assignment measures distance from (usually the camera).
var focus_position := Vector3.ZERO


class Store:
	## Sparse-set component storage for one component type.
	var sparse := {}  ## entity index -> dense slot
	var components: Array[RefCounted] = []
	var entities := PackedInt64Array()  ## dense entity ids


class QueryCache:
	## Live entity list for one required-component signature, split by tier.
	var required: Array[StringName] = []
	var key := ""
	var tiers: Array[PackedInt64Array] = [
		PackedInt64Array(), PackedInt64Array(),
		PackedInt64Array(), PackedInt64Array(),
	]

	func count() -> int:
		var total := 0
		for t in tiers:
			total += t.size()
		return total

	func _has(entity: int) -> bool:
		for t in tiers:
			if t.has(entity):
				return true
		return false


# --- Entity storage ---
var _generations := PackedInt32Array()
var _free := PackedByteArray()  ## 1 = index is on the free list
var _free_count := 0
var _entity_types: Array[Dictionary] = []  ## index -> {component_id: true}
var _tier := PackedByteArray()
var _alive_count := 0

# --- Component stores ---
var _stores: Dictionary = {}  ## StringName -> Store

# --- Query caches ---
var _caches: Dictionary = {}  ## key -> QueryCache

# --- Events ---
var _event_channels: Dictionary = {}  ## StringName -> Array[Dictionary]

# --- Commands ---
var commands: EcsCommands

# --- Stats (read by HUD / tests) ---
var stats := {
	"entities": 0,
	"tier_counts": PackedInt32Array([0, 0, 0, 0]),
	"events_published": 0,
}


func _init() -> void:
	commands = EcsCommands.new(self)


# ── Entities ─────────────────────────────────────────────────────────────────


## Create an entity now and return its handle. Prefer commands.spawn_with()
## from inside system iteration.
func spawn() -> int:
	var index := _acquire_index()
	return index | (_generations[index] << 32)


## Despawn immediately. Safe outside iteration; use commands.despawn() inside.
func despawn(entity: int) -> void:
	var index := entity & 0xFFFFFFFF
	if not is_alive(entity):
		return
	for component_id in _entity_types[index].keys():
		_remove_from_store(_store(component_id), index)
	_entity_types[index] = {}
	for cache in _caches.values():
		_remove_from_cache(cache, entity)
	_free[index] = 1
	_free_count += 1
	_generations[index] += 1
	_alive_count -= 1


func is_alive(entity: int) -> bool:
	var index := entity & 0xFFFFFFFF
	return index >= 0 and index < _generations.size() \
		and _generations[index] == entity >> 32 \
		and _free[index] == 0


# ── Components ───────────────────────────────────────────────────────────────


func add_component(entity: int, component: RefCounted) -> void:
	if not is_alive(entity) or component == null:
		return
	var index := entity & 0xFFFFFFFF
	var component_id: StringName = component.get("COMPONENT_ID")
	var store := _store(component_id)
	if _entity_types[index].has(component_id):
		store.components[store.sparse[index]] = component
		return
	_entity_types[index][component_id] = true
	store.sparse[index] = store.components.size()
	store.components.append(component)
	store.entities.append(entity)
	_on_structure_changed(index, entity, true, component_id)


func remove_component(entity: int, component_id: StringName) -> void:
	if not is_alive(entity):
		return
	var index := entity & 0xFFFFFFFF
	if not _entity_types[index].has(component_id):
		return
	_remove_from_store(_store(component_id), index)
	_entity_types[index].erase(component_id)
	_on_structure_changed(index, entity, false, component_id)


## Get a component, or null. Always check the return for stale handles.
func get_component(entity: int, component_id: StringName) -> RefCounted:
	var index := entity & 0xFFFFFFFF
	if not is_alive(entity):
		return null
	var store: Store = _stores.get(component_id)
	if store == null or not store.sparse.has(index):
		return null
	return store.components[store.sparse[index]]


func has_component(entity: int, component_id: StringName) -> bool:
	var index := entity & 0xFFFFFFFF
	return is_alive(entity) and _entity_types[index].has(component_id)


# ── Queries ──────────────────────────────────────────────────────────────────


## Get (or create) the live query cache for a component signature.
## The returned cache updates automatically as entities change.
func query(required: Array[StringName]) -> QueryCache:
	var sorted := required.duplicate()
	sorted.sort()
	var key := ",".join(sorted)
	if _caches.has(key):
		return _caches[key]
	var cache := QueryCache.new()
	cache.required = sorted
	cache.key = key
	_caches[key] = cache
	_rebuild_cache(cache)
	return cache


## Entities from a cache that are owed processing this frame, across tiers.
## Per-entity staggering spreads coarse tiers across frames, the way BotW
## time-slices distant actors. Dormant (tier 3) entities never appear.
func frame_entities(cache: QueryCache, frame: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	for tier in TIER_COUNT - 1:
		var cadence := TIER_CADENCE[tier]
		if cadence == 0:
			continue
		for i in cache.tiers[tier].size():
			var entity := cache.tiers[tier][i]
			var index := entity & 0xFFFFFFFF
			if (frame + index) % cadence == 0:
				out.append(entity)
	return out


## Simulation delta for an entity this frame. Coarser tiers receive scaled
## delta so behavior stays frame-rate independent (BotW does the same).
func entity_delta(entity: int, delta: float) -> float:
	var index := entity & 0xFFFFFFFF
	var cadence := TIER_CADENCE[_tier[index]]
	return delta if cadence <= 1 else delta * cadence


## All entities in a cache, including dormant tier 3. Used by tier
## reassignment and spatial grid rebuilds — not for per-frame iteration.
func all_entities(cache: QueryCache) -> PackedInt64Array:
	var out := PackedInt64Array()
	for t in TIER_COUNT:
		out.append_array(cache.tiers[t])
	return out


## All entities (incl. dormant) in a REUSED buffer — hot-path variant of
## all_entities(). The result is only valid until the next call, so use it
## immediately and never hold it across another all_entities_scratch().
func all_entities_scratch(cache: QueryCache) -> PackedInt64Array:
	_scratch_all.clear()
	for t in TIER_COUNT:
		_scratch_all.append_array(cache.tiers[t])
	return _scratch_all


var _scratch_all := PackedInt64Array()


func tier_of(entity: int) -> int:
	return _tier[entity & 0xFFFFFFFF]


# ── Tiers ────────────────────────────────────────────────────────────────────


## Assign (or reassign) an entity's processing tier.
func set_tier(entity: int, tier: int) -> void:
	var index := entity & 0xFFFFFFFF
	if not is_alive(entity) or tier < 0 or tier >= TIER_COUNT:
		return
	var old := _tier[index]
	if old == tier:
		return
	_tier[index] = tier
	for cache in _caches.values():
		if cache.tiers[old].has(entity):
			_remove_from_cache(cache, entity)
			cache.tiers[tier].append(entity)


## Tier distance assignment from focus position, BotW-style A/B/C profiles.
## `positions_by_entity` maps entity -> squared distance to focus.
func assign_tiers_by_distance(positions_by_entity: Dictionary, near: float, mid: float, far: float) -> void:
	for entity in positions_by_entity:
		var dist_sq: float = positions_by_entity[entity]
		var tier := 3
		if dist_sq < near * near:
			tier = 0
		elif dist_sq < mid * mid:
			tier = 1
		elif dist_sq < far * far:
			tier = 2
		set_tier(entity, tier)


# ── Events ───────────────────────────────────────────────────────────────────


func publish(channel: StringName, payload: Dictionary) -> void:
	if not _event_channels.has(channel):
		var fresh: Array[Dictionary] = []
		_event_channels[channel] = fresh
	_event_channels[channel].append(payload)
	stats["events_published"] += 1


## Take all pending events on a channel (empties it).
func drain(channel: StringName) -> Array[Dictionary]:
	if not _event_channels.has(channel):
		return []
	var events: Array[Dictionary] = _event_channels[channel]
	var fresh: Array[Dictionary] = []
	_event_channels[channel] = fresh
	return events


## Channels with pending events — bridges forward these to SystemBus.
func pending_channels() -> Array[StringName]:
	var out: Array[StringName] = []
	for channel in _event_channels:
		if not _event_channels[channel].is_empty():
			out.append(channel)
	return out


# ── Commands ─────────────────────────────────────────────────────────────────


## Apply all buffered structural commands. Called at sync points by the
## scheduler, after each phase.
func flush_commands() -> void:
	commands.apply()


# ── Internals ────────────────────────────────────────────────────────────────


func _acquire_index() -> int:
	var index: int
	if _free_count == 0:
		index = _generations.size()
		_generations.append(0)
		_entity_types.append({})
		_tier.append(0)
		_free.append(0)
	else:
		index = _find_free_index()
		_entity_types[index] = {}
		_free[index] = 0
		_free_count -= 1
	_alive_count += 1
	return index


func _find_free_index() -> int:
	for i in _free.size():
		if _free[i] == 1:
			return i
	return -1  # Unreachable when _free_count > 0.


func _store(component_id: StringName) -> Store:
	if not _stores.has(component_id):
		_stores[component_id] = Store.new()
	return _stores[component_id]


## Swap-remove an entity's dense entry from a store and drop its sparse slot.
func _remove_from_store(store: Store, index: int) -> void:
	if not store.sparse.has(index):
		return
	var slot: int = store.sparse[index]
	var last := store.components.size() - 1
	if slot != last:
		store.components[slot] = store.components[last]
		store.entities[slot] = store.entities[last]
		store.sparse[store.entities[slot] & 0xFFFFFFFF] = slot
	store.components.resize(last)
	store.entities.resize(last)
	store.sparse.erase(index)


func _on_structure_changed(index: int, entity: int, added: bool, component_id: StringName) -> void:
	for cache in _caches.values():
		if added:
			if not cache._has(entity) and _entity_types[index].has_all(cache.required):
				cache.tiers[_tier[index]].append(entity)
		else:
			if cache.required.has(component_id) and cache._has(entity) \
					and not _entity_types[index].has_all(cache.required):
				_remove_from_cache(cache, entity)


func _remove_from_cache(cache: QueryCache, entity: int) -> void:
	for t in TIER_COUNT:
		var slot := cache.tiers[t].find(entity)
		if slot >= 0:
			cache.tiers[t].remove_at(slot)
			return


func _rebuild_cache(cache: QueryCache) -> void:
	var candidate := PackedInt64Array()
	var first := true
	for component_id in cache.required:
		var store: Store = _stores.get(component_id)
		if store == null:
			return
		if first:
			candidate = store.entities.duplicate()
			first = false
		else:
			var filtered := PackedInt64Array()
			for e in candidate:
				if store.sparse.has(e & 0xFFFFFFFF):
					filtered.append(e)
			candidate = filtered
	for e in candidate:
		var index := e & 0xFFFFFFFF
		if _entity_types[index].has_all(cache.required):
			cache.tiers[_tier[index]].append(e)


func refresh_stats() -> void:
	var counts := PackedInt32Array([0, 0, 0, 0])
	for index in _generations.size():
		if _free[index] == 0:
			counts[_tier[index]] += 1
	stats["entities"] = _alive_count
	stats["tier_counts"] = counts
