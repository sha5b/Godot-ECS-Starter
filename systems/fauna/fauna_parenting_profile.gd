class_name FaunaParentingProfile
extends Node

@export_group("Parenting")
@export var enabled: bool = true
@export var care_mode: StringName = &"maternal"
@export var juvenile_follow_radius: float = 8.0
@export var guard_radius: float = 6.0
@export_range(0.0, 1.0) var independence_age_fraction: float = 0.35
@export var returns_young_home: bool = true
@export var escorts_offspring: bool = true
@export var regroup_offspring_distance: float = 10.0
@export var escort_home_distance: float = 14.0
@export_range(0.0, 1.0) var threat_response_bias: float = 0.8
