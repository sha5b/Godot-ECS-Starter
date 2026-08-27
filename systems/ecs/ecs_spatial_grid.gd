class_name EcsSpatialGrid
extends RefCounted

## Uniform-grid spatial hash over entity positions.
## Chemistry and AI sensors use it for radius queries; rebuilt per consumer
## tick because entities move. Cell keys are Vector2i (XZ plane) — the
## chemistry playground is effectively planar.


var cell_size := 4.0

var _cells: Dictionary = {}  ## Vector2i -> PackedInt64Array


func clear() -> void:
	_cells.clear()


func insert(entity: int, position: Vector3) -> void:
	var key := cell_key(position)
	if not _cells.has(key):
		_cells[key] = PackedInt64Array()
	_cells[key].append(entity)


## All unique entities with positions within `radius` of `position`.
func query_radius(position: Vector3, radius: float) -> PackedInt64Array:
	var out := PackedInt64Array()
	var r_cells := ceili(radius / cell_size)
	var center := cell_key(position)
	var radius_sq := radius * radius
	for cx in range(center.x - r_cells, center.x + r_cells + 1):
		for cz in range(center.y - r_cells, center.y + r_cells + 1):
			var cell: PackedInt64Array = _cells.get(Vector2i(cx, cz), PackedInt64Array())
			for entity in cell:
				out.append(entity)
	# Distance filtering happens in the caller (it has positions);
	# here we only guarantee the candidate neighborhood.
	return out


func cell_key(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / cell_size),
		floori(position.z / cell_size)
	)
