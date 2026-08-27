extends Node3D

## Chunked, event-driven stylized grass view.
##
## Optimization model (this is the pattern the user asked for — rethink the
## mesh + chunking around what actually changes):
## - ONE MultiMesh, blades grouped into 8m ground chunks
## - colors change ONLY in response to chemistry events (ignite, burn out,
##   extinguish, freeze) plus a slow round-robin wetness sweep — no more
##   scanning every blade every frame
## - burning blades animate at ~10Hz and are tracked in a small set
## - one shared flat-shaded material, per-instance colors, no specular —
##   stylized look, one draw call, cheap shader
##
## The ECS owns all state; this is pure view.


const CHUNK_SIZE := 8.0
const BASE_COLOR := Color(0.30, 0.52, 0.18)
const BLADE_SIZE := Vector3(0.34, 0.95, 0.06)

## Visual states, ordered by render priority (higher overrides lower).
const STATE_NORMAL := 0
const STATE_WET := 1
const STATE_BURNING := 2
const STATE_FROZEN := 3
const STATE_CHARRED := 4

const ANIMATE_EVERY := 6       # frames between burning pulses (~10Hz)
const DIRTY_CHUNKS_PER_PASS := 3
const SWEEP_CHUNKS_PER_PASS := 2

var world: EcsWorld

var _multimesh: MultiMesh
var _entity_to_index: Dictionary = {}
var _base_shade := PackedFloat32Array()
var _last_state := PackedByteArray()

var _chunk_of_index: Array[Vector2i] = []
var _chunk_blades: Dictionary = {}   # Vector2i -> PackedInt32Array
var _chunk_keys: Array = []          # ordered, for the round-robin sweep
var _dirty_chunks: Dictionary = {}   # Vector2i -> true
var _sweep_cursor := 0

var _burning: Dictionary = {}        # index -> true
var _index_to_entity: Dictionary = {}  # reverse of _entity_to_index

var _time := 0.0
var _frame := 0


func setup(ecs_world: EcsWorld) -> void:
	world = ecs_world


func _ready() -> void:
	# Stylized blade: a thin prism reads as grass at RTS distance and is
	# cheaper than a box.
	var mesh := PrismMesh.new()
	mesh.size = BLADE_SIZE
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 1.0
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.material = _material

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = mesh

	var instance := MultiMeshInstance3D.new()
	instance.multimesh = _multimesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


var _material: StandardMaterial3D


## Pre-allocate the instance buffer once. Spare instances are parked
## underground where they are invisible.
func reserve(count: int) -> void:
	_multimesh.instance_count = max(count, 1)
	var hidden := Transform3D(Basis(), Vector3(0, -50, 0))
	for i in _multimesh.instance_count:
		_multimesh.set_instance_transform(i, hidden)
		_multimesh.set_instance_color(i, Color(0, 0, 0))


## Spawn one grass entity with a matching multimesh instance.
func spawn_blade(position: Vector3, fuel: float) -> int:
	var entity := world.spawn()
	var transform := CTransform.new()
	transform.position = position + Vector3(0.0, BLADE_SIZE.y * 0.5, 0.0)
	transform.facing = randf() * TAU
	transform.uniform_scale = randf_range(0.75, 1.35)
	world.add_component(entity, transform)
	var body := CBody.new()
	body.material = CBody.SurfaceMaterial.GRASS
	body.fuel = fuel
	world.add_component(entity, body)
	world.add_component(entity, CElemental.new())

	var index := _base_shade.size()
	_base_shade.append(randf_range(0.75, 1.2))
	_entity_to_index[entity] = index
	_index_to_entity[index] = entity
	if _last_state.size() < index + 1:
		_last_state.resize(index + 1)
	_last_state[index] = STATE_NORMAL

	var chunk := Vector2i(floori(position.x / CHUNK_SIZE), floori(position.z / CHUNK_SIZE))
	if _chunk_of_index.size() < index + 1:
		_chunk_of_index.resize(index + 1)
	_chunk_of_index[index] = chunk
	if not _chunk_blades.has(chunk):
		_chunk_blades[chunk] = PackedInt32Array()
		_chunk_keys.append(chunk)
	_chunk_blades[chunk].append(index)

	_multimesh.set_instance_transform(index, _blade_transform(transform))
	_multimesh.set_instance_color(index, _normal_color(index))
	return entity


