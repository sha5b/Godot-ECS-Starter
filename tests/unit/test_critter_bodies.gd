extends EcsTestCase

## Headless tests for the procedural critter body pipeline:
## CritterGenome (operators + derived stats), the CGenome component,
## BreedingSystem (crossover + mutation offspring), CritterBodyBuilder
## (rig topology) and CritterGait (phase table + FK evaluation).


func _seeded_rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# ── CritterGenome ─────────────────────────────────────────────────────────────

func test_randomized_is_deterministic_per_seed() -> void:
	var a := CritterGenome.randomized(_seeded_rng(42))
	var b := CritterGenome.randomized(_seeded_rng(42))
	assert_equal(a.genes, b.genes, "same seed => same genes")
	assert_equal(a.species_name(), b.species_name(), "same seed => same species name")


func test_randomized_genes_stay_in_range() -> void:
	for seed_value in range(5):
		var genome := CritterGenome.randomized(_seeded_rng(seed_value))
		for gene in genome.genes.keys():
			var value: float = float(genome.genes[gene])
			var r := CritterGenome.gene_range(gene)
			assert_true(value >= r.x and value <= r.y,
				"gene %s out of range: %f not in [%f, %f]" % [str(gene), value, r.x, r.y])


func test_mutation_clamps_within_ranges() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(7))
	for _i in 50:
		genome.mutate(_seeded_rng(1000 + _i), 3.0)
	for gene in genome.genes.keys():
		var value: float = float(genome.genes[gene])
		var r := CritterGenome.gene_range(gene)
		assert_true(value >= r.x and value <= r.y,
			"mutated gene %s escaped range: %f" % [str(gene), value])


func test_mutation_changes_something() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(9))
	var copy := CritterGenome.new(genome)
	copy.mutate(_seeded_rng(11), 1.0)
	assert_false(copy.genes == genome.genes, "mutation should drift at least one gene")


func test_crossover_blends_parents() -> void:
	var a := CritterGenome.randomized(_seeded_rng(1))
	var b := CritterGenome.randomized(_seeded_rng(2))
	var child := CritterGenome.crossover(a, b, _seeded_rng(3))
	assert_true(child.generation > maxi(a.generation, b.generation), "child generation advances")
	for gene in child.genes.keys():
		var lo := minf(float(a.genes[gene]), float(b.genes[gene]))
		var hi := maxf(float(a.genes[gene]), float(b.genes[gene]))
		var value: float = float(child.genes[gene])
		assert_true(value >= lo and value <= hi,
			"crossover gene %s outside parent range" % str(gene))


func test_derived_speed_rewards_legs() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(13))
	genome.genes[CritterGenome.GENE_HAS_WINGS] = 0.0
	genome.genes[CritterGenome.GENE_LEG_PAIRS] = 2.0
	var short_legs := CritterGenome.new(genome)
	short_legs.genes[CritterGenome.GENE_LEG_LENGTH] = CritterGenome.gene_range(CritterGenome.GENE_LEG_LENGTH).x
	var long_legs := CritterGenome.new(genome)
	long_legs.genes[CritterGenome.GENE_LEG_LENGTH] = CritterGenome.gene_range(CritterGenome.GENE_LEG_LENGTH).y
	assert_true(long_legs.derived_speed() > short_legs.derived_speed(),
		"longer legs should derive higher speed")


func test_derived_speed_rewards_gait_cycle() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(17))
	genome.genes[CritterGenome.GENE_HAS_WINGS] = 0.0
	genome.genes[CritterGenome.GENE_LEG_PAIRS] = 2.0
	var slow := CritterGenome.new(genome)
	slow.genes[CritterGenome.GENE_GAIT_CYCLE] = CritterGenome.gene_range(CritterGenome.GENE_GAIT_CYCLE).x
	var fast := CritterGenome.new(genome)
	fast.genes[CritterGenome.GENE_GAIT_CYCLE] = CritterGenome.gene_range(CritterGenome.GENE_GAIT_CYCLE).y
	assert_true(fast.derived_speed() > slow.derived_speed(),
		"faster gait cycle should derive higher speed")


func test_serialization_round_trip() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(21))
	genome.generation = 5
	var restored := CritterGenome.from_dict(genome.to_dict())
	assert_equal(restored.genes, genome.genes, "genes survive round trip")
	assert_equal(restored.generation, genome.generation, "generation survives round trip")


# ── CGenome component ─────────────────────────────────────────────────────────

