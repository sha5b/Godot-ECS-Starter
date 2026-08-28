class_name WorldVariation
extends RefCounted

## What the seed changes about a world, beyond the arrangement of its noise.
##
## The seed already randomizes on every start, and every noise layer in the
## project is keyed on it — so the terrain is genuinely different each time.
## What was NOT different was the world's RECIPE. Land fraction was solved to
## the same 0.38, relief to the same 35 m, mountain coverage to the same 0.34,
## island scale to the same frequency, climate to the same envelope. Every seed
## produced another arrangement of the same kind of place, which is why a fresh
## start did not feel fresh.
##
## This rolls the recipe from the seed as well: how much land there is, how big
## the landmasses are, how much relief they have, how mountainous they are, and
## whether the world is hot or cold, wet or dry.
##
## Pure computation — a seed in, multipliers out. It touches no config and no
## scene tree, so the same roll can be printed, tested, and reproduced from
## nothing but the seed.

## How far the recipe may stray from the authored values, 0..1.
## 0 reproduces the config exactly, which is what the QA harnesses want.
var strength := 1.0

# --- The roll. Multipliers unless the name says otherwise. ---

## Land fraction is an absolute value, not a multiplier: it is already a
## fraction, and scaling it would make a low-land world's variation smaller
## than a high-land one's.
var land_fraction := 0.38

## Continent noise frequency. Lower means bigger, fewer landmasses.
var continent_frequency_scale := 1.0

## Vertical scale of the whole height field.
var height_scale_multiplier := 1.0

## Prominence of ridged mountain crests.
var ridged_weight_multiplier := 1.0

## Fraction of land inside an orogeny belt, absolute like land_fraction.
var orogeny_coverage := 0.34

## Belt frequency. Lower means longer, wider-spaced ranges.
var orogeny_frequency_scale := 1.0

## Added to the climate axes, in the same 0..1 units the biome envelopes use.
## A cold world and a hot one pick visibly different biomes from the same
## content, which is the cheapest large-scale variety available.
var temperature_bias := 0.0
var moisture_bias := 0.0

## A short human-readable summary of what was rolled, for the startup log.
var summary := ""


## Roll a world from a seed.
##
## `base_*` are the authored config values; the roll is centred on them, so
## turning `strength` down walks back toward exactly what the inspector says.
static func roll(world_seed: int, variation_strength: float,
		base_land_fraction: float, base_orogeny_coverage: float) -> WorldVariation:
	var variation := WorldVariation.new()
	variation.strength = clampf(variation_strength, 0.0, 1.0)
	var rng := RandomNumberGenerator.new()
	# A dedicated stream. Reusing the raw seed would correlate the recipe with
	# the continent noise that also uses it, so a world with more land would
	# always also be the flatter one.
	rng.seed = (world_seed ^ 0x5c4a9e) & 0x7fffffff

	var k := variation.strength
	variation.land_fraction = clampf(
		base_land_fraction + rng.randf_range(-0.13, 0.17) * k, 0.12, 0.72)
	variation.continent_frequency_scale = lerpf(1.0, rng.randf_range(0.6, 1.55), k)
	variation.height_scale_multiplier = lerpf(1.0, rng.randf_range(0.7, 1.5), k)
	variation.ridged_weight_multiplier = lerpf(1.0, rng.randf_range(0.55, 1.35), k)
	variation.orogeny_coverage = clampf(
		base_orogeny_coverage + rng.randf_range(-0.16, 0.22) * k, 0.06, 0.7)
	variation.orogeny_frequency_scale = lerpf(1.0, rng.randf_range(0.7, 1.45), k)
	variation.temperature_bias = rng.randf_range(-0.16, 0.16) * k
	variation.moisture_bias = rng.randf_range(-0.16, 0.16) * k
	variation.summary = variation._describe()
	return variation


## Plain-language shape of the world, so the startup line says what kind of
## place this seed produced rather than eight numbers.
func _describe() -> String:
	var parts: PackedStringArray = []
	if land_fraction < 0.28:
		parts.append("scattered islands")
	elif land_fraction > 0.5:
		parts.append("broad landmasses")
	else:
		parts.append("mixed coast")
	if continent_frequency_scale < 0.8:
		parts.append("large")
	elif continent_frequency_scale > 1.25:
		parts.append("fragmented")
	if height_scale_multiplier > 1.2 and ridged_weight_multiplier > 1.05:
		parts.append("high relief")
	elif height_scale_multiplier < 0.85:
		parts.append("low relief")
	if orogeny_coverage > 0.45:
		parts.append("widely mountainous")
	elif orogeny_coverage < 0.2:
		parts.append("few ranges")
	if temperature_bias > 0.07:
		parts.append("warm")
	elif temperature_bias < -0.07:
		parts.append("cold")
	if moisture_bias > 0.07:
		parts.append("wet")
	elif moisture_bias < -0.07:
		parts.append("dry")
	return ", ".join(parts)


## The numbers, for the log and the tests.
func describe_values() -> String:
	return ("land %.2f, continent freq x%.2f, height x%.2f, ridges x%.2f, "
		+ "belts %.2f at x%.2f, temp %+.2f, moisture %+.2f") % [
		land_fraction, continent_frequency_scale, height_scale_multiplier,
		ridged_weight_multiplier, orogeny_coverage, orogeny_frequency_scale,
		temperature_bias, moisture_bias]
