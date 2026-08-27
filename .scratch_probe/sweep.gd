extends SceneTree

const RADIAL := 10

var issues := {}

func note(key: String, detail: String) -> void:
	if not issues.has(key):
		issues[key] = {"count": 0, "examples": []}
	issues[key]["count"] += 1
	if issues[key]["examples"].size() < 4:
		issues[key]["examples"].append(detail)

func analyze(torso: CritterTorso, tag: String) -> void:
	var mesh := torso.mesh_instance.mesh as ArrayMesh
	if mesh == null:
		note("no_mesh", tag)
		return
	var arr: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]

	# --- vertex sanity
	for i in v.size():
		var p := v[i]
		if is_nan(p.x) or is_nan(p.y) or is_nan(p.z) or is_inf(p.x) or is_inf(p.y) or is_inf(p.z):
			note("nan_vertex", "%s v[%d]=%s" % [tag, i, p])
			break
	for i in n.size():
		var nn := n[i]
		if is_nan(nn.x) or is_nan(nn.y) or is_nan(nn.z):
			note("nan_normal", "%s n[%d]" % [tag, i]); break
		if nn.length() < 0.5:
			note("degenerate_normal", "%s n[%d]=%s len=%.4f" % [tag, i, nn, nn.length()])
			break

	# --- ring structure
	var ring_count := 0
	# rings occupy the first ring_count*RADIAL vertices; caps are 2 extra verts
	ring_count = int((v.size() - 2) / RADIAL)

	# collapsed rings (all verts at the same place)
	for r in ring_count:
		var c := Vector3.ZERO
		for k in RADIAL:
			c += v[r * RADIAL + k]
		c /= float(RADIAL)
		var rad_min := INF
		var rad_max := 0.0
		for k in RADIAL:
			var d := (v[r * RADIAL + k] - c).length()
			rad_min = minf(rad_min, d); rad_max = maxf(rad_max, d)
		if rad_min < 1e-5:
			note("collapsed_ring_vertex", "%s ring %d rmin=%.6f" % [tag, r, rad_min])
			break
		if rad_max > 0.0 and rad_min / rad_max < 0.5:
			note("non_circular_ring", "%s ring %d rmin/rmax=%.3f" % [tag, r, rad_min / rad_max])
			break

	# --- winding: walls vs caps, using Godot's convention
	# (front face => cross(B-A,C-A) points OPPOSITE the outward vertex normal)
	var wall_tris := (ring_count - 1) * RADIAL * 2
	var wall_bad := 0
	var wall_zero := 0
	var cap_bad := 0
	var cap_tris := 0
	var ti := 0
	for t in range(0, idx.size(), 3):
		var a := v[idx[t]]; var b := v[idx[t + 1]]; var c := v[idx[t + 2]]
		var fn := (b - a).cross(c - a)
		var is_wall := ti < wall_tris
		if fn.length() < 1e-10:
			if is_wall: wall_zero += 1
			ti += 1
			continue
		var vn := (n[idx[t]] + n[idx[t + 1]] + n[idx[t + 2]])
		if vn.length() < 1e-6:
			ti += 1
			continue
		var d := fn.normalized().dot(vn.normalized())
		if is_wall:
			if d > 0.0: wall_bad += 1
		else:
			cap_tris += 1
			if d > 0.0: cap_bad += 1
		ti += 1
	if wall_bad > 0:
		note("wall_winding_inverted", "%s %d/%d wall tris back-facing" % [tag, wall_bad, wall_tris])
	if wall_zero > 0:
		note("wall_zero_area_tris", "%s %d zero-area wall tris" % [tag, wall_zero])
	if cap_bad > 0:
		note("cap_winding_inverted", "%s %d/%d cap tris back-facing" % [tag, cap_bad, cap_tris])

	# --- adjacent ring twist pop: compare vertex k of ring r and r+1
	for r in range(ring_count - 1):
		var seg := 0.0
		var cen_a := Vector3.ZERO; var cen_b := Vector3.ZERO
		for k in RADIAL:
			cen_a += v[r * RADIAL + k]; cen_b += v[(r + 1) * RADIAL + k]
		cen_a /= float(RADIAL); cen_b /= float(RADIAL)
		var spacing := (cen_b - cen_a).length()
		var maxd := 0.0
		for k in RADIAL:
			maxd = maxf(maxd, (v[(r + 1) * RADIAL + k] - v[r * RADIAL + k]).length())
		var ravg := 0.0
		for k in RADIAL:
			ravg += (v[r * RADIAL + k] - cen_a).length()
		ravg /= float(RADIAL)
		if maxd > spacing + ravg * 1.5:
			note("ring_twist_pop", "%s rings %d-%d spacing=%.4f maxvertdist=%.4f r=%.4f" % [tag, r, r + 1, spacing, maxd, ravg])
			break

	# --- centerline reversal (spline overshoot / backtracking)
	var prev_dir := Vector3.ZERO
	for r in range(ring_count - 1):
		var ca := Vector3.ZERO; var cb := Vector3.ZERO
		for k in RADIAL:
			ca += v[r * RADIAL + k]; cb += v[(r + 1) * RADIAL + k]
		ca /= float(RADIAL); cb /= float(RADIAL)
		var d := cb - ca
		if d.length() < 1e-6:
			note("zero_length_spline_segment", "%s rings %d-%d" % [tag, r, r + 1])
			break
		var dir := d.normalized()
		if prev_dir != Vector3.ZERO and prev_dir.dot(dir) < 0.0:
			note("centerline_reversal", "%s at ring %d dot=%.3f" % [tag, r, prev_dir.dot(dir)])
			break
		prev_dir = dir

	# --- self intersection proxy: non adjacent ring centers closer than sum of radii
	var centers: Array[Vector3] = []
	var rads: Array[float] = []
	for r in ring_count:
		var c := Vector3.ZERO
		for k in RADIAL:
			c += v[r * RADIAL + k]
		c /= float(RADIAL)
		var rr := 0.0
		for k in RADIAL:
			rr += (v[r * RADIAL + k] - c).length()
		centers.append(c); rads.append(rr / float(RADIAL))
	for i in ring_count:
		var hit := false
		for j in range(i + 4, ring_count):
			if (centers[i] - centers[j]).length() < (rads[i] + rads[j]) * 0.5:
				note("tube_self_overlap", "%s rings %d,%d dist=%.4f radsum=%.4f" % [tag, i, j, (centers[i] - centers[j]).length(), rads[i] + rads[j]])
				hit = true
				break
		if hit: break

