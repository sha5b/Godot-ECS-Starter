class_name CloudConfig
extends Node

## Configuration for the CloudSystem.
## Drop as a child of CloudSystem and tweak in Inspector.

@export_group("Cloud Layer")
## Altitude of the cloud layer (world units above origin)
@export var cloud_altitude: float = 60.0

## How far clouds extend from the camera before recycling
@export var cloud_radius: float = 200.0

## Maximum number of cloud blobs in the scene
@export var max_clouds: int = 14

@export_group("Cloud Shape")
## World-space size of one cloud blob
@export var blob_size: float = 30.0

## Grid resolution per cloud blob (higher = smoother but heavier)
@export_range(4, 20) var blob_resolution: int = 8

## Noise frequency for cloud shape
@export var noise_frequency: float = 0.08

## Detail noise frequency multiplier
@export var detail_frequency: float = 0.15

@export_group("Drift")
## Minimum drift speed
@export var drift_speed_min: float = 0.8

## Maximum drift speed
@export var drift_speed_max: float = 2.5

## How often distant clouds are recycled (seconds)
@export var recycle_interval: float = 3.0

@export_range(1, 6) var max_recycled_per_interval: int = 2

@export_group("Scale Variation")
## Minimum random scale for cloud blobs
@export var scale_min: float = 0.7

## Maximum random scale for cloud blobs
@export var scale_max: float = 1.4

## Minimum vertical squash (clouds are flatter than wide)
@export var scale_y_min: float = 0.5

## Maximum vertical squash
@export var scale_y_max: float = 0.8

@export_group("Storm Behavior")
@export var storm_altitude: float = 45.0
@export var storm_scale_multiplier: float = 1.6
@export var storm_speed_multiplier: float = 1.8
@export var storm_transition_speed: float = 0.3
@export var local_wetness_lerp_speed: float = 0.55
@export var cloud_mass_lerp_speed: float = 0.45
@export var dry_scale_multiplier: float = 0.42
@export var wet_growth_boost: float = 0.42
@export var rain_altitude_drop: float = 8.0
@export var dry_visibility_threshold: float = 0.12
@export var wet_zone_sample_distance: float = 34.0
@export_range(4, 16) var wet_zone_candidate_count: int = 8

@export_group("Vertical Spread")
## Random Y offset range for cloud placement variety
@export var y_offset_range: float = 8.0
