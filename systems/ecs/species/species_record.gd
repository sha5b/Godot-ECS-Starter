class_name SpeciesRecord
extends RefCounted

## One species: everything shared by every animal that belongs to it.
##
## Species data lives here ONCE, not on every entity. A herd of forty deer
## shares one record, so a `CSpecies` component only has to carry an id.

enum Diet { HERBIVORE, CARNIVORE, OMNIVORE }

## Stable lineage id. Founding species take the FaunaEntry name (&"deer");
## species that split off get an id derived from their parent (&"deer.2").
var id: StringName = &""

## The FaunaEntry this lineage ultimately descends from. Every species that
## splits off keeps it, so "all the descendants of deer" stays answerable.
var root_entry: StringName = &""

## Pseudo-latin name for HUDs. Derived from the founder genome, so it is
## stable for the life of the species.
var display_name: String = ""

## The body plan this species is centred on. Individuals vary around it, and
## drift away from it is what eventually triggers a split.
var founder: CritterGenome

var diet: Diet = Diet.HERBIVORE

## Species ids this one hunts. Resolved from FaunaEntry.prey_names at
## registration, and inherited by any species that splits off.
var prey: Array[StringName] = []

## How far an individual may drift from `founder` before it is no longer this
## species. Inherited from the FaunaEntry that founded the lineage.
var speciation_distance: float = 0.42

## Mutation strength for this lineage's offspring.
var mutation_rate: float = 1.0

## Does this species move in groups, and how tightly?
## Sourced from FaunaEntry, inherited by every lineage that splits off.
var flocks: bool = false
var flock_separation: float = 1.0
var flock_alignment: float = 0.6
var flock_cohesion: float = 0.5
var flock_radius: float = 9.0

## How many splits deep this lineage is. 0 for a founding species.
var depth: int = 0

## Generation the species appeared in. 0 for founding species.
var founded_generation: int = 0


func is_carnivore() -> bool:
	return diet == Diet.CARNIVORE or diet == Diet.OMNIVORE


func eats_plants() -> bool:
	return diet == Diet.HERBIVORE or diet == Diet.OMNIVORE


## Does this species hunt `other`?
##
## Predation follows the ROOT entry, not the exact species id, so a wolf
## lineage that has split three ways still hunts every deer lineage. Prey
## lists are authored per FaunaEntry and would otherwise go stale the first
## time either side speciated.
func hunts(other: SpeciesRecord) -> bool:
	if other == null or not is_carnivore():
		return false
	if other.root_entry == root_entry:
		return false
	return other.root_entry in prey or other.id in prey


static func diet_from_name(diet_name: StringName) -> Diet:
	match diet_name:
		&"carnivore":
			return Diet.CARNIVORE
		&"omnivore":
			return Diet.OMNIVORE
		_:
			return Diet.HERBIVORE
