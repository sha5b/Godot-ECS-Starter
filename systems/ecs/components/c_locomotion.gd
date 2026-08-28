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


func is_swimmer() -> bool:
	return medium == Medium.WATER


func is_flier() -> bool:
	return medium == Medium.AIR


## Read an animal's medium off its authored content.
##
## FaunaEntry already describes all of this — `aquatic`, `swim_height`,
## `can_fly`, `flight_height_min/max` — and the ECS spawner read none of it.
## `rng` picks a flier's cruising height inside its authored band so a flock is
## not all at exactly one altitude.
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
		locomotion.hover_height = rng.randf_range(
			entry.flight_height_min, entry.flight_height_max)
	return locomotion