func describe_controls(torso: CritterTorso, tag: String) -> String:
	var s := ""
	var prev := Vector3.INF
	for i in torso.controls.size():
		var p: Vector3 = torso._control_position(i)
		var r: float = torso.controls[i]["radius"]
		var node: Node3D = torso.controls[i]["node"]
		var gap := 0.0 if prev == Vector3.INF else (p - prev).length()
		s += "  [%02d] %-8s pos=(%6.3f,%6.3f,%6.3f) r=%.4f gap=%.4f%s\n" % [i, node.name, p.x, p.y, p.z, r, gap, "   <-- GAP < RADIUS" if (gap > 0.0 and gap < r) else ""]
		prev = p
	return s

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	var detail_printed := 0
	for s in range(200):
		rng.seed = s
		var genome := CritterGenome.randomized(rng)
		var root := CritterBodyBuilder.build(genome)
		var gait := root.get_node("Gait") as CritterGait
		var torso := gait.get_torso()
		analyze(torso, "seed%d/rest" % s)
		for step in 24:
			gait.tick(1.0 / 30.0, 1.0 if step % 2 == 0 else 0.4)
			analyze(torso, "seed%d/step%d" % [s, step])
		if s < 3:
			print("=== genome seed %d: segs=%d tail=%d legs=%d wings=%s ===" % [s, genome.segment_count(), genome.tail_segment_count(), genome.leg_pairs(), genome.has_wings()])
			print(describe_controls(torso, "seed%d" % s))
		root.free()
	print("\n===== ISSUE SUMMARY over 200 genomes x 25 poses =====")
	var keys := issues.keys()
	keys.sort()
	for k in keys:
		print("%-28s count=%d" % [k, issues[k]["count"]])
		for e in issues[k]["examples"]:
			print("      e.g. ", e)
	quit()
