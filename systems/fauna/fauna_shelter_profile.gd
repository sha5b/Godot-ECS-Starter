class_name FaunaShelterProfile
extends Node

@export_group("Shelter")
@export var enabled: bool = true
@export var shelter_type: StringName = &"nest"
@export var site_search_radius: float = 12.0
@export var site_search_samples: int = 10
@export var claim_radius: float = 4.0
@export var return_home_distance: float = 8.0
@export var weather_shelter_threshold: float = 0.5
@export var returns_home_to_rest: bool = true
@export var min_site_height_delta: float = 0.0
@export var prefers_elevated_sites: bool = false
@export var prefers_cliffs: bool = false
@export var cliff_min_slope_degrees: float = 35.0
@export var prefers_support_flora: bool = false
@export var support_search_radius: float = 4.0
@export var support_height_offset: float = 2.5
@export var preferred_support_flora_names: Array[StringName] = []

@export_group("Territory")
@export var territory_enabled: bool = false
@export var home_range_radius: float = 12.0
@export var territory_radius: float = 0.0
@export_range(0.0, 1.0) var patrol_bias: float = 0.35

@export_group("Breeding")
@export var breeding_requires_shelter: bool = false
@export_range(0.0, 1.0) var site_fidelity: float = 0.5
