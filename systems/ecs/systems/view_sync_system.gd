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


func tick(world: EcsWorld, _delta: float, _frame: int) -> void:
	var alive: Array[WeakRef] = []
	for ref in _bindings:
		var view := ref.get_ref() as EntityView
		if view == null:
			continue
		if not world.is_alive(view.entity):
			view.queue_free()
			continue
		alive.append(ref)
		var transform := world.get_component(view.entity, &"CTransform") as CTransform
		if transform != null:
			view.global_position = transform.position
			view.rotation.y = transform.facing
		var elemental := world.get_component(view.entity, &"CElemental") as CElemental
		if elemental != null:
			view.apply_elemental(elemental)
	_bindings = alive


func binding_count() -> int:
	return _bindings.size()
