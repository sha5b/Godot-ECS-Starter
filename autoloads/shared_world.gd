class_name SharedWorldClass
extends Node

## Shared mutable world state — the singleton component.
## Systems READ this frequently. Only the owning system WRITES its section.

# --- Time ---
## Normalized time of day: 0.0 = midnight, 0.25 = sunrise, 0.5 = noon, 0.75 = sunset
var time_of_day: float = 0.25

# --- Weather ---
## Current wind direction (normalized XZ vector)
var wind_direction: Vector3 = Vector3.RIGHT

## Wind strength in world units/sec
var wind_strength: float = 1.0

## Combined wind vector (direction * strength)
var wind_vector: Vector3:
	get:
		return wind_direction * wind_strength

## Current weather state name (clear, cloudy, rain, storm, fog)
var weather_state: StringName = &"clear"

## Rain intensity 0.0 (dry) to 1.0 (heavy)
var rain_intensity: float = 0.0

## Valley-fog event intensity 0.0 (off) to 1.0 (thick mist pooling low)
var fog_intensity: float = 0.0

# --- Camera / Spatial ---
## Current chunk coordinate the camera is in
var camera_chunk_pos: Vector2i = Vector2i.ZERO

## The world point the view is centred on — for an orbit camera this is
## the FOCUS on the ground, not the camera body 100 m above it. Chunk
## streaming, ECS processing tiers and AI threat range all key off it.
##
## Write it through publish_camera_focus() so there is exactly one owner
## per frame. Four different places used to assign this directly (World
## plus each camera controller) and whichever ran last won, so the ECS
## focus flickered between the ground and the camera body. When the camera
## body won, nothing was within tier_near_distance and EVERY actor dropped
## to a coarse tier — tier 0 measured empty in a live capture, which makes
## creatures advance in 4x and 12x delta jumps instead of moving smoothly.
var camera_world_pos: Vector3 = Vector3.ZERO

## Process frame on which a camera controller last published the focus.
var _focus_frame: int = -1

# --- Biome ---
## Biome index at the camera position
var active_biome_at_camera: int = 0

## Biome name at camera position
var active_biome_name: StringName = &"plains"

# --- Terrain ---
## Sea level Y coordinate (written by TerrainSystem at init)
var sea_level: float = 0.0

## How far the camera is under the surface, 0 (dry) to 1 (fully submerged).
## Written by UnderwaterSystem.
var camera_submersion: float = 0.0

## Height scale for terrain (written by TerrainSystem at init)
var height_scale: float = 20.0

# --- Season ---
## Current season name (written by WeatherSystem)
var current_season: StringName = &"spring"

## Day counter (incremented by WeatherSystem each full day cycle)
var day_count: int = 0

# --- Ecosystem ---
## Total flora instances across all loaded chunks (written by FloraSystem)
var total_flora_count: int = 0

## Total fauna instances across all loaded chunks (written by FaunaSystem)
var total_fauna_count: int = 0

## Consecutive dry ticks (written by WeatherSystem when rain_intensity == 0)
var consecutive_dry_ticks: int = 0

var shelter_registry: Dictionary = {}

var territory_claims: Dictionary = {}

var fauna_groups: Dictionary = {}

var tribe_registry: Dictionary = {}

var building_registry: Dictionary = {}

# --- ECS runtime ---
## Live ECS statistics written by EcsSystem (entities, tier counts,
## per-system microseconds). Read by debug HUDs.
var ecs_stats: Dictionary = {}

# --- Rivers ---
## River paths per chunk: coord → Array of Array[Vector3] (written by TerrainSystem)
var river_paths: Dictionary = {}

## River cells per chunk: coord → Array[Dictionary] (written by TerrainSystem)
var river_cells: Dictionary = {}


## Publish the view focus. Camera controllers call this; World only fills
## in from the raw camera transform when no controller has claimed it.
func publish_camera_focus(focus: Vector3) -> void:
	camera_world_pos = focus
	_focus_frame = Engine.get_process_frames()


## True while some camera controller is actively publishing the focus.
func has_camera_focus_owner() -> bool:
	return Engine.get_process_frames() - _focus_frame <= 1


## Convert a world position to chunk coordinates
func world_to_chunk(world_pos: Vector3) -> Vector2i:
	var cs := GameConfig.chunk_size
	return Vector2i(
		floori(world_pos.x / cs),
		floori(world_pos.z / cs)
	)


## Convert chunk coordinates to world position (center of chunk)
func chunk_to_world(chunk_coord: Vector2i) -> Vector3:
	var cs := GameConfig.chunk_size
	return Vector3(
		(chunk_coord.x + 0.5) * cs,
		0.0,
		(chunk_coord.y + 0.5) * cs
	)
