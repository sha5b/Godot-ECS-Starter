class_name FoliageConfig
extends Node

@export var density_per_chunk: int = 9000
@export var max_instances_per_chunk: int = 12000
@export var quad_width: float = 0.72
@export var quad_height: float = 1.7
@export var scale_min: float = 0.82
@export var scale_max: float = 2.45
@export var ground_sink: float = 0.2
@export_range(0.0, 1.0) var terrain_normal_align_strength: float = 0.32
@export_range(0.0, 25.0) var terrain_normal_max_degrees: float = 14.0
@export var ground_contact_lift: float = 0.0
@export var max_slope_degrees: float = 42.0
@export var min_height: float = 0.02
@export var max_height: float = 0.92
@export var min_water_clearance: float = 0.9
@export var shoreline_fade_distance: float = 4.5
@export var sample_cell_stride: int = 1
@export var cluster_per_cell_max: int = 56
@export var jitter_within_cell: float = 0.58
@export var river_cell_clearance: int = 2
@export var excluded_biomes: Array[StringName] = [&"snow", &"beach", &"shallow_water", &"coral_reef", &"kelp_forest", &"deep_ocean", &"desert"]
@export var cast_shadows: bool = false
