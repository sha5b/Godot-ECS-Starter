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

	# ── Sample the spline ────────────────────────────────────────────────
	var positions: Array[Vector3] = []
	var radii: Array[float] = []
	for i in controls.size():
		positions.append(_control_position(i))
		radii.append(float(controls[i]["radius"]))
	var points := PackedVector3Array()
	var point_radii := PackedFloat32Array()
	for span in positions.size() - 1:
		var i0 := maxi(span - 1, 0)
		var i3 := mini(span + 2, positions.size() - 1)
		for s in SUBDIV:
			var t := float(s) / float(SUBDIV)
			points.append(_catmull(positions[i0], positions[span], positions[span + 1], positions[i3], t))
			# Catmull-Rom overshoots on steep radius steps; clamp each
			# sample to a band around its span's control radii so the tube
			# can spike or pinch into a see-through hole.
			var r_min := minf(radii[span], radii[span + 1])
			var r_max := maxf(radii[span], radii[span + 1])
			point_radii.append(clampf(
				_catmull_f(radii[i0], radii[span], radii[span + 1], radii[i3], t),
				r_min * 0.75, r_max * 1.1))
	points.append(positions[positions.size() - 1])
	point_radii.append(radii[radii.size() - 1])
	if points.size() < 2:
		return

	# ── Parallel-transport frames along the line ─────────────────────────
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var tangent: Vector3 = (points[1] - points[0]).normalized()
	var side := _perpendicular(tangent)
	var up_dir := tangent.cross(side).normalized()

	var ring_count := points.size()
	for i in ring_count:
		if i > 0:
			var next_tangent := (points[mini(i + 1, ring_count - 1)] - points[maxi(i - 1, 0)]).normalized()
			if next_tangent.length_squared() > 0.5:
				# Transport the frame by projecting the previous side vector
				# onto the new tangent's perpendicular plane. A single
				# Quaternion(tangent, next_tangent) is undefined when the
				# line kinks near backwards (opposite vectors) and can flip
				# the ring frame — an inside-out tube you can see into.
				# Projection has no such singularity at any turn angle.
				tangent = next_tangent
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
	_append_cap(verts, normals, colors, indices, points, 0, -1.0)
	_append_cap(verts, normals, colors, indices, points, ring_count - 1, 1.0)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_instance.mesh = mesh


# ── Internals ─────────────────────────────────────────────────────────────────


## Control position in the space node's local coordinates, composed from
## local transforms only (works detached from the scene tree).
func _control_position(index: int) -> Vector3:
	var node := controls[index]["node"] as Node3D
	var offset: Vector3 = controls[index]["offset"]
	var xform := Transform3D()
	var chain: Array[Node3D] = []
	var cur := node
	while cur != null and cur != space:
		chain.append(cur)
		cur = cur.get_parent() as Node3D
	for i in range(chain.size() - 1, -1, -1):
		xform = chain[i].transform * xform
	return xform * offset


func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


func _catmull_f(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


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


func _append_cap(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		points: PackedVector3Array, ring_index: int, direction: float) -> void:
	var neighbor := maxi(ring_index - 1, 1) if direction < 0.0 else mini(ring_index + 1, points.size() - 1)
	var tangent := (points[neighbor] - points[ring_index]).normalized() * direction
	var pole := verts.size()
	verts.append(points[ring_index] + tangent * 0.01)
	normals.append(tangent)
	colors.append(_coat_color(Vector3.ZERO, 0.0 if direction < 0.0 else 1.0))
	var ring_base := ring_index * RADIAL
	for k in RADIAL:
		var k_next := (k + 1) % RADIAL
		if direction < 0.0:
			indices.append(pole)
			indices.append(ring_base + k_next)
			indices.append(ring_base + k)
		else:
			indices.append(pole)
			indices.append(ring_base + k)
			indices.append(ring_base + k_next)
