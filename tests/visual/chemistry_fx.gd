extends Node3D

## Pooled chemistry visuals: light pillars for lightning strikes, white
## flashes for shocks.
##
## The old version spawned a node + material per event. During a
## fast-spreading fire that meant hundreds of node creations per second —
## the single biggest framerate killer in this scene. Everything here is
## pre-allocated at ready and recycled round-robin; runtime cost per event
## is moving two nodes and resetting a timer.


const STRIKE_COLOR := Color(0.75, 0.85, 1.0)
const SHOCK_COLOR := Color(1.0, 1.0, 0.8)

const FLASH_POOL := 24
const PILLAR_POOL := 8
const FLASH_LIFE := 0.3
const PILLAR_LIFE := 0.45

var _flashes: Array[MeshInstance3D] = []
var _flash_ttl := PackedFloat32Array()
var _pillars: Array[Node3D] = []
var _pillar_ttl := PackedFloat32Array()
var _flash_cursor := 0
var _pillar_cursor := 0


func _ready() -> void:
	var flash_mesh := SphereMesh.new()
	flash_mesh.radius = 0.5
	flash_mesh.height = 1.0
	var flash_material := StandardMaterial3D.new()
	flash_material.emission_enabled = true
	flash_material.emission = SHOCK_COLOR
	flash_material.emission_energy_multiplier = 3.0
	flash_material.albedo_color = SHOCK_COLOR
	for i in FLASH_POOL:
		var flash := MeshInstance3D.new()
		flash.mesh = flash_mesh
		flash.material_override = flash_material
		flash.visible = false
		add_child(flash)
		_flashes.append(flash)
		_flash_ttl.append(0.0)

	var pillar_mesh := BoxMesh.new()
	pillar_mesh.size = Vector3(0.35, 26.0, 0.35)
	var pillar_material := StandardMaterial3D.new()
	pillar_material.emission_enabled = true
	pillar_material.emission = STRIKE_COLOR
	pillar_material.emission_energy_multiplier = 3.0
	pillar_material.albedo_color = STRIKE_COLOR
	for i in PILLAR_POOL:
		var pillar := Node3D.new()
		var mesh := MeshInstance3D.new()
		mesh.mesh = pillar_mesh
		mesh.material_override = pillar_material
		pillar.add_child(mesh)
		var light := OmniLight3D.new()
		light.omni_range = 14.0
		light.light_color = STRIKE_COLOR
		light.light_energy = 4.0
		pillar.add_child(light)
		pillar.visible = false
		add_child(pillar)
		_pillars.append(pillar)
		_pillar_ttl.append(0.0)


## Callable(channel, payload) — wired via EcsSystem.add_event_listener.
func on_ecs_event(channel: StringName, payload: Dictionary) -> void:
	match channel:
		ChemistryDefs.CHANNEL_STRIKE:
			_show(_pillars, _pillar_ttl, _pillar_cursor, payload["position"] + Vector3(0, 13, 0), PILLAR_LIFE)
			_pillar_cursor = (_pillar_cursor + 1) % PILLAR_POOL
		ChemistryDefs.CHANNEL_SHOCKED:
			_show(_flashes, _flash_ttl, _flash_cursor, payload["position"] + Vector3(0, 0.6, 0), FLASH_LIFE)
			_flash_cursor = (_flash_cursor + 1) % FLASH_POOL


func _process(delta: float) -> void:
	_tick_pool(_flashes, _flash_ttl, delta)
	_tick_pool(_pillars, _pillar_ttl, delta)


func _show(pool: Array, ttls: PackedFloat32Array, cursor: int, position: Vector3, life: float) -> void:
	var node := pool[cursor] as Node3D
	node.position = position
	node.visible = true
	node.scale = Vector3.ONE
	ttls[cursor] = life


func _tick_pool(pool: Array, ttls: PackedFloat32Array, delta: float) -> void:
	for i in pool.size():
		if ttls[i] <= 0.0:
			continue
		ttls[i] = maxf(ttls[i] - delta, 0.0)
		var node := pool[i] as Node3D
		if ttls[i] == 0.0:
			node.visible = false
		else:
			node.scale = Vector3.ONE * (0.4 + 0.6 * ttls[i] / 0.45)
