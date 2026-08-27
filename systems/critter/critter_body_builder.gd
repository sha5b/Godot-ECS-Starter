class_name CritterBodyBuilder
extends RefCounted

## Turns a CritterGenome into a rigged Node3D body (view layer only).
##
## Spore approach: the rig is a plain joint chain (spine segments, head,
## tail, hips/knees, wings) carrying rest angles from the genome, and the
## BODY LINE is one continuous swept tube (CritterTorso) from tail tip to
## snout tip — no separate blob meshes that can gap apart. Limbs blend in
## with shoulder bulges that overlap the tube surface. CritterGait adds
## gait angles on top and re-skins the tube, so the whole body flexes.
##
## Tree-independent (buildable and testable headless) and survives
## Node.duplicate(), which is what the FaunaSystem spawn path needs.
##
## Facing convention: forward is +Z (matches FaunaSystem's
## atan2(dir.x, dir.z) heading math). Left side is +X.

## Gene values are multipliers against these base units (world meters).
const UNIT_SEG_LENGTH := 0.42
const UNIT_SEG_GIRTH := 0.28
const UNIT_HEAD_SIZE := 0.30
const UNIT_SNOUT := 0.30
const UNIT_EAR := 0.30
const UNIT_HORN := 0.35
const UNIT_LEG := 0.55
const UNIT_LEG_GIRTH := 0.06
const UNIT_FOOT := 0.6
const UNIT_TAIL := 0.22
const UNIT_WING := 0.5

const GROUP_BODY := &"critter_body"
const GROUP_SPINE := &"critter_spine"
const GROUP_HIP := &"critter_hip"
const GROUP_KNEE := &"critter_knee"
const GROUP_TAIL := &"critter_tail"
const GROUP_HEAD := &"critter_head"
const GROUP_WING := &"critter_wing"


## Build a complete rigged critter. Returns the "Critter" root with a
## "Gait" (CritterGait) child already set up — nothing else to call.
static func build(genome: CritterGenome) -> Node3D:
	var root := Node3D.new()
	root.name = "Critter"
	root.add_to_group(GROUP_BODY)

	var palette := _build_palette(genome)
	var joints: Dictionary = {}

	var spine_root := _build_spine(genome, joints)
	root.add_child(spine_root)
	_build_head(genome, palette, spine_root, joints)
	_build_legs(genome, palette, spine_root, joints)
	_build_tail(genome, spine_root, joints)
	if genome.has_wings():
		_build_wings(genome, palette, spine_root, joints)
	_assemble_torso(genome, palette, spine_root, joints)
	_build_spots(genome, palette, joints)

	var gait := CritterGait.new()
	gait.name = "Gait"
	gait.setup(genome, joints)
	root.add_child(gait)
	return root


# ── Palette ───────────────────────────────────────────────────────────────────

static func _build_palette(genome: CritterGenome) -> Dictionary:
	var hue: float = float(genome.genes[CritterGenome.GENE_HUE])
	var sat: float = float(genome.genes[CritterGenome.GENE_SAT])
	var val: float = float(genome.genes[CritterGenome.GENE_VAL])
	var belly_light: float = float(genome.genes[CritterGenome.GENE_BELLY_LIGHT])

	var base_color := Color.from_hsv(hue, sat, val)
	var belly_color := Color.from_hsv(hue, sat * 0.65, clampf(val + belly_light, 0.0, 1.0))
	var accent_color := Color.from_hsv(hue, clampf(sat * 1.05, 0.0, 1.0), val * 0.5)

	var flat := func(color: Color) -> StandardMaterial3D:
		var material := StandardMaterial3D.new()
		material.roughness = 1.0
		material.albedo_color = color
		return material

	return {
		"base_color": base_color,
		"belly_color": belly_color,
		"accent_color": accent_color,
		"base": flat.call(base_color),
		"belly": flat.call(belly_color),
		"accent": flat.call(accent_color),
		"eye": flat.call(Color(0.06, 0.05, 0.04)),
	}


# ── Torso ─────────────────────────────────────────────────────────────────────

