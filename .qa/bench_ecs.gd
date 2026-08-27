extends SceneTree

# Microbenchmark EcsWorld at the entity counts the real world produces.
# load_radius 10 => 21x21 = 441 chunks
#   grass 48/chunk, critters 3, berries 6, campfire ~0.34  => ~25k entities

func _t() -> int: return Time.get_ticks_usec()

func bench(n: int) -> void:
	print("\n=== N = %d entities ===" % n)
	var w := EcsWorld.new()
	# Register the same query caches the real systems create.
	w.query([&"CTransform"])                                  # TierSystem
	w.query([&"CTransform", &"CVelocity"])                    # MovementSystem
	w.query([&"CHealth"])                                     # VitalitySystem
	w.query([&"CLifetime"])                                   # VitalitySystem
	w.query([&"CBody", &"CElemental", &"CTransform"])          # Chemistry
	w.query([&"CAgent", &"CTransform", &"CVelocity"])          # UtilityAI
	w.query([&"CTransform", &"CElemental"])                    # ViewSync-ish

	var t0 := _t()
	var ents := PackedInt64Array()
	for i in n:
		var e := w.spawn()
		var tr := CTransform.new()
		tr.position = Vector3(randf() * 600.0, 0.0, randf() * 600.0)
		w.add_component(e, tr)
		var b := CBody.new()
		b.material = CBody.SurfaceMaterial.GRASS
		w.add_component(e, b)
		w.add_component(e, CElemental.new())
		ents.append(e)
	var spawn_us := _t() - t0
	print("  spawn+3 components : %8.1f ms" % (spawn_us / 1000.0))

	# TierSystem pass: everything starts tier 0, most are far => mass retier.
	var cache := w.query([&"CTransform"])
	t0 = _t()
	var dists := {}
	for e in w.all_entities(cache):
		var tr := w.get_component(e, &"CTransform") as CTransform
		dists[e] = tr.position.distance_squared_to(w.focus_position)
	var gather_us := _t() - t0
	t0 = _t()
	w.assign_tiers_by_distance(dists, 40.0, 120.0, 300.0)
	var retier_us := _t() - t0
	print("  tier gather        : %8.1f ms" % (gather_us / 1000.0))
	print("  tier assign (1st)  : %8.1f ms   <-- runs every %d frames" % [retier_us / 1000.0, 15])

	# Steady state: nothing moved, so no tier changes.
	t0 = _t()
	w.assign_tiers_by_distance(dists, 40.0, 120.0, 300.0)
	print("  tier assign (noop) : %8.1f ms" % ((_t() - t0) / 1000.0))

	# frame_entities allocation cost, per system per frame
	t0 = _t()
	for f in 10:
		var _o := w.frame_entities(cache, f)
	print("  frame_entities x10 : %8.1f ms" % ((_t() - t0) / 1000.0))

	# Despawn a chunk's worth, then respawn (chunk streaming pattern).
	var chunk := 57
	t0 = _t()
	for i in chunk:
		w.despawn(ents[i])
	print("  despawn %d          : %8.1f ms" % [chunk, (_t() - t0) / 1000.0])
	t0 = _t()
	for i in chunk:
		var e := w.spawn()
		var tr := CTransform.new()
		w.add_component(e, tr)
		w.add_component(e, CBody.new())
		w.add_component(e, CElemental.new())
	print("  respawn %d (freelist): %7.1f ms   <-- per chunk load" % [chunk, (_t() - t0) / 1000.0])

func _init() -> void:
	seed(1234)
	for n in [1000, 5000, 12000, 25000]:
		bench(n)
	quit()
