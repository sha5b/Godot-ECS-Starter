class_name VitalitySystem
extends RefCounted

## End-of-life bookkeeping: publishes death events for bodies whose health
## hit zero, and despawns expired lifetimes. Runs after chemistry so deaths
## caused this frame are handled before the command flush.

const CHANNEL_DIED := &"ecs.died"

var _health: EcsWorld.QueryCache = null
var _lifetimes: EcsWorld.QueryCache = null


func tick(world: EcsWorld, delta: float, frame: int) -> void:
	if _health == null:
		_health = world.query([&"CHealth"])
		_lifetimes = world.query([&"CLifetime"])

	for entity in world.frame_entities(_health, frame):
		var health := world.get_component(entity, &"CHealth") as CHealth
		if health != null and health.dead:
			var transform := world.get_component(entity, &"CTransform") as CTransform
			world.publish(CHANNEL_DIED, {
				"entity": entity,
				"position": transform.position if transform else Vector3.ZERO,
			})
			world.commands.despawn(entity)

	for entity in world.frame_entities(_lifetimes, frame):
		var lifetime := world.get_component(entity, &"CLifetime") as CLifetime
		if lifetime == null:
			continue
		lifetime.remaining -= world.entity_delta(entity, delta)
		if lifetime.remaining <= 0.0:
			world.commands.despawn(entity)