## Spine chain: S0 (rear, tail side) .. Sn-1 (front, head side), curved by
## the spine_arch gene, tapered by the taper gene. Joints only — the
## surface comes from the swept torso tube in _assemble_torso.
static func _build_spine(genome: CritterGenome, joints: Dictionary) -> Node3D:
	var count := genome.segment_count()
	var seg_len: float = float(genome.genes[CritterGenome.GENE_SEG_LENGTH]) * UNIT_SEG_LENGTH
	var girth_r: float = float(genome.genes[CritterGenome.GENE_SEG_GIRTH]) * UNIT_SEG_GIRTH
	var taper: float = float(genome.genes[CritterGenome.GENE_TAPER])
	var arch: float = float(genome.genes[CritterGenome.GENE_SPINE_ARCH])

	var spine_root := Node3D.new()
	spine_root.name = "SpineRoot"
	# Stance: solve the leg chain exactly so the feet REST on the ground
	# plane. A stance below 1 crouches by bending the knee further; legs
	# never stretch past the genome's rest bend, so feet can't float or
	# sink no matter what mutation produced.
	if genome.leg_pairs() > 0:
		var leg_total: float = float(genome.genes[CritterGenome.GENE_LEG_LENGTH]) * UNIT_LEG
		var upper_len := leg_total * 0.55
		var lower_len := leg_total * 0.5
		var bend: float = float(genome.genes[CritterGenome.GENE_KNEE_BEND])
		var splay: float = float(genome.genes[CritterGenome.GENE_STANCE_SPLAY])
		var foot_r: float = float(genome.genes[CritterGenome.GENE_FOOT_SIZE]) * UNIT_FOOT
		var reach_full := (upper_len + lower_len * cos(bend)) * cos(splay)
		var stance: float = minf(float(genome.genes[CritterGenome.GENE_STANCE_HEIGHT]), 1.0)
		var desired := reach_full * stance
		var cos_eff: float = (desired / maxf(cos(splay), 0.001) - upper_len) / maxf(lower_len, 0.001)
		var bend_eff := bend
		if cos_eff > -1.0 and cos_eff < 1.0:
			bend_eff = maxf(bend, acos(cos_eff))
		var reach := (upper_len + lower_len * cos(bend_eff)) * cos(splay)
		joints["knee_bend_effective"] = bend_eff
		# Hips sit seg radius * 0.1 below the spine node; the squashed foot
		# sphere's half-height is the contact patch.
		spine_root.position.y = reach + foot_r * 0.55 + girth_r * 0.1
	else:
		spine_root.position.y = girth_r * 0.9

	var segments: Array[Node3D] = []
	var radii: Array[float] = []
	for i in count:
		var seg := Node3D.new()
		seg.name = "S%d" % i
		seg.add_to_group(GROUP_SPINE)
		var t := float(i) / maxf(float(count - 1), 1.0)
		# The chain hangs each segment off the previous one (so the spine
		# wave carries through), which means local offsets must be one STEP
		# each — absolute centered offsets compound through the chain and
		# bunch the body toward the rear. S0 starts at the rear of a
		# body-length centered on the spine root.
		if i > 0:
			seg.position.z = seg_len
			segments[i - 1].add_child(seg)
		else:
			seg.position.z = -(float(count) - 1.0) * 0.5 * seg_len
			spine_root.add_child(seg)
		seg.rotation.x = -arch * 1.5 / float(count)
		radii.append(girth_r * (1.0 + taper * (t - 0.5)))
		segments.append(seg)

	joints["spine_root"] = spine_root
	joints["spine"] = segments
	joints["spine_radii"] = radii
	return spine_root


