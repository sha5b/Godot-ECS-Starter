class_name FaunaTribeProfile
extends Node

@export_group("Tribe")
@export var enabled: bool = true
@export var tribe_species_name: StringName = &""
@export_range(0.0, 1.0) var min_intelligence: float = 0.9
@export var min_group_size: int = 3
@export var founding_radius: float = 18.0
@export var preferred_tribe_type: StringName = &"camp"
@export var can_found_tribe: bool = true

@export_group("Expansion")
@export var building_enabled: bool = true
@export var max_buildings: int = 3
@export var building_spacing: float = 6.0
@export var prefers_building_near_home: bool = true
