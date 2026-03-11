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

## Current weather state name (clear, cloudy, rain, storm)
var weather_state: StringName = &"clear"

## Rain intensity 0.0 (dry) to 1.0 (heavy)
var rain_intensity: float = 0.0

# --- Camera / Spatial ---
## Current chunk coordinate the camera is in
var camera_chunk_pos: Vector2i = Vector2i.ZERO

## Camera world position (updated by camera or world script)
var camera_world_pos: Vector3 = Vector3.ZERO

# --- Biome ---
## Biome index at the camera position
var active_biome_at_camera: int = 0

## Biome name at camera position
var active_biome_name: StringName = &"plains"

# --- Terrain ---
## Sea level Y coordinate (written by TerrainSystem at init)
var sea_level: float = 0.0

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

# --- Rivers ---
## River paths per chunk: coord → Array of Array[Vector3] (written by TerrainSystem)
var river_paths: Dictionary = {}

## River cells per chunk: coord → Array[Dictionary] (written by TerrainSystem)
var river_cells: Dictionary = {}


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
