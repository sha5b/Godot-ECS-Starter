class_name UnderwaterConfig
extends Node

## Tuning for the submerged-camera look.

@export_group("Submersion")
## Metres below sea level over which the effect blends fully in. A band rather
## than a hard line keeps the surface crossing from snapping.
@export_range(0.05, 8.0, 0.05) var blend_depth: float = 1.2

@export_group("Screen Effect")
## Multiplied over the rendered frame while submerged.
@export var water_tint: Color = Color(0.32, 0.68, 0.80)

## Horizontal/vertical ripple travel speed.
@export_range(0.0, 8.0, 0.1) var wave_speed: float = 1.6

## Ripple count across the screen.
@export_range(0.0, 40.0, 0.5) var wave_frequency: float = 9.0

## Ripple amplitude in screen UV units.
@export_range(0.0, 0.05, 0.001) var wave_width: float = 0.006

## Blur tap distance in screen UV units.
@export_range(0.0, 0.02, 0.0005) var blur_radius: float = 0.0022

## Corner darkening while submerged.
@export_range(0.0, 1.0, 0.01) var vignette: float = 0.4

@export_group("Fog")
## Underwater fog colour. Overrides the weather system's haze while submerged.
@export var fog_color: Color = Color(0.06, 0.28, 0.36)

## Underwater fog density — short sight lines are what sells being under.
@export_range(0.0, 0.5, 0.001) var fog_density: float = 0.016

## Ambient light energy multiplier applied while submerged.
@export_range(0.0, 2.0, 0.01) var ambient_dim: float = 0.7