## Sweep the continuous torso: tail tip → tail chain → spine → neck →
## skull → snout tip. One mesh, painted with the coat genes.
static func _assemble_torso(genome: CritterGenome, palette: Dictionary, spine_root: Node3D, joints: Dictionary) -> void:
	var instance := MeshInstance3D.new()
	instance.name = "Torso"
	var material := StandardMaterial3D.new()
	material.roughness = 1.0
	material.vertex_color_use_as_albedo = true
	instance.material_override = material
	spine_root.add_child(instance)

	var torso := CritterTorso.new()
	torso.setup(spine_root, instance)
	torso.base_color = palette["base_color"]
	torso.belly_color = palette["belly_color"]
	torso.accent_color = palette["accent_color"]
	torso.accent_amount = float(genome.genes[CritterGenome.GENE_ACCENT_AMOUNT])
	if genome.coat_pattern() == CritterGenome.CoatPattern.STRIPES:
		torso.stripe_count = maxi(genome.segment_count() * 2, 3)

	# Tail line, tip first so the radius grows toward the body.
	var tail: Array[Node3D] = joints.get("tail", [])
	var girth_r: float = float(genome.genes[CritterGenome.GENE_SEG_GIRTH]) * UNIT_SEG_GIRTH
	var tail_len: float = float(genome.genes[CritterGenome.GENE_TAIL_LENGTH]) * UNIT_TAIL
	if not tail.is_empty():
		torso.add_control(tail[tail.size() - 1], Vector3(0.0, 0.0, -tail_len * 0.95), 0.015)
		for i in range(tail.size() - 1, -1, -1):
			var radius := girth_r * lerpf(0.08, 0.5, float(i) / float(tail.size()))
			torso.add_control(tail[i], Vector3.ZERO, radius)

	# Torso line, rear to front.
	var segments: Array[Node3D] = joints["spine"]
	var radii: Array[float] = joints["spine_radii"]
	for i in segments.size():
		torso.add_control(segments[i], Vector3.ZERO, radii[i])

	# Head line: neck → skull → snout, so the face melts out of the body.
	var head: Node3D = joints["head"]
	var skull_r: float = float(genome.genes[CritterGenome.GENE_HEAD_SIZE]) * UNIT_HEAD_SIZE
	var snout_len: float = float(genome.genes[CritterGenome.GENE_SNOUT_LENGTH]) * UNIT_SNOUT
	var snout_pivot := head.get_node("Snout") as Node3D
	var neck_r := lerpf(radii[radii.size() - 1], skull_r, 0.55)
	torso.add_control(head, Vector3.ZERO, neck_r)
	torso.add_control(head, Vector3(0.0, skull_r * 0.2, skull_r * 0.45), skull_r)
	if snout_pivot != null:
		torso.add_control(snout_pivot, Vector3.ZERO, skull_r * 0.5)
		torso.add_control(snout_pivot, Vector3(0.0, 0.0, snout_len + skull_r * 0.15), skull_r * 0.16)

	torso.reskin()
	joints["torso"] = torso


# ── Head ──────────────────────────────────────────────────────────────────────

