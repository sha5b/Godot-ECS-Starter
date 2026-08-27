class_name EdgeFogSystem
extends BaseSystem

## Volumetric fog ring that hides the chunk-loading frontier.
##
## Four FogVolume walls live just outside the loaded chunk region and
## follow the camera chunk-for-chunk. Terrain streams in clear INSIDE the
## ring while the fog stays at the ever-advancing edge, so the world ends
## in soft volumetric mist instead of a visible cliff of missing chunks.
## Requires the environment's volumetric fog to be enabled (base density
## stays ~0 — only the walls contribute).


var _walls: Array[FogVolume] = []
var _last_chunk := Vector2i(999999, 999999)
var _config: EdgeFogConfig


func _initialize() -> void:
	system_name = &"EdgeFog"
	priority = 100
	_config = _find_child_of_type(EdgeFogConfig) as EdgeFogConfig
	if _config == null:
		_config = EdgeFogConfig.new()
		add_child(_config)
	for i in 4:
		var wall := FogVolume.new()
		wall.name = "EdgeFogWall%d" % i
		var material := FogMaterial.new()
		material.density = _config.density
		material.albedo = _config.fog_color
		wall.material = material
		add_child(wall)
		_walls.append(wall)
	_layout(SharedWorld.camera_chunk_pos)


func _register_signals() -> void:
	pass


func system_process(_delta: float) -> void:
	var current := SharedWorld.camera_chunk_pos
	if current != _last_chunk:
		_layout(current)


func _layout(camera_chunk: Vector2i) -> void:
	_last_chunk = camera_chunk
	var cs := GameConfig.chunk_size
	var r := GameConfig.load_radius
	# Loaded region spans chunks [c-r .. c+r] per axis.
	var region_min := Vector2(camera_chunk.x - r, camera_chunk.y - r) * cs
	var region_max := Vector2(camera_chunk.x + r + 1, camera_chunk.y + r + 1) * cs
	var center := (region_min + region_max) * 0.5
	var span_x: float = (region_max.x - region_min.x) + _config.thickness * 2.0 + cs
	var span_z: float = (region_max.y - region_min.y) + _config.thickness * 2.0 + cs

	# North / south walls (across X), east / west walls (across Z).
	_position_wall(_walls[0], Vector3(center.x, 0.0, region_min.y - _config.thickness * 0.5),
		Vector3(span_x, _config.height, _config.thickness))
	_position_wall(_walls[1], Vector3(center.x, 0.0, region_max.y + _config.thickness * 0.5),
		Vector3(span_x, _config.height, _config.thickness))
	_position_wall(_walls[2], Vector3(region_min.x - _config.thickness * 0.5, 0.0, center.y),
		Vector3(_config.thickness, _config.height, span_z))
	_position_wall(_walls[3], Vector3(region_max.x + _config.thickness * 0.5, 0.0, center.y),
		Vector3(_config.thickness, _config.height, span_z))


func _position_wall(wall: FogVolume, position: Vector3, size: Vector3) -> void:
	wall.position = position
	wall.size = size
	wall.visible = true


func _shutdown() -> void:
	_walls.clear()
