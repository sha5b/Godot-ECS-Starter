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

## Width of shore foam band (world units)
@export var foam_width: float = 0.8

## Foam noise scale for patchy appearance
@export var foam_noise_scale: float = 8.0

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

## Wave amplitude in world units
@export var wave_amplitude: float = 0.15

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

@export_group("Far Ocean")
## Endless ocean ring past the loaded chunk frontier — the world ends in
## open water fading into haze instead of a terrain cut over void.
@export var far_ocean_enabled: bool = true

## How far (meters) the ring extends beyond the loaded region. Should
## comfortably exceed the fog distance so the ring edge is never visible.
@export_range(128.0, 2048.0, 8.0) var far_ocean_extent: float = 480.0
