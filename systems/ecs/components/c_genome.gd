class_name CGenome
extends RefCounted

## Procedural body component — the ECS handle for a critter's morphology.
##
## Wraps a CritterGenome (body plan + gait angles) and caches the stats the
## genome derives from it, so gameplay systems read plain floats instead of
## re-deriving them every tick. Attach alongside CAgent/CHealth and copy the
## cached values into them at spawn: morphology then drives behavior, which
## is what makes body genes subject to natural selection.

const COMPONENT_ID := &"CGenome"

## The body plan. Assigned at spawn, replaced never (children get a fresh
## genome from BreedingSystem crossover + mutation).
var genome: CritterGenome

# --- Cached derived stats (refresh_derived() after editing genes) ---
var derived_move_speed := 2.0
var derived_health_max := 5.0
var derived_flee_multiplier := 1.2
var species := &""


## Build a component from a genome and cache its derived stats.
static func from_genome(source: CritterGenome) -> CGenome:
	var component := CGenome.new()
	component.genome = source
	component.refresh_derived()
	return component


## Build a component from a fresh seeded random genome.
static func random(rng: RandomNumberGenerator) -> CGenome:
	return from_genome(CritterGenome.randomized(rng))


## Recompute cached stats after genes changed (used by tests and editors).
func refresh_derived() -> void:
	if genome == null:
		return
	derived_move_speed = genome.derived_speed()
	derived_health_max = genome.derived_health()
	derived_flee_multiplier = genome.derived_flee_multiplier()
	species = StringName(genome.species_name())
