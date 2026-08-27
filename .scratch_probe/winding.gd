extends SceneTree

func _initialize() -> void:
	# Establish Godot's front-face winding convention empirically from a
	# built-in primitive whose normals are known-correct (outward).
	for m in [SphereMesh.new(), BoxMesh.new(), CapsuleMesh.new()]:
		var arr: Array = m.get_mesh_arrays()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var agree := 0
		var disagree := 0
		for t in range(0, idx.size(), 3):
			var a := v[idx[t]]
			var b := v[idx[t + 1]]
			var c := v[idx[t + 2]]
			var fn := (b - a).cross(c - a)
			if fn.length() < 1e-12:
				continue
			var vn := (n[idx[t]] + n[idx[t + 1]] + n[idx[t + 2]]) / 3.0
			if fn.normalized().dot(vn.normalized()) > 0.0:
				agree += 1
			else:
				disagree += 1
		print("%s: cross(B-A,C-A) agrees with vertex normal on %d tris, disagrees on %d" % [m.get_class(), agree, disagree])
	quit()
