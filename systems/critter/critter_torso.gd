class_name CritterTorso
extends RefCounted

## Continuous body surface for a critter — the Spore look.
##
## Instead of separate blob meshes per vertebra (which gap apart at some
## gene combinations), the whole body line — tail tip → spine → head →
## snout tip — is ONE swept tube skinned along the joint chain:
##   - control points ride the rig joints (they carry rest angles),
##   - a Catmull-Rom spline smooths the line and the radius profile,
##   - parallel-transport frames keep the sweep twist-free end to end,
##   - per-vertex colors paint the coat: belly gradient + stripes.
## CritterGait re-skins the tube when joints rotate, so the body bends
## fluidly through the whole animation instead of articulating in parts.
##
## Everything is computed in the owning space node's local transform, so
## the torso builds and re-skins even when detached from the scene tree
## (headless tests) and survives Node.duplicate().

## Radial resolution of the tube (vertices per ring).
const RADIAL := 10
## Spline subdivisions between control points.
const SUBDIV := 3

## The MeshInstance3D wearing the generated ArrayMesh (child of the space).
var mesh_instance: MeshInstance3D

## Node whose local space the sweep is generated in (the SpineRoot).
var space: Node3D

## Ordered sweep controls: {node: Node3D, offset: Vector3, radius: float}.
var controls: Array[Dictionary] = []

# Coat painting (vertex colors).
var base_color := Color(0.5, 0.4, 0.3)
var belly_color := Color(0.8, 0.75, 0.65)
var accent_color := Color(0.3, 0.22, 0.15)
## Stripe count along the body (0 = no stripes).
var stripe_count := 0
## 0..1 strength of the accent color.
var accent_amount := 0.0
## Direction dot below which the belly color blends in (space-local).
var belly_threshold := -0.1

var _last_pose: Dictionary = {}  ## node instance id -> rotation Vector3

## Reused across re-skins so a walking body does not allocate a mesh a frame.
var _mesh: ArrayMesh = null


func setup(space_node: Node3D, instance: MeshInstance3D) -> void:
	space = space_node
	mesh_instance = instance


func add_control(node: Node3D, offset: Vector3, radius: float) -> void:
	controls.append({"node": node, "offset": offset, "radius": maxf(radius, 0.012)})


## Re-skin only when a control joint actually rotated past epsilon — idle
## critters cost nothing, walking critters rebuild a tiny mesh.
func reskin_if_moved(epsilon := 0.004) -> bool:
	var moved := _last_pose.is_empty()
	for control in controls:
		var node := control["node"] as Node3D
		if node == null:
			continue
		var key := node.get_instance_id()
		var rotation_now: Vector3 = node.rotation
		if not _last_pose.has(key):
			moved = true
			break
		var delta_rot: Vector3 = _last_pose[key]
		if absf(rotation_now.x - delta_rot.x) > epsilon \
				or absf(rotation_now.y - delta_rot.y) > epsilon \
				or absf(rotation_now.z - delta_rot.z) > epsilon:
			moved = true
			break
	if moved:
		reskin()
	return moved


