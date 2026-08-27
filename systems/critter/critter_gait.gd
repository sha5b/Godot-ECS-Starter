class_name CritterGait
extends Node

## Procedural animation for a built critter body — the Spore property:
## there are no baked clips anywhere. Every joint angle is evaluated from
## genome gait genes each frame, so a mutated body animates correctly the
## instant it is built.
##
## The controller is additive: the builder captures each joint's rest pose
## (the genome's rest-angle genes) and tick() layers gait angles on top,
## blending to the rest pose at idle. Works detached from the scene tree,
## which keeps it headless-testable.

## Phase offsets (in cycles, 0..1) per gait pattern, hip order [FL, FR, RL, RR].
static func leg_phase_offsets(pattern: int, pairs: int) -> Array[float]:
	if pairs <= 1:
		return [0.0, 0.5]
	match pattern:
		CritterGenome.GaitPattern.TROT:
			return [0.0, 0.5, 0.5, 0.0]
		CritterGenome.GaitPattern.PACE:
			return [0.0, 0.5, 0.0, 0.5]
		CritterGenome.GaitPattern.BOUND:
			return [0.0, 0.0, 0.5, 0.5]
		_:
			return [0.0, 0.5, 0.75, 0.25]

var genome: CritterGenome

var _torso: CritterTorso = null
var _spine_root: Node3D
var _spine: Array[Node3D] = []
var _hips: Array[Node3D] = []
var _knees: Array[Node3D] = []
var _tail: Array[Node3D] = []
var _head: Node3D = null
var _wing_l: Node3D = null
var _wing_r: Node3D = null
var _offsets: Array[float] = []

## instance_id -> {"rot": Vector3, "pos": Vector3} rest pose captured at setup.
var _rest: Dictionary = {}

var _phase := 0.0
var _time := 0.0

## Optional ground query: func(x: float, z: float) -> float returning the
## world surface height, or INF where nothing is loaded. When set, the legs
## are IK-adapted to the terrain after the gait pose is evaluated.
var ground_sampler := Callable()

## Foot nodes and the leg segment lengths the IK solves against, captured
## by the builder alongside the joints.
var _feet: Array[Node3D] = []
var _upper_len := 0.0
var _lower_len := 0.0
var _foot_contact := 0.0
## How much the gait is lifting each leg this tick (0 = planted).
var _leg_lift: Array[float] = []


## Called by CritterBodyBuilder right after construction. Also safe to call
## directly on a rebuilt body.
func setup(source_genome: CritterGenome, joints: Dictionary) -> void:
	genome = source_genome
	_torso = joints.get("torso", null) as CritterTorso
	_spine_root = joints.get("spine_root", null) as Node3D
	_spine = joints.get("spine", []) as Array[Node3D]
	_hips = joints.get("hips", []) as Array[Node3D]
	_knees = joints.get("knees", []) as Array[Node3D]
	_tail = joints.get("tail", []) as Array[Node3D]
	_head = joints.get("head", null) as Node3D
	_wing_l = joints.get("wing_l", null) as Node3D
	_wing_r = joints.get("wing_r", null) as Node3D
	_feet = joints.get("feet", []) as Array[Node3D]
	_upper_len = float(joints.get("upper_len", 0.0))
	_lower_len = float(joints.get("lower_len", 0.0))
	_foot_contact = float(joints.get("foot_contact", 0.0))

	_capture_rest(_spine_root)
	for seg in _spine:
		_capture_rest(seg)
	for hip in _hips:
		_capture_rest(hip)
	for knee in _knees:
		_capture_rest(knee)
	for joint in _tail:
		_capture_rest(joint)
	_capture_rest(_head)
	_capture_rest(_wing_l)
	_capture_rest(_wing_r)

	var pairs := maxi(genome.leg_pairs(), 1)
	var pattern_offsets := leg_phase_offsets(genome.gait_pattern(), pairs)
	_offsets = []
	for i in _hips.size():
		_offsets.append(pattern_offsets[i % pattern_offsets.size()])