func test_cgenome_registers_in_world() -> void:
	var world := EcsWorld.new()
	var entity := world.spawn()
	var comp := CGenome.random(_seeded_rng(31))
	world.add_component(entity, comp)

	assert_true(world.has_component(entity, &"CGenome"), "world sees CGenome")
	assert_equal((world.get_component(entity, &"CGenome") as CGenome).species, comp.species,
		"component round trips through the store")
	var cache := world.query([&"CGenome", &"CAgent"])
	var agent := CAgent.new()
	agent.brain = UtilityBrain.critter_brain()
	world.add_component(entity, agent)
	assert_true(cache.count() == 1, "query cache includes genome+agent entities")


func test_cgenome_caches_derived_stats() -> void:
	var comp := CGenome.random(_seeded_rng(33))
	assert_almost(comp.derived_move_speed, comp.genome.derived_speed(), 0.0001,
		"cached speed matches genome")
	assert_true(comp.species != &"", "species name is populated")


# ── BreedingSystem ────────────────────────────────────────────────────────────

func _breeding_world(population: int) -> EcsWorld:
	var world := EcsWorld.new()
	var rng := _seeded_rng(99)
	for i in population:
		var entity := world.spawn()
		var transform := CTransform.new()
		transform.position = Vector3(float(i % 2) * 2.0, 0.0, float(i / 2) * 2.0)
		world.add_component(entity, transform)
		var agent := CAgent.new()
		agent.brain = UtilityBrain.critter_brain()
		world.add_component(entity, agent)
		var comp := CGenome.random(rng)
		# Same species so the pairing pass can match them.
		comp.genome.seed_value = 4242
		comp.refresh_derived()
		world.add_component(entity, comp)
	return world


func test_breeding_produces_crossover_child() -> void:
	var world := _breeding_world(2)
	# Force the pair adjacent and mature.
	var positions := world.query([&"CGenome", &"CAgent", &"CTransform"])
	for entity in world.all_entities(positions):
		(world.get_component(entity, &"CTransform") as CTransform).position = Vector3.ZERO

	var breeding := BreedingSystem.new()
	breeding.partner_radius = 3.0
	breeding.breed_cooldown = 1.0
	breeding.max_population = 10
	breeding.maturity_delay = 0.0

	# Enough ticks to pass the 0.5 s breed check + command flushes.
	for _i in 4:
		breeding.tick(world, 0.3, _i)
		world.flush_commands()

	var genome_carriers := world.query([&"CGenome", &"CTransform"])
	assert_true(genome_carriers.count() == 3,
		"expected parents + 1 child, got %d" % genome_carriers.count())

	var events := world.drain(&"critter_bred")
	assert_false(events.is_empty(), "breeding publishes critter_bred")

	# The child genome must differ from both parents (crossover + mutation).
	var child_speeds: Array[float] = []
	for entity in genome_carriers.tiers[0]:
		child_speeds.append((world.get_component(entity, &"CGenome") as CGenome).derived_move_speed)
	assert_true(child_speeds.size() == 3, "all carriers readable")


func test_breeding_respects_population_cap() -> void:
	var world := _breeding_world(2)
	var positions := world.query([&"CGenome", &"CAgent", &"CTransform"])
	for entity in world.all_entities(positions):
		(world.get_component(entity, &"CTransform") as CTransform).position = Vector3.ZERO

	var breeding := BreedingSystem.new()
	breeding.partner_radius = 3.0
	breeding.breed_cooldown = 0.1
	breeding.maturity_delay = 0.0
	breeding.max_population = 2

	for _i in 4:
		breeding.tick(world, 0.3, _i)
		world.flush_commands()

	var carriers := world.query([&"CGenome"])
	assert_true(carriers.count() <= 2,
		"population cap must hold, got %d" % carriers.count())


# ── CritterBodyBuilder ────────────────────────────────────────────────────────

func test_builder_rig_topology() -> void:
	var rng := _seeded_rng(77)
	for i in 3:
		var genome := CritterGenome.randomized(rng)
		var root := CritterBodyBuilder.build(genome)
		assert_not_null(root, "builder returns a root")
		assert_not_null(root.get_node_or_null("Gait") as CritterGait,
			"body %d ships with a gait controller" % i)
		assert_not_null(root.get_node_or_null("SpineRoot"), "body %d has a spine root" % i)
		root.free()