## Rebuild the tube mesh from the current joint transforms.
func reskin() -> void:
	for control in controls:
		var node := control["node"] as Node3D
		if node != null:
			_last_pose[node.get_instance_id()] = node.rotation
	if mesh_instance == null or controls.size() < 2:
		return

	# ── Collect controls, dropping near-coincident ones ──────────────────
	# A control closer to its predecessor than a fraction of the local tube
	# radius makes the centreline turn tighter than the tube is thick, and
	# the swept surface folds through itself. Merging them away is the
	# general guard; the head/snout layout in the builder is the specific
	# case that used to trip it on every single body.
	var positions: Array[Vector3] = []
	var radii: Array[float] = []
	for i in controls.size():
		var position := _control_position(i)
		var radius := float(controls[i]["radius"])
		if not positions.is_empty():
			var previous: Vector3 = positions[positions.size() - 1]
			var floor_gap: float = 0.35 * maxf(radius, radii[radii.size() - 1])
			if position.distance_to(previous) < floor_gap:
				# Keep the wider radius so the surface does not pinch.
				radii[radii.size() - 1] = maxf(radii[radii.size() - 1], radius)
				continue
		positions.append(position)
		radii.append(radius)
	if positions.size() < 2:
		return

	# ── Radius slope limit ───────────────────────────────────────────────
	# A tube cannot widen faster than it advances without the surface
	# turning back on itself. Short tails are the usual offender: a 2 cm
	# tail tip meeting a 35 cm body over 9 cm of length is a 75-degree
	# cone, and its rings overlap into inverted facets. Two sweeps clamp
	# every step to roughly a 42-degree flare. They only ever REDUCE radii,
	# so the result is a smooth taper into the tail rather than a step —
	# which is also what real animals look like.
	const MAX_SLOPE := 0.9
	for i in range(1, radii.size()):
		radii[i] = minf(radii[i],
			radii[i - 1] + MAX_SLOPE * positions[i].distance_to(positions[i - 1]))
	for i in range(radii.size() - 2, -1, -1):
		radii[i] = minf(radii[i],
			radii[i + 1] + MAX_SLOPE * positions[i].distance_to(positions[i + 1]))

	# ── Sample the spline ────────────────────────────────────────────────
	# Centripetal Catmull-Rom (alpha = 0.5). Control spacing inside one body
	# ranges over roughly 10x, and the uniform-parameter form overshoots and
	# self-loops across ratios like that. The centripetal form is provably
	# cusp- and loop-free for any spacing.
	var points := PackedVector3Array()
	var point_radii := PackedFloat32Array()
	for span in positions.size() - 1:
		var i0 := maxi(span - 1, 0)
		var i3 := mini(span + 2, positions.size() - 1)
		var p0: Vector3 = positions[i0]
		var p1: Vector3 = positions[span]
		var p2: Vector3 = positions[span + 1]
		var p3: Vector3 = positions[i3]
		var knots := _centripetal_knots(p0, p1, p2, p3)
		# Sample density follows span length relative to tube thickness, so
		# long spine spans stay smooth without over-sampling 3 cm head spans.
		var r_min := minf(radii[span], radii[span + 1])
		var r_max := maxf(radii[span], radii[span + 1])
		var subdiv := clampi(ceili(p1.distance_to(p2) / maxf(r_max * 0.6, 0.01)), 2, 8)
		for s in subdiv:
			var t := float(s) / float(subdiv)
			points.append(_catmull_nonuniform_v(p0, p1, p2, p3, knots, t))
			point_radii.append(clampf(
				_catmull_nonuniform_f(radii[i0], radii[span], radii[span + 1], radii[i3], knots, t),
				r_min * 0.75, r_max * 1.1))
	points.append(positions[positions.size() - 1])
	point_radii.append(radii[radii.size() - 1])
	if points.size() < 2:
		return

	# ── Curvature limit ──────────────────────────────────────────────────
	# A swept tube whose radius exceeds its centreline's radius of curvature
	# MUST fold through itself on the inside of the turn — the rings there
	# cross over and the quads between them come out inverted. Capping each
	# ring at a fraction of the local bend radius trades a slight pinch on
	# sharp turns for a surface that never self-intersects.
	for i in range(1, points.size() - 1):
		var limit := _curvature_radius(points[i - 1], points[i], points[i + 1])
		if limit < INF:
			point_radii[i] = minf(point_radii[i], limit * 0.8)

	# ── Parallel-transport frames along the line ─────────────────────────
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var tangent: Vector3 = (points[1] - points[0]).normalized()
	if tangent.length_squared() < 0.5:
		tangent = Vector3.FORWARD
	var side := _perpendicular(tangent)
	var up_dir := tangent.cross(side).normalized()

	var ring_count := points.size()
	for i in ring_count:
		if i > 0:
			var step := points[mini(i + 1, ring_count - 1)] - points[maxi(i - 1, 0)]
			# Coincident samples give no direction to transport toward, so
			# keep the previous frame rather than normalizing a zero vector.
			if step.length_squared() > 1e-12:
				# Transport the frame by projecting the previous side vector
				# onto the new tangent's perpendicular plane. A single
				# Quaternion(tangent, next_tangent) is undefined when the
				# line kinks near backwards (opposite vectors) and can flip
				# the ring frame — an inside-out tube you can see into.
				# Projection has no such singularity at any turn angle.
				tangent = step.normalized()
				var projected := side - tangent * side.dot(tangent)
				if projected.length_squared() < 0.0001:
					projected = up_dir - tangent * up_dir.dot(tangent)
				if projected.length_squared() < 0.0001:
					projected = _perpendicular(tangent)
				side = projected.normalized()
				up_dir = tangent.cross(side).normalized()
		var center: Vector3 = points[i]
		var radius := maxf(point_radii[i], 0.012)
		var u := float(i) / float(ring_count - 1)
		var ring_base := verts.size()
		for k in RADIAL:
			var theta := TAU * float(k) / float(RADIAL)
			var dir := (side * cos(theta) + up_dir * sin(theta)).normalized()
			verts.append(center + dir * radius)
			normals.append(dir)
			colors.append(_coat_color(dir, u))
			uvs.append(Vector2(u, float(k) / float(RADIAL)))
		if i > 0:
			var prev_base := ring_base - RADIAL
			for k in RADIAL:
				var k_next := (k + 1) % RADIAL
				indices.append(prev_base + k)
				indices.append(ring_base + k)
				indices.append(prev_base + k_next)
				indices.append(prev_base + k_next)
				indices.append(ring_base + k)
				indices.append(ring_base + k_next)

	# ── End caps (fan to a pole vertex) ──────────────────────────────────
	_append_cap(verts, normals, colors, indices, points, point_radii, uvs, 0, -1.0)
	_append_cap(verts, normals, colors, indices, points, point_radii, uvs, ring_count - 1, 1.0)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	# Reuse one ArrayMesh across re-skins. A walking critter rebuilds every
	# few frames, and allocating a fresh mesh each time is pure GC churn at
	# world population scale.
	if _mesh == null:
		_mesh = ArrayMesh.new()
		mesh_instance.mesh = _mesh
	else:
		_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh_instance.mesh != _mesh:
		mesh_instance.mesh = _mesh


