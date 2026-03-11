class_name FloraConfig
extends Node

## Global configuration for the FloraSystem.
## Flora types are auto-discovered as FloraEntry children of FloraSystem.
## Just drop flora .tscn scenes as children — they register automatically.

@export_group("Density")
## Base density of flora placement attempts per chunk (before biome multiplier)
@export var base_density: int = 50

## Minimum distance between flora instances (world units)
@export var min_spacing: float = 1.5

@export_group("Performance")
## Whether to use MultiMesh for rendering (future — not yet implemented)
@export var use_multimesh: bool = false

## Maximum flora instances per chunk (hard cap to prevent lag)
@export var max_per_chunk: int = 200

## Distance from camera beyond which wind sway animation is skipped (world units)
@export var sway_cull_distance: float = 80.0

@export_group("Lifecycle")
## Master toggle for flora lifecycle simulation (growth, aging, death)
@export var lifecycle_enabled: bool = true

## Seconds between lifecycle update ticks
@export var lifecycle_tick_interval: float = 5.0

## Random variance applied to max_age per instance (±fraction)
@export_range(0.0, 0.5) var max_age_variance: float = 0.3

## Scale fraction at seedling stage (0 = invisible, 1 = full size)
@export_range(0.1, 1.0) var seedling_scale: float = 0.3

## Scale fraction at mature stage
@export_range(0.5, 1.5) var mature_scale: float = 1.0

## Scale fraction at old/dying stage
@export_range(0.5, 1.5) var old_scale: float = 0.85

## Minimum rain intensity to trigger growth bonus
@export_range(0.0, 1.0) var rain_growth_threshold: float = 0.1

## Search radius (squared) for fauna-ate-flora event matching
@export var forage_search_radius_sq: float = 9.0

## How many consecutive dry ticks before flora considers it a drought
@export var drought_threshold_ticks: int = 50

@export_group("Seed Spreading")
## Maximum new seedlings spawned per lifecycle tick (rate limit)
@export var max_seedlings_per_tick: int = 3

## Maximum seedlings allowed per chunk (prevents overgrowth)
@export var max_seedlings_per_chunk: int = 10
