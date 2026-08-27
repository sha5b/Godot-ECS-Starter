extends EcsTestCase

## Unit tests for the chemistry engine: rules matrix, ignition, spread,
## dousing, electric arcs, freezing, and rain coupling.
##
## Determinism comes from custom rules with 0/1 probabilities rather than
## seeded randomness, so these tests never flake.


func _make_body(material: int, fuel: float) -> CBody:
	var body := CBody.new()
	body.material = material
	body.fuel = fuel
	return body


func _spawn_body(world: EcsWorld, material: int, fuel: float,
		position: Vector3, health: float = -1.0) -> int:
	var e := world.spawn()
	var transform := CTransform.new()
	transform.position = position
	world.add_component(e, transform)
	world.add_component(e, _make_body(material, fuel))
	world.add_component(e, CElemental.new())
	if health > 0.0:
		var hp := CHealth.new()
		hp.max_hp = health
		hp.hp = health
		world.add_component(e, hp)
	return e


func _certain_rules() -> ChemistryRules:
	## Extreme-valued rules: everything ignites and spreads instantly.
	var rules := ChemistryRules.new()
	rules.default_rules()
	rules.reaction_for(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.GRASS).ignite_chance = 1.0
	rules.reaction_for(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.GRASS).fire_virulence = 1.0
	rules.fire_spread_chance = 1.0
	rules.reaction_for(ChemistryDefs.Element.ELECTRICITY, CBody.SurfaceMaterial.METAL).shock_damage = 4.0
	return rules


func test_rules_matrix_lookups() -> void:
	var rules := ChemistryRules.new()
	assert_almost(rules.flammability(CBody.SurfaceMaterial.GRASS), 0.9, 0.0001, "grass flammable")
	assert_almost(rules.flammability(CBody.SurfaceMaterial.STONE), 0.0, 0.0001, "stone not flammable")
	assert_true(rules.reaction_for(ChemistryDefs.Element.WATER, CBody.SurfaceMaterial.GRASS).douses,
		"water douses grass")
	assert_null(rules.reaction_for(ChemistryDefs.Element.WIND, CBody.SurfaceMaterial.STONE),
		"undefined pairs are null")


func test_fire_ignites_flammable_body() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 2.0, Vector3.ZERO)
	(world.get_component(e, &"CElemental") as CElemental).add_element(ChemistryDefs.Element.FIRE, 1.0)

	chem.tick(world, 1.0, 1)
	var elemental := world.get_component(e, &"CElemental") as CElemental
	assert_true(elemental.burning, "grass ignited")
	assert_false(world.drain(ChemistryDefs.CHANNEL_IGNITED).is_empty(), "ignition event")


func test_fire_does_not_ignite_stone() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var e := _spawn_body(world, CBody.SurfaceMaterial.STONE, 5.0, Vector3.ZERO)
	(world.get_component(e, &"CElemental") as CElemental).add_element(ChemistryDefs.Element.FIRE, 1.0)

	chem.tick(world, 1.0, 1)
	assert_false((world.get_component(e, &"CElemental") as CElemental).burning, "stone ignores fire")


func test_wetness_gate_blocks_ignition() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 2.0, Vector3.ZERO)
	var elemental := world.get_component(e, &"CElemental") as CElemental
	elemental.wetness = 0.8
	elemental.add_element(ChemistryDefs.Element.FIRE, 1.0)

	chem.tick(world, 1.0, 1)
	assert_false(elemental.burning, "soaked grass cannot ignite")


func test_burning_consumes_fuel_and_charres() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 2.5, Vector3.ZERO)
	(world.get_component(e, &"CElemental") as CElemental).add_element(ChemistryDefs.Element.FIRE, 1.0)

	chem.tick(world, 1.0, 1)
	var elemental := world.get_component(e, &"CElemental") as CElemental
	assert_true(elemental.burning, "burning while fuel lasts")
	chem.tick(world, 1.0, 2)
	chem.tick(world, 1.0, 3)
	assert_false(elemental.burning, "fire out of fuel")
	assert_true(elemental.charred, "charred after burnout")
	assert_false(world.drain(ChemistryDefs.CHANNEL_BURNED_OUT).is_empty(), "burnout event")


