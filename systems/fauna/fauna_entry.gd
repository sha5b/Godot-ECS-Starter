class_name FaunaEntry
extends Node

## Defines a single fauna type as a drag-and-drop scene.
## The 3D mesh nodes are children of this node — one file = one content type.
##
## HOW TO ADD NEW FAUNA:
## 1. Create a new scene with FaunaEntry as root
## 2. Add MeshInstance3D children (the actual 3D animal model)
## 3. Configure spawn rules, behavior, biome filters in Inspector
## 4. Drag the .tscn as a child of FaunaSystem — done!

@export var entry_name: StringName = &"deer"

@export_group("Spawn Rules")
## Relative spawn weight (higher = more common)
@export var spawn_weight: float = 1.0

## Maximum count of this fauna type per chunk
@export var max_per_chunk: int = 3

## Minimum height above sea level to spawn (normalized 0-1)
@export_range(0.0, 1.0) var min_height: float = 0.02

## Maximum height to spawn (normalized 0-1)
@export_range(0.0, 1.0) var max_height: float = 0.6

## Maximum terrain slope this fauna spawns on (degrees)
@export_range(0.0, 90.0) var max_slope_degrees: float = 30.0

@export_group("Scale")
## Minimum random scale
@export var scale_min: float = 0.9

## Maximum random scale
@export var scale_max: float = 1.2

@export_group("Biome Filter")
## If not empty, this fauna ONLY spawns in these biomes
@export var allowed_biomes: Array[StringName] = []

## Biomes where this fauna NEVER spawns
@export var excluded_biomes: Array[StringName] = []

@export_group("Behavior")
## Movement speed in world units per second
@export var move_speed: float = 3.0

## How far the animal wanders from its spawn point
@export var wander_radius: float = 10.0

## Time in seconds between wander decisions
@export var wander_interval: float = 4.0

## Distance at which the animal flees from the camera
@export var flee_distance: float = 15.0

## Speed multiplier when fleeing
@export var flee_speed_multiplier: float = 2.0

## Whether this animal uses flocking behavior
@export var flocking: bool = false

## Whether this fauna is aquatic (spawns in water, not on land)
@export var aquatic: bool = false

## Minimum water depth for aquatic fauna (world units below sea level)
@export var min_water_depth: float = 0.5

## Maximum water depth for aquatic fauna (world units below sea level)
@export var max_water_depth: float = 10.0

## Swim height above seafloor (world units) — where the fauna hovers
@export var swim_height: float = 1.0

@export_group("Predator / Prey")
## Is this fauna a predator? (will chase prey fauna)
@export var is_predator: bool = false

## Names of fauna types this predator hunts
@export var prey_names: Array[StringName] = []

## Detection radius for predator to spot prey
@export var predator_detection_range: float = 20.0

## Chase speed multiplier when pursuing prey
@export var chase_speed_multiplier: float = 1.5

## Whether this fauna flies instead of staying terrain-grounded
@export var can_fly: bool = false

## Minimum flight height above terrain for flying fauna
@export var flight_height_min: float = 2.0

## Maximum flight height above terrain for flying fauna
@export var flight_height_max: float = 6.0

## Vertical idle bob amplitude for flying fauna
@export var flight_bob_amplitude: float = 0.35

## Vertical idle bob speed for flying fauna
@export var flight_bob_speed: float = 2.0

@export_group("Lifecycle")
## Enable age/hunger/health simulation for this fauna type
@export var lifecycle_enabled: bool = false

## Maximum lifespan in seconds
@export var max_age: float = 600.0

## Age in seconds at which this fauna becomes adult (can breed)
@export var maturity_age: float = 120.0

## Hunger increase per second (0 = never hungry)
@export var hunger_rate: float = 0.01

## Hunger level at which this fauna dies of starvation
@export var hunger_death_threshold: float = 1.0

## Diet type: "herbivore", "carnivore", "omnivore"
@export var diet: StringName = &"herbivore"

## Flora types this herbivore/omnivore eats (entry_name values)
@export var food_flora_names: Array[StringName] = []

## How much hunger is restored per feeding event
@export var food_value: float = 0.5

## Maximum health
@export var health_max: float = 1.0

@export_group("Breeding")
## Whether adults of this type can breed
@export var can_breed: bool = false

## Cooldown seconds between breed attempts
@export var breed_cooldown: float = 120.0

## How close a mate must be to initiate breeding
@export var breed_partner_radius: float = 15.0

## Minimum offspring per breeding event
@export var offspring_count_min: int = 1

## Maximum offspring per breeding event
@export var offspring_count_max: int = 3

## Whether fauna builds a nest before breeding
@export var nesting_enabled: bool = false

## Seconds spent nesting/incubating before offspring appear
@export var nest_duration: float = 30.0

## Preferred biomes for nesting (empty = any biome)
@export var nest_biomes: Array[StringName] = []


## Create a new Node3D instance by duplicating this entry's mesh children
func create_instance() -> Node3D:
	var instance := Node3D.new()
	for child in get_children():
		instance.add_child(child.duplicate())
	return instance


## Check if this fauna is allowed in a given biome
func is_allowed_in_biome(biome_name: StringName) -> bool:
	if not excluded_biomes.is_empty() and biome_name in excluded_biomes:
		return false
	if not allowed_biomes.is_empty() and biome_name not in allowed_biomes:
		return false
	return true