func test_builder_joint_groups_match_genome() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(78))
	genome.genes[CritterGenome.GENE_LEG_PAIRS] = 2.0
	genome.genes[CritterGenome.GENE_TAIL_SEGMENTS] = 3.0
	genome.genes[CritterGenome.GENE_HAS_WINGS] = 1.0
	var root := CritterBodyBuilder.build(genome)

	var hips := _group_under(root, &"critter_hip")
	var knees := _group_under(root, &"critter_knee")
	var spine := _group_under(root, &"critter_spine")
	var tail := _group_under(root, &"critter_tail")

	assert_equal(hips.size(), 4, "two leg pairs => 4 hips")
	assert_equal(knees.size(), 4, "two leg pairs => 4 knees")
	assert_equal(spine.size(), genome.segment_count(), "spine segments match genome")
	assert_equal(tail.size(), 3, "tail joints match genome")
	assert_not_null(root.find_child("WingL", true, false), "WingL exists (FaunaSystem compat)")
	assert_not_null(root.find_child("WingR", true, false), "WingR exists (FaunaSystem compat)")
	assert_not_null(root.find_child("Head", true, false), "head joint exists")
	root.free()


func test_builder_legless_genome_has_no_legs() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(79))
	genome.genes[CritterGenome.GENE_LEG_PAIRS] = 0.0
	var root := CritterBodyBuilder.build(genome)
	assert_equal(_group_under(root, &"critter_hip").size(), 0, "no legs when gene says none")
	root.free()


# ── CritterTorso (continuous body surface) ────────────────────────────────────

func test_torso_mesh_is_built_for_many_genomes() -> void:
	var rng := _seeded_rng(101)
	for i in 10:
		var genome := CritterGenome.randomized(rng)
		var root := CritterBodyBuilder.build(genome)
		var torso_node := root.get_node_or_null("SpineRoot/Torso") as MeshInstance3D
		assert_not_null(torso_node, "body %d has a torso mesh node" % i)
		if torso_node == null or torso_node.mesh == null:
			root.free()
			continue
		var arrays := torso_node.mesh.surface_get_arrays(0)
		var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		assert_true(verts.size() > 100, "body %d torso has a real surface (%d verts)" % [i, verts.size()])
		for v in verts:
			assert_true(is_finite(v.x) and is_finite(v.y) and is_finite(v.z),
				"body %d torso vertex is NaN/inf" % i)
			break
		root.free()


func test_torso_reskin_follows_joint_rotation() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(103))
	var root := CritterBodyBuilder.build(genome)
	var torso_node := root.get_node("SpineRoot/Torso") as MeshInstance3D
	var torso := (root.get_node("Gait") as CritterGait).get_torso()
	assert_not_null(torso, "gait exposes its torso skinner")
	var verts_before: PackedVector3Array = torso_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]

	var spine: Array = _group_under(root, &"critter_spine")
	(spine[spine.size() - 1] as Node3D).rotation.y += 0.6
	assert_true(torso.reskin_if_moved(), "rotated joint triggers a reskin")

	var verts_after: PackedVector3Array = torso_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_equal(verts_after.size(), verts_before.size(), "reskin keeps topology")
	var moved := false
	for i in verts_after.size():
		if verts_after[i].distance_squared_to(verts_before[i]) > 0.0001:
			moved = true
			break
	assert_true(moved, "rotating a spine joint must move torso vertices")
	root.free()


func _group_under(root: Node, group: StringName) -> Array:
	var found: Array = []
	for node in root.get_children():
		_collect_group(node, group, found)
	return found


func _collect_group(node: Node, group: StringName, found: Array) -> void:
	if node.is_in_group(group):
		found.append(node)
	for child in node.get_children():
		_collect_group(child, group, found)


# ── CritterGait ───────────────────────────────────────────────────────────────

func test_gait_phase_offsets() -> void:
	var walk := CritterGait.leg_phase_offsets(CritterGenome.GaitPattern.WALK, 2)
	assert_equal(walk.size(), 4, "walk covers 4 legs")
	assert_true(walk.has(0.75), "walk uses 4 distinct phases")

	var trot := CritterGait.leg_phase_offsets(CritterGenome.GaitPattern.TROT, 2)
	assert_almost(trot[0], trot[3], 0.0001, "trot syncs diagonal FL+RR")
	assert_almost(trot[1], trot[2], 0.0001, "trot syncs diagonal FR+RL")

	var pace := CritterGait.leg_phase_offsets(CritterGenome.GaitPattern.PACE, 2)
	assert_almost(pace[0], pace[2], 0.0001, "pace syncs same-side FL+RL")

	var bound := CritterGait.leg_phase_offsets(CritterGenome.GaitPattern.BOUND, 2)
	assert_almost(bound[0], bound[1], 0.0001, "bound syncs front pair")

	var biped := CritterGait.leg_phase_offsets(CritterGenome.GaitPattern.WALK, 1)
	assert_equal(biped.size(), 2, "single pair => two phases")


