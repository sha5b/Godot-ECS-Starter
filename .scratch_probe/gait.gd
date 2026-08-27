extends SceneTree

func world_of(node: Node3D, root: Node3D) -> Transform3D:
	var x := Transform3D()
	var chain: Array[Node3D] = []
	var cur := node
	while cur != null and cur != root:
		chain.append(cur)
		cur = cur.get_parent() as Node3D
	for i in range(chain.size() - 1, -1, -1):
		x = chain[i].transform * x
	return x

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()

	# ---------- 1. rest pose: do the feet touch the ground? ----------
	print("=== FOOT GROUND CONTACT AT REST (y should be ~0 for every foot) ===")
	var worst := 0.0
	var spread_worst := 0.0
	var n_checked := 0
	for s in range(300):
		rng.seed = s
		var genome := CritterGenome.randomized(rng)
		if genome.leg_pairs() == 0:
			continue
		var root := CritterBodyBuilder.build(genome)
		var lo := INF
		var hi := -INF
		for foot in root.find_children("Foot_*", "MeshInstance3D", true, false):
			var w := world_of(foot, root)
			var half: float = (foot.mesh as SphereMesh).radius * foot.scale.y
			var contact: float = w.origin.y - half
			lo = minf(lo, contact); hi = maxf(hi, contact)
		n_checked += 1
		if s < 6:
			print("  seed %-3d arch=%+.3f segs=%d pairs=%d  lowest foot y=%+.4f highest foot y=%+.4f (spread %.4f)" % [
				s, genome.genes[CritterGenome.GENE_SPINE_ARCH], genome.segment_count(), genome.leg_pairs(), lo, hi, hi - lo])
		worst = maxf(worst, maxf(absf(lo), absf(hi)))
		spread_worst = maxf(spread_worst, hi - lo)
		root.free()
	print("  worst |foot y| over %d legged genomes: %.4f m ; worst front/rear spread: %.4f m" % [n_checked, worst, spread_worst])

	# ---------- 2. knee/hip phase relationship ----------
	print("\n=== GAIT PHASE: is the foot lifted during the FORWARD swing? ===")
	print("  (correct: foot LOW while travelling backward (stance), HIGH while travelling forward)")
	var bad := 0
	var tested := 0
	for s in range(60):
		rng.seed = s
		var genome := CritterGenome.randomized(rng)
		if genome.leg_pairs() == 0:
			continue
		var root := CritterBodyBuilder.build(genome)
		var gait := root.get_node("Gait") as CritterGait
		var foot := root.find_children("Foot_FL", "MeshInstance3D", true, false)[0] as Node3D
		# sample one full stride
		var ys: Array[float] = []
		var zs: Array[float] = []
		var steps := 64
		var cycle: float = float(genome.genes[CritterGenome.GENE_GAIT_CYCLE])
		var dt: float = 1.0 / (cycle * 1.5 * float(steps))   # one full 2pi cycle at sr=1
		for i in steps:
			gait.tick(dt, 1.0)
			var w := world_of(foot, root)
			ys.append(w.origin.y)
			zs.append(w.origin.z)
		# correlation between height and forward velocity
		var num := 0.0
		var ymean := 0.0
		for y in ys: ymean += y
		ymean /= float(steps)
		var vz: Array[float] = []
		for i in steps:
			vz.append(zs[(i + 1) % steps] - zs[i])
		var vmean := 0.0
		for x in vz: vmean += x
		vmean /= float(steps)
		var cov := 0.0
		var sy := 0.0
		var sv := 0.0
		for i in steps:
			cov += (ys[i] - ymean) * (vz[i] - vmean)
			sy += (ys[i] - ymean) * (ys[i] - ymean)
			sv += (vz[i] - vmean) * (vz[i] - vmean)
		var corr := cov / maxf(sqrt(sy * sv), 1e-12)
		tested += 1
		if corr < 0.0:
			bad += 1
		if s < 8:
			print("  seed %-3d corr(foot height, forward velocity) = %+.3f %s" % [s, corr, "  <-- INVERTED (foot lifts on the power stroke)" if corr < 0.0 else ""])
		root.free()
	print("  inverted on %d of %d legged genomes" % [bad, tested])

	# ---------- 3. idle: does the gait rest? ----------
	print("\n=== IDLE (speed_ratio = 0): joints should settle to the rest pose ===")
	rng.seed = 0
	var genome0 := CritterGenome.randomized(rng)
	var root0 := CritterBodyBuilder.build(genome0)
	var gait0 := root0.get_node("Gait") as CritterGait
	var hip0 := root0.find_children("Leg_FL", "Node3D", true, false)[0] as Node3D
	var rest_x: float = hip0.rotation.x
	var amp := 0.0
	for i in 240:
		gait0.tick(1.0 / 60.0, 0.0)
		amp = maxf(amp, absf(hip0.rotation.x - rest_x))
	print("  stride_amp gene = %.3f rad ; max hip deviation from rest at IDLE = %.3f rad (%.1f deg)" % [
		genome0.genes[CritterGenome.GENE_STRIDE_AMP], amp, rad_to_deg(amp)])
	print("  spine_root scale after idle ticks = %s (non-uniform breathing scales the legs too)" % str(root0.get_node("SpineRoot").scale))
	root0.free()

	# ---------- 4. gait re-entrancy: is tick() additive-safe? ----------
	print("\n=== RE-ENTRANCY: two ticks with delta 0 must not drift ===")
	rng.seed = 5
	var g := CritterGenome.randomized(rng)
	var r2 := CritterBodyBuilder.build(g)
	var gt := r2.get_node("Gait") as CritterGait
	var hip := r2.find_children("Leg_FL", "Node3D", true, false)[0] as Node3D
	gt.tick(0.016, 1.0)
	var a := hip.rotation
	gt.tick(0.0, 1.0)
	var b := hip.rotation
	print("  hip rot after tick=%s, after extra zero-delta tick=%s, drift=%.6f" % [a, b, (a - b).length()])
	r2.free()

	# ---------- 5. dead gene range ----------
	print("\n=== stance_height gene ===")
	print("  range is 0.7..1.5 but _build_spine does minf(stance,1.0) -> values above 1.0 are inert (%.0f%% of the gene range is dead)" % (100.0 * 0.5 / 0.8))
	quit()