## Head parts (eyes, ears, horns, nose) ride the Head joint; the skull and
## snout surfaces belong to the torso sweep.
static func _build_head(genome: CritterGenome, palette: Dictionary, spine_root: Node3D, joints: Dictionary) -> void:
	var segments: Array[Node3D] = joints["spine"]
	var seg_len: float = float(genome.genes[CritterGenome.GENE_SEG_LENGTH]) * UNIT_SEG_LENGTH
	var front: Node3D = segments[segments.size() - 1]
	var skull_r: float = float(genome.genes[CritterGenome.GENE_HEAD_SIZE]) * UNIT_HEAD_SIZE

	var head := Node3D.new()
	head.name = "Head"
	head.add_to_group(GROUP_HEAD)
	head.position = Vector3(0.0, skull_r * 0.25, seg_len * 0.45 + skull_r * 0.55)
	front.add_child(head)

	# Snout pivot only — the capsule surface is swept by the torso.
	var snout_len: float = float(genome.genes[CritterGenome.GENE_SNOUT_LENGTH]) * UNIT_SNOUT
	var droop: float = float(genome.genes[CritterGenome.GENE_SNOUT_DROOP])
	var snout_pivot := Node3D.new()
	snout_pivot.name = "Snout"
	snout_pivot.position = Vector3(0.0, -skull_r * 0.1, skull_r * 0.6)
	snout_pivot.rotation.x = droop
	head.add_child(snout_pivot)
	var nose := _sphere(skull_r * 0.2, palette["belly"])
	nose.position = Vector3(0.0, 0.0, snout_len + skull_r * 0.2)
	snout_pivot.add_child(nose)

	# Eyes sit ON the swept skull surface. The torso sweep is the real
	# surface — rigid offsets inside the skull radius end up buried
	# (invisible) or floating beside the face depending on genes. The skull
	# control rides the head at (0, 0.2, 0.45) * skull_r with tube radius
	# skull_r; nesting each eye sphere ~45% into that surface keeps it
	# visible and attached for every gene combination.
	var eye_r: float = float(genome.genes[CritterGenome.GENE_EYE_SIZE])
	var eye_count := genome.eye_count()
	var skull_axis := Vector3(0.0, skull_r * 0.2, skull_r * 0.45)
	for side in [-1.0, 1.0]:
		var row := 0
		while row * 2 < eye_count:
			var r := eye_r * (1.0 - 0.2 * float(row))
			var dir := Vector3(
				side * 0.78,
				0.55 + 0.25 * float(row),
				0.40 - 0.22 * float(row)).normalized()
			var eye := _sphere(r, palette["eye"])
			eye.name = "Eye_%d%s" % [row, "L" if side > 0.0 else "R"]
			eye.position = skull_axis + dir * (skull_r - r * 0.45)
			head.add_child(eye)
			row += 1

	# Ears — cones tilted outward by the ear_angle gene.
	var ear_len: float = float(genome.genes[CritterGenome.GENE_EAR_SIZE]) * UNIT_EAR
	if ear_len > 0.02:
		var ear_angle: float = float(genome.genes[CritterGenome.GENE_EAR_ANGLE])
		for side in [-1.0, 1.0]:
			var ear := MeshInstance3D.new()
			ear.name = "Ear%s" % ("L" if side > 0.0 else "R")
			var ear_mesh := CylinderMesh.new()
			ear_mesh.top_radius = ear_len * 0.15
			ear_mesh.bottom_radius = ear_len * 0.35
			ear_mesh.height = ear_len
			ear.mesh = ear_mesh
			ear.material_override = palette["base"]
			ear.position = Vector3(side * skull_r * 0.55, skull_r * 0.8, -skull_r * 0.15)
			ear.rotation.z = -side * (0.35 + ear_angle)
			head.add_child(ear)

	# Horns — accent-colored cones when the gene is expressed.
	var horn_len: float = float(genome.genes[CritterGenome.GENE_HORN_SIZE]) * UNIT_HORN
	if horn_len > 0.03:
		for side in [-1.0, 1.0]:
			var horn := MeshInstance3D.new()
			horn.name = "Horn%s" % ("L" if side > 0.0 else "R")
			var horn_mesh := CylinderMesh.new()
			horn_mesh.top_radius = horn_len * 0.08
			horn_mesh.bottom_radius = horn_len * 0.22
			horn_mesh.height = horn_len
			horn.mesh = horn_mesh
			horn.material_override = palette["accent"]
			horn.position = Vector3(side * skull_r * 0.35, skull_r * 0.85, -skull_r * 0.25)
			horn.rotation.z = -side * 0.45
			head.add_child(horn)

	joints["head"] = head


# ── Legs ──────────────────────────────────────────────────────────────────────

## Hip joints live on spine segments (so the spine wave carries them).
## Attachment follows a limb zone — the middle ~20%..80% of the spine,
## evenly divided between pairs. Real tetrapods anchor forelimbs at the
## shoulder and hindlimbs at the pelvis, clear of the neck and tail; legs
## on the head-bearing or tail-bearing segment, or two pairs bunched on
## adjacent segments of a short body, read as misplaced.
static func _limb_zone_segment(t: float, count: int) -> int:
	var idx := int(round(t * float(count - 1)))
	# Keep one segment clear of the head (front) and tail (rear) anchors
	# whenever the body is long enough to afford it.
	if count >= 4:
		return clampi(idx, 1, count - 2)
	return clampi(idx, 0, count - 1)


