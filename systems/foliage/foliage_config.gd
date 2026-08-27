class_name FoliageConfig
extends Node

@export var density_per_chunk: int = 9000
@export var max_instances_per_chunk: int = 12000
## Tuft dimensions — grass must stay well under the flora trees (~4-9m) or
## the meadow reads as scrub the same size as the forest canopy.
@export var quad_width: float = 0.55
@export var quad_height: float = 0.85
@export var scale_min: float = 0.7
@export var scale_max: float = 1.3
@export var ground_sink: float = 0.1
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

## Recolor foliage instances near ECS chemistry events (fire spread,
## charred patches, freezing). Costs nothing until events fire.
@export var chemistry_reactive: bool = true


@export_group("View Distance")
## Beyond this distance a chunk's grass stops rendering. Ground cover is
## the densest thing in the world (thousands of instances per chunk over
## hundreds of chunks) and it is also the first thing that stops being
## readable with distance, so it is the cheapest thing to cull.
@export_range(32.0, 1024.0, 8.0) var view_distance: float = 170.0

## Dissolve band before view_distance, so chunks fade rather than pop.
@export_range(0.0, 128.0, 2.0) var view_fade: float = 32.0
