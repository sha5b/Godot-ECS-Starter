class_name ChemistrySystem
extends RefCounted

## The chemistry engine simulation, BotW-style.
##
## Every processed body:
##   1. gains wetness from rain, loses it to evaporation (faster while burning)
##   2. decays transient element intensities (constant sources re-apply)
##   3. rolls ignition from active FIRE (blocked by wetness gate)
##   4. burns: consumes fuel, damages health, and spreads FIRE to flammable
##      neighbors — biased downwind, blocked by their wetness
##   5. conducts ELECTRICITY: arcs chain through conductive/wet bodies
##   6. freezes when wet bodies meet ICE; frozen bodies eventually thaw
##
## All structural changes (none here) would go through commands; this system
## only writes component data and publishes events, so iteration is safe.

var rules: ChemistryRules
var grid := EcsSpatialGrid.new()

## Rebuild the chemistry grid every N frames instead of every frame.
## Agents move slowly relative to spread radii, so ~100ms staleness is
## invisible — and it removes an O(entity) dictionary rebuild per frame.
var grid_rebuild_interval := 6

## Burning sources roll spread on staggered frames (every Nth frame with
## N× delta — same expected rate, fraction of the per-frame cost). 1 = off.
var spread_interval := 4

## When true, accumulates per-section microsecond counts into
## profile_sections (read by debug tooling / perf probes).
var debug_profile := false
var profile_sections := {}

var _grid_frame := 0

## Environment context, refreshed by the bridge from SharedWorld.
var env := {
	"rain_intensity": 0.0,
	"wind_direction": Vector3.RIGHT,
	"wind_strength": 1.0,
}

var _cache: EcsWorld.QueryCache = null


func _init(rulebook: ChemistryRules = null) -> void:
	rules = rulebook if rulebook != null else ChemistryRules.new()


## Lightning strike: blast ELECTRICITY at a world position. Chains through
## conductive bodies near the strike point.
func strike(world: EcsWorld, position: Vector3, power: float = 1.0, radius: float = 2.0) -> void:
	world.publish(ChemistryDefs.CHANNEL_STRIKE, {"position": position, "power": power})
	for entity in grid.query_radius(position, radius):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if transform == null:
			continue
		if transform.position.distance_squared_to(position) > radius * radius:
			continue
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		var body := world.get_component(entity, &"CBody") as CBody
		if elemental == null or body == null:
			continue
		elemental.add_element(ChemistryDefs.Element.ELECTRICITY, power)
		elemental.shock_timer = 0.35
	_arc_chain(world, entity_power_map(world, position, power), position)


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if _cache == null:
		_cache = world.query([&"CTransform", &"CElemental", &"CBody"])
	_grid_frame += 1
	if _grid_frame == 1 or _grid_frame % grid_rebuild_interval == 0:
		_profile("grid", world, func() -> void: _rebuild_grid(world))
	_profile("sim", world, func() -> void: _tick_sim(world, delta, frame))
	_profile("spread", world, func() -> void: _tick_spread(world, delta, frame))
	_profile("auras", world, func() -> void: _apply_source_auras(world, delta))


func _tick_sim(world: EcsWorld, delta: float, frame: int) -> void:
	for entity in world.frame_entities(_cache, frame):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		var body := world.get_component(entity, &"CBody") as CBody
		var dt := world.entity_delta(entity, delta)
		_apply_environment(elemental, body, dt)
		# Elements act first, then decay — a one-shot pulse must land even
		# at coarse tier deltas.
		_process_elements(world, entity, transform, elemental, body, dt)
		_decay_elements(elemental, dt)


func _tick_spread(world: EcsWorld, delta: float, frame: int) -> void:
	var burning_this_frame: Array[int] = []
	for entity in world.frame_entities(_cache, frame):
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		if elemental == null:
			continue
		if not (elemental.burning or elemental.constant_elements.has(ChemistryDefs.Element.FIRE)):
			continue
		# Time-slice: each source spreads every Nth frame with scaled delta.
		if spread_interval > 1 and (frame + (entity & 0xFFFFFFFF)) % spread_interval != 0:
			continue
		burning_this_frame.append(entity)
	for entity in burning_this_frame:
		var transform := world.get_component(entity, &"CTransform") as CTransform
		var dt := world.entity_delta(entity, delta) * spread_interval
		_spread_fire(world, entity, transform, dt)


