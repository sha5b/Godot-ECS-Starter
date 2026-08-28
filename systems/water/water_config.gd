class_name WaterConfig
extends Node

## Configuration component for the WaterSystem.

@export_group("Appearance")
## Shore/very shallow water color (ankle-depth)
@export var shore_color: Color = Color(0.30, 0.65, 0.60, 0.35)

## Shallow water color (shelf zone)
@export var shallow_color: Color = Color(0.15, 0.45, 0.55, 0.6)

## Mid-depth water color (continental slope)
@export var mid_color: Color = Color(0.08, 0.28, 0.42, 0.75)

## Deep water color (abyss)
@export var deep_color: Color = Color(0.03, 0.08, 0.20, 0.92)

## Depth (normalized 0-1) where shallow→mid transition happens
@export_range(0.0, 1.0) var mid_depth_start: float = 0.25

## Depth (normalized 0-1) where mid→deep transition happens
@export_range(0.0, 1.0) var deep_depth_start: float = 0.6

## Water roughness (0 = mirror, 1 = matte)
@export_range(0.0, 1.0) var roughness: float = 0.05

## Water metallic
@export_range(0.0, 1.0) var metallic: float = 0.3

@export_group("Foam")
## Foam color at shoreline
@export var foam_color: Color = Color(0.92, 0.95, 1.0, 0.9)

## Width of the shore foam band (world units) at the reference seabed slope.
## Gentler shores widen it and steeper ones narrow it — see
## foam_slope_reference.
@export var foam_width: float = 0.8

## Foam noise cycles per metre, measured ACROSS the shore. Streaks are
## stretched along it by foam_streak_stretch.
@export var foam_noise_scale: float = 0.45

@export_subgroup("Shore Flow")
## Shore foam is advected along a flow field taken from the seabed: the depth
## gradient gives the direction water runs up the beach, its magnitude gives
## how far the swash spreads, and the swell bearing against it gives how
## exposed the coast is. See systems/water/water_surface.gdshader.

## How fast foam runs up the beach (metres per second).
@export_range(0.0, 4.0) var foam_drift_speed: float = 0.9

## Longshore drift (metres per second), perpendicular to the up-beach run.
## Negative reverses which way along the coast the foam slides.
@export_range(-3.0, 3.0) var foam_longshore_speed: float = 0.45

## Seconds an advected foam layer runs before it is swapped out. Longer looks
## smoother but stretches the pattern further before it resets.
@export_range(0.5, 12.0) var foam_cycle: float = 3.2

## How much longer foam streaks are along the shore than across it. 1 = round
## blobs, which is what foam looks like when nothing tells it where the beach
## is.
@export_range(1.0, 12.0) var foam_streak_stretch: float = 3.4

## Seabed slope (m/m) at which the foam band is exactly foam_width wide.
## Wave runup goes as height over slope, so shallower shores widen the band
## and steeper ones narrow it.
@export_range(0.005, 1.0) var foam_slope_reference: float = 0.09

## Clamps on that widening, as multiples of foam_width.
@export_range(0.1, 2.0) var foam_band_min: float = 0.55
@export_range(1.0, 8.0) var foam_band_max: float = 1.8

## Foam left on a fully sheltered shore, as a fraction of an exposed one.
## 1 = every coast foams the same whichever way it faces.
@export_range(0.0, 1.0) var foam_exposure_min: float = 0.4

@export_group("Caustics")
## Enable underwater caustics pattern on the seafloor
@export var caustics_enabled: bool = true

## Caustics brightness
@export_range(0.0, 1.0) var caustics_strength: float = 0.3

## Caustics animation speed
@export var caustics_speed: float = 1.2

@export_group("Waves")
## Enable simple vertex wave animation via shader
@export var waves_enabled: bool = true

## Swell amplitude in world units (crest to still-water, so wave height is
## roughly twice this). 0.15 m on a 110 m swell is invisible; open water wants
## something you can read against the horizon.
@export var wave_amplitude: float = 0.85

## Wave frequency
@export var wave_frequency: float = 1.5

## Wave speed multiplier
@export var wave_speed: float = 0.8

## Approximate water depth range used to transition from shore to deep water waves
@export var shore_depth_range: float = 4.0

## Minimum normalized water depth before large waves appear
@export_range(0.0, 1.0) var shore_wave_min_depth: float = 0.15

## Normalized water depth where deep-water waves are fully restored
@export_range(0.0, 1.0) var shore_wave_max_depth: float = 0.8

## Strength of the shoreline break ripple pattern
@export_range(0.0, 2.0) var shore_break_strength: float = 0.55

@export_group("Sea State")
## Wind strength that counts as a full gale — the sea state the shader gets is
## SharedWorld.wind_strength over this value.
@export_range(1.0, 40.0) var sea_state_full_wind: float = 9.0

## How fast the sea builds under a rising wind (per second).
@export_range(0.01, 2.0) var sea_build_rate: float = 0.12

## How fast the sea lays down when the wind drops. Slower than building — a
## swell outlives the wind that raised it.
@export_range(0.01, 2.0) var sea_calm_rate: float = 0.05

## How fast the wave bearing swings round to a new wind direction.
@export_range(0.01, 2.0) var sea_turn_rate: float = 0.08

@export_group("Far Ocean")
## Endless ocean ring past the loaded chunk frontier — the world ends in
## open water fading into haze instead of a terrain cut over void.
@export var far_ocean_enabled: bool = true

## How far (meters) the ring extends beyond the loaded region. Should
## comfortably exceed the fog distance so the ring edge is never visible.
@export_range(128.0, 2048.0, 8.0) var far_ocean_extent: float = 480.0
