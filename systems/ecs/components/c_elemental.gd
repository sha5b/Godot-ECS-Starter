class_name CElemental
extends RefCounted

## Elemental state component — the heart of the chemistry engine.
##
## Tracks active element intensities (applied by sources like campfires or
## lightning strikes), wetness, burning state, and freeze state.
## ChemistrySystem owns all writes; everything else reads or requests
## element application through the world.

const COMPONENT_ID := &"CElemental"

## Active element intensities: element enum value -> float power.
## Intensities decay each chemistry tick.
var elements: Dictionary = {}

## Constant element sources the body re-applies every tick (campfires keep
## burning, puddles keep wetting). Element enum value -> power.
var constant_elements: Dictionary = {}

var burning := false
var wetness := 0.0
var frozen := false

## Seconds until a frozen body thaws (absent ice).
var thaw_remaining := 0.0

## Seconds left of the current shock flash (visual only).
var shock_timer := 0.0

## Cached ignition roll threshold from rules, refreshed when wetness crosses
## the ignition threshold band. Kept on the component so ignition checks stay
## O(1) per entity.
var charred := false


func add_element(element: int, power: float) -> void:
	elements[element] = maxf(float(elements.get(element, 0.0)), power)


func get_element(element: int) -> float:
	return float(elements.get(element, 0.0))


func has_element(element: int) -> bool:
	return elements.has(element)


func clear_element(element: int) -> void:
	elements.erase(element)