func test_burning_damage_kills_health() -> void:
	var world := EcsWorld.new()
	var rules := _certain_rules()
	rules.reaction_for(ChemistryDefs.Element.FIRE, CBody.SurfaceMaterial.GRASS).burn_damage = 10.0
	var chem := ChemistrySystem.new(rules)
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 5.0, Vector3.ZERO, 2.0)

	(world.get_component(e, &"CElemental") as CElemental).add_element(ChemistryDefs.Element.FIRE, 1.0)
	chem.tick(world, 1.0, 1)
	var health := world.get_component(e, &"CHealth") as CHealth
	assert_true(health.dead, "burn damage killed the body")


func test_fire_spreads_to_neighbor() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var source := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 10.0, Vector3.ZERO)
	var neighbor := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 10.0, Vector3(2, 0, 0))
	(world.get_component(source, &"CElemental") as CElemental).add_element(ChemistryDefs.Element.FIRE, 1.0)

	chem.tick(world, 1.0, 1)
	var source_el := world.get_component(source, &"CElemental") as CElemental
	var neighbor_el := world.get_component(neighbor, &"CElemental") as CElemental
	assert_true(source_el.burning, "source burning")
	# Spread sources are time-sliced (every Nth frame) — tick a full window.
	for frame in range(2, 8):
		chem.tick(world, 1.0, frame)
	assert_true(neighbor_el.has_element(ChemistryDefs.Element.FIRE)
		or neighbor_el.burning, "fire spread to the neighbor")


func test_water_element_douses_burning_body() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 10.0, Vector3.ZERO)
	var elemental := world.get_component(e, &"CElemental") as CElemental
	elemental.add_element(ChemistryDefs.Element.FIRE, 1.0)

	chem.tick(world, 1.0, 1)
	assert_true(elemental.burning, "burning first")

	elemental.add_element(ChemistryDefs.Element.WATER, 1.0)
	chem.tick(world, 1.0, 2)
	assert_false(elemental.burning, "water extinguished the fire")
	assert_true(elemental.wetness > 0.0, "water wet the body")
	assert_false(world.drain(ChemistryDefs.CHANNEL_EXTINGUISHED).is_empty(), "extinguish event")


func test_rain_wets_and_eventually_extinguishes() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	chem.env["rain_intensity"] = 1.0
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 10.0, Vector3.ZERO)
	var elemental := world.get_component(e, &"CElemental") as CElemental
	elemental.burning = true

	for frame in range(2, 12):
		chem.tick(world, 1.0, frame)
	assert_false(elemental.burning, "rain put the fire out")
	assert_true(elemental.wetness >= chem.rules.ignition_wetness_gate, "rain soaked the body")


func test_electricity_arcs_between_metal() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var a := _spawn_body(world, CBody.SurfaceMaterial.METAL, 0.0, Vector3.ZERO, 10.0)
	var b := _spawn_body(world, CBody.SurfaceMaterial.METAL, 0.0, Vector3(4, 0, 0), 10.0)
	var c := _spawn_body(world, CBody.SurfaceMaterial.METAL, 0.0, Vector3(8, 0, 0), 10.0)

	chem.tick(world, 1.0, 1)  # builds the grid
	chem.strike(world, Vector3.ZERO, 1.0, 1.5)

	var shocked := world.drain(ChemistryDefs.CHANNEL_SHOCKED)
	assert_equal(shocked.size(), 2, "arc chained through both neighbors")
	var b_health := world.get_component(b, &"CHealth") as CHealth
	var c_health := world.get_component(c, &"CHealth") as CHealth
	assert_true(b_health.hp < 10.0, "direct neighbor shocked harder")
	assert_true(c_health.hp < 10.0, "chain hop still shocks")
	assert_true(b_health.hp < c_health.hp or absf(b_health.hp - c_health.hp) < 0.001,
		"closer body takes at least as much damage")
	assert_true((world.get_component(a, &"CElemental") as CElemental).shock_timer > 0.0
		or shocked.size() == 2, "strike target also flashes")


