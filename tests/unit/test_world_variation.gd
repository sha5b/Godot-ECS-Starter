extends EcsTestCase

## Unit tests for the seed-rolled world recipe.
##
## The properties that matter are: the same seed always gives the same world,
## different seeds give different ones, and turning the dial to zero gives back
## exactly what the inspector says.

const BASE_LAND := 0.38
const BASE_BELTS := 0.34


func _roll(world_seed: int, strength := 1.0) -> WorldVariation:
	return WorldVariation.roll(world_seed, strength, BASE_LAND, BASE_BELTS)


## Reproducibility is the whole point of printing the seed: paste it back in
## and you must get the same world.
func test_same_seed_gives_the_same_world() -> void:
	var a := _roll(123456)
	var b := _roll(123456)
	assert_almost(a.land_fraction, b.land_fraction, 0.0, "land fraction")
	assert_almost(a.height_scale_multiplier, b.height_scale_multiplier, 0.0, "relief")
	assert_almost(a.orogeny_coverage, b.orogeny_coverage, 0.0, "belts")
	assert_almost(a.temperature_bias, b.temperature_bias, 0.0, "temperature")
	assert_equal(a.summary, b.summary, "character")


func test_different_seeds_give_different_worlds() -> void:
	var a := _roll(1)
	var b := _roll(2)
	var differences := 0
	if absf(a.land_fraction - b.land_fraction) > 0.01:
		differences += 1
	if absf(a.height_scale_multiplier - b.height_scale_multiplier) > 0.02:
		differences += 1
	if absf(a.orogeny_coverage - b.orogeny_coverage) > 0.01:
		differences += 1
	if absf(a.temperature_bias - b.temperature_bias) > 0.01:
		differences += 1
	assert_true(differences >= 3,
		"only %d of 4 recipe axes differed between two seeds" % differences)


## Strength 0 must reproduce the authored config exactly. The QA harnesses rely
## on it, and so does anyone tuning the inspector values.
func test_zero_strength_reproduces_the_config() -> void:
	for world_seed in [1, 42, 999999]:
		var v := _roll(world_seed, 0.0)
		assert_almost(v.land_fraction, BASE_LAND, 0.0001, "land fraction is untouched")
		assert_almost(v.orogeny_coverage, BASE_BELTS, 0.0001, "belt coverage is untouched")
		assert_almost(v.continent_frequency_scale, 1.0, 0.0001, "island scale is untouched")
		assert_almost(v.height_scale_multiplier, 1.0, 0.0001, "relief is untouched")
		assert_almost(v.ridged_weight_multiplier, 1.0, 0.0001, "ridges are untouched")
		assert_almost(v.orogeny_frequency_scale, 1.0, 0.0001, "belt spacing is untouched")
		assert_almost(v.temperature_bias, 0.0, 0.0001, "no climate shift")
		assert_almost(v.moisture_bias, 0.0, 0.0001, "no climate shift")


## Every roll has to stay somewhere playable. A world with 5% land or a tenth
## of the relief is technically varied and practically broken.
func test_rolls_stay_within_playable_bounds() -> void:
	for i in 200:
		var v := _roll(i * 7919 + 13)
		assert_true(v.land_fraction >= 0.12 and v.land_fraction <= 0.72,
			"land fraction %.3f out of range" % v.land_fraction)
		assert_true(v.orogeny_coverage >= 0.06 and v.orogeny_coverage <= 0.7,
			"belt coverage %.3f out of range" % v.orogeny_coverage)
		assert_true(v.height_scale_multiplier >= 0.7 and v.height_scale_multiplier <= 1.5,
			"relief x%.3f out of range" % v.height_scale_multiplier)
		assert_true(absf(v.temperature_bias) <= 0.16,
			"temperature bias %+.3f out of range" % v.temperature_bias)
		assert_true(absf(v.moisture_bias) <= 0.16,
			"moisture bias %+.3f out of range" % v.moisture_bias)


## The recipe must not correlate with the terrain noise that shares the seed,
## or "more land" would always arrive with the same relief.
func test_recipe_axes_are_independent() -> void:
	var land_high_relief := 0
	var land_low_relief := 0
	for i in 400:
		var v := _roll(i * 104729 + 5)
		if v.land_fraction <= BASE_LAND:
			continue
		if v.height_scale_multiplier > 1.1:
			land_high_relief += 1
		elif v.height_scale_multiplier < 0.9:
			land_low_relief += 1
	assert_true(land_high_relief > 10 and land_low_relief > 10,
		"high-land worlds came out %d hilly and %d flat — the axes are coupled"
			% [land_high_relief, land_low_relief])


## The startup line has to actually say something.
func test_character_summary_is_populated() -> void:
	for world_seed in [3, 77, 5150, 88888]:
		var v := _roll(world_seed)
		assert_true(v.summary.length() > 0, "seed %d produced no character" % world_seed)
		assert_true(v.describe_values().contains("land"), "values line is malformed")
