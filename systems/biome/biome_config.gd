class_name BiomeConfig
extends Node

## Configuration component for the BiomeSystem.
## Biomes are auto-discovered as BiomeData children of BiomeSystem.
## Just drop biome .tscn scenes as children — they register automatically.

@export_group("Noise")
## Noise frequency for temperature map
@export var temperature_frequency: float = 0.005

## Noise frequency for moisture map
@export var moisture_frequency: float = 0.007

## Temperature noise seed offset (added to world seed)
@export var temperature_seed_offset: int = 1000

## Moisture noise seed offset (added to world seed)
@export var moisture_seed_offset: int = 2000

## Octaves of the climate fields.
##
## Unset, FastNoiseLite defaults to 5 FBM octaves, which put the top octave of
## the temperature field at ~0.08 — metre-scale detail in a field that is
## supposed to vary over kilometres. That is what speckles biome maps: two
## neighbouring cells land on different sides of a tolerance edge and the map
## turns to confetti. Climate is a macro field. Keep this at 1-2.
@export_range(1, 4) var climate_octaves: int = 2

@export_group("Natural Boundaries")
## Domain warp the climate sample position.
##
## Straight-ish climate gradients give biome borders that look drawn with a
## compass. Warping the lookup position by a second low-frequency noise field
## is the standard trick for organic boundaries: it costs two noise samples and
## turns every border into a meandering, fractal-edged coastline shape.
@export var climate_warp_enabled: bool = true

## Warp displacement in world units. Roughly the size of the wiggle in a border.
@export_range(0.0, 800.0) var climate_warp_strength: float = 260.0

@export var climate_warp_frequency: float = 0.0009

## Ecotone width: how close two biomes' scores must be to interleave.
##
## Real vegetation zones do not meet on a line, they interdigitate over a
## transition belt — tongues of forest run up a valley into the grassland
## beside it. Where two biomes score within this margin the choice is made by
## a hash, so the border becomes a mixed belt instead of a clean cut.
@export_range(0.0, 0.5) var ecotone_blend: float = 0.14

## Scale of the interleaving pattern, in world units.
@export_range(1.0, 60.0) var ecotone_scale: float = 11.0

@export_group("Macro Climate")
## Enables a simple latitude-style temperature gradient layered over noise.
@export var use_latitude_temperature: bool = true

## World-space north/south scale for latitude climate bands.
@export var latitude_scale: float = 0.0015

## Strength of the latitude effect blended into temperature (0 = noise only).
@export_range(0.0, 1.0) var latitude_temperature_strength: float = 0.35

## Optional moisture reduction at high elevations (simulates drier mountains).
@export_range(0.0, 1.0) var altitude_moisture_loss: float = 0.2
