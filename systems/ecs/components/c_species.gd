class_name CSpecies
extends RefCounted

## Which species an actor belongs to.
##
## This is the bridge between the two halves of the project: `FaunaEntry`
## content scenes describe what a deer IS (biomes, diet, prey, body plan) and
## the ECS describes what a deer DOES. Attaching this component is what lets
## breeding, predation and biome-gated spawning read one authored definition
## instead of each inventing its own idea of a species.
##
## Deliberately small. Everything shared by every member of a species lives
## once in `SpeciesRegistry`; only the id and this individual's own lineage
## bookkeeping are per-entity.

const COMPONENT_ID := &"CSpecies"

## Lineage id — the key into SpeciesRegistry. Founding species use the
## FaunaEntry name (&"deer"); split-off lineages get &"deer.2" and so on.
var species_id: StringName = &""

## Generations since this individual's lineage founded. Rises with every
## breeding event, resets when the lineage speciates.
var generation: int = 0

## How far this individual's genome sits from its species founder, 0..1.
## Cached at birth by BreedingSystem so predation and HUDs can read it
## without walking every gene.
var drift: float = 0.0


static func of(id: StringName, generation_count: int = 0) -> CSpecies:
	var component := CSpecies.new()
	component.species_id = id
	component.generation = generation_count
	return component