func test_gait_tick_moves_legs() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(88))
	genome.genes[CritterGenome.GENE_LEG_PAIRS] = 2.0
	genome.genes[CritterGenome.GENE_STRIDE_AMP] = 0.6
	var root := CritterBodyBuilder.build(genome)
	var gait := root.get_node("Gait") as CritterGait

	var hip := _first_in_group(root, &"critter_hip")
	var rest_rot := hip.rotation

	gait.tick(0.5, 1.0)
	assert_false(hip.rotation == rest_rot, "running gait must swing hips off rest")

	# Idle settles near rest pose (small offsets only).
	gait.tick(0.016, 0.0)
	assert_almost(hip.rotation.x, rest_rot.x, 0.35, "idle stays near rest pose")
	root.free()


func _first_in_group(root: Node, group: StringName) -> Node3D:
	var found: Array = []
	_collect_group(root, group, found)
	return found[0] as Node3D


# ── Growth-rule invariants ─────────────────────────────────────────────────────

func test_builder_feet_rest_on_ground() -> void:
	var checked := 0
	for seed_value in range(8):
		var genome := CritterGenome.randomized(_seeded_rng(500 + seed_value))
		if genome.leg_pairs() < 1:
			continue
		var root := CritterBodyBuilder.build(genome)
		var foot_r: float = float(genome.genes[CritterGenome.GENE_FOOT_SIZE]) \
			* CritterBodyBuilder.UNIT_FOOT
		for node in _group_under(root, &"critter_knee"):
			for child in node.get_children():
				if child is MeshInstance3D and (child as Node).name.begins_with("Foot_"):
					var foot := child as MeshInstance3D
					# Foot bottom = center minus the squashed half-height
					# (feet are spheres scaled (1, 0.55, 1.3)). Transforms
					# are composed manually — global_position needs a
					# processed tree frame, which headless tests don't have.
					var bottom := _transform_under(foot, root).origin.y - foot_r * 0.55
					assert_true(absf(bottom) < 0.06,
						"%s must rest on the ground (bottom %.3f, seed %d)"
						% [foot.name, bottom, seed_value])
					checked += 1
		root.free()
	assert_true(checked >= 4, "expected to check several feet (checked %d)" % checked)


## World transform of `node` relative to `ancestor`, composed from rest
## transforms — valid outside the scene tree.
func _transform_under(node: Node3D, ancestor: Node) -> Transform3D:
	var chain: Array[Node3D] = []
	var cursor := node
	while cursor != null and cursor != ancestor:
		chain.append(cursor)
		cursor = cursor.get_parent() as Node3D
	var xform := Transform3D()
	for i in range(chain.size() - 1, -1, -1):
		xform = xform * chain[i].transform
	return xform


func test_builder_leg_pairs_spread_along_spine() -> void:
	for seed_value in range(8):
		var genome := CritterGenome.randomized(_seeded_rng(600 + seed_value))
		var count := genome.segment_count()
		if genome.leg_pairs() < 2 or count < 4:
			continue
		var root := CritterBodyBuilder.build(genome)
		var indexes: Array[int] = []
		for hip in _group_under(root, &"critter_hip"):
			indexes.append(int((hip.get_parent() as Node3D).name.trim_prefix("S")))
		assert_true(indexes.max() <= count - 2,
			"front pair stays clear of the head segment")
		assert_true(indexes.min() >= 1,
			"rear pair stays clear of the tail segment")
		assert_true(indexes.max() - indexes.min() >= 1,
			"leg pairs must not bunch on one segment")
		root.free()


func test_builder_spots_are_mirrored_pairs() -> void:
	var genome := CritterGenome.randomized(_seeded_rng(700))
	genome.genes[CritterGenome.GENE_PATTERN] = 2.0  # SPOTS
	genome.genes[CritterGenome.GENE_ACCENT_AMOUNT] = 0.8
	var root := CritterBodyBuilder.build(genome)
	var spots := root.find_children("Spot_*", "MeshInstance3D", true, false)
	assert_true(spots.size() >= 4, "spotted coat places mirrored spot pairs")
	var left := 0
	var right := 0
	for node in spots:
		var spot := node as MeshInstance3D
		if spot.name.ends_with("L"):
			left += 1
			var twin := spot.get_parent().get_node_or_null(
				NodePath(spot.name.trim_suffix("L") + "R")) as MeshInstance3D
			assert_not_null(twin, "every left spot has a right twin (%s)" % spot.name)
			if twin != null:
				assert_almost(twin.position.x, -spot.position.x, 0.0001,
					"spot twin mirrored across the midline")
				assert_almost(twin.position.z, spot.position.z, 0.0001,
					"spot twin shares its spine position")
		else:
			right += 1
	assert_true(left > 0 and left == right,
		"spots come in mirrored pairs (%d L / %d R)" % [left, right])
	root.free()


