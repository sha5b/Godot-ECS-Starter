class_name GeoConfig
extends Node

@export_group("Temperature")
@export var temperature_frequency: float = 0.0018
@export var latitude_scale: float = 0.0012
@export_range(0.0, 1.0) var latitude_temperature_strength: float = 0.65
@export_range(0.0, 1.0) var continental_temperature_loss: float = 0.18
@export_range(0.0, 1.0) var season_temperature_strength: float = 0.12
@export_range(0.0, 1.0) var biome_temperature_macro_blend: float = 0.7

@export_group("Moisture")
@export var precipitation_frequency: float = 0.0016
@export var continentality_frequency: float = 0.0009
@export_range(0.0, 1.0) var latitude_precipitation_strength: float = 0.55
@export_range(0.0, 1.0) var inland_precipitation_loss: float = 0.35
@export_range(0.0, 1.0) var inland_moisture_loss: float = 0.25
@export_range(0.0, 1.0) var rain_shadow_strength: float = 0.4
@export_range(0.0, 1.0) var season_precipitation_strength: float = 0.18
@export_range(0.0, 1.0) var biome_moisture_macro_blend: float = 0.72
@export_range(0.0, 1.0) var altitude_moisture_loss: float = 0.2

@export_group("Hydrology")
@export var basin_frequency: float = 0.0011
@export var ridge_frequency: float = 0.0015
@export_range(0.0, 1.0) var basin_strength: float = 0.7
@export_range(0.0, 1.0) var drainage_strength: float = 0.6
@export_range(0.0, 1.0) var source_noise_influence: float = 0.22
@export_range(0.0, 1.0) var runoff_height_influence: float = 0.45
@export_range(0.0, 1.0) var runoff_slope_influence: float = 0.5
@export_range(0.0, 1.0) var runoff_precipitation_influence: float = 0.7
@export_range(0.1, 60.0) var runoff_reference_slope_degrees: float = 18.0
@export_range(0.0, 1.0) var river_source_score_bias: float = 0.52
@export_range(0.1, 2.0) var river_source_score_gain: float = 1.0

@export_group("Wind")
@export var prevailing_wind_angle_degrees: float = 35.0
@export_range(0.0, 1.0) var latitude_wind_variation: float = 0.35
@export var rain_shadow_sample_distance: float = 48.0
