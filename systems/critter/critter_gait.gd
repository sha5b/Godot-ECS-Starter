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

## Which way the knee folds in the IK solve. The rig's knees bend backwards
## (foot trails the hip), so the hip aims ahead of the target direction.
const IK_ELBOW_SIGN := -1.0

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
	for i in _hips.size():
		var hip := _hips[i]
		var foot := _feet[i]
		if hip == null or foot == null or not foot.is_inside_tree():
			continue
		var ground: float = ground_sampler.call(foot.global_position.x, foot.global_position.z)
		if not is_finite(ground):
			continue
		# Keep whatever lift the gait asked for, measured from the terrain
		# rather than from a flat plane.
		var lift_gain: float = _leg_lift[i] * _lower_len * 0.35
		var target_y := ground + _foot_contact + lift_gain
		# Two stages, because one joint is not enough: the knee sets how FAR
		# the foot is from the hip, the hip pitch then swings that reach onto
		# the target height. Solving only the pitch leaves the foot on a
		# fixed-radius arc that need not pass through the target at all.
		# Two passes: pitching the hip moves the foot, which changes how far
		# the target is, which changes the knee. Two rounds converge; more
		# buys nothing measurable.
		for _pass in 2:
			_solve_knee_reach(_knees[i], hip, foot, target_y)
			_solve_hip_pitch(hip, foot, target_y)


## Close or open the knee until the hip-to-foot distance matches how far
## the target actually is. Monotonic — folding the knee always brings the
## foot nearer the hip — so a plain bisection is enough.
func _solve_knee_reach(knee: Node3D, hip: Node3D, foot: Node3D, target_y: float) -> void:
	if knee == null:
		return
	var hip_pos := hip.global_position
	var want: float = Vector3(foot.global_position.x, target_y,
		foot.global_position.z).distance_to(hip_pos)
	var base := knee.rotation
	var lo := 0.0
	var hi := PI * 0.85
	for _iter in 7:
		var mid := (lo + hi) * 0.5
		knee.rotation = Vector3(mid, base.y, base.z)
		if foot.global_position.distance_to(hip_pos) > want:
			lo = mid
		else:
			hi = mid
	knee.rotation = Vector3((lo + hi) * 0.5, base.y, base.z)


## Pitch one hip so its foot reaches `target_y`, by search rather than by
## a closed form.
##
## An analytic two-bone solve looked right and was wrong: Node3D uses YXZ
## Euler order, so a hip's rotation composes as Ry * Rx * Rz and the fixed
## outward splay on Z is applied AFTER the pitch on X. The limb therefore
## does not swing in the plane a planar solver assumes, and every splayed
## leg came out 6-16 cm off. Searching the one axis we actually control
## sidesteps the whole issue and is exact to the sample resolution.
##
## Coarse sweep first so it cannot be fooled by the non-monotonic tails of
## the reach curve, then a short bisection inside the winning bracket.
func _solve_hip_pitch(hip: Node3D, foot: Node3D, target_y: float) -> void:
	var base := hip.rotation
	var best := base.x
	var best_err := INF
	const SPAN := 1.3
	const COARSE := 7
	for c in COARSE:
		var angle := base.x - SPAN + 2.0 * SPAN * float(c) / float(COARSE - 1)
		hip.rotation = Vector3(angle, base.y, base.z)
		var err := absf(foot.global_position.y - target_y)
		if err < best_err:
			best_err = err
			best = angle
	var step := 2.0 * SPAN / float(COARSE - 1)
	var lo := best - step
	var hi := best + step
	for _iter in 4:
		var mid_lo := lo + (hi - lo) * 0.33
		var mid_hi := lo + (hi - lo) * 0.67
		hip.rotation = Vector3(mid_lo, base.y, base.z)
		var err_lo := absf(foot.global_position.y - target_y)
		hip.rotation = Vector3(mid_hi, base.y, base.z)
		var err_hi := absf(foot.global_position.y - target_y)
		if err_lo < err_hi:
			hi = mid_hi
		else:
			lo = mid_lo
	hip.rotation = Vector3((lo + hi) * 0.5, base.y, base.z)


## The torso skinner this gait re-skins (set by the builder; tests and
## tooling use it to reach the live surface).
func get_torso() -> CritterTorso:
	return _torso


func _capture_rest(node: Node3D) -> void:
	if node == null:
		return
	_rest[node.get_instance_id()] = {"rot": node.rotation, "pos": node.position}
