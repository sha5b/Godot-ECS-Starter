extends SceneTree

const RADIAL := 10

func dump(seed_value: int, steps: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var genome := CritterGenome.randomized(rng)
	var root := CritterBodyBuilder.build(genome)
	var gait := root.get_node("Gait") as CritterGait
	var torso := gait.get_torso()
	for i in steps:
		gait.tick(1.0 / 30.0, 1.0)
	print("=== seed %d after %d gait steps | snout_droop=%.3f spine_arch=%.3f tail_segs=%d head_size=%.2f ===" % [
		seed_value, steps, genome.genes[CritterGenome.GENE_SNOUT_DROOP],
		genome.genes[CritterGenome.GENE_SPINE_ARCH], genome.tail_segment_count(),
		genome.genes[CritterGenome.GENE_HEAD_SIZE]])
	print(" controls:")
	for i in torso.controls.size():
		var p: Vector3 = torso._control_position(i)
		print("   [%02d] %-6s pos=(%7.4f,%7.4f,%7.4f) r=%.4f" % [i, torso.controls[i]["node"].name, p.x, p.y, p.z, torso.controls[i]["radius"]])
	var mesh := torso.mesh_instance.mesh as ArrayMesh
	var arr: Array = mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var rc := int((v.size() - 2) / RADIAL)
	var centers: Array[Vector3] = []
	var rads: Array[float] = []
	for r in rc:
		var c := Vector3.ZERO
		for k in RADIAL: c += v[r * RADIAL + k]
		c /= float(RADIAL)
		centers.append(c)
		var rr := 0.0
		for k in RADIAL: rr += (v[r * RADIAL + k] - c).length()
		rads.append(rr / float(RADIAL))
	print(" rings (ctrl idx = ring/3):")
	for r in rc:
		var line := "   ring %02d c=(%7.4f,%7.4f,%7.4f) r=%.4f" % [r, centers[r].x, centers[r].y, centers[r].z, rads[r]]
		if r > 0:
			var d0 := (centers[r] - centers[r - 1])
			line += " step=%.4f" % d0.length()
			if r > 1:
				var dprev := (centers[r - 1] - centers[r - 2]).normalized()
				var dot := dprev.dot(d0.normalized())
				line += " turn=%5.1fdeg" % rad_to_deg(acos(clampf(dot, -1.0, 1.0)))
				if dot < 0.0: line += "  <<< CENTERLINE REVERSES"
		# handedness of the ring loop relative to the local travel direction
		if r < rc - 1:
			var axis := (centers[r + 1] - centers[r]).normalized()
			var e0 := v[r * RADIAL + 0] - centers[r]
			var e1 := v[r * RADIAL + 1] - centers[r]
			var hand := e0.cross(e1).dot(axis)
			if hand < 0.0: line += "  [ring wound BACKWARDS vs travel]"
		print(line)
	# which wall tris are back facing
	var wall_tris := (rc - 1) * RADIAL * 2
	var ti := 0
	var bad := {}
	for t in range(0, idx.size(), 3):
		if ti >= wall_tris: break
		var a := v[idx[t]]; var b := v[idx[t + 1]]; var c := v[idx[t + 2]]
		var fn := (b - a).cross(c - a)
		var vn := n[idx[t]] + n[idx[t + 1]] + n[idx[t + 2]]
		if fn.length() > 1e-12 and fn.normalized().dot(vn.normalized()) > 0.0:
			bad[int(ti / (RADIAL * 2))] = int(bad.get(int(ti / (RADIAL * 2)), 0)) + 1
		ti += 1
	print(" back-facing wall tris per ring-band: ", bad)
	root.free()

func _initialize() -> void:
	dump(0, 0)
	dump(3, 0)
	dump(3, 5)
	quit()
