class_name FaunaConfig
extends Node

## Global configuration for the FaunaSystem.
## Fauna types are auto-discovered as FaunaEntry children of FaunaSystem.

@export_group("Density")
## Base number of fauna spawn attempts per chunk
@export var base_density: int = 8

## Minimum distance between fauna of the same type (world units)
@export var min_spacing: float = 5.0

@export_group("AI")
## How often fauna AI ticks (seconds). Lower = smoother but heavier.
@export var ai_tick_interval: float = 0.5

## Maximum fauna instances across all loaded chunks (hard cap)
@export var max_total_fauna: int = 100

## Social neighbor radius (world units)
@export var social_neighbor_radius: float = 14.0

## Duration (seconds) that fauna remember threats
@export var threat_memory_duration: float = 20.0

## Interval (seconds) between territory patrol checks
@export var territory_patrol_interval: float = 6.0

## Maximum distance (world units) that juveniles follow their parents
@export var juvenile_follow_distance: float = 10.0

@export_group("Lifecycle")
## Master toggle for fauna lifecycle simulation (age, hunger, health)
@export var lifecycle_enabled: bool = true

## Seconds between lifecycle update ticks
@export var lifecycle_tick_interval: float = 3.0

## Whether hunger drains over time
@export var hunger_enabled: bool = true

## Whether fauna can die of old age
@export var natural_death_enabled: bool = true

## Random variance applied to max_age per instance (±fraction)
@export_range(0.0, 0.5) var max_age_variance: float = 0.25

## Fraction of max_age at which fauna becomes elder (e.g. 0.75 = last 25% of life)
@export_range(0.5, 1.0) var elder_age_fraction: float = 0.75

## Minimum visual scale for juveniles (fraction of adult scale)
@export_range(0.1, 1.0) var juvenile_min_scale: float = 0.4

## Visual scale multiplier for elder fauna
@export_range(0.5, 1.5) var elder_scale: float = 0.9

## Hunger level at which fauna starts seeking food
@export_range(0.0, 1.0) var foraging_hunger_threshold: float = 0.3

## Distance at which fauna can eat a flora target (world units)
@export var eating_distance: float = 3.0

## Max spawn offset for offspring from parent position (world units)
@export var offspring_spawn_radius: float = 2.0

## Scale fraction for newly born juveniles
@export_range(0.1, 1.0) var juvenile_scale_fraction: float = 0.4

@export_group("Performance")
## Maximum fauna to spawn per frame (rate limiting)
@export var max_spawns_per_frame: int = 5
