class_name EcsConfig
extends Node

## Inspector-first tuning for the ECS runtime, following the config-child
## doctrine. Drop different values here to reshape the whole simulation.

## Which subsystems run at all.
@export var tiering_enabled := true
@export var movement_enabled := true
@export var ai_enabled := true
@export var chemistry_enabled := true
@export var vitality_enabled := true
@export var view_sync_enabled := true

## Tier distances from the focus (camera/player), BotW A/B/C style.
@export var tier_near_distance := 40.0
@export var tier_mid_distance := 120.0
@export var tier_far_distance := 300.0
@export var tier_recheck_frames := 15

## Actors are confined inside this radius around the origin (0 = unbounded).
@export var movement_bounds_radius := 0.0

## Chemistry rulebook. Swap for a custom Resource to change world physics.
@export var chemistry_rules: ChemistryRules

## AI sensor ranges.
@export var ai_sensor_range := 24.0
@export var ai_threat_range := 7.0

@export_group("World Population")
## Spawn ECS actors from the generated world (chemistry grass + critters
## per loaded chunk). Disable in scenes that spawn their own content.
@export var populate_world := true

## Chemistry grass bodies per chunk — an invisible simulation layer that
## the foliage renderer reacts to (fire spreads through the visible grass).
@export var chemistry_grass_per_chunk := 48

## Foraging critters per chunk (visible utility-AI agents).
@export var critters_per_chunk := 3

## Berry bushes per chunk — edible targets for the foraging loop.
@export var berries_per_chunk := 6

## Chance a chunk contains a lit campfire (permanent fire source).
@export_range(0.0, 1.0) var campfire_chance := 0.34

## Grass only spawns on land at least this far above sea level.
@export var populate_min_height_above_sea := 0.5

@export_group("Procedural Critters")
## Give ECS critters a CGenome: bodies are built procedurally from genome
## data (see docs/PROCEDURAL_CRITTER_BODIES.md) instead of the simple
## capsule view. Off until the Body Lab output passes visual QA.
@export var procedural_critters := false

## Run BreedingSystem — crossover + mutation reproduction for genome-backed
## critters. Requires procedural_critters to produce carriers.
@export var breeding_enabled := false

## How close critters must stand to breed, in world units.
@export var breed_partner_radius := 6.0

## Seconds between breed attempts per critter.
@export var breed_cooldown := 30.0

## Population cap for genome-backed critters.
@export var breed_max_population := 24

## Mutation strength handed to the genome on birth (1 = default drift).
@export var critter_mutation_rate := 1.0


func _ready() -> void:
	if chemistry_rules == null:
		chemistry_rules = ChemistryRules.new()
		chemistry_rules.default_rules()
