class_name RiverConfig
extends Node

## Configuration for the RiverSystem water fill visuals.
## River path tracing and voxel carving are configured in TerrainConfig.
## This config controls only the water mesh appearance inside carved channels.

@export_group("Water Fill")
## Width of the water strip at source (world units) — should match TerrainConfig.river_width_start
@export var river_width_min: float = 0.95

## Width of the water strip at sea level (world units) — should match TerrainConfig.river_width_end
@export var river_width_max: float = 4.0

## How far below the terrain surface the water sits (world units)
@export var water_surface_offset: float = 0.34

@export_group("Flow Visual")
## Flow speed for the river shader (UV scroll speed)
@export var flow_speed: float = 1.5

@export var wave_amplitude: float = 0.032

@export var wave_frequency: float = 1.0

@export var wave_speed: float = 0.55

## River water color (shallow / edges)
@export var river_shallow_color: Color = Color(0.30, 0.61, 0.72, 0.92)

@export var river_shore_color: Color = Color(0.34, 0.74, 0.70, 0.82)

@export var river_mid_color: Color = Color(0.09, 0.34, 0.52, 0.94)

## River water color (deep / center)
@export var river_deep_color: Color = Color(0.08, 0.27, 0.44, 0.98)

@export var foam_color: Color = Color(0.92, 0.95, 1.0, 0.9)

@export var foam_width: float = 1.1

@export var foam_noise_scale: float = 5.5

@export var roughness: float = 0.06

@export var metallic: float = 0.12
