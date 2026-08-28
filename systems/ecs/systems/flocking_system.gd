class_name FlockingSystem
extends RefCounted

## Herds, flocks, shoals and packs — Reynolds' three rules over the shared
## actor index.
##
## Runs AFTER the AI, and BLENDS rather than replaces. The AI has already
## decided where this animal wants to go; flocking is the correction its
## neighbours apply to that. Running it the other way round, or letting it
## overwrite velocity outright, produces a herd that cannot flee — the boids
## rules would happily steer a deer back into the middle of the group it is
## trying to run away from.
##
## `CGroup.influence` is the ceiling on that correction, and panic and evade
## lower it further, so formation breaks exactly when it should.

## Actions during which an animal ignores its neighbours entirely.
const BREAKS_FORMATION := {
	&"panic": true,
	&"evade": true,
	&"flee": true,
}

## Shared neighbour index, owned by EcsSystem.
var index: EcsActorIndex

## Cap on neighbours considered per animal. A dense herd is quadratic
## otherwise, and the twentieth neighbour changes nothing the first ten did
## not already say.
var max_neighbours := 10

var _cache: EcsWorld.QueryCache = null


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if index == null:
		return
	if _cache == null:
		_cache = world.query([&"CTransform", &"CVelocity", &"CGroup", &"CSpecies"])

	for entity in world.frame_entities(_cache, frame):
		_steer(world, entity, world.entity_delta(entity, delta))


func _steer(world: EcsWorld, entity: int, dt: float) -> void:
	var group := world.get_component(entity, &"CGroup") as CGroup
	var transform := world.get_component(entity, &"CTransform") as CTransform
	var velocity := world.get_component(entity, &"CVelocity") as CVelocity
	var species := world.get_component(entity, &"CSpecies") as CSpecies
	if group == null or transform == null or velocity == null or species == null:
		return

	var agent := world.get_component(entity, &"CAgent") as CAgent
	if agent != null and BREAKS_FORMATION.has(agent.current_action):
		# Break formation OUTRIGHT, not at reduced weight.
		#
		# Merely scaling the influence down is not enough: the blend below
		# converges on the steering target, so even a small weight applied
		# every tick eventually turns the animal around. Measured — an animal
		# sprinting away from its herd at 4 m/s was down to 1 m/s and still
		# turning after two seconds of "reduced" flocking. A deer that cannot
		# leave its herd cannot escape a wolf.
		group.neighbours = 0
		return
	var influence := group.influence

	var separation := Vector3.ZERO
	var heading := Vector3.ZERO
	var centre := Vector3.ZERO
	var found := 0

	for candidate in index.query_radius(transform.position, group.neighbour_radius):
		if candidate == entity or found >= max_neighbours:
			continue
		# Same species only. A mixed grazing plain is several herds sharing
		# ground, not one flock of everything.
		if index.species_of(candidate) != species.species_id:
			continue
		var other := world.get_component(candidate, &"CTransform") as CTransform
		if other == null:
			continue
		var offset := other.position - transform.position
		offset.y = 0.0
		var dist := offset.length()
		if dist > group.neighbour_radius or dist < 0.0001:
			continue

		found += 1
		centre += other.position
		var other_velocity := world.get_component(candidate, &"CVelocity") as CVelocity
		if other_velocity != null:
			heading += other_velocity.linear
		if dist < group.personal_space:
			# Push apart, harder the closer they are.
			separation -= offset.normalized() * (1.0 - dist / group.personal_space)

	group.neighbours = found
	if found == 0:
		group.centre = transform.position
		return

	centre /= float(found)
	group.centre = centre

	var to_centre := centre - transform.position
	to_centre.y = 0.0
	heading /= float(found)
	heading.y = 0.0

	var steer := separation * group.separation
	steer += heading.normalized() * group.alignment if heading.length() > 0.01 else Vector3.ZERO
	steer += to_centre.normalized() * group.cohesion if to_centre.length() > 0.01 else Vector3.ZERO
	if steer.length() < 0.0001:
		return

	# Blend at the animal's own speed, so flocking never makes it faster than
	# its body can move.
	var speed := velocity.linear.length()
	if speed < 0.01:
		speed = agent.move_speed * 0.5 if agent != null else 1.0
	var wanted := steer.normalized() * speed
	velocity.linear = velocity.linear.lerp(wanted, clampf(influence * dt * 4.0, 0.0, 1.0))
