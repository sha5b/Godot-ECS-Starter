class_name CGroup
extends RefCounted

## Membership of a herd, flock, shoal or pack.
##
## Groups are not authored — they are whatever same-species animals happen to
## be standing near each other, recomputed by FlockingSystem from the shared
## actor index. Storing a fixed roster would mean maintaining it through every
## birth, death and chunk unload; storing nothing but the steering weights
## lets the group be an emergent fact about positions.

const COMPONENT_ID := &"CGroup"

## How hard this animal keeps its distance from its neighbours.
var separation := 1.0

## How hard it matches their heading.
var alignment := 0.6

## How hard it pulls toward the middle of the group.
var cohesion := 0.5

## Radius within which same-species animals count as neighbours.
var neighbour_radius := 9.0

## Preferred spacing. Neighbours closer than this push back.
var personal_space := 2.0

## How much of the animal's velocity flocking may override, 0..1. Kept below
## 1 so a fleeing or panicking animal can still break formation.
var influence := 0.55

# --- Written by FlockingSystem, read by HUDs and group-aware behaviour ---

## Neighbours found on the last flocking tick.
var neighbours := 0

## Centre of the group this animal is currently part of.
var centre := Vector3.ZERO


static func from_record(record: SpeciesRecord) -> CGroup:
	var group := CGroup.new()
	if record != null:
		group.separation = record.flock_separation
		group.alignment = record.flock_alignment
		group.cohesion = record.flock_cohesion
		group.neighbour_radius = record.flock_radius
	return group