## Accumulate section timings when debug_profile is on. Zero-cost when off.
func _profile(section: String, _world: EcsWorld, work: Callable) -> void:
	if not debug_profile:
		work.call()
		return
	var t0 := Time.get_ticks_usec()
	work.call()
	var elapsed := float(Time.get_ticks_usec() - t0)
	profile_sections[section] = float(profile_sections.get(section, 0.0)) + elapsed
	profile_last[section] = elapsed


var profile_last := {}


# ── Per-entity passes ────────────────────────────────────────────────────────


func _apply_environment(elemental: CElemental, _body: CBody, dt: float) -> void:
	# Shock refractory counts down in the simulation (not the view layer).
	if elemental.shock_timer > 0.0:
		elemental.shock_timer = maxf(elemental.shock_timer - dt, 0.0)
	var rain: float = env["rain_intensity"]
	if rain > 0.0:
		elemental.wetness = minf(elemental.wetness + rules.rain_wet_rate * rain * dt, 1.0)
	var evap := rules.evaporation_rate
	if elemental.burning:
		evap += rules.burning_evaporation_rate
	elemental.wetness = maxf(elemental.wetness - evap * dt, 0.0)


func _decay_elements(elemental: CElemental, dt: float) -> void:
	for element in elemental.elements.keys():
		# Constant sources do not decay — they are re-applied every tick.
		if elemental.constant_elements.has(element):
			continue
		var value: float = elemental.elements[element]
		value -= rules.element_decay * value * dt
		if value <= 0.01:
			elemental.elements.erase(element)
		else:
			elemental.elements[element] = value


func _process_elements(world: EcsWorld, entity: int, transform: CTransform,
		elemental: CElemental, body: CBody, dt: float) -> void:
	# Constant sources (campfires, puddles) re-apply their element.
	for element in elemental.constant_elements:
		elemental.add_element(element, float(elemental.constant_elements[element]))

	# Thaw frozen bodies.
	if elemental.frozen:
		elemental.thaw_remaining -= dt
		if elemental.thaw_remaining <= 0.0 and not elemental.has_element(ChemistryDefs.Element.ICE):
			elemental.frozen = false
			world.publish(ChemistryDefs.CHANNEL_FROZEN, {
				"entity": entity, "position": transform.position, "frozen": false,
			})

	# Water wets and douses.
	if elemental.has_element(ChemistryDefs.Element.WATER):
		var water := reaction(body, ChemistryDefs.Element.WATER)
		if water != null:
			elemental.wetness = minf(elemental.wetness + water.wet_gain * dt, 1.0)
			if water.douses and elemental.burning and elemental.get_element(ChemistryDefs.Element.WATER) > 0.3:
				elemental.burning = false
				world.publish(ChemistryDefs.CHANNEL_EXTINGUISHED, {
					"entity": entity, "position": transform.position, "cause": &"water",
				})

	# Rain extinguishes soaked burning bodies.
	var rain: float = env["rain_intensity"]
	if elemental.burning and rain > 0.5 and elemental.wetness >= rules.ignition_wetness_gate:
		elemental.burning = false
		world.publish(ChemistryDefs.CHANNEL_EXTINGUISHED, {
			"entity": entity, "position": transform.position, "cause": &"rain",
		})

	# Ignition from active fire.
	if not elemental.burning and not elemental.charred and not elemental.frozen \
			and elemental.has_element(ChemistryDefs.Element.FIRE) \
			and body.fuel > 0.0 \
			and elemental.wetness < rules.ignition_wetness_gate:
		var fire := reaction(body, ChemistryDefs.Element.FIRE)
		if fire != null and fire.ignite_chance > 0.0:
			if randf() < fire.ignite_chance * dt:
				elemental.burning = true
				world.publish(ChemistryDefs.CHANNEL_IGNITED, {
					"entity": entity, "position": transform.position,
				})

	# Burning consumes fuel and damages health.
	if elemental.burning:
		var fire := reaction(body, ChemistryDefs.Element.FIRE)
		var virulence := fire.fire_virulence if fire else 1.0
		body.fuel = maxf(body.fuel - rules.fuel_burn_rate * dt, 0.0)
		var damage := fire.burn_damage if fire else 0.0
		if damage > 0.0:
			var health := world.get_component(entity, &"CHealth") as CHealth
			if health != null:
				health.apply_damage(damage * dt)
		if body.fuel <= 0.0:
			elemental.burning = false
			elemental.charred = true
			world.publish(ChemistryDefs.CHANNEL_BURNED_OUT, {
				"entity": entity, "position": transform.position,
				"virulence": virulence,
			})

	# Electricity arcs through conductive bodies. The carrier discharges
	# into the arc, and freshly shocked bodies get a refractory window
	# (shock_timer) during which they cannot re-arc — together that turns
	# a strike into an expanding ring that dies out instead of an
	# exponential storm of overlapping chains.
	if elemental.has_element(ChemistryDefs.Element.ELECTRICITY):
		var power := elemental.get_element(ChemistryDefs.Element.ELECTRICITY)
		if power >= rules.arc_retrigger_power and elemental.shock_timer <= 0.0:
			elemental.clear_element(ChemistryDefs.Element.ELECTRICITY)
			_arc_chain(world, {entity: power}, transform.position)

	# Ice freezes wet bodies.
	if not elemental.frozen and elemental.has_element(ChemistryDefs.Element.ICE):
		var ice := reaction(body, ChemistryDefs.Element.ICE)
		if ice != null and ice.can_freeze and elemental.wetness > 0.3:
			elemental.frozen = true
			elemental.thaw_remaining = rules.thaw_time
			world.publish(ChemistryDefs.CHANNEL_FROZEN, {
				"entity": entity, "position": transform.position, "frozen": true,
			})


