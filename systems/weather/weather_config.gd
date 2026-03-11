class_name WeatherConfig
extends Node

## Configuration component for the WeatherSystem.

## Length of a full day cycle in seconds
@export var day_length_seconds: float = 120.0

@export_group("Weather State Machine")
## Chance per tick to transition: clear → cloudy
@export_range(0.0, 1.0) var chance_clear_to_cloudy: float = 0.25

## Chance per tick to transition: cloudy → rain
@export_range(0.0, 1.0) var chance_cloudy_to_rain: float = 0.35

## Chance per tick to transition: rain → storm
@export_range(0.0, 1.0) var chance_rain_to_storm: float = 0.2

## Chance per tick to transition: storm → rain (de-escalation)
@export_range(0.0, 1.0) var chance_storm_to_rain: float = 0.3

## Chance per tick to transition: rain → cloudy (clearing)
@export_range(0.0, 1.0) var chance_rain_to_cloudy: float = 0.25

## Chance per tick to transition: cloudy → clear
@export_range(0.0, 1.0) var chance_cloudy_to_clear: float = 0.3

## How fast rain_intensity lerps toward target (per second)
@export var rain_intensity_lerp_speed: float = 0.5

## Target rain intensity during "rain" state
@export var rain_intensity_rain: float = 0.5

## Target rain intensity during "storm" state
@export var rain_intensity_storm: float = 0.9

@export_group("Wind")
## Minimum wind strength
@export var wind_min: float = 0.5

## Maximum wind strength
@export var wind_max: float = 5.0

## Wind gust chance per tick (0-1) — sudden increase
@export_range(0.0, 1.0) var wind_gust_chance: float = 0.15

## Gust strength multiplier
@export var wind_gust_multiplier: float = 2.5

## How fast wind lerps toward target (per second)
@export var wind_lerp_speed: float = 0.3

## How often the weather state re-evaluates (seconds)
@export var weather_tick_interval: float = 10.0

@export_group("Season")
## How many in-game days per season (4 seasons cycle: spring→summer→autumn→winter)
@export var days_per_season: int = 7

@export_group("Local Weather")
## Noise frequency for weather front zones (lower = larger weather regions)
@export var weather_zone_frequency: float = 0.003

## How fast weather fronts drift across the world (world units per second)
@export var weather_drift_speed: float = 2.0

## How strongly biome moisture modulates local rain probability (0=global, 1=fully local)
@export_range(0.0, 1.0) var biome_moisture_influence: float = 0.6

## Cloud density multiplier for rainy regions
@export var rain_cloud_density: float = 2.0

## Cloud density multiplier for dry/clear regions
@export var clear_cloud_density: float = 0.3

@export_group("Ecosystem")
## Rain intensity below this value counts as "dry" for drought tracking
@export_range(0.0, 0.5) var dry_rain_threshold: float = 0.05

## How many dry weather ticks before drought flag is set
@export var drought_threshold_ticks: int = 50

## Sun color at noon
@export var sun_color_noon: Color = Color(1.0, 0.95, 0.85)

## Sun color at sunrise/sunset
@export var sun_color_horizon: Color = Color(1.0, 0.55, 0.2)

## Ambient light intensity at night (0–1)
@export_range(0.0, 1.0) var night_ambient: float = 0.05

## Ambient light intensity at day (0–1)
@export_range(0.0, 1.0) var day_ambient: float = 0.4

@export_group("Sky Colors")
## Sky top color at noon
@export var sky_noon_top: Color = Color(0.25, 0.47, 0.85)

## Sky horizon color at noon
@export var sky_noon_horizon: Color = Color(0.55, 0.70, 0.90)

## Sky top color at sunrise/sunset
@export var sky_sunset_top: Color = Color(0.30, 0.25, 0.50)

## Sky horizon color at sunrise/sunset
@export var sky_sunset_horizon: Color = Color(0.95, 0.50, 0.20)

## Sky top color at night
@export var sky_night_top: Color = Color(0.02, 0.02, 0.06)

## Sky horizon color at night
@export var sky_night_horizon: Color = Color(0.05, 0.05, 0.12)

## Fog color at noon
@export var fog_noon: Color = Color(0.70, 0.75, 0.80)

## Fog color at sunset
@export var fog_sunset: Color = Color(0.80, 0.50, 0.30)
