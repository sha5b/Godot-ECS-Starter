class_name ViewSyncSystem
extends RefCounted

## The only place where ECS data touches the scene tree.
##
## Bound EntityView nodes mirror their entity's transform and elemental
## visual state. When an entity dies or despawns, its view node is freed.
## Everything here is cosmetic: kill the view and the simulation is
## unaffected — which is exactly what the headless tests rely on.

var _bindings: Array[WeakRef] = []  ## EntityView nodes


## Link a scene node to an entity. The node must have (or extend) EntityView.
func bind(entity: int, node: Node) -> void:
	if node is EntityView:
		node.entity = entity
		_bindings.append(weakref(node))


func tick(world: EcsWorld, _delta: float, frame: int) -> void:
	var alive: Array[WeakRef] = []
	for ref in _bindings:
		var view := ref.get_ref() as EntityView
		if view == null:
			continue
		if not world.is_alive(view.entity):
			view.queue_free()
			continue
		alive.append(ref)
		var tier := world.tier_of(view.entity)
		# LOD first, and UNCONDITIONALLY. This is what tells a critter view
		# to drop its rig, so it has to reach views that the cadence gate
		# below skips — dormant entities have cadence 0, and gating this
		# behind it meant the far critters were exactly the ones never told
		# to free their bodies.
		if view is CritterView:
			(view as CritterView).apply_detail(tier)
		# Mirror at the entity's processing cadence, not unconditionally.
		# Pushing a transform into the scene tree for every bound view every
		# frame ignored tiering entirely, so dormant actors hundreds of
		# metres away still cost a global_position write (and the transform
		# propagation it triggers) 60 times a second.
		var cadence := world.TIER_CADENCE[tier]
		if cadence == 0 or (frame + (view.entity & 0xFFFFFFFF)) % cadence != 0:
			continue
		var transform := world.get_component(view.entity, &"CTransform") as CTransform
		if transform != null:
			view.global_position = transform.position
			view.rotation.y = transform.facing
		var elemental := world.get_component(view.entity, &"CElemental") as CElemental
		if elemental != null:
			view.apply_elemental(elemental)
		if view is CritterView:
			_sync_critter_view(world, view)
	_bindings = alive


## Push genome and motion data into procedural critter views. Still one-way:
## the view reads simulation state, never writes it.
func _sync_critter_view(world: EcsWorld, view: CritterView) -> void:
	var genome_comp := world.get_component(view.entity, &"CGenome") as CGenome
	if genome_comp != null:
		view.apply_genome(genome_comp.genome)
	var velocity := world.get_component(view.entity, &"CVelocity") as CVelocity
	if velocity != null:
		var cap := 3.0
		var agent := world.get_component(view.entity, &"CAgent") as CAgent
		if agent != null and agent.move_speed > 0.0:
			cap = agent.move_speed
		view.apply_motion(velocity.linear.length() / cap)


func binding_count() -> int:
	return _bindings.size()