static func _build_legs(genome: CritterGenome, palette: Dictionary, spine_root: Node3D, joints: Dictionary) -> void:
	var pairs := genome.leg_pairs()
	if pairs <= 0:
		joints["hips"] = [] as Array[Node3D]
		joints["knees"] = [] as Array[Node3D]
		joints["hip_meta"] = [] as Array[Dictionary]
		return
	var segments: Array[Node3D] = joints["spine"]
	var radii: Array[float] = joints["spine_radii"]
	var count := segments.size()

	var leg_total: float = float(genome.genes[CritterGenome.GENE_LEG_LENGTH]) * UNIT_LEG
	var upper_len := leg_total * 0.55
	var lower_len := leg_total * 0.5
	var leg_r: float = float(genome.genes[CritterGenome.GENE_LEG_GIRTH]) * UNIT_LEG_GIRTH
	# Stance solver may have deepened the knee bend so the feet reach the
	# ground — the rig must use the solved angle, not the raw gene.
	var bend: float = float(joints.get("knee_bend_effective",
		float(genome.genes[CritterGenome.GENE_KNEE_BEND])))
	var splay: float = float(genome.genes[CritterGenome.GENE_STANCE_SPLAY])
	var foot_r: float = float(genome.genes[CritterGenome.GENE_FOOT_SIZE]) * UNIT_FOOT

	var hips: Array[Node3D] = []
	var knees: Array[Node3D] = []
	var hip_meta: Array[Dictionary] = []
	# Order [FL, FR, RL, RR] — CritterGait's phase table expects this.
	# A single pair rides mid-body (under the center of mass).
	var slots: Array = []
	if pairs > 1:
		slots = [
			["F", 0, _limb_zone_segment(0.78, count), 1.0],
			["F", 1, _limb_zone_segment(0.78, count), -1.0],
			["R", 0, _limb_zone_segment(0.22, count), 1.0],
			["R", 1, _limb_zone_segment(0.22, count), -1.0],
		]
	else:
		var biped := _limb_zone_segment(0.62, count)
		slots = [["F", 0, biped, 1.0], ["F", 1, biped, -1.0]]

	for slot in slots:
		var tag: String = str(slot[0]) + ("L" if float(slot[3]) > 0.0 else "R")
		var seg: Node3D = segments[int(slot[2])]
		var seg_r: float = radii[int(slot[2])]
		var side: float = float(slot[3])

		var hip := Node3D.new()
		hip.name = "Leg_%s" % tag
		hip.add_to_group(GROUP_HIP)
		hip.position = Vector3(side * (seg_r + leg_r * 0.2), -seg_r * 0.1, 0.0)
		hip.rotation.z = side * splay
		seg.add_child(hip)

		# Shoulder bulge — blends the limb into the torso surface.
		var shoulder := _sphere(leg_r * 2.6, palette["base"])
		shoulder.name = "Shoulder_%s" % tag
		shoulder.position = Vector3(-side * leg_r * 0.8, leg_r * 1.2, 0.0)
		hip.add_child(shoulder)

		var upper := MeshInstance3D.new()
		var upper_mesh := CapsuleMesh.new()
		upper_mesh.radius = leg_r
		upper_mesh.height = upper_len
		upper.mesh = upper_mesh
		upper.material_override = palette["base"]
		upper.position = Vector3(0.0, -upper_len * 0.5, 0.0)
		hip.add_child(upper)

		var knee := Node3D.new()
		knee.name = "Knee_%s" % tag
		knee.add_to_group(GROUP_KNEE)
		knee.position = Vector3(0.0, -upper_len, 0.0)
		knee.rotation.x = bend
		hip.add_child(knee)

		var lower := MeshInstance3D.new()
		var lower_mesh := CapsuleMesh.new()
		lower_mesh.radius = leg_r * 0.75
		lower_mesh.height = lower_len
		lower.mesh = lower_mesh
		lower.material_override = palette["base"]
		lower.position = Vector3(0.0, -lower_len * 0.5, 0.0)
		knee.add_child(lower)

		var foot := _sphere(foot_r, palette["belly"])
		foot.name = "Foot_%s" % tag
		foot.scale = Vector3(1.0, 0.55, 1.3)
		foot.position = Vector3(0.0, -lower_len, 0.02)
		knee.add_child(foot)

		hips.append(hip)
		knees.append(knee)
		hip_meta.append({"pair": int(slot[1]), "side": int(side), "tag": tag})

	joints["hips"] = hips
	joints["knees"] = knees
	joints["hip_meta"] = hip_meta


# ── Tail & wings ──────────────────────────────────────────────────────────────

