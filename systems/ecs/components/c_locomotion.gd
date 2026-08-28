class_name CLocomotion
extends RefCounted

## Which medium an animal lives in, and how far off the ground it sits.
##
## The grounding pass re-seats every actor on the terrain surface each tick,
## which is what makes a walking animal look like it is ON the ground. Applied
## to everything, it also drags a bird down to the dirt and buries a fish in
## the seafloor — and because the ECS spawner only ever placed actors above sea
## level, no fish existed to be buried in the first place. Measured before this
## component: `fish` and `whale` had no living individuals anywhere in the
## world, and the one jellyfish that had spawned was standing on a beach.
##
## The medium also decides where an animal is ALLOWED to be. A fish that swims
## up a beach is as wrong as a deer that walks into the sea, so swimmers are
## turned back at the shallows.

const COMPONENT_ID := &"CLocomotion"

enum Medium {
	LAND,   ## walks on the surface
	WATER,  ## swims between the seafloor and the surface
	AIR,    ## flies at a height above the surface
}

var medium: Medium = Medium.LAND

## Metres above the terrain surface this animal holds. 0 for walkers, the
## authored swim_height for swimmers, a roll inside the authored flight range
## for fliers.
var hover_height := 0.0

## Swimmers only: the shallowest water they will enter, and the deepest. Both
## come from the FaunaEntry, and both are enforced — the shallow limit is what
## keeps a shoal off the sand, and the deep limit keeps a reef fish on the reef.
var min_water_depth := 0.0
var max_water_depth := 0.0


## Airborne state, for fliers. Managed by FlightSystem, which is what makes a
## flier take off, cruise and land instead of sliding along at a fixed height.
var airborne := false

## Metres per second of climb and descent, from the genome.
var climb_rate := 2.0

## Cruising height when airborne, from the genome.
var cruise_height := 4.0

## Seconds this body can stay up before it has to come down.
var flight_endurance := 12.0

## Seconds spent in the current airborne or perched state.
var state_time := 0.0


## Where an animal of this medium belongs, given the ground beneath it.
##
## One helper, called by spawning, breeding and the grounding pass, because
## three copies of this arithmetic is three chances to disagree. They did:
## spawning added hover_height unconditionally, so a swimmer whose body wanted
## to cruise 2 m off a seafloor 0.5 m down was placed 1.5 m into the AIR — and
## because dormant actors are never re-grounded, the ones far from the camera
## stayed there. Measured: 14 animals on the wrong side of the water line.
static func rest_height(for_medium: Medium, hover: float, ground: float,
		sea: float) -> float:
	match for_medium:
		Medium.WATER:
			# Submerged, and off the bottom by as much as the water allows.
			return maxf(minf(ground + hover, sea - 0.25), ground)
		Medium.AIR:
			# Never below the water surface, whatever is underneath.
			return maxf(ground, sea) + hover
		_:
			return ground


func is_swimmer() -> bool:
	return medium == Medium.WATER


func is_flier() -> bool:
	return medium == Medium.AIR


## Read an animal's medium off its GENOME, with the authored entry as the
## fallback and the source of its depth limits.
##
## The medium used to come from FaunaEntry's `aquatic` and `can_fly` flags,
## which meant a lineage could evolve its shape, size, gait, diet response and
## colour but never what it moved through — nothing that walked could give rise
## to anything that swam. has_fins and has_wings are ordinary mutable genes, so
## now it can, and the body that comes with the new medium is the body that
## earned it: fin span drives thrust, wing span drives cruising height.
##
## The entry still supplies the water depth band, because that is a fact about
## where a species LIVES rather than about how its body works, and it is what
## keeps a reef fish on the reef.
static func from_genome(genome: CritterGenome, entry: FaunaEntry,
		rng: RandomNumberGenerator) -> CLocomotion:
	var locomotion := CLocomotion.new()
	if genome == null:
		return from_entry(entry, rng)
	match genome.medium_name():
		&"water":
			locomotion.medium = Medium.WATER
			locomotion.hover_height = genome.derived_swim_height()
			if entry != null and entry.aquatic:
				locomotion.min_water_depth = entry.min_water_depth
				locomotion.max_water_depth = entry.max_water_depth
			else:
				# A lineage that evolved fins on land has no authored band.
				# Give it the whole water column its body can handle.
				locomotion.min_water_depth = locomotion.hover_height + 0.4
				locomotion.max_water_depth = 40.0
		&"air":
			locomotion.medium = Medium.AIR
			locomotion.cruise_height = genome.derived_cruise_height()
			locomotion.climb_rate = genome.derived_climb_rate()
			locomotion.flight_endurance = genome.derived_flight_endurance()
			# Starts perched. Taking off is a decision, not a spawn state.
			locomotion.airborne = false
			locomotion.hover_height = 0.0
		_:
			locomotion.medium = Medium.LAND
	return locomotion


## Medium from authored content alone, for animals with no genome.
##
## FaunaEntry already describes all of this — `aquatic`, `swim_height`,
## `can_fly`, `flight_height_min/max` — and the ECS spawner read none of it.
static func from_entry(entry: FaunaEntry, rng: RandomNumberGenerator) -> CLocomotion:
	var locomotion := CLocomotion.new()
	if entry == null:
		return locomotion
	if entry.aquatic:
		locomotion.medium = Medium.WATER
		locomotion.hover_height = entry.swim_height
		locomotion.min_water_depth = entry.min_water_depth
		locomotion.max_water_depth = entry.max_water_depth
	elif entry.can_fly:
		locomotion.medium = Medium.AIR
		locomotion.cruise_height = rng.randf_range(
			entry.flight_height_min, entry.flight_height_max)
		locomotion.hover_height = 0.0
	return locomotion
