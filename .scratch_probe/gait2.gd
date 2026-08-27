extends SceneTree

const RADIAL := 10
const SUBDIV := 3

# ---------- correct-order re-implementation of the torso sweep ----------
func ctrl_pos(torso: CritterTorso, i: int) -> Vector3:
	var node: Node3D = torso.controls[i]["node"]
	var off: Vector3 = torso.controls[i]["offset"]
	return torso.space.global_transform.affine_inverse() * (node.global_transform * off)

func catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t; var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

func catmull_f(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var t2 := t * t; var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

## Returns [centers, radii] of the corrected sweep
func corrected_sweep(torso: CritterTorso) -> Array:
	var positions: Array[Vector3] = []
	var radii: Array[float] = []
	for i in torso.controls.size():
		positions.append(ctrl_pos(torso, i))
		radii.append(float(torso.controls[i]["radius"]))
	var pts: Array[Vector3] = []
	var prs: Array[float] = []
	for span in positions.size() - 1:
		var i0 := maxi(span - 1, 0)
		var i3 := mini(span + 2, positions.size() - 1)
		for s in SUBDIV:
			var t := float(s) / float(SUBDIV)
			pts.append(catmull(positions[i0], positions[span], positions[span + 1], positions[i3], t))
			var r_min := minf(radii[span], radii[span + 1])
			var r_max := maxf(radii[span], radii[span + 1])
			prs.append(clampf(catmull_f(radii[i0], radii[span], radii[span + 1], radii[i3], t), r_min * 0.75, r_max * 1.1))
	pts.append(positions[positions.size() - 1])
	prs.append(radii[radii.size() - 1])
	return [pts, prs]

var stats := {}
func bump(k: String, d: String) -> void:
	if not stats.has(k): stats[k] = {"c": 0, "e": []}
	stats[k]["c"] += 1
	if stats[k]["e"].size() < 3: stats[k]["e"].append(d)

func check_sweep(pts: Array[Vector3], prs: Array[float], tag: String) -> void:
	var n := pts.size()
	# fold-back: |dr| > spacing means the swept surface turns inside out
	for i in range(n - 1):
		var sp := (pts[i + 1] - pts[i]).length()
		if sp < 1e-9:
			bump("zero_length_segment", "%s at %d" % [tag, i]); break
		if absf(prs[i + 1] - prs[i]) > sp:
			bump("cone_folds_back", "%s seg %d dr=%.4f spacing=%.4f slope=%.2f" % [tag, i, prs[i + 1] - prs[i], sp, (prs[i + 1] - prs[i]) / sp]); break
	# curvature radius smaller than tube radius => self intersecting sweep
	for i in range(1, n - 1):
		var a := (pts[i] - pts[i - 1])
		var b := (pts[i + 1] - pts[i])
		if a.length() < 1e-9 or b.length() < 1e-9: continue
		var ang := a.normalized().angle_to(b.normalized())
		if ang < 1e-6: continue
		var curv_radius := (a.length() + b.length()) * 0.5 / ang
		if curv_radius < prs[i]:
			bump("bend_tighter_than_tube_radius", "%s at %d turn=%.1fdeg curveR=%.4f tubeR=%.4f" % [tag, i, rad_to_deg(ang), curv_radius, prs[i]]); break
	# extreme kink
	for i in range(1, n - 1):
		var a := (pts[i] - pts[i - 1]); var b := (pts[i + 1] - pts[i])
		if a.length() < 1e-9 or b.length() < 1e-9: continue
		if rad_to_deg(a.normalized().angle_to(b.normalized())) > 60.0:
			bump("kink>60deg", "%s at %d %.1f deg" % [tag, i, rad_to_deg(a.normalized().angle_to(b.normalized()))]); break

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()

	# ===== 1. foot ground contact, using the ENGINE's transforms =====
	print("=== FOOT GROUND CONTACT AT REST (engine global_transform) ===")
	var worst := 0.0; var spread := 0.0; var below := 0; var tot := 0
	for s in range(120):
		rng.seed = s
		var g := CritterGenome.randomized(rng)
		if g.leg_pairs() == 0: continue
		var body := CritterBodyBuilder.build(g)
		root.add_child(body)
		await process_frame
		var lo := INF; var hi := -INF
		for foot in body.find_children("Foot_*", "MeshInstance3D", true, false):
			var w: Transform3D = body.global_transform.affine_inverse() * foot.global_transform
			var half: float = (foot.mesh as SphereMesh).radius * 0.55
			var contact: float = w.origin.y - half
			lo = minf(lo, contact); hi = maxf(hi, contact)
		tot += 1
		if lo < -0.02: below += 1
		worst = maxf(worst, maxf(absf(lo), absf(hi)))
		spread = maxf(spread, hi - lo)
		if s < 6:
			print("  seed %-3d arch=%+.3f pairs=%d segs=%d  lowest foot=%+.4f highest foot=%+.4f (spread %.4f)" % [
				s, g.genes[CritterGenome.GENE_SPINE_ARCH], g.leg_pairs(), g.segment_count(), lo, hi, hi - lo])
		body.queue_free()
		await process_frame
	print("  %d of %d legged genomes have a foot >2cm below y=0; worst |offset| %.4f m; worst front/rear spread %.4f m" % [below, tot, worst, spread])

	# ===== 2. knee/hip phase =====
	print("\n=== GAIT PHASE (engine transforms): foot height vs forward velocity ===")
	var badc := 0; var tot2 := 0
	var mean_corr := 0.0
	for s in range(40):
		rng.seed = s
		var g := CritterGenome.randomized(rng)
		if g.leg_pairs() == 0: continue
		var body := CritterBodyBuilder.build(g)
		root.add_child(body)
		var gait := body.get_node("Gait") as CritterGait
		var foot := body.find_children("Foot_FL", "MeshInstance3D", true, false)[0] as Node3D
		var steps := 48
		var cyc: float = float(g.genes[CritterGenome.GENE_GAIT_CYCLE])
		var dt: float = 1.0 / (cyc * 1.5 * float(steps))
		var ys: Array[float] = []; var zs: Array[float] = []
		for i in steps:
			gait.tick(dt, 1.0)
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
		var corr := cov / maxf(sqrt(sy * sv), 1e-12)
		mean_corr += corr
		tot2 += 1
		if corr < 0.35: badc += 1
		if s < 8: print("  seed %-3d corr = %+.3f  (want strongly positive)" % [s, corr])
		body.queue_free()
		await process_frame
	print("  mean corr = %+.3f ; %d of %d genomes below +0.35" % [mean_corr / float(tot2), badc, tot2])

	# ===== 3. corrected sweep: which mesh defects survive the transform fix? =====
	print("\n=== SWEEP GEOMETRY WITH THE TRANSFORM ORDER FIXED ===")
	for s in range(150):
		rng.seed = s
		var g := CritterGenome.randomized(rng)
		var body := CritterBodyBuilder.build(g)
		root.add_child(body)
		var gait := body.get_node("Gait") as CritterGait
		var torso := gait.get_torso()
		await process_frame
		var sw := corrected_sweep(torso)
		check_sweep(sw[0], sw[1], "s%d/rest" % s)
		for step in 8:
			gait.tick(1.0 / 30.0, 1.0)
			await process_frame
			var sw2 := corrected_sweep(torso)
			check_sweep(sw2[0], sw2[1], "s%d/st%d" % [s, step])
		body.queue_free()
		await process_frame
	var keys := stats.keys(); keys.sort()
	print("  (150 genomes x 9 poses = 1350 sweeps)")
	for k in keys:
		print("  %-32s count=%d" % [k, stats[k]["c"]])
		for e in stats[k]["e"]: print("        ", e)

	# ===== 4. tail radius profile direction =====
	print("\n=== TAIL RADIUS PROFILE (should GROW from tip toward the body) ===")
	rng.seed = 0
	var g0 := CritterGenome.randomized(rng)
	var b0 := CritterBodyBuilder.build(g0)
	var t0 := (b0.get_node("Gait") as CritterGait).get_torso()
	for i in t0.controls.size():
		var nm: String = t0.controls[i]["node"].name
		if nm.begins_with("Tail") or nm == "S0":
			print("   control[%d] %-6s radius=%.4f" % [i, nm, t0.controls[i]["radius"]])
	b0.free()
	quit()
