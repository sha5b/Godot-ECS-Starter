extends SceneTree

func world_of(node: Node3D, root: Node3D) -> Transform3D:
	var x := Transform3D()
	var chain: Array[Node3D] = []
	var cur := node
	while cur != null and cur != root:
		chain.append(cur); cur = cur.get_parent() as Node3D
	for i in range(chain.size() - 1, -1, -1):
		x = chain[i].transform * x
	return x

func _initialize() -> void:
	var rng := RandomNumberGenerator.new()
	for s in [1, 0, 2]:
		rng.seed = s
		var g := CritterGenome.randomized(rng)
		var root := CritterBodyBuilder.build(g)
		var sr := root.get_node("SpineRoot") as Node3D
		var leg_total: float = float(g.genes[CritterGenome.GENE_LEG_LENGTH]) * CritterBodyBuilder.UNIT_LEG
		var upper := leg_total * 0.55
		var lower := leg_total * 0.5
		var bend: float = float(g.genes[CritterGenome.GENE_KNEE_BEND])
		var splay: float = float(g.genes[CritterGenome.GENE_STANCE_SPLAY])
		var foot_r: float = float(g.genes[CritterGenome.GENE_FOOT_SIZE]) * CritterBodyBuilder.UNIT_FOOT
		var girth_r: float = float(g.genes[CritterGenome.GENE_SEG_GIRTH]) * CritterBodyBuilder.UNIT_SEG_GIRTH
		var stance: float = minf(float(g.genes[CritterGenome.GENE_STANCE_HEIGHT]), 1.0)
		print("--- seed %d: pairs=%d segs=%d leg_total=%.3f upper=%.3f lower=%.3f bend=%.3f splay=%.3f foot_r=%.3f girth_r=%.3f stance=%.2f arch=%.3f" % [
			s, g.leg_pairs(), g.segment_count(), leg_total, upper, lower, bend, splay, foot_r, girth_r, stance, g.genes[CritterGenome.GENE_SPINE_ARCH]])
		print("    spine_root.y = %.4f  (formula reach + foot_r*0.55 + girth_r*0.1)" % sr.position.y)
		for hip in root.find_children("Leg_*", "Node3D", true, false):
			if not hip.name.begins_with("Leg_"): continue
			var knee := hip.get_child(2) if false else hip.get_node("Knee_%s" % hip.name.substr(4))
			var foot := knee.get_node_or_null("Foot_%s" % hip.name.substr(4))
			var wh := world_of(hip, root)
			var wk := world_of(knee, root)
			var wf := world_of(foot, root)
			var half: float = (foot.mesh as SphereMesh).radius * wf.basis.get_scale().y
			print("    %-8s hip.y=%.4f knee.y=%.4f (knee.rot.x=%.3f) foot.y=%.4f half=%.4f  CONTACT y=%+.4f" % [
				hip.name, wh.origin.y, wk.origin.y, knee.rotation.x, wf.origin.y, half, wf.origin.y - half])
		root.free()
	quit()
