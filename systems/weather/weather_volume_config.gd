class_name WeatherVolumeConfig
extends Node

## Configuration for localized atmospheric fog volumes.

@export_group("General")
## How often to refresh chunk-local fog volumes (seconds)
@export var update_interval: float = 0.5

## Extra horizontal padding applied to chunk-sized fog volumes
@export var chunk_coverage_multiplier: float = 1.15

@export_range(1, 4) var tiles_per_axis: int = 2

## Shared edge fade for all fog materials
@export_range(0.0, 1.0) var edge_fade: float = 0.18

@export_group("Rain Mist")
## Minimum local rain intensity required before a rain mist volume appears
@export_range(0.0, 1.0) var rain_mist_threshold: float = 0.24

## Density applied to localized rain mist volumes
@export var rain_mist_density: float = 0.08

## Base tint used for localized rain mist volumes
@export var rain_mist_color: Color = Color(0.71, 0.76, 0.81, 1.0)

## Vertical size of localized rain mist volumes
@export var rain_mist_height: float = 9.5

## Offset above terrain center for localized rain mist volumes
@export var rain_mist_height_offset: float = 1.0

## How quickly rain mist fades with height
@export var rain_mist_height_falloff: float = 0.5

@export_group("Sand Haze")
## Biomes that are allowed to spawn dry dust/sand haze volumes
@export var sand_haze_biomes: Array[StringName] = [&"desert", &"canyon"]

## Minimum wind strength required for sand haze volumes
@export var sand_haze_wind_threshold: float = 2.6

## Maximum local rain intensity allowed for sand haze volumes
@export_range(0.0, 1.0) var sand_haze_max_local_rain: float = 0.2

## Density applied to localized sand haze volumes
@export var sand_haze_density: float = 0.16

## Base tint used for localized sand haze volumes
@export var sand_haze_color: Color = Color(0.74, 0.66, 0.52, 1.0)

## Vertical size of localized sand haze volumes
@export var sand_haze_height: float = 14.0

## Offset above terrain center for localized sand haze volumes
@export var sand_haze_height_offset: float = 1.8

## How quickly sand haze fades with height
@export var sand_haze_height_falloff: float = 0.22
