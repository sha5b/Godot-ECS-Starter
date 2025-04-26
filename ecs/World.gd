extends Node
class_name World

var _next_entity_id: int = 1
var entities: Dictionary = {}
var components: Dictionary = {}
var systems: Array = []

func _ready() -> void:
    set_process(true)

func create_entity() -> Entity:
    var entity = Entity.new(_next_entity_id)
    entities[_next_entity_id] = entity
    _next_entity_id += 1
    return entity

func add_component(entity: Entity, component: Component) -> void:
    var comp_type = component.get_type()
    print("[WORLD DEBUG] Adding component: get_type=", comp_type)
    if not components.has(comp_type):
        components[comp_type] = {}
    components[comp_type][entity.id] = component

func get_components(comp_class_name: String) -> Dictionary:
    return components.get(comp_class_name, {})

func query(comp_classes: Array) -> Array:
    var result: Array = []
    if comp_classes.size() == 0:
        return result
    var base = get_components(comp_classes[0])
    for id in base.keys():
        var ok = true
        for i in range(1, comp_classes.size()):
            if not get_components(comp_classes[i]).has(id):
                ok = false
                break
        if ok:
            result.append(id)
    return result

func add_system(system: System) -> void:
    systems.append(system)

func _process(delta: float) -> void:
    for system in systems:
        system.update(self, delta)
