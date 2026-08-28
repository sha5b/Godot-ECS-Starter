class_name FlightSystem
extends RefCounted

## Take-off, cruising and landing for winged animals.
##
## Fliers used to be held at a fixed height above the ground for their whole
## lives — spawned airborne, never landing, never climbing, sliding along a
## contour offset. Nothing about that reads as flight: what makes a bird look
## like a bird is that it is sometimes on the ground, leaves it when startled,
## climbs at a rate its wings can manage, and comes back down when it is tired.
##
## This owns only the vertical half of the behaviour. The utility AI still
## decides where a flier is going; the grounding pass still applies the height.
## What lives here is the decision to be up or down, and the climb between —
## which is why a startled bird's escape looks like a bird's escape and not a
## teleport to cruising altitude.
##
## Every number comes from the genome (see CritterGenome.derived_climb_rate,
## derived_cruise_height, derived_flight_endurance), so a lineage that evolves
## broader wings genuinely climbs faster, flies higher and stays up longer.

const CHANNEL_TOOK_OFF := &"flight.took_off"
const CHANNEL_LANDED := &"flight.landed"

## Actions that put a flier in the air immediately, whatever it was doing.
## A bird that finishes its meal before reacting to a wolf is a dead bird.
const STARTLES := {
	&"panic": true,
	&"evade": true,
	&"flee": true,
}

## Actions a flier will not interrupt to take off on a whim. It still startles
## out of them — that is the list above — but it will not leave a meal to go
## for a routine flight.
const GROUNDED_BUSINESS := {
	&"seek_food": true,
	&"rest": true,
}

## Energy below which a flier comes down to rest, 0..1.
var land_energy := 0.35

## Seconds a flier will sit perched before it takes off again, at the low and
## high end. Randomized per animal so a flock does not launch in unison.
var perch_min := 4.0
var perch_max := 14.0

var _cache: EcsWorld.QueryCache = null
var _rng := RandomNumberGenerator.new()


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if _cache == null:
		_cache = world.query([&"CTransform", &"CLocomotion", &"CAgent"])

	for entity in world.frame_entities(_cache, frame):
		var locomotion := world.get_component(entity, &"CLocomotion") as CLocomotion
		if locomotion == null or locomotion.medium != CLocomotion.Medium.AIR:
			continue
		var agent := world.get_component(entity, &"CAgent") as CAgent
		var dt := world.entity_delta(entity, delta)
		locomotion.state_time += dt
		_decide(world, entity, locomotion, agent)
		_climb(locomotion, dt)


## Up or down, and why.
func _decide(world: EcsWorld, entity: int, locomotion: CLocomotion,
		agent: CAgent) -> void:
	var startled := agent != null and STARTLES.has(agent.current_action)
	if startled and not locomotion.airborne:
		_set_airborne(world, entity, locomotion, true)
		return
	if not locomotion.airborne:
		# Perched. Take off again once it has sat long enough, unless it is
		# busy with something that happens on the ground.
		if agent != null and GROUNDED_BUSINESS.has(agent.current_action):
			return
		if agent != null and agent.energy < land_energy:
			return
		var perch_for := _perch_time(entity)
		if locomotion.state_time >= perch_for:
			_set_airborne(world, entity, locomotion, true)
		return

	# Airborne. Comes down when it runs out of endurance or energy, and stays
	# up as long as something is chasing it.
	if startled:
		return
	var tired := locomotion.state_time >= locomotion.flight_endurance
	var spent := agent != null and agent.energy < land_energy
	if tired or spent:
		_set_airborne(world, entity, locomotion, false)


## How long this animal perches before taking off, stable per entity.
##
## Derived from the entity id rather than rolled each tick: a value re-rolled
## every frame would average out and every bird in the world would launch on
## the same cadence.
func _perch_time(entity: int) -> float:
	_rng.seed = entity ^ 0x9e3779b9
	return _rng.randf_range(perch_min, perch_max)


func _set_airborne(world: EcsWorld, entity: int, locomotion: CLocomotion,
		up: bool) -> void:
	if locomotion.airborne == up:
		return
	locomotion.airborne = up
	locomotion.state_time = 0.0
	world.publish(CHANNEL_TOOK_OFF if up else CHANNEL_LANDED, {
		"entity": entity,
		"cruise_height": locomotion.cruise_height,
	})


## Move toward the target height at the body's own climb rate.
##
## Rate-limited rather than snapped, because the climb IS the take-off. A
## flier that reaches cruising height in one frame has not taken off, it has
## changed altitude.
func _climb(locomotion: CLocomotion, dt: float) -> void:
	var target := locomotion.cruise_height if locomotion.airborne else 0.0
	var step := locomotion.climb_rate * dt
	# Coming down is faster than going up: gravity helps.
	if not locomotion.airborne:
		step *= 1.6
	locomotion.hover_height = move_toward(locomotion.hover_height, target, step)
