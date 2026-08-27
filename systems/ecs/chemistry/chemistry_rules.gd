class_name ChemistryRules
extends Resource

## The complete rulebook of the chemistry engine.
##
## BotW's chemistry is two lists — elements and materials — and a matrix of
## how they combine. This resource is that matrix. Replace it wholesale in
## the inspector to change the physics of an entire world.

## All element × material reactions.
@export var reactions: Array[ElementReaction] = []

# ── Global tuning ────────────────────────────────────────────────────────────

## Fire jumps to flammable bodies within this radius.
@export var fire_spread_radius := 3.5

## Base chance per second that a burning body ignites a flammable neighbor.
@export_range(0.0, 1.0) var fire_spread_chance := 0.35

## How much a downwind neighbor's ignition chance is boosted (1 = doubled).
@export_range(0.0, 4.0) var wind_spread_boost := 1.0

## Bodies wetter than this cannot ignite.
@export_range(0.0, 1.0) var ignition_wetness_gate := 0.35

## Fuel consumed per second while burning.
@export var fuel_burn_rate := 1.0

## Element intensities drop by this fraction per second.
@export var element_decay := 1.5

## Wetness lost per second in dry air.
@export var evaporation_rate := 0.02

## Extra evaporation while on fire.
@export var burning_evaporation_rate := 0.3

## Wetness gained per second per unit of rain intensity.
## Wetness gained per second per unit of rain intensity. Must exceed
## burning_evaporation_rate or rain can never douse an active fire.
@export var rain_wet_rate := 0.5

## Electric arcs reach this far between conductive bodies.
@export var arc_range := 6.0

## Maximum arc chain length from a single source.
@export var arc_chain_max := 5

## Arc power falloff per hop.
@export_range(0.0, 1.0) var arc_falloff := 0.35

## Charged bodies only re-arc while at least this charged; below it the
## residual charge just decays. Without this, arcs ping-pong forever
## between wet conductors.
@export_range(0.0, 1.0) var arc_retrigger_power := 0.25

## Wet bodies conduct as if their material conductivity were boosted by this.
@export_range(0.0, 1.0) var wet_conductivity_bonus := 0.6

## Seconds a frozen body takes to thaw (absent ice).
@export var thaw_time := 8.0

## Constant WATER/ICE sources apply their element to bodies within this
## radius (puddles splash, ice shards chill — fire uses spread rules).
@export var source_aura_radius := 3.5

## Chance per second that an aura source applies its element to a neighbor.
@export_range(0.0, 2.0) var aura_chance := 0.8


var _lookup := {}  ## "element:material" -> ElementReaction


func _init() -> void:
	default_rules()


func default_rules() -> void:
	reactions = [
		# Fire
		_make(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.GRASS,
			0.9, 2.0, 0.0, 0.0, 0.0, false, false, 1.4),
		_make(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.WOOD,
			0.45, 1.0, 0.0, 0.0, 0.0, false, false, 0.8),
		_make(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.FLESH,
			0.15, 3.0, 0.0, 0.0, 0.0, false, false, 0.2),
		_make(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.STONE,
			0.0, 0.0, 0.0, 0.0, 0.0, false, false, 0.0),
		_make(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.METAL,
			0.0, 0.0, 1.0, 0.0, 0.0, false, false, 0.0),

		# Water
		_make(ChemistryDefs.Element.WATER, CBody.SurfaceMaterial.GRASS,
			0.0, 0.0, 0.0, 0.0, 0.8, true, true, 0.0),
		_make(ChemistryDefs.Element.WATER, CBody.SurfaceMaterial.WOOD,
			0.0, 0.0, 0.0, 0.0, 0.5, true, false, 0.0),
		_make(ChemistryDefs.Element.WATER, CBody.SurfaceMaterial.STONE,
			0.0, 0.0, 0.0, 0.0, 0.3, true, false, 0.0),
		_make(ChemistryDefs.Element.WATER, CBody.SurfaceMaterial.METAL,
			0.0, 0.0, 0.8, 0.0, 0.4, true, false, 0.0),
		_make(ChemistryDefs.Element.WATER, CBody.SurfaceMaterial.FLESH,
			0.0, 0.0, 0.0, 0.0, 0.6, true, false, 0.0),

		# Electricity
		_make(ChemistryDefs.Element.ELECTRICITY, CBody.SurfaceMaterial.METAL,
			0.0, 0.0, 1.0, 4.0, 0.0, false, false, 0.0),
		_make(ChemistryDefs.Element.ELECTRICITY, CBody.SurfaceMaterial.FLESH,
			0.0, 0.0, 0.2, 5.0, 0.0, false, false, 0.0),
		_make(ChemistryDefs.Element.ELECTRICITY, CBody.SurfaceMaterial.GRASS,
			0.0, 0.0, 0.05, 1.0, 0.0, false, false, 0.0),
		_make(ChemistryDefs.Element.ELECTRICITY, CBody.SurfaceMaterial.WOOD,
			0.0, 0.0, 0.05, 1.0, 0.0, false, false, 0.0),
		_make(ChemistryDefs.Element.ELECTRICITY, CBody.SurfaceMaterial.STONE,
			0.0, 0.0, 0.0, 0.0, 0.0, false, false, 0.0),

		# Ice
		_make(ChemistryDefs.Element.ICE, CBody.SurfaceMaterial.GRASS,
			0.0, 0.0, 0.0, 0.0, 0.0, false, true, 0.0),
		_make(ChemistryDefs.Element.ICE, CBody.SurfaceMaterial.WOOD,
			0.0, 0.0, 0.0, 0.0, 0.0, false, true, 0.0),
		_make(ChemistryDefs.Element.ICE, CBody.SurfaceMaterial.FLESH,
			0.0, 0.0, 0.0, 0.0, 0.0, false, true, 0.0),
	]
	rebuild_lookup()


## Reaction for an element/material pair, or null if none defined.
func reaction_for(element: int, material: int) -> ElementReaction:
	return _lookup.get("%d:%d" % [element, material])


func rebuild_lookup() -> void:
	_lookup.clear()
	for reaction in reactions:
		_lookup["%d:%d" % [reaction.element, reaction.material]] = reaction


func flammability(material: int) -> float:
	var reaction := reaction_for(ChemistryDefs.Element.FIRE, material)
	return reaction.ignite_chance if reaction else 0.0


func conductivity_of(material: int, wetness: float) -> float:
	var reaction := reaction_for(ChemistryDefs.Element.ELECTRICITY, material)
	if reaction == null:
		return 0.0
	return clampf(reaction.conductivity + wetness * wet_conductivity_bonus, 0.0, 1.0)


func _make(element: int, material: int, ignite: float, burn_dmg: float,
		conduct: float, shock_dmg: float, wet: float,
		douse: bool, freeze: bool, virulence: float) -> ElementReaction:
	var reaction := ElementReaction.new()
	reaction.element = element
	reaction.material = material
	reaction.ignite_chance = ignite
	reaction.burn_damage = burn_dmg
	reaction.conductivity = conduct
	reaction.shock_damage = shock_dmg
	reaction.wet_gain = wet
	reaction.douses = douse
	reaction.can_freeze = freeze
	reaction.fire_virulence = virulence
	return reaction