## Event hook — the director forwards ECS chemistry events. This is the
## ONLY thing that triggers recolors outside the slow wetness sweep.
func on_ecs_event(channel: StringName, payload: Dictionary) -> void:
	var index: int = _entity_to_index.get(payload.get("entity", -1), -1)
	if index < 0:
		return
	match channel:
		ChemistryDefs.CHANNEL_IGNITED:
			_burning[index] = true
			_write(index, STATE_BURNING, _burning_color(index))
		ChemistryDefs.CHANNEL_BURNED_OUT:
			_burning.erase(index)
			_write(index, STATE_CHARRED, Color(0.06, 0.05, 0.04))
		ChemistryDefs.CHANNEL_EXTINGUISHED, ChemistryDefs.CHANNEL_FROZEN:
			_burning.erase(index)
			_mark_chunk_dirty(index)
		_:
			pass


func _process(delta: float) -> void:
	_time += delta
	_frame += 1
	if _frame % ANIMATE_EVERY != 0:
		return

	# Burning blades pulse — small set, animated at ~10Hz.
	for index in _burning:
		_multimesh.set_instance_color(index, _burning_color(index))

	# Chunks touched by events get a full recolor, a few per pass.
	var budget := DIRTY_CHUNKS_PER_PASS
	for chunk in _dirty_chunks.keys():
		if budget <= 0:
			break
		budget -= 1
		_dirty_chunks.erase(chunk)
		_recolor_chunk(chunk)

	# Round-robin wetness sweep so rain darkening / drying stays fresh
	# without ever touching the whole field in one frame.
	for i in SWEEP_CHUNKS_PER_PASS:
		if _chunk_keys.is_empty():
			break
		var chunk: Vector2i = _chunk_keys[_sweep_cursor % _chunk_keys.size()]
		_sweep_cursor += 1
		if not _dirty_chunks.has(chunk):
			_recolor_chunk(chunk)


func _recolor_chunk(chunk: Vector2i) -> void:
	var blades: PackedInt32Array = _chunk_blades.get(chunk, PackedInt32Array())
	for index in blades:
		var state := _state_of(index)
		if state == _last_state[index] and state != STATE_BURNING:
			continue
		_write(index, state, _color_for_state(index, state))


func _state_of(index: int) -> int:
	if _burning.has(index):
		return STATE_BURNING
	var entity: int = int(_index_to_entity.get(index, 0))
	if entity == 0 or not world.is_alive(entity):
		return STATE_CHARRED
	var elemental := world.get_component(entity, &"CElemental") as CElemental
	if elemental == null:
		return STATE_NORMAL
	if elemental.charred:
		return STATE_CHARRED
	if elemental.frozen:
		return STATE_FROZEN
	if elemental.wetness > 0.35:
		return STATE_WET
	return STATE_NORMAL


func _color_for_state(index: int, state: int) -> Color:
	match state:
		STATE_CHARRED:
			return Color(0.06, 0.05, 0.04)
		STATE_FROZEN:
			return Color(0.68, 0.86, 1.0)
		STATE_BURNING:
			return _burning_color(index)
		STATE_WET:
			return _normal_color(index).darkened(0.35)
		_:
			return _normal_color(index)


func _burning_color(index: int) -> Color:
	var pulse := 0.5 + 0.3 * sin(_time * 14.0 + index)
	return Color(1.0, 0.35 + 0.25 * pulse, 0.08)


func _normal_color(index: int) -> Color:
	var shade := _base_shade[index]
	return Color(BASE_COLOR.r * shade, BASE_COLOR.g * shade, BASE_COLOR.b * shade)


func _write(index: int, state: int, color: Color) -> void:
	_last_state[index] = state
	_multimesh.set_instance_color(index, color)


func _mark_chunk_dirty(index: int) -> void:
	if index < _chunk_of_index.size():
		_dirty_chunks[_chunk_of_index[index]] = true


func _blade_transform(transform: CTransform) -> Transform3D:
	var basis := Basis(Vector3.UP, transform.facing).scaled(
		Vector3.ONE * transform.uniform_scale)
	return Transform3D(basis, transform.position)
