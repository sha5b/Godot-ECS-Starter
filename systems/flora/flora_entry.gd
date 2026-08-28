class_name FloraEntry
extends Node3D

## Defines a single flora type as a drag-and-drop scene.
## The 3D mesh nodes are children of this node — one file = one content type.
##
## HOW TO ADD NEW FLORA:
## 1. Create a new scene with FloraEntry as root
## 2. Add MeshInstance3D children (the actual 3D object to spawn)
## 3. Configure spawn rules, scale, biome filters in Inspector
## 4. Drag the .tscn as a child of FloraSystem — done!

@export var entry_name: StringName = &"tree"

@export_group("Rendering")
## This type is drawn by the FoliageSystem's ground-cover shader instead of
## the flora MultiMesh batches. Set it on grass-like entries so the two
## renderers do not both plant the same cover; leave it off for props.
##
## This used to be a hardcoded name list inside FloraSystem, which silently
## dropped any new entry that happened to share one of those names.
@export var drawn_by_foliage_shader: bool = false

@export_group("Spawn Rules")
## Relative spawn weight (higher = more common compared to other flora)
@export var spawn_weight: float = 1.0

## Minimum height above sea level to spawn (normalized 0-1)
@export_range(0.0, 1.0) var min_height: float = 0.01

## Maximum height above sea level to spawn (normalized 0-1)
@export_range(0.0, 1.0) var max_height: float = 0.7

## Maximum terrain slope this flora can spawn on (degrees)
@export_range(0.0, 90.0) var max_slope_degrees: float = 35.0

## Minimum distance from water (world units, 0 = can touch water)
@export var min_water_distance: float = 0.5

@export_group("Scale")
## Minimum random scale
@export var scale_min: float = 0.8

## Maximum random scale
@export var scale_max: float = 1.4

@export_group("Biome Filter")
## If not empty, this flora ONLY spawns in these biomes.
## Leave empty = spawns in all biomes.
@export var allowed_biomes: Array[StringName] = []

## Biomes where this flora NEVER spawns (overrides allowed_biomes)
@export var excluded_biomes: Array[StringName] = []

## Density multiplier for this specific flora type (stacks with biome density)
@export var density_multiplier: float = 1.0

@export_group("Aquatic")
## Whether this flora spawns underwater (below sea level) instead of on land
@export var aquatic: bool = false

## Minimum water depth for this aquatic flora (world units below sea level)
@export var min_water_depth: float = 0.5

## Maximum water depth for this aquatic flora (world units below sea level)
@export var max_water_depth: float = 8.0

@export_group("Placement")
## Random Y rotation (always true for natural look, disable for aligned objects)
@export var random_rotation: bool = true

## Random tilt amount in degrees (0 = perfectly upright)
@export_range(0.0, 30.0) var random_tilt: float = 0.0

## Radius used to probe supporting ground under this flora footprint
@export var ground_probe_radius: float = 0.35

## Maximum allowed support height difference within the probed footprint
@export var max_ground_delta: float = 0.45

## How strongly this flora aligns to the supporting surface (0 = upright, 1 = full)
@export_range(0.0, 1.0) var surface_alignment: float = 0.25

## Sink into ground by this amount (useful for rocks, grass)
@export var ground_sink: float = 0.0

@export_group("Visual Variation")
@export_range(0.0, 0.2) var hue_variation: float = 0.0

@export_range(0.0, 0.4) var value_variation: float = 0.0

@export_group("Wind")
@export_range(0.0, 1.0) var wind_sway_strength: float = 0.0

@export_group("Lifecycle")
## Enable growth/aging/death simulation for this flora type
@export var growth_enabled: bool = false

## Number of growth stages (1 = seedling only, 3 = seedling→mature→old)
@export_range(1, 5) var growth_stages: int = 3

## Seconds per growth stage (modulated by season/weather)
@export var growth_time: float = 60.0

## Total lifespan in seconds before natural death
@export var max_age: float = 300.0

## Per-season growth rate multipliers (e.g. spring=1.5, winter=0.2)
@export var seasonal_growth_modifiers: Dictionary = {}

## Extra growth rate bonus during rain (additive, 0-1)
@export_range(0.0, 1.0) var rain_growth_bonus: float = 0.3

## Chance per lifecycle tick to die during drought
@export_range(0.0, 0.1) var drought_death_chance: float = 0.01

@export_group("Seed Spreading")
## Whether mature flora spreads seeds to spawn new seedlings
@export var spreads_seeds: bool = false

## Maximum radius for seed dispersal (world units)
@export var seed_spread_radius: float = 8.0

## Chance per lifecycle tick to spread a seed (when mature)
@export_range(0.0, 1.0) var seed_spread_chance: float = 0.1

## Minimum seconds between seed events for this parent
@export var seed_spread_interval: float = 30.0

## Maximum offspring from one parent over its lifetime
@export var max_children_per_parent: int = 2

## Dispersal method: "drop" (nearby), "wind" (drift with wind), "animal" (fauna-carried)
@export var seed_dispersal_method: StringName = &"drop"


## Create a new Node3D instance by duplicating this entry's mesh children
func create_instance() -> Node3D:
	var instance := Node3D.new()
	for child in get_children():
		instance.add_child(child.duplicate())
	return instance


## Check if this flora entry is allowed in a given biome
func is_allowed_in_biome(biome_name: StringName) -> bool:
	if not excluded_biomes.is_empty() and biome_name in excluded_biomes:
		return false
	if not allowed_biomes.is_empty() and biome_name not in allowed_biomes:
		return false
	return true
