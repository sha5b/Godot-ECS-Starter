class_name FaunaBuildingProfile
extends Node

@export_group("Building")
@export var enabled: bool = true
@export var building_type: StringName = &"hut"
@export var footprint_radius: float = 2.0
@export var preferred_offset_from_center: float = 5.0
@export var requires_territory: bool = false
@export var requires_shelter_site: bool = false

@export_group("Lifecycle")
@export var decay_when_abandoned: bool = true
@export var shared_by_group: bool = true