## Tail joints only — the tail surface is part of the torso sweep.
static func _build_tail(genome: CritterGenome, spine_root: Node3D, joints: Dictionary) -> void:
	var count := genome.tail_segment_count()
	var tail: Array[Node3D] = []
	if count > 0:
		var segments: Array[Node3D] = joints["spine"]
		var rear: Node3D = segments[0]
		var seg_len: float = float(genome.genes[CritterGenome.GENE_TAIL_LENGTH]) * UNIT_TAIL
		var droop: float = float(genome.genes[CritterGenome.GENE_TAIL_DROOP])
		var parent := rear
		for i in count:
			var joint := Node3D.new()
			joint.name = "Tail%d" % i
			joint.add_to_group(GROUP_TAIL)
			joint.position = Vector3(0.0, 0.0, -seg_len)
			joint.rotation.x = -droop / float(count)
			parent.add_child(joint)
			parent = joint
			tail.append(joint)
	joints["tail"] = tail


## Wings are named WingL/WingR so FaunaSystem's existing flying-fauna flap
## animation drives them unchanged once deployed there. A blend bulge at
## the shoulder keeps them rooted in the body.
static func _build_wings(genome: CritterGenome, palette: Dictionary, spine_root: Node3D, joints: Dictionary) -> void:
	var segments: Array[Node3D] = joints["spine"]
	var radii: Array[float] = joints["spine_radii"]
	var attach_idx := maxi(segments.size() - 2, 0)
	var attach: Node3D = segments[attach_idx]
	var seg_r: float = radii[attach_idx]
	var span: float = float(genome.genes[CritterGenome.GENE_WING_SPAN]) * UNIT_WING
	var chord := span * 0.45

	for side in [-1.0, 1.0]:
		var anchor := Vector3(side * seg_r * 0.6, seg_r * 0.35, 0.0)
		var blend := _sphere(seg_r * 0.5, palette["base"])
		blend.position = anchor
		attach.add_child(blend)

		var wing := Node3D.new()
		wing.name = "Wing%s" % ("L" if side > 0.0 else "R")
		wing.add_to_group(GROUP_WING)
		wing.position = anchor
		attach.add_child(wing)
		var membrane := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(span, 0.025, chord)
		membrane.mesh = box
		membrane.material_override = palette["accent"]
		membrane.position = Vector3(side * span * 0.5, 0.0, 0.0)
		wing.add_child(membrane)
		if side > 0.0:
			joints["wing_l"] = wing
		else:
			joints["wing_r"] = wing


# ── Coat spots ────────────────────────────────────────────────────────────────

## Accent blobs on the back for the SPOTS coat pattern (stripes are vertex
## colors painted by the torso sweep). Spots come in mirrored left/right
## pairs — bilaterians mirror their surface features across the midline,
## and a random one-sided blob reads as an orphaned limb.
static func _build_spots(genome: CritterGenome, palette: Dictionary, joints: Dictionary) -> void:
	if genome.coat_pattern() != CritterGenome.CoatPattern.SPOTS:
		return
	if float(genome.genes[CritterGenome.GENE_ACCENT_AMOUNT]) < 0.3:
		return
	var segments: Array[Node3D] = joints["spine"]
	var radii: Array[float] = joints["spine_radii"]
	var rng := RandomNumberGenerator.new()
	rng.seed = genome.seed_value ^ 0x5EEd
	var spot_count := 2 + (rng.randi() % 3)
	for i in spot_count:
		var index := rng.randi() % segments.size()
		var radius := float(radii[index])
		var offset := rng.randf_range(0.25, 0.75)
		var lift := rng.randf_range(0.55, 0.9)
		var z_jitter := rng.randf_range(-0.45, 0.45)
		for side in [-1.0, 1.0]:
			var spot := _sphere(radius * 0.3, palette["accent"])
			spot.name = "Spot_%d%s" % [i, "L" if side > 0.0 else "R"]
			# Nest into the segment's tube surface (same rule as the eyes)
			# so accent blobs never float beside or sink under the coat.
			var dir := Vector3(side * offset, lift, z_jitter).normalized()
			spot.position = dir * (radius * 0.88)
			segments[index].add_child(spot)


# ── Mesh helpers ──────────────────────────────────────────────────────────────

static func _sphere(radius: float, mat: StandardMaterial3D) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	node.mesh = mesh
	node.material_override = mat
	return node
