extends SceneTree

const RADIAL := 10
const SUBDIV := 3

var stats := {}

func bump(key: String, detail: String) -> void:
	if not stats.has(key):
		stats[key] = {"count": 0, "examples": []}
	stats[key]["count"] += 1
	if stats[key]["examples"].size() < 3:
		stats[key]["examples"].append(detail)

func ring_center(v: PackedVector3Array, r: int) -> Vector3:
	var c := Vector3.ZERO
	for k in RADIAL:
		c += v[r * RADIAL + k]
	return c / float(RADIAL)

func ring_radius(v: PackedVector3Array, r: int, c: Vector3) -> float:
	var s := 0.0
	for k in RADIAL:
		s += (v[r * RADIAL + k] - c).length()
	return s / float(RADIAL)

func analyze(torso: CritterTorso, tag: String, verbose: bool) -> void:
	var mesh := torso.mesh_instance.mesh as ArrayMesh
	var arr: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var ring_count := int((v.size() - 2) / RADIAL)

	var centers: Array[Vector3] = []
	var rads: Array[float] = []
	for r in ring_count:
		var c := ring_center(v, r)
		centers.append(c)
		rads.append(ring_radius(v, r, c))

	# ---- pole vertices
	var pole_a := v[ring_count * RADIAL]
	var pole_b := v[ring_count * RADIAL + 1]
	if (pole_b - centers[ring_count - 1]).length() < 1e-6:
		bump("far_cap_pole_degenerate", "%s pole_b == last ring center exactly" % tag)
	if (pole_a - centers[0]).length() < 1e-6:
		bump("near_cap_pole_degenerate", "%s pole_a == first ring center" % tag)
	# is the pole inside the tube? (protrusion smaller than the ring radius)
	var prot_a := (pole_a - centers[0]).length()
	var prot_b := (pole_b - centers[ring_count - 1]).length()
	if prot_a < rads[0]:
		bump("near_cap_flat_or_sunken", "%s protrusion=%.4f ring radius=%.4f" % [tag, prot_a, rads[0]])
	if prot_b < rads[ring_count - 1]:
		bump("far_cap_flat_or_sunken", "%s protrusion=%.4f ring radius=%.4f" % [tag, prot_b, rads[ring_count - 1]])

	# ---- cap winding via geometry (outward = away from the body)
	var wall_tris := (ring_count - 1) * RADIAL * 2
	var out_a := (centers[0] - centers[1]).normalized()
	var out_b := (centers[ring_count - 1] - centers[ring_count - 2]).normalized()
	var cap_bad_a := 0
	var cap_bad_b := 0
	var ti := 0
	var bad_wall_rings := {}
	for t in range(0, idx.size(), 3):
		var a := v[idx[t]]; var b := v[idx[t + 1]]; var c := v[idx[t + 2]]
		var fn := (b - a).cross(c - a)
		if ti < wall_tris:
			if fn.length() > 1e-12:
				var vn := n[idx[t]] + n[idx[t + 1]] + n[idx[t + 2]]
				if fn.normalized().dot(vn.normalized()) > 0.0:
					var ring := int(ti / (RADIAL * 2))
					bad_wall_rings[ring] = int(bad_wall_rings.get(ring, 0)) + 1
		elif ti < wall_tris + RADIAL:
			# near cap: front-facing in Godot => cross points OPPOSITE outward
			if fn.length() > 1e-12 and fn.normalized().dot(out_a) > 0.0:
				cap_bad_a += 1
		else:
			if fn.length() > 1e-12 and fn.normalized().dot(out_b) > 0.0:
				cap_bad_b += 1
		ti += 1
	if cap_bad_a > 0:
		bump("near_cap_backfacing", "%s %d/%d tris" % [tag, cap_bad_a, RADIAL])
	if cap_bad_b > 0:
		bump("far_cap_backfacing", "%s %d/%d tris" % [tag, cap_bad_b, RADIAL])
	if not bad_wall_rings.is_empty():
		var ks := bad_wall_rings.keys(); ks.sort()
		var slope := ""
		for r in ks:
			var sp := (centers[r + 1] - centers[r]).length()
			slope += " ring%d(dr=%.4f,spacing=%.4f,slope=%.2f)" % [r, rads[r + 1] - rads[r], sp, (rads[r + 1] - rads[r]) / maxf(sp, 1e-9)]
		bump("wall_backfacing_at_rings", "%s%s" % [tag, slope])

	# ---- flare: |dr| / spacing > 1 means the surface folds back on itself
	for r in range(ring_count - 1):
		var sp := (centers[r + 1] - centers[r]).length()
		var dr := absf(rads[r + 1] - rads[r])
		if dr > sp:
			bump("surface_folds_back(|dr|>spacing)", "%s rings %d-%d dr=%.4f spacing=%.4f slope=%.2f" % [tag, r, r + 1, dr, sp, dr / maxf(sp, 1e-9)])
			break

	# ---- frame roll between adjacent rings (parallel-transport twist pop)
	var worst_roll := 0.0
	var worst_at := -1
	for r in range(ring_count - 1):
		var axis := (centers[r + 1] - centers[r])
		if axis.length() < 1e-9:
			continue
		axis = axis.normalized()
		var a0 := v[r * RADIAL] - centers[r]
		var b0 := v[(r + 1) * RADIAL] - centers[r + 1]
		a0 = (a0 - axis * a0.dot(axis))
		b0 = (b0 - axis * b0.dot(axis))
		if a0.length() < 1e-9 or b0.length() < 1e-9:
			continue
		var ang := absf(rad_to_deg(a0.normalized().angle_to(b0.normalized())))
		if ang > worst_roll:
			worst_roll = ang; worst_at = r
	if worst_roll > 45.0:
		bump("frame_roll_pop>45deg", "%s %.1f deg between rings %d-%d" % [tag, worst_roll, worst_at, worst_at + 1])
	elif worst_roll > 20.0:
		bump("frame_roll_pop>20deg", "%s %.1f deg between rings %d-%d" % [tag, worst_roll, worst_at, worst_at + 1])

	# ---- fold / self intersection: arc separation exceeds the radii sum but
	#      the rings are still overlapping in space
	var arc: Array[float] = []
	var acc := 0.0
	arc.append(0.0)
	for r in range(ring_count - 1):
		acc += (centers[r + 1] - centers[r]).length()
		arc.append(acc)
	var found := false
	for i in ring_count:
		for j in range(i + 1, ring_count):
			var rs: float = rads[i] + rads[j]
			if arc[j] - arc[i] < rs * 1.2:
				continue
			if (centers[i] - centers[j]).length() < rs * 0.75:
				bump("true_self_intersection", "%s rings %d,%d dist=%.4f radsum=%.4f arc=%.4f" % [tag, i, j, (centers[i] - centers[j]).length(), rs, arc[j] - arc[i]])
				found = true
				break
		if found: break

	if verbose:
		print("  %s: rings=%d radius min=%.4f max=%.4f" % [tag, ring_count, rads.min(), rads.max()])

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	print("--- radius profile of the CONTROL points (rest pose), first 3 seeds ---")
	for s in range(400):
		rng.seed = s
		var genome := CritterGenome.randomized(rng)
		var root := CritterBodyBuilder.build(genome)
		var gait := root.get_node("Gait") as CritterGait
		var torso := gait.get_torso()
		analyze(torso, "s%d/rest" % s, false)
		for step in 20:
			gait.tick(1.0 / 30.0, 1.0)
			analyze(torso, "s%d/st%d" % [s, step], false)
		root.free()
	print("\n===== SUMMARY over 400 genomes x 21 poses (8400 meshes) =====")
	var keys := stats.keys(); keys.sort()
	for k in keys:
		print("%-34s count=%d" % [k, stats[k]["count"]])
		for e in stats[k]["examples"]:
			print("        ", e)
	quit()