## Advance the gait. speed_ratio: 0 = idle, ~0.5 = walk, 1 = run.
func tick(delta: float, speed_ratio: float) -> void:
	if genome == null:
		return
	var sr := clampf(speed_ratio, 0.0, 1.0)
	_time += delta
	var cycle: float = float(genome.genes[CritterGenome.GENE_GAIT_CYCLE])
	_phase += delta * cycle * (0.35 + 1.15 * sr) * TAU
	var ph := _phase

	# Every locomotion amplitude reaches zero at sr = 0, so a standing
	# critter actually holds its rest pose. The old floors (25-50% of full
	# amplitude at idle) left it walking on the spot with sliding feet —
	# and, because a control joint always moved more than reskin's epsilon,
	# they also forced a full torso mesh rebuild every frame for every
	# critter, defeating the change-triggered re-skin entirely.
	# Idle motion is the breathing/sway layer below, and nothing else.
	var stride: float = float(genome.genes[CritterGenome.GENE_STRIDE_AMP]) * sr
	var lift: float = float(genome.genes[CritterGenome.GENE_KNEE_LIFT]) * sr
	var wave: float = float(genome.genes[CritterGenome.GENE_SPINE_WAVE]) * sr
	var bob: float = float(genome.genes[CritterGenome.GENE_HEAD_BOB]) * sr
	var wag: float = float(genome.genes[CritterGenome.GENE_TAIL_WAG]) * sr

	# Legs: hip swings fore/aft, knee lifts during the swing half of the cycle.
	_leg_lift.resize(_hips.size())
	for i in _hips.size():
		var hip := _hips[i]
		var hip_rest := _rest.get(hip.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var hip_rot: Vector3 = hip_rest["rot"]
		var swing := sin(ph + _offsets[i] * TAU)
		hip.rotation = Vector3(hip_rot.x + swing * stride, hip_rot.y, hip_rot.z)

		var knee := _knees[i]
		var knee_rest := _rest.get(knee.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var knee_rot: Vector3 = knee_rest["rot"]
		# Lift the foot during the SWING half of the cycle, not the power
		# half. Positive hip rotation.x swings the leg's -Y axis toward -Z,
		# i.e. backwards (forward is +Z), so the backward power stroke is
		# sin(ph) > 0. Raising on +sin therefore picked the foot up exactly
		# while it should have been pushing, and planted it while it swung
		# forward — the critter moonwalked. Negating puts the lift on the
		# forward swing.
		var raised := maxf(0.0, -sin(ph + _offsets[i] * TAU + 1.1))
		_leg_lift[i] = raised
		knee.rotation = Vector3(knee_rot.x + raised * lift, knee_rot.y, knee_rot.z)

	# Spine: lateral undulation travels rearward; bounders also hop.
	for i in _spine.size():
		var seg := _spine[i]
		var rest := _rest.get(seg.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var rot: Vector3 = rest["rot"]
		seg.rotation = Vector3(
			rot.x + sin(ph * 2.0 - float(i) * 0.4) * 0.02 * sr,
			rot.y + sin(ph - float(i) * 0.55) * wave,
			rot.z)
	if _spine_root != null:
		var root_rest := _rest.get(_spine_root.get_instance_id(), {"pos": Vector3.ZERO}) as Dictionary
		var root_pos: Vector3 = root_rest["pos"]
		var hop_amp := 0.10 if genome.gait_pattern() == CritterGenome.GaitPattern.BOUND else 0.02
		_spine_root.position = Vector3(
			root_pos.x,
			root_pos.y + absf(sin(ph)) * hop_amp * sr,
			root_pos.z)
		# Idle breathing fades out as the critter speeds up. It swells the
		# torso surface only — scaling the spine root instead pushed a
		# non-uniform scale down the whole rig, stretching every leg, foot
		# and head part and shearing the rotated ones.
		if _torso != null and _torso.mesh_instance != null:
			var breathe := 1.0 + sin(_time * 1.6) * 0.02 * (1.0 - sr)
			_torso.mesh_instance.scale = Vector3(breathe, breathe, 1.0)

	# Head bobs at twice the stride frequency.
	if _head != null:
		var rest := _rest.get(_head.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var rot: Vector3 = rest["rot"]
		_head.rotation = Vector3(rot.x + sin(ph * 2.0) * bob, rot.y, rot.z)

	# Tail wags with a rearward-traveling wave.
	for i in _tail.size():
		var joint := _tail[i]
		var rest := _rest.get(joint.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var rot: Vector3 = rest["rot"]
		joint.rotation = Vector3(
			rot.x,
			rot.y + sin(ph * 0.7 - float(i) * 0.5) * wag,
			rot.z)

	# Wings flap at double phase, hovering gently even at idle.
	if _wing_l != null:
		var flap: float = float(genome.genes[CritterGenome.GENE_WING_FLAP])
		var rest := _rest.get(_wing_l.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var rot: Vector3 = rest["rot"]
		var angle := sin(ph * 2.0) * flap
		_wing_l.rotation = Vector3(rot.x, rot.y, rot.z + angle)
	if _wing_r != null:
		var flap: float = float(genome.genes[CritterGenome.GENE_WING_FLAP])
		var rest := _rest.get(_wing_r.get_instance_id(), {"rot": Vector3.ZERO}) as Dictionary
		var rot: Vector3 = rest["rot"]
		var angle := sin(ph * 2.0) * flap
		_wing_r.rotation = Vector3(rot.x, rot.y, rot.z - angle)

	# Plant the feet on the actual ground before the surface is re-skinned.
	if ground_sampler.is_valid():
		_adapt_legs_to_ground()

	# Re-skin the continuous torso so the body surface follows the joints —
	# cheap when nothing moved, a tiny mesh rebuild while walking.
	if _torso != null:
		_torso.reskin_if_moved()


## Terrain-adaptive legs: two-bone IK that puts each planted foot on the
## surface under it.
##
## The gait alone produces one canned stride on a flat plane, so on a slope
## the uphill feet sink into the hill and the downhill feet hang in the air.
## Here each foot's own ground height is sampled and the leg is re-solved to
## reach it — keeping whatever lift the gait asked for, so a swinging foot
## still arcs over the ground instead of dragging along it.
##
## Needs the rig in the scene tree (it reads global transforms); silently
## does nothing otherwise, which keeps headless builds working.
func _adapt_legs_to_ground() -> void:
	if _feet.size() != _hips.size() or _upper_len <= 0.0:
		return
	var reach := _upper_len + _lower_len
	for i in _hips.size():
		var hip := _hips[i]
		var knee := _knees[i]
		var foot := _feet[i]
		if hip == null or knee == null or foot == null or not foot.is_inside_tree():
			continue
		var foot_world := foot.global_position
		var ground: float = ground_sampler.call(foot_world.x, foot_world.z)
		if not is_finite(ground):
			continue
		# Keep the gait's own lift above the terrain, not above the plane.
		var lift_gain: float = _leg_lift[i] * _lower_len * 0.35
		var target_y := ground + _foot_contact + lift_gain
		var target := Vector3(foot_world.x, target_y, foot_world.z)

		# Solve in the hip's parent frame: the hip pitches to aim at the
		# target and the knee closes to match the remaining distance.
		var parent := hip.get_parent() as Node3D
		if parent == null:
			continue
		var local: Vector3 = parent.global_transform.affine_inverse() * target
		local -= hip.position
		var dist := clampf(local.length(),
			absf(_upper_len - _lower_len) + 0.01, reach - 0.01)
		if dist <= 0.001:
			continue
		# Law of cosines for the knee, then aim the whole leg at the target.
		var cos_knee := clampf(
			(_upper_len * _upper_len + _lower_len * _lower_len - dist * dist)
			/ (2.0 * _upper_len * _lower_len), -1.0, 1.0)
		var knee_bend := PI - acos(cos_knee)
		var cos_hip := clampf(
			(_upper_len * _upper_len + dist * dist - _lower_len * _lower_len)
			/ (2.0 * _upper_len * dist), -1.0, 1.0)
		# Leg hangs down -Y; measure the aim angle in the hip's YZ plane.
		var aim := atan2(local.z, -local.y)
		hip.rotation.x = aim - acos(cos_hip)
		knee.rotation.x = knee_bend


## The torso skinner this gait re-skins (set by the builder; tests and
## tooling use it to reach the live surface).
func get_torso() -> CritterTorso:
	return _torso


func _capture_rest(node: Node3D) -> void:
	if node == null:
		return
	_rest[node.get_instance_id()] = {"rot": node.rotation, "pos": node.position}
