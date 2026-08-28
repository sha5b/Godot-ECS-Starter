class_name PredationSystem
extends RefCounted

## Who eats whom.
##
## Runs after the AI, and does two jobs in that order:
##
##   1. RESOLVE the bites the AI committed to this frame. The AI decides to
##      hunt and closes the distance; this decides whether the bite lands,
##      how much it hurts, and what the hunter gets out of it.
##   2. SENSE for next frame — write nearest prey and nearest predator into
##      every agent's blackboard, so `hunt` and `evade` have something to
##      score against.
##
## The split is the same one the rest of the runtime uses: the AI writes
## INTENT (a target, a velocity), a system resolves it. Putting the damage
## rules in the brain would make every new predator behaviour a rules change.
##
## Predator/prey relationships come from SpeciesRecord.hunts(), which keys off
## the root FaunaEntry rather than the exact species id — so a deer lineage
## that has split three ways is still hunted by everything that hunts deer.

const CHANNEL_KILLED := &"predation.killed"
const CHANNEL_ATTACKED := &"predation.attacked"

## How far a hunter senses prey.
var hunt_range := 30.0

## How far prey senses a hunter. Deliberately longer than hunt_range: being
## seen first is what gives prey any chance, and a herd that only reacts once
## the wolf is already in bite range never gets to flee.
var flee_range := 34.0

## Reach of a bite, in world units.
var bite_range := 1.6

## Seconds between bites from one hunter.
var bite_cooldown := 1.2

## Damage per bite, before the attacker's body-mass scaling.
var bite_damage := 3.5

## Fraction of hunger a successful kill removes.
var kill_nutrition := 0.85

## The world's species. Without it this system does nothing — predation is
## defined entirely by species relationships.
var registry: SpeciesRegistry

## Shared neighbour index, owned by EcsSystem.
var index: EcsActorIndex

var _cache: EcsWorld.QueryCache = null

## species id -> does this species hunt anything, or get hunted by anything?
##
## An animal in neither position has no predation work to do, and skipping it
## outright is the difference between scanning every neighbour of every animal
## in the world and scanning only the ones that matter. Rebuilt whenever the
## registry grows, which speciation does.
var _participates: Dictionary = {}
var _known_species := -1


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if registry == null or index == null:
		return
	if _cache == null:
		_cache = world.query([&"CTransform", &"CAgent", &"CSpecies"])
	_refresh_participation()

	for entity in world.frame_entities(_cache, frame):
		var species := world.get_component(entity, &"CSpecies") as CSpecies
		if species == null or not _participates.get(species.species_id, false):
			continue
		var dt := world.entity_delta(entity, delta)
		_resolve_bite(world, entity, dt)
		_sense(world, entity)


## Work out which species are involved in predation at all.
func _refresh_participation() -> void:
	if registry.count() == _known_species:
		return
	_known_species = registry.count()
	_participates.clear()
	var ids := registry.ids()
	for id in ids:
		var record := registry.get_record(id)
		if record == null:
			continue
		var involved := record.is_carnivore() and not record.prey.is_empty()
		if not involved:
			for other_id in ids:
				var other := registry.get_record(other_id)
				if other != null and other.hunts(record):
					involved = true
					break
		_participates[id] = involved


# ── Attack resolution ────────────────────────────────────────────────────────


## Land the bite the AI committed to, if the hunter is actually in reach.
##
## The AI sets `hunt_target` when it commits to hunting; reach and cooldown
## are checked here so a hunter cannot chew through a herd by running past it.
func _resolve_bite(world: EcsWorld, entity: int, dt: float) -> void:
	var agent := world.get_component(entity, &"CAgent") as CAgent
	if agent == null:
		return
	var target := int(agent.blackboard.get("hunt_target", 0))
	if target == 0 or not world.is_alive(target):
		agent.blackboard["hunt_target"] = 0
		return
	if agent.is_on_cooldown(&"bite"):
		return

	var here := world.get_component(entity, &"CTransform") as CTransform
	var there := world.get_component(target, &"CTransform") as CTransform
	if here == null or there == null:
		return
	if here.position.distance_to(there.position) > bite_range:
		return

	var health := world.get_component(target, &"CHealth") as CHealth
	if health == null:
		return

	# A bigger body bites harder. Morphology already drives speed and health;
	# this is what puts it on the other side of the exchange too, so a lineage
	# that evolves bulk actually becomes more dangerous.
	var damage := bite_damage
	var genome := world.get_component(entity, &"CGenome") as CGenome
	if genome != null and genome.genome != null:
		damage *= clampf(0.6 + genome.genome.body_mass() * 0.45, 0.5, 2.5)

	health.apply_damage(damage)
	agent.cooldowns[&"bite"] = bite_cooldown
	world.publish(CHANNEL_ATTACKED, {
		"hunter": entity,
		"prey": target,
		"damage": damage,
		"position": there.position,
	})

	if not health.dead:
		return

	# The kill feeds the hunter. VitalitySystem despawns the body.
	agent.hunger = maxf(agent.hunger - kill_nutrition, 0.0)
	agent.blackboard["hunt_target"] = 0
	world.publish(CHANNEL_KILLED, {
		"hunter": entity,
		"prey": target,
		"hunter_species": _species_id(world, entity),
		"prey_species": _species_id(world, target),
		"position": there.position,
	})


# ── Sensing ──────────────────────────────────────────────────────────────────


## Write nearest prey and nearest predator into the agent's blackboard.
func _sense(world: EcsWorld, entity: int) -> void:
	var agent := world.get_component(entity, &"CAgent") as CAgent
	var transform := world.get_component(entity, &"CTransform") as CTransform
	var species := world.get_component(entity, &"CSpecies") as CSpecies
	if agent == null or transform == null or species == null:
		return
	var record := registry.get_record(species.species_id)
	if record == null:
		return

	var best_prey := 0
	var best_prey_dist := hunt_range
	var best_hunter_dist := flee_range
	var hunter_pos := Vector3.ZERO

	var radius := maxf(hunt_range, flee_range)
	for candidate in index.query_radius(transform.position, radius):
		if candidate == entity:
			continue
		var other_record := registry.get_record(index.species_of(candidate))
		if other_record == null:
			continue
		var hunts_them := record.hunts(other_record)
		var hunted_by_them := other_record.hunts(record)
		if not hunts_them and not hunted_by_them:
			continue
		var other := world.get_component(candidate, &"CTransform") as CTransform
		if other == null:
			continue
		var dist := transform.position.distance_to(other.position)
		if hunts_them and dist < best_prey_dist:
			best_prey_dist = dist
			best_prey = candidate
		if hunted_by_them and dist < best_hunter_dist:
			best_hunter_dist = dist
			hunter_pos = other.position

	agent.blackboard["prey_entity"] = best_prey
	agent.blackboard[Consideration.SensorInput.PREY_PROXIMITY] = 0.0 if best_prey == 0 \
		else 1.0 - best_prey_dist / hunt_range
	agent.blackboard["predator_pos"] = hunter_pos
	agent.blackboard[Consideration.SensorInput.PREDATOR_PROXIMITY] = \
		0.0 if best_hunter_dist >= flee_range else 1.0 - best_hunter_dist / flee_range


func _species_id(world: EcsWorld, entity: int) -> StringName:
	var species := world.get_component(entity, &"CSpecies") as CSpecies
	return species.species_id if species != null else &""