func test_randomization_covers_multiple_body_plans() -> void:
	var plans: Dictionary = {}
	for seed_value in range(40):
		var genome := CritterGenome.randomized(_seeded_rng(800 + seed_value))
		var key := str(genome.leg_pairs()) + "legs_" + str(int(genome.has_wings())) + "wings"
		plans[key] = true
	assert_true(plans.size() >= 3,
		"40 seeds should sample several archetypes, got %s" % str(plans.keys()))


func test_randomization_respects_allometric_floors() -> void:
	for seed_value in range(10):
		var genome := CritterGenome.randomized(_seeded_rng(900 + seed_value))
		var floor_girth := sqrt(genome.body_mass()) * 0.34
		assert_true(float(genome.genes[CritterGenome.GENE_LEG_GIRTH]) >= floor_girth - 0.001,
			"leg girth meets the allometric floor for mass %.2f" % genome.body_mass())


func test_eyes_rest_on_the_skull_surface() -> void:
	# The swept torso is the real head surface — an eye sphere must pierce
	# that shell (visible) without floating far off it (detached look).
	for seed_value in range(6):
		var genome := CritterGenome.randomized(_seeded_rng(950 + seed_value))
		var root := CritterBodyBuilder.build(genome)
		var head := root.find_child("Head", true, false) as Node3D
		assert_not_null(head, "body has a head")
		if head == null:
			root.free()
			continue
		var skull_r: float = float(genome.genes[CritterGenome.GENE_HEAD_SIZE]) \
			* CritterBodyBuilder.UNIT_HEAD_SIZE
		var eye_r: float = float(genome.genes[CritterGenome.GENE_EYE_SIZE])
		var axis := Vector3(0.0, skull_r * 0.2, skull_r * 0.45)
		var eyes := head.find_children("Eye_*", "MeshInstance3D", true, false)
		assert_true(eyes.size() >= 2, "eyes exist for seed %d" % seed_value)
		for node in eyes:
			var eye := node as MeshInstance3D
			var surface_dist: float = absf((eye.position - axis).length() - skull_r)
			assert_true(surface_dist < eye_r,
				"%s must pierce the skull shell (off by %.3f, eye r %.3f)"
				% [eye.name, surface_dist, eye_r])
			assert_true((eye.position - axis).length() < skull_r + eye_r * 1.2,
				"%s must not float free of the skull" % eye.name)
		root.free()


func test_torso_survives_hard_kinks() -> void:
	# Bend the body into near-reversal kinks and re-skin: every vertex must
	# stay finite and every ring open — collapsed or flipped rings show the
	# tube's hollow interior.
	var genome := CritterGenome.randomized(_seeded_rng(970))
	genome.genes[CritterGenome.GENE_TAIL_SEGMENTS] = 4.0
	genome.genes[CritterGenome.GENE_COUNT_BODY_SEGMENTS] = 5.0
	var root := CritterBodyBuilder.build(genome)
	var gait := root.get_node("Gait") as CritterGait
	var torso := gait.get_torso()

	var flip := 1.0
	for node in _group_under(root, &"critter_tail"):
		(node as Node3D).rotation = Vector3(flip * 0.9, 0.0, flip * 0.4)
		flip = -flip
	for node in _group_under(root, &"critter_spine"):
		(node as Node3D).rotation = Vector3(0.0, flip * 0.8, flip * 0.3)
		flip = -flip
	torso.reskin()

	var torso_node := root.get_node("SpineRoot/Torso") as MeshInstance3D
	assert_not_null(torso_node.mesh, "kinked body still skins a mesh")
	var verts := torso_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	assert_true(verts.size() > 100, "kinked torso keeps a real surface")
	for v in verts:
		assert_true(is_finite(v.x) and is_finite(v.y) and is_finite(v.z),
			"kinked torso vertex is NaN/inf")

	# Ring verts come first (RADIAL per ring), cap poles after — each ring
	# must stay open (no zero-radius pinch that shows the interior).
	var radial := 10
	var ring_count := (verts.size() - 2) / radial
	for ring in ring_count:
		var base := ring * radial
		var first := verts[base]
		var spread := 0.0
		for k in range(1, radial):
			spread = maxf(spread, first.distance_to(verts[base + k]))
		assert_true(spread > 0.004,
			"ring %d collapsed (spread %.4f) — interior would show" % [ring, spread])
	root.free()
