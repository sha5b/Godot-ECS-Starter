class_name BiomeData
extends Node

## Defines a single biome type as a drag-and-drop scene.
##
## HOW TO ADD A NEW BIOME:
## 1. Create a new scene with BiomeData as root
## 2. Configure climate, textures, flora in the Inspector
## 3. Drag the .tscn as a child of BiomeSystem — done!

@export var biome_name: StringName = &"plains"

@export_group("Terrain Appearance")
## Color used for terrain vertex coloring in this biome
@export var terrain_color: Color = Color(0.35, 0.55, 0.20)

## Optional terrain texture (albedo) — used when texture painting is enabled
@export var terrain_texture: Texture2D

## Optional cliff/slope texture — applied on steep surfaces
@export var slope_texture: Texture2D

## Texture tiling scale (higher = smaller texture repeat)
@export var texture_scale: float = 4.0

@export_group("Climate")
## Ideal temperature (0.0 = frozen, 1.0 = scorching)
@export_range(0.0, 1.0) var ideal_temperature: float = 0.5

## How far from ideal temp is still acceptable (wider = more common)
@export_range(0.0, 0.5) var temperature_tolerance: float = 0.2

## Ideal moisture (0.0 = desert, 1.0 = swamp)
@export_range(0.0, 1.0) var ideal_moisture: float = 0.5

## How far from ideal moisture is still acceptable
@export_range(0.0, 0.5) var moisture_tolerance: float = 0.2

@export_group("Height")
## Ideal normalized height (0 = sea level, 1 = mountain peak)
@export_range(0.0, 1.0) var ideal_height: float = 0.3

## Height tolerance
@export_range(0.0, 0.5) var height_tolerance: float = 0.3

@export_group("Flora")
## How densely flora spawns in this biome (multiplier, 0 = none)
@export var flora_density_multiplier: float = 1.0

## How densely fauna spawns in this biome (multiplier, 0 = none)
@export var fauna_density_multiplier: float = 1.0

@export_group("Audio / FX")
## Optional ambient sound for this biome (e.g. wind, birds, insects)
@export var ambient_sound: AudioStream

## Particle effect scene for this biome (e.g. falling leaves, sand dust)
@export var particle_effect: PackedScene


## Score how well a given climate matches this biome (higher = better match)
## Returns 0.0 if outside tolerance, up to 1.0 for perfect match.
func score(temperature: float, moisture: float, height_normalized: float) -> float:
	var t_dist := absf(temperature - ideal_temperature)
	var m_dist := absf(moisture - ideal_moisture)
	var h_dist := absf(height_normalized - ideal_height)

	if t_dist > temperature_tolerance or m_dist > moisture_tolerance or h_dist > height_tolerance:
		return 0.0

	var t_score := 1.0 - (t_dist / temperature_tolerance)
	var m_score := 1.0 - (m_dist / moisture_tolerance)
	var h_score := 1.0 - (h_dist / height_tolerance)

	return t_score * m_score * h_score
