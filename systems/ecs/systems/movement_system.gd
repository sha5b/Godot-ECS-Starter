class_name MovementSystem
extends RefCounted

## Integrates CVelocity into CTransform and keeps actors inside the play
## area. Pure kinematics — chemistry and AI only write intent.


## Actors are clamped inside this radius around the origin (0 = no clamp).
var bounds_radius := 0.0

var _cache: EcsWorld.QueryCache = null


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if _cache == null:
		_cache = world.query([&"CTransform", &"CVelocity"])
	for entity in world.frame_entities(_cache, frame):
		var transform := world.get_component(entity, &"CTransform") as CTransform
		var velocity := world.get_component(entity, &"CVelocity") as CVelocity
		var dt := world.entity_delta(entity, delta)
		transform.position += velocity.linear * dt
		if bounds_radius > 0.0:
			var flat := Vector2(transform.position.x, transform.position.z)
			if flat.length() > bounds_radius:
				flat = flat.normalized() * bounds_radius
				transform.position = Vector3(flat.x, transform.position.y, flat.y)
		# Frozen bodies stay put; ice halts velocity at the source.
		var elemental := world.get_component(entity, &"CElemental") as CElemental
		if elemental != null and elemental.frozen:
			velocity.linear = Vector3.ZERO
