extends SceneTree

func _initialize() -> void:
	# ---- minimal proof that the chain composition order is reversed ----
	var a := Node3D.new(); a.name = "A"
	var b := Node3D.new(); b.name = "B"
	var c := Node3D.new(); c.name = "C"
	a.add_child(b); b.add_child(c)
	a.rotation = Vector3(0.0, 0.0, 0.0)
	b.position = Vector3(1, 0, 0); b.rotation = Vector3(0, deg_to_rad(90), 0)
	c.position = Vector3(1, 0, 0)
	root.add_child(a)
	await process_frame
	var truth: Transform3D = a.global_transform.affine_inverse() * c.global_transform
	# replicate CritterTorso._control_position's loop exactly
	var x := Transform3D()
	var chain: Array[Node3D] = []
	var cur: Node3D = c
	while cur != null and cur != a:
		chain.append(cur); cur = cur.get_parent() as Node3D
	for i in range(chain.size() - 1, -1, -1):
		x = chain[i].transform * x
	print("engine truth  C in A space: ", truth * Vector3.ZERO)
	print("torso formula C in A space: ", x * Vector3.ZERO)
	print("correct order (parent-first): ", (b.transform * c.transform) * Vector3.ZERO)
	print("MATCH: ", (truth * Vector3.ZERO).distance_to(x * Vector3.ZERO) < 1e-6)
	a.free()

	# ---- same check on a real critter, in a real scene tree, mid-gait ----
	print("\n=== CritterTorso._control_position vs engine global_transform ===")
	var rng := RandomNumberGenerator.new()
	var worst_rest := 0.0
	var worst_gait := 0.0
	var report := 0
	for s in range(40):
		rng.seed = s
		var g := CritterGenome.randomized(rng)
		var body := CritterBodyBuilder.build(g)
		root.add_child(body)
		var gait := body.get_node("Gait") as CritterGait
		var torso := gait.get_torso()
		var space := torso.space
		await process_frame
		var e_rest := 0.0
		for i in torso.controls.size():
			var node: Node3D = torso.controls[i]["node"]
			var off: Vector3 = torso.controls[i]["offset"]
			var truth2: Vector3 = space.global_transform.affine_inverse() * (node.global_transform * off)
			e_rest = maxf(e_rest, (truth2 - torso._control_position(i)).length())
		worst_rest = maxf(worst_rest, e_rest)
		for step in 10:
			gait.tick(1.0 / 30.0, 1.0)
		await process_frame
		var e_gait := 0.0
		var worst_i := -1
		for i in torso.controls.size():
			var node: Node3D = torso.controls[i]["node"]
			var off: Vector3 = torso.controls[i]["offset"]
			var truth3: Vector3 = space.global_transform.affine_inverse() * (node.global_transform * off)
			var e := (truth3 - torso._control_position(i)).length()
			if e > e_gait:
				e_gait = e; worst_i = i
		worst_gait = maxf(worst_gait, e_gait)
		if report < 4 and e_gait > 0.05:
			var node2: Node3D = torso.controls[worst_i]["node"]
			var off2: Vector3 = torso.controls[worst_i]["offset"]
			print("  seed %-3d control[%d] (%s): engine=%s  torso=%s  error=%.4f m" % [
				s, worst_i, node2.name,
				str(space.global_transform.affine_inverse() * (node2.global_transform * off2)),
				str(torso._control_position(worst_i)), e_gait])
			report += 1
		body.queue_free()
		await process_frame
	print("  worst control-point error at REST: %.4f m" % worst_rest)
	print("  worst control-point error MID-GAIT: %.4f m" % worst_gait)
	quit()