func _spread_fire(world: EcsWorld, source_entity: int, source: CTransform, dt: float) -> void:
	var source_body := world.get_component(source_entity, &"CBody") as CBody
	var fire := reaction(source_body, ChemistryDefs.Element.FIRE)
	# Sources with no fire reaction of their own (stone campfires) radiate
	# with default virulence.
	var virulence := fire.fire_virulence if fire != null and fire.fire_virulence > 0.0 else 1.0

	var wind: Vector3 = env["wind_direction"]
	var wind_norm: float = clampf(env["wind_strength"] / 5.0, 0.0, 2.0)
	var radius := rules.fire_spread_radius * (1.0 + 0.35 * wind_norm)

	for neighbor in grid.query_radius(source.position, radius):
		if neighbor == source_entity:
			continue
		var n_transform := world.get_component(neighbor, &"CTransform") as CTransform
		var n_elemental := world.get_component(neighbor, &"CElemental") as CElemental
		var n_body := world.get_component(neighbor, &"CBody") as CBody
		if n_transform == null or n_elemental == null or n_body == null:
			continue
		var offset := n_transform.position - source.position
		if offset.length_squared() > radius * radius:
			continue
		if n_elemental.burning or n_elemental.charred or n_body.fuel <= 0.0:
			continue

		var n_fire := reaction(n_body, ChemistryDefs.Element.FIRE)
		if n_fire == null or n_fire.ignite_chance <= 0.0:
			continue
		if n_elemental.wetness >= rules.ignition_wetness_gate:
			continue

		# Downwind neighbors catch more easily.
		var wind_factor := 1.0
		if wind_norm > 0.01 and offset.length() > 0.01:
			var downwind := offset.normalized().dot(wind.normalized())
			wind_factor = 1.0 + maxf(0.0, downwind) * rules.wind_spread_boost * wind_norm

		var chance: float = rules.fire_spread_chance * n_fire.ignite_chance \
			* virulence * wind_factor * dt
		if randf() < chance:
			n_elemental.add_element(ChemistryDefs.Element.FIRE, 0.8)


# ── Internals ────────────────────────────────────────────────────────────────


