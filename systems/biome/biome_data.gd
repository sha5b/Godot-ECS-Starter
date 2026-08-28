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

@export_group("Ground Cover")
## Per-biome tuning for the FoliageSystem's shader ground cover.
##
## These used to be `match biome_name:` tables inside foliage_system.gd, so
## every new biome scene needed a code edit before it grew any grass. They
## are inspector values now: a new biome renders with these defaults and is
## tuned here, not in the renderer.

## How lush the ground cover reads (shader input, 0 = sparse, 1 = jungle).
@export_range(0.0, 1.0) var foliage_lushness: float = 0.55

## How dry/yellowed the ground cover reads (shader input).
@export_range(0.0, 1.0) var foliage_dryness: float = 0.22

## Multiplies foliage instance size in this biome.
@export_range(0.25, 2.0) var foliage_scale_multiplier: float = 1.0

## Added to this biome's computed foliage density score (can be negative).
@export_range(-1.0, 1.0) var foliage_density_bonus: float = 0.0

## Relative pick weight per foliage sprite in the atlas, one entry per
## sprite. All-zero or empty falls back to a uniform pick.
@export var foliage_sprite_weights: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0, 1.0])

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


## Weighted pick of a ground-cover sprite index for this biome.
func pick_foliage_sprite(rng: RandomNumberGenerator, sprite_count: int) -> int:
	if sprite_count <= 0:
		return 0
	var total := 0.0
	for i in mini(foliage_sprite_weights.size(), sprite_count):
		total += maxf(foliage_sprite_weights[i], 0.0)
	if total <= 0.0:
		return rng.randi_range(0, sprite_count - 1)
	var roll := rng.randf() * total
	var cumulative := 0.0
	for i in mini(foliage_sprite_weights.size(), sprite_count):
		cumulative += maxf(foliage_sprite_weights[i], 0.0)
		if roll <= cumulative:
			return i
	return 0
