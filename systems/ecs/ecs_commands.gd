class_name EcsCommands
extends RefCounted

## Deferred structural command buffer.
##
## Systems must not spawn/despawn/add/remove while iterating query results —
## that corrupts the arrays being walked. They record intent here instead,
## and the scheduler applies everything at phase sync points, exactly like
## BotW's message-driven actor updates resolve after their pass.

enum Kind { SPAWN_COMPONENTS, DESPAWN, ADD, REMOVE }

var _world: WeakRef
var _buffer: Array[Dictionary] = []


func _init(world: EcsWorld) -> void:
	_world = weakref(world)


## Reserve an entity handle now, attach components at flush time.
## The returned id is immediately valid for recording follow-up commands.
func spawn_with(components: Array = []) -> int:
	var world: EcsWorld = _world.get_ref()
	if world == null:
		return -1
	var entity := world.spawn()
	_buffer.append({"kind": Kind.SPAWN_COMPONENTS, "entity": entity, "components": components})
	return entity


func despawn(entity: int) -> void:
	_buffer.append({"kind": Kind.DESPAWN, "entity": entity})


func add(entity: int, component: RefCounted) -> void:
	_buffer.append({"kind": Kind.ADD, "entity": entity, "component": component})


func remove(entity: int, component_id: StringName) -> void:
	_buffer.append({"kind": Kind.REMOVE, "entity": entity, "id": component_id})


## Apply every buffered command in order. Stale entity handles are skipped.
func apply() -> void:
	var world: EcsWorld = _world.get_ref()
	if world == null:
		return
	var pending := _buffer
	_buffer = []
	for cmd in pending:
		var entity: int = cmd["entity"]
		match cmd["kind"]:
			Kind.SPAWN_COMPONENTS:
				if world.is_alive(entity):
					for component in cmd["components"]:
						world.add_component(entity, component)
			Kind.DESPAWN:
				world.despawn(entity)
			Kind.ADD:
				if world.is_alive(entity):
					world.add_component(entity, cmd["component"])
			Kind.REMOVE:
				if world.is_alive(entity):
					world.remove_component(entity, cmd["id"])


func pending_count() -> int:
	return _buffer.size()