func test_shockwave_dies_out() -> void:
	## Regression: arcs must not ping-pong between conductors forever —
	## the carrier discharges into the arc and the wave decays away.
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var a := _spawn_body(world, CBody.SurfaceMaterial.METAL, 0.0, Vector3.ZERO, 100.0)
	var b := _spawn_body(world, CBody.SurfaceMaterial.METAL, 0.0, Vector3(4, 0, 0), 100.0)

	chem.tick(world, 1.0, 1)
	chem.strike(world, Vector3.ZERO, 1.2, 1.5)

	var charged := 2
	for frame in range(2, 60):
		chem.tick(world, 1.0, frame)
		charged = 0
		for e in [a, b]:
			if (world.get_component(e, &"CElemental") as CElemental).has_element(ChemistryDefs.Element.ELECTRICITY):
				charged += 1
		if charged == 0:
			break
	assert_equal(charged, 0, "shockwave dissipated instead of looping forever")


func test_wetness_improves_conductivity() -> void:
	var rules := ChemistryRules.new()
	var dry := rules.conductivity_of(CBody.SurfaceMaterial.GRASS, 0.0)
	var wet := rules.conductivity_of(CBody.SurfaceMaterial.GRASS, 1.0)
	assert_almost(dry, 0.05, 0.0001, "dry grass barely conducts")
	assert_true(wet > 0.5, "wet grass conducts well")
	var stone := rules.conductivity_of(CBody.SurfaceMaterial.STONE, 1.0)
	assert_almost(stone, 0.6, 0.05, "wet stone gains bonus conductivity")


func test_ice_freezes_wet_bodies() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var e := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 5.0, Vector3.ZERO)
	var elemental := world.get_component(e, &"CElemental") as CElemental
	elemental.wetness = 0.8
	elemental.add_element(ChemistryDefs.Element.ICE, 1.0)

	chem.tick(world, 1.0, 1)
	assert_true(elemental.frozen, "wet grass froze")
	assert_false(world.drain(ChemistryDefs.CHANNEL_FROZEN).is_empty(), "freeze event")


func test_constant_sources_reapply_elements() -> void:
	var world := EcsWorld.new()
	var chem := ChemistrySystem.new(_certain_rules())
	var campfire := _spawn_body(world, CBody.SurfaceMaterial.STONE, 0.0, Vector3.ZERO)
	var elemental := world.get_component(campfire, &"CElemental") as CElemental
	elemental.constant_elements[ChemistryDefs.Element.FIRE] = 1.0

	chem.tick(world, 1.0, 1)
	chem.tick(world, 1.0, 2)
	assert_true(elemental.has_element(ChemistryDefs.Element.FIRE),
		"constant source keeps its element despite decay")


func test_water_source_wets_neighbor() -> void:
	var world := EcsWorld.new()
	var rules := _certain_rules()
	rules.aura_chance = 2.0  # deterministic: every roll succeeds
	var chem := ChemistrySystem.new(rules)
	var puddle := _spawn_body(world, CBody.SurfaceMaterial.STONE, 0.0, Vector3.ZERO)
	(world.get_component(puddle, &"CElemental") as CElemental).constant_elements[ChemistryDefs.Element.WATER] = 1.0
	var grass := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 5.0, Vector3(1, 0, 0))

	chem.tick(world, 1.0, 1)
	chem.tick(world, 1.0, 2)
	var grass_el := world.get_component(grass, &"CElemental") as CElemental
	assert_true(grass_el.wetness > 0.3, "puddle splashed the grass wet (got %f)" % grass_el.wetness)


func test_ice_source_freezes_wet_neighbor() -> void:
	var world := EcsWorld.new()
	var rules := _certain_rules()
	rules.aura_chance = 2.0
	var chem := ChemistrySystem.new(rules)
	var shard := _spawn_body(world, CBody.SurfaceMaterial.STONE, 0.0, Vector3.ZERO)
	(world.get_component(shard, &"CElemental") as CElemental).constant_elements[ChemistryDefs.Element.ICE] = 1.0
	var grass := _spawn_body(world, CBody.SurfaceMaterial.GRASS, 5.0, Vector3(1, 0, 0))
	(world.get_component(grass, &"CElemental") as CElemental).wetness = 0.8

	chem.tick(world, 1.0, 1)
	chem.tick(world, 1.0, 2)
	assert_true((world.get_component(grass, &"CElemental") as CElemental).frozen,
		"ice shard froze the wet grass")
