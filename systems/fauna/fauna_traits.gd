class_name FaunaTraits
extends Node

## Optional drop-in component for advanced fauna intelligence and social behavior.
## Add as a child node inside any FaunaEntry .tscn to enable intelligence features.
##
## HOW TO USE:
## 1. Open any fauna content .tscn (e.g. deer.tscn)
## 2. Add a child Node with this script attached
## 3. Configure intelligence/social values in Inspector
## 4. FaunaSystem auto-detects this component at spawn time
##
## Fauna WITHOUT this component behave exactly as before (pure animal AI).
## Fauna WITH intelligence >= 1.0 will be eligible for future TribeSystem.

@export_group("Intelligence")
## Intelligence level: 0.0 = animal, 0.5 = pack animal, 1.0 = sapient
@export_range(0.0, 1.0) var intelligence: float = 0.0

## Tendency to form and maintain groups (0 = solitary, 1 = highly social)
@export_range(0.0, 1.0) var social_drive: float = 0.0

## Tendency to defend a home area (0 = nomadic, 1 = fiercely territorial)
@export_range(0.0, 1.0) var territoriality: float = 0.0

## Tendency to explore new areas vs stay near known locations
@export_range(0.0, 1.0) var curiosity: float = 0.0

## Future: ability to interact with objects and craft
@export_range(0.0, 1.0) var tool_use_potential: float = 0.0

@export_group("Social")
## How far social signals (calls, alerts) reach in world units
@export var communication_range: float = 0.0

## How many locations/events this fauna can remember (0 = no memory)
@export var memory_capacity: int = 0

## Runtime memory store: Array of {type, position, time} dictionaries
var memories: Array[Dictionary] = []


## Add a memory entry (auto-evicts oldest if at capacity)
func remember(event_type: StringName, world_pos: Vector3, time: float) -> void:
	if memory_capacity <= 0:
		return
	memories.append({
		"type": event_type,
		"position": world_pos,
		"time": time,
	})
	while memories.size() > memory_capacity:
		memories.pop_front()


## Find the most recent memory of a given type, or null
func recall(event_type: StringName) -> Dictionary:
	for i in range(memories.size() - 1, -1, -1):
		if memories[i]["type"] == event_type:
			return memories[i]
	return {}


## Clear all memories
func forget_all() -> void:
	memories.clear()