## Constant WATER/ICE sources (puddles, ice shards) push their element onto
## nearby bodies so auras emerge naturally. Sources are cached — there are
## a handful of them, and scanning every entity for constants each tick
## showed up in profiling.
func _apply_source_auras(world: EcsWorld, delta: float) -> void:
	_aura_timer += delta
	if _aura_timer >= _aura_refresh:
		_aura_timer = 0.0
		_aura_sources.clear()
		for entity in world.all_entities_scratch(_cache):
			var elemental := world.get_component(entity, &"CElemental") as CElemental
			if elemental == null or elemental.constant_elements.is_empty():
				continue
			for element in [ChemistryDefs.Element.WATER, ChemistryDefs.Element.ICE]:
				if elemental.constant_elements.has(element):
					_aura_sources.append(entity)
					break

	if _aura_sources.is_empty():
		return
	var radius := rules.source_aura_radius
	for entity in _aura_sources:
		var transform := world.get_component(entity, &"CTransform") as CTransform
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		if transform == null or elemental == null:
			continue
		for neighbor in grid.query_radius(transform.position, radius):
			if neighbor == entity:
				continue
			var n_transform := world.get_component(neighbor, &"CTransform") as CTransform
			var n_elemental := world.get_component(neighbor, &"CElemental") as CElemental
			if n_transform == null or n_elemental == null:
				continue
			if n_transform.position.distance_to(transform.position) > radius:
				continue
			for element in [ChemistryDefs.Element.WATER, ChemistryDefs.Element.ICE]:
				if not elemental.constant_elements.has(element):
					continue
				if randf() < rules.aura_chance * delta:
					n_elemental.add_element(element, 0.4)


var _aura_sources: Array[int] = []
var _aura_refresh := 0.5
var _aura_timer := 999.0


## Chain electricity: BFS from seeded {entity: power} sources through
## conductive bodies within arc range, losing power per hop.
func _arc_chain(world: EcsWorld, seeds: Dictionary, _origin: Vector3) -> void:
	var visited := seeds.keys()
	var frontier := seeds.duplicate(true)
	while not frontier.is_empty() and visited.size() < rules.arc_chain_max + seeds.size():
		var next := {}
		for entity in frontier:
			var power: float = frontier[entity]
			var transform := world.get_component(entity, &"CTransform") as CTransform
			if transform == null:
				continue
			for neighbor in grid.query_radius(transform.position, rules.arc_range):
				if neighbor in visited:
					continue
				var n_transform := world.get_component(neighbor, &"CTransform") as CTransform
				var n_body := world.get_component(neighbor, &"CBody") as CBody
				var n_elemental := world.get_component(neighbor, &"CElemental") as CElemental
				if n_transform == null or n_body == null or n_elemental == null:
					continue
				if n_transform.position.distance_to(transform.position) > rules.arc_range:
					continue
				var conductivity := rules.conductivity_of(n_body.material, n_elemental.wetness)
				if conductivity < 0.15:
					continue
				visited.append(neighbor)
				var shock := reaction(n_body, ChemistryDefs.Element.ELECTRICITY)
				var damage := (shock.shock_damage if shock else 2.0) * conductivity * power
				var health := world.get_component(neighbor, &"CHealth") as CHealth
				if health != null:
					health.apply_damage(damage)
				n_elemental.shock_timer = 0.35
				n_elemental.add_element(ChemistryDefs.Element.ELECTRICITY, power * (1.0 - rules.arc_falloff))
				world.publish(ChemistryDefs.CHANNEL_SHOCKED, {
					"entity": neighbor,
					"position": n_transform.position,
					"power": power,
				})
				if conductivity >= 0.5:
					next[neighbor] = power * (1.0 - rules.arc_falloff)
		frontier = next


func entity_power_map(_world: EcsWorld, position: Vector3, power: float) -> Dictionary:
	var seeds := {}
	for entity in grid.query_radius(position, 2.0):
		var transform := _world.get_component(entity, &"CTransform") as CTransform
		if transform != null and transform.position.distance_to(position) < 2.0:
			seeds[entity] = power
	return seeds


func reaction(body: CBody, element: int) -> ElementReaction:
	return rules.reaction_for(element, body.material)


func _rebuild_grid(world: EcsWorld) -> void:
	grid.clear()
	if _cache == null:
		return
	for entity in world.all_entities_scratch(_cache):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		if transform != null:
			grid.insert(entity, transform.position)
