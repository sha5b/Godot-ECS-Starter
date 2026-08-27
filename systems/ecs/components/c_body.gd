class_name CBody
extends RefCounted

## Physical material body. How an entity reacts to elements is decided by
## the ChemistryRules matrix, not by per-entity code.

## Named SurfaceMaterial because a "Material" enum would collide with
## Godot's built-in Material class in typed contexts.
enum SurfaceMaterial {
	NONE,
	GRASS,
	WOOD,
	METAL,
	STONE,
	FLESH,
}

const COMPONENT_ID := &"CBody"

var material: SurfaceMaterial = SurfaceMaterial.NONE

## Burnable fuel in seconds. Consumed while burning; 0 = cannot sustain fire.
var fuel := 0.0

## Mass in arbitrary units. Heavier conductors carry stronger arcs.
var mass := 1.0
