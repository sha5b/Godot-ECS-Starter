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

## Carnivores hunt prey species, and prey run from them.
@export var predation_enabled := true

## Herds, flocks, shoals and packs steer with their neighbours.
@export var flocking_enabled := true
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

@export_group("Predation")
## How far a hunter senses prey.
@export var predation_hunt_range := 30.0

## How far prey senses a hunter. Longer than hunt range on purpose — being
## seen first is what gives prey a chance.
@export var predation_flee_range := 34.0

## Reach of a bite, in world units.
@export var predation_bite_range := 1.6

## Damage per bite, before the hunter's body-mass scaling.
@export var predation_bite_damage := 3.5

@export_group("World Population")
## Spawn ECS actors from the generated world (chemistry grass + critters
## per loaded chunk). Disable in scenes that spawn their own content.
@export var populate_world := true

## Chemistry grass bodies per chunk — an invisible simulation layer that
## the foliage renderer reacts to (fire spreads through the visible grass).
@export var chemistry_grass_per_chunk := 48

## Per-chunk spawn budget for animals.
##
## This is a budget, not a count: each attempt picks a species that suits the
## biome and still has room under its own FaunaEntry.max_per_chunk, so the mix
## follows the authored content. Raised from 3 now that the ECS is the only
## thing spawning animals — FaunaSystem used to place its own on top.
@export var critters_per_chunk := 8

## Berry bushes per chunk — edible targets for the foraging loop.
@export var berries_per_chunk := 6

## Chance a chunk contains a lit campfire (permanent fire source).
@export_range(0.0, 1.0) var campfire_chance := 0.34

## Grass only spawns on land at least this far above sea level.
@export var populate_min_height_above_sea := 0.5

## Spawn ECS animals from the FaunaEntry content scenes under FaunaSystem,
## gated by biome, instead of one anonymous critter type everywhere.
##
## This is what connects authored species (body plan, diet, prey, biome rules)
## to the simulation that breeds and evolves them. Turn it off to go back to
## generic lucky-dip critters.
@export var use_fauna_species := true

@export_group("Procedural Critters")
## Give ECS critters a CGenome: bodies are built procedurally from genome
## data (see docs/PROCEDURAL_CRITTER_BODIES.md) instead of the simple
## capsule view. Bodies are distance-LOD'd by CritterView, so only near and
## mid-tier critters carry a full rig.
@export var procedural_critters := true

## Run BreedingSystem — crossover + mutation reproduction for genome-backed
## critters. Requires procedural_critters to produce carriers.
@export var breeding_enabled := true

## How close critters must stand to breed, in world units.
@export var breed_partner_radius := 6.0

## Seconds between breed attempts per critter.
@export var breed_cooldown := 30.0

## Population cap for genome-backed critters.
@export var breed_max_population := 24

## Genetic distance beyond which two members of one species can no longer
## interbreed, when the species record does not override it.
@export_range(0.05, 1.0) var breed_interbreed_distance := 0.5

## Mutation strength handed to the genome on birth (1 = default drift).
@export var critter_mutation_rate := 1.0


func _ready() -> void:
	if chemistry_rules == null:
		chemistry_rules = ChemistryRules.new()
		chemistry_rules.default_rules()
