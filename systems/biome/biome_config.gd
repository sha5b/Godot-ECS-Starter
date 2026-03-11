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

@export_group("Macro Climate")
## Enables a simple latitude-style temperature gradient layered over noise.
@export var use_latitude_temperature: bool = true

## World-space north/south scale for latitude climate bands.
@export var latitude_scale: float = 0.0015

## Strength of the latitude effect blended into temperature (0 = noise only).
@export_range(0.0, 1.0) var latitude_temperature_strength: float = 0.35

## Optional moisture reduction at high elevations (simulates drier mountains).
@export_range(0.0, 1.0) var altitude_moisture_loss: float = 0.2
