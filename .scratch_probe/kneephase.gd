extends SceneTree

## Drive the rig manually with candidate hip/knee formulas and score the
## resulting foot trajectory. Score = corr(foot height, forward velocity):
## a correct gait lifts the foot while it swings FORWARD.

func score(body: Node3D, hips: Array, knees: Array, rest_h: Array, rest_k: Array,
		stride: float, lift: float, knee_shift: float, hip_sign: float) -> float:
	var foot := body.find_children("Foot_FL", "MeshInstance3D", true, false)[0] as Node3D
	var steps := 64
	var ys: Array[float] = []
	var zs: Array[float] = []
	for i in steps:
		var ph := TAU * float(i) / float(steps)
		for j in hips.size():
			var h: Node3D = hips[j]
			var k: Node3D = knees[j]
			var rh: Vector3 = rest_h[j]
			var rk: Vector3 = rest_k[j]
			h.rotation = Vector3(rh.x + hip_sign * sin(ph) * stride, rh.y, rh.z)
			k.rotation = Vector3(rk.x + maxf(0.0, sin(ph + knee_shift)) * lift, rk.y, rk.z)
		await process_frame
		var w: Transform3D = body.global_transform.affine_inverse() * foot.global_transform
		ys.append(w.origin.y); zs.append(w.origin.z)
	var vz: Array[float] = []
	for i in steps: vz.append(zs[(i + 1) % steps] - zs[i])
	var ym := 0.0; var vm := 0.0
	for y in ys: ym += y
	for x in vz: vm += x
	ym /= steps; vm /= steps
	var cov := 0.0; var sy := 0.0; var sv := 0.0
	for i in steps:
		cov += (ys[i] - ym) * (vz[i] - vm); sy += pow(ys[i] - ym, 2); sv += pow(vz[i] - vm, 2)
	return cov / maxf(sqrt(sy * sv), 1e-12)

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	var shifts := [1.1, 1.1 + PI, -1.1, PI / 2.0, PI, 3.0 * PI / 2.0, 0.0]
	var names := ["+1.1 (CURRENT)", "+1.1+PI", "-1.1", "+PI/2", "+PI", "+3PI/2", "0"]
	var totals_pos := []
	var totals_neg := []
	for i in shifts.size():
		totals_pos.append(0.0); totals_neg.append(0.0)
	var n := 0
	for s in range(20):
		rng.seed = s
		var g := CritterGenome.randomized(rng)
		if g.leg_pairs() == 0: continue
		var body := CritterBodyBuilder.build(g)
		root.add_child(body)
		await process_frame
		var hips: Array = body.find_children("Leg_*", "Node3D", true, false)
		var knees: Array = []
		var rh: Array = []
		var rk: Array = []
		for h in hips:
			knees.append(h.get_node("Knee_%s" % h.name.substr(4)))
			rh.append(h.rotation)
		for k in knees: rk.append(k.rotation)
		var stride: float = float(g.genes[CritterGenome.GENE_STRIDE_AMP])
		var lift: float = float(g.genes[CritterGenome.GENE_KNEE_LIFT])
		for i in shifts.size():
			totals_pos[i] += await score(body, hips, knees, rh, rk, stride, lift, shifts[i], 1.0)
			totals_neg[i] += await score(body, hips, knees, rh, rk, stride, lift, shifts[i], -1.0)
		n += 1
		body.queue_free()
		await process_frame
	print("mean corr(foot height, forward velocity) over %d legged genomes" % n)
	print("%-16s %10s %10s" % ["knee phase", "hip +sin", "hip -sin"])
	for i in shifts.size():
		print("%-16s %+10.3f %+10.3f" % [names[i], totals_pos[i] / n, totals_neg[i] / n])
	quit()
