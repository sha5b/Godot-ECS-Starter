class_name ElementReaction
extends Resource

## One cell of the element × material interaction matrix.
## Fully inspector-editable — designers tune the chemistry of the world
## without touching simulation code.

## Which element triggers this reaction.
@export var element: ChemistryDefs.Element = ChemistryDefs.Element.FIRE

## Which material this reaction applies to.
@export var material: CBody.SurfaceMaterial = CBody.SurfaceMaterial.GRASS

## Chance per second of catching fire while the element is active on the
## body (0 = never ignites).
@export_range(0.0, 1.0) var ignite_chance := 0.0

## Damage per second while burning.
@export var burn_damage := 0.0

## How strongly this material carries electric arcs (0 = insulator).
@export_range(0.0, 1.0) var conductivity := 0.0

## Damage taken from electric shocks, scaled by conductivity and wetness.
@export var shock_damage := 0.0

## Wetness gained per second while the element is active (WATER on things).
@export_range(0.0, 2.0) var wet_gain := 0.0

## If true, the element extinguishes burning bodies (rain, water splash).
@export var douses := false

## If true, the element can freeze this body when it is wet enough.
@export var can_freeze := false

## How much fire this material contributes when burning (drives spread).
@export_range(0.0, 2.0) var fire_virulence := 0.0


func _get_property_list() -> Array[Dictionary]:
	# Enums export as ints; hint the inspector with readable options.
	return []