# ── Internals ─────────────────────────────────────────────────────────────────


## Control position in the space node's local coordinates, composed from
## local transforms only (works detached from the scene tree).
##
## `chain` is collected child-first: chain[0] is the control node and
## chain[n-1] is its outermost ancestor below `space`. Composing to space
## coordinates therefore needs the OUTERMOST transform applied last:
##   A[n-1] * A[n-2] * ... * A[0] * offset
## Iterating forward and left-multiplying builds exactly that. Iterating
## backward builds the reverse product, which happens to agree for
## translation-only chains but diverges the moment any joint carries a
## rotation — i.e. for every arched spine, drooped snout, or animated pose.
func _control_position(index: int) -> Vector3:
	var node := controls[index]["node"] as Node3D
	var offset: Vector3 = controls[index]["offset"]
	var xform := Transform3D()
	var chain: Array[Node3D] = []
	var cur := node
	while cur != null and cur != space:
		chain.append(cur)
		cur = cur.get_parent() as Node3D
	for link in chain:
		xform = link.transform * xform
	return xform * offset


## Centripetal knot vector (alpha = 0.5) for four control points. Spacing
## each knot by sqrt(distance) is what makes the resulting Catmull-Rom
## provably free of cusps and self-intersections regardless of how uneven
## the control spacing is — the uniform form loops on ratios this body
## routinely produces (0.03 m head spans next to 0.28 m spine spans).
## The 1e-5 floor keeps the knots strictly increasing for coincident points.
func _centripetal_knots(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> PackedFloat32Array:
	var t0 := 0.0
	var t1: float = t0 + sqrt(maxf(p0.distance_to(p1), 1e-5))
	var t2: float = t1 + sqrt(maxf(p1.distance_to(p2), 1e-5))
	var t3: float = t2 + sqrt(maxf(p2.distance_to(p3), 1e-5))
	return PackedFloat32Array([t0, t1, t2, t3])


## Barry-Goldman evaluation of a non-uniform Catmull-Rom span (p1 -> p2).
func _catmull_nonuniform_v(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		knots: PackedFloat32Array, t: float) -> Vector3:
	var t0 := knots[0]
	var t1 := knots[1]
	var t2 := knots[2]
	var t3 := knots[3]
	var tt := lerpf(t1, t2, t)
	var a1 := p0.lerp(p1, (tt - t0) / (t1 - t0))
	var a2 := p1.lerp(p2, (tt - t1) / (t2 - t1))
	var a3 := p2.lerp(p3, (tt - t2) / (t3 - t2))
	var b1 := a1.lerp(a2, (tt - t0) / (t2 - t0))
	var b2 := a2.lerp(a3, (tt - t1) / (t3 - t1))
	return b1.lerp(b2, (tt - t1) / (t2 - t1))


## Same evaluation for the scalar radius profile, sharing the position-derived
## knots so the radius follows arc length rather than control index.
func _catmull_nonuniform_f(p0: float, p1: float, p2: float, p3: float,
		knots: PackedFloat32Array, t: float) -> float:
	var t0 := knots[0]
	var t1 := knots[1]
	var t2 := knots[2]
	var t3 := knots[3]
	var tt := lerpf(t1, t2, t)
	var a1 := lerpf(p0, p1, (tt - t0) / (t1 - t0))
	var a2 := lerpf(p1, p2, (tt - t1) / (t2 - t1))
	var a3 := lerpf(p2, p3, (tt - t2) / (t3 - t2))
	var b1 := lerpf(a1, a2, (tt - t0) / (t2 - t0))
	var b2 := lerpf(a2, a3, (tt - t1) / (t3 - t1))
	return lerpf(b1, b2, (tt - t1) / (t2 - t1))


## Radius of the circle through three consecutive centreline samples — the
## local radius of curvature. INF when they are collinear (a straight run
## imposes no limit on tube thickness).
func _curvature_radius(a: Vector3, b: Vector3, c: Vector3) -> float:
	var ab := b - a
	var ac := c - a
	var bc := c - b
	var area2 := ab.cross(ac).length()
	if area2 < 1e-9:
		return INF
	return (ab.length() * bc.length() * ac.length()) / (2.0 * area2)


func _perpendicular(direction: Vector3) -> Vector3:
	var helper := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return (helper - direction * helper.dot(direction)).normalized()


## Coat painting: belly gradient from the ring direction, stripes from the
## position along the body (u), blended into the base color.
func _coat_color(dir: Vector3, u: float) -> Color:
	var color := base_color
	var belly := clampf((-dir.y - belly_threshold) / 0.4, 0.0, 1.0) * 0.85
	if belly > 0.0:
		color = color.lerp(belly_color, belly)
	if stripe_count > 0 and accent_amount > 0.0:
		var band := sin(u * float(stripe_count) * TAU)
		var stripe := clampf((band - 0.55) / 0.25, 0.0, 1.0) * accent_amount
		if stripe > 0.0:
			color = color.lerp(accent_color, stripe)
	return color


## Close one end of the tube with a fan to a pole vertex.
##
## `direction` is -1 for the near (tail-tip) end and +1 for the far
## (snout-tip) end. The outward axis always points AWAY from the tube, so
## it is measured from the neighbour ring toward this one — the far end
## previously clamped its neighbour to itself, producing a zero-length
## tangent, a zero normal, and a pole sitting exactly on the ring centre.
##
## Winding matches the tube walls: in Godot a front-facing triangle has
## cross(B-A, C-A) pointing OPPOSITE the outward normal (verified against
## SphereMesh/BoxMesh/CapsuleMesh). Both caps used to be wound the other
## way, so back-face culling erased them and left permanent holes at the
## snout and tail tips that you could see into the body through.
## Tip poles have no belly side, so they take the stripe banding only.
## Feeding Vector3.ZERO through _coat_color gave every pole a fixed 21%
## belly blend and a visible colour seam once the caps became visible.
func _pole_color(u: float) -> Color:
	var color := base_color
	if stripe_count > 0 and accent_amount > 0.0:
		var band := sin(u * float(stripe_count) * TAU)
		var stripe := clampf((band - 0.55) / 0.25, 0.0, 1.0) * accent_amount
		if stripe > 0.0:
			color = color.lerp(accent_color, stripe)
	return color


func _append_cap(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		points: PackedVector3Array, point_radii: PackedFloat32Array,
		uvs: PackedVector2Array, ring_index: int, direction: float) -> void:
	var neighbor := clampi(
		ring_index + 1 if direction < 0.0 else ring_index - 1,
		0, points.size() - 1)
	var tangent := points[ring_index] - points[neighbor]
	if tangent.length_squared() < 1e-12:
		tangent = Vector3.FORWARD * direction
	tangent = tangent.normalized()
	# Round the tip off by the local radius. A hard-coded 0.01 left the cap
	# flat or sunken against rings 3-15x that size.
	var radius := maxf(point_radii[ring_index], 0.012)
	var u := 0.0 if direction < 0.0 else 1.0
	var pole := verts.size()
	verts.append(points[ring_index] + tangent * radius * 0.75)
	normals.append(tangent)
	colors.append(_pole_color(u))
	uvs.append(Vector2(u, 0.5))
	var ring_base := ring_index * RADIAL
	for k in RADIAL:
		var k_next := (k + 1) % RADIAL
		if direction < 0.0:
			indices.append(pole)
			indices.append(ring_base + k)
			indices.append(ring_base + k_next)
		else:
			indices.append(pole)
			indices.append(ring_base + k_next)
			indices.append(ring_base + k)
